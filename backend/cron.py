import sqlite3, time, asyncio, logging

logging.basicConfig(level=logging.INFO)
DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def get_settings():
    conn = get_db()
    rows = conn.execute("SELECT key,value FROM settings").fetchall()
    conn.close()
    return {r['key']: r['value'] for r in rows}

def check_expired_users():
    """Помечает истёкших пользователей"""
    conn = get_db()
    now = int(time.time())
    
    # Истёкшие по дате
    expired = conn.execute(
        "SELECT id,username FROM users WHERE status='active' AND expire_at>0 AND expire_at<?",
        (now,)
    ).fetchall()
    for u in expired:
        conn.execute("UPDATE users SET status='expired' WHERE id=?", (u['id'],))
        logging.info(f'Истёк: {u["username"]}')
    
    # Превышен лимит трафика
    overlimit = conn.execute(
        "SELECT id,username FROM users WHERE status='active' AND data_limit>0 AND data_used>=data_limit"
    ).fetchall()
    for u in overlimit:
        conn.execute("UPDATE users SET status='disabled' WHERE id=?", (u['id'],))
        logging.info(f'Превышен лимит: {u["username"]}')
    
    conn.commit()
    conn.close()
    return len(expired), len(overlimit)

def auto_extend_users():
    """Автопродление если включено"""
    settings = get_settings()
    if settings.get('auto_extend') != '1':
        return 0
    
    days = int(settings.get('auto_extend_days', '30'))
    conn = get_db()
    now = int(time.time())
    
    # Пользователи у которых истекает через 1 день и включено автопродление
    users = conn.execute(
        "SELECT id,username,expire_at FROM users WHERE status='active' AND auto_extend=1 AND expire_at>0 AND expire_at<?",
        (now + 86400,)
    ).fetchall()
    
    for u in users:
        new_expire = (u['expire_at'] or now) + days * 86400
        conn.execute("UPDATE users SET expire_at=? WHERE id=?", (new_expire, u['id']))
        logging.info(f'Автопродлён: {u["username"]} на {days} дней')
    
    conn.commit()
    conn.close()
    return len(users)

def notify_expiring():
    """Уведомления в Telegram за 3 дня до истечения"""
    settings = get_settings()
    token = settings.get('tg_bot_token','')
    if not token: return
    
    conn = get_db()
    now = int(time.time())
    soon = now + 3 * 86400
    
    users = conn.execute(
        "SELECT id,username,telegram_id,expire_at FROM users WHERE status='active' AND expire_at>? AND expire_at<? AND telegram_id IS NOT NULL AND telegram_id!=''",
        (now, soon)
    ).fetchall()
    
    import urllib.request, json
    for u in users:
        days_left = round((u['expire_at'] - now) / 86400)
        msg = f'⚠️ Ваша подписка истекает через {days_left} дней!\n\nИспользуйте /start для продления.'
        try:
            data = json.dumps({'chat_id': u['telegram_id'], 'text': msg}).encode()
            req = urllib.request.Request(
                f'https://api.telegram.org/bot{token}/sendMessage',
                data=data,
                headers={'Content-Type': 'application/json'}
            )
            urllib.request.urlopen(req, timeout=5)
            logging.info(f'Уведомление отправлено: {u["username"]}')
        except Exception as e:
            logging.error(f'Ошибка уведомления {u["username"]}: {e}')
    
    conn.close()


import requests as _req

# Снапшот для дельты трафика по нодам
_cron_prev_stats = {}

def collect_connections():
    """Собирает трафик по протоколам/нодам через V2Ray Stats API (каждые 5 мин)"""
    import sys, socket, threading
    proto_dir = '/tmp/vpn_stats_proto'
    if proto_dir not in sys.path:
        sys.path.insert(0, proto_dir)
    venv = '/opt/vpn_panel/venv/lib/python3.12/site-packages'
    if venv not in sys.path:
        sys.path.insert(0, venv)

    # Берём node_id из БД чтобы совпадало с таблицей nodes
    db_nodes = get_db()
    node_rows = db_nodes.execute("SELECT id, host FROM nodes WHERE status='online'").fetchall()
    db_nodes.close()
    host_to_id = {r['host']: r['id'] for r in node_rows}

    NODE_CONFIGS = [
        {'key': host_to_id.get('212.15.49.151', 'russia'), 'host': '212.15.49.151',  'password': 'PVJXSWnS6ZXUg', 'local_port': 18381},
        {'key': host_to_id.get('150.241.106.238', 'de'),   'host': '150.241.106.238', 'password': 'alexander77',    'local_port': 18382},
        {'key': host_to_id.get('150.241.88.243', 'fin'),   'host': '150.241.88.243',  'password': 'alexander77',    'local_port': 18383},
    ]
    BRIDGE_UUID = '3b5ba9bb-c766-46a4-8485-a3a5e2bddaeb'

    try:
        import grpc, stats_pb2, stats_pb2_grpc
    except ImportError:
        logging.warning('cron: grpc not available, skip traffic_hourly')
        return

    db = get_db()
    now = int(time.time())
    hour = now - (now % 3600)

    for node in NODE_CONFIGS:
        local_port = node['local_port']
        node_key = node['key']
        try:
            ch = grpc.insecure_channel(f'127.0.0.1:{local_port}')
            stub = stats_pb2_grpc.StatsServiceStub(ch)
            resp = stub.QueryStats(stats_pb2.QueryStatsRequest(pattern='', reset=False), timeout=3)
            ch.close()

            # Считаем трафик по протоколам
            proto_up = {}
            proto_down = {}
            for s in resp.stat:
                parts = s.name.split('>>>')
                if len(parts) != 4 or parts[0] != 'inbound' or parts[2] != 'traffic':
                    continue
                tag = parts[1]  # vless-in, hysteria2-in, bridge-fin-in
                if 'vless' in tag:
                    proto = 'vless'
                elif 'hysteria' in tag or 'bridge' in tag:
                    proto = 'hysteria2'
                else:
                    continue

                if parts[3] == 'uplink':
                    proto_up[proto] = proto_up.get(proto, 0) + s.value
                elif parts[3] == 'downlink':
                    proto_down[proto] = proto_down.get(proto, 0) + s.value

            # Считаем дельту
            prev = _cron_prev_stats.get(node_key, {})
            for proto in set(list(proto_up.keys()) + list(proto_down.keys())):
                up = proto_up.get(proto, 0)
                down = proto_down.get(proto, 0)
                prev_up = prev.get(f'{proto}_up', up)
                prev_down = prev.get(f'{proto}_down', down)
                delta_up = max(0, up - prev_up)
                delta_down = max(0, down - prev_down)
                _cron_prev_stats.setdefault(node_key, {})[f'{proto}_up'] = up
                _cron_prev_stats.setdefault(node_key, {})[f'{proto}_down'] = down

                if delta_up + delta_down <= 0:
                    continue

                existing = db.execute(
                    "SELECT id FROM traffic_hourly WHERE hour=? AND protocol=? AND node_id=?",
                    (hour, proto, node_key)
                ).fetchone()
                if existing:
                    db.execute(
                        "UPDATE traffic_hourly SET bytes_up=bytes_up+?, bytes_down=bytes_down+? WHERE id=?",
                        (delta_up, delta_down, existing[0])
                    )
                else:
                    db.execute(
                        "INSERT INTO traffic_hourly (hour,protocol,node_id,bytes_up,bytes_down) VALUES (?,?,?,?,?)",
                        (hour, proto, node_key, delta_up, delta_down)
                    )

        except Exception as e:
            logging.warning(f'cron collect [{node_key}]: {e}')

    db.commit()
    db.close()

def run():
    logging.info('🔄 Cron запущен')
    while True:
        try:
            collect_connections()
            collect_connection_logs()
            expired, overlimit = check_expired_users()
            extended = auto_extend_users()
            notify_expiring()
            if expired or overlimit or extended:
                logging.info(f'Истекло: {expired}, Лимит: {overlimit}, Продлено: {extended}')
        except Exception as e:
            logging.error(f'Ошибка cron: {e}')
        time.sleep(300)  # каждые 5 минут

if __name__ == '__main__':
    run()

def collect_connection_logs():
    """Собирает логи подключений со всех нод и сохраняет в audit_log"""
    import paramiko
    
    NODE_CONFIGS = [
        {'key': 'russia', 'host': '212.15.49.151',  'password': 'PVJXSWnS6ZXUg',  'name': 'russia'},
        {'key': 'de',     'host': '150.241.106.238', 'password': 'alexander77',     'name': 'de'},
        {'key': 'fin',    'host': '150.241.88.243',  'password': 'alexander77',     'name': 'fin'},
    ]
    
    db = get_db()
    
    # Получаем маппинг UUID -> username
    users = db.execute("SELECT id, username FROM users").fetchall()
    uuid_to_name = {u['id']: u['username'] for u in users}
    
    # Последняя обработанная временная метка для каждой ноды
    for node in NODE_CONFIGS:
        try:
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.connect(node['host'], username='root', password=node['password'], timeout=10)
            
            # Читаем последние 200 строк лога
            _, stdout, _ = ssh.exec_command('tail -200 /var/log/sing-box.log')
            lines = stdout.read().decode(errors='ignore').splitlines()
            ssh.close()
            
            now = int(time.time())
            
            for line in lines:
                event_type = None
                username = None
                details = {}
                
                # Успешное подключение с UUID
                # INFO [...] inbound/vless[vless-in]: [UUID] inbound connection to HOST
                if 'inbound connection to' in line and '] inbound connection' in line:
                    import re
                    # Извлекаем UUID
                    uuid_match = re.search(r'\[([0-9a-f-]{36})\]', line)
                    if uuid_match:
                        uuid = uuid_match.group(1)
                        if uuid in uuid_to_name:
                            username = uuid_to_name[uuid]
                            # Протокол
                            if 'vless' in line:
                                proto = 'VLESS'
                            elif 'hysteria2' in line or 'bridge' in line:
                                proto = 'Hysteria2'
                            else:
                                proto = 'unknown'
                            event_type = 'connection_ok'
                            details = {'proto': proto, 'node': node['name']}
                
                # Ошибка подключения - неверный ключ/EOF
                elif 'process connection from' in line and ('EOF' in line or 'error' in line.lower()):
                    import re
                    ip_match = re.search(r'from (\d+\.\d+\.\d+\.\d+)', line)
                    ip = ip_match.group(1) if ip_match else 'unknown'
                    if 'vless' in line:
                        proto = 'VLESS'
                    elif 'hysteria' in line:
                        proto = 'Hysteria2'
                    else:
                        proto = 'unknown'
                    reason = 'EOF - неверный ключ или несовместимый клиент'
                    if 'i/o timeout' in line:
                        reason = 'Timeout'
                    event_type = 'connection_fail'
                    username = f'unknown ({ip})'
                    details = {'proto': proto, 'node': node['name'], 'reason': reason, 'ip': ip}
                
                if not event_type:
                    continue
                
                # Парсим время из лога
                import re
                time_match = re.search(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', line)
                if not time_match:
                    continue
                
                # Проверяем дубликаты - не добавляем если уже есть такая запись
                existing = db.execute(
                    "SELECT id FROM audit_log WHERE action=? AND details LIKE ? AND created_at > ?",
                    (event_type, f'%{node["name"]}%', now - 600)
                ).fetchone()
                
                # Дедупликация - не добавляем одинаковые события за последние 5 мин
                if event_type == 'connection_fail':
                    ip = details.get('ip', '')
                    dup = db.execute(
                        "SELECT id FROM audit_log WHERE action='connection_fail' AND details LIKE ? AND created_at > ?",
                        (f'%{ip}%', now - 600)
                    ).fetchone()
                    if dup:
                        continue
                elif event_type == 'connection_ok':
                    dup = db.execute(
                        "SELECT id FROM audit_log WHERE action='connection_ok' AND details LIKE ? AND created_at > ?",
                        (f'%{username}%{node["name"]}%', now - 600)
                    ).fetchone()
                    if dup:
                        continue
                
                detail_str = f"proto: {details.get('proto','?')}, node: {details.get('node','?')}"
                if 'reason' in details:
                    detail_str += f", reason: {details['reason']}"
                
                full_detail = f"{username or 'unknown'} | {detail_str}"
                db.execute(
                    "INSERT INTO audit_log (admin, action, details, created_at) VALUES (?,?,?,?)",
                    ('system', event_type, full_detail, now)
                )
        
        except Exception as e:
            logging.warning(f'collect_logs [{node["name"]}]: {e}')
    
    db.commit()
    db.close()
