#!/usr/bin/bash

# Название скрипта
SCRIPT_NAME="system_diag_collector.sh"

# Директория для временного хранения данных
TEMP_DIR=$(mktemp -d /tmp/system_diag_XXXXXX)

# Лог-файл (вне временной директории)
LOG_FILE="$(pwd)/system_diag.log"

# ===============================
# Настройки обработки больших файлов
# ===============================
MAX_FILE_SIZE=$((10 * 1024 * 1024))        # Порог 10 МБ для "больших" файлов
SIMILARITY_THRESHOLD=50                     # Порог схожести строк (%) по умолчанию

# Функция для вывода ошибок
error_exit() {
    log_message "Ошибка: $1"
    exit 1
}

# Функция для логирования (без графических символов для совместимости)
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Модуль: Умная обработка больших файлов с дедупликацией строк
process_large_file_smart() {
    local source=$1
    local destination=$2
    local base_name=$(basename "$source")
    local cut_file="${destination}_cut"
    local archive_file="${destination}.tar.gz"
    
    if [[ ! -f "$source" ]]; then
        return 1
    fi
    
    local file_size=$(stat -c%s "$source")
    
    if [[ $file_size -le $MAX_FILE_SIZE ]]; then
        cp "$source" "$destination" 2>/dev/null
        return $?
    fi
    
    log_message "Обработка большого файла (>10MB): $source (${file_size} байт)"
    
    if ! file -b --mime-type "$source" | grep -qE '^text/|^application/json|^application/xml'; then
        log_message "Файл $source не является текстовым, копируем как есть"
        cp "$source" "$destination" 2>/dev/null
        return $?
    fi
    
    local thresh=${SIMILARITY_THRESHOLD:-50}
    if (( thresh < 0 )); then thresh=0; fi
    if (( thresh > 100 )); then thresh=100; fi
    
    if LC_ALL=C awk -v thresh="$thresh" '
    BEGIN { prev=""; first=1 }
    {
        if (first) { print; prev=$0; first=0; next }
        l1=length(prev); l2=length($0)
        max=(l1>l2)?l1:l2
        if (max==0) next
        m=0
        for(i=1;i<=max;i++) if(substr(prev,i,1)==substr($0,i,1)) m++
        p=int(m*100/max)
        if (p<=thresh) { print; prev=$0 }
    }' "$source" > "$cut_file" 2>/dev/null && [[ -s "$cut_file" ]]; then
        
        local orig_size=$(stat -c%s "$source")
        local cut_size=$(stat -c%s "$cut_file")
        local reduction=0
        if (( orig_size > 0 )); then
            reduction=$(( (orig_size - cut_size) * 100 / orig_size ))
        fi
        
        log_message "Создан сокращённый файл: ${cut_file} (экономия ~${reduction}%)"
        
        if tar -czf "$archive_file" -C "$(dirname "$source")" "$base_name" 2>/dev/null; then
            local archive_size=$(stat -c%s "$archive_file")
            log_message "Оригинал архивирован: ${archive_file} (${archive_size} байт)"
        else
            log_message "Предупреждение: Не удалось архивировать $source, удаляем _cut файл"
            rm -f "$cut_file"
            return 1
        fi
    else
        log_message "Предупреждение: Ошибка при дедупликации $source или пустой результат, копируем как есть"
        cp "$source" "$destination" 2>/dev/null
        return $?
    fi
    
    return 0
}

# Модуль: Проверка наличия и установка необходимых утилит
check_and_install_dependencies() {
    log_message "Проверка наличия необходимых утилит..."

    REQUIRED_UTILS=("dmidecode" "rsync" "smartmontools" "ss" "lsof" "sestatus" "util-linux-core")

    for util in "${REQUIRED_UTILS[@]}"; do
        if ! command -v "$util" &>/dev/null; then
            log_message "Утилита $util не найдена."

            if command -v yum &>/dev/null; then
                log_message "Попытка установки $util через yum..."
                yum install -y "$util" >> "$LOG_FILE" 2>&1
                if [[ $? -eq 0 ]]; then
                    log_message "Утилита $util успешно установлена через yum."
                else
                    log_message "Не удалось установить $util через yum. Установите вручную при необходимости."
                fi
            elif command -v dnf &>/dev/null; then
                log_message "Попытка установки $util через dnf..."
                dnf install -y "$util" >> "$LOG_FILE" 2>&1
                if [[ $? -eq 0 ]]; then
                    log_message "Утилита $util успешно установлена через dnf."
                else
                    log_message "Не удалось установить $util через dnf. Установите вручную при необходимости."
                fi
            else
                log_message "Менеджер пакетов не найден. Установите $util вручную при необходимости."
            fi
        else
            log_message "Утилита $util уже установлена."
        fi
    done
}

# Модуль: Проверка свободного места на диске
check_disk_space() {
    REQUIRED_SPACE=500
    FREE_SPACE=$(df -m . | awk 'NR==2 {print $4}')
    if (( FREE_SPACE < REQUIRED_SPACE )); then
        error_exit "Недостаточно свободного места на диске. Требуется минимум ${REQUIRED_SPACE}МБ."
    fi
}

# Модуль: Сбор пользовательских конфигов (Shell, Cinnamon, Citrix)
collect_user_configs() {
    log_message "Начало сбора пользовательских конфигураций..."

    local all_homes=()

    while IFS=: read -r username _ uid _ _ home_dir _; do
        if [[ "$uid" -eq 0 ]] || { [[ "$uid" -ge 1000 ]] && [[ "$uid" -ne 65534 ]]; }; then
            if [[ -d "$home_dir" ]]; then
                all_homes+=("$home_dir")
                log_message "Найдена домашняя директория: $username -> $home_dir"
            fi
        fi
    done < /etc/passwd

    if [[ ${#all_homes[@]} -eq 0 ]]; then
        log_message "Домашние директории пользователей не найдены."
        return 0
    fi

    for home_dir in "${all_homes[@]}"; do
        local user_name
        user_name=$(basename "$home_dir")
        if [[ "$user_name" == "root" ]]; then
             user_name="root_user"
        fi

        local user_out_dir="$TEMP_DIR/users/$user_name"
        mkdir -p "$user_out_dir"/{shell,config}

        log_message "Обработка пользователя: $user_name ($home_dir)"

        if [[ -f "$home_dir/.bash_history" ]]; then
            tail -n 100 "$home_dir/.bash_history" > "$user_out_dir/shell/.bash_history_last100.txt" 2>/dev/null
        fi

        for file in .bash_logout .bash_profile .bashrc .vimrc .lesshst .viminfo .xsession-errors; do
            if [[ -f "$home_dir/$file" ]]; then
                local dest="$user_out_dir/shell/$file"
                process_large_file_smart "$home_dir/$file" "$dest"
            fi
        done

        for file in cinnamon.dconf .Xauthority; do
            if [[ -f "$home_dir/$file" ]]; then
                local dest="$user_out_dir/config/$file"
                process_large_file_smart "$home_dir/$file" "$dest"
            fi
        done

        if [[ -d "$home_dir/.config" ]]; then
            local cfg_src="$home_dir/.config"
            local cfg_dst="$user_out_dir/config"

            log_message "Копирование .config (исключая браузеры)..."
            for item in "$cfg_src"/*; do
                [[ ! -e "$item" ]] && continue
                local item_name
                item_name=$(basename "$item")

                case "$item_name" in
                    yandex-browser|google-chrome|chromium|mozilla|firefox|Brave|Opera|cache)
                        log_message "Пропущено (браузер/кэш): $item_name"
                        continue
                        ;;
                esac

                if [[ -d "$item" ]]; then
                    find "$item" -type f | while read -r subfile; do
                        local rel_path="${subfile#$cfg_src/}"
                        local sub_dest="$cfg_dst/$rel_path"
                        mkdir -p "$(dirname "$sub_dest")"
                        process_large_file_smart "$subfile" "$sub_dest"
                    done
                elif [[ -f "$item" ]]; then
                    process_large_file_smart "$item" "$cfg_dst/"
                fi
            done
        fi

        if [[ -d "$home_dir/.ICAClient" ]]; then
            mkdir -p "$user_out_dir/citrix"
            local ctx_src="$home_dir/.ICAClient"
            local ctx_dst="$user_out_dir/citrix"

            log_message "Найден Citrix клиент. Сбор данных..."

            for file in wfclient.ini All_Regions.ini module.ini webview.conf; do
                if [[ -f "$ctx_src/$file" ]]; then
                    process_large_file_smart "$ctx_src/$file" "$ctx_dst/$file"
                fi
            done

            find "$ctx_src" -type f -name "*.log" | while read -r logfile; do
                local log_dest="$ctx_dst/$(basename "$logfile")"
                process_large_file_smart "$logfile" "$log_dest"
            done

            for dir in SSL cache; do
                if [[ -d "$ctx_src/$dir" ]]; then
                    cp -rL "$ctx_src/$dir" "$ctx_dst/" 2>/dev/null
                fi
            done
        fi
    done
    log_message "Сбор пользовательских данных завершен."
}

# Модуль: Сбор системной информации
collect_system_info() {
    log_message "Сбор системной информации..."
    mkdir -p "$TEMP_DIR/system"
    uname -a > "$TEMP_DIR/system/uname.txt"
    cat /etc/os-release > "$TEMP_DIR/system/os-release.txt"

    # Coredumps
    if command -v coredumpctl &>/dev/null; then
        coredumpctl list > "$TEMP_DIR/system/coredumpctl_list.txt" 2>&1
        coredumpctl -1 info > "$TEMP_DIR/system/coredumpctl_last_info.txt" 2>&1
        log_message "Собрана информация о coredumps"
    else
        log_message "Утилита coredumpctl не найдена. Пропускаем сбор информации о coredumps."
    fi

    log_message "Сбор системной информации завершен."
}

# Модуль: Сбор журналов системы
collect_logs() {
    log_message "Сбор журналов системы..."
    mkdir -p "$TEMP_DIR/logs"

    dmesg > "$TEMP_DIR/logs/dmesg.txt" 2>/dev/null
    journalctl --since "1 day ago" > "$TEMP_DIR/logs/journalctl.txt" 2>&1

    for log_path in /var/log/*; do
        [[ ! -e "$log_path" ]] && continue

        local base_name=$(basename "$log_path")

        if [[ "$base_name" == "lastlog" ]]; then
            log_message "Пропуск исключённого файла: $log_path"
            continue
        fi

        local dest_path="$TEMP_DIR/logs/$base_name"

        if [[ -f "$log_path" ]]; then
            if process_large_file_smart "$log_path" "$dest_path"; then
                if [[ -f "${dest_path}_cut" ]]; then
                    log_message "Обработан (с дедупликацией): $log_path"
                else
                    log_message "Скопирован: $log_path"
                fi
            else
                log_message "Не удалось обработать: $log_path"
            fi
        elif [[ -d "$log_path" ]]; then
            mkdir -p "$dest_path"
            cp -rL "$log_path"/* "$dest_path/" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                log_message "Скопирована директория логов: $log_path"
            else
                log_message "Не удалось скопировать содержимое: $log_path"
            fi
        fi
    done

    log_message "Сбор журналов системы завершён."
}

# Модуль: Сбор конфигурационных файлов
collect_config_files() {
    log_message "Сбор конфигурационных файлов..."
    mkdir -p "$TEMP_DIR/config"

    CONFIG_FILE="/etc/system_diag.conf"
    CONFIG_FILES=()
    
    if [[ -f "$CONFIG_FILE" ]]; then
        log_message "Используется пользовательский список конфигурационных файлов из $CONFIG_FILE"
        
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/[[:space:]]*$//')
            
            if [[ -z "$line" || "$line" =~ ^# ]]; then
                continue
            fi
            
            if [[ "$line" =~ ^SIMILARITY_THRESHOLD[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
                SIMILARITY_THRESHOLD="${BASH_REMATCH[1]}"
                if (( SIMILARITY_THRESHOLD < 0 )); then
                    SIMILARITY_THRESHOLD=0
                elif (( SIMILARITY_THRESHOLD > 100 )); then
                    SIMILARITY_THRESHOLD=100
                fi
                log_message "Порог схожести установлен: $SIMILARITY_THRESHOLD%"
                continue
            fi
            
            CONFIG_FILES+=("$line")
            
        done < "$CONFIG_FILE"
    else
        log_message "Файл $CONFIG_FILE не найден. Используется стандартный список."
        log_message "Порог схожести по умолчанию: $SIMILARITY_THRESHOLD%"

        CONFIG_FILES=(
            "/etc/fstab"
            "/etc/X11"
            "/etc/grub.conf"
            "/boot/grub2/grub.cfg"
            "/etc/sysctl.conf"
            "/etc/passwd"
            "/etc/group"
            "/etc/login.defs"
            "/etc/nsswitch.conf"
            "/etc/hostname"
            "/etc/hosts"
            "/etc/resolv.conf"
            "/etc/network/interfaces"
            "/etc/sysconfig/network-scripts"
            "/etc/NetworkManager"
            "/etc/sudoers"
            "/etc/security"
            "/etc/selinux"
            "/etc/pam.d"
            "/etc/audit"
            "/etc/rsyslog.conf"
            "/etc/logrotate.conf"
            "/etc/nginx"
            "/etc/httpd"
            "/etc/mysql"
            "/etc/postgresql"
            "/etc/sssd"
            "/etc/ssh/sshd_config"
            "/etc/yum.repos.d"
            "/etc/yum.conf"
            "/etc/dnf/dnf.conf"
            "/etc/shadow"
            "/etc/gshadow"
        )
    fi

    for config in "${CONFIG_FILES[@]}"; do
        if [[ -f "$config" || -d "$config" ]]; then
            rsync -aRL --safe-links "$config" "$TEMP_DIR/config/" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                log_message "Скопирован: $config"
            else
                log_message "Не удалось скопировать: $config"
            fi
        else
            log_message "Файл или директория не найдены: $config"
        fi
    done

    if [[ -d "/etc/systemd/system" ]]; then
        log_message "Копирование файлов из /etc/systemd/system с разрешением символических ссылок..."
        mkdir -p "$TEMP_DIR/config/etc/systemd/system"
        cp -rL /etc/systemd/system/* "$TEMP_DIR/config/etc/systemd/system/" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            log_message "Файлы из /etc/systemd/system успешно скопированы."
        else
            log_message "Не удалось скопировать файлы из /etc/systemd/system."
        fi
    else
        log_message "Директория /etc/systemd/system не найдена."
    fi

    log_message "Сбор конфигурационных файлов завершён."
}

# Модуль: Сбор сетевых настроек
collect_network_settings() {
    log_message "Сбор сетевых настроек..."
    mkdir -p "$TEMP_DIR/network"
    ip addr show > "$TEMP_DIR/network/ip_addr.txt"
    ip route show > "$TEMP_DIR/network/ip_route.txt"
    cat /etc/resolv.conf > "$TEMP_DIR/network/resolv.conf"
    log_message "Сбор сетевых настроек завершен."
}

# Модуль: Сбор информации о межсетевом экране (firewall)
collect_firewall_info() {
    log_message "Сбор информации о настройках межсетевого экрана..."
    mkdir -p "$TEMP_DIR/network/firewall"

    # nftables
    if command -v nft &>/dev/null; then
        nft -a list ruleset > "$TEMP_DIR/network/firewall/ruleset.txt" 2>&1
        log_message "Собран ruleset nftables"
    else
        log_message "Утилита nft не найдена. Пропускаем сбор nftables."
    fi

    # iptables (IPv4)
    if command -v iptables-save &>/dev/null; then
        iptables-save > "$TEMP_DIR/network/firewall/ruleset-legacy4.txt" 2>&1
        log_message "Собран iptables (IPv4)"
    else
        log_message "Утилита iptables-save не найдена. Пропускаем."
    fi

    # ip6tables (IPv6)
    if command -v ip6tables-save &>/dev/null; then
        ip6tables-save > "$TEMP_DIR/network/firewall/ruleset-legacy6.txt" 2>&1
        log_message "Собран ip6tables (IPv6)"
    else
        log_message "Утилита ip6tables-save не найдена. Пропускаем."
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --list-all > "$TEMP_DIR/network/firewall/firewalld-list-all.txt" 2>&1
        firewall-cmd --direct --get-all-rules > "$TEMP_DIR/network/firewall/firewalld-direct.txt" 2>&1
        firewall-cmd --get-active-zones > "$TEMP_DIR/network/firewall/firewalld-active-zones.txt" 2>&1
        log_message "Собраны настройки firewalld"
    else
        log_message "Утилита firewall-cmd не найдена. Пропускаем сбор firewalld."
    fi

    log_message "Сбор информации о межсетевом экране завершён."
}

# Модуль: Сбор информации о сетевых подключениях
collect_network_connections() {
    log_message "Сбор информации о сетевых подключениях..."
    mkdir -p "$TEMP_DIR/network"

    if command -v ss &>/dev/null; then
        ss -tuln > "$TEMP_DIR/network/ss_connections.txt"
        log_message "Сетевые подключения собраны с помощью ss."
    else
        log_message "Утилита ss не найдена. Пропускаем сбор данных с её помощью."
    fi

    if command -v lsof &>/dev/null; then
        lsof -i -n -P > "$TEMP_DIR/network/lsof_connections.txt"
        log_message "Сетевые подключения собраны с помощью lsof."
    else
        log_message "Утилита lsof не найдена. Пропускаем сбор данных с её помощью."
    fi

    log_message "Сбор информации о сетевых подключениях завершен."
}

# Модуль: Сбор информации о дисках и хранилище
collect_storage_info() {
    log_message "Сбор информации о дисках и хранилище..."
    mkdir -p "$TEMP_DIR/storage"
    df -h > "$TEMP_DIR/storage/df.txt" 2>/dev/null
    lsblk > "$TEMP_DIR/storage/lsblk.txt" 2>/dev/null
    fdisk -l > "$TEMP_DIR/storage/fdisk.txt" 2>/dev/null

    if command -v smartctl &>/dev/null; then
        log_message "Сбор SMART с подключённых накопителей..."
        local devices=()
        for dev in /dev/sd[a-z]; do
            [[ -b "$dev" ]] && devices+=("$dev")
        done

        for dev in /dev/nvme[0-9]n[0-9]; do
            [[ -b "$dev" ]] && devices+=("$dev")
        done

        for device in "${devices[@]}"; do
            if [[ -b "$device" ]]; then
                local safe_name=$(basename "$device")
                smartctl -a "$device" > "$TEMP_DIR/storage/smartctl_${safe_name}.txt" 2>&1
                if [[ -s "$TEMP_DIR/storage/smartctl_${safe_name}.txt" ]]; then
                    log_message "SMART собран: $device"
                else
                    echo "=== Ошибка чтения SMART с $device ===" >> "$TEMP_DIR/storage/smartctl_${safe_name}.txt"
                    log_message "Не удалось получить SMART-данные: $device"
                fi
            fi
        done
    else
        log_message "Утилита smartctl не найдена. Пропускаем сбор SMART-данных."
    fi

    log_message "Сбор информации о дисках и хранилище завершён."
}

# Модуль: Сбор информации о смонтированных SMB и CIFS-шарах
collect_cifs_mounts() {
    log_message "Сбор информации о смонтированных SMB/CIFS-шарах..."
    mkdir -p "$TEMP_DIR/network/cifs"

    mount | grep cifs > "$TEMP_DIR/network/cifs/mount_info.txt" 2>/dev/null
    cat /proc/mounts | grep cifs > "$TEMP_DIR/network/cifs/proc_mounts.txt" 2>/dev/null

    if command -v smbstatus &>/dev/null; then
        smbstatus -b > "$TEMP_DIR/network/cifs/smbstatus_brief.txt" 2>&1
        smbstatus > "$TEMP_DIR/network/cifs/smbstatus_full.txt" 2>&1
    else
        log_message "Утилита smbstatus не найдена. Пропускаем сбор детальной информации о SMB."
    fi

    if command -v findmnt &>/dev/null; then
        findmnt -t cifs > "$TEMP_DIR/network/cifs/findmnt_output.txt" 2>&1
    else
        log_message "Утилита findmnt не найдена. Пропускаем вывод через findmnt."
    fi

    ps aux | grep mount.cifs | grep -v grep > "$TEMP_DIR/network/cifs/mount_processes.txt" 2>&1

    log_message "Сбор информации о SMB/CIFS-шарах завершён."
}

# Модуль: Сбор информации о безопасности (SELinux + аудит)
collect_security_info() {
    log_message "Сбор информации о безопасности (SELinux)..."
    mkdir -p "$TEMP_DIR/security"
    getenforce > "$TEMP_DIR/security/selinux_status.txt"
    sestatus > "$TEMP_DIR/security/sestatus.txt" 2>/dev/null
    if command -v aureport &>/dev/null; then
        aureport -x --summary > "$TEMP_DIR/security/aureport.txt" 2>&1
    else
        log_message "aureport не найден. Установите auditd для сбора аудита."
    fi
    log_message "Сбор информации о безопасности завершен."
}

# Модуль: Сбор информации о процессах
collect_process_info() {
    log_message "Сбор информации о процессах..."
    mkdir -p "$TEMP_DIR/system"
    ps aux > "$TEMP_DIR/system/ps_aux.txt"
    top -b -n 1 > "$TEMP_DIR/system/top.txt"
    log_message "Сбор информации о процессах завершен."
}

# Модуль: Сбор информации о службах
collect_services_info() {
    log_message "Сбор информации о службах..."
    mkdir -p "$TEMP_DIR/services"
    systemctl list-units --type=service --all > "$TEMP_DIR/services/systemctl_services.txt"
    systemctl list-timers --all > "$TEMP_DIR/services/systemctl_timers.txt"
    log_message "Сбор информации о службах завершен."
}

# Модуль: Сбор информации о cron-задачах
collect_cron_info() {
    log_message "Сбор информации о cron-задачах..."
    mkdir -p "$TEMP_DIR/cron"
    crontab -l > "$TEMP_DIR/cron/user_crontab.txt" 2>/dev/null
    cat /etc/crontab > "$TEMP_DIR/cron/system_crontab.txt" 2>/dev/null
    if [[ -d /etc/cron.d ]]; then
        cp -r /etc/cron.d/* "$TEMP_DIR/cron/cron.d/" 2>/dev/null
    else
        log_message "/etc/cron.d не найден..."
    fi
    log_message "Сбор информации о cron-задачах завершен."
}

# Модуль: Сбор информации об установленном ПО
collect_installed_software() {
    log_message "Сбор информации об установленном программном обеспечении..."
    mkdir -p "$TEMP_DIR/software/yum"
    rpm -qa > "$TEMP_DIR/software/yum/rpm_packages.txt"
    yum list installed > "$TEMP_DIR/software/yum/yum_packages.txt"
    yum list available > "$TEMP_DIR/software/yum/yum_packages_avlbl.txt"
    yum repolist -v > "$TEMP_DIR/software/yum/yum_repolist.txt"
    yum history -v > "$TEMP_DIR/software/yum/yum_history.txt"
    yum check-update --changelogs > "$TEMP_DIR/software/yum/yum_chkupdt.txt" || true
    
    if command -v pip &>/dev/null; then
        mkdir -p "$TEMP_DIR/software/python"
        pip list --format=freeze > "$TEMP_DIR/software/python/pip_packages.txt"
    fi
    if command -v npm &>/dev/null; then
        mkdir -p "$TEMP_DIR/software/nodejs"
        npm list -g --depth=0 > "$TEMP_DIR/software/nodejs/npm_global_packages.txt"
    fi

    # Шрифты
    mkdir -p "$TEMP_DIR/software/fonts"
    
    if [[ -d /usr/share/fonts ]]; then
        ls -l /usr/share/fonts/* > "$TEMP_DIR/software/fonts/fonts_list.log" 2>&1
        log_message "Собран список системных шрифтов"
    else
        log_message "Директория /usr/share/fonts не найдена"
    fi
    
    # Безопасная обработка glob для AlterOffice
    shopt -s nullglob
    alteroffice_fonts=(/opt/alteroffice*/misc/fonts/truetype/)
    shopt -u nullglob
    
    if [[ ${#alteroffice_fonts[@]} -gt 0 ]]; then
        ls -l "${alteroffice_fonts[@]}" > "$TEMP_DIR/software/fonts/fonts_alteroffice.log" 2>&1
        log_message "Собран список шрифтов AlterOffice"
    else
        log_message "Шрифты AlterOffice не найдены"
    fi

    log_message "Сбор информации об установленном программном обеспечении завершен."
}

# Модуль: Сбор информации о snap и snap-пакетах
collect_snap_info() {
    log_message "Сбор информации о snap и установленных snap-пакетах..."
    mkdir -p "$TEMP_DIR/software/snap"

    if command -v snap &>/dev/null; then
        snap list > "$TEMP_DIR/software/snap/snap_packages.txt"
        snap --version > "$TEMP_DIR/software/snap/snap_version.txt"
        systemctl status snapd >> "$TEMP_DIR/software/snap/snap_service_status.txt" 2>&1
        log_message "Информация о snap успешно собрана."
    else
        log_message "Утилита snap не найдена. Пропускаем сбор данных о snap."
    fi

    log_message "Сбор информации о snap завершён."
}

# Модуль: Сбор списка загруженных модулей ядра (lsmod)
collect_loaded_modules() {
    log_message "Сбор списка загруженных модулей ядра..."
    mkdir -p "$TEMP_DIR/modules"

    if command -v lsmod &>/dev/null; then
        lsmod > "$TEMP_DIR/modules/lsmod.txt" 2>&1
        log_message "Список загруженных модулей получен (lsmod)"
    else
        log_message "Утилита lsmod не найдена. Пропускаем."
    fi

    log_message "Сбор списка загруженных модулей ядра завершён."
}

# Модуль: Сбор информации о модулях ядра - файлы
collect_kernel_modules() {
    log_message "Сбор информации о модулях ядра (файлы)..."
    KERNEL_VERSION=$(uname -r)
    MODULES_DIR="/usr/lib/modules/${KERNEL_VERSION}"

    if [[ -d "$MODULES_DIR" ]]; then
        mkdir -p "$TEMP_DIR/modules"
        cp -r "$MODULES_DIR" "$TEMP_DIR/modules/" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            log_message "Модули ядра $KERNEL_VERSION успешно скопированы."
        else
            log_message "Не удалось скопировать модули ядра. Проверьте права доступа."
        fi
    else
        log_message "Директория модулей ядра не найдена: $MODULES_DIR"
    fi

    log_message "Сбор информации о модулях ядра (файлы) завершён."
}

# Модуль: Сбор информации об аппаратном обеспечении
collect_hardware_info() {
    log_message "Сбор информации об аппаратном обеспечении..."
    mkdir -p "$TEMP_DIR/hardware"

    log_message "Определение типа виртуализации..."
    if command -v systemd-detect-virt &>/dev/null; then
        virt_type=$(systemd-detect-virt)
        echo "$virt_type" > "$TEMP_DIR/hardware/virtualization.txt"
        log_message "Определён тип платформы: $virt_type"
    else
        echo "tool-not-found" > "$TEMP_DIR/hardware/virtualization.txt"
        log_message "Не удалось определить тип платформы: утилита systemd-detect-virt недоступна."
    fi

    if command -v dmidecode &>/dev/null; then
        log_message "Сбор данных через dmidecode..."
        dmidecode -t system > "$TEMP_DIR/hardware/dmi_system.txt" 2>/dev/null
        dmidecode -t bios > "$TEMP_DIR/hardware/dmi_bios.txt" 2>/dev/null
        dmidecode -t baseboard > "$TEMP_DIR/hardware/dmi_baseboard.txt" 2>/dev/null
        dmidecode -t chassis > "$TEMP_DIR/hardware/dmi_chassis.txt" 2>/dev/null
        dmidecode -t processor > "$TEMP_DIR/hardware/dmi_processor.txt" 2>/dev/null
        dmidecode -t memory > "$TEMP_DIR/hardware/dmi_memory.txt" 2>/dev/null
        dmidecode -t cache > "$TEMP_DIR/hardware/dmi_cache.txt" 2>/dev/null
        dmidecode -t slot > "$TEMP_DIR/hardware/dmi_slots.txt" 2>/dev/null
        dmidecode -t connector > "$TEMP_DIR/hardware/dmi_connectors.txt" 2>/dev/null
        dmidecode -t oemstring > "$TEMP_DIR/hardware/dmi_oem.txt" 2>/dev/null
    else
        log_message "Утилита dmidecode не найдена. Пропускаем сбор детальной информации об оборудовании."
    fi

    if command -v hwinfo &>/dev/null; then
        log_message "Сбор данных через hwinfo..."
        hwinfo --short > "$TEMP_DIR/hardware/hwinfo_short.txt" 2>/dev/null
        hwinfo --bios > "$TEMP_DIR/hardware/hwinfo_bios.txt" 2>/dev/null
        hwinfo --cpu > "$TEMP_DIR/hardware/hwinfo_cpu.txt" 2>/dev/null
        hwinfo --memory > "$TEMP_DIR/hardware/hwinfo_memory.txt" 2>/dev/null
        hwinfo --storage > "$TEMP_DIR/hardware/hwinfo_storage.txt" 2>/dev/null
        hwinfo --disk > "$TEMP_DIR/hardware/hwinfo_disk.txt" 2>/dev/null
        hwinfo --partition > "$TEMP_DIR/hardware/hwinfo_partition.txt" 2>/dev/null
        hwinfo --network > "$TEMP_DIR/hardware/hwinfo_network.txt" 2>/dev/null
        hwinfo --graphics > "$TEMP_DIR/hardware/hwinfo_graphics.txt" 2>/dev/null
        hwinfo --sound > "$TEMP_DIR/hardware/hwinfo_sound.txt" 2>/dev/null
        hwinfo --usb > "$TEMP_DIR/hardware/hwinfo_usb.txt" 2>/dev/null
        hwinfo --pcmcia > "$TEMP_DIR/hardware/hwinfo_pcmcia.txt" 2>/dev/null
    else
        log_message "Утилита hwinfo не найдена. Пропускаем сбор данных через hwinfo."
    fi

    lscpu > "$TEMP_DIR/hardware/lscpu.txt" 2>/dev/null
    lspci -knn > "$TEMP_DIR/hardware/lspci.txt" 2>/dev/null
    lsusb > "$TEMP_DIR/hardware/lsusb.txt" 2>/dev/null
    dmesg | grep -i "memory\|bios\|acpi\|firmware" > "$TEMP_DIR/hardware/dmesg_hardware.txt" 2>&1

    cat /proc/cpuinfo > "$TEMP_DIR/hardware/cpuinfo.txt"
    cat /proc/meminfo > "$TEMP_DIR/hardware/meminfo.txt"
    free -h > "$TEMP_DIR/hardware/free.txt"
    uptime > "$TEMP_DIR/hardware/uptime.txt"

    # Принтеры
    if command -v lpstat &>/dev/null; then
        lpstat -t > "$TEMP_DIR/hardware/printers.txt" 2>&1
        log_message "Собрана информация о принтерах"
    else
        log_message "Утилита lpstat не найдена. Пропускаем сбор информации о принтерах."
    fi

    log_message "Сбор информации об аппаратном обеспечении завершён."
}

# Модуль: Архивация данных
create_archive() {
    log_message "Создание архива..."
    ARCHIVE_NAME="system_diag_$(date +%Y%m%d_%H%M%S).tar.gz"
    ARCHIVE_DIR="${ARCHIVE_NAME%.tar.gz}"
    mkdir "$TEMP_DIR/$ARCHIVE_DIR"
    
    for i in "$TEMP_DIR"/*; do
        if [[ "$(basename "$i")" != "$ARCHIVE_DIR" ]]; then
            mv "$i" "$TEMP_DIR/$ARCHIVE_DIR"
        fi
    done
    
    tar -czf "$ARCHIVE_NAME" -C "$TEMP_DIR" ./"$ARCHIVE_DIR"
    log_message "Архив создан: $(pwd)/$ARCHIVE_NAME"
}

# Модуль: Очистка временных файлов
cleanup() {
    log_message "Очистка временных файлов..."
    rm -rf "$TEMP_DIR"
}

# Основной блок
log_message "Запуск скрипта $SCRIPT_NAME..."

COLLECT_MODULES=false

if [[ "$#" -gt 0 ]]; then
    case "$1" in
        -h|--help)
            cat <<EOF
Скрипт: system_diag_collector.sh — инструмент диагностики системы AlterOS

ОПИСАНИЕ:
Этот скрипт предназначен для сбора диагностической информации с ОС AlterOS.

ОСНОВНЫЕ ФУНКЦИИ:
1. Сбор системной информации, журналов, сетевых настроек
2. Умная обработка больших текстовых файлов (>10 МБ) с дедупликацией строк
3. Сбор конфигурационных файлов по умолчанию или из /etc/system_diag.conf
4. Сбор информации о межсетевом экране (nftables, iptables-legacy, firewalld)
5. Сбор списка загруженных модулей ядра (lsmod)
6. Сбор информации о принтерах (lpstat)
7. Сбор списков установленных шрифтов (системных и AlterOffice)
8. Сбор информации о coredumps (coredumpctl)

КАСТОМИЗАЦИЯ СБОРА:
Создайте файл /etc/system_diag.conf для изменения поведения.
Пример содержимого:
  SIMILARITY_THRESHOLD=70
  /etc/fstab
  /etc/ssh/sshd_config

ПАРАМЕТРЫ ЗАПУСКА:
  --help, -h     : Вывод справки
  --modules, -m  : Сбор файлов модулей ядра из /usr/lib/modules/<версия_ядра>
                   (по умолчанию собирается только список lsmod)

ВАЖНО:
Скрипт должен запускаться от имени root.
EOF
            exit 0
            ;;
        -m|--modules)
            COLLECT_MODULES=true
            shift
            ;;
        *)
            error_exit "Неизвестный параметр: $1"
            ;;
    esac
fi

if [[ $EUID -ne 0 ]]; then
    error_exit "Скрипт должен быть запущен с правами root."
fi

check_and_install_dependencies
check_disk_space
collect_system_info
collect_user_configs
collect_logs
collect_config_files
collect_network_settings
collect_firewall_info
collect_storage_info
collect_cifs_mounts
collect_security_info
collect_process_info
collect_services_info
collect_network_connections
collect_cron_info
collect_installed_software
collect_snap_info
collect_hardware_info
collect_loaded_modules

if [[ "$COLLECT_MODULES" == true ]]; then
    collect_kernel_modules
fi

create_archive || error_exit "Ошибка при создании архива."
cleanup

log_message "Finished."