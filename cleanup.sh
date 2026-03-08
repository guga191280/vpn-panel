#!/bin/bash
# Логи панели - оставляем 5000 строк
tail -5000 /opt/vpn_panel/panel.log > /tmp/_p.log && mv /tmp/_p.log /opt/vpn_panel/panel.log
tail -2000 /opt/vpn_panel/bot.log > /tmp/_b.log && mv /tmp/_b.log /opt/vpn_panel/bot.log
tail -1000 /opt/vpn_panel/autodiag.log > /tmp/_a.log && mv /tmp/_a.log /opt/vpn_panel/autodiag.log

# Sing-box логи на нодах
for HOST in 212.15.49.151 150.241.106.238 150.241.88.243; do
  PASS=$([ "$HOST" = "212.15.49.151" ] && echo "PVJXSWnS6ZXUg" || echo "alexander77")
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@$HOST \
    "tail -2000 /var/log/sing-box.log > /tmp/_sb.log && mv /tmp/_sb.log /var/log/sing-box.log" 2>/dev/null
done

# Journal - оставляем 50MB
journalctl --vacuum-size=50M -q

# btmp - неудачные SSH входы
> /var/log/btmp

# audit_log в БД - оставляем 30 дней
sqlite3 /opt/vpn_panel/backend/vpn_panel.db \
  "DELETE FROM audit_log WHERE created_at < strftime('%s','now','-30 days');"

# connection_logs - оставляем 7 дней
sqlite3 /opt/vpn_panel/backend/vpn_panel.db \
  "DELETE FROM audit_log WHERE action IN ('connection_ok','connection_fail') AND created_at < strftime('%s','now','-7 days');"

echo "[$(date)] cleanup done, disk: $(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
