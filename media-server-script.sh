#!/bin/bash

# Проверка наличия необходимых пакетов
check_dependencies() {
    local dependencies=("minidlna" "ffmpeg" "samba" "iotop" "htop" "iftop" "vnstat" "fail2ban" "nginx")
    local missing_deps=()

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "Отсутствуют следующие пакеты: ${missing_deps[*]}"
        echo "Установка необходимых пакетов..."
        sudo apt-get update
        sudo apt-get install -y "${missing_deps[@]}"
    fi
}

# Создание структуры директорий
setup_directories() {
    local base_dir="$1"
    local dirs=("music" "videos" "photos" "playlists")

    for dir in "${dirs[@]}"; do
        mkdir -p "$base_dir/$dir"
        chmod 755 "$base_dir/$dir"
    done
}

# Настройка Samba для общего доступа
configure_samba() {
    local base_dir="$1"
    local samba_conf="/etc/samba/smb.conf"

    # Создание резервной копии конфигурации
    sudo cp "$samba_conf" "${samba_conf}.backup"

    # Добавление конфигурации общего доступа
    cat << EOF | sudo tee -a "$samba_conf"
[MediaServer]
    path = $base_dir
    browseable = yes
    read only = no
    guest ok = yes
    create mask = 0644
    directory mask = 0755
EOF

    # Перезапуск службы Samba
    sudo systemctl restart smbd
}

# Настройка MiniDLNA
configure_minidlna() {
    local base_dir="$1"
    local minidlna_conf="/etc/minidlna.conf"

    # Создание резервной копии конфигурации
    sudo cp "$minidlna_conf" "${minidlna_conf}.backup"

    # Настройка MiniDLNA с оптимизацией для игровых консолей
    cat << EOF | sudo tee "$minidlna_conf"
media_dir=A,$base_dir/music
media_dir=V,$base_dir/videos
media_dir=P,$base_dir/photos
db_dir=$base_dir/.minidlna
log_dir=$base_dir/.minidlna
inotify=yes
notify_interval=60
album_art_names=Cover.jpg/cover.jpg/AlbumArtSmall.jpg/albumartsmall.jpg/AlbumArt.jpg/albumart.jpg/Album.jpg/album.jpg/Folder.jpg/folder.jpg/Thumb.jpg/thumb.jpg
enable_subtitles=yes
strict_dlna=no
model_number=1
friendly_name=HomemediaServer
network_interface=
port=8200
presentation_url=http://@ADDRESS@:8200
max_connections=20
EOF

    # Создание директории для базы данных и логов
    mkdir -p "$base_dir/.minidlna"
    sudo chown minidlna:minidlna "$base_dir/.minidlna"

    # Перезапуск службы MiniDLNA
    sudo systemctl restart minidlna
}
}

# Настройка портов и файрвола
configure_firewall() {
    local ports=("445" "139" "8200")  # Samba и DLNA порты
    
    # Проверяем, установлен ли ufw
    if ! command -v ufw &>/dev/null; then
        echo "Установка UFW (Uncomplicated Firewall)..."
        sudo apt-get install -y ufw
    fi

    # Включаем файрвол, если он не активен
    sudo ufw status | grep -q "Status: active" || sudo ufw enable

    # Открываем необходимые порты
    for port in "${ports[@]}"; do
        echo "Открываем порт $port..."
        sudo ufw allow "$port/tcp"
    done

    # Применяем правила
    sudo ufw reload

    # Выводим статус портов
    echo "Статус открытых портов:"
    sudo netstat -tulpn | grep -E "445|139|8200|80|443"
}

# Настройка веб-интерфейса через Nginx
configure_web_interface() {
    local base_dir="$1"
    
    # Создаем конфигурацию Nginx
    cat << EOF | sudo tee /etc/nginx/sites-available/media-server
server {
    listen 80;
    server_name localhost;

    root $base_dir;
    index index.html;

    location / {
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }

    location /status {
        stub_status on;
        allow 127.0.0.1;
        deny all;
    }
}
EOF

    # Создаем пользователя для веб-интерфейса
    echo "Создание пользователя для веб-интерфейса"
    read -p "Введите имя пользователя: " web_user
    sudo htpasswd -c /etc/nginx/.htpasswd "$web_user"

    # Включаем сайт
    sudo ln -sf /etc/nginx/sites-available/media-server /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl restart nginx
}

# Настройка мониторинга системы
setup_monitoring() {
    # Настройка fail2ban
    cat << EOF | sudo tee /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[samba]
enabled = true
ports = 139,445
filter = samba
logpath = /var/log/samba/log.%m
maxretry = 5

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /var/log/nginx/error.log
EOF

    sudo systemctl restart fail2ban

    # Настройка VNStat для мониторинга трафика
    sudo vnstat -u -i $(ip route | grep default | awk '{print $5}')
    sudo systemctl enable vnstat
    sudo systemctl start vnstat
}

# Функция для создания скриптов обслуживания
create_maintenance_scripts() {
    local base_dir="$1"
    local scripts_dir="$base_dir/scripts"
    mkdir -p "$scripts_dir"

    # Скрипт для бэкапа
    cat << 'EOF' > "$scripts_dir/backup.sh"
#!/bin/bash
backup_dir="/backup/mediaserver_$(date +%Y%m%d)"
mkdir -p "$backup_dir"
rsync -av --progress /etc/samba/smb.conf "$backup_dir/"
rsync -av --progress /etc/minidlna.conf "$backup_dir/"
rsync -av --progress /etc/nginx/sites-available/media-server "$backup_dir/"
EOF

    # Скрипт для проверки здоровья системы
    cat << 'EOF' > "$scripts_dir/health_check.sh"
#!/bin/bash
echo "=== Проверка дискового пространства ==="
df -h
echo -e "\n=== Проверка нагрузки на систему ==="
uptime
echo -e "\n=== Проверка памяти ==="
free -h
echo -e "\n=== Проверка сетевых соединений ==="
netstat -an | grep ESTABLISHED | wc -l
echo -e "\n=== Статистика сети ==="
vnstat -h
echo -e "\n=== Проверка служб ==="
systemctl status minidlna | grep Active
systemctl status smbd | grep Active
systemctl status nginx | grep Active
EOF

    # Скрипт для очистки временных файлов
    cat << 'EOF' > "$scripts_dir/cleanup.sh"
#!/bin/bash
find /tmp -type f -atime +7 -delete
find /var/log -type f -name "*.log" -size +100M -exec truncate -s 100M {} \;
journalctl --vacuum-time=7d
EOF

    # Делаем скрипты исполняемыми
    chmod +x "$scripts_dir"/*.sh

    # Добавляем задачи в cron
    (crontab -l 2>/dev/null; echo "0 3 * * * $scripts_dir/backup.sh") | crontab -
    (crontab -l 2>/dev/null; echo "0 * * * * $scripts_dir/health_check.sh > $base_dir/logs/health_$(date +\%Y\%m\%d).log") | crontab -
    (crontab -l 2>/dev/null; echo "0 4 * * * $scripts_dir/cleanup.sh") | crontab -
}

# Функция для управления правами доступа
setup_permissions() {
    local base_dir="$1"
    
    # Создаём группу для медиа-сервера
    sudo groupadd mediaserver
    sudo usermod -aG mediaserver $USER
    
    # Устанавливаем правильные права
    sudo chown -R $USER:mediaserver "$base_dir"
    sudo chmod -R 775 "$base_dir"
    
    # Устанавливаем SGID бит для новых файлов
    sudo chmod g+s "$base_dir"
    
    # Создаём ACL правила
    sudo setfacl -R -m g:mediaserver:rwx "$base_dir"
    sudo setfacl -R -d -m g:mediaserver:rwx "$base_dir"
}

# Основная функция
main() {
    echo "Настройка домашнего медиа-сервера"
    
    # Запрос пути для медиа-файлов
    read -p "Введите путь для хранения медиа-файлов [/home/$USER/MediaServer]: " base_dir
    base_dir=${base_dir:-"/home/$USER/MediaServer"}

    # Проверка и установка зависимостей
    check_dependencies

    # Создание директорий
    setup_directories "$base_dir"

    # Настройка служб
    configure_samba "$base_dir"
    configure_minidlna "$base_dir"
    
    # Настройка файрвола и портов
    echo "Настройка файрвола и открытие портов..."
    configure_firewall
    
    # Настройка веб-интерфейса
    echo "Настройка веб-интерфейса..."
    configure_web_interface "$base_dir"
    
    # Настройка мониторинга
    echo "Настройка систем мониторинга..."
    setup_monitoring
    
    # Создание скриптов обслуживания
    echo "Создание скриптов обслуживания..."
    create_maintenance_scripts "$base_dir"
    
    # Настройка прав доступа
    echo "Настройка прав доступа..."
    setup_permissions "$base_dir"

    # Получение сетевой информации
    local ip_address=$(hostname -I | awk '{print $1}')
    local hostname=$(hostname)

    # Создание файла с инструкциями
    cat << EOF > "$base_dir/CONNECTION_GUIDE.txt"
=== РУКОВОДСТВО ПО ПОДКЛЮЧЕНИЮ К МЕДИА-СЕРВЕРУ ===

IP-адрес сервера: $ip_address
Имя хоста: $hostname

1. ПОДКЛЮЧЕНИЕ ЧЕРЕЗ WEB-ИНТЕРФЕЙС
================================
Откройте в браузере:
http://$ip_address
или
http://$hostname

2. ПОДКЛЮЧЕНИЕ ЧЕРЕЗ WINDOWS (SMB)
================================
Метод 1 - Через проводник:
- Нажмите Win + R
- Введите: \\\\$ip_address или \\\\$hostname
- Нажмите Enter

Метод 2 - Подключение сетевого диска:
- Откройте проводник
- Правой кнопкой на "Этот компьютер"
- "Подключить сетевой диск"
- Введите: \\\\$ip_address\MediaServer

3. ПОДКЛЮЧЕНИЕ ЧЕРЕЗ MACOS
========================
- Finder -> Go -> Connect to Server
- Введите: smb://$ip_address или smb://$hostname

4. ПОДКЛЮЧЕНИЕ ЧЕРЕЗ LINUX
========================
Метод 1 - Через файловый менеджер:
- Введите в адресной строке: smb://$ip_address

Метод 2 - Монтирование через терминал:
mkdir -p ~/mediaserver
mount -t cifs //$ip_address/MediaServer ~/mediaserver -o guest

5. ПОДКЛЮЧЕНИЕ ИГРОВЫХ КОНСОЛЕЙ
==============================
XBOX:
1. На главном экране Xbox перейдите в раздел "Мои игры и приложения"
2. Найдите и установите приложение "Медиаплеер" (Media Player)
3. Запустите Медиаплеер
4. Ваш медиасервер должен отобразиться автоматически как "HomemediaServer"
5. Если сервер не появился автоматически:
   - Перейдите в настройки сети Xbox
   - Убедитесь, что Xbox в той же сети, что и медиасервер
   - Проверьте, что включено обнаружение медиаустройств

Поддерживаемые форматы для Xbox:
- Видео: MP4, MKV, AVI (с кодеком H.264)
- Аудио: MP3, WAV, WMA, M4A
- Фото: JPEG, PNG, GIF

Оптимальные настройки для Xbox:
- Видео: H.264, разрешение до 4K
- Аудио: AAC или AC3, до 5.1 каналов
- Субтитры: SRT, SSA/ASS

PlayStation:
1. Перейдите в раздел "Медиаплеер" на главном экране
2. Медиасервер должен отобразиться автоматически
3. Выберите тип медиа (видео, музыка, фото)

Nintendo Switch:
- К сожалению, Nintendo Switch не поддерживает DLNA напрямую
- Рекомендуется использовать веб-интерфейс через браузер

РЕШЕНИЕ ПРОБЛЕМ С КОНСОЛЯМИ:
1. Xbox не видит сервер:
   sudo systemctl restart minidlna
   sudo systemctl restart smbd
   
2. Проблемы с воспроизведением:
   - Проверьте формат файла
   - Убедитесь, что кодек поддерживается
   - Попробуйте перекодировать файл:
     ffmpeg -i input.mkv -c:v h264 -c:a aac output.mp4

3. Проблемы с производительностью:
   - Уменьшите битрейт видео
   - Проверьте скорость сети
   - Мониторьте нагрузку: htop

4. Для оптимальной работы с консолями:
   - Используйте проводное подключение
   - Держите файлы в поддерживаемых форматах
   - Регулярно очищайте кэш на консоли

ПОЛЕЗНЫЕ КОМАНДЫ ДЛЯ РАБОТЫ С КОНСОЛЯМИ:
# Перекодирование видео для Xbox
ffmpeg -i input.mkv -c:v h264 -preset medium -crf 23 -c:a aac -b:a 192k output.mp4

# Проверка формата файла
mediainfo filename.mkv

# Мониторинг соединений с консолью
sudo netstat -an | grep 8200

6. МОНИТОРИНГ И УПРАВЛЕНИЕ
========================
Веб-статистика: http://$ip_address/status
Мониторинг системы:
- htop - мониторинг процессов
- iotop - мониторинг дисков
- iftop - мониторинг сети
- vnstat - статистика сети

7. ПОЛЕЗНЫЕ КОМАНДЫ
==================
# Перезапуск служб:
sudo systemctl restart minidlna
sudo systemctl restart smbd
sudo systemctl restart nginx

# Проверка статуса:
sudo systemctl status minidlna
sudo systemctl status smbd
sudo systemctl status nginx

# Просмотр логов:
tail -f /var/log/minidlna.log
tail -f /var/log/samba/log.*
tail -f /var/log/nginx/access.log

8. БЕЗОПАСНОСТЬ
=============
- Все подключения логируются
- Защита от брутфорс-атак через fail2ban
- Мониторинг подключений через vnstat

9. СТРУКТУРА ДИРЕКТОРИЙ
=====================
$base_dir/
├── music/      - Музыка
├── videos/     - Видео
├── photos/     - Фото
├── playlists/  - Плейлисты
└── scripts/    - Скрипты обслуживания

10. АВТОМАТИЧЕСКОЕ ОБСЛУЖИВАНИЕ
============================
Ежедневно в 3:00 - Резервное копирование
Ежечасно - Проверка здоровья системы
Ежедневно в 4:00 - Очистка временных файлов

Для получения помощи или отчета о проблеме:
1. Проверьте логи в директории logs/
2. Запустите скрипт проверки здоровья: ./scripts/health_check.sh
3. Проверьте статус служб через systemctl status
EOF

    echo "
=== УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО ===

Медиа-сервер настроен и готов к использованию!

Подробное руководство по подключению создано в файле:
$base_dir/CONNECTION_GUIDE.txt

Быстрый доступ:
- Веб-интерфейс: http://$ip_address
- DLNA/UPnP: http://$ip_address:8200
- Windows: \\\\$ip_address
- MacOS/Linux: smb://$ip_address

Рекомендуется:
1. Сохранить файл CONNECTION_GUIDE.txt
2. Проверить подключение через веб-интерфейс
3. Настроить автоматическое резервное копирование
4. Регулярно проверять логи и статус сервера

Приятного использования!
"
}

# Запуск скрипта
main