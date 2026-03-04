#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()     { echo -e "${GREEN}[✓]${NC} $1"; }
fail()   { echo -e "${RED}[✗]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
info()   { echo -e "${CYAN}[i]${NC} $1"; }
header() { echo -e "\n${BLUE}══════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════${NC}"; }
PANEL_DIR="/opt/vpn_panel"; DB="$PANEL_DIR/backend/vpn_panel.db"
FIN_HOST="fin243.alexanderoff.store"

header "1. СИСТЕМА"
echo "  OS: $(lsb_release -d 2>/dev/null | cut -f2)"
echo "  RAM: $(free -h | awk '/^Mem/{print $3"/"$2}')"
echo "  Disk: $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
echo "  Uptime: $(uptime -p)"

header "2. СЕРВИСЫ"
for svc in vpn-panel sing-box nginx; do
    st=$(systemctl is-active $svc 2>/dev/null)
    [ "$st" = "active" ] && ok "$svc actve" || fail "$svc $st"
done

header "3. ПАНЕЛЬ"
[ -f "$DB" ] && ok "БД: $(du -sh $DB | cut -f1)" || fail "БД не найдена"
pid=$(pgrep -f "python3.*main.py" | head -1)
[ -n "$pid" ] && ok "Процесс PID=$pid" || fail "Процесс не найден"
ss -tlnp | grep -q ":8080" && ok "Порт 8080 OK" || fail "Порт 8080 не слушает"
cd $PANEL_DIR && info "Git: $(git log -1 --format='%h %s %cr' 2>/dev/null)"

header "4. API"
TOKEN=$(python3 -c "import sqlite3; conn=sqlite3.connect('$DB'); r=conn.execute('SELECT token FROM admins LIMIT 1').fetchone(); print(r[0] if r else '')" 2>/dev/null)
[ -n "$TOKEN" ] && ok "Токен получен" || fail "Токен не получен"
for ep in /api/nodes /api/users /api/hosts; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "http://localhost:8080$ep" 2>/dev/null)
    [ "$code" = "200" ] && ok "$ep OK" || fail "$ep -> $code"
done

header "5. БАЗА ДАННЫХ"
python3 - << PYEOF2
import sqlite3, time
conn = sqlite3.connect('$DB'); conn.row_factory = sqlite3.Row
nodes = conn.execute("SELECT * FROM nodes").fetchall()
print(f"  Нод: {len(nodes)}")
for n in nodes: print(f"    [{n['id']}] {n['name']} {n['host']} status={n['status']}")
users = conn.execute("SELECT username,status,expire_at FROM users").fetchall()
now = int(time.time())
print(f"  Пользователей: {len(users)}")
for u in users: print(f"    {u['username']} | {u['status']} | {(u['expire_at']-now)//86400} дней")
hosts = conn.execute("SELECT remark,address,port FROM hosts WHERE active=1").fetchall()
print(f"  Хостов: {len(hosts)}")
for h in hosts: print(f"    {h['remark']} {h['address']}:{h['port']}")
print(f"  Активных мостов: {conn.execute('SELECT count(*) FROM bridges WHERE active=1').fetchone()[0]}")
conn.close()
PYEOF2

header "6. SING-BOX RU"
st=$(systemctl is-active sing-box 2>/dev/null)
[ "$st" = "active" ] && ok "sing-box active" || fail "sing-box $st"
for p in 4443 20897; do ss -tlnp | grep -q ":$p" && ok "Порт $p OK" || fail "Порт $p закрыт"; done
uc=$(python3 -c "import json; cfg=json.load(open('/etc/sing-box/config.json')); [print(len(inb.get('users',[]))) for inb in cfg['inbounds'] if inb['type']=='vless']" 2>/dev/null)
ok "Пользователей в конфиге: $uc"

header "7. ФИНСКАЯ НОДА"
FIN_PASS=$(python3 -c "import sqlite3; conn=sqlite3.connect('$DB'); r=conn.execute(\"SELECT value FROM settings WHERE key='fin_ssh_pass'\").fetchone(); print(r[0] if r else 'alexander77'); conn.close()" 2>/dev/null)
command -v sshpass &>/dev/null || apt-get install -y sshpass -qq
fin_st=$(sshpass -p "$FIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$FIN_HOST "systemctl is-active sing-box" 2>/dev/null)
[ "$fin_st" = "active" ] && ok "sing-box active на fin" || fail "sing-box $fin_st на fin"
fin_uc=$(sshpass -p "$FIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$FIN_HOST \
  "python3 -c \"import json; cfg=json.load(open('/etc/sing-box/config.json')); [print(len(inb.get('users',[]))) for inb in cfg['inbounds'] if inb['type']=='vless']\"" 2>/dev/null)
ok "Пользователей на fin: $fin_uc"
for p in 4443 20379; do
    fin_p=$(sshpass -p "$FIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$FIN_HOST "ss -tnlp | grep -c ":$p" || ss -unlp | grep -c ":$p"'" 2>/dev/null)
    [ "$fin_p" -gt 0 ] 2>/dev/null && ok "Fin порт $p OK" || fail "Fin порт $p закрыт"
done

header "8. СИНХРОНИЗАЦИЯ"
cd $PANEL_DIR && python3 backend/sync_users.py 2>&1 | sed 's/^/  /'

header "9. KEYGEN"
python3 - << PYEOF2
import sys; sys.path.insert(0,'/opt/vpn_panel/backend')
import keygen, sqlite3
conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')
users = conn.execute("SELECT id,username FROM users LIMIT 5").fetchall()
conn.close()
for uid,uname in users:
    keys = keygen.generate_keys(uid)
    real = {k:v for k,v in keys.items() if k not in ('vless_main','vless')}
    print(f"  {uname}: {len(real)} ключей")
    for k,v in real.items():
        print(f"    [{'OK' if v else 'EMPTY'}] {k}")
PYEOF2

header "10. ПОРТЫ"
ss -tlnp | grep LISTEN | awk '{print "  "$4}' | sort

header "11. ЛОГИ ОШИБОК"
journalctl -u vpn-panel -n 20 --no-pager 2>/dev/null | grep -iE "error|exception|traceback" | tail -10 | sed 's/^/  /' || ok "Нет ошибок"

header "ИТОГ"
echo "  Дата: $(date '+%Y-%m-%d %H:%M:%S')"
ok "Диагностика завершена!"
