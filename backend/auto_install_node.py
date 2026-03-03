#!/usr/bin/env python3
import sys, os, time, json, sqlite3, subprocess, secrets, string, uuid

DB_PATH = os.path.join(os.path.dirname(__file__), "vpn_panel.db")

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def update_node_status(node_id, status):
    conn = get_db()
    conn.execute("UPDATE nodes SET status=? WHERE id=?", (status, node_id))
    conn.commit()
    conn.close()
    print(f"[{node_id}] Status -> {status}")

def generate_uuid():
    return str(uuid.uuid4())

def generate_reality_keys():
    result = subprocess.run(
        ["/usr/local/bin/sing-box", "generate", "reality-keypair"],
        capture_output=True, text=True
    )
    private_key = ""
    for line in result.stdout.splitlines():
        if "PrivateKey" in line:
            private_key = line.split(":")[1].strip()
    return private_key

def random_short_id():
    return secrets.token_hex(8)

def run_ssh(host, port, user, password, command):
    cmd = [
        "sshpass", "-p", password,
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=30",
        "-p", str(port),
        f"{user}@{host}",
        command
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return result.returncode, result.stdout, result.stderr

def main():
    if len(sys.argv) < 6:
        print("Usage: auto_install_node.py <node_id> <host> <ssh_port> <ssh_user> <ssh_password> <node_name> <country>")
        sys.exit(1)

    node_id      = sys.argv[1]
    host         = sys.argv[2]
    ssh_port     = int(sys.argv[3])
    ssh_user     = sys.argv[4]
    ssh_password = sys.argv[5]
    node_name    = sys.argv[6] if len(sys.argv) > 6 else "Node"
    country      = sys.argv[7] if len(sys.argv) > 7 else "Unknown"

    print(f"[{node_id}] Starting auto-install on {host}...")
    update_node_status(node_id, "installing")

    # 1. Проверяем SSH соединение
    code, out, err = run_ssh(host, ssh_port, ssh_user, ssh_password, "echo OK")
    if code != 0:
        print(f"[{node_id}] SSH failed: {err}")
        update_node_status(node_id, "offline")
        return

    print(f"[{node_id}] SSH OK")

    # 2. Устанавливаем sing-box
    install_cmd = """apt-get update -qq && apt-get install -y -qq curl wget unzip && \
if ! command -v sing-box &> /dev/null; then \
ARCH=$(uname -m); if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi; \
VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/v//'); \
wget -q "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz" -O /tmp/sing-box.tar.gz; \
tar -xzf /tmp/sing-box.tar.gz -C /tmp/; \
mv /tmp/sing-box-*/sing-box /usr/local/bin/sing-box; \
chmod +x /usr/local/bin/sing-box; fi"""

    print(f"[{node_id}] Installing sing-box...")
    code, out, err = run_ssh(host, ssh_port, ssh_user, ssh_password, install_cmd)
    if code != 0:
        print(f"[{node_id}] Install failed: {err}")
        update_node_status(node_id, "offline")
        return

    # 3. Генерируем ключи
    user_uuid = generate_uuid()
    private_key = generate_reality_keys()
    short_id = random_short_id()
    vless_port = 4443
    hy2_port = 20000 + secrets.randbelow(1000)

    # 4. SSL сертификат
    ssl_cmd = f"""mkdir -p /etc/sing-box && \
if [ ! -f /etc/sing-box/cert.pem ]; then \
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
-keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem \
-days 3650 -subj "/CN={host}"; fi"""
    run_ssh(host, ssh_port, ssh_user, ssh_password, ssl_cmd)

    # 5. Создаём конфиг
    config = {
        "log": {"level": "info"},
        "inbounds": [
            {
                "type": "vless",
                "tag": "vless-in",
                "listen": "::",
                "listen_port": vless_port,
                "users": [{"uuid": user_uuid, "flow": "xtls-rprx-vision"}],
                "tls": {
                    "enabled": True,
                    "server_name": "www.microsoft.com",
                    "reality": {
                        "enabled": True,
                        "handshake": {"server": "www.microsoft.com", "server_port": 443},
                        "private_key": private_key,
                        "short_id": [short_id]
                    }
                }
            },
            {
                "type": "hysteria2",
                "tag": "hysteria2-in",
                "listen": "::",
                "listen_port": hy2_port,
                "users": [{"password": user_uuid}],
                "tls": {
                    "enabled": True,
                    "certificate_path": "/etc/sing-box/cert.pem",
                    "key_path": "/etc/sing-box/key.pem"
                }
            }
        ],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"rules": [], "final": "direct"}
    }
    config_str = json.dumps(config, indent=2)
    config_cmd = "mkdir -p /etc/sing-box && cat > /etc/sing-box/config.json << ENDCFG\n" + config_str + "\nENDCFG"
    run_ssh(host, ssh_port, ssh_user, ssh_password, config_cmd)

    # 6. Запускаем sing-box сервис
    service_cmd = """cat > /etc/systemd/system/sing-box.service << 'ENDSVC'
[Unit]
Description=sing-box
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
ENDSVC
systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box"""
    code, out, err = run_ssh(host, ssh_port, ssh_user, ssh_password, service_cmd)
    print(f"[{node_id}] sing-box service: {out}")

    # 7. Устанавливаем панель на ноду
    panel_cmd = """apt-get install -y -qq python3 python3-venv git && \
if [ ! -d /opt/vpn_panel ]; then git clone https://github.com/guga191280/vpn-panel.git /opt/vpn_panel; fi && \
cd /opt/vpn_panel && python3 -m venv venv && \
/opt/vpn_panel/venv/bin/pip install -q fastapi uvicorn aiohttp psutil requests && \
cat > /etc/systemd/system/vpn-panel.service << 'ENDSVC'
[Unit]
Description=VPN Panel
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/vpn_panel/backend
ExecStart=/opt/vpn_panel/venv/bin/python3 main.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
ENDSVC
systemctl daemon-reload && systemctl enable vpn-panel && systemctl restart vpn-panel"""
    print(f"[{node_id}] Installing panel...")
    run_ssh(host, ssh_port, ssh_user, ssh_password, panel_cmd)

    # 8. Обновляем статус ноды
    conn = get_db()
    conn.execute("UPDATE nodes SET status='online', api_port=8080 WHERE id=?", (node_id,))
    conn.commit()
    conn.close()

    print(f"[{node_id}] Installation complete!")
    print(f"[{node_id}] UUID: {user_uuid}")
    print(f"[{node_id}] VLESS port: {vless_port}")
    print(f"[{node_id}] HY2 port: {hy2_port}")

if __name__ == "__main__":
    main()
