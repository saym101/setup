#!/bin/bash
# wget https://raw.githubusercontent.com/saym101/setup/main/setup.sh
clear
shopt -s extglob

# === 0. Проверка прав ===
if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт должен быть запущен от имени root."
    echo "Перезапустите его командой: sudo bash $0"
    exit 1
fi

# === Переменные ===
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
standard_packages="curl git sudo htop iotop ncdu mc zip unzip 7zip dnsutils net-tools nmap iproute2 ca-certificates gnupg chrony openssh-server openssh-client lynx rsync"
chrony_servers="0.ru.pool.ntp.org 1.ru.pool.ntp.org 2.ru.pool.ntp.org 3.ru.pool.ntp.org"

# Читаем текущий порт из sshd_config
ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshconfigfile" | awk '{print $2}' | head -n 1)
if [ -z "$ssh_port" ]; then
    ssh_port=22
fi

# Логирование
LOG_FILE="${PWD}/$(basename "$0" .sh)_${DATE}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# === Функции ===
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

# 1. Hostname
setup_hostname() {
    echo "${colors[g]}1] Установка hostname${colors[x]}"
    local current_hostname
    current_hostname=$(hostname)
    echo "Текущее имя хоста: $current_hostname"
    if confirm "${colors[y]}Хотите изменить имя хоста?${colors[x]}" "n"; then
        while true; do
            read -r -p "Введите новое имя хоста: " new_hostname
            if [[ -n "$new_hostname" && "$new_hostname" =~ ^[a-zA-Z0-9-]+$ ]]; then
                break
            else
                echo "${colors[r]}Имя хоста должно содержать только буквы, цифры и дефисы, и не быть пустым.${colors[x]}"
            fi
        done
        echo "$new_hostname" > /etc/hostname
        sed -i "s/^127\.0\.1\.1[[:space:]]\+.*$/127.0.1.1\t$new_hostname/" /etc/hosts
        hostname "$new_hostname"
        echo "${colors[y]}Имя хоста успешно изменено на $new_hostname.${colors[x]}"
    else
        echo "${colors[r]}Отмена изменения имени хоста.${colors[x]}"
    fi
}

# 2. Locale
setup_locale() {
    echo "${colors[g]}2] Устанавливаем корректную локаль...${colors[x]}"
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

# 3. Timezone
setup_timezone() {
    echo "${colors[g]}3] Настройка часового пояса${colors[x]}"
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

# 4. Software
setup_software() {
    echo "${colors[g]}4] Установка минимального набора ПО${colors[x]}"
    if confirm "${colors[y]}Установить набор программ?${colors[x]}" "n"; then
        echo "${colors[r]}Предварительный список программ:${colors[x]}"
        echo "$standard_packages"
        while true; do
            read -r -e -i "$standard_packages" -p "${colors[y]}Список программ можно изменить(добавить или удалить) или оставить как есть:${colors[x]} " user_input
            if [[ -n "$user_input" ]]; then
                break
            fi
        done
        echo "${colors[y]}Обновление списка пакетов...${colors[x]}"
        apt-get update
        # Читаем строку в массив — каждый пакет отдельным элементом
        read -r -a pkg_array <<< "$user_input"
        if ! apt-get install -y "${pkg_array[@]}"; then
            echo "${colors[r]}Ошибка при установке пакетов.${colors[x]}"
        fi
        [ -f /usr/share/mc/syntax/sh.syntax ] && cp /usr/share/mc/syntax/sh.syntax /usr/share/mc/syntax/unknown.syntax
        echo "${colors[y]}Установка завершена.${colors[x]}"
    else
        echo "${colors[r]}Установка отменена.${colors[x]}"
    fi
}

# 5. Chrony
setup_chrony() {
    echo "${colors[g]}5] Настройка Chrony${colors[x]}"
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

# 6. SSH Keys
setup_ssh_keys() {
    echo "${colors[g]}6] Настройка доступа через SSH-ключи.${colors[x]}"
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

# 7. SSH Port
change_ssh_port() {
    echo "${colors[g]}7] Изменение порта для SSH...${colors[x]}"
    local current_ssh_port
    current_ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshconfigfile" | awk '{print $2}')
    [ -z "$current_ssh_port" ] && current_ssh_port=22
    echo "${colors[c]}Текущий порт: $current_ssh_port. Введите новый (22, 1025-49150) или Enter для случайного:${colors[x]}"
    read -r -p "${colors[y]}Ваш выбор: ${colors[x]}" new_port_input
    [ -z "$new_port_input" ] && new_port_input="y"
    if [[ "$new_port_input" =~ ^[Yy]$ ]]; then
        ssh_port=$(( RANDOM % 48126 + 1025 ))
    elif [[ "$new_port_input" =~ ^[0-9]+$ ]] && { [ "$new_port_input" -eq 22 ] || { [ "$new_port_input" -ge 1025 ] && [ "$new_port_input" -le 49150 ]; }; }; then
        ssh_port=$new_port_input
    else
        echo "${colors[r]}Ошибка ввода. Порт не изменён.${colors[x]}"
        return
    fi
    sed -i "/^#*Port /c\\Port $ssh_port" "$sshconfigfile" || echo "Port $ssh_port" >> "$sshconfigfile"
    systemctl restart ssh
    echo "${colors[y]}Порт SSH изменён на $ssh_port.${colors[x]}"
}

# 8. UFW
configure_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        if confirm "UFW не установлен. Установить?" "n"; then
            echo "${colors[y]}Устанавливаем UFW...${colors[x]}"
            if apt-get update && apt-get install -y ufw; then
                if ! command -v ufw >/dev/null 2>&1; then
                    echo "${colors[r]}Ошибка: UFW не установлен после выполнения команды. Выход.${colors[x]}"
                    return 1
                fi
                echo "${colors[g]}UFW успешно установлен.${colors[x]}"
            else
                echo "${colors[r]}Ошибка при установке UFW.${colors[x]}"
                return 1
            fi
        else
            echo "${colors[c]}Установка отменена пользователем.${colors[x]}"
            return 0
        fi
    else
        echo "${colors[g]}UFW обнаружен в системе. Переход к настройке.${colors[x]}"
    fi
    while true; do
        clear
        echo "${colors[g]}=== Управление брандмауэром UFW ===${colors[x]}"
        echo "Статус: $(ufw status | grep "Status" | awk '{print $2}')"
        echo "---------------------------------"
        echo "1) Включить UFW (с защитой текущего SSH порта)"
        echo "2) Показать текущие правила (status numbered)"
        echo "3) Открыть порт (Allow)"
        echo "4) Закрыть/Запретить порт (Deny)"
        echo "5) Удалить правило по номеру"
        echo "6) Сбросить все настройки (Reset)"
        echo "7) Отключить UFW"
        echo "0) Назад в главное меню"
        echo "---------------------------------"
        read -r -p "Выберите действие: " ufw_choice
        case $ufw_choice in
            1)
                ufw allow "$ssh_port"/tcp
                ufw --force enable
                echo "${colors[g]}UFW включен. Доступ по порту $ssh_port разрешен.${colors[x]}"
                ;;
            2) ufw status numbered ;;
            3)
                read -r -p "Введите порт или название сервиса (напр. 80 или http): " p_allow
                ufw allow "$p_allow"
                ;;
            4)
                read -r -p "Введите порт для запрета: " p_deny
                ufw deny "$p_deny"
                ;;
            5)
                ufw status numbered
                read -r -p "Введите НОМЕР правила для удаления: " p_del
                ufw delete "$p_del"
                ;;
            6)
                if confirm "${colors[r]}Вы уверены, что хотите сбросить ВСЕ правила?${colors[x]}" "n"; then
                    ufw reset
                fi
                ;;
            7)
                if confirm "${colors[r]}Вы уверены, что хотите отключить UFW?${colors[x]}" "n"; then
                    ufw disable
                fi
                ;;
            0) break ;;
            *) echo "Неверный выбор" ;;
        esac
        read -r -p "Нажмите Enter, чтобы продолжить..."
    done
}

# 9. Add User
add_new_user() {
    echo "${colors[g]}9] Добавление пользователя${colors[x]}"
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
        echo "$new_user:$new_user_password" | chpasswd
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

# 10. Fail2ban
setup_fail2ban() {
    echo "${colors[g]}10] Установка и настройка fail2ban${colors[x]}"
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
        echo "1) Добавить защиту нового порта/сервиса"
        echo "2) Удалить правило"
        echo "3) Выйти в главное меню"
        echo ""
        read -r -p "Ваш выбор: " action_choice

        case $action_choice in
            1)
                echo ""
                echo "${colors[c]}Добавить защиту для:${colors[x]}"
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

# 11. LAMP Setup
setup_lamp() {
echo "${colors[g]}11] Настройка LAMP/LEMP${colors[x]}"
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

# 12. Clean cache
clean_apt_cache() {
    echo "${colors[g]}12] Очистка системного кэша${colors[x]}"
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

# 13. Reboot
reboot_system() {
    echo "${colors[g]}13] Завершение настройки${colors[x]}"
    if confirm "${colors[r]}Перезагрузить систему?${colors[x]}" "n"; then
        reboot
    fi
}

# === Main Menu ===
while true; do
    clear
    echo "${colors[g]}Настройка Debian/Ubuntu${colors[x]}"
    echo "${colors[r]}Задайте предварительно пароль для root командой 'sudo passwd root'.${colors[x]}"
    echo
    echo "${colors[y]}Выберите номер нужного пункта:${colors[x]}"
    echo
    echo "${colors[c]}1.${colors[x]}  ${colors[g]}Установить минимальный набор ПО${colors[x]}"   
    echo "${colors[c]}2.${colors[x]}  ${colors[g]}Изменить hostname${colors[x]}"
    echo "${colors[c]}3.${colors[x]}  ${colors[g]}Изменить локаль${colors[x]}"
    echo "${colors[c]}4.${colors[x]}  ${colors[g]}Изменить часовой пояс${colors[x]}"
    echo "${colors[c]}5.${colors[x]}  ${colors[g]}Настроить Chrony${colors[x]}"
    echo "${colors[c]}6.${colors[x]}  ${colors[g]}Настроить SSH ключи${colors[x]}"
    echo "${colors[c]}7.${colors[x]}  ${colors[g]}Изменить порт SSH${colors[x]}"
    echo "${colors[c]}8.${colors[x]}  ${colors[g]}Настроить UFW${colors[x]}"
    echo "${colors[c]}9.${colors[x]}  ${colors[g]}Добавить пользователя${colors[x]}"
    echo "${colors[c]}10.${colors[x]} ${colors[g]}Настроить fail2ban (Защита от взлома)${colors[x]}"
    echo "${colors[c]}11.${colors[x]} ${colors[g]}Настройка LAMP/LEMP${colors[x]}"
    echo "${colors[c]}12.${colors[x]} ${colors[g]}Очистить apt кеш и историю${colors[x]}"
    echo "${colors[c]}13.${colors[x]} ${colors[g]}Перезагрузить систему${colors[x]}"
    echo "${colors[c]}0.${colors[x]}  Выход"
    echo
    read -r -p "${colors[y]}Введите номер:${colors[x]} " choice
    case $choice in
        1)  setup_software ;;    
        2)  setup_hostname ;;
        3)  setup_locale ;;
        4)  setup_timezone ;;
        5)  setup_chrony ;;
        6)  setup_ssh_keys ;;
        7)  change_ssh_port ;;
        8)  configure_ufw ;;
        9)  add_new_user ;;
        10) setup_fail2ban ;;
        11) setup_lamp ;;
        12) clean_apt_cache ;;
        13) reboot_system ;;
        0)  exit 0 ;;
        *)  echo "${colors[r]}Неверный выбор.${colors[x]}" ;;
    esac
    read -r -p "${colors[y]}Нажмите Enter для продолжения...${colors[x]}"
done
