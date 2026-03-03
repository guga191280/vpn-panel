#!/usr/bin/env python3
import os, json, sqlite3, subprocess, uuid, secrets

DB_PATH = os.path.join(os.path.dirname(__file__), "vpn_panel.db")

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def main():
    conn = get_db()
    
    # 1. Получаем все активные ноды
    nodes = conn.execute("SELECT * FROM nodes WHERE status='online'").fetchall()
    print(f"Found {len(nodes)} online nodes")

    # 2. Для каждой ноды создаём хосты если их нет
    for node in nodes:
        host = node["host"]
        name = node["name"]
        
        # Получаем порты из sing-box конфига ноды
        vless_port = 4443
        hy2_port = 20897
        
        try:
            result = subprocess.run(
                ["sshpass", "-p", node["ssh_password"],
                 "ssh", "-o", "StrictHostKeyChecking=no",
                 "-o", "ConnectTimeout=10",
                 "-p", str(node["port"] or 22),
                 f"{node['ssh_user'] or 'root'}@{host}",
                 "cat /etc/sing-box/config.json"],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0:
                cfg = json.loads(result.stdout)
                for inbound in cfg.get("inbounds", []):
                    if inbound.get("type") == "vless":
                        vless_port = inbound.get("listen_port", 4443)
                    elif inbound.get("type") == "hysteria2":
                        hy2_port = inbound.get("listen_port", 20897)
                print(f"[{name}] Got ports: VLESS={vless_port}, HY2={hy2_port}")
        except Exception as e:
            print(f"[{name}] Could not get ports: {e}, using defaults")

        # Удаляем старые прямые хосты этой ноды
        conn.execute("DELETE FROM hosts WHERE address=? AND remark NOT LIKE 'Bridge%'", (host,))
        
        # Создаём новые хосты
        conn.execute("INSERT INTO hosts (inbound_tag,remark,address,port,sni,active) VALUES (?,?,?,?,?,1)",
            ('vless-in', name+' VLESS', host, vless_port, 'www.microsoft.com'))
        conn.execute("INSERT INTO hosts (inbound_tag,remark,address,port,sni,active) VALUES (?,?,?,?,?,1)",
            ('hysteria2-in', name+' HY2', host, hy2_port, host))
        print(f"[{name}] Hosts created")

    conn.commit()

    # 3. Перегенерируем ключи всех пользователей
    users = conn.execute("SELECT * FROM users WHERE status='active'").fetchall()
    print(f"Found {len(users)} active users")
    
    for user in users:
        new_uuid = str(uuid.uuid4())
        new_sub = secrets.token_urlsafe(24)
        conn.execute("UPDATE users SET subscription_url=? WHERE id=?", 
                    (new_sub, user["id"]))
        print(f"[{user['username']}] Keys regenerated")

    conn.commit()
    conn.close()
    print("✅ All keys regenerated and hosts updated!")

if __name__ == "__main__":
    main()
