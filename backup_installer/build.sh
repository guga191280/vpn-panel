#!/bin/bash
# Скрипт для упаковки текущей панели в один файл
OUTPUT="install_vpn_panel.sh"

echo "#!/bin/bash" > $OUTPUT
echo "echo '📦 Начинаю развертывание VPN Panel...'" >> $OUTPUT
echo "mkdir -p /opt/vpn_panel/backend /opt/vpn_panel/frontend" >> $OUTPUT

# Функция для упаковки файла
pack_file() {
    local source=$1
    local dest=$2
    echo "echo '📄 Распаковка $dest...'" >> $OUTPUT
    echo "cat <<'FILEEOF' > $dest" >> $OUTPUT
    cat "$source" >> $OUTPUT
    echo -e "\nFILEEOF" >> $OUTPUT
}

# Упаковываем Бэкенд
[ -f /opt/vpn_panel/backend/main.py ] && pack_file "/opt/vpn_panel/backend/main.py" "/opt/vpn_panel/backend/main.py"
[ -f /opt/vpn_panel/backend/keygen.py ] && pack_file "/opt/vpn_panel/backend/keygen.py" "/opt/vpn_panel/backend/keygen.py"
[ -f /opt/vpn_panel/backend/traffic_monitor.py ] && pack_file "/opt/vpn_panel/backend/traffic_monitor.py" "/opt/vpn_panel/backend/traffic_monitor.py"
[ -f /opt/vpn_panel/backend/sync_users.py ] && pack_file "/opt/vpn_panel/backend/sync_users.py" "/opt/vpn_panel/backend/sync_users.py"

# Упаковываем Фронтенд
[ -f /opt/vpn_panel/frontend/index.html ] && pack_file "/opt/vpn_panel/frontend/index.html" "/opt/vpn_panel/frontend/index.html"

echo "echo '✅ Все файлы успешно развернуты в /opt/vpn_panel/'" >> $OUTPUT
chmod +x $OUTPUT
echo "---"
echo "🎉 Готово! Твой файл-установщик создан: /opt/vpn_panel/backup_installer/$OUTPUT"
echo "Этот файл можно сохранить на компьютер или залить в Git."
