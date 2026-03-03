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

def collect_connections():
    """Собирает данные подключений из Clash API каждые 5 минут"""
    try:
        r = _req.get('http://127.0.0.1:9090/connections', timeout=3)
        if r.status_code != 200: return
        data = r.json()
        conns = data.get('connections', [])
        if not conns: return
        
        conn = get_db()
        now = int(time.time())
        hour = now - (now % 3600)
        
        for c in conns:
            meta = c.get('metadata', {})
            src_ip = meta.get('sourceIP','')
            proto_type = meta.get('type','')
            
            # Определяем протокол
            if 'hysteria2' in proto_type.lower():
                protocol = 'hysteria2'
            elif 'vless' in proto_type.lower():
                protocol = 'vless'
            else:
                protocol = 'other'
            
            # Определяем ноду по source IP
            if src_ip.startswith('185.40'):
                node_id = 'ru75'
            else:
                node_id = 'main'
            
            up = c.get('upload', 0)
            down = c.get('download', 0)
            
            # Ищем пользователя по UUID в chains
            chains = c.get('chains', [])
            user_id = None
            username = 'unknown'
            
            # Сохраняем почасовую статистику
            existing = conn.execute(
                "SELECT id,bytes_up,bytes_down FROM traffic_hourly WHERE hour=? AND protocol=? AND node_id=?",
                (hour, protocol, node_id)
            ).fetchone()
            
            if existing:
                conn.execute(
                    "UPDATE traffic_hourly SET bytes_up=bytes_up+?, bytes_down=bytes_down+? WHERE id=?",
                    (up, down, existing[0])
                )
            else:
                conn.execute(
                    "INSERT INTO traffic_hourly (hour,protocol,node_id,bytes_up,bytes_down) VALUES (?,?,?,?,?)",
                    (hour, protocol, node_id, up, down)
                )
        
        conn.commit()
        conn.close()
    except Exception as e:
        logging.error(f'collect_connections error: {e}')

def run():
    logging.info('🔄 Cron запущен')
    while True:
        try:
            collect_connections()
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
