#!/bin/bash
# Авто-диагностика и авто-восстановление VPN Panel
LOG="/opt/vpn_panel/autodiag.log"
MAX_LINES=500

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG; }

# Обрезаем лог если больше 500 строк
lines=$(wc -l < $LOG 2>/dev/null || echo 0)
[ $lines -gt $MAX_LINES ] && tail -$MAX_LINES $LOG > $LOG.tmp && mv $LOG.tmp $LOG

# Получаем токен телеграм из БД
TG_TOKEN=$(python3 -c "
import sqlite3
conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')
r = conn.execute(\"SELECT value FROM settings WHERE key='tg_bot_token'\").fetchone()
print(r[0] if r and r[0] else '')
conn.close()
" 2>/dev/null)

TG_ADMIN=$(python3 -c "
import sqlite3
conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')
r = conn.execute(\"SELECT value FROM settings WHERE key='tg_admin_id'\").fetchone()
print(r[0] if r and r[0] else '')
conn.close()
" 2>/dev/null)

tg_notify() {
    [ -z "$TG_TOKEN" ] || [ -z "$TG_ADMIN" ] && return
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_ADMIN}&text=🚨 VPN Panel Alert:%0A$1" > /dev/null 2>&1
}

check_service() {
    local name=$1
    if ! systemctl is-active --quiet $name; then
        log "⚠️  $name не работает — перезапускаем..."
        systemctl restart $name
        sleep 3
        if systemctl is-active --quiet $name; then
            log "✅ $name перезапущен успешно"
            tg_notify "$name был перезапущен автоматически"
        else
            log "❌ $name НЕ удалось перезапустить!"
            tg_notify "$name НЕ запускается! Требуется ручное вмешательство"
        fi
    fi
}

# Проверяем сервисы
check_service vpn-panel
check_service sing-box
check_service nginx

# Проверяем API панели
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/api/stats -H "Authorization: Bearer dummy" 2>/dev/null)
if [ "$HTTP" = "000" ]; then
    log "⚠️  API панели не отвечает — перезапускаем vpn-panel..."
    systemctl restart vpn-panel
    sleep 3
    tg_notify "API панели не отвечал, перезапущен"
fi

# Проверяем финскую ноду
FIN_OK=$(sshpass -p 'alexander77' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    root@fin243.alexanderoff.store "systemctl is-active sing-box" 2>/dev/null)
if [ "$FIN_OK" != "active" ]; then
    log "⚠️  Finland sing-box не работает — перезапускаем..."
    sshpass -p 'alexander77' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        root@fin243.alexanderoff.store "systemctl restart sing-box" 2>/dev/null
    sleep 3
    FIN_OK2=$(sshpass -p 'alexander77' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        root@fin243.alexanderoff.store "systemctl is-active sing-box" 2>/dev/null)
    if [ "$FIN_OK2" = "active" ]; then
        log "✅ Finland sing-box перезапущен"
        tg_notify "Finland sing-box перезапущен автоматически"
    else
        log "❌ Finland sing-box не запустился!"
        tg_notify "Finland sing-box НЕ запускается!"
    fi
fi
