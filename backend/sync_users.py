import json, sqlite3, os, sys
sys.path.insert(0, '/opt/vpn_panel/venv/lib/python3.12/site-packages')
import paramiko

DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def sync_main_node(uuids):
    try:
        with open('/etc/sing-box/config.json') as f:
            config = json.load(f)
        for inbound in config['inbounds']:
            if inbound.get('type') == 'vless':
                inbound['users'] = [{"uuid": u, "flow": "xtls-rprx-vision"} for u in uuids]
            elif inbound.get('type') == 'hysteria2':
                inbound['users'] = [{"password": u} for u in uuids]
        with open('/etc/sing-box/config.json', 'w') as f:
            json.dump(config, f, indent=2)
        os.system('systemctl restart sing-box')
        print(f'✅ Main: {len(uuids)} пользователей')
    except Exception as e:
        print(f'❌ Main ошибка: {e}')

def sync_remote_node(node):
    host     = node['host']
    ssh_port = node['port'] or 22
    ssh_user = node['ssh_user'] or 'root'
    ssh_pass = node['ssh_password'] or ''
    name     = node['name']
    if not ssh_pass:
        print(f'⚠️ {name}: нет SSH пароля, пропускаем')
        return
    try:
        conn = get_db()
        uuids = [u['id'] for u in conn.execute("SELECT id FROM users WHERE status='active'").fetchall()]
        conn.close()
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(host, port=ssh_port, username=ssh_user, password=ssh_pass, timeout=15)
        stdin, stdout, stderr = ssh.exec_command('cat /etc/sing-box/config.json')
        cfg = json.loads(stdout.read())
        for inb in cfg.get('inbounds', []):
            if inb.get('type') == 'vless':
                inb['users'] = [{"uuid": u, "flow": "xtls-rprx-vision"} for u in uuids]
            elif inb.get('type') == 'hysteria2':
                inb['users'] = [{"password": u} for u in uuids]
        sftp = ssh.open_sftp()
        with sftp.open('/etc/sing-box/config.json', 'w') as f:
            f.write(json.dumps(cfg, indent=2))
        sftp.close()
        ssh.exec_command('systemctl restart sing-box')
        ssh.close()
        print(f'✅ {name}: {len(uuids)} пользователей')
    except Exception as e:
        print(f'❌ {name} ошибка: {e}')

def sync():
    conn = get_db()
    uuids = [u['id'] for u in conn.execute("SELECT id FROM users WHERE status='active'").fetchall()]
    nodes = [dict(n) for n in conn.execute("SELECT * FROM nodes WHERE id != 'main'").fetchall()]
    conn.close()
    print(f'Синхронизация {len(uuids)} пользователей на {len(nodes)+1} нод...')
    sync_main_node(uuids)
    for node in nodes:
        sync_remote_node(node)
    print(f'✅ Готово!')

if __name__ == '__main__':
    sync()
