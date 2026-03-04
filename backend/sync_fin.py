import sqlite3, json, sys
sys.path.insert(0, '/opt/vpn_panel/venv/lib/python3.12/site-packages')

DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'

def sync_fin():
    try:
        import paramiko
    except ImportError:
        print("❌ paramiko не установлен")
        return

    conn = sqlite3.connect(DB_PATH)
    users = conn.execute("SELECT id FROM users WHERE status='active'").fetchall()
    node = conn.execute("SELECT host,port FROM nodes WHERE id='dfb6cf92'").fetchone()
    fin_pass = conn.execute("SELECT value FROM settings WHERE key='fin_ssh_pass'").fetchone()
    conn.close()

    if not node:
        print("❌ Финская нода не найдена в БД")
        return

    fin_pass = fin_pass[0] if fin_pass else 'alexander77'
    host, port = node[0], node[1] or 22

    print(f"Подключаемся к {host}:{port}...")

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(host, port=port, username='root', password=fin_pass, timeout=10)
    print("✅ SSH подключён")

    # Читаем конфиг
    stdin, stdout, stderr = ssh.exec_command('cat /etc/sing-box/config.json')
    cfg = json.loads(stdout.read())

    # Обновляем пользователей
    vless_users = [{"uuid": u[0], "flow": "xtls-rprx-vision"} for u in users]
    hy2_users = [{"password": u[0]} for u in users]

    for inb in cfg.get('inbounds', []):
        if inb.get('type') == 'vless':
            inb['users'] = vless_users
            print(f"  vless users: {len(vless_users)}")
        elif inb.get('type') == 'hysteria2':
            inb['users'] = hy2_users
            print(f"  hy2 users: {len(hy2_users)}")

    # Записываем
    new_cfg = json.dumps(cfg, indent=2)
    sftp = ssh.open_sftp()
    with sftp.open('/etc/sing-box/config.json', 'w') as f:
        f.write(new_cfg)
    sftp.close()
    print("✅ Конфиг записан")

    # Перезапускаем
    ssh.exec_command('systemctl restart sing-box')
    ssh.close()
    print(f"✅ Finland нода синхронизирована: {len(users)} пользователей")

sync_fin()
