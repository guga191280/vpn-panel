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

fi

log "─────────────────────────────"

# ===== АВТО-ОЧИСТКА =====
log "🧹 Очистка..."

# Логи панели > 50MB - обрезаем
PANEL_LOG="/opt/vpn_panel/panel.log"
if [ -f "$PANEL_LOG" ]; then
    size=$(du -m "$PANEL_LOG" | cut -f1)
    if [ "$size" -gt 50 ]; then
        tail -1000 "$PANEL_LOG" > "$PANEL_LOG.tmp" && mv "$PANEL_LOG.tmp" "$PANEL_LOG"
        log "✅ panel.log обрезан (был ${size}MB)"
    fi
fi

# Старые записи в БД (connection_logs > 30 дней)
python3 -c "
import sqlite3, time
conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')
cutoff = int(time.time()) - 30*86400
deleted = conn.execute('DELETE FROM connection_logs WHERE timestamp < ?', (cutoff,)).rowcount
if deleted > 0:
    conn.commit()
    print(f'Удалено {deleted} старых connection_logs')
conn.close()
" 2>/dev/null | while read line; do log "✅ БД: $line"; done

# Старые записи audit_log > 90 дней
python3 -c "
import sqlite3, time
conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')
cutoff = int(time.time()) - 90*86400
deleted = conn.execute('DELETE FROM audit_log WHERE created_at < ?', (cutoff,)).rowcount
if deleted > 0:
    conn.commit()
    print(f'Удалено {deleted} старых audit_log')
conn.close()
" 2>/dev/null | while read line; do log "✅ БД: $line"; done

# Старые записи traffic_hourly > 90 дней
python3 -c "
import sqlite3, time
conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')
cutoff = int(time.time()) - 90*86400
deleted = conn.execute('DELETE FROM traffic_hourly WHERE hour < ?', (cutoff,)).rowcount
if deleted > 0:
    conn.commit()
    print(f'Удалено {deleted} старых traffic_hourly')
conn.close()
" 2>/dev/null | while read line; do log "✅ БД: $line"; done

# Временные файлы
rm -f /tmp/sing-box*.tar.gz /tmp/sing-box-* 2>/dev/null
log "✅ /tmp очищен"

# Журналы systemd > 100MB
journalctl --vacuum-size=100M > /dev/null 2>&1
log "✅ Journald очищен"

log "─────────────────────────────"
