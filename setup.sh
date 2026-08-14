#!/bin/bash
# wget https://raw.githubusercontent.com/saym101/setup/main/setup.sh
clear
shopt -s extglob

# =========================================================
# 00. ROOT / ENVIRONMENT CHECK
# =========================================================
if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт должен быть запущен от имени root."
    echo "Перезапустите его командой: sudo bash $0"
    exit 1
fi

# =========================================================
# 01. ЦВЕТА И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
# =========================================================
declare -A colors=(
    [r]=$(tput setaf 1)
    [g]=$(tput setaf 2)
    [y]=$(tput setaf 3)
    [c]=$(tput setaf 6)
    [p]=$(tput setaf 5)
    [x]=$(tput sgr0)
    [b]=$(tput bold)
)

currhostname=$(cat /etc/hostname 2>/dev/null || hostname)
authorizedfile="/root/.ssh/authorized_keys"
sshconfigfile="/etc/ssh/sshd_config"
DATE=$(date "+%Y-%m-%d")
LAMP_URL="https://raw.githubusercontent.com/saym101/-LAMP-Apache-Angie-PHP-/main/lamp.sh"
standard_packages="
ca-certificates
curl
dnsutils
git
gnupg
htop
iotop
iproute2
jq
lynx
lsof
mc
ncdu
openssh-client
openssh-server
openssl
rsync
socat
traceroute
unzip
zip
7zip
"
optional_packages="
ethtool
nmap
tcpdump
net-tools
qrencode
"
chrony_servers="0.ru.pool.ntp.org 1.ru.pool.ntp.org 2.ru.pool.ntp.org 3.ru.pool.ntp.org"

BACKUP_DIR="/root/.setup_backups"
UFW_BACKUP_DIR="$BACKUP_DIR/ufw"
APT_UPDATED=0

# MOTD runtime-состояние
MOTD_SCRIPT="/etc/update-motd.d/20-server-info"
MOTD_CONFIG="/etc/default/server-info-motd"
MOTD_UPDATE_DIR="/etc/update-motd.d"
MOTD_OPTIONS=(SHOW_HOSTNAME SHOW_OS SHOW_KERNEL SHOW_UPTIME SHOW_NETWORK SHOW_SSH_PORT SHOW_LOAD SHOW_MEMORY SHOW_DISK SHOW_UFW SHOW_FAIL2BAN SHOW_TIME USE_COLORS)
declare -A MOTD_VALUES

# SSH runtime-состояние (заполняется в разделе 03, refresh_ssh_state)
ssh_port=22
ssh_session_port=""
ssh_client_ip=""
ssh_client_port=""
ssh_server_ip=""
running_via_ssh=0

# Сетевые runtime-переменные (используются функциями раздела 05)
NET_BACKEND=""
NET_BACKEND_FILE=""
NET_SELECTED_IFACE=""
NET_IFACES=()
NET_REVERT_BACKUP_FILE=""
NET_REVERT_TARGET_FILE=""
NET_REVERT_IFACE=""
NET_REVERT_NM_CONN=""
NET_REVERT_NM_METHOD=""
NET_REVERT_NM_ADDR=""
NET_REVERT_NM_GW=""
NET_REVERT_NM_DNS=""

# Логирование — по умолчанию выключено (см. README: приватные ключи/пароли
# могут попадать на экран, а с логом — и в файл). Включить при отладке:
#   sudo bash setup.sh --log
ENABLE_LOG=0
for arg in "$@"; do
    case "$arg" in
        --log|-l) ENABLE_LOG=1 ;;
    esac
done
if [ "$ENABLE_LOG" -eq 1 ]; then
    LOG_FILE="${PWD}/$(basename "$0" .sh)_${DATE}.log"
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "${colors[y]}Логирование включено: $LOG_FILE (в лог может попасть приватный ключ при генерации — удалите файл после отладки).${colors[x]}"
fi

# =========================================================
# 02. ОБЩИЕ СЛУЖЕБНЫЕ ФУНКЦИИ
# =========================================================
confirm() {
    local msg="$1"
    local default="$2"
    local answer
    while true; do
        read -r -p "${msg} [${default,,}] " answer
        answer="${answer,,}"
        if [[ -z "$answer" ]]; then
            answer="${default,,}"
        fi
        if [[ "$answer" =~ ^(y|n)$ ]]; then
            break
        else
            echo "${colors[r]}Неверный ввод. Пожалуйста, введите 'y' или 'n'.${colors[x]}"
        fi
    done
    [[ "$answer" == "y" ]]
}

confirm_dangerous() {
    local msg="$1"
    local answer
    echo "${colors[r]}${msg}${colors[x]}"
    read -r -p "Введите YES для продолжения: " answer
    [ "$answer" = "YES" ]
}

pause_menu() {
    read -r -p "${colors[y]}Нажмите Enter для продолжения...${colors[x]}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_package() {
    local pkg="$1"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        return 0
    fi
    if [ "$APT_UPDATED" -eq 0 ]; then
        apt-get update
        APT_UPDATED=1
    fi
    apt-get install -y "$pkg"
}

require_command() {
    local cmd="$1" pkg="${2:-$1}"
    command_exists "$cmd" && return 0
    install_package "$pkg"
    command_exists "$cmd"
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_ipv4() {
    local ip="$1" part parts
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do
        [ "$part" -le 255 ] || return 1
    done
    return 0
}

validate_ipv6() {
    local ip="$1"
    [ "$ip" = "::" ] && return 0
    [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]
}

validate_cidr_prefix() {
    local prefix="$1" max="${2:-32}"
    [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le "$max" ]
}

validate_cidr() {
    local input="$1" ip prefix
    [[ "$input" == */* ]] || return 1
    ip="${input%%/*}"
    prefix="${input##*/}"
    if validate_ipv4 "$ip"; then
        validate_cidr_prefix "$prefix" 32
    elif validate_ipv6 "$ip"; then
        validate_cidr_prefix "$prefix" 128
    else
        return 1
    fi
}

validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

backup_file() {
    local file="$1" backup
    [ -f "$file" ] || return 1
    mkdir -p "$BACKUP_DIR"
    backup="${file}.bak_$(date +%Y%m%d_%H%M%S)"
    if cp -p "$file" "$backup"; then
        echo "$backup"
        return 0
    fi
    return 1
}

restore_file() {
    local file="$1" backup="$2"
    [ -f "$backup" ] || return 1
    cp -p "$backup" "$file"
}

# =========================================================
# 03. ОПРЕДЕЛЕНИЕ СОСТОЯНИЯ SSH
# =========================================================
get_ssh_configured_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
    if [ -z "$port" ]; then
        port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshconfigfile" 2>/dev/null | awk '{print $2}' | tail -n1)
    fi
    [ -z "$port" ] && port=22
    echo "$port"
}

refresh_ssh_state() {
    ssh_port="$(get_ssh_configured_port)"
    if [ -n "${SSH_CONNECTION:-}" ]; then
        read -r ssh_client_ip ssh_client_port ssh_server_ip ssh_session_port <<< "$SSH_CONNECTION"
        running_via_ssh=1
    else
        ssh_client_ip=""
        ssh_client_port=""
        ssh_server_ip=""
        ssh_session_port=""
        running_via_ssh=0
    fi
}

show_ssh_state() {
    echo "${colors[y]}Текущая SSH-сессия${colors[x]}"
    echo
    if [ "$running_via_ssh" -eq 1 ]; then
        printf "%-24s%s:%s\n" "Клиент:" "$ssh_client_ip" "$ssh_client_port"
        printf "%-24s%s\n" "IP сервера:" "$ssh_server_ip"
        printf "%-24s%s\n" "Порт текущей сессии:" "$ssh_session_port"
        printf "%-24s%s\n" "Настроенный SSH-порт:" "$ssh_port"
        if [ "$ssh_session_port" != "$ssh_port" ]; then
            echo
            echo "${colors[r]}ВНИМАНИЕ${colors[x]}"
            echo "Текущая SSH-сессия работает через TCP/$ssh_session_port."
            echo "В конфигурации sshd уже установлен TCP/$ssh_port."
            echo "Новые подключения должны выполняться через TCP/$ssh_port."
        fi
    else
        echo "${colors[c]}Текущая сессия не является SSH-соединением.${colors[x]}"
    fi
}

# =========================================================
# 04. НАСТРОЙКА ПРОГРАММ
# =========================================================
software_normalize_list() {
    # Схлопывает многострочный список пакетов в одну строку через пробел
    echo "$1" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

software_install_list() {
    local title="$1" list user_input pkg_array
    list=$(software_normalize_list "$2")
    echo "${colors[r]}Предварительный список программ:${colors[x]}"
    echo "$list"
    while true; do
        read -r -e -i "$list" -p "${colors[y]}Список программ можно изменить (добавить или удалить) или оставить как есть:${colors[x]} " user_input
        [[ -n "$user_input" ]] && break
    done
    echo "${colors[y]}Обновление списка пакетов...${colors[x]}"
    if [ "$APT_UPDATED" -eq 0 ]; then
        apt-get update
        APT_UPDATED=1
    fi
    read -r -a pkg_array <<< "$user_input"
    if apt-get install -y "${pkg_array[@]}"; then
        echo "${colors[y]}Установка «$title» завершена.${colors[x]}"
    else
        echo "${colors[r]}Ошибка при установке пакетов.${colors[x]}"
    fi
    [ -f /usr/share/mc/syntax/sh.syntax ] && cp /usr/share/mc/syntax/sh.syntax /usr/share/mc/syntax/unknown.syntax
}

setup_software() {
    echo "${colors[g]}Установка рекомендуемого набора ПО${colors[x]}"
    if confirm "${colors[y]}Установить рекомендуемый набор программ?${colors[x]}" "n"; then
        software_install_list "рекомендуемый набор" "$standard_packages"
    else
        echo "${colors[r]}Установка отменена.${colors[x]}"
    fi
}

setup_diagnostic_tools() {
    echo "${colors[g]}Установка диагностических утилит${colors[x]}"
    if confirm "${colors[y]}Установить диагностические утилиты?${colors[x]}" "n"; then
        software_install_list "диагностические утилиты" "$optional_packages"
    else
        echo "${colors[r]}Установка отменена.${colors[x]}"
    fi
}

software_menu() {
    local c
    while true; do
        clear
        echo "${colors[g]}=== Установка ПО ===${colors[x]}"
        echo
        echo "1. Установить рекомендуемый набор (возможно изменить список вручную)"
        echo "2. Установить диагностические утилиты (возможно изменить список вручную)"
        echo "0. Назад"
        read -r -p "${colors[y]}Выбор:${colors[x]} " c
        case "$c" in
            1) setup_software; pause_menu ;;
            2) setup_diagnostic_tools; pause_menu ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
    done
}

# 2. Locale
setup_locale() {
    echo "${colors[g]}Устанавливаем корректную локаль...${colors[x]}"
    local current_locale
    current_locale=$(locale | grep "^LANG=" | cut -d'=' -f2 | tr -d '"')
    echo "${colors[g]}Текущая локаль: LANG=$current_locale${colors[x]}"
    if confirm "${colors[y]}Меняем локаль?${colors[x]}" "n"; then
        local default_locale="ru_RU.UTF-8"
        if [ "$current_locale" = "$default_locale" ]; then
            echo "${colors[y]}Текущая локаль уже установлена как '$default_locale'.${colors[x]}"
            if ! confirm "${colors[y]}Всё равно хотите ввести другую локаль?${colors[x]}" "n"; then
                echo "${colors[r]}Изменение локали отменено.${colors[x]}"
                return
            fi
        fi
        while true; do
            read -r -p "Введите желаемую локаль (по умолчанию $default_locale, Enter для отмены): " new_locale
            if [ -z "$new_locale" ]; then
                echo "${colors[r]}Изменение локали отменено.${colors[x]}"
                return
            fi
            if locale -a | grep -Fx "$new_locale" > /dev/null; then
                break
            else
                echo "${colors[r]}Локаль '$new_locale' не найдена. Доступные локали: 'locale -a'.${colors[x]}"
            fi
        done
        if grep -qiE "Debian|Ubuntu" /etc/os-release; then
            echo "LANG=\"$new_locale\"" > /etc/default/locale
            echo "${colors[y]}Локаль '$new_locale' успешно установлена.${colors[x]}"
        else
            echo "${colors[r]}Ваша ОС не поддерживается для автоматической установки локали.${colors[x]}"
        fi
    else
        echo "${colors[r]}Отмена установки локализации.${colors[x]}"
    fi
}

# =========================================================
# 05. НАСТРОЙКА РАСПОЛОЖЕНИЯ (функции; меню — в конце раздела)
# =========================================================
setup_timezone() {
    echo "${colors[g]}Настройка часового пояса${colors[x]}"
    local current_timezone
    current_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
    [ -z "$current_timezone" ] && current_timezone="Не определён"
    echo "${colors[g]}Текущий часовой пояс: $current_timezone${colors[x]}"
    if confirm "${colors[y]}Хотите изменить часовой пояс?${colors[x]}" "n"; then
        timedatectl list-timezones | grep "^Europe/" | nl -s ") " -w 2 | pr -3 -t -w 80
        while true; do
            read -r -p "Введите номер часового пояса (Enter для отмены): " choice
            if [ -z "$choice" ]; then
                echo "${colors[r]}Изменение часового пояса отменено.${colors[x]}"
                return
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                selected_timezone=$(timedatectl list-timezones | grep "^Europe/" | sed -n "${choice}p")
                if [ -n "$selected_timezone" ]; then
                    break
                fi
            fi
            echo "${colors[r]}Некорректный ввод. Введите номер из списка.${colors[x]}"
        done
        timedatectl set-timezone "$selected_timezone"
        echo "${colors[y]}Часовой пояс изменён на $selected_timezone.${colors[x]}"
    else
        echo "${colors[r]}Процедура изменения часового пояса отменена.${colors[x]}"
    fi
}

setup_chrony() {
    echo "${colors[g]}Настройка Chrony${colors[x]}"
    if ! command -v chronyc >/dev/null 2>&1 || ! [ -f /etc/chrony/chrony.conf ]; then
        echo "${colors[r]}Chrony не установлен или конфигурационный файл отсутствует.${colors[x]}"
        if confirm "${colors[y]}Установить Chrony?${colors[x]}" "y"; then
            if apt-get update && apt-get install -y chrony; then
                echo "${colors[y]}Chrony успешно установлен.${colors[x]}"
                cp /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.original"
                while IFS= read -r server; do
                    [ -n "$server" ] && echo "pool $server iburst" >> /etc/chrony/chrony.conf
                done <<< "$chrony_servers"
                systemctl enable --now chrony
                sleep 2
                if systemctl restart chrony && chronyc sources; then
                    :
                else
                    echo "${colors[r]}Ошибка при перезапуске Chrony.${colors[x]}"
                fi
            else
                echo "${colors[r]}Ошибка при установке Chrony.${colors[x]}"
                return
            fi
        fi
        return
    fi
    if ! systemctl is-active --quiet chrony; then
        systemctl start chrony
        sleep 2
        if ! systemctl is-active --quiet chrony; then
            echo "${colors[r]}Не удалось запустить службу chrony.${colors[x]}"
            return
        fi
    fi
    echo "${colors[y]}Текущие источники синхронизации:${colors[x]}"
    chronyc sources
    if confirm "${colors[y]}Хотите сменить NTP-серверы в настройках?${colors[x]}" "n"; then
        local backup_file
        backup_file="/etc/chrony/chrony.conf.bak_$(date +%Y%m%d_%H%M%S)"
        cp /etc/chrony/chrony.conf "$backup_file"
        local default_servers
        default_servers=$(echo "$chrony_servers" | tr '\n' '|' | sed 's/|$//')
        while true; do
            echo -e "${colors[y]}Можете удалить весь список или любые два три сервера и вписать свой. Или оставить как есть."
            read -r -e -i "$default_servers" -p "${colors[r]}Ваш выбор: ${colors[g]}" input_servers
            if [[ -n "$input_servers" && "$input_servers" =~ ^[a-zA-Z0-9\ .\-]+$ ]]; then
                break
            else
                echo "${colors[r]}Неверный формат ввода.${colors[x]}"
            fi
        done
        local new_servers
        new_servers=$(echo "$input_servers" | tr '|' '\n' | tr ' ' '\n' | grep -v '^$')
        if [ -n "$new_servers" ]; then
            local temp_conf
            temp_conf=$(mktemp)
            grep -v "^pool" /etc/chrony/chrony.conf > "$temp_conf"
            while IFS= read -r server; do
                echo "pool $server iburst" >> "$temp_conf"
            done <<< "$new_servers"
            mv "$temp_conf" /etc/chrony/chrony.conf
            chmod 644 /etc/chrony/chrony.conf
            if systemctl restart chrony && chronyc sources; then
                :
            else
                echo "${colors[r]}Ошибка при перезапуске Chrony.${colors[x]}"
            fi
        fi
    fi
}

location_menu() {
    while true; do
        clear
        echo "${colors[g]}=== Настройка расположения ===${colors[x]}"
        echo
        echo "1. Изменить часовой пояс"
        echo "2. Настроить Chrony"
        echo "3. Показать время и часовой пояс"
        echo "4. Проверить синхронизацию времени"
        echo "5. Показать источники Chrony"
        echo "0. Назад"
        read -r -p "${colors[y]}Выбор:${colors[x]} " c
        case "$c" in
            1) setup_timezone; pause_menu ;;
            2) setup_chrony; pause_menu ;;
            3) timedatectl; pause_menu ;;
            4)
                if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
                    echo "${colors[g]}[OK] Время синхронизировано.${colors[x]}"
                else
                    echo "${colors[r]}[FAIL] Время не синхронизировано.${colors[x]}"
                fi
                pause_menu
                ;;
            5)
                if command_exists chronyc; then chronyc sources; else echo "${colors[r]}Chrony не установлен.${colors[x]}"; fi
                pause_menu
                ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
    done
}

# =========================================================
# 06. НАСТРОЙКА SSH
# =========================================================
setup_ssh_keys() {
    echo "${colors[g]}Настройка доступа через SSH-ключи.${colors[x]}"
    if [ -f "$authorizedfile" ]; then
        echo "${colors[y]}Найден файл публичного ключа: $authorizedfile ${colors[x]}"
    fi
    if confirm "${colors[y]}Хотите создать новую пару SSH-ключей?${colors[x]}" "n"; then
        while true; do
            read -r -p "${colors[y]}Введите email для привязки к SSH-ключу: ${colors[x]}" email
            if [[ -n "$email" && "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                break
            fi
        done
        directory="$HOME/.ssh"
        mkdir -p "$directory"
        key_path="$directory/$currhostname-$DATE"

        # Генерация ключа — только один раз, результат проверяем по коду возврата
        if ssh-keygen -t rsa -b 4096 -C "$email" -f "$key_path" -N "" >/dev/null 2>&1; then
            if apt-get install -y putty-tools >/dev/null 2>&1; then
                puttygen "$key_path" -o "$key_path.ppk" 2>/dev/null
                if [ -f "$key_path.ppk" ]; then
                    echo "${colors[y]}Содержимое файла $key_path.ppk (Скопируйте его!):${colors[x]}"
                    echo "---------------------------------------------"
                    cat "$key_path.ppk"
                    echo "---------------------------------------------"
                    echo -e "${colors[r]}Ключ $key_path.ppk лучше удалить с сервера после копирования.${colors[x]}"
                    echo -e "${colors[r]}WARNING: this is a private key. Copy it now and delete it (and $key_path) from the server.${colors[x]}"
                    echo ""
                    if confirm "${colors[r]}Удаляем?${colors[x]}" "n"; then
                        rm "$key_path.ppk"
                    fi
                fi
            fi
        else
            echo "${colors[r]}Ошибка генерации SSH-ключа.${colors[x]}"
            return
        fi

        if [ -f "$key_path.pub" ]; then
            if ! grep -qF "$(cat "$key_path.pub")" "$authorizedfile" 2>/dev/null; then
                cat "$key_path.pub" >> "$authorizedfile"
                echo "${colors[y]}Ключ добавлен в authorized_keys.${colors[x]}"
            else
                echo "${colors[c]}Этот ключ уже есть в списке. Пропускаем.${colors[x]}"
            fi
            chmod 600 "$authorizedfile"
        fi

        if [ -f /etc/ssh/sshd_config ]; then
            cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup_$(date +%F_%H-%M-%S)"
        fi
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshconfigfile"
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$sshconfigfile"
        sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$sshconfigfile"
        sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$sshconfigfile"
        systemctl restart ssh
        echo "${colors[y]}Вход по паролю для root отключен. SSH перезапущен.${colors[x]}"
    fi
}

change_ssh_port() {
    echo "${colors[g]}Изменение порта SSH${colors[x]}"
    echo "Текущий настроенный порт: $ssh_port"
    read -r -p "Введите новый порт (1-65535, Enter — случайный 1025-49150): " new_port_input

    local new_port
    if [ -z "$new_port_input" ]; then
        new_port=$(( RANDOM % 48126 + 1025 ))
    elif validate_port "$new_port_input"; then
        new_port="$new_port_input"
    else
        echo "${colors[r]}Некорректный порт.${colors[x]}"
        return 1
    fi

    if command_exists ss && ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${new_port}\$"; then
        echo "${colors[r]}Порт $new_port уже занят другим процессом.${colors[x]}"
        confirm "Всё равно продолжить?" "n" || return 1
    fi

    local backup
    backup=$(backup_file "$sshconfigfile")
    if [ -z "$backup" ]; then
        echo "${colors[r]}Не удалось создать резервную копию sshd_config.${colors[x]}"
        return 1
    fi

    if grep -qE '^[[:space:]]*#*[[:space:]]*Port[[:space:]]+[0-9]+' "$sshconfigfile"; then
        sed -i -E "s/^[[:space:]]*#*[[:space:]]*Port[[:space:]]+[0-9]+/Port $new_port/" "$sshconfigfile"
    else
        echo "Port $new_port" >> "$sshconfigfile"
    fi

    local errfile
    errfile=$(mktemp)
    trap 'rm -f "$errfile"' RETURN
    if ! sshd -t 2>"$errfile"; then
        echo "${colors[r]}Ошибка в конфигурации sshd:${colors[x]}"
        cat "$errfile"
        restore_file "$sshconfigfile" "$backup"
        echo "${colors[y]}Конфигурация восстановлена из резервной копии.${colors[x]}"
        return 1
    fi

    if ufw_is_installed 2>/dev/null && ufw_is_active 2>/dev/null; then
        if ! ufw status | grep -qE "^${new_port}/tcp"; then
            echo "${colors[y]}UFW активен, но порт $new_port ещё не разрешён.${colors[x]}"
            if confirm "Разрешить TCP/$new_port в UFW перед применением?" "y"; then
                ufw allow "${new_port}/tcp" comment "SSH"
            else
                echo "${colors[r]}Внимание: без правила UFW новые подключения на $new_port могут быть заблокированы.${colors[x]}"
            fi
        fi
    fi

    if systemctl reload ssh 2>/dev/null || systemctl restart ssh; then
        if systemctl is-active --quiet ssh; then
            ssh_port="$new_port"
            echo "${colors[g]}Порт SSH успешно изменён на $ssh_port.${colors[x]}"
        else
            echo "${colors[r]}Служба SSH не активна после перезапуска.${colors[x]}"
            restore_file "$sshconfigfile" "$backup"
            systemctl restart ssh
            return 1
        fi
    else
        echo "${colors[r]}Ошибка перезапуска SSH. Восстанавливаем конфигурацию.${colors[x]}"
        restore_file "$sshconfigfile" "$backup"
        systemctl restart ssh
        return 1
    fi
}

# =========================================================
# 07. НАСТРОЙКА СЕТИ
# =========================================================

# --- Информация об интерфейсах ---
network_get_default_interface() {
    ip route show default 2>/dev/null | awk '{print $5; exit}'
}

network_get_default_gateway() {
    ip route show default 2>/dev/null | awk '{print $3; exit}'
}

network_get_interface_ipv4() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -n1
}

network_get_interface_ipv6() {
    ip -6 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | head -n1
}

network_get_dns() {
    local dns
    if command_exists resolvectl; then
        dns=$(resolvectl dns 2>/dev/null | awk -F': ' '{print $2}' | tr -s ' \n' ' ' | sed 's/^ *//;s/ *$//')
    else
        dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
    fi
    echo "$dns"
}

network_list_interfaces() {
    local default_iface name state ip4 i=1
    default_iface=$(network_get_default_interface)
    NET_IFACES=()
    while IFS= read -r name; do
        name="${name%%@*}"
        [ "$name" = "lo" ] && continue
        NET_IFACES+=("$name")
        state=$(ip -o link show dev "$name" 2>/dev/null | grep -o 'state [A-Z]*' | awk '{print $2}')
        ip4=$(network_get_interface_ipv4 "$name")
        [ -z "$ip4" ] && ip4="—"
        if [ "$name" = "$default_iface" ]; then
            printf "%d. %-10s %-8s %-20s %s\n" "$i" "$name" "$state" "$ip4" "${colors[g]}DEFAULT${colors[x]}"
        else
            printf "%d. %-10s %-8s %-20s\n" "$i" "$name" "$state" "$ip4"
        fi
        ((i++))
    done < <(ip -o link show | awk -F': ' '{print $2}')
}

network_select_interface() {
    network_list_interfaces
    if [ "${#NET_IFACES[@]}" -eq 0 ]; then
        echo "${colors[r]}Сетевые интерфейсы не найдены.${colors[x]}"
        NET_SELECTED_IFACE=""
        return 1
    fi
    if [ "${#NET_IFACES[@]}" -eq 1 ]; then
        NET_SELECTED_IFACE="${NET_IFACES[0]}"
        return 0
    fi
    local choice
    read -r -p "Выберите интерфейс (номер): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#NET_IFACES[@]}" ]; then
        NET_SELECTED_IFACE="${NET_IFACES[$((choice - 1))]}"
        return 0
    fi
    echo "${colors[r]}Неверный выбор.${colors[x]}"
    NET_SELECTED_IFACE=""
    return 1
}

network_show_status() {
    local iface ip4 ip6 gw dns
    iface=$(network_get_default_interface)
    [ -z "$iface" ] && iface="—"
    ip4=$(network_get_interface_ipv4 "$iface"); [ -z "$ip4" ] && ip4="—"
    ip6=$(network_get_interface_ipv6 "$iface"); [ -z "$ip6" ] && ip6="—"
    gw=$(network_get_default_gateway); [ -z "$gw" ] && gw="—"
    dns=$(network_get_dns); [ -z "$dns" ] && dns="—"
    printf "%-22s%s\n" "Текущий hostname:" "$(hostname)"
    printf "%-22s%s\n" "Основной интерфейс:" "$iface"
    printf "%-22s%s\n" "IPv4:" "$ip4"
    printf "%-22s%s\n" "IPv6:" "$ip6"
    printf "%-22s%s\n" "Gateway:" "$gw"
    printf "%-22s%s\n" "DNS:" "$dns"
}

network_show_full_config() {
    echo "${colors[g]}=== ip addr ===${colors[x]}"
    ip addr show
    echo
    echo "${colors[g]}=== ip route ===${colors[x]}"
    ip route show
    echo
    echo "${colors[g]}=== DNS ===${colors[x]}"
    network_get_dns
}

# --- Определение сетевого backend ---
network_detect_backend() {
    if command_exists netplan && compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1; then
        NET_BACKEND="netplan"
        NET_BACKEND_FILE=$(find /etc/netplan -maxdepth 1 -name '*.yaml' 2>/dev/null | sort | tail -n1)
    elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
        NET_BACKEND="networkmanager"
        NET_BACKEND_FILE="nmcli"
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        NET_BACKEND="networkd"
        NET_BACKEND_FILE="/etc/systemd/network"
    elif [ -f /etc/network/interfaces ]; then
        NET_BACKEND="interfaces"
        NET_BACKEND_FILE="/etc/network/interfaces"
    else
        NET_BACKEND="unknown"
        NET_BACKEND_FILE=""
    fi
}

network_show_backend() {
    network_detect_backend
    echo "${colors[c]}Сетевой backend: $NET_BACKEND${colors[x]}"
    [ -n "$NET_BACKEND_FILE" ] && echo "${colors[c]}Файл конфигурации: $NET_BACKEND_FILE${colors[x]}"
}

# --- Подтверждение с автоматическим откатом (для операций через SSH) ---
network_confirm_or_rollback() {
    local revert_func="$1" _confirm_input
    echo
    echo "${colors[y]}Изменения применены.${colors[x]}"
    echo "${colors[y]}Если соединение работает — нажмите Enter в течение 120 секунд, чтобы подтвердить.${colors[x]}"
    echo "${colors[y]}Если ничего не нажать, будет выполнен откат к предыдущей конфигурации.${colors[x]}"
    if read -r -t 120 -p "Подтвердить [Enter]: " _confirm_input; then
        echo "${colors[g]}Изменения подтверждены.${colors[x]}"
        return 0
    else
        echo
        echo "${colors[r]}Тайм-аут истёк. Выполняется откат...${colors[x]}"
        "$revert_func"
        return 1
    fi
}

# --- netplan ---
network_netplan_write_override() {
    local iface="$1" mode="$2" ip="$3" cidr="$4" gw="$5" dns="$6"
    local file="/etc/netplan/90-setup-sh-${iface}.yaml"
    local renderer="networkd"
    grep -ql "renderer: NetworkManager" /etc/netplan/*.yaml 2>/dev/null && renderer="NetworkManager"
    {
        echo "network:"
        echo "  version: 2"
        echo "  renderer: $renderer"
        echo "  ethernets:"
        echo "    ${iface}:"
        if [ "$mode" = "dhcp" ]; then
            echo "      dhcp4: true"
        else
            echo "      dhcp4: false"
            echo "      addresses: [${ip}/${cidr}]"
            if [ -n "$gw" ]; then
                echo "      routes:"
                echo "        - to: default"
                echo "          via: ${gw}"
            fi
            if [ -n "$dns" ]; then
                echo "      nameservers:"
                echo "        addresses: [${dns// /, }]"
            fi
        fi
    } > "$file"
    chmod 600 "$file"
    echo "$file"
}

network_apply_netplan() {
    local iface="$1" mode="$2" ip="$3" cidr="$4" gw="$5" dns="$6"
    local backup_dir file errfile
    backup_dir="$BACKUP_DIR/netplan_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -p /etc/netplan/*.yaml "$backup_dir/" 2>/dev/null
    file=$(network_netplan_write_override "$iface" "$mode" "$ip" "$cidr" "$gw" "$dns")
    errfile=$(mktemp)
    trap 'rm -f "$errfile"' RETURN
    if ! netplan generate 2>"$errfile"; then
        echo "${colors[r]}Ошибка в конфигурации netplan:${colors[x]}"
        cat "$errfile"
        rm -f "$file"
        return 1
    fi
    echo "${colors[y]}Backup сохранён в: $backup_dir${colors[x]}"
    echo "${colors[y]}Применяем через 'netplan try' (автоматический откат через 120с, если не подтвердить Enter)...${colors[x]}"
    if netplan try --timeout 120; then
        echo "${colors[g]}Конфигурация применена и подтверждена.${colors[x]}"
        return 0
    else
        echo "${colors[r]}Изменения отклонены или произошёл откат.${colors[x]}"
        rm -f "$file"
        netplan apply
        return 1
    fi
}

# --- NetworkManager ---
network_nm_get_connection() {
    nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v d="$1" '$2==d{print $1; exit}'
}

network_revert_nm() {
    nmcli con mod "$NET_REVERT_NM_CONN" ipv4.method "$NET_REVERT_NM_METHOD" ipv4.addresses "$NET_REVERT_NM_ADDR" ipv4.gateway "$NET_REVERT_NM_GW" ipv4.dns "$NET_REVERT_NM_DNS"
    nmcli con up "$NET_REVERT_NM_CONN" >/dev/null 2>&1
}

network_apply_nm() {
    local iface="$1" mode="$2" ip="$3" cidr="$4" gw="$5" dns="$6" conn
    conn=$(network_nm_get_connection "$iface")
    if [ -z "$conn" ]; then
        echo "${colors[r]}Активное подключение NetworkManager для $iface не найдено.${colors[x]}"
        return 1
    fi
    NET_REVERT_NM_CONN="$conn"
    NET_REVERT_NM_METHOD=$(nmcli -g ipv4.method con show "$conn")
    NET_REVERT_NM_ADDR=$(nmcli -g ipv4.addresses con show "$conn")
    NET_REVERT_NM_GW=$(nmcli -g ipv4.gateway con show "$conn")
    NET_REVERT_NM_DNS=$(nmcli -g ipv4.dns con show "$conn")

    if [ "$mode" = "dhcp" ]; then
        nmcli con mod "$conn" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
    else
        nmcli con mod "$conn" ipv4.method manual ipv4.addresses "${ip}/${cidr}" ipv4.gateway "$gw" ipv4.dns "$dns"
    fi
    if ! nmcli con up "$conn" >/dev/null 2>&1; then
        echo "${colors[r]}Ошибка применения настроек NetworkManager.${colors[x]}"
        network_revert_nm
        return 1
    fi
    if [ "$running_via_ssh" -eq 1 ]; then
        network_confirm_or_rollback network_revert_nm
    fi
}

# --- systemd-networkd ---
network_revert_networkd() {
    if [ -n "$NET_REVERT_BACKUP_FILE" ] && [ -f "$NET_REVERT_BACKUP_FILE" ]; then
        cp -p "$NET_REVERT_BACKUP_FILE" "$NET_REVERT_TARGET_FILE"
    else
        rm -f "$NET_REVERT_TARGET_FILE"
    fi
    systemctl restart systemd-networkd
}

network_apply_networkd() {
    local iface="$1" mode="$2" ip="$3" cidr="$4" gw="$5" dns="$6" d
    local file="/etc/systemd/network/10-${iface}.network"
    NET_REVERT_TARGET_FILE="$file"
    NET_REVERT_BACKUP_FILE=""
    [ -f "$file" ] && NET_REVERT_BACKUP_FILE=$(backup_file "$file")
    {
        echo "[Match]"
        echo "Name=${iface}"
        echo
        echo "[Network]"
        if [ "$mode" = "dhcp" ]; then
            echo "DHCP=yes"
        else
            echo "Address=${ip}/${cidr}"
            [ -n "$gw" ] && echo "Gateway=${gw}"
            for d in $dns; do
                echo "DNS=${d}"
            done
        fi
    } > "$file"
    if ! systemctl restart systemd-networkd; then
        echo "${colors[r]}Ошибка перезапуска systemd-networkd.${colors[x]}"
        network_revert_networkd
        return 1
    fi
    if [ "$running_via_ssh" -eq 1 ]; then
        network_confirm_or_rollback network_revert_networkd
    fi
}

# --- /etc/network/interfaces ---
network_cidr_to_netmask() {
    local cidr="$1" i mask="" full_octets partial
    full_octets=$((cidr / 8))
    partial=$((cidr % 8))
    for ((i = 0; i < 4; i++)); do
        if [ "$i" -lt "$full_octets" ]; then
            mask+="255"
        elif [ "$i" -eq "$full_octets" ] && [ "$partial" -gt 0 ]; then
            mask+=$((256 - 2 ** (8 - partial)))
        else
            mask+="0"
        fi
        [ "$i" -lt 3 ] && mask+="."
    done
    echo "$mask"
}

network_revert_interfaces() {
    if [ -n "$NET_REVERT_BACKUP_FILE" ] && [ -f "$NET_REVERT_BACKUP_FILE" ]; then
        cp -p "$NET_REVERT_BACKUP_FILE" "$NET_REVERT_TARGET_FILE"
        ifdown "$NET_REVERT_IFACE" 2>/dev/null
        ifup "$NET_REVERT_IFACE" 2>/dev/null
    fi
}

network_apply_interfaces() {
    local iface="$1" mode="$2" ip="$3" cidr="$4" gw="$5" dns="$6"
    local file="/etc/network/interfaces" tmp
    NET_REVERT_TARGET_FILE="$file"
    NET_REVERT_IFACE="$iface"
    NET_REVERT_BACKUP_FILE=$(backup_file "$file")
    tmp=$(mktemp)
    awk -v iface="$iface" '
        BEGIN { skip = 0 }
        /^(auto|iface|allow-hotplug)[ \t]/ {
            if ($0 ~ "^iface[ \t]+" iface "[ \t]") { skip = 1; next }
            if ($0 ~ "^auto[ \t]+" iface "$") { next }
            if ($0 ~ "^allow-hotplug[ \t]+" iface "$") { next }
            skip = 0
        }
        skip && /^[ \t]/ { next }
        { if (!skip) print }
    ' "$file" > "$tmp"
    {
        echo ""
        echo "auto ${iface}"
        if [ "$mode" = "dhcp" ]; then
            echo "iface ${iface} inet dhcp"
        else
            echo "iface ${iface} inet static"
            echo "    address ${ip}"
            echo "    netmask $(network_cidr_to_netmask "$cidr")"
            [ -n "$gw" ] && echo "    gateway ${gw}"
            [ -n "$dns" ] && echo "    dns-nameservers ${dns}"
        fi
    } >> "$tmp"
    mv "$tmp" "$file"
    if ! { ifdown "$iface" 2>/dev/null; ifup "$iface"; }; then
        echo "${colors[r]}Ошибка применения через ifup/ifdown.${colors[x]}"
        network_revert_interfaces
        return 1
    fi
    if [ "$running_via_ssh" -eq 1 ]; then
        network_confirm_or_rollback network_revert_interfaces
    fi
}

# --- Общий диспетчер применения по backend ---
network_apply_config() {
    local iface="$1" mode="$2" ip="$3" cidr="$4" gw="$5" dns="$6"
    network_detect_backend
    case "$NET_BACKEND" in
        netplan) network_apply_netplan "$iface" "$mode" "$ip" "$cidr" "$gw" "$dns" ;;
        networkmanager) network_apply_nm "$iface" "$mode" "$ip" "$cidr" "$gw" "$dns" ;;
        networkd) network_apply_networkd "$iface" "$mode" "$ip" "$cidr" "$gw" "$dns" ;;
        interfaces) network_apply_interfaces "$iface" "$mode" "$ip" "$cidr" "$gw" "$dns" ;;
        *)
            echo "${colors[r]}Не удалось определить сетевой backend. Изменение отменено.${colors[x]}"
            return 1
            ;;
    esac
}

network_show_after_change() {
    local iface="$1" gw
    gw=$(network_get_default_gateway)
    echo
    echo "${colors[g]}=== Новая конфигурация ===${colors[x]}"
    printf "%-12s%s\n" "Interface:" "$iface"
    printf "%-12s%s\n" "MAC:" "$(cat "/sys/class/net/$iface/address" 2>/dev/null)"
    printf "%-12s%s\n" "IPv4:" "$(network_get_interface_ipv4 "$iface")"
    printf "%-12s%s\n" "IPv6:" "$(network_get_interface_ipv6 "$iface")"
    printf "%-12s%s\n" "Gateway:" "$gw"
    printf "%-12s%s\n" "DNS:" "$(network_get_dns)"
    printf "%-12s%s\n" "MTU:" "$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)"
    echo
    if ip link show dev "$iface" 2>/dev/null | grep -q "state UP"; then
        echo "${colors[g]}[OK] Interface UP${colors[x]}"
    else
        echo "${colors[r]}[FAIL] Interface UP${colors[x]}"
    fi
    if [ -n "$gw" ] && ping -c1 -W2 "$gw" >/dev/null 2>&1; then
        echo "${colors[g]}[OK] Gateway${colors[x]}"
    else
        echo "${colors[r]}[FAIL] Gateway${colors[x]}"
    fi
    if getent hosts ya.ru >/dev/null 2>&1; then
        echo "${colors[g]}[OK] DNS resolve${colors[x]}"
    else
        echo "${colors[r]}[FAIL] DNS resolve${colors[x]}"
    fi
    if [ "$running_via_ssh" -eq 1 ]; then
        echo "${colors[g]}[OK] Текущая SSH-сессия активна${colors[x]}"
    fi
}

# --- IPv4: настройка / DHCP-Static ---
network_configure_ipv4() {
    network_select_interface || return
    local iface="$NET_SELECTED_IFACE"
    network_show_backend

    local cur_ip cur_cidr cur_gw cur_dns cur_addr
    cur_addr=$(network_get_interface_ipv4 "$iface")
    cur_ip="${cur_addr%%/*}"
    cur_cidr="${cur_addr##*/}"
    [ -z "$cur_cidr" ] || [ "$cur_cidr" = "$cur_addr" ] && cur_cidr=24
    cur_gw=$(network_get_default_gateway)
    cur_dns=$(network_get_dns)

    local new_ip new_cidr new_gw new_dns
    read -r -e -i "$cur_ip" -p "IPv4 [$cur_ip]: " new_ip
    new_ip="${new_ip:-$cur_ip}"
    read -r -e -i "$cur_cidr" -p "CIDR [$cur_cidr]: " new_cidr
    new_cidr="${new_cidr:-$cur_cidr}"
    read -r -e -i "$cur_gw" -p "Gateway [$cur_gw]: " new_gw
    new_gw="${new_gw:-$cur_gw}"
    read -r -e -i "$cur_dns" -p "DNS [$cur_dns]: " new_dns
    new_dns="${new_dns:-$cur_dns}"

    if ! validate_ipv4 "$new_ip"; then
        echo "${colors[r]}Некорректный IPv4-адрес.${colors[x]}"
        return 1
    fi
    if ! validate_cidr_prefix "$new_cidr" 32; then
        echo "${colors[r]}Некорректный CIDR.${colors[x]}"
        return 1
    fi
    if [ -n "$new_gw" ] && ! validate_ipv4 "$new_gw"; then
        echo "${colors[r]}Некорректный gateway.${colors[x]}"
        return 1
    fi
    local d
    for d in $new_dns; do
        if ! validate_ipv4 "$d" && ! validate_ipv6 "$d"; then
            echo "${colors[r]}Некорректный DNS-адрес: $d${colors[x]}"
            return 1
        fi
    done

    if [ "$running_via_ssh" -eq 1 ]; then
        echo
        echo "${colors[r]}ВНИМАНИЕ${colors[x]}"
        echo "Вы подключены к серверу через SSH."
        echo "Текущий адрес сервера: $ssh_server_ip"
        echo "Новый адрес: $new_ip"
        echo "После применения текущая SSH-сессия может быть разорвана."
        echo
        confirm_dangerous "Продолжить смену IP-адреса?" || { echo "${colors[c]}Отменено.${colors[x]}"; return 1; }
    else
        confirm "Применить новую конфигурацию IPv4?" "n" || return 1
    fi

    if network_apply_config "$iface" "static" "$new_ip" "$new_cidr" "$new_gw" "$new_dns"; then
        network_show_after_change "$iface"
    else
        echo "${colors[r]}Применение конфигурации не выполнено.${colors[x]}"
    fi
}

network_configure_dhcp() {
    network_select_interface || return
    local iface="$NET_SELECTED_IFACE" mode_choice
    echo "1. DHCP"
    echo "2. Static"
    read -r -p "Выберите режим: " mode_choice
    case "$mode_choice" in
        1)
            if [ "$running_via_ssh" -eq 1 ]; then
                confirm_dangerous "Переключение на DHCP может изменить IP-адрес и разорвать SSH-сессию. Продолжить?" || return
            fi
            if network_apply_config "$iface" "dhcp" "" "" "" ""; then
                network_show_after_change "$iface"
            fi
            ;;
        2) network_configure_ipv4 ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
    esac
}

network_configure_gateway() {
    echo "${colors[c]}Изменение gateway выполняется через настройку IPv4 (адрес и DNS можно оставить прежними, нажимая Enter).${colors[x]}"
    network_configure_ipv4
}

# --- DNS ---
network_dns_apply() {
    local dns_list="$1" iface ip cidr gw addr
    network_select_interface || return
    iface="$NET_SELECTED_IFACE"
    addr=$(network_get_interface_ipv4 "$iface")
    ip="${addr%%/*}"
    cidr="${addr##*/}"
    gw=$(network_get_default_gateway)
    if network_apply_config "$iface" "static" "$ip" "$cidr" "$gw" "$dns_list"; then
        echo "${colors[g]}[OK] DNS обновлён: $dns_list${colors[x]}"
    else
        echo "${colors[r]}[ERROR] Не удалось обновить DNS.${colors[x]}"
    fi
}

network_configure_dns() {
    local c
    while true; do
        echo
        echo "${colors[g]}=== Настройка DNS ===${colors[x]}"
        echo "Текущие DNS: $(network_get_dns)"
        echo "1. Показать DNS"
        echo "2. Добавить DNS"
        echo "3. Изменить DNS (весь список)"
        echo "4. Удалить DNS"
        echo "5. Восстановить предыдущие настройки"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) network_get_dns ;;
            2)
                local new_dns_ip
                read -r -p "IP DNS-сервера для добавления: " new_dns_ip
                if validate_ipv4 "$new_dns_ip" || validate_ipv6 "$new_dns_ip"; then
                    network_dns_apply "$(echo "$(network_get_dns) $new_dns_ip" | xargs)"
                else
                    echo "${colors[r]}Некорректный адрес.${colors[x]}"
                fi
                ;;
            3)
                local new_dns_list d ok=1
                read -r -e -i "$(network_get_dns)" -p "Новый список DNS через пробел: " new_dns_list
                for d in $new_dns_list; do
                    { validate_ipv4 "$d" || validate_ipv6 "$d"; } || ok=0
                done
                if [ "$ok" -eq 1 ]; then
                    network_dns_apply "$new_dns_list"
                else
                    echo "${colors[r]}Список содержит некорректный адрес.${colors[x]}"
                fi
                ;;
            4)
                local del_dns_ip remaining
                read -r -p "IP DNS-сервера для удаления: " del_dns_ip
                remaining=$(network_get_dns | tr ' ' '\n' | grep -vx "$del_dns_ip" | tr '\n' ' ')
                network_dns_apply "$remaining"
                ;;
            5)
                if [ -n "$NET_REVERT_BACKUP_FILE" ]; then
                    echo "${colors[y]}Резервная копия текущей сессии: $NET_REVERT_BACKUP_FILE${colors[x]}"
                    confirm "Восстановить эту резервную копию?" "n" && restore_file "$NET_REVERT_TARGET_FILE" "$NET_REVERT_BACKUP_FILE"
                else
                    echo "${colors[c]}Нет сохранённой резервной копии в этой сессии.${colors[x]}"
                fi
                ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
    done
}

# --- IPv6 ---
network_netplan_ipv6_write() {
    local iface="$1" mode="$2" ip6="$3" prefix="$4" gw6="$5"
    local file="/etc/netplan/91-setup-sh-${iface}-ipv6.yaml"
    {
        echo "network:"
        echo "  version: 2"
        echo "  ethernets:"
        echo "    ${iface}:"
        if [ "$mode" = "auto" ]; then
            echo "      dhcp6: true"
            echo "      accept-ra: true"
        else
            echo "      addresses: [${ip6}/${prefix}]"
            if [ -n "$gw6" ]; then
                echo "      routes:"
                echo "        - to: ::/0"
                echo "          via: ${gw6}"
            fi
        fi
    } > "$file"
    chmod 600 "$file"
}

network_configure_ipv6() {
    network_select_interface || return
    local iface="$NET_SELECTED_IFACE" cur_ip6 c
    cur_ip6=$(network_get_interface_ipv6 "$iface")
    echo "Текущий IPv6: ${cur_ip6:-нет}"
    echo "1. Автоконфигурация (SLAAC/DHCPv6)"
    echo "2. Статический IPv6"
    echo "3. Отключить IPv6 на интерфейсе"
    read -r -p "Выбор: " c
    case "$c" in
        1)
            network_detect_backend
            case "$NET_BACKEND" in
                networkmanager)
                    local conn; conn=$(network_nm_get_connection "$iface")
                    if [ -n "$conn" ]; then
                        nmcli con mod "$conn" ipv6.method auto
                        nmcli con up "$conn" >/dev/null 2>&1
                    fi
                    ;;
                netplan)
                    network_netplan_ipv6_write "$iface" "auto"
                    netplan try --timeout 120
                    ;;
                *) echo "${colors[c]}Для этого backend настройте автоконфигурацию IPv6 вручную в файле конфигурации.${colors[x]}" ;;
            esac
            ;;
        2)
            local new_ip6 new_prefix new_gw6
            read -r -p "IPv6 адрес: " new_ip6
            read -r -p "Префикс (0-128) [64]: " new_prefix
            new_prefix="${new_prefix:-64}"
            read -r -p "Gateway IPv6 (можно пусто): " new_gw6
            if ! validate_ipv6 "$new_ip6"; then
                echo "${colors[r]}Некорректный IPv6.${colors[x]}"
                return
            fi
            if ! validate_cidr_prefix "$new_prefix" 128; then
                echo "${colors[r]}Некорректный префикс.${colors[x]}"
                return
            fi
            if [ "$running_via_ssh" -eq 1 ]; then
                confirm_dangerous "Изменение IPv6 может повлиять на доступ. Продолжить?" || return
            fi
            network_detect_backend
            case "$NET_BACKEND" in
                networkmanager)
                    local conn; conn=$(network_nm_get_connection "$iface")
                    if [ -n "$conn" ]; then
                        nmcli con mod "$conn" ipv6.method manual ipv6.addresses "${new_ip6}/${new_prefix}" ipv6.gateway "$new_gw6"
                        nmcli con up "$conn" >/dev/null 2>&1
                    fi
                    ;;
                netplan)
                    network_netplan_ipv6_write "$iface" "static" "$new_ip6" "$new_prefix" "$new_gw6"
                    netplan try --timeout 120
                    ;;
                *) echo "${colors[c]}Автоматическая настройка IPv6 для этого backend не реализована. При необходимости используйте 'ip -6 addr add' вручную.${colors[x]}" ;;
            esac
            ;;
        3)
            confirm_dangerous "Отключить IPv6 на $iface?" && sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=1"
            ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
    esac
}

# --- Маршрутизация ---
network_route_add() {
    local dest gw iface metric cmd
    read -r -p "Destination (напр. 10.10.0.0/24 или default): " dest
    read -r -p "Gateway: " gw
    network_select_interface
    iface="$NET_SELECTED_IFACE"
    read -r -p "Metric (можно пусто): " metric

    if [ "$dest" != "default" ] && ! validate_cidr "$dest"; then
        echo "${colors[r]}Некорректный destination.${colors[x]}"
        return
    fi
    if [ -n "$gw" ] && ! validate_ipv4 "$gw" && ! validate_ipv6 "$gw"; then
        echo "${colors[r]}Некорректный gateway.${colors[x]}"
        return
    fi

    cmd=(ip route add "$dest")
    [ -n "$gw" ] && cmd+=(via "$gw")
    [ -n "$iface" ] && cmd+=(dev "$iface")
    [ -n "$metric" ] && cmd+=(metric "$metric")

    echo "${colors[y]}Будет выполнено: ${cmd[*]}${colors[x]}"
    confirm "Добавить маршрут?" "y" || return
    if "${cmd[@]}"; then
        echo "${colors[g]}[OK] Маршрут добавлен.${colors[x]}"
    else
        echo "${colors[r]}[ERROR] Не удалось добавить маршрут.${colors[x]}"
    fi
}

network_route_delete() {
    local num target
    ip route show | nl -w2 -s') '
    read -r -p "Номер маршрута для удаления: " num
    target=$(ip route show | sed -n "${num}p")
    if [ -z "$target" ]; then
        echo "${colors[r]}Маршрут не найден.${colors[x]}"
        return
    fi
    echo "Будет удалён: $target"
    confirm_dangerous "Удалить этот маршрут?" || return
    # shellcheck disable=SC2086
    if ip route del $target; then
        echo "${colors[g]}[OK] Маршрут удалён.${colors[x]}"
    else
        echo "${colors[r]}[ERROR] Не удалось удалить маршрут.${colors[x]}"
    fi
}

network_routes_menu() {
    local c
    while true; do
        echo
        echo "${colors[g]}=== Маршрутизация ===${colors[x]}"
        ip route show
        echo
        echo "1. Показать маршруты"
        echo "2. Добавить статический маршрут"
        echo "3. Удалить статический маршрут"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) ip route show ;;
            2) network_route_add ;;
            3) network_route_delete ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- MTU ---
network_change_mtu() {
    network_select_interface || return
    local iface="$NET_SELECTED_IFACE" cur_mtu new_mtu
    cur_mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)
    read -r -p "Новый MTU для $iface [$cur_mtu]: " new_mtu
    new_mtu="${new_mtu:-$cur_mtu}"
    if [[ ! "$new_mtu" =~ ^[0-9]+$ ]] || [ "$new_mtu" -lt 68 ] || [ "$new_mtu" -gt 9000 ]; then
        echo "${colors[r]}Некорректное значение MTU (68-9000).${colors[x]}"
        return
    fi
    if ip link set dev "$iface" mtu "$new_mtu"; then
        echo "${colors[g]}[OK] MTU изменён на $new_mtu.${colors[x]}"
    else
        echo "${colors[r]}[ERROR] Не удалось изменить MTU.${colors[x]}"
        return
    fi
    network_detect_backend
    case "$NET_BACKEND" in
        netplan)
            local file="/etc/netplan/92-setup-sh-${iface}-mtu.yaml"
            {
                echo "network:"
                echo "  version: 2"
                echo "  ethernets:"
                echo "    ${iface}:"
                echo "      mtu: ${new_mtu}"
            } > "$file"
            netplan apply
            ;;
        networkmanager)
            local conn; conn=$(network_nm_get_connection "$iface")
            [ -n "$conn" ] && nmcli con mod "$conn" 802-3-ethernet.mtu "$new_mtu"
            ;;
        *) echo "${colors[c]}Значение применено только на время работы (runtime). Для постоянства отредактируйте конфигурацию backend вручную.${colors[x]}" ;;
    esac
}

# --- Управление интерфейсами ---
network_interfaces_menu() {
    local c
    while true; do
        echo
        echo "${colors[g]}=== Управление интерфейсами ===${colors[x]}"
        network_list_interfaces
        echo
        echo "1. Поднять интерфейс (up)"
        echo "2. Отключить интерфейс (down)"
        echo "3. Перезагрузить сеть"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1)
                network_select_interface || { pause_menu; continue; }
                if ip link set dev "$NET_SELECTED_IFACE" up; then
                    echo "${colors[g]}[OK] Интерфейс поднят.${colors[x]}"
                else
                    echo "${colors[r]}[ERROR]${colors[x]}"
                fi
                ;;
            2)
                network_select_interface || { pause_menu; continue; }
                if [ "$running_via_ssh" -eq 1 ] && [ "$NET_SELECTED_IFACE" = "$(network_get_default_interface)" ]; then
                    echo "${colors[r]}ВНИМАНИЕ: это интерфейс, через который может проходить текущая SSH-сессия.${colors[x]}"
                    show_ssh_state
                fi
                confirm_dangerous "Отключить интерфейс $NET_SELECTED_IFACE?" || { pause_menu; continue; }
                if ip link set dev "$NET_SELECTED_IFACE" down; then
                    echo "${colors[g]}[OK] Интерфейс отключён.${colors[x]}"
                else
                    echo "${colors[r]}[ERROR]${colors[x]}"
                fi
                ;;
            3) network_restart ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

network_restart() {
    echo "${colors[y]}Перезапуск сетевой службы применит текущую сохранённую конфигурацию (может отличаться от состояния runtime).${colors[x]}"
    if [ "$running_via_ssh" -eq 1 ]; then
        show_ssh_state
        echo
        confirm_dangerous "Перезапустить сеть? Текущая SSH-сессия может быть разорвана." || return
    else
        confirm "Перезапустить сетевую службу?" "n" || return
    fi
    network_detect_backend
    case "$NET_BACKEND" in
        netplan)
            if netplan apply; then
                echo "${colors[g]}[OK] Сеть перезапущена (netplan apply).${colors[x]}"
            else
                echo "${colors[r]}[ERROR] Ошибка применения netplan.${colors[x]}"
            fi
            ;;
        networkmanager)
            if systemctl restart NetworkManager; then
                echo "${colors[g]}[OK] NetworkManager перезапущен.${colors[x]}"
            else
                echo "${colors[r]}[ERROR] Ошибка перезапуска NetworkManager.${colors[x]}"
            fi
            ;;
        networkd)
            if systemctl restart systemd-networkd; then
                echo "${colors[g]}[OK] systemd-networkd перезапущен.${colors[x]}"
            else
                echo "${colors[r]}[ERROR] Ошибка перезапуска systemd-networkd.${colors[x]}"
            fi
            ;;
        interfaces)
            if systemctl list-unit-files 2>/dev/null | grep -q '^networking\.service'; then
                if systemctl restart networking; then
                    echo "${colors[g]}[OK] Сеть перезапущена (networking.service).${colors[x]}"
                else
                    echo "${colors[r]}[ERROR] Ошибка перезапуска networking.service.${colors[x]}"
                fi
            else
                echo "${colors[y]}Служба networking.service не найдена, перезапускаю интерфейсы по отдельности...${colors[x]}"
                local iface
                network_list_interfaces >/dev/null
                for iface in "${NET_IFACES[@]}"; do
                    ifdown "$iface" 2>/dev/null
                    ifup "$iface" 2>/dev/null
                done
                echo "${colors[g]}[OK] Интерфейсы перезапущены.${colors[x]}"
            fi
            ;;
        *)
            echo "${colors[r]}Не удалось определить сетевой backend, перезапуск отменён.${colors[x]}"
            return 1
            ;;
    esac
}

# --- Диагностика сети ---
network_diagnostics_menu() {
    local c
    while true; do
        clear
        echo "${colors[g]}=== Диагностика сети ===${colors[x]}"
        echo "1. ip addr"
        echo "2. ip link"
        echo "3. ip route"
        echo "4. Проверить gateway"
        echo "5. Проверить DNS"
        echo "6. Ping IP"
        echo "7. Ping hostname"
        echo "8. Показать открытые локальные порты"
        echo "9. Показать активные TCP/UDP соединения"
        echo "10. Проверить удалённый TCP-порт"
        echo "11. Показать DNS-конфигурацию"
        echo "12. Показать текущую SSH-сессию"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) ip addr ;;
            2) ip link ;;
            3) ip route ;;
            4)
                local gw; gw=$(network_get_default_gateway)
                if [ -n "$gw" ] && ping -c3 -W2 "$gw" >/dev/null 2>&1; then
                    echo "${colors[g]}[OK] Gateway $gw доступен.${colors[x]}"
                else
                    echo "${colors[r]}[FAIL] Gateway недоступен.${colors[x]}"
                fi
                ;;
            5)
                if getent hosts ya.ru >/dev/null 2>&1; then
                    echo "${colors[g]}[OK] DNS резолвинг работает.${colors[x]}"
                else
                    echo "${colors[r]}[FAIL] DNS резолвинг не работает.${colors[x]}"
                fi
                ;;
            6)
                local target_ip; read -r -p "IP для ping: " target_ip
                ping -c4 "$target_ip"
                ;;
            7)
                local target_host; read -r -p "Hostname для ping: " target_host
                ping -c4 "$target_host"
                ;;
            8)
                if command_exists ss; then ss -tulnp; else netstat -tulnp; fi
                ;;
            9)
                if command_exists ss; then ss -tunp; else netstat -tunp; fi
                ;;
            10)
                local rhost rport
                read -r -p "Хост: " rhost
                read -r -p "Порт: " rport
                if validate_port "$rport"; then
                    if timeout 3 bash -c "echo >/dev/tcp/$rhost/$rport" 2>/dev/null; then
                        echo "${colors[g]}[OK] Порт $rport на $rhost открыт.${colors[x]}"
                    else
                        echo "${colors[r]}[FAIL] Порт $rport на $rhost недоступен.${colors[x]}"
                    fi
                else
                    echo "${colors[r]}Некорректный порт.${colors[x]}"
                fi
                ;;
            11)
                if command_exists resolvectl; then resolvectl dns; else cat /etc/resolv.conf; fi
                ;;
            12)
                refresh_ssh_state
                show_ssh_state
                ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Hostname (перенесено из раздела "Настройка программ") ---
setup_hostname() {
    echo "${colors[g]}Установка hostname${colors[x]}"
    local current_hostname new_hostname
    current_hostname=$(hostname)
    echo "Текущее имя хоста: $current_hostname"
    if confirm "${colors[y]}Хотите изменить имя хоста?${colors[x]}" "n"; then
        while true; do
            read -r -p "Введите новое имя хоста: " new_hostname
            if validate_hostname "$new_hostname"; then
                break
            else
                echo "${colors[r]}Имя хоста должно содержать только буквы, цифры и дефисы, и не быть пустым.${colors[x]}"
            fi
        done
        echo "$new_hostname" > /etc/hostname
        sed -i "s/^127\.0\.1\.1[[:space:]]\+.*$/127.0.1.1\t$new_hostname/" /etc/hosts
        hostname "$new_hostname"
        currhostname="$new_hostname"
        echo "${colors[y]}Имя хоста успешно изменено на $new_hostname.${colors[x]}"
    else
        echo "${colors[r]}Отмена изменения имени хоста.${colors[x]}"
    fi
}

# --- Главное меню раздела "Настройка сети" ---
network_menu() {
    local c
    while true; do
        clear
        echo "${colors[g]}=== Настройка сети ===${colors[x]}"
        echo
        network_show_status
        echo
        echo "1. Показать полную конфигурацию сети"
        echo "2. Настроить IPv4"
        echo "3. DHCP / статический IPv4"
        echo "4. Изменить gateway"
        echo "5. Настроить DNS"
        echo "6. Настроить IPv6"
        echo "7. Управление маршрутами"
        echo "8. Изменить MTU"
        echo "9. Управление интерфейсами"
        echo "10. Изменить hostname"
        echo "11. Диагностика сети"
        echo "0. Назад"
        read -r -p "${colors[y]}Выбор:${colors[x]} " c
        case "$c" in
            1) network_show_full_config; pause_menu ;;
            2) network_configure_ipv4; pause_menu ;;
            3) network_configure_dhcp; pause_menu ;;
            4) network_configure_gateway; pause_menu ;;
            5) network_configure_dns ;;
            6) network_configure_ipv6; pause_menu ;;
            7) network_routes_menu ;;
            8) network_change_mtu; pause_menu ;;
            9) network_interfaces_menu ;;
            10) setup_hostname; pause_menu ;;
            11) network_diagnostics_menu ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
    done
}

# =========================================================
# 08. НАСТРОЙКА UFW
# =========================================================

# --- Базовые проверки и общий раннер команд ---
ufw_is_installed() { command_exists ufw; }
ufw_is_active() { ufw status 2>/dev/null | grep -q "Status: active"; }

ufw_run() {
    local ok_msg="$1" fail_msg="$2"
    shift 2
    if "$@"; then
        echo "${colors[g]}[OK] $ok_msg${colors[x]}"
        return 0
    else
        echo "${colors[r]}[ERROR] $fail_msg${colors[x]}"
        return 1
    fi
}

ufw_rule_exists() {
    ufw status 2>/dev/null | grep -qiE "$1"
}

ufw_select_protocol() {
    echo "1. TCP" >&2
    echo "2. UDP" >&2
    echo "3. TCP + UDP" >&2
    local p
    read -r -p "Протокол: " p
    case "$p" in
        1) echo "tcp" ;;
        2) echo "udp" ;;
        3) echo "tcp+udp" ;;
        *) echo "tcp" ;;
    esac
}

# --- Управление службой UFW ---
ufw_install() {
    if ufw_is_installed; then
        echo "${colors[c]}UFW уже установлен.${colors[x]}"
        return 0
    fi
    if install_package ufw && ufw_is_installed; then
        echo "${colors[g]}UFW установлен.${colors[x]}"
        return 0
    fi
    echo "${colors[r]}Ошибка установки UFW.${colors[x]}"
    return 1
}

ufw_remove() {
    confirm_dangerous "Полностью удалить пакет UFW?" || return
    if apt-get remove -y ufw; then
        echo "${colors[g]}[OK] UFW удалён.${colors[x]}"
    else
        echo "${colors[r]}[ERROR] Ошибка удаления UFW.${colors[x]}"
    fi
}

ufw_enable() {
    if ! ufw_is_installed; then
        echo "${colors[r]}UFW не установлен.${colors[x]}"
        return 1
    fi
    echo "${colors[c]}Настроенный SSH-порт: $ssh_port${colors[x]}"
    if [ "$running_via_ssh" -eq 1 ]; then
        show_ssh_state
        echo
    fi
    if ! ufw status | grep -qE "^${ssh_port}/tcp"; then
        echo "${colors[y]}Для SSH TCP/$ssh_port отсутствует разрешающее правило.${colors[x]}"
        if confirm "Создать его перед включением UFW?" "y"; then
            ufw allow "${ssh_port}/tcp" comment "SSH"
        else
            echo "${colors[r]}ВНИМАНИЕ: без этого правила вы рискуете потерять доступ по SSH после включения UFW.${colors[x]}"
            confirm_dangerous "Всё равно включить UFW?" || return 1
        fi
    fi
    if [ -n "$ssh_session_port" ] && [ "$ssh_session_port" != "$ssh_port" ] && ! ufw status | grep -qE "^${ssh_session_port}/tcp"; then
        echo "${colors[y]}Текущая SSH-сессия использует TCP/$ssh_session_port, для него нет правила.${colors[x]}"
        confirm "Разрешить также TCP/$ssh_session_port (текущая сессия)?" "y" && ufw allow "${ssh_session_port}/tcp" comment "SSH session"
    fi
    if ufw --force enable; then
        systemctl enable ufw >/dev/null 2>&1
        echo "${colors[g]}[OK] UFW включён.${colors[x]}"
    else
        echo "${colors[r]}[ERROR] Не удалось включить UFW.${colors[x]}"
        return 1
    fi
}

ufw_disable() {
    confirm_dangerous "Отключить UFW? Сервер останется без файрвола." || return
    ufw_run "UFW отключён." "Не удалось отключить UFW." ufw disable
}

ufw_reload() {
    ufw_run "UFW перезагружен." "Не удалось перезагрузить UFW." ufw reload
}

ufw_reset() {
    confirm_dangerous "СБРОСИТЬ ВСЕ правила UFW к значениям по умолчанию?" || return
    confirm "Создать резервную копию перед сбросом?" "y" && ufw_backup
    ufw_run "UFW сброшен." "Не удалось сбросить UFW." ufw --force reset
}

ufw_show_verbose_status() { ufw status verbose; }

ufw_service_menu() {
    local c
    while true; do
        echo
        echo "${colors[g]}=== Управление UFW ===${colors[x]}"
        echo "1. Включить UFW"
        echo "2. Отключить UFW"
        echo "3. Reload"
        echo "4. Reset"
        echo "5. Удалить UFW"
        echo "6. Подробный статус"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) ufw_enable ;;
            2) ufw_disable ;;
            3) ufw_reload ;;
            4) ufw_reset ;;
            5) ufw_remove ;;
            6) ufw_show_verbose_status ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Просмотр и удаление правил ---

ufw_delete_rule() {
    local num rule_line
    while true; do
        echo
        ufw status numbered
        echo
        read -r -p "Номер правила для удаления (Enter — назад): " num
        [ -z "$num" ] && return
        if [[ ! "$num" =~ ^[0-9]+$ ]]; then
            echo "${colors[r]}Некорректный номер.${colors[x]}"
            continue
        fi
        rule_line=$(ufw status numbered | grep -E "^\[[[:space:]]*${num}\]")
        if [ -z "$rule_line" ]; then
            echo "${colors[r]}Правило не найдено.${colors[x]}"
            continue
        fi
        echo "${colors[y]}Выбрано: $rule_line${colors[x]}"

        if echo "$rule_line" | grep -qE "(^|[^0-9])${ssh_port}(/tcp|/udp|[^0-9]|$)"; then
            echo "${colors[r]}ВНИМАНИЕ: правило относится к настроенному SSH-порту ($ssh_port).${colors[x]}"
        fi
        if [ -n "$ssh_session_port" ] && echo "$rule_line" | grep -qE "(^|[^0-9])${ssh_session_port}([^0-9]|$)"; then
            echo "${colors[r]}ВНИМАНИЕ: правило относится к порту текущей SSH-сессии ($ssh_session_port).${colors[x]}"
        fi
        if [ -n "$ssh_client_ip" ] && echo "$rule_line" | grep -qF "$ssh_client_ip"; then
            echo "${colors[r]}ВНИМАНИЕ: правило разрешает IP текущего SSH-клиента ($ssh_client_ip).${colors[x]}"
        fi

        if confirm_dangerous "Удалить правило номер $num?"; then
            ufw_run "Правило удалено." "Не удалось удалить правило." ufw --force delete "$num"
        else
            echo "${colors[c]}Отменено.${colors[x]}"
        fi
    done
}

# --- Правила портов ---
ufw_allow_port() {
    local port="$1" proto="$2" comment="$3" cmd
    cmd=(ufw allow "${port}/${proto}")
    [ -n "$comment" ] && cmd+=(comment "$comment")
    ufw_run "Разрешён порт ${port}/${proto}" "Не удалось разрешить порт ${port}/${proto}" "${cmd[@]}"
}

ufw_deny_port() {
    local port="$1" proto="$2" comment="$3" cmd
    cmd=(ufw deny "${port}/${proto}")
    [ -n "$comment" ] && cmd+=(comment "$comment")
    ufw_run "Запрещён порт ${port}/${proto}" "Не удалось запретить порт ${port}/${proto}" "${cmd[@]}"
}

ufw_allow_port_range() {
    ufw_run "Разрешён диапазон ${1}/${2}" "Не удалось разрешить диапазон ${1}/${2}" ufw allow "${1}/${2}"
}

ufw_deny_port_range() {
    ufw_run "Запрещён диапазон ${1}/${2}" "Не удалось запретить диапазон ${1}/${2}" ufw deny "${1}/${2}"
}

ufw_limit_port() {
    ufw_run "Порт ${1}/${2} ограничен (limit)" "Не удалось применить limit к ${1}/${2}" ufw limit "${1}/${2}"
}

ufw_ports_menu() {
    local c port range proto comment
    while true; do
        echo
        echo "${colors[g]}=== Правила портов ===${colors[x]}"
        echo "1. Разрешить порт"
        echo "2. Запретить порт"
        echo "3. Разрешить диапазон"
        echo "4. Запретить диапазон"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1)
                read -r -p "Порт (1-65535): " port
                if validate_port "$port"; then
                    proto=$(ufw_select_protocol)
                    read -r -p "Комментарий (можно пусто): " comment
                    if [ "$proto" = "tcp+udp" ]; then
                        ufw_allow_port "$port" tcp "$comment"
                        ufw_allow_port "$port" udp "$comment"
                    else
                        ufw_allow_port "$port" "$proto" "$comment"
                    fi
                else
                    echo "${colors[r]}Некорректный порт.${colors[x]}"
                fi
                ;;
            2)
                read -r -p "Порт (1-65535): " port
                if validate_port "$port"; then
                    if [ "$port" = "$ssh_port" ]; then
                        echo "${colors[r]}ВНИМАНИЕ: это настроенный SSH-порт ($ssh_port). Запрет заблокирует доступ по SSH.${colors[x]}"
                        confirm_dangerous "Всё равно запретить порт $port?" || { pause_menu; continue; }
                    fi
                    proto=$(ufw_select_protocol)
                    read -r -p "Комментарий (можно пусто): " comment
                    if [ "$proto" = "tcp+udp" ]; then
                        ufw_deny_port "$port" tcp "$comment"
                        ufw_deny_port "$port" udp "$comment"
                    else
                        ufw_deny_port "$port" "$proto" "$comment"
                    fi
                else
                    echo "${colors[r]}Некорректный порт.${colors[x]}"
                fi
                ;;
            3)
                read -r -p "Диапазон (напр. 6000:6010): " range
                proto=$(ufw_select_protocol)
                if [ "$proto" = "tcp+udp" ]; then
                    ufw_allow_port_range "$range" tcp
                    ufw_allow_port_range "$range" udp
                else
                    ufw_allow_port_range "$range" "$proto"
                fi
                ;;
            4)
                read -r -p "Диапазон (напр. 6000:6010): " range
                proto=$(ufw_select_protocol)
                if [ "$proto" = "tcp+udp" ]; then
                    ufw_deny_port_range "$range" tcp
                    ufw_deny_port_range "$range" udp
                else
                    ufw_deny_port_range "$range" "$proto"
                fi
                ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}
# --- IP и подсети ---
ufw_allow_ip() { ufw_run "Разрешён IP $1" "Не удалось разрешить IP $1" ufw allow from "$1"; }
ufw_deny_ip() { ufw_run "Заблокирован IP $1" "Не удалось заблокировать IP $1" ufw deny from "$1"; }
ufw_allow_subnet() { ufw_run "Разрешена подсеть $1" "Не удалось разрешить подсеть $1" ufw allow from "$1"; }
ufw_deny_subnet() { ufw_run "Заблокирована подсеть $1" "Не удалось заблокировать подсеть $1" ufw deny from "$1"; }

ufw_ip_to_port() {
    local action="$1" ip="$2" port="$3" proto="$4"
    ufw_run "Правило добавлено: $action from $ip to any port $port/$proto" "Не удалось добавить правило" \
        ufw "$action" from "$ip" to any port "$port" proto "$proto"
}

ufw_subnet_to_port() {
    local action="$1" subnet="$2" port="$3" proto="$4"
    ufw_run "Правило добавлено: $action from $subnet to any port $port/$proto" "Не удалось добавить правило" \
        ufw "$action" from "$subnet" to any port "$port" proto "$proto"
}

ufw_ip_menu() {
    local c ip sn port proto
    while true; do
        echo
        echo "${colors[g]}=== Правила IP / подсетей ===${colors[x]}"
        echo "1. Разрешить IP"
        echo "2. Заблокировать IP"
        echo "3. Разрешить подсеть"
        echo "4. Заблокировать подсеть"
        echo "5. Разрешить IP -> порт"
        echo "6. Заблокировать IP -> порт"
        echo "7. Разрешить подсеть -> порт"
        echo "8. Заблокировать подсеть -> порт"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) read -r -p "IP: " ip; { validate_ipv4 "$ip" || validate_ipv6 "$ip"; } && ufw_allow_ip "$ip" || echo "${colors[r]}Некорректный IP.${colors[x]}" ;;
            2)
                read -r -p "IP: " ip
                if { validate_ipv4 "$ip" || validate_ipv6 "$ip"; }; then
                    if [ -n "$ssh_client_ip" ] && [ "$ip" = "$ssh_client_ip" ]; then
                        echo "${colors[r]}ВНИМАНИЕ: это IP текущего SSH-клиента ($ssh_client_ip). Блокировка разорвёт вашу сессию.${colors[x]}"
                        confirm_dangerous "Всё равно заблокировать IP $ip?" && ufw_deny_ip "$ip"
                    else
                        ufw_deny_ip "$ip"
                    fi
                else
                    echo "${colors[r]}Некорректный IP.${colors[x]}"
                fi
                ;;
            3) read -r -p "Подсеть (CIDR): " sn; validate_cidr "$sn" && ufw_allow_subnet "$sn" || echo "${colors[r]}Некорректная подсеть.${colors[x]}" ;;
            4) read -r -p "Подсеть (CIDR): " sn; validate_cidr "$sn" && ufw_deny_subnet "$sn" || echo "${colors[r]}Некорректная подсеть.${colors[x]}" ;;
            5)
                read -r -p "IP: " ip; read -r -p "Порт: " port; proto=$(ufw_select_protocol)
                { validate_ipv4 "$ip" || validate_ipv6 "$ip"; } && validate_port "$port" && ufw_ip_to_port allow "$ip" "$port" "$proto" || echo "${colors[r]}Некорректные данные.${colors[x]}"
                ;;
            6)
                read -r -p "IP: " ip; read -r -p "Порт: " port; proto=$(ufw_select_protocol)
                { validate_ipv4 "$ip" || validate_ipv6 "$ip"; } && validate_port "$port" && ufw_ip_to_port deny "$ip" "$port" "$proto" || echo "${colors[r]}Некорректные данные.${colors[x]}"
                ;;
            7)
                read -r -p "Подсеть (CIDR): " sn; read -r -p "Порт: " port; proto=$(ufw_select_protocol)
                validate_cidr "$sn" && validate_port "$port" && ufw_subnet_to_port allow "$sn" "$port" "$proto" || echo "${colors[r]}Некорректные данные.${colors[x]}"
                ;;
            8)
                read -r -p "Подсеть (CIDR): " sn; read -r -p "Порт: " port; proto=$(ufw_select_protocol)
                validate_cidr "$sn" && validate_port "$port" && ufw_subnet_to_port deny "$sn" "$port" "$proto" || echo "${colors[r]}Некорректные данные.${colors[x]}"
                ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Правила интерфейсов ---
ufw_interface_rule() {
    local action="$1" direction="$2" iface="$3"
    if [ "$direction" = "in" ]; then
        ufw_run "Правило добавлено: $action in on $iface" "Не удалось добавить правило" ufw "$action" in on "$iface"
    else
        ufw_run "Правило добавлено: $action out on $iface" "Не удалось добавить правило" ufw "$action" out on "$iface"
    fi
}

ufw_interface_menu() {
    local c
    while true; do
        echo
        echo "${colors[g]}=== Правила интерфейсов ===${colors[x]}"
        echo "1. Allow IN on interface"
        echo "2. Deny IN on interface"
        echo "3. Allow OUT on interface"
        echo "4. Deny OUT on interface"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) network_select_interface && ufw_interface_rule allow in "$NET_SELECTED_IFACE" ;;
            2) network_select_interface && ufw_interface_rule deny in "$NET_SELECTED_IFACE" ;;
            3) network_select_interface && ufw_interface_rule allow out "$NET_SELECTED_IFACE" ;;
            4) network_select_interface && ufw_interface_rule deny out "$NET_SELECTED_IFACE" ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Исходящий трафик ---
ufw_outgoing_menu() {
    local c port ip proto
    while true; do
        echo
        echo "${colors[g]}=== Исходящий трафик ===${colors[x]}"
        echo "1. Разрешить исходящий порт"
        echo "2. Запретить исходящий порт"
        echo "3. Разрешить соединения к IP"
        echo "4. Запретить соединения к IP"
        echo "5. IP + destination port"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1)
                read -r -p "Порт: " port
                proto=$(ufw_select_protocol)
                validate_port "$port" && ufw_run "Разрешён исходящий порт $port/$proto" "Ошибка" ufw allow out "${port}/${proto}"
                ;;
            2)
                read -r -p "Порт: " port
                proto=$(ufw_select_protocol)
                echo "${colors[y]}Запрет исходящего трафика может нарушить работу сервисов (обновления, DNS и т.д.).${colors[x]}"
                confirm "Продолжить?" "n" || { pause_menu; continue; }
                validate_port "$port" && ufw_run "Запрещён исходящий порт $port/$proto" "Ошибка" ufw deny out "${port}/${proto}"
                ;;
            3)
                read -r -p "IP назначения: " ip
                { validate_ipv4 "$ip" || validate_ipv6 "$ip"; } && ufw_run "Разрешены исходящие к $ip" "Ошибка" ufw allow out to "$ip"
                ;;
            4)
                read -r -p "IP назначения: " ip
                echo "${colors[y]}Запрет исходящего трафика может нарушить работу сервисов.${colors[x]}"
                confirm "Продолжить?" "n" || { pause_menu; continue; }
                { validate_ipv4 "$ip" || validate_ipv6 "$ip"; } && ufw_run "Запрещены исходящие к $ip" "Ошибка" ufw deny out to "$ip"
                ;;
            5)
                read -r -p "IP назначения: " ip
                read -r -p "Порт назначения: " port
                proto=$(ufw_select_protocol)
                { validate_ipv4 "$ip" || validate_ipv6 "$ip"; } && validate_port "$port" && \
                    ufw_run "Разрешено: to $ip port $port/$proto" "Ошибка" ufw allow out to "$ip" port "$port" proto "$proto"
                ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Routed / Forward ---
ufw_route_rule() {
    local action="$1" src dst iface_in iface_out port cmd
    read -r -p "Source (CIDR, можно пусто = any): " src
    read -r -p "Destination (CIDR, можно пусто = any): " dst
    network_select_interface; iface_in="$NET_SELECTED_IFACE"
    read -r -p "Out interface (можно пусто): " iface_out
    read -r -p "Порт (можно пусто): " port

    if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
        echo "${colors[y]}IP forwarding сейчас отключён. Routed-правила UFW не будут иметь эффекта, пока forwarding не включён.${colors[x]}"
        confirm_dangerous "Включить net.ipv4.ip_forward?" && sysctl -w net.ipv4.ip_forward=1
    fi

    cmd=(ufw route "$action")
    [ -n "$src" ] && cmd+=(from "$src")
    [ -n "$dst" ] && cmd+=(to "$dst")
    [ -n "$iface_in" ] && cmd+=(in on "$iface_in")
    [ -n "$iface_out" ] && cmd+=(out on "$iface_out")
    [ -n "$port" ] && cmd+=(port "$port")

    echo "${colors[y]}Будет выполнено: ${cmd[*]}${colors[x]}"
    confirm "Продолжить?" "y" || return
    ufw_run "Routed-правило добавлено." "Ошибка добавления routed-правила." "${cmd[@]}"
}

ufw_routed_menu() {
    local c in_if out_if
    while true; do
        echo
        echo "${colors[g]}=== Routed / Forward ===${colors[x]}"
        ufw status verbose | grep -i routed
        echo "1. Показать routed policy"
        echo "2. Allow route"
        echo "3. Deny route"
        echo "4. Правило interface -> interface"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) ufw status verbose | grep -i routed ;;
            2) ufw_route_rule allow ;;
            3) ufw_route_rule deny ;;
            4)
                network_select_interface; in_if="$NET_SELECTED_IFACE"
                network_select_interface; out_if="$NET_SELECTED_IFACE"
                ufw_run "Route $in_if -> $out_if разрешён." "Ошибка." ufw route allow in on "$in_if" out on "$out_if"
                ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Защита SSH ---
ufw_protect_ssh() { ufw_allow_port "$ssh_port" tcp "SSH"; }
ufw_limit_ssh() { ufw_run "SSH TCP/$ssh_port ограничен (limit)." "Ошибка." ufw limit "${ssh_port}/tcp"; }

ufw_ssh_menu() {
    local c ip sn
    while true; do
        echo
        echo "${colors[g]}=== Защита SSH ===${colors[x]}"
        echo "Настроенный порт: $ssh_port"
        echo "1. Разрешить текущий SSH-порт"
        echo "2. Разрешить SSH только с определённого IP"
        echo "3. Разрешить SSH только из подсети"
        echo "4. Ограничить SSH через ufw limit"
        echo "5. Показать SSH-правила UFW"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) ufw_protect_ssh ;;
            2)
                read -r -p "IP-адрес: " ip
                if validate_ipv4 "$ip" || validate_ipv6 "$ip"; then
                    ufw_ip_to_port allow "$ip" "$ssh_port" tcp
                else
                    echo "${colors[r]}Некорректный IP.${colors[x]}"
                fi
                ;;
            3)
                read -r -p "Подсеть (CIDR): " sn
                if validate_cidr "$sn"; then
                    ufw_subnet_to_port allow "$sn" "$ssh_port" tcp
                else
                    echo "${colors[r]}Некорректная подсеть.${colors[x]}"
                fi
                ;;
            4)
                echo "${colors[y]}ufw limit ограничивает число подключений с одного IP за короткое время (защита от перебора паролей).${colors[x]}"
                confirm "Применить limit к SSH TCP/$ssh_port?" "y" && ufw_limit_ssh
                ;;
            5) ufw status numbered | grep -E "${ssh_port}/tcp|SSH" ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Профили приложений ---
ufw_app_list() { ufw app list; }
ufw_app_info() {
    local app
    read -r -p "Название профиля: " app
    ufw app info "$app"
}
ufw_app_allow() {
    local app
    ufw app list
    read -r -p "Название профиля для разрешения: " app
    ufw_run "Профиль $app разрешён." "Ошибка." ufw allow "$app"
}
ufw_app_delete() {
    local app
    ufw status numbered
    read -r -p "Название профиля для удаления правила: " app
    ufw_run "Правило профиля $app удалено." "Ошибка." ufw delete allow "$app"
}
ufw_app_menu() {
    local c
    while true; do
        echo
        echo "${colors[g]}=== Профили приложений ===${colors[x]}"
        echo "1. ufw app list"
        echo "2. Информация о профиле"
        echo "3. Разрешить профиль"
        echo "4. Удалить правило профиля"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) ufw_app_list ;;
            2) ufw_app_info ;;
            3) ufw_app_allow ;;
            4) ufw_app_delete ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Логирование ---
ufw_show_logging() { ufw status verbose | grep -i "Logging"; }
ufw_set_logging() {
    local lvl
    echo "Текущий уровень: $(ufw_show_logging)"
    echo "off low medium high full"
    read -r -p "Новый уровень логирования: " lvl
    case "$lvl" in
        off|low) ufw logging "$lvl" ;;
        medium|high|full)
            echo "${colors[y]}Внимание: уровень '$lvl' может создавать большой объём логов.${colors[x]}"
            confirm "Продолжить?" "n" && ufw logging "$lvl"
            ;;
        *) echo "${colors[r]}Неверный уровень.${colors[x]}"; return ;;
    esac
    echo "${colors[g]}[OK] Уровень логирования: $(ufw_show_logging)${colors[x]}"
}
ufw_logging_menu() {
    local c
    while true; do
        echo
        echo "${colors[g]}=== Логирование UFW ===${colors[x]}"
        ufw_show_logging
        echo "1. Изменить уровень логирования"
        echo "2. Показать последние записи UFW"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) ufw_set_logging ;;
            2)
                if [ -f /var/log/ufw.log ]; then
                    tail -n 50 /var/log/ufw.log
                else
                    journalctl -k -n 50 --no-pager 2>/dev/null | grep -i UFW
                fi
                ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Политики по умолчанию ---
ufw_show_default_policies() { ufw status verbose | grep -i "Default:"; }
ufw_set_default_policies() {
    local which target pc policy
    echo "${colors[c]}Текущие политики:${colors[x]}"
    ufw_show_default_policies
    echo
    echo "1. Incoming"
    echo "2. Outgoing"
    echo "3. Routed"
    read -r -p "Что изменить: " which
    case "$which" in
        1) target="incoming" ;;
        2) target="outgoing" ;;
        3) target="routed" ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}"; return ;;
    esac
    echo "1. allow"
    echo "2. deny"
    echo "3. reject"
    read -r -p "Новая политика: " pc
    case "$pc" in
        1) policy="allow" ;;
        2) policy="deny" ;;
        3) policy="reject" ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}"; return ;;
    esac
    if [ "$target" = "outgoing" ] && [ "$policy" != "allow" ]; then
        echo "${colors[r]}ВНИМАНИЕ: запрет исходящего трафика по умолчанию может нарушить работу сервера (обновления, DNS и т.д.).${colors[x]}"
        confirm_dangerous "Продолжить?" || return
    fi
    ufw_run "Политика $target установлена: $policy." "Не удалось изменить политику." ufw default "$policy" "$target"
}

# --- Расширенный конструктор правила ---
ufw_rule_builder() {
    echo "${colors[g]}=== Расширенный конструктор правила ===${colors[x]}"
    local action direction proto src dst sport dport iface comment a d p s ds cmd pattern_check

    echo "Действие: 1) ALLOW 2) DENY 3) REJECT 4) LIMIT"
    read -r -p "Выбор: " a
    case "$a" in
        1) action="allow" ;; 2) action="deny" ;; 3) action="reject" ;; 4) action="limit" ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}"; return ;;
    esac

    echo "Направление: 1) IN 2) OUT 3) ROUTE"
    read -r -p "Выбор: " d
    case "$d" in
        1) direction="in" ;; 2) direction="out" ;; 3) direction="route" ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}"; return ;;
    esac

    echo "Протокол: 1) TCP 2) UDP 3) ANY"
    read -r -p "Выбор: " p
    case "$p" in
        1) proto="tcp" ;; 2) proto="udp" ;; 3) proto="any" ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}"; return ;;
    esac

    echo "Source: 1) ANY 2) IP 3) CIDR"
    read -r -p "Выбор: " s
    case "$s" in
        1) src="any" ;;
        2) read -r -p "Source IP: " src; { validate_ipv4 "$src" || validate_ipv6 "$src"; } || { echo "${colors[r]}Некорректный IP.${colors[x]}"; return; } ;;
        3) read -r -p "Source CIDR: " src; validate_cidr "$src" || { echo "${colors[r]}Некорректный CIDR.${colors[x]}"; return; } ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}"; return ;;
    esac

    echo "Destination: 1) ANY 2) IP 3) CIDR"
    read -r -p "Выбор: " ds
    case "$ds" in
        1) dst="any" ;;
        2) read -r -p "Destination IP: " dst; { validate_ipv4 "$dst" || validate_ipv6 "$dst"; } || { echo "${colors[r]}Некорректный IP.${colors[x]}"; return; } ;;
        3) read -r -p "Destination CIDR: " dst; validate_cidr "$dst" || { echo "${colors[r]}Некорректный CIDR.${colors[x]}"; return; } ;;
        *) echo "${colors[r]}Неверный выбор.${colors[x]}"; return ;;
    esac

    read -r -p "Source port (можно пусто): " sport
    if [ -n "$sport" ] && ! validate_port "$sport"; then echo "${colors[r]}Некорректный source port.${colors[x]}"; return; fi
    read -r -p "Destination port (можно пусто): " dport
    if [ -n "$dport" ] && ! validate_port "$dport"; then echo "${colors[r]}Некорректный destination port.${colors[x]}"; return; fi
    read -r -p "Interface (можно пусто): " iface
    read -r -p "Comment (можно пусто): " comment

    echo
    echo "${colors[y]}Будет добавлено правило:${colors[x]}"
    echo
    echo "$(echo "$action" | tr '[:lower:]' '[:upper:]') $(echo "$direction" | tr '[:lower:]' '[:upper:]') $(echo "$proto" | tr '[:lower:]' '[:upper:]')"
    echo "FROM ${src}${sport:+ PORT $sport}"
    echo "TO ${dst}${dport:+ PORT $dport}"
    [ -n "$iface" ] && echo "INTERFACE $iface"
    [ -n "$comment" ] && echo "COMMENT $comment"
    echo

    pattern_check="${dport:-$sport}"
    if [ -n "$pattern_check" ] && ufw_rule_exists "${pattern_check}/${proto}.*$(echo "$action" | tr '[:lower:]' '[:upper:]')"; then
        echo "${colors[y]}Возможно похожее правило уже существует. Проверьте 'ufw status' перед продолжением.${colors[x]}"
    fi

    confirm "Продолжить?" "y" || { echo "${colors[c]}Отменено.${colors[x]}"; return; }

    cmd=(ufw)
    if [ "$direction" = "route" ]; then
        cmd+=(route "$action")
    else
        cmd+=("$action" "$direction")
        [ -n "$iface" ] && cmd+=(on "$iface")
    fi
    [ "$proto" != "any" ] && cmd+=(proto "$proto")
    cmd+=(from "$src")
    [ -n "$sport" ] && cmd+=(port "$sport")
    cmd+=(to "$dst")
    [ -n "$dport" ] && cmd+=(port "$dport")
    [ -n "$comment" ] && cmd+=(comment "$comment")

    ufw_run "Правило добавлено." "Не удалось добавить правило." "${cmd[@]}"
}

# --- Резервная копия / восстановление UFW ---
ufw_backup() {
    mkdir -p "$UFW_BACKUP_DIR"
    local dest
    dest="$UFW_BACKUP_DIR/ufw_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$dest"
    if cp -p /etc/ufw/user.rules /etc/ufw/user6.rules /etc/ufw/before.rules /etc/ufw/after.rules "$dest/" 2>/dev/null; then
        echo "${colors[g]}[OK] Резервная копия UFW создана: $dest${colors[x]}"
    else
        echo "${colors[r]}[ERROR] Не удалось создать полную резервную копию.${colors[x]}"
    fi
}

ufw_restore() {
    local backups=() i=1 b num chosen
    if [ ! -d "$UFW_BACKUP_DIR" ] || [ -z "$(ls -A "$UFW_BACKUP_DIR" 2>/dev/null)" ]; then
        echo "${colors[c]}Резервные копии не найдены.${colors[x]}"
        return
    fi
    backups=("$UFW_BACKUP_DIR"/*)
    for b in "${backups[@]}"; do
        echo "$i. $(basename "$b")"
        ((i++))
    done
    read -r -p "Номер резервной копии для восстановления: " num
    if [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#backups[@]}" ]; then
        echo "${colors[r]}Неверный номер.${colors[x]}"
        return
    fi
    chosen="${backups[$((num - 1))]}"
    if [ "$running_via_ssh" -eq 1 ]; then
        echo "${colors[y]}ВНИМАНИЕ: восстановление правил UFW из резервной копии может закрыть текущий доступ по SSH, если в бэкапе не было правила для порта $ssh_port.${colors[x]}"
    fi
    confirm_dangerous "Восстановить правила UFW из $chosen?" || return
    cp -p "$chosen"/* /etc/ufw/ 2>/dev/null
    ufw_run "Правила восстановлены и перезагружены." "Не удалось перезагрузить UFW после восстановления." ufw reload
}

ufw_backup_menu() {
    local c
    while true; do
        echo
        echo "${colors[g]}=== Резервная копия / восстановление UFW ===${colors[x]}"
        echo "1. Создать backup UFW"
        echo "2. Показать существующие backup"
        echo "3. Восстановить backup"
        echo "0. Назад"
        read -r -p "Выбор: " c
        case "$c" in
            1) ufw_backup ;;
            2) [ -d "$UFW_BACKUP_DIR" ] && ls -1 "$UFW_BACKUP_DIR" || echo "${colors[c]}Нет резервных копий.${colors[x]}" ;;
            3) ufw_restore ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
        pause_menu
    done
}

# --- Сводка состояния и главное меню UFW ---
ufw_show_summary() {
    local installed="нет" status="—" ipv6="—" logging="—" default_in default_out default_routed rules_count=0
    if ufw_is_installed; then
        installed="да"
        status=$(ufw status | awk -F': ' '/^Status/{print $2}')
        if grep -qi '^IPV6=yes' /etc/default/ufw 2>/dev/null; then ipv6="включён"; else ipv6="выключен"; fi
        logging=$(ufw_show_logging | awk -F': ' '{print $2}')
        default_in=$(ufw status verbose | grep -i "Default:" | sed -n 's/.*Default: \([a-z]*\) (incoming).*/\1/p')
        default_out=$(ufw status verbose | grep -i "Default:" | sed -n 's/.*, \([a-z]*\) (outgoing).*/\1/p')
        default_routed=$(ufw status verbose | grep -i "Default:" | sed -n 's/.*, \([a-z]*\) (routed).*/\1/p')
        rules_count=$(ufw status numbered | grep -c "^\[")
    fi

    echo "${colors[g]}=== UFW ===${colors[x]}"
    echo
    printf "%-18s%s\n" "Installed:" "$installed"
    printf "%-18s%s\n" "Status:" "$status"
    printf "%-18s%s\n" "Logging:" "$logging"
    printf "%-18s%s\n" "IPv6:" "$ipv6"
    echo
    echo "Default:"
    printf " %-17s%s\n" "incoming:" "${default_in:-—}"
    printf " %-17s%s\n" "outgoing:" "${default_out:-—}"
    printf " %-17s%s\n" "routed:" "${default_routed:-—}"
    echo
    printf "%-18s%s\n" "SSH configured:" "TCP/$ssh_port"
    [ -n "$ssh_session_port" ] && printf "%-18s%s\n" "SSH session:" "TCP/$ssh_session_port"
    [ -n "$ssh_client_ip" ] && printf "%-18s%s\n" "SSH client:" "$ssh_client_ip"
    echo
    printf "%-18s%s\n" "Rules:" "$rules_count"
}

ufw_menu() {
    local c
    if ! ufw_is_installed; then
        if confirm "UFW не установлен. Установить?" "y"; then
            ufw_install || return
        else
            return
        fi
    fi
    while true; do
        clear
        ufw_show_summary
        echo
        echo "1.  Управление UFW"
        echo "2.  Показать правила"
        echo "3.  Правила портов"
        echo "4.  Правила IP / подсетей"
        echo "5.  Удалить правило"
        echo "6.  Правила интерфейсов"
        echo "7.  Исходящий трафик"
        echo "8.  Routed / Forward"
        echo "9.  Защита SSH"
        echo "10. Профили приложений"
        echo "11. Логирование"
        echo "12. Политики по умолчанию"
        echo "13. Расширенный конструктор правила"
        echo "14. Резервная копия / восстановление"
        echo "0.  Назад"
        read -r -p "${colors[y]}Выбор:${colors[x]} " c
        case "$c" in
            1) ufw_service_menu ;;
            2) ufw_show_verbose_status; pause_menu ;;
            3) ufw_ports_menu ;;
            4) ufw_ip_menu ;;
            5) ufw_delete_rule ;;
            6) ufw_interface_menu ;;
            7) ufw_outgoing_menu ;;
            8) ufw_routed_menu ;;
            9) ufw_ssh_menu ;;
            10) ufw_app_menu ;;
            11) ufw_logging_menu ;;
            12) ufw_set_default_policies; pause_menu ;;
            13) ufw_rule_builder; pause_menu ;;
            14) ufw_backup_menu ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
    done
}

configure_ufw() {
    ufw_menu
}

# =========================================================
# 09. НАСТРОЙКА ПОЛЬЗОВАТЕЛЕЙ
# =========================================================
add_new_user() {
    echo "${colors[g]}Добавление пользователя${colors[x]}"
    local login_dir="${PWD}/login"
    mkdir -p "$login_dir"
    chmod 700 "$login_dir"

    local existing_files=()
    while IFS= read -r -d '' file; do
        existing_files+=("$file")
    done < <(find "$login_dir" -maxdepth 1 -name '*_temp_*.txt' -print0 2>/dev/null | sort -z)
    local total_files=${#existing_files[@]}

    if [ "$total_files" -gt 0 ]; then
        echo "${colors[c]}Найдены сохранённые данные для входа ($total_files):${colors[x]}"
        echo ""
        for i in "${!existing_files[@]}"; do
            echo "$((i + 1))) $(basename "${existing_files[$i]}")"
        done
        echo ""
        while true; do
            read -r -p "Показать содержимое файла (введи номер или Enter для пропуска): " file_choice
            if [ -z "$file_choice" ]; then
                echo "${colors[g]}Пропускаем просмотр.${colors[x]}"
                break
            elif [[ "$file_choice" =~ ^[0-9]+$ ]] && [ "$file_choice" -ge 1 ] && [ "$file_choice" -le "$total_files" ]; then
                local selected_index=$((file_choice - 1))
                local selected_file="${existing_files[$selected_index]}"
                if [ -f "$selected_file" ]; then
                    echo ""
                    echo "${colors[g]}=== $(basename "$selected_file") ===${colors[x]}"
                    cat "$selected_file"
                    echo ""
                    if confirm "${colors[y]}Показать ещё один файл?${colors[x]}" "n"; then
                        continue
                    else
                        break
                    fi
                else
                    echo "${colors[r]}Файл не найден.${colors[x]}"
                fi
            else
                echo "${colors[r]}Неверный номер. Введите 1-$total_files или Enter для пропуска.${colors[x]}"
            fi
        done
        echo ""
    fi

    if confirm "Хотите добавить нового пользователя?" "n"; then
        mapfile -t all_users < <(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | sort)
        local total_users=${#all_users[@]}

        if [ "$total_users" -gt 0 ]; then
            echo "${colors[c]}Существующие пользователи в системе ($total_users):${colors[x]}"
            local per_page=36 cols=3 page=0
            local total_pages=$(( (total_users + per_page - 1) / per_page ))
            while true; do
                clear
                echo "${colors[g]}=== Существующие пользователи (страница $((page + 1)) из $total_pages) ===${colors[x]}"
                echo "---------------------------------"
                local start=$((page * per_page))
                local page_users=("${all_users[@]:$start:$per_page}")
                local page_count=${#page_users[@]}
                local col_size=$(( (page_count + cols - 1) / cols ))
                for row in $(seq 0 $((col_size - 1))); do
                    local line=""
                    for col in $(seq 0 $((cols - 1))); do
                        local idx=$((col * col_size + row))
                        if [ "$idx" -lt "$page_count" ]; then
                            local user="${page_users[$idx]}"
                            local sudo_mark=""
                            if id -nG "$user" 2>/dev/null | grep -qw "sudo"; then
                                sudo_mark="${colors[y]}*${colors[x]}"
                            fi
                            line+=$(printf "%-15s" "$user$sudo_mark")
                        fi
                    done
                    echo "$line"
                done
                echo "---------------------------------"
                echo "${colors[c]}* = пользователь в группе sudo${colors[x]}"
                echo ""
                if [ "$total_pages" -gt 1 ]; then
                    echo "Навигация: [N]ext [B]ack [Q]Продолжить"
                    read -r -p "Выберите действие: " nav_choice
                    case $nav_choice in
                        [Nn])
                            if [ $((page + 1)) -lt "$total_pages" ]; then ((page++)); else echo "${colors[r]}Это последняя страница.${colors[x]}"; sleep 1; fi
                            ;;
                        [Bb])
                            if [ "$page" -gt 0 ]; then ((page--)); else echo "${colors[r]}Это первая страница.${colors[x]}"; sleep 1; fi
                            ;;
                        [Qq]) break ;;
                        *) echo "${colors[r]}Неверный ввод. Продолжаем...${colors[x]}"; sleep 1; break ;;
                    esac
                else
                    echo "${colors[g]}Все пользователи показаны. Нажмите Enter для продолжения...${colors[x]}"
                    read -r
                    break
                fi
            done
        else
            echo "${colors[r]}В системе нет обычных пользователей.${colors[x]}"
        fi

        clear
        echo "${colors[g]}=== Создание нового пользователя ===${colors[x]}"
        while true; do
            read -r -p "Введите имя: " new_user
            if [[ "$new_user" =~ ^[a-zA-Z0-9_]+$ ]] && ! id -u "$new_user" >/dev/null 2>&1; then
                break
            else
                echo "${colors[r]}Неверное имя или пользователь существует.${colors[x]}"
            fi
        done

        while true; do
            read -s -r -p "Введите пароль: " new_user_password; echo
            read -s -r -p "Повторите пароль: " new_user_password_confirm; echo
            [ -n "$new_user_password" ] && [ "$new_user_password" = "$new_user_password_confirm" ] && break
            echo "${colors[r]}Пароли не совпадают или пустые.${colors[x]}"
        done

        useradd -m -s /bin/bash "$new_user"
        chpasswd <<< "$new_user:$new_user_password"
        chage -d 0 "$new_user"

        local user_ssh_dir="/home/$new_user/.ssh"
        mkdir -p "$user_ssh_dir"
        local user_key_path="$user_ssh_dir/id_rsa"
        ssh-keygen -t rsa -b 4096 -C "$new_user@$currhostname" -f "$user_key_path" -N "" >/dev/null 2>&1

        local user_ppk_path=""
        if command -v puttygen >/dev/null 2>&1; then
            user_ppk_path="$user_ssh_dir/$new_user.ppk"
            puttygen "$user_key_path" -o "$user_ppk_path" 2>/dev/null
        fi

        chmod 700 "$user_ssh_dir"
        chmod 600 "$user_key_path"
        [ -f "$user_ppk_path" ] && chmod 600 "$user_ppk_path"
        cat "$user_key_path.pub" > "$user_ssh_dir/authorized_keys"
        chmod 600 "$user_ssh_dir/authorized_keys"
        chown -R "$new_user:$new_user" "$user_ssh_dir"

        local pass_file="${login_dir}/${new_user}_temp_${DATE}.txt"
        {
            echo "=== Временные данные для входа ==="
            echo "Дата: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Пользователь: $new_user"
            echo "Пароль: $new_user_password"
            echo "SSH Ключ (private): $user_key_path"
            [ -n "$user_ppk_path" ] && echo "SSH Ключ (PPK): $user_ppk_path"
            echo "==================================="
        } > "$pass_file"
        chmod 600 "$pass_file"

        echo -e "${colors[y]}Данные для '$new_user' сохранены в: ${pass_file}${colors[x]}"
        echo -e "${colors[r]}СКАЧАЙТЕ ЭТОТ ФАЙЛ И УДАЛИТЕ ЕГО С СЕРВЕРА!${colors[x]}"
        echo -e "${colors[r]}WARNING: this file contains a plaintext password and points to an unencrypted private key ($user_key_path). Download it and delete it (and the key) from the server!${colors[x]}"
        unset new_user_password

        local old_files=()
        for f in "$login_dir"/"${new_user}"_temp_*.txt; do
            [ -e "$f" ] || continue
            [[ "$f" != "$pass_file" ]] && old_files+=("$f")
        done
        if [ "${#old_files[@]}" -gt 0 ]; then
            echo "${colors[r]}Найдены старые файлы для '$new_user':${colors[x]}"
            printf '  %s\n' "${old_files[@]}"
            if confirm "Удалить старые файлы?" "y"; then
                rm -f "${old_files[@]}"
                echo "${colors[g]}Старые файлы удалены.${colors[x]}"
            fi
        fi

        if confirm "${colors[y]}Добавить пользователя '$new_user' в группу sudo?${colors[x]}" "y"; then
            if getent group sudo >/dev/null; then
                usermod -aG sudo "$new_user"
                echo "${colors[y]}Пользователь добавлен в группу sudo.${colors[x]}"
            else
                echo "${colors[r]}Группа sudo не найдена. Пропускаем.${colors[x]}"
            fi
        fi

        mkdir -p "/home/$new_user"/{.config,.local/share}
        chown -R "$new_user:$new_user" "/home/$new_user"

        if confirm "Создать дополнительные папки (backup projects)?${colors[x]}" "n"; then
            read -r -p "Папки через пробел: " custom_folders
            for folder in $custom_folders; do
                mkdir -p "/home/$new_user/$folder"
                chown "$new_user:$new_user" "/home/$new_user/$folder"
            done
        fi

        touch "/home/$new_user/.bashrc"
        chown "$new_user:$new_user" "/home/$new_user/.bashrc"
        echo "${colors[y]}Пользователь '$new_user' настроен и готов к входу по ключу.${colors[x]}"
    fi
}

# =========================================================
# 10. НАСТРОЙКА FAIL2BAN
# =========================================================
setup_fail2ban() {
    echo "${colors[g]}Установка и настройка fail2ban${colors[x]}"
    local local_jail="/etc/fail2ban/jail.local"
    local local_jail_d="/etc/fail2ban/jail.d"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "${colors[r]}Fail2ban не найден в системе.${colors[x]}"
        if confirm "${colors[y]}Установить fail2ban?${colors[x]}" "n"; then
            echo "${colors[y]}Устанавливаем fail2ban...${colors[x]}"
            if apt-get update && apt-get install -y fail2ban; then
                if ! command -v fail2ban-client >/dev/null 2>&1; then
                    echo "${colors[r]}Ошибка: fail2ban не установлен после выполнения команды.${colors[x]}"
                    return 1
                fi
                echo "${colors[g]}Fail2ban успешно установлен.${colors[x]}"
                echo "${colors[g]}$(fail2ban-client version)${colors[x]}"
            else
                echo "${colors[r]}Ошибка при установке fail2ban.${colors[x]}"
                return 1
            fi
        else
            echo "${colors[c]}Установка отменена пользователем.${colors[x]}"
            return 0
        fi
    else
        echo "${colors[g]}Fail2ban обнаружен в системе.${colors[x]}"
    fi

    get_all_protected_ports() {
        local ports_list=""
        [ -f "$local_jail" ] && ports_list+="$(grep -E "^port\s*=" "$local_jail" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')"$'\n'
        if [ -d "$local_jail_d" ]; then
            for conf in "$local_jail_d"/*.conf; do
                [ -f "$conf" ] || continue
                ports_list+="$(grep -E "^port\s*=" "$conf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')"$'\n'
            done
        fi
        echo "$ports_list" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -u
    }

    check_port_conflicts() {
        local new_ports="$1"
        local existing_ports
        existing_ports=$(get_all_protected_ports)
        local conflicts=""
        for port in $(echo "$new_ports" | tr ',' '\n'); do
            if echo "$existing_ports" | grep -qx "$port"; then
                conflicts+="$port "
            fi
        done
        echo "$conflicts"
    }

    find_rule_by_port() {
        local search_port="$1"
        local found_file=""
        if [ -d "$local_jail_d" ]; then
            for conf in "$local_jail_d"/*.conf; do
                [ -f "$conf" ] || continue
                local ports
                ports=$(grep -E "^port\s*=" "$conf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
                if echo "$ports" | tr ',' '\n' | grep -qx "$search_port"; then
                    found_file="$conf"
                    break
                fi
            done
        fi
        if [ -z "$found_file" ] && [ -f "$local_jail" ]; then
            local ports
            ports=$(grep -E "^port\s*=" "$local_jail" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            if echo "$ports" | tr ',' '\n' | grep -qx "$search_port"; then
                found_file="$local_jail"
            fi
        fi
        echo "$found_file"
    }

    mkdir -p "$local_jail_d"

    if [ ! -f "$local_jail" ]; then
        {
            echo "[DEFAULT]"
            echo "bantime  = 10h"
            echo "findtime  = 20m"
            echo "maxretry = 5"
            echo "ignoreip = 127.0.0.1/8 ::1"
        } > "$local_jail"
        echo "${colors[g]}Создан базовый конфиг: $local_jail${colors[x]}"
    fi

    while true; do
        clear
        local fail2ban_version
        fail2ban_version="$(fail2ban-client version)"
        echo "${colors[y]}=== Управление Fail2Ban ===${colors[x]}"
        echo "${colors[g]}Текущая версия: ${colors[r]}$fail2ban_version${colors[x]}"
        echo ""
        echo "${colors[c]}Текущие активные правила:${colors[x]}"
        local has_rules=false
        if [ -f "$local_jail" ]; then
            local jail_ports
            jail_ports=$(grep -E "^port\s*=" "$local_jail" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            if [ -n "$jail_ports" ]; then
                echo "  - jail.local: порты $jail_ports"
                has_rules=true
            fi
        fi
        if [ -d "$local_jail_d" ]; then
            for conf in "$local_jail_d"/*.conf; do
                [ -f "$conf" ] || continue
                local conf_name; conf_name=$(basename "$conf")
                local conf_ports
                conf_ports=$(grep -E "^port\s*=" "$conf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
                if [ -n "$conf_ports" ]; then
                    echo "  - $conf_name: порты $conf_ports"
                    has_rules=true
                fi
            done
        fi
        [ "$has_rules" = false ] && echo "  (нет правил)"
        echo ""
        echo "${colors[y]}Выберите действие:${colors[x]}"
        echo "1) Добавить новое правило для порта/сервиса"
        echo "2) Удалить правило"
        echo "3) Выйти в главное меню"
        echo ""
        read -r -p "Ваш выбор: " action_choice

        case $action_choice in
            1)
                echo ""
                echo "${colors[c]}Добавить новое правило для:${colors[x]}"
                echo "1) SSH (порт $ssh_port)"
                echo "2) Web (80, 443)"
                echo "3) Почта (25, 465, 587)"
                echo "4) Ввести порт вручную"
                read -r -p "Выберите вариант (1-4): " port_choice
                local jail_name="" jail_port="" jail_log=""
                case $port_choice in
                    1) jail_name="sshd"; jail_port="$ssh_port"; jail_log="%(sshd_log)s" ;;
                    2)
                        jail_name="webserver-auth"
                        jail_port="80,443"
                        # Определяем активный веб-сервер для правильного пути к логу
                        if command -v angie &>/dev/null; then
                            jail_log="/var/log/angie/error.log"
                        elif command -v apache2 &>/dev/null; then
                            jail_log="/var/log/apache2/error.log"
                        else
                            jail_log="/var/log/syslog"
                        fi
                        ;;
                    3) jail_name="postfix"; jail_port="25,465,587"; jail_log="/var/log/mail.log" ;;
                    4)
                        read -r -p "Введите имя правила (латиница, напр. myapp): " jail_name
                        [ -z "$jail_name" ] && jail_name="custom"
                        read -r -p "Введите порт(ы) через запятую: " jail_port
                        read -r -p "Путь к логу (напр. /var/log/syslog): " jail_log
                        [ -z "$jail_log" ] && jail_log="/var/log/syslog"
                        ;;
                esac

                if [ -n "$jail_port" ]; then
                    local conflicts
                    conflicts=$(check_port_conflicts "$jail_port")
                    if [ -n "$conflicts" ]; then
                        echo ""
                        echo "${colors[r]}ВНИМАНИЕ: Обнаружены конфликты портов!${colors[x]}"
                        echo "Следующие порты уже защищены:"
                        for conflict_port in $conflicts; do
                            local conflict_file
                            conflict_file=$(find_rule_by_port "$conflict_port")
                            echo "  - Порт $conflict_port в файле: ${conflict_file:-unknown}"
                        done
                        echo ""
                        echo "${colors[y]}Выберите действие:${colors[x]}"
                        echo "1) Заменить старое правило (удалить конфликтующее)"
                        echo "2) Добавить всё равно (риск конфликта)"
                        echo "3) Отменить"
                        read -r -p "Ваш выбор: " conflict_choice
                        case $conflict_choice in
                            1)
                                for conflict_port in $conflicts; do
                                    local conflict_file
                                    conflict_file=$(find_rule_by_port "$conflict_port")
                                    if [ -n "$conflict_file" ] && [ -f "$conflict_file" ]; then
                                        echo "${colors[c]}Удаляем: $conflict_file${colors[x]}"
                                        cp "$conflict_file" "${conflict_file}_${DATE}.backup"
                                        rm "$conflict_file"
                                    fi
                                done
                                echo "${colors[g]}Конфликтующие правила удалены.${colors[x]}"
                                ;;
                            2) echo "${colors[r]}Добавляем с риском конфликта.${colors[x]}" ;;
                            3)
                                echo "${colors[c]}Отмена.${colors[x]}"
                                read -r -p "Нажмите Enter для продолжения..."
                                continue
                                ;;
                        esac
                    fi
                fi

                local rule_file="${local_jail_d}/${jail_name}.conf"
                [ -f "$rule_file" ] && cp "$rule_file" "${rule_file}_${DATE}.bak"
                {
                    echo "[${jail_name}]"
                    echo "enabled = true"
                    echo "port = $jail_port"
                    echo "logpath = $jail_log"
                    echo "backend = systemd"
                    echo "maxretry = 5"
                    echo "bantime = 10h"
                } > "$rule_file"
                echo "${colors[g]}Правило создано: $rule_file${colors[x]}"
                echo ""
                cat "$rule_file"
                echo ""

                if confirm "${colors[y]}Применить и перезапустить fail2ban?${colors[x]}" "y"; then
                    fail2ban-client reload
                    sleep 3
                    if systemctl is-active --quiet fail2ban; then
                        echo "${colors[y]}Fail2ban перезапущен.${colors[x]}"
                        fail2ban-client status 2>/dev/null || echo "${colors[c]}Статус недоступен.${colors[x]}"
                    else
                        echo "${colors[r]}Ошибка запуска.${colors[x]}"
                    fi
                else
                    echo "${colors[r]}Конфигурация не применена.${colors[x]}"
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                local all_conf_files=()
                [ -f "$local_jail" ] && all_conf_files+=("$local_jail")
                if [ -d "$local_jail_d" ]; then
                    for conf in "$local_jail_d"/*.conf; do
                        [ -f "$conf" ] && all_conf_files+=("$conf")
                    done
                fi
                if [ "${#all_conf_files[@]}" -eq 0 ]; then
                    echo "${colors[r]}Нет правил для удаления.${colors[x]}"
                    read -r -p "Нажмите Enter для продолжения..."
                    continue
                fi
                echo ""
                echo "${colors[c]}Выберите файл для удаления:${colors[x]}"
                for i in "${!all_conf_files[@]}"; do
                    echo "  $((i + 1))) ${all_conf_files[$i]}"
                done
                echo "  0) Отмена"
                echo ""
                read -r -p "Введите номер: " del_choice
                if [[ "$del_choice" =~ ^[0-9]+$ ]] && [ "$del_choice" -ge 1 ] && [ "$del_choice" -le "${#all_conf_files[@]}" ]; then
                    local del_index=$((del_choice - 1))
                    local del_file="${all_conf_files[$del_index]}"
                    if [ -f "$del_file" ]; then
                        echo ""
                        echo "${colors[r]}Содержимое файла:${colors[x]}"
                        echo "---------------------------------"
                        cat "$del_file"
                        echo "---------------------------------"
                        echo ""
                        if confirm "${colors[r]}Удалить этот файл?${colors[x]}" "n"; then
                            cp "$del_file" "${del_file}_${DATE}.deleted"
                            rm "$del_file"
                            echo "${colors[g]}Файл удалён (бэкап сохранён).${colors[x]}"
                            if confirm "${colors[y]}Перезапустить fail2ban?${colors[x]}" "y"; then
                                systemctl restart fail2ban
                                sleep 3
                                systemctl is-active --quiet fail2ban && echo "${colors[y]}Fail2ban перезапущен.${colors[x]}"
                            fi
                        else
                            echo "${colors[c]}Удаление отменено.${colors[x]}"
                        fi
                    fi
                else
                    echo "${colors[r]}Неверный номер.${colors[x]}"
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            3)
                echo "${colors[g]}Выход в главное меню.${colors[x]}"
                break
                ;;
            *)
                echo "${colors[r]}Неверный выбор.${colors[x]}"
                read -r -p "Нажмите Enter для продолжения..."
                ;;
        esac
    done
}

# =========================================================
# 11. НАСТРОЙКА MOTD
# =========================================================

# --- Состояние и конфигурация ---
motd_is_installed() { [ -f "$MOTD_SCRIPT" ]; }

motd_status() {
    if [ ! -f "$MOTD_SCRIPT" ]; then
        echo "NOT INSTALLED"
    elif [ -x "$MOTD_SCRIPT" ]; then
        echo "ENABLED"
    else
        echo "DISABLED"
    fi
}

motd_load_config() {
    local opt val
    for opt in "${MOTD_OPTIONS[@]}"; do
        MOTD_VALUES[$opt]=1
    done
    if [ -f "$MOTD_CONFIG" ]; then
        for opt in "${MOTD_OPTIONS[@]}"; do
            val=$(grep -E "^${opt}=" "$MOTD_CONFIG" 2>/dev/null | tail -n1 | cut -d= -f2)
            [[ "$val" =~ ^[01]$ ]] && MOTD_VALUES[$opt]="$val"
        done
    fi
}

motd_save_config() {
    {
        echo "SHOW_HOSTNAME=${MOTD_VALUES[SHOW_HOSTNAME]}"
        echo "SHOW_OS=${MOTD_VALUES[SHOW_OS]}"
        echo "SHOW_KERNEL=${MOTD_VALUES[SHOW_KERNEL]}"
        echo "SHOW_UPTIME=${MOTD_VALUES[SHOW_UPTIME]}"
        echo
        echo "SHOW_NETWORK=${MOTD_VALUES[SHOW_NETWORK]}"
        echo "SHOW_SSH_PORT=${MOTD_VALUES[SHOW_SSH_PORT]}"
        echo
        echo "SHOW_LOAD=${MOTD_VALUES[SHOW_LOAD]}"
        echo "SHOW_MEMORY=${MOTD_VALUES[SHOW_MEMORY]}"
        echo "SHOW_DISK=${MOTD_VALUES[SHOW_DISK]}"
        echo
        echo "SHOW_UFW=${MOTD_VALUES[SHOW_UFW]}"
        echo "SHOW_FAIL2BAN=${MOTD_VALUES[SHOW_FAIL2BAN]}"
        echo
        echo "SHOW_TIME=${MOTD_VALUES[SHOW_TIME]}"
        echo
        echo "USE_COLORS=${MOTD_VALUES[USE_COLORS]}"
    } > "$MOTD_CONFIG"
    chmod 644 "$MOTD_CONFIG"
}

# Единый механизм изменения одного параметра — только через whitelist MOTD_OPTIONS
motd_set_option() {
    local name="$1" value="$2"
    [[ " ${MOTD_OPTIONS[*]} " == *" $name "* ]] || return 1
    [[ "$value" =~ ^[01]$ ]] || return 1
    MOTD_VALUES[$name]="$value"
    motd_save_config
}

motd_toggle_item() {
    local name="$1" new
    if [ "${MOTD_VALUES[$name]}" = "1" ]; then new=0; else new=1; fi
    motd_set_option "$name" "$new"
}

motd_enable_all() {
    local opt
    for opt in "${MOTD_OPTIONS[@]}"; do
        MOTD_VALUES[$opt]=1
    done
    motd_save_config
}

motd_disable_all() {
    local opt
    for opt in "${MOTD_OPTIONS[@]}"; do
        [ "$opt" = "USE_COLORS" ] && continue
        MOTD_VALUES[$opt]=0
    done
    motd_save_config
}

motd_restore_defaults() { motd_enable_all; }

# --- Генерация системного скрипта /etc/update-motd.d/20-server-info ---
motd_write_script() {
    cat > "$MOTD_SCRIPT" <<'MOTD_SCRIPT_EOF'
#!/bin/bash
# =========================================================
# Dynamic MOTD - Server Information
# Сгенерировано setup.sh. Настраивается через setup.sh (MOTD),
# ручные правки этого файла будут перезаписаны при переустановке.
# =========================================================

CONFIG_FILE="/etc/default/server-info-motd"

SHOW_HOSTNAME=1
SHOW_OS=1
SHOW_KERNEL=1
SHOW_UPTIME=1
SHOW_NETWORK=1
SHOW_SSH_PORT=1
SHOW_LOAD=1
SHOW_MEMORY=1
SHOW_DISK=1
SHOW_UFW=1
SHOW_FAIL2BAN=1
SHOW_TIME=1
USE_COLORS=1

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/etc/default/server-info-motd
    . "$CONFIG_FILE"
fi

if [ "$USE_COLORS" = "1" ]; then
    RESET='\033[0m'
    BOLD='\033[1m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    RED='\033[31m'
    CYAN='\033[36m'
else
    RESET=''
    BOLD=''
    GREEN=''
    YELLOW=''
    RED=''
    CYAN=''
fi

group_system=0
[ "$SHOW_HOSTNAME" = "1" ] && group_system=1
[ "$SHOW_OS" = "1" ] && group_system=1
[ "$SHOW_KERNEL" = "1" ] && group_system=1
[ "$SHOW_UPTIME" = "1" ] && group_system=1

group_network=0
[ "$SHOW_NETWORK" = "1" ] && group_network=1
[ "$SHOW_SSH_PORT" = "1" ] && group_network=1

group_resources=0
[ "$SHOW_LOAD" = "1" ] && group_resources=1
[ "$SHOW_MEMORY" = "1" ] && group_resources=1
[ "$SHOW_DISK" = "1" ] && group_resources=1

group_security=0
[ "$SHOW_UFW" = "1" ] && group_security=1
[ "$SHOW_FAIL2BAN" = "1" ] && group_security=1

group_time=0
[ "$SHOW_TIME" = "1" ] && group_time=1

if [ "$group_system" = "0" ] && [ "$group_network" = "0" ] && [ "$group_resources" = "0" ] && \
   [ "$group_security" = "0" ] && [ "$group_time" = "0" ]; then
    exit 0
fi

# ---------------------------------------------------------
# System
# ---------------------------------------------------------

if [ "$SHOW_HOSTNAME" = "1" ]; then
    HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)
fi

if [ "$SHOW_OS" = "1" ]; then
    OS_VAL=$(
        awk -F= '
            $1 == "PRETTY_NAME" {
                sub(/^"/, "", $2)
                sub(/"$/, "", $2)
                print $2
                exit
            }
        ' /etc/os-release 2>/dev/null
    )
    OS_VAL=${OS_VAL:-Unknown}
fi

[ "$SHOW_KERNEL" = "1" ] && KERNEL_VAL=$(uname -r)

if [ "$SHOW_UPTIME" = "1" ]; then
    UPTIME_VAL=$(uptime -p 2>/dev/null)
    UPTIME_VAL=${UPTIME_VAL#up }
    UPTIME_VAL=${UPTIME_VAL:-N/A}
fi

# ---------------------------------------------------------
# Network
# ---------------------------------------------------------

if [ "$SHOW_NETWORK" = "1" ]; then
    DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -n 1)
    DEFAULT_IF=$(awk '{print $5}' <<< "$DEFAULT_ROUTE")
    GATEWAY=$(awk '{print $3}' <<< "$DEFAULT_ROUTE")

    if [ -n "$DEFAULT_IF" ]; then
        IPV4=$(
            ip -4 -o addr show dev "$DEFAULT_IF" scope global 2>/dev/null |
            awk 'NR == 1 {print $4}'
        )
    fi

    DEFAULT_IF=${DEFAULT_IF:-N/A}
    IPV4=${IPV4:-N/A}
    GATEWAY=${GATEWAY:-N/A}

    NETWORK_INFO="$DEFAULT_IF | $IPV4 | GW $GATEWAY"
fi

if [ "$SHOW_SSH_PORT" = "1" ]; then
    SSH_PORT_VAL=$(
        sshd -T 2>/dev/null |
        awk '$1 == "port" {print $2; exit}'
    )
    SSH_PORT_VAL=${SSH_PORT_VAL:-22}
fi

# ---------------------------------------------------------
# Resources
# ---------------------------------------------------------

[ "$SHOW_LOAD" = "1" ] && LOAD_VAL=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
[ "$SHOW_LOAD" = "1" ] && LOAD_VAL=${LOAD_VAL:-N/A}

if [ "$SHOW_MEMORY" = "1" ]; then
    read -r MEM_TOTAL MEM_USED < <(
        free -h 2>/dev/null |
        awk '/^Mem:/ {print $2, $3}'
    )
    MEM_TOTAL=${MEM_TOTAL:-N/A}
    MEM_USED=${MEM_USED:-N/A}
fi

if [ "$SHOW_DISK" = "1" ]; then
    read -r DISK_TOTAL DISK_USED DISK_PERCENT < <(
        df -hP / 2>/dev/null |
        awk 'NR == 2 {print $2, $3, $5}'
    )
    DISK_TOTAL=${DISK_TOTAL:-N/A}
    DISK_USED=${DISK_USED:-N/A}
    DISK_PERCENT=${DISK_PERCENT:-N/A}
fi

# ---------------------------------------------------------
# Security
# ---------------------------------------------------------

if [ "$SHOW_UFW" = "1" ]; then
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q '^Status: active'; then
            UFW_STATUS="ACTIVE"
            UFW_COLOR="$GREEN"
        else
            UFW_STATUS="INACTIVE"
            UFW_COLOR="$RED"
        fi
    else
        UFW_STATUS="not installed"
        UFW_COLOR="$YELLOW"
    fi
fi

if [ "$SHOW_FAIL2BAN" = "1" ]; then
    if command -v fail2ban-client >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            F2B_STATUS="ACTIVE"
            F2B_COLOR="$GREEN"
            JAILS=$(timeout 1 fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}')
            if [ -n "$JAILS" ]; then
                JAIL_COUNT=$(echo "$JAILS" | tr ',' '\n' | grep -c '[^[:space:]]')
                [ "$JAIL_COUNT" -gt 0 ] && F2B_STATUS="ACTIVE ($JAIL_COUNT jails)"
            fi
        else
            F2B_STATUS="INACTIVE"
            F2B_COLOR="$RED"
        fi
    else
        F2B_STATUS="not installed"
        F2B_COLOR="$YELLOW"
    fi
fi

# ---------------------------------------------------------
# Time
# ---------------------------------------------------------

[ "$SHOW_TIME" = "1" ] && CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ---------------------------------------------------------
# Output helpers
# ---------------------------------------------------------

print_border() {
    printf '%b+--------------------------------------------------------------+%b\n' \
        "$CYAN" "$RESET"
}

print_row() {
    local label="$1"
    local value="$2"

    printf '%b|%b %-14s %-45s %b|%b\n' \
        "$CYAN" "$RESET" "$label" "$value" "$CYAN" "$RESET"
}

print_status_row() {
    local label="$1"
    local value="$2"
    local color="$3"

    printf '%b|%b %-14s %b%-45s%b %b|%b\n' \
        "$CYAN" "$RESET" \
        "$label" \
        "$color" "$value" "$RESET" \
        "$CYAN" "$RESET"
}

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------

printf '\n'

print_border

printf '%b|%b                 %bSERVER INFORMATION%b                           %b|%b\n' \
    "$CYAN" "$RESET" "$BOLD" "$RESET" "$CYAN" "$RESET"

print_border

if [ "$group_system" = "1" ]; then
    [ "$SHOW_HOSTNAME" = "1" ] && print_row "Hostname:" "$HOSTNAME_VAL"
    [ "$SHOW_OS" = "1" ] && print_row "OS:" "$OS_VAL"
    [ "$SHOW_KERNEL" = "1" ] && print_row "Kernel:" "$KERNEL_VAL"
    [ "$SHOW_UPTIME" = "1" ] && print_row "Uptime:" "$UPTIME_VAL"
    print_border
fi

if [ "$group_network" = "1" ]; then
    [ "$SHOW_NETWORK" = "1" ] && print_row "Network:" "$NETWORK_INFO"
    [ "$SHOW_SSH_PORT" = "1" ] && print_row "SSH port:" "$SSH_PORT_VAL"
    print_border
fi

if [ "$group_resources" = "1" ]; then
    [ "$SHOW_LOAD" = "1" ] && print_row "Load:" "$LOAD_VAL"
    [ "$SHOW_MEMORY" = "1" ] && print_row "Memory:" "$MEM_USED / $MEM_TOTAL"
    [ "$SHOW_DISK" = "1" ] && print_row "Disk /:" "$DISK_USED / $DISK_TOTAL ($DISK_PERCENT)"
    print_border
fi

if [ "$group_security" = "1" ]; then
    [ "$SHOW_UFW" = "1" ] && print_status_row "UFW:" "$UFW_STATUS" "$UFW_COLOR"
    [ "$SHOW_FAIL2BAN" = "1" ] && print_status_row "Fail2Ban:" "$F2B_STATUS" "$F2B_COLOR"
    print_border
fi

if [ "$group_time" = "1" ]; then
    print_row "Time:" "$CURRENT_TIME"
    print_border
fi

printf '\n'
MOTD_SCRIPT_EOF
    chmod 755 "$MOTD_SCRIPT"
}

motd_offer_disable_10uname() {
    local f="$MOTD_UPDATE_DIR/10-uname"
    if [ -f "$f" ] && [ -x "$f" ]; then
        echo
        echo "${colors[y]}Обнаружен стандартный MOTD: 10-uname${colors[x]}"
        echo "Он может выводить дополнительную строку uname перед Server Information."
        if confirm "Отключить 10-uname?" "n"; then
            chmod -x "$f"
            echo "${colors[g]}[OK] 10-uname отключён (chmod -x).${colors[x]}"
        fi
    fi
}

motd_install() {
    echo "${colors[g]}Установка Server Information MOTD${colors[x]}"
    mkdir -p "$MOTD_UPDATE_DIR"

    if [ -f "$MOTD_SCRIPT" ]; then
        local backup
        backup=$(backup_file "$MOTD_SCRIPT")
        [ -n "$backup" ] && echo "${colors[y]}Резервная копия: $backup${colors[x]}"
    fi

    motd_write_script

    if [ -f "$MOTD_CONFIG" ]; then
        echo "${colors[c]}Найдена существующая конфигурация: $MOTD_CONFIG (оставлена без изменений).${colors[x]}"
        motd_load_config
    else
        motd_restore_defaults
        echo "${colors[y]}Создана конфигурация по умолчанию: $MOTD_CONFIG${colors[x]}"
    fi

    local errfile
    errfile=$(mktemp)
    trap 'rm -f "$errfile"' RETURN
    if bash -n "$MOTD_SCRIPT" 2>"$errfile"; then
        echo "${colors[g]}[OK] MOTD установлен: $MOTD_SCRIPT${colors[x]}"
    else
        echo "${colors[r]}[ERROR] Синтаксическая ошибка в сгенерированном MOTD:${colors[x]}"
        cat "$errfile"
        return 1
    fi

    motd_offer_disable_10uname
}

motd_enable() {
    if ! motd_is_installed; then
        echo "${colors[r]}MOTD не установлен. Сначала выполните установку.${colors[x]}"
        return 1
    fi
    chmod +x "$MOTD_SCRIPT"
    echo "${colors[g]}[OK] MOTD включён.${colors[x]}"
}

motd_disable() {
    if ! motd_is_installed; then
        echo "${colors[r]}MOTD не установлен.${colors[x]}"
        return 1
    fi
    chmod -x "$MOTD_SCRIPT"
    echo "${colors[g]}[OK] MOTD отключён (файл и настройки сохранены).${colors[x]}"
}

motd_remove() {
    if ! motd_is_installed && [ ! -f "$MOTD_CONFIG" ]; then
        echo "${colors[c]}MOTD не установлен.${colors[x]}"
        return
    fi
    confirm_dangerous "Удалить Server Information MOTD и его настройки?" || return
    rm -f "$MOTD_SCRIPT" "$MOTD_CONFIG"
    echo "${colors[g]}[OK] MOTD и его конфигурация удалены.${colors[x]}"
}

motd_preview() {
    if ! motd_is_installed; then
        echo "${colors[r]}MOTD ещё не установлен.${colors[x]}"
        return 1
    fi
    echo "${colors[g]}=== Preview ===${colors[x]}"
    echo
    bash "$MOTD_SCRIPT"
}

motd_show_status() {
    motd_load_config
    echo "${colors[g]}=== Текущие настройки MOTD ===${colors[x]}"
    echo "Статус:       $(motd_status)"
    echo "Файл:         $MOTD_SCRIPT"
    echo "Конфигурация: $MOTD_CONFIG"
    echo
    local opt
    for opt in "${MOTD_OPTIONS[@]}"; do
        if [ "${MOTD_VALUES[$opt]}" = "1" ]; then
            printf "  %-16s %s\n" "$opt" "${colors[g]}ON${colors[x]}"
        else
            printf "  %-16s %s\n" "$opt" "${colors[r]}OFF${colors[x]}"
        fi
    done
}

# --- Меню выбора отображаемых пунктов ---
motd_item_line() {
    local num="$1" name="$2" label="$3" state
    if [ "${MOTD_VALUES[$name]}" = "1" ]; then state="[ON ]"; else state="[OFF]"; fi
    printf "%s %2d. %s\n" "$state" "$num" "$label"
}

motd_items_menu() {
    local c
    while true; do
        motd_load_config
        clear
        echo "${colors[g]}=== Отображаемые пункты MOTD ===${colors[x]}"
        echo
        motd_item_line 1 SHOW_HOSTNAME "Hostname"
        motd_item_line 2 SHOW_OS "OS"
        motd_item_line 3 SHOW_KERNEL "Kernel"
        motd_item_line 4 SHOW_UPTIME "Uptime"
        echo
        motd_item_line 5 SHOW_NETWORK "Network"
        motd_item_line 6 SHOW_SSH_PORT "SSH port"
        echo
        motd_item_line 7 SHOW_LOAD "Load average"
        motd_item_line 8 SHOW_MEMORY "Memory"
        motd_item_line 9 SHOW_DISK "Disk /"
        echo
        motd_item_line 10 SHOW_UFW "UFW"
        motd_item_line 11 SHOW_FAIL2BAN "Fail2Ban"
        echo
        motd_item_line 12 SHOW_TIME "Date / Time"
        echo
        motd_item_line 13 USE_COLORS "Colors"
        echo
        echo "14. Включить всё"
        echo "15. Отключить всё"
        echo "16. Восстановить рекомендуемые настройки"
        echo
        echo "0. Назад"
        read -r -p "${colors[y]}Выбор:${colors[x]} " c
        case "$c" in
            1) motd_toggle_item SHOW_HOSTNAME ;;
            2) motd_toggle_item SHOW_OS ;;
            3) motd_toggle_item SHOW_KERNEL ;;
            4) motd_toggle_item SHOW_UPTIME ;;
            5) motd_toggle_item SHOW_NETWORK ;;
            6) motd_toggle_item SHOW_SSH_PORT ;;
            7) motd_toggle_item SHOW_LOAD ;;
            8) motd_toggle_item SHOW_MEMORY ;;
            9) motd_toggle_item SHOW_DISK ;;
            10) motd_toggle_item SHOW_UFW ;;
            11) motd_toggle_item SHOW_FAIL2BAN ;;
            12) motd_toggle_item SHOW_TIME ;;
            13) motd_toggle_item USE_COLORS ;;
            14) motd_enable_all ;;
            15) motd_disable_all ;;
            16) confirm "Восстановить рекомендуемые настройки?" "y" && motd_restore_defaults ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
    done
}

# --- Управление другими MOTD-скриптами в /etc/update-motd.d ---
motd_other_scripts_menu() {
    local files=() f name state choice i
    while true; do
        clear
        echo "${colors[g]}=== /etc/update-motd.d ===${colors[x]}"
        echo
        files=()
        for f in "$MOTD_UPDATE_DIR"/*; do
            [ -f "$f" ] || continue
            files+=("$f")
        done
        if [ "${#files[@]}" -eq 0 ]; then
            echo "${colors[c]}Файлы не найдены.${colors[x]}"
            pause_menu
            return
        fi
        i=1
        for f in "${files[@]}"; do
            name=$(basename "$f")
            if [ -x "$f" ]; then state="[ON ]"; else state="[OFF]"; fi
            printf "%s %2d. %s\n" "$state" "$i" "$name"
            ((i++))
        done
        echo
        echo "Введите номер для переключения."
        echo "0. Назад"
        read -r -p "${colors[y]}Выбор:${colors[x]} " choice
        if [ "$choice" = "0" ]; then return; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
            f="${files[$((choice - 1))]}"
            if [ -x "$f" ]; then
                chmod -x "$f"
                echo "${colors[g]}[OK] $(basename "$f") отключён.${colors[x]}"
            else
                chmod +x "$f"
                echo "${colors[g]}[OK] $(basename "$f") включён.${colors[x]}"
            fi
            pause_menu
        else
            echo "${colors[r]}Неверный выбор.${colors[x]}"
            pause_menu
        fi
    done
}

# --- Главное меню MOTD ---
motd_menu() {
    local c status status_color
    while true; do
        motd_load_config
        clear
        status=$(motd_status)
        case "$status" in
            ENABLED) status_color="${colors[g]}" ;;
            DISABLED) status_color="${colors[r]}" ;;
            *) status_color="${colors[y]}" ;;
        esac
        echo "${colors[g]}=== Server MOTD ===${colors[x]}"
        echo
        echo "Статус: ${status_color}${status}${colors[x]}"
        echo "Файл:   $MOTD_SCRIPT"
        echo
        echo "1. Подключить / обновить MOTD"
        echo "2. Включить MOTD"
        echo "3. Отключить MOTD"
        echo "4. Настроить отображаемые пункты"
        echo "5. Предпросмотр"
        echo "6. Показать текущие настройки"
        echo "7. Восстановить настройки по умолчанию"
        echo "8. Удалить MOTD"
        echo "9. Управление другими MOTD-скриптами"
        echo "0. Назад"
        read -r -p "${colors[y]}Выбор:${colors[x]} " c
        case "$c" in
            1) motd_install; pause_menu ;;
            2) motd_enable; pause_menu ;;
            3) motd_disable; pause_menu ;;
            4) motd_items_menu ;;
            5) motd_preview; pause_menu ;;
            6) motd_show_status; pause_menu ;;
            7) confirm_dangerous "Восстановить рекомендуемые настройки MOTD?" && motd_restore_defaults; pause_menu ;;
            8) motd_remove; pause_menu ;;
            9) motd_other_scripts_menu ;;
            0) return ;;
            *) echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
        esac
    done
}

# =========================================================
# 12. ВНЕШНИЕ УСТАНОВЩИКИ
# =========================================================
setup_lamp() {
echo "${colors[g]}Настройка LAMP/LEMP${colors[x]}"
local lamp_dir="${PWD}"
local lamp_script="${lamp_dir}/lamp.sh"
# Скачиваем если нет или предлагаем обновить
if [ -f "$lamp_script" ]; then
echo "${colors[y]}Найден существующий lamp.sh: $lamp_script${colors[x]}"
if confirm "${colors[y]}Скачать актуальную версию с GitHub?${colors[x]}" "n"; then
if wget -q --timeout=30 -O "${lamp_script}.new" "$LAMP_URL" 2>/dev/null && [ -s "${lamp_script}.new" ]; then
cp "$lamp_script" "${lamp_script}.bak_${DATE}"
mv "${lamp_script}.new" "$lamp_script"
echo "${colors[g]}Обновлён. Старая версия: ${lamp_script}.bak_${DATE}${colors[x]}"
else
rm -f "${lamp_script}.new"
echo "${colors[r]}Ошибка загрузки. Используем существующий скрипт.${colors[x]}"
fi
fi
else
echo "${colors[c]}Скачиваю lamp.sh с GitHub...${colors[x]}"
if wget -q --timeout=30 -O "$lamp_script" "$LAMP_URL" 2>/dev/null && [ -s "$lamp_script" ]; then
echo "${colors[g]}Загружено: $lamp_script${colors[x]}"
else
rm -f "$lamp_script"
echo "${colors[r]}Ошибка загрузки lamp.sh с GitHub.${colors[x]}"
echo "${colors[y]}Проверьте доступ к: $LAMP_URL${colors[x]}"
return 1
fi
fi
chmod +x "$lamp_script"
echo ""
echo "${colors[g]}Запуск lamp.sh...${colors[x]}"
echo "${colors[c]}Скрипт останется в: $lamp_script${colors[x]}"
echo ""
bash "$lamp_script"
}

# =========================================================
# 13. ОБСЛУЖИВАНИЕ СИСТЕМЫ
# =========================================================
clean_apt_cache() {
    echo "${colors[g]}Очистка системного кэша${colors[x]}"
    if confirm "${colors[y]}Очистить кэш и историю?${colors[x]}" "n"; then
        apt-get clean 2>/dev/null
        rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*
        if [ -n "$BASH" ]; then
            history -c
            [ -f ~/.bash_history ] && cat /dev/null > ~/.bash_history
        fi
        echo "${colors[y]}Готово!${colors[x]}"
    fi
}

reboot_system() {
    echo "${colors[g]}Завершение настройки${colors[x]}"
    if confirm "${colors[r]}Перезагрузить систему?${colors[x]}" "n"; then
        reboot
    fi
}

# =========================================================
# 14. ГЛАВНОЕ МЕНЮ
# =========================================================

# Первоначальное определение состояния SSH (настроенный порт, сессия)
refresh_ssh_state

while true; do
    clear
    echo "${colors[g]}=== Настройка Debian/Ubuntu ===${colors[x]}"
    echo "${colors[r]}Задайте предварительно пароль для root командой 'sudo passwd root'.${colors[x]}"
    echo
    echo "${colors[y]}Выберите номер нужного пункта:${colors[x]}"
    echo
    echo "${colors[c]}1.${colors[x]}  ${colors[g]}Установка ПО${colors[x]}"
    echo "${colors[c]}2.${colors[x]}  ${colors[g]}Настройка сети${colors[x]}"
    echo "${colors[c]}3.${colors[x]}  ${colors[g]}Изменить локаль${colors[x]}"
    echo "${colors[c]}4.${colors[x]}  ${colors[g]}Настройка расположения${colors[x]}"
    echo "${colors[c]}5.${colors[x]}  ${colors[g]}Настроить SSH-ключи${colors[x]}"
    echo "${colors[c]}6.${colors[x]}  ${colors[g]}Изменить порт SSH${colors[x]}"
    echo "${colors[c]}7.${colors[x]}  ${colors[g]}Установить и настроить UFW${colors[x]}"
    echo "${colors[c]}8.${colors[x]}  ${colors[g]}Добавить пользователя${colors[x]}"
    echo "${colors[c]}9.${colors[x]}  ${colors[g]}Настроить Fail2Ban${colors[x]}"
    echo "${colors[c]}10.${colors[x]} ${colors[g]}Настройка вывода информации в консоль SSH через MOTD${colors[x]}"
    echo "${colors[c]}11.${colors[x]} ${colors[g]}Настройка LAMP/LEMP${colors[x]}"
    echo "${colors[c]}12.${colors[x]} ${colors[g]}Очистить apt кеш и историю${colors[x]}"
    echo "${colors[c]}13.${colors[x]} ${colors[g]}Перезагрузить систему${colors[x]}"
    echo "${colors[c]}0.${colors[x]}  Выход"
    echo
    read -r -p "${colors[y]}Введите номер:${colors[x]} " choice
    case $choice in
        1)  software_menu ;;
        2)  network_menu ;;
        3)  setup_locale; pause_menu ;;
        4)  location_menu ;;
        5)  setup_ssh_keys; pause_menu ;;
        6)  change_ssh_port; pause_menu ;;
        7)  configure_ufw ;;
        8)  add_new_user; pause_menu ;;
        9)  setup_fail2ban ;;
        10) motd_menu ;;
        11) setup_lamp; pause_menu ;;
        12) clean_apt_cache; pause_menu ;;
        13) reboot_system; pause_menu ;;
        0)  exit 0 ;;
        *)  echo "${colors[r]}Неверный выбор.${colors[x]}"; pause_menu ;;
    esac
done
