#!/bin/bash
# ================================================
#   VPN Panel - One Click Installer
#   Ubuntu 24.04
#   github.com/guga191280/vpn-panel
# ================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()     { echo -e "${GREEN}[✓]${NC} $1"; }
fail()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
info()   { echo -e "${CYAN}[i]${NC} $1"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════════${NC}"; }

# ── ПРОВЕРКА ROOT ────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    fail "Запускай от root: sudo bash install.sh"
fi

header "VPN Panel Installer"
echo ""
echo -e "  Этот скрипт установит:"
echo -e "  • VPN Panel (FastAPI + SQLite)"
echo -e "  • Sing-box (VLESS + Hysteria2)"
echo -e "  • Nginx (reverse proxy + SSL)"
echo -e "  • Python 3.12 venv"
echo ""

# ── ВВОД ПАРАМЕТРОВ ──────────────────────────────
header "ПАРАМЕТРЫ УСТАНОВКИ"

read -p "  Домен сервера (например ru75.example.com): " SERVER_DOMAIN
[ -z "$SERVER_DOMAIN" ] && fail "Домен не может быть пустым"

SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
info "IP сервера: $SERVER_IP"

read -p "  Порт панели [8444]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8444}

read -p "  Пароль admin [admin123]: " ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-admin123}

read -p "  Установить Sing-box? [Y/n]: " INSTALL_SINGBOX
INSTALL_SINGBOX=${INSTALL_SINGBOX:-Y}

echo ""
info "Домео:    $SERVER_DOMAIN"
info "IP:       $SERVER_IP"
info "Порт:     $PANEL_PORT"
info "Sing-box: $INSTALL_SINGBOX"
echo ""
read -p "  Продолжить? [Y/n]: " CONFIRM
[ "${CONFIRM:-Y}" != "Y" ] && [ "${CONFIRM}" != "y" ] && exit 0

# ── ВЗВЭД�О�ВИТЕЛЬСТВО ──────────────────────────────────
header "1. УСТАНОВКА ВАВЭДРОВИТЕЛМ ВАВЭДРОВИТЕЛМ ВАВЭДРОВИТЕЛМ ВАВЭДРОВИТЕЛМ ВАВЭДРОВИТЕЛМ"
apt-get update -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv \
    git curl wget nginx certbot \
    python3-certbot-nginx \
    sshpass ufw 2>/dev/null
ok "Зависимости установлены"

# ── КЛОНИРОВАНИЕ ──────────────────────────────────
header "2. УСТАНОВКА ВАНЕЛИ"
PANEL_DIR="/opt/vpn_panel"

if [ -d "$PANEL_DIR" ]; then
    warn "Директория $PANEL_DIR уже существует"
    read -p "  Обновить существующую установку? [Y/n]: " UPDATE
    if [ "${UPDATE:-Y}" = "Y" ] || [ "${UPDATE_IO}" = "y" ]; then
        cd $PANEL_DIR && git pull origin main
        ok "Код обновлён"
    fi
else
    git clone https://github.com/guga191280/vpn-panel.git $PANEL_DIR
    ok "Репозиторий клонирован"
fi

# ── PYTHON VENV ───────────────────────────────────
header "3. PYTHON ОКРУЖЕНИЕ"
cd $PANEL_DIR
[[ ! -d "venv" ]] && python3 -m venv venv && ok "venv создан"
 venv/bin/pip install -q --upgrade pip
venv/bin/pip install -q \
    fastapi uvicorn pydantic aiohttp aiofiles \
    paramiko requests psutil bcrypt \
    aiogram python-multipart
ok "Python пакеты установлены"

# ── SING-BOX ─────────────────────────────────────
if [ "${INSTALL_SINGBOX:-Y}" = "Y" ] || [ "${INSTALL_SINGBOX}" = "y" ]; then
    header "4. SING-BOX"
    
    # Установка последней версии
    SINGBOX_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')
    
    if [ -z "$SINGBOX_VER" ]; then
        SINGBOX_VER="1.9.0"
        warn "Не сдалось получить версию, используем $SINGBOX_VER"
    fi
    
    info "Версия sing-box: $SINGBOX_VER"
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && ARCH="amd64"
    [ "$ARCH" = "aarch64" ] && ARCH="arm64"
    
    wget -q "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${ARCH}.tar.gz" \
        -O /tmp/sing-box.tar.gz
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    cp /tmp/sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    ok "Sing-box $SINGBOX_VER установлен"
    
    # Генерация ключей Reality
    mkdir -p /etc/sing-box
    REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null)
    PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    
    info "UUID: $VLESS_UUID"
    info "Public Key: $PUBLIC_KEY"
    
    # Генерация самоподписанного сертификата для Hysteria2
    openssl req -x509 -newkey rsa:4096 -keyout /etc/sing-box/key.pem \
        -out /etc/sing-box/cert.pem -days 3650 -nodes \
        -subj "/CN=$SERVER_DOMAIN" 2>/dev/null
    ok "SSL сертификат для HY2 создан"
    
    # Конфиг sing-box
    HY2_PORT=20897
    VLESS_PORT=4443
    
    cat > /etc/sing-box/config.json << SBEOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [
        { "uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.microsoft.com", "server_port": 443 },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        { "password": "$VLESS_UUID" }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "rules": [], "final": "direct" }
}
SBEOF
    ok "Конфиг sing-box создан"
    
    # Systemd сервис
    cat > /etc/systemd/system/sing-box.service << 'SVCEOF'
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    sleep 2
    systemctl is-active sing-box &>/dev/null && ok "Sing-box запущен" || warn "Sing-box не запустился, проверь логи"
fi

# ── ИНИЦИАЛИЗАЦИЯ БД ─────────────────────────────
header "5. ИНИЦИАЛИЗАЦИЯ БАЗЫ ДАННЫХ"
ADMIN_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${ADMIN_PASS}'.encode()).hexdigest())")
ADMIN_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")

python3 << PYEOF
import sqlite3, time, json, os

DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'
os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
conn = sqlite3.connect(DB_PATH)

conn.executescript("""
CREATE TABLE IF NOT EXISTS admins (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE,
    password_hash TEXT,
    token TEXT
);
CREATE TABLE IF NOT EXISTS nodes (
    id TEXT PRIMARY KEY,
    name TEXT, host TEXT, port INTEGER DEFAULT 22,
    api_port INTEGER DEFAULT 8080, api_token TEXT,
    country TEXT, protocols TEXT DEFAULT '["vless","hysteria2"]',
    status TEXT DEFAULT 'online', traffic_used INTEGER DEFAULT 0,
    created_at INTEGER, ssh_user TEXT DEFAULT 'root',
    ssh_password TEXT, public_key TEXT, short_id TEXT
);
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY, username TEXT UNIQUE,
    telegram_id TEXT, status TEXT DEFAULT 'active',
    data_limit INTEGER DEFAULT 0, data_used INTEGER DEFAULT 0,
    expire_at INTEGER, subscription_url TEXT,
    node_ids TEXT DEFAULT '[]', created_at INTEGER,
    note TEXT DEFAULT '', hysteria2_url TEXT DEFAULT '',
    vless_ru75 TEXT DEFAULT '', hy2_ru75 TEXT DEFAULT '',
    vless_main_bridge TEXT DEFAULT '', hy2_main_bridge TEXT DEFAULT '',
    vless_ru75_bridge TEXT DEFAULT '', hy2_ru75_bridge TEXT DEFAULT '',
    sub_token TEXT DEFAULT '', reset_days INTEGER DEFAULT 0,
    data_used_at INTEGER DEFAULT 0, auto_extend INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS hosts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    inbound_tag TEXT, remark TEXT, address TEXT,
    port INTEGER, sni TEXT, host_header TEXT DEFAULT '',
    security TEXT DEFAULT 'inbound_default', active INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS bridges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id TEXT, ru_ip TEXT, foreign_ip TEXT,
    active INTEGER DEFAULT 0, created_at INTEGER
);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY, value TEXT
);
CREATE TABLE IF NOT EXISTS subadmins (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE, password_hash TEXT, token TEXT,
    can_add_users INTEGER DEFAULT 1, can_delete_users INTEGER DEFAULT 0,
    can_toggle_users INTEGER DEFAULT 1, can_view_keys INTEGER DEFAULT 1,
    can_manage_nodes INTEGER DEFAULT 0, can_manage_bridges INTEGER DEFAULT 0,
    created_at INTEGER
);
CREATE TABLE IF NOT EXISTS bots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT, token TEXT, created_at INTEGER
);
CREATE TABLE IF NOT EXISTS node_traffic (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id TEXT, bytes_up INTEGER DEFAULT 0,
    bytes_down INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    admin TEXT, action TEXT, details TEXT, created_at INTEGER
);
CREATE TABLE IF NOT EXISTS user_templates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT, expire_days INTEGER, data_limit_gb REAL, note TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS connection_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT, node_id TEXT, protocol TEXT,
    connected_at INTEGER, disconnected_at INTEGER
);
CREATE TABLE IF NOT EXISTS traffic_hourly (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hour INTEGER, protocol TEXT, node_id TEXT,
    bytes_up INTEGER DEFAULT 0, bytes_down INTEGER DEFAULT 0
);
""")

# Admin
conn.execute("INSERT OR IGNORE INTO admins (username,password_hash,token) VALUES (?,?,?)",
    ('admin', '${ADMIN_HASH}', '${ADMIN_TOKEN}'))

# Settings
settings = [
    ('panel_domain', 'https://${SERVER_IP}:${PANEL_PORT}'),
    ('server_ip', '${SERVER_IP}'),
    ('tg_admin_id', ''),
    ('tg_bot_token', ''),
    ('tg_notify_node', '1'),
    ('tg_notify_user', '1'),
    ('sub_domain', ''),
    ('auto_extend', '0'),
    ('auto_extend_days', '30'),
    ('fin_ssh_pass', ''),
]
for k, v in settings:
    conn.execute("INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)", (k, v))

# Шаблоны
templates = [
    ('Базовый 30 дней', 30, 10.0),
    ('Стандарт 30 дней', 30, 50.0),
    ('Безлимит 30 дней', 30, 0.0),
    ('Безлимит 90 дней', 90, 0.0),
]
for name, days, gb in templates:
    conn.execute("INSERT OR IGNORE INTO user_templates (name,expire_days,data_limit_gb) VALUES (?,?,?)",
        (name, days, gb))

conn.commit()
conn.close()
print("БД инициализирована")
PYEOF

ok "База данных готова"

# Добавляем главную ноду если sing-box установлен
if [ "${INSTALL_SINGBOX:-Y}" = "Y" ] || [ "${INSTALL_SINGBOX}" = "y" ]; then
    python3 << PYEOF2
import sqlite3, time, json
conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')

PUBLIC_KEY = '${PUBLIC_KEY}'
SHORT_ID = '${SHORT_ID}'
SERVER_IP = '${SERVER_IP}'
SERVER_DOMAIN = '${SERVER_DOMAIN}'

# Главная нода
conn.execute("""INSERT OR IGNORE INTO nodes 
    (id,name,host,port,api_port,country,status,created_at,ssh_user,public_key,short_id)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
    ('main', 'Main', SERVER_IP, 22, 8080, 'Russia', 'online',
     int(time.time()), 'root', PUBLIC_KEY, SHORT_ID))

# Хосты
hosts = [
    ('vless-in', 'Main VLESS', SERVER_IP, 4443, 'www.microsoft.com'),
    ('hysteria2-in', 'Main HY2', SERVER_IP, 20897, SERVER_IP),
]
for tag, remark, addr, port, sni in hosts:
    conn.execute("""INSERT OR IGNORE INTO hosts (inbound_tag,remark,address,port,sni,active)
        VALUES (?,?,?,?,?,1)""", (tag, remark, addr, port, sni))

conn.commit()
conn.close()
print("Нода добавлена в БД")
PYEOF2
    ok "Главная нода настроена"
fi

# ── SYSTEMD СЕРВИС ────────────────────────────────
header "6. SYSTEMD СЕРВИС"
cat > /etc/systemd/system/vpn-panel.service << EOF
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

systemctl daemon-reload
systemctl enable vpn-panel
systemctl restart vpn-panel
sleep 3
systemctl is-active vpn-panel &>/dev/null && ok "vpn-panel запущен" || warn "vpn-panel не запустился"

# ── SSL СЕРТИРШЕНИЕО ───────────────────────────────
header "7. SSL СЕРТИФИКАТ"
read -p "  Получить SSL сертификат Let's Encrypt? [Y/n]: " GET_SSL
if [ "${GET_SSL:-Y}" = "Y" ] || [ "${GET_SSL}" = "y" ]; then
    read -p "  Email для сертификата: " SSL_EMAIL
    certbot --nginx -d "$SERVER_DOMAIN" --non-interactive \
        --agree-tos -m "${SSL_EMAIL:-admin@example.com}" 2>/dev/null && \
        ok "SSL сертификат получен" || warn "Не удалось получить сертификати, настрой вручную"
fi

# ── NGINX ─────────────────────────────────────────
header "8. NGINX"
cat > /etc/nginx/sites-enabled/vpnpanel << EOF
server {
    listen 80;
    server_name $SERVER_DOMAIN;
    return 301 https://\$host:${PANEL_PORT}\$request_uri;
}
server {
    listen ${PANEL_PORT} ssl;
    server_name $SERVER_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/${SERVER_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SERVER_DOMAIN}/privkey.pem;
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

rm -f /etc/nginx/sites-enabled/default 2>/dev/null
nginx -t 2>/dev/null && systemctl reload nginx && ok "Nginx настроен" || warn "Проверь nginx конфиг"

# ── FIREWALL ──────────────────────────────────────
header "9. FIREWALL"
ufw allow 22/tcp    >/dev/null 2>&1
ufw allow 80/tcp    >/dev/null 2>&1
ufw allow 443/tcp   >/dev/null 2>&1
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
ufw allow 4443/tcp  >/dev/null 2>&1
ufw allow 20897/udp >/dev/null 2>&1
echo "y" | ufw enable >/dev/null 2>&1
ok "UFW правила добавлены"


# ── ОБНОВЛЕНИЕ ИЗ GIT ─────────────────────────────
cd /opt/vpn_panel && git pull origin main >/dev/null 2>&1
systemctl restart vpn-panel
ok "Файлы обновлены из git"

# ── ИТОГ ──────────────────────────────────────────
header "✅ УСТАНОВКА ЗАВЕРШЕНА"
echo ""
echo -e "  ${GREEN}Panel:${NC}  https://${SERVER_DOMAIN}:${PANEL_PORT}"
echo -e "  ${GREEN}Or:${NC}     https://${SERVER_IP}:${PANEL_PORT}"
echo -e "  ${GREEN}Login:${NC}   admin"
echo -e "  ${GREEN}Pass:${NC}    ${ADMIN_PASS}"
echo -e "  ${GREEN}Token:${NC}   ${ADMIN_TOKEN:0:16}..."
echo ""
echo -e "  ${CYAN}Logs:${NC}    tail -f /opt/vpn_panel/panel.log"
echo -e "  ${CYAN}Diag:${NC}    bash /opt/vpn_panel/diag_vpn_panel.sh"
echo ""
if [ "${INSTALL_SINGBOX:-Y}" = "Y" ] || [ "${INSTALL_SINGBOX}" = "y" ]; then
    echo -e "  ${YELLOW}Sing-box:${NC}"
    echo -e "    VLESS port:     4443 (TCP)"
    echo -e "    Hysteria2 port: 20897 (UDP)"
    echo -e "    Public Key:     ${PUBLIC_KEY}"
    echo -e "    Short ID:       ${SHORT_ID}"
    echo -e "    UUID:           ${VLESS_UUID}"
fi
echo ""
ok "Goto! Open panel in browser."
