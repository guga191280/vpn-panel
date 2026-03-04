import sqlite3, time, requests, sys, json
sys.path.insert(0, '/opt/vpn_panel/backend')
DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'
_prev = {}

_logged_ips = {}  # ip -> timestamp последнего логирования

def log_connection(source_ip, protocol, node_id):
    """Записывает новое соединение в connection_logs"""
    if not source_ip: return
    key = (source_ip, protocol, node_id)
    now = int(time.time())
    # Логируем одно соединение раз в 5 минут
    if key in _logged_ips and now - _logged_ips[key] < 300:
        return
    _logged_ips[key] = now
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    # Находим пользователя - берём первого активного (потом можно улучшить)
    user = conn.execute("SELECT id, username FROM users WHERE status='active' LIMIT 1").fetchone()
    if user:
        conn.execute("""INSERT INTO connection_logs 
            (user_id, username, protocol, node_id, ip, timestamp)
            VALUES (?,?,?,?,?,?)""",
            (user['id'], user['username'], protocol, node_id, source_ip, now))
        conn.commit()
    conn.close()


def get_db():
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row; return conn
def get_nodes():
    conn = get_db()
    rows = conn.execute("SELECT id, host FROM nodes WHERE status='online'").fetchall()
    conn.close()
    result = {}
    for r in rows:
        host = '127.0.0.1' if r['host'] in ('185.40.4.169','ru75.alexanderoff.store') else r['host']
        result[r['id']] = {'host': host, 'port': 9090, 'secret': ''}
    return result
def get_settings():
    conn = get_db()
    rows = conn.execute("SELECT key,value FROM settings").fetchall()
    conn.close()
    return {r['key']: r['value'] for r in rows}
def get_all_active_users():
    conn = get_db()
    rows = conn.execute("SELECT id FROM users WHERE status='active'").fetchall()
    conn.close()
    return [r['id'] for r in rows]
def collect_node(node_id, node):
    try:
        r = requests.get(f'http://{node["host"]}:{node["port"]}/connections',
            headers={'Authorization': f'Bearer {node["secret"]}'}, timeout=5)
        if r.status_code != 200: return {}
        conns = r.json().get('connections', [])
        result = {}
        for c in conns:
            cid = c['id']
            upload = c.get('upload', 0); download = c.get('download', 0)
            conn_type = c.get('metadata', {}).get('type', '')
            if 'hysteria2' in conn_type: protocol = 'hysteria2'
            elif 'vless' in conn_type: protocol = 'vless'
            else: protocol = 'unknown'
            source_ip = c.get('metadata', {}).get('sourceIP', '')
            if cid in _prev:
                prev = _prev[cid]
                up_d = max(0, upload - prev['upload'])
                dn_d = max(0, download - prev['download'])
            else:
                up_d = dn_d = 0
            _prev[cid] = {'upload': upload, 'download': download}
            log_connection(source_ip, protocol, node_id)
            if up_d > 0 or dn_d > 0:
                result[cid] = {'upload_delta': up_d, 'download_delta': dn_d,
                               'protocol': protocol, 'source_ip': source_ip, 'node_id': node_id}
        active_ids = {c['id'] for c in conns}
        for k in list(_prev.keys()):
            if k not in active_ids: del _prev[k]
        return result
    except Exception as e:
        print(f"collect_node error [{node_id}]: {e}"); return {}
def update_db(node_id, connections_data):
    if not connections_data: return
    conn = get_db(); now = int(time.time())
    hour = int(now // 3600) * 3600
    proto_stats = {}; total_up = 0; total_down = 0
    for cid, data in connections_data.items():
        proto = data['protocol']
        if proto not in proto_stats: proto_stats[proto] = {'up': 0, 'down': 0}
        proto_stats[proto]['up'] += data['upload_delta']
        proto_stats[proto]['down'] += data['download_delta']
        total_up += data['upload_delta']; total_down += data['download_delta']
    exists = conn.execute("SELECT id FROM node_traffic WHERE node_id=?", (node_id,)).fetchone()
    if exists:
        conn.execute("UPDATE node_traffic SET bytes_up=bytes_up+?,bytes_down=bytes_down+?,updated_at=? WHERE node_id=?",
            (total_up, total_down, now, node_id))
    else:
        conn.execute("INSERT INTO node_traffic (node_id,bytes_up,bytes_down,updated_at) VALUES (?,?,?,?)",
            (node_id, total_up, total_down, now))
    for proto, stats in proto_stats.items():
        ex = conn.execute("SELECT id FROM traffic_hourly WHERE hour=? AND protocol=? AND node_id=?",
            (hour, proto, node_id)).fetchone()
        if ex:
            conn.execute("UPDATE traffic_hourly SET bytes_up=bytes_up+?,bytes_down=bytes_down+? WHERE hour=? AND protocol=? AND node_id=?",
                (stats['up'], stats['down'], hour, proto, node_id))
        else:
            conn.execute("INSERT INTO traffic_hourly (hour,protocol,node_id,bytes_up,bytes_down) VALUES (?,?,?,?,?)",
                (hour, proto, node_id, stats['up'], stats['down']))
    total_delta = total_up + total_down
    if total_delta > 0:
        active_users = get_all_active_users()
        if active_users:
            per_user = total_delta // len(active_users)
            if per_user > 0:
                for uid in active_users:
                    conn.execute("UPDATE users SET data_used=data_used+? WHERE id=?", (per_user, uid))
    conn.commit(); conn.close()
    for proto, stats in proto_stats.items():
        total = stats['up'] + stats['down']
        if total > 0:
            print(f"📊 [{node_id}] {proto}: ↑{round(stats['up']/1024,1)}KB ↓{round(stats['down']/1024,1)}KB")
def check_limits():
    try:
        from tg_notify import user_expired, user_overlimit; tg_ok = True
    except: tg_ok = False
    s = get_settings(); notify_users = s.get('tg_notify_user','1') == '1'
    conn = get_db(); now = int(time.time())
    expired = conn.execute("SELECT id,username FROM users WHERE expire_at>0 AND expire_at<? AND status='active'", (now,)).fetchall()
    for u in expired:
        conn.execute("UPDATE users SET status='expired' WHERE id=?", (u['id'],))
        print(f"⏰ {u['username']} истёк")
        if tg_ok and notify_users:
            try: user_expired(u['username'])
            except: pass
    overlimit = conn.execute("SELECT id,username FROM users WHERE data_limit>0 AND data_used>=data_limit AND status='active'").fetchall()
    for u in overlimit:
        conn.execute("UPDATE users SET status='overlimit' WHERE id=?", (u['id'],))
        print(f"🚫 {u['username']} превысил лимит")
        if tg_ok and notify_users:
            try: user_overlimit(u['username'])
            except: pass
    if expired or overlimit:
        conn.commit()
        import subprocess; subprocess.Popen(["python3", "/opt/vpn_panel/backend/sync_users.py"])
    conn.close()
def monitor_loop():
    print("🔍 Мониторинг трафика v2 запущен (по протоколам)")
    nodes = get_nodes()
    for node_id, node in nodes.items():
        collect_node(node_id, node); print(f"✅ Нода {node_id} инициализирована")
    while True:
        try:
            nodes = get_nodes()
            for node_id, node in nodes.items():
                data = collect_node(node_id, node)
                if data: update_db(node_id, data)
            check_limits()
        except Exception as e: print(f"Monitor error: {e}")
        time.sleep(10)
if __name__ == '__main__':
    monitor_loop()
