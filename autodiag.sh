#!/bin/bash
LOG="/opt/vpn_panel/autodiag.log"
MAX_LINES=500

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG; }

# Обрезаем лог
lines=$(wc -l < $LOG 2>/dev/null || echo 0)
[ $lines -gt $MAX_LINES ] && tail -$MAX_LINES $LOG > $LOG.tmp && mv $LOG.tmp $LOG

log "🔍 Проверка запущена"

check_service() {
    local name=$1
    if systemctl is-active --quiet $name; then
        log "✅ $name — работает"
    else
        log "⚠️  $name — не работает, перезапускаем..."
        systemctl restart $name
        sleep 3
        if systemctl is-active --quiet $name; then
            log "✅ $name — перезапущен успешно"
        else
            log "❌ $name — НЕ удалось перезапустить!"
        fi
    fi
}

check_service vpn-panel
check_service sing-box
check_service nginx

# Проверяем API
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/ 2>/dev/null)
if [ "$HTTP" = "200" ] || [ "$HTTP" = "401" ] || [ "$HTTP" = "307" ]; then
    log "✅ API панели — отвечает ($HTTP)"
else
    log "❌ API панели — не отвечает ($HTTP), перезапускаем..."
    systemctl restart vpn-panel
    sleep 3
fi

# Проверяем финскую ноду
FIN_OK=$(sshpass -p 'alexander77' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    root@fin243.alexanderoff.store "systemctl is-active sing-box" 2>/dev/null)
if [ "$FIN_OK" = "active" ]; then
    log "✅ Finland sing-box — работает"
else
    log "⚠️  Finland sing-box — не работает, перезапускаем..."
    sshpass -p 'alexander77' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        root@fin243.alexanderoff.store "systemctl restart sing-box" 2>/dev/null
    sleep 3
    FIN_OK2=$(sshpass -p 'alexander77' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        root@fin243.alexanderoff.store "systemctl is-active sing-box" 2>/dev/null)
    if [ "$FIN_OK2" = "active" ]; then
        log "✅ Finland sing-box — перезапущен успешно"
    else
        log "❌ Finland sing-box — НЕ запустился!"
    fi
fi

log "─────────────────────────────"
