#!/bin/bash
# Копируем обновлённый сертификат на russia ноду
sshpass -p "PVJXSWnS6ZXUg" scp /etc/letsencrypt/live/ru75.alexanderoff.store/fullchain.pem root@212.15.49.151:/etc/sing-box/cert.pem
sshpass -p "PVJXSWnS6ZXUg" scp /etc/letsencrypt/live/ru75.alexanderoff.store/privkey.pem root@212.15.49.151:/etc/sing-box/key.pem
sshpass -p "PVJXSWnS6ZXUg" ssh root@212.15.49.151 "systemctl restart sing-box"
echo "[$(date)] russia cert renewed"
