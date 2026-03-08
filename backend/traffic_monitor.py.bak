import time, requests, sqlite3, paramiko, re
from pathlib import Path
from io import StringIO

DB_PATH = Path(__file__).parent / "vpn_panel.db"
_prev = {}  # node_id -> {up, down}
_ssh_clients = {}

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def get_nodes():
    conn = get_db()
    rows = conn.execute("SELECT id, host, ssh_password FROM nodes WHERE status='online'").fetchall()
    conn.close()
    return [dict(r) for r in rows]

def get_ssh(host, password):
    key = host
    try:
        if key in _ssh_clients:
            _ssh_clients[key].exec_command('echo ok')[1].read()
            return _ssh_clients[key]
    except:
        pass
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(host, username='root', password=password, timeout=10)
    _ssh_clients[key] = ssh
    return ssh

def get_user_index_map(ssh):
    """Возвращает {index: uuid} из конфига sing-box"""
    _, out, _ = ssh.exec_command('cat /etc/sing-box/config.json')
    cfg = __import__('json').loads(out.read())
    result = {}
    for inb in cfg.get('inbounds', []):
        if inb['type'] in ('vless', 'hysteria2'):
            for i, u in enumerate(inb.get('users', [])):
                uid = u.get('uuid') or u.get('password', '')
                if uid:
                    result[i] = uid
    return result

def parse_log_traffic(ssh, index_map):
    """Парсим лог: матчим conn_id -> IP -> user_index -> uuid"""
    _, out, _ = ssh.exec_command('cat /var/log/sing-box.log && truncate -s 0 /var/log/sing-box.log')
    log = out.read().decode()
    
    # conn_id -> source IP
    conn_ip = {}
    # conn_id -> user index
    conn_idx = {}
    
    for line in log.splitlines():
        # Извлекаем conn_id: INFO [1661628521 ...] 
        m_conn = re.search(r'\[(\d{6,12})\s', line)
        if not m_conn: continue
        conn_id = m_conn.group(1)
        
        # inbound connection from IP:PORT
        m_from = re.search(r'inbound connection from ([\d\.]+):\d+', line)
        if m_from:
            conn_ip[conn_id] = m_from.group(1)
        
        # [N] inbound connection to DEST
        m_idx = re.search(r'\[(\d+)\] inbound', line)
        if m_idx:
            conn_idx[conn_id] = int(m_idx.group(1))
    
    # Строим uuid -> hit count
    user_hits = {}
    for conn_id, idx in conn_idx.items():
        if idx in index_map:
            uuid = index_map[idx]
            user_hits[uuid] = user_hits.get(uuid, 0) + 1
    
    return user_hits

def collect_and_save():
    db = get_db()
    node_configs = {
        '212.15.49.151': 'PVJXSWnS6ZXUg',
        '150.241.106.238': 'alexander77',
        '150.241.88.243': 'alexander77',
    }
    
    # Получаем трафик нод через clash API
    nodes = get_db()
    node_rows = nodes.execute("SELECT id, host FROM nodes WHERE status='online'").fetchall()
    nodes.close()
    
    node_deltas = {}  # node_id -> total_delta
    for row in node_rows:
        node_id = row['host'] if row['host'] != '185.40.4.169' else '127.0.0.1'
        host = '127.0.0.1' if row['host'] == '185.40.4.169' else row['host']
        try:
            r = requests.get(f'http://{host}:9090/connections', timeout=5)
            if r.status_code != 200: continue
            data = r.json()
            total_up = data.get('uploadTotal', 0)
            total_down = data.get('downloadTotal', 0)
            prev = _prev.get(row['id'], {'up': total_up, 'down': total_down})
            up_d = max(0, total_up - prev['up'])
            dn_d = max(0, total_down - prev['down'])
            _prev[row['id']] = {'up': total_up, 'down': total_down}
            if up_d + dn_d > 0:
                node_deltas[row['id']] = {'delta': up_d + dn_d, 'host': host}
        except Exception as e:
            print(f"clash error [{row['id']}]: {e}")
    
    if not node_deltas:
        db.close()
        return
    
    # Для каждой ноды парсим лог и считаем кто качал
    for node_id, info in node_deltas.items():
        host = info['host']
        if host == '127.0.0.1': host = '185.40.4.169'
        password = node_configs.get(host, 'alexander77')
        total_delta = info['delta']
        
        try:
            ssh = get_ssh(host if host != '185.40.4.169' else '212.15.49.151', password)
            index_map = get_user_index_map(ssh)
            user_hits = parse_log_traffic(ssh, index_map)
            
            if not user_hits:
                continue
            
            total_hits = sum(user_hits.values())
            for uuid, hits in user_hits.items():
                share = int(total_delta * hits / total_hits)
                if share > 0:
                    db.execute("UPDATE users SET data_used=data_used+? WHERE id=? AND status='active'",
                               (share, uuid))
                    print(f"📊 [{node_id}] {uuid[:8]}: +{round(share/1024,1)}KB ({hits} conns)")
        except Exception as e:
            print(f"log parse error [{node_id}]: {e}")
    
    # Проверяем лимиты
    overlimit = db.execute(
        "SELECT id, username FROM users WHERE data_limit>0 AND data_used>=data_limit AND status='active'"
    ).fetchall()
    for u in overlimit:
        db.execute("UPDATE users SET status='overlimit' WHERE id=?", (u['id'],))
        print(f"🚫 {u['username']} превысил лимит")
    
    db.commit()
    db.close()

def monitor_loop():
    print("🚀 Traffic monitor started (per-user via log parsing)")
    while True:
        try:
            collect_and_save()
        except Exception as e:
            print(f"monitor error: {e}")
        time.sleep(30)
