import sqlite3, time, requests, sys
sys.path.insert(0, '/opt/vpn_panel/backend')

DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'
NODES = {
    'main':  {'host': '127.0.0.1', 'port': 9090, 'secret': 'vpnpanel2024'},
    'ru75':  {'host': 'ru75.alexanderoff.store', 'port': 9090, 'secret': 'vpnpanel2024'},
}
_prev = {}

def get_settings():
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute("SELECT key,value FROM settings").fetchall()
    conn.close()
    return {r[0]:r[1] for r in rows}

def collect_node(node_id, node):
    try:
        r = requests.get(f'http://{node["host"]}:{node["port"]}/connections',
                        headers={'Authorization': f'Bearer {node["secret"]}'}, timeout=5)
        if r.status_code != 200:
            return 0
        conns = r.json().get('connections', [])
        delta = 0
        for c in conns:
            cid = (node_id, c['id'])
            total = c.get('upload', 0) + c.get('download', 0)
            prev = _prev.get(cid, total)
            d = max(0, total - prev)
            _prev[cid] = total
            delta += d
        active = {(node_id, c['id']) for c in conns}
        for k in list(_prev.keys()):
            if k[0] == node_id and k not in active:
                del _prev[k]
        return delta
    except:
        return 0

def update_db(node_id, delta):
    if delta <= 0:
        return
    conn = sqlite3.connect(DB_PATH)
    now = int(time.time())
    exists = conn.execute("SELECT id FROM node_traffic WHERE node_id=?", (node_id,)).fetchone()
    if exists:
        conn.execute("UPDATE node_traffic SET bytes_down=bytes_down+?,updated_at=? WHERE node_id=?", (delta, now, node_id))
    else:
        conn.execute("INSERT INTO node_traffic (node_id,bytes_up,bytes_down,updated_at) VALUES (?,0,?,?)", (node_id, delta, now))
    users = conn.execute("SELECT id FROM users WHERE status='active'").fetchall()
    if users:
        per_user = delta // len(users)
        if per_user > 0:
            for u in users:
                conn.execute("UPDATE users SET data_used=data_used+? WHERE id=?", (per_user, u[0]))
    conn.commit()
    conn.close()

def check_limits():
    try:
        from tg_notify import user_expired, user_overlimit
        tg_ok = True
    except:
        tg_ok = False

    s = get_settings()
    notify_users = s.get('tg_notify_user', '1') == '1'

    conn = sqlite3.connect(DB_PATH)
    now = int(time.time())

    expired = conn.execute(
        "SELECT id,username FROM users WHERE expire_at>0 AND expire_at<? AND status='active'", (now,)
    ).fetchall()
    for u in expired:
        conn.execute("UPDATE users SET status='expired' WHERE id=?", (u[0],))
        if tg_ok and notify_users:
            try: user_expired(u[1])
            except: pass

    overlimit = conn.execute(
        "SELECT id,username FROM users WHERE data_limit>0 AND data_used>=data_limit AND status='active'"
    ).fetchall()
    for u in overlimit:
        conn.execute("UPDATE users SET status='overlimit' WHERE id=?", (u[0],))
        if tg_ok and notify_users:
            try: user_overlimit(u[1])
            except: pass

    if expired or overlimit:
        conn.commit()
        import subprocess
        subprocess.Popen(["python3", "/opt/vpn_panel/backend/sync_users.py"])
    conn.close()

def monitor_loop():
    print("🔍 Мониторинг трафика запущен")
    for node_id, node in NODES.items():
        collect_node(node_id, node)
    while True:
        try:
            for node_id, node in NODES.items():
                delta = collect_node(node_id, node)
                if delta > 0:
                    update_db(node_id, delta)
                    print(f"📊 {node_id}: +{round(delta/1024,1)} KB")
            check_limits()
        except Exception as e:
            print(f"Monitor error: {e}")
        time.sleep(10)

if __name__ == '__main__':
    monitor_loop()
