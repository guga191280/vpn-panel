import json
import sqlite3, json, os, requests

DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'

NODES = {
    'main': {'host': '127.0.0.1', 'port': 9090, 'secret': 'vpnpanel2024'},
    'ru75': {'host': 'ru75.alexanderoff.store', 'port': 9090, 'secret': 'vpnpanel2024'},
}

def get_sing_box_config(node_id):
    node = NODES[node_id]
    try:
        # Читаем конфиг напрямую для main ноды
        if node_id == 'main':
            with open('/etc/sing-box/config.json') as f:
                return json.load(f)
    except:
        pass
    return None

def sync_main_node(users):
    try:
        with open('/etc/sing-box/config.json') as f:
            config = json.load(f)
        
        vless_users = [{"uuid": u[0], "flow": "xtls-rprx-vision"} for u in users]
        hy2_users = [{"password": u[0]} for u in users]
        
        for inbound in config['inbounds']:
            if inbound['tag'] == 'vless-in':
                inbound['users'] = vless_users
            elif inbound['tag'] == 'hysteria2-in':
                inbound['users'] = hy2_users
        
        with open('/etc/sing-box/config.json', 'w') as f:
            json.dump(config, f, indent=2)
        
        os.system('systemctl reload sing-box 2>/dev/null || systemctl restart sing-box')
        print(f'✅ Main нода: {len(users)} пользователей')
    except Exception as e:
        print(f'❌ Main нода ошибка: {e}')

def sync_remote_node(node_id, users, node_cfg):
    try:
        import sys; sys.path.insert(0, '/opt/vpn_panel/venv/lib/python3.12/site-packages'); import paramiko
        # SSH синхронизация для удалённых нод
        # TODO: добавить SSH ключи
        print(f'⚠️ Remote sync {node_id}: требует SSH настройку')
    except:
        print(f'⚠️ {node_id}: paramiko не установлен, пропускаем')

def sync_fin_node(users):
    try:
        import requests as _req
        # Читаем конфиг финского сервера через SSH и обновляем
        fin_config_url = 'http://fin243.alexanderoff.store:9090'
        # Проверяем доступность
        r = _req.get(fin_config_url+'/version', timeout=3)
        if r.status_code != 200:
            print('⚠️ Finland нода недоступна')
            return
        # Получаем текущий конфиг финского сервера через SSH
        import sys; sys.path.insert(0, '/opt/vpn_panel/venv/lib/python3.12/site-packages'); import paramiko
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        conn2 = sqlite3.connect(DB_PATH)
        node = conn2.execute("SELECT host,port FROM nodes WHERE id='fin'").fetchone()
        conn2.close()
        if not node: return
        # Пароль финского сервера хранится в настройках
        cfg2 = conn2b = sqlite3.connect(DB_PATH)
        fin_pass = conn2b.execute("SELECT value FROM settings WHERE key='fin_ssh_pass'").fetchone()
        conn2b.close()
        fin_pass = fin_pass[0] if fin_pass else 'changeme'
        ssh.connect(node[0], port=node[1] or 22, username='root', password=fin_pass, timeout=5)
        stdin, stdout, stderr = ssh.exec_command('cat /etc/sing-box/config.json')
        cfg = json.loads(stdout.read())
        user_list = [{"uuid": u[0], "flow": "xtls-rprx-vision"} for u in users]
        for inb in cfg.get('inbounds', []):
            if inb.get('type') in ('vless', 'hysteria2'):
                if inb['type'] == 'vless':
                    inb['users'] = user_list
                else:
                    inb['users'] = [{"password": u[0]} for u in users]
        new_cfg = json.dumps(cfg, indent=2)
        # Записываем через sftp
        sftp = ssh.open_sftp()
        with sftp.open('/etc/sing-box/config.json', 'w') as f:
            f.write(new_cfg)
        sftp.close()
        ssh.exec_command('systemctl restart sing-box')
        ssh.close()
        print(f'✅ Finland нода: {len(users)} пользователей')
    except Exception as e:
        print(f'⚠️ Finland sync error: {e}')

def sync():
    conn = sqlite3.connect(DB_PATH)
    users = conn.execute("SELECT id, username FROM users WHERE status='active'").fetchall()
    conn.close()
    
    sync_main_node(users)
    sync_fin_node(users)
    print(f'✅ Синхронизировано {len(users)} пользователей')

if __name__ == '__main__':
    sync()
