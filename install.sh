#!/bin/bash
# VPN Panel Installer - Clean Version
set -e

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}[✓]${NC} $1"; }
info(){ echo -e "  ${CYAN}[i]${NC} $1"; }
warn(){ echo -e "  ${YELLOW}[!]${NC} $1"; }
header() { echo ""; echo "══════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════"; }

header "VPN Panel Installer"
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
read -p "  Домен сервера: " SERVER_DOMAIN
info "IP сервера: $SERVER_IP"
read -p "  Порт панели [8444]: " PANEL_PORT; PANEL_PORT=${PANEL_PORT:-8444}
read -p "  Пароль admin [admin123]: " ADMIN_PASS; ADMIN_PASS=${ADMIN_PASS:-admin123}
read -p "  Установить Sing-box? [Y/n]: " INSTALL_SINGBOX; INSTALL_SINGBOX=${INSTALL_SINGBOX:-Y}
echo ""; info "Домен: $SERVER_DOMAIN"; info "IP: $SERVER_IP"; info "Порт: $PANEL_PORT"
read -p "  Продолжить? [Y/n]: " CONFIRM; CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" != "Y" && "$CONFIRM" != "y" ]] && exit 0

header "1. ЗАВИСИМОСТИ"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv nginx curl wget git certbot python3-certbot-nginx sshpass uuid-runtime openssl >/dev/null 2>&1
ok "Зависимости установлены"

header "2. УСТАНОВКА ПАНЕЛИ"
PANEL_DIR="/opt/vpn_panel"
if [ -d "$PANEL_DIR" ]; then
    warn "Директория уже существует"
    read -p "  Обновить? [Y/n]: " UPD; UPD=${UPD:-Y}
    [[ "$UPD" == "Y" || "$UPD" == "y" ]] && cd $PANEL_DIR && git pull origin main >/dev/null 2>&1 && ok "Обновлено"
else
    git clone https://github.com/guga191280/vpn-panel.git $PANEL_DIR >/dev/null 2>&1
    ok "Репозиторий клонирован"
fi

header "3. PYTHON"
cd $PANEL_DIR
python3 -m venv venv >/dev/null 2>&1
venv/bin/pip install --upgrade pip -q
venv/bin/pip install fastapi uvicorn requests aiofiles python-multipart -q
ok "Python готов"

header "4. SING-BOX"
if [[ "$INSTALL_SINGBOX" == "Y" || "$INSTALL_SINGBOX" == "y" ]]; then
    LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d'"' -f4 | tr -d 'v')
    info "Версия: $LATEST"
    curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-amd64.tar.gz" -o /tmp/sing-box.tar.gz
    tar -xzf /tmp/sing-box.tar.gz -C /tmp
    systemctl stop sing-box 2>/dev/null || true
    cp /tmp/sing-box-${LATEST}-linux-amd64/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box
    ok "Sing-box установлен"

    VLESS_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null)
    PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)

    mkdir -p /etc/sing-box
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem \
        -subj "/CN=$SERVER_DOMAIN" -days 3650 >/dev/null 2>&1

    python3 -c "
import json
cfg = {
  'log': {'level': 'info'},
  'inbounds': [
    {'type':'vless','tag':'vless-in','listen':'::','listen_port':4443,
     'users':[{'uuid':'${VLESS_UUID}','flow':'xtls-rprx-vision'}],
     'tls':{'enabled':True,'server_name':'www.microsoft.com',
            'reality':{'enabled':True,'handshake':{'server':'www.microsoft.com','server_port':443},
                       'private_key':'${PRIVATE_KEY}','short_id':['${SHORT_ID}']}}},
    {'type':'hysteria2','tag':'hysteria2-in','listen':'::','listen_port':20897,
     'users':[{'password':'${VLESS_UUID}'}],
     'tls':{'enabled':True,'certificate_path':'/etc/sing-box/cert.pem','key_path':'/etc/sing-box/key.pem'}}
  ],
  'outbounds':[{'type':'direct','tag':'direct'}],
  'route':{'rules':[],'final':'direct'},
  'experimental':{'clash_api':{'external_controller':'127.0.0.1:9090','secret':''}}
}
json.dump(cfg, open('/etc/sing-box/config.json','w'), indent=2)
print('OK')
"
    ok "Конфиг sing-box создан"

    cat > /etc/systemd/system/sing-box.service << 'EOF'
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
EOF
    systemctl daemon-reload && systemctl enable sing-box >/dev/null 2>&1 && systemctl restart sing-box
    ok "Sing-box запущен"
fi

header "5. БАЗА ДАННЫХ"
ADMIN_TOKEN=$(openssl rand -hex 32)
ADMIN_PASS_HASH=$(echo -n "$ADMIN_PASS" | sha256sum | cut -d' ' -f1)
SERVER_DOMAIN=$SERVER_DOMAIN SERVER_IP=$SERVER_IP VLESS_UUID=$VLESS_UUID ADMIN_TOKEN=$ADMIN_TOKEN ADMIN_PASS_HASH=$ADMIN_PASS_HASH PUBLIC_KEY=$PUBLIC_KEY SHORT_ID=$SHORT_ID \
python3 << 'PYEOF'
import sqlite3, time, os
db='/opt/vpn_panel/backend/vpn_panel.db'; conn=sqlite3.connect(db)
conn.executescript("""
CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, username TEXT UNIQUE, telegram_id TEXT, status TEXT DEFAULT 'active', data_limit INTEGER DEFAULT 0, data_used INTEGER DEFAULT 0, expire_at INTEGER DEFAULT 0, created_at INTEGER DEFAULT 0, subscription_url TEXT DEFAULT '', hysteria2_url TEXT DEFAULT '', vless_ru75 TEXT DEFAULT '', hy2_ru75 TEXT DEFAULT '', vless_main_bridge TEXT DEFAULT '', hy2_main_bridge TEXT DEFAULT '', node_ids TEXT DEFAULT '["main"]', note TEXT DEFAULT '', sub_token TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, name TEXT, host TEXT, country TEXT, status TEXT DEFAULT 'online', created_at INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS node_traffic (id INTEGER PRIMARY KEY AUTOINCREMENT, node_id TEXT, bytes_up INTEGER DEFAULT 0, bytes_down INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS traffic_hourly (id INTEGER PRIMARY KEY AUTOINCREMENT, hour INTEGER, protocol TEXT, node_id TEXT, bytes_up INTEGER DEFAULT 0, bytes_down INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS connection_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT, username TEXT, protocol TEXT, node_id TEXT, bytes_up INTEGER DEFAULT 0, bytes_down INTEGER DEFAULT 0, timestamp INTEGER, country TEXT DEFAULT '', city TEXT DEFAULT '', ip TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS admins (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password_hash TEXT, token TEXT, role TEXT DEFAULT 'admin', created_at INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, admin TEXT, action TEXT, details TEXT DEFAULT '', created_at INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS bridges (id TEXT PRIMARY KEY, name TEXT, host TEXT, port INTEGER, node_id TEXT, status TEXT DEFAULT 'active');
CREATE TABLE IF NOT EXISTS hosts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, address TEXT, port INTEGER, inbound_tag TEXT, sni TEXT DEFAULT '', status TEXT DEFAULT 'active');
CREATE TABLE IF NOT EXISTS subadmins (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password_hash TEXT, token TEXT, created_at INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS bots (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, token TEXT, status TEXT DEFAULT 'active');
CREATE TABLE IF NOT EXISTS templates (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, expire_days INTEGER DEFAULT 30, data_limit_gb REAL DEFAULT 0, note TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS inbounds (tag TEXT PRIMARY KEY, type TEXT, port INTEGER, listen TEXT DEFAULT '::', raw TEXT DEFAULT '{}');
""")
now=int(time.time())
d=os.environ.get('SERVER_DOMAIN','localhost'); ip=os.environ.get('SERVER_IP','127.0.0.1')
uuid=os.environ.get('VLESS_UUID',''); token=os.environ.get('ADMIN_TOKEN',''); ph=os.environ.get('ADMIN_PASS_HASH','')
conn.execute("INSERT OR IGNORE INTO admins (username,password_hash,token,created_at) VALUES (?,?,?,?)",('admin',ph,token,now))
conn.execute("INSERT OR REPLACE INTO nodes (id,name,host,port,api_port,api_token,country,protocols,status,traffic_used,created_at,ssh_user,ssh_password,public_key,short_id,panel_port,ssh_pass,uuid) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    ('main','Russia',ip,22,8000,'','Russia','[\"vless\",\"hysteria2\"]','online',0,now,'root','',os.environ.get('PUBLIC_KEY',''),os.environ.get('SHORT_ID',''),8080,'',os.environ.get('VLESS_UUID','')))
for k,v in [('panel_domain',d),('panel_port','8444'),('server_ip',ip),('vless_uuid',uuid),('tg_bot_token',''),('tg_admin_id',''),('tg_notify_user','1')]:
    conn.execute("INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)",(k,v))
conn.commit(); conn.close(); print("БД инициализирована")
PYEOF
ok "База данных готова"

# Добавляем hosts автоматически
SERVER_IP=$SERVER_IP python3 << 'HOSTSEOF'
import sqlite3, os
ip = os.environ.get('SERVER_IP', '127.0.0.1')
conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')
cols = [r[1] for r in conn.execute("PRAGMA table_info(hosts)").fetchall()]
if 'remark' not in cols:
    conn.execute("ALTER TABLE hosts ADD COLUMN remark TEXT DEFAULT ''")
conn.execute("DELETE FROM hosts")
conn.execute("INSERT INTO hosts (inbound_tag,name,remark,address,port,sni,status) VALUES (?,?,?,?,?,?,?)",
    ('vless-in','de VLESS','de VLESS',ip,4443,'www.microsoft.com',1))
conn.execute("INSERT INTO hosts (inbound_tag,name,remark,address,port,sni,status) VALUES (?,?,?,?,?,?,?)",
    ('hysteria2-in','de HY2','de HY2',ip,20897,ip,1))
conn.commit(); conn.close()
print("Hosts добавлены")
HOSTSEOF

python3 $PANEL_DIR/backend/sync_users.py >/dev/null 2>&1 || true
ok "Нода настроена"

header "6. SYSTEMD"
cat > /etc/systemd/system/vpn-panel.service << 'EOF'
[Unit]
Description=VPN Panel
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/vpn_panel/backend
ExecStart=/opt/vpn_panel/venv/bin/python3 main.py
Restart=always
RestartSec=5
StandardOutput=append:/opt/vpn_panel/panel.log
StandardError=append:/opt/vpn_panel/panel.log
[Install]
WantedBy=multi-user.target
EOF
touch /opt/vpn_panel/panel.log /opt/vpn_panel/autodiag.log
chmod +x /opt/vpn_panel/autodiag.sh 2>/dev/null || true
systemctl daemon-reload && systemctl enable vpn-panel >/dev/null 2>&1 && systemctl restart vpn-panel
ok "vpn-panel запущен"

cat > /etc/systemd/system/vpn-autodiag.service << 'EOF'
[Unit]
Description=VPN Panel Auto Diagnostics
[Service]
Type=oneshot
ExecStart=/opt/vpn_panel/autodiag.sh
EOF
cat > /etc/systemd/system/vpn-autodiag.timer << 'EOF'
[Unit]
Description=VPN Panel Auto Diagnostics Timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload && systemctl enable vpn-autodiag.timer >/dev/null 2>&1 && systemctl start vpn-autodiag.timer
ok "Autodiag запущен"

header "7. SSL"
read -p "  Получить SSL Let's Encrypt? [Y/n]: " GET_SSL; GET_SSL=${GET_SSL:-Y}
if [[ "$GET_SSL" == "Y" || "$GET_SSL" == "y" ]]; then
    read -p "  Email: " SSL_EMAIL
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d $SERVER_DOMAIN --email $SSL_EMAIL --agree-tos --non-interactive >/dev/null 2>&1
    SSL_CERT="/etc/letsencrypt/live/$SERVER_DOMAIN/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/$SERVER_DOMAIN/privkey.pem"
    ok "SSL получен"
else
    SSL_CERT="/etc/sing-box/cert.pem"; SSL_KEY="/etc/sing-box/key.pem"
    warn "Используется self-signed"
fi

header "8. NGINX"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
cat > /etc/nginx/sites-enabled/vpnpanel << EOF
server {
    listen 80;
    server_name $SERVER_DOMAIN;
    return 301 https://\$host:$PANEL_PORT\$request_uri;
}
server {
    listen $PANEL_PORT ssl;
    server_name $SERVER_DOMAIN;
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    keepalive_timeout 65;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300;
        proxy_connect_timeout 10;
        proxy_send_timeout 30;
    }
    location /sub/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 30;
        proxy_connect_timeout 5;
        add_header Cache-Control "no-cache";
    }
}
EOF
nginx -t >/dev/null 2>&1 && systemctl restart nginx
ok "Nginx настроен"

header "9. FIREWALL"
ufw allow 22/tcp >/dev/null 2>&1; ufw allow 80/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1; ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
ufw allow 4443/tcp >/dev/null 2>&1; ufw allow 20897/udp >/dev/null 2>&1
echo "y" | ufw enable >/dev/null 2>&1
ok "Firewall настроен"

header "✅ УСТАНОВКА ЗАВЕРШЕНА"
echo ""
echo -e "  ${GREEN}Panel:${NC}  https://${SERVER_DOMAIN}:${PANEL_PORT}"
echo -e "  ${GREEN}Or:${NC}     https://${SERVER_IP}:${PANEL_PORT}"
echo -e "  ${GREEN}Login:${NC}  admin"
echo -e "  ${GREEN}Pass:${NC}   ${ADMIN_PASS}"
echo ""
if [[ "$INSTALL_SINGBOX" == "Y" || "$INSTALL_SINGBOX" == "y" ]]; then
    echo -e "  ${YELLOW}Sing-box:${NC}"
    echo -e "    VLESS port:     4443"
    echo -e "    Hysteria2 port: 20897"
    echo -e "    Public Key:     ${PUBLIC_KEY}"
    echo -e "    Short ID:       ${SHORT_ID}"
    echo -e "    UUID:           ${VLESS_UUID}"
fi
echo ""
ok "Готово! Открой панель в браузере."
