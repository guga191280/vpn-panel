#!/usr/bin/env python3
import sys, os, json, sqlite3, subprocess, secrets

DB_PATH = os.path.join(os.path.dirname(__file__), "vpn_panel.db")

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

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
    if len(sys.argv) < 9:
        print("Usage: auto_bridge.py <node_id> <ru_ip> <ssh_port> <ssh_user> <ssh_pass> <foreign_ip> <foreign_ssh_port> <foreign_ssh_user> <foreign_ssh_pass>")
        sys.exit(1)

    node_id          = sys.argv[1]
    ru_ip            = sys.argv[2]
    ssh_port         = int(sys.argv[3])
    ssh_user         = sys.argv[4]
    ssh_password     = sys.argv[5]
    foreign_ip       = sys.argv[6]
    foreign_ssh_port = int(sys.argv[7])
    foreign_ssh_user = sys.argv[8]
    foreign_ssh_pass = sys.argv[9] if len(sys.argv) > 9 else ssh_password

    print(f"[bridge] Starting bridge setup: {ru_ip} -> {foreign_ip}")

    # 1. Проверяем SSH на русский сервер
    code, out, err = run_ssh(ru_ip, ssh_port, ssh_user, ssh_password, "echo OK")
    if code != 0:
        print(f"[bridge] SSH to RU failed: {err}")
        return

    print(f"[bridge] SSH to RU OK")

    # 2. Проверяем SSH на иностранный сервер
    code, out, err = run_ssh(foreign_ip, foreign_ssh_port, foreign_ssh_user, foreign_ssh_pass, "echo OK")
    if code != 0:
        print(f"[bridge] SSH to foreign failed: {err}")
        return

    print(f"[bridge] SSH to foreign OK")

    # 3. Получаем порты sing-box с иностранного сервера
    code, out, err = run_ssh(foreign_ip, foreign_ssh_port, foreign_ssh_user, foreign_ssh_pass,
        "cat /etc/sing-box/config.json")
    
    vless_port = 4443
    hy2_port = 20897
    
    if code == 0 and out:
        try:
            cfg = json.loads(out)
            for inbound in cfg.get("inbounds", []):
                if inbound.get("type") == "vless":
                    vless_port = inbound.get("listen_port", 4443)
                elif inbound.get("type") == "hysteria2":
                    hy2_port = inbound.get("listen_port", 20897)
            print(f"[bridge] Got ports: VLESS={vless_port}, HY2={hy2_port}")
        except:
            print(f"[bridge] Could not parse config, using defaults")

    # 4. Настраиваем iptables на русском сервере для проброса трафика
    iptables_cmd = f"""
# Включаем форвардинг
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

# Очищаем старые правила для этого foreign_ip
iptables -t nat -D PREROUTING -p tcp --dport {vless_port} -j DNAT --to-destination {foreign_ip}:{vless_port} 2>/dev/null
iptables -t nat -D PREROUTING -p udp --dport {hy2_port} -j DNAT --to-destination {foreign_ip}:{hy2_port} 2>/dev/null

# Добавляем новые правила
iptables -t nat -A PREROUTING -p tcp --dport {vless_port} -j DNAT --to-destination {foreign_ip}:{vless_port}
iptables -t nat -A PREROUTING -p udp --dport {hy2_port} -j DNAT --to-destination {foreign_ip}:{hy2_port}
iptables -t nat -A POSTROUTING -j MASQUERADE

# Сохраняем правила
apt-get install -y -qq iptables-persistent && netfilter-persistent save
echo "iptables OK"
"""
    print(f"[bridge] Setting up iptables on RU server...")
    code, out, err = run_ssh(ru_ip, ssh_port, ssh_user, ssh_password, iptables_cmd)
    print(f"[bridge] iptables: {out[-200:] if out else err[-200:]}")

    # 5. Добавляем хосты в БД
    conn = get_db()
    # Удаляем старые хосты для этого моста
    # Не удаляем старые мосты — только добавляем новый (проверяем дубли)
    # Добавляем новые с правильными портами
    conn.execute("INSERT OR IGNORE INTO hosts (inbound_tag,remark,address,port,sni,active) VALUES (?,?,?,?,?,1)",
        ('vless-in', f'Bridge VLESS ({foreign_ip})', ru_ip, vless_port, 'www.microsoft.com'))
    conn.execute("INSERT OR IGNORE INTO hosts (inbound_tag,remark,address,port,sni,active) VALUES (?,?,?,?,?,1)",
        ('hysteria2-in', f'Bridge HY2 ({foreign_ip})', ru_ip, hy2_port, ru_ip))
    conn.commit()
    conn.close()

    print(f"[bridge] ✅ Bridge setup complete!")
    print(f"[bridge] Traffic: {ru_ip}:{vless_port} -> {foreign_ip}:{vless_port}")
    print(f"[bridge] Traffic: {ru_ip}:{hy2_port} -> {foreign_ip}:{hy2_port}")

if __name__ == "__main__":
    main()
