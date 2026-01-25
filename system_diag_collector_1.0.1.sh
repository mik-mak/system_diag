#!/usr/bin/bash

# Название скрипта
SCRIPT_NAME="system_diag_collector.sh"

# Директория для временного хранения данных
TEMP_DIR=$(mktemp -d /tmp/system_diag_XXXXXX)

# Лог-файл (вне временной директории)
LOG_FILE="$(pwd)/system_diag.log"  # Лог будет дописываться в текущую директорию

# Функция для вывода ошибок
error_exit() {
    log_message "Ошибка: $1"
    exit 1
}

# Функция для логирования
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Модуль: Проверка свободного места на диске
check_disk_space() {
    REQUIRED_SPACE=500  # Минимум 500 МБ
    FREE_SPACE=$(df -m . | awk 'NR==2 {print $4}')
    if (( FREE_SPACE < REQUIRED_SPACE )); then
        error_exit "Недостаточно свободного места на диске. Требуется минимум ${REQUIRED_SPACE}МБ."
        fi
}

# Модуль: Обработка больших файлов
copy_large_file() {
    local source=$1
    local destination=$2
    MAX_SIZE=$((10 * 1024 * 1024))  # 10 МБ
    if [[ -f "$source" ]]; then
        if [[ $(stat -c%s "$source") -gt $MAX_SIZE ]]; then
            head -c $MAX_SIZE "$source" > "$destination"
            log_message "Ограничен размер файла: $source (первые 10 МБ)"
        else
            cp "$source" "$destination"
                fi
    fi
}

# Модуль: Проверка наличия и установка необходимых утилит
check_and_install_dependencies() {
    log_message "Проверка наличия необходимных утилит..."

    REQUIRED_UTILS=("dmidecode" "rsync" "smartmontools" "ss" "lsof" "sestatus" "util-linux-core")

    for util in "${REQUIRED_UTILS[@]}"; do
        if ! command -v "$util" &>/dev/null; then
            log_message "Утилита $util не найдена."

            # Попытка установки (без проверки интернета) как договорились на митинге
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

# Модуль: Сбор системной информации
collect_system_info() {
    log_message "Сбор системной информации..."
    mkdir -p "$TEMP_DIR/system"
    uname -a > "$TEMP_DIR/system/uname.txt"
    cat /etc/os-release > "$TEMP_DIR/system/os-release.txt"
    rpm -qa > "$TEMP_DIR/system/installed_packages.txt"
    log_message "Сбор системной информации завершен."
}

# Модуль: Сбор журналов системы
collect_logs() {
    log_message "Сбор журналов системы..."
    mkdir -p "$TEMP_DIR/logs"
    dmesg > "$TEMP_DIR/logs/dmesg.txt"
    journalctl --since "1 day ago" > "$TEMP_DIR/logs/journalctl.txt"
    for log in /var/log/*; do
        copy_large_file "$log" "$TEMP_DIR/logs/$(basename "$log")"
    done
    log_message "Сбор журналов системы завершен."
}

# Модуль: Сбор конфигурационных файлов
collect_config_files() {
    log_message "Сбор конфигурационных файлов..."
    mkdir -p "$TEMP_DIR/config"

    CONFIG_FILE="/etc/system_diag.conf"
    if [[ -f "$CONFIG_FILE" ]]; then
        log_message "Используется пользовательский список конфигурационных файлов из $CONFIG_FILE"
        CONFIG_FILES=()
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/[[:space:]]*$//')  # Убираем концевые пробелы
            if [[ -n "$line" && ! "$line" =~ ^# ]]; then
                CONFIG_FILES+=("$line")
            fi
        done < "$CONFIG_FILE"
    else
        log_message "Файл $CONFIG_FILE не найден. Используется стандартный список."

        # ===============================
        # Системные и загрузочные конфиги
        # ===============================
        CONFIG_FILES=(
            "/etc/fstab"
            "/etc/X11"
            "/etc/grub.conf"
            "/boot/grub2/grub.cfg"
            "/etc/sysctl.conf"

            # ======================
            # Пользователи и привилегии
            # ======================
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

            # ==================
            # Безопасность
            # ==================
            "/etc/security"
            "/etc/selinux"
            "/etc/pam.d"
            "/etc/audit"
            "/etc/rsyslog.conf"
            "/etc/logrotate.conf"

            # ==================
            # Сервисы
            # ==================
            "/etc/nginx"
            "/etc/httpd"
            "/etc/mysql"
            "/etc/postgresql"
            "/etc/sssd"
            "/etc/ssh/sshd_config"

            # ==================
            # Репозитории и пакеты
            # ==================
            "/etc/yum.repos.d"
            "/etc/yum.conf"
            "/etc/dnf/dnf.conf"

            # ==================
            # Чувствительные
            # ==================
            "/etc/shadow"
            "/etc/gshadow"
        )
    fi

    # Копирование файлов с сохранением структуры
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

    # Копирование /etc/systemd/system с разрешением символических ссылок
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

# Модуль: Сбор информации о сетевых подключениях
collect_network_connections() {
    log_message "Сбор информации о сетевых подключениях..."
    mkdir -p "$TEMP_DIR/network"

    # Используем ss для современных систем
    if command -v ss &>/dev/null; then
        ss -tuln > "$TEMP_DIR/network/ss_connections.txt"
        log_message "Сетевые подключения собраны с помощью ss."
    else
        log_message "Утилита ss не найдена. Пропускаем сбор данных с её помощью."
    fi

    # Используем lsof для дополнительной информации
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
    df -h > "$TEMP_DIR/storage/df.txt"
    lsblk > "$TEMP_DIR/storage/lsblk.txt"
    fdisk -l > "$TEMP_DIR/storage/fdisk.txt" 2>/dev/null
    smartctl -a /dev/sda > "$TEMP_DIR/storage/smartctl_sda.txt" 2>/dev/null
    log_message "Сбор информации о дисках и хранилище завершен."
}

# Модуль: Сбор информации о смонтированных SMB и CIFS-шарах
collect_cifs_mounts() {
    log_message "Сбор информации о смонтированных SMB/CIFS-шарах..."
    mkdir -p "$TEMP_DIR/network/cifs"

    # Вывод текущих CIFS-монтирований
    mount | grep cifs > "$TEMP_DIR/network/cifs/mount_info.txt" 2>/dev/null
    cat /proc/mounts | grep cifs > "$TEMP_DIR/network/cifs/proc_mounts.txt" 2>/dev/null

    # Детальная информация через smbstatus (если доступен)
    if command -v smbstatus &>/dev/null; then
        smbstatus -b > "$TEMP_DIR/network/cifs/smbstatus_brief.txt" 2>&1
        smbstatus > "$TEMP_DIR/network/cifs/smbstatus_full.txt" 2>&1
    else
        log_message "Утилита smbstatus не найдена. Пропускаем сбор детальной информации о SMB."
    fi

    # Информация через findmnt (если установлена с util-linux-core)
    if command -v findmnt &>/dev/null; then
        findmnt -t cifs > "$TEMP_DIR/network/cifs/findmnt_output.txt" 2>&1
    else
        log_message "Утилита findmnt не найдена. Пропускаем вывод через findmnt."
    fi

    # Проверка активных процессов монтирования
    ps aux | grep mount.cifs | grep -v grep > "$TEMP_DIR/network/cifs/mount_processes.txt" 2>&1

    log_message "Сбор информации о SMB/CIFS-шарах завершён."
}

# Модуль: Сбор информации о безопасности (SELinux)
collect_security_info() {
    log_message "Сбор информации о безопасности (SELinux)..."
    mkdir -p "$TEMP_DIR/security"
    getenforce > "$TEMP_DIR/security/selinux_status.txt"
    sestatus > "$TEMP_DIR/security/sestatus.txt" 2>/dev/null
    log_message "Сбор информации о безопасности (SELinux) завершен."
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
    mkdir -p "$TEMP_DIR/software"
    rpm -qa > "$TEMP_DIR/software/rpm_packages.txt"
    if command -v pip &>/dev/null; then
        mkdir -p "$TEMP_DIR/software/python"
        pip list --format=freeze > "$TEMP_DIR/software/python/pip_packages.txt"
    fi
    if command -v npm &>/dev/null; then
        mkdir -p "$TEMP_DIR/software/nodejs"
        npm list -g --depth=0 > "$TEMP_DIR/software/nodejs/npm_global_packages.txt"
    fi
    log_message "Сбор информации об установленном программном обеспечении завершен."
}

# Модуль: Сбор информации о snap и snap-пакетах
collect_snap_info() {
    log_message "Сбор информации о snap и установленных snap-пакетах..."

    mkdir -p "$TEMP_DIR/software/snap"

    if command -v snap &>/dev/null; then
        # Список установленных snap-пакетов
        snap list > "$TEMP_DIR/software/snap/snap_packages.txt"
        # Версия snap
        snap --version > "$TEMP_DIR/software/snap/snap_version.txt"
        # Информация о состоянии сервиса snapd
        systemctl status snapd >> "$TEMP_DIR/software/snap/snap_service_status.txt" 2>&1

        log_message "Информация о snap успешно собрана."
    else
        log_message "Утилита snap не найдена. Пропускаем сбор данных о snap."
    fi

    log_message "Сбор информации о snap завершён."
}

# Модуль: Сбор информации о модулях ядра
collect_kernel_modules() {
    log_message "Сбор информации о модулях ядра..."

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

    log_message "Сбор информации о модулях ядра завершён."
}

# Модуль: Сбор информации об аппаратном обеспечении
collect_hardware_info() {
    log_message "Сбор информации об аппаратном обеспечении..."
    mkdir -p "$TEMP_DIR/hardware"

    # 1. Определение типа виртуализации
    log_message "Определение типа виртуализации..."
    if command -v systemd-detect-virt &>/dev/null; then
        virt_type=$(systemd-detect-virt)
        echo "$virt_type" > "$TEMP_DIR/hardware/virtualization.txt"
        log_message "Определён тип платформы: $virt_type"
    else
        echo "tool-not-found" > "$TEMP_DIR/hardware/virtualization.txt"
        log_message "Не удалось определить тип платформы: утилита systemd-detect-virt недоступна."
    fi

    # 2. Информация от dmidecode (если доступен)
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

    # 3. Информация от hwinfo (если доступен)
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

    # 4. Стандартные утилиты (почти всегда доступны)
    lscpu > "$TEMP_DIR/hardware/lscpu.txt" 2>/dev/null
    lspci > "$TEMP_DIR/hardware/lspci.txt" 2>/dev/null
    lsusb > "$TEMP_DIR/hardware/lsusb.txt" 2>/dev/null
    dmesg | grep -i "memory\|bios\|acpi\|firmware" > "$TEMP_DIR/hardware/dmesg_hardware.txt" 2>&1

    # 5. Дополнительная информация
    cat /proc/cpuinfo > "$TEMP_DIR/hardware/cpuinfo.txt"
    cat /proc/meminfo > "$TEMP_DIR/hardware/meminfo.txt"
    free -h > "$TEMP_DIR/hardware/free.txt"
    uptime > "$TEMP_DIR/hardware/uptime.txt"

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

# Обработка параметров командной строки
COLLECT_MODULES=false

if [[ "$#" -gt 0 ]]; then
    case "$1" in
        -h|--help)
            cat <<EOF
Скрипт: system_diag_collector.sh — инструмент диагностики системы AlterOS

ОПИСАНИЕ:
Этот скрипт предназначен для сбора диагностической информации с ОС AlterOS, необходимой для анализа обращений в Службу Поддержки.

ОСНОВНЫЕ ФУНКЦИИ:
1. Сбор системной информации (ядро, версия ОС, список установленных пакетов)
2. Сбор журналов системы (dmesg, journalctl, /var/log/)
3. Сбор сетевых настроек (IP-адреса, маршруты, DNS, активные соединения)
4. Сбор информации о дисках, хранилищах и состоянии SMART
5. Сбор конфигурационных файлов по умолчанию или пользовательскому списку
6. Сбор информации о процессах, службах, cron-задачах
7. Сбор информации о безопасности (SELinux, PAM, аудит)
8. Сбор информации об установленном ПО (RPM, Python, Node.js, snap)
9. Сбор информации о смонтированных SMB/CIFS-шарах
10. Опционально: сбор модулей ядра

СПИСОК СОБИРАЕМЫХ КОНФИГУРАЦИЙ:
По умолчанию скрипт собирает следующие файлы и директории:
- Системные: /etc/fstab, /etc/sysctl.conf, /boot/grub2/grub.cfg и другие
- Пользователи и доступ: /etc/passwd, /etc/group, /etc/sudoers
- Сеть: /etc/hosts, /etc/resolv.conf, /etc/network/, NetworkManager и др.
- Безопасность: /etc/security, SELinux, sshd_config
- Сервисы: Nginx, Apache, MySQL, PostgreSQL, SSSD
- Репозитории: /etc/yum.repos.d, /etc/yum.conf
- Чувствительные файлы: /etc/shadow, /etc/gshadow

КАСТОМИЗАЦИЯ СБОРА:
Вы можете изменить список собираемых конфигурационных файлов, создав файл:
/etc/system_diag.conf
Формат:
- По одному пути на строке
- Комментарии начинаются с символа #
Пример содержимого:
# Конфиг для сбора диагностики
/etc/fstab
/etc/passwd
/etc/hostname
/etc/ssh/sshd_config

Если файл существует, он будет использоваться вместо списка по умолчанию.

ДОПОЛНИТЕЛЬНЫЕ ПАРАМЕТРЫ ЗАПУСКА:

--help, -h         : Вывод справки (этот экран)
--modules, -m       : Сбор модулей ядра из /usr/lib/modules/<версия_ядра>

РЕЗУЛЬТАТ РАБОТЫ:
Скрипт создаёт архив с данными диагностики в текущей директории, например:
system_diag_20250405_143000.tar.gz

Архив содержит:
- Все собранные данные в структурированном виде
- Лог выполнения: system_diag.log

ПРИМЕРЫ ИСПОЛЬЗОВАНИЯ:
1. Обычный запуск:
   ./system_diag_collector.sh

2. С запуском сбора модулей ядра:
   ./system_diag_collector.sh --modules

3. Для просмотра справки:
   ./system_diag_collector.sh --help

ВАЖНО:
Скрипт должен запускаться от имени root. При необходимости недостающие утилиты будут установлены автоматически через yum/dnf.

СКРИПТ АВТОМАТИЧЕСКИ УСТАНАВЛИВАЕТ НЕДОСТАЮЩИЕ ЗАВИСИМОСТИ:
dmidecode, rsync, smartmontools, ss, lsof, sestatus, util-linux-core и другие, если они отсутствуют.
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


# Проверка прав доступа
if [[ $EUID -ne 0 ]]; then
    error_exit "Скрипт должен быть запущен с правами root."
fi

# Проверка и установка зависимостей
check_and_install_dependencies

# Выполнение сбора данных
check_disk_space
collect_system_info
collect_logs
collect_config_files
collect_network_settings
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
if [[ "$COLLECT_MODULES" == true ]]; then
    collect_kernel_modules
fi
# Создание архива
create_archive || error_exit "Ошибка при создании архива."

# Очистка
cleanup

log_message "Finished.."

