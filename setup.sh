#!/bin/bash
clear

# === Переменные ===
declare -A colors=(
    [r]=$(tput setaf 1)  # красный
    [g]=$(tput setaf 2)  # зеленый
    [y]=$(tput setaf 3)  # желтый
    [c]=$(tput setaf 6)  # циановый
    [p]=$(tput setaf 5)  # фиолетовый
    [x]=$(tput sgr0)     # сброс цвета
    [b]=$(tput bold)     # жирный текст
)

currhostname=$(cat /etc/hostname)
authorizedfile="/root/.ssh/authorized_keys"
sshconfigfile="/etc/ssh/sshd_config"
DATE=$(date "+%Y-%m-%d")
standard_packages="curl gnupg mc ufw htop iftop net-tools ca-certificates lynx openssh-server openssh-client chrony"
chrony_servers="
0.ru.pool.ntp.org
1.ru.pool.ntp.org
2.ru.pool.ntp.org
3.ru.pool.ntp.org"
# Читаем текущий порт из sshd_config при запуске
ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshconfigfile" | awk '{print $2}' | head -n 1)
if [ -z "$ssh_port" ]; then
    ssh_port=22  # Если порт не указан в конфиге, предполагаем 22
fi

# Логирование в текущую директорию
LOG_FILE="${PWD}/$(basename "$0" .sh)_${DATE}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# === Функции ===

# Функция для запроса подтверждения с обработкой ошибок и валидацией ввода
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

# 1. Функция для установки hostname
setup_hostname() {
    echo "${colors[g]}1] Установка hostname${colors[x]}"
    local current_hostname=$(hostname)
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
        sed -i "s/^\(127\.0\.1\.1\)\s.*$/\1 $new_hostname/" /etc/hosts
        hostname "$new_hostname"
        echo "${colors[y]}Имя хоста успешно изменено на $new_hostname.${colors[x]}"
    else
        echo "${colors[r]}Отмена изменения имени хоста.${colors[x]}"
    fi
}

# 2. Функция для установки локали
setup_locale() {
    echo "${colors[g]}2] Устанавливаем корректную локаль...${colors[x]}"
    echo "${colors[g]}Текущая локаль:${colors[x]}"
    local current_locale=$(locale | grep "^LANG=" | cut -d'=' -f2 | tr -d '"')
    echo "LANG=$current_locale"

    if confirm "${colors[y]}Меняем локаль?${colors[x]}" "n"; then
        # Предлагаемая по умолчанию локаль
        local default_locale="ru_RU.UTF-8"

        # Проверяем, совпадает ли текущая локаль с предлагаемой по умолчанию
        if [ "$current_locale" = "$default_locale" ]; then
            echo "${colors[y]}Текущая локаль уже установлена как '$default_locale'.${colors[x]}"
            if confirm "${colors[y]}Всё равно хотите ввести другую локаль?${colors[x]}" "n"; then
                # Если пользователь хочет сменить, переходим к вводу
                :
            else
                echo "${colors[r]}Изменение локали отменено, так как текущая локаль уже соответствует умолчанию.${colors[x]}"
                return
            fi
        fi

        while true; do
            read -r -p "Введите желаемую локаль (по умолчанию $default_locale, Enter для отмены): " new_locale

            # Если строка пустая, считаем это отказом
            if [ -z "$new_locale" ]; then
                echo "${colors[r]}Изменение локали отменено (ввод пустой).${colors[x]}"
                return
            fi

            # Проверяем, доступна ли введённая локаль
            if locale -a | grep -Fx "$new_locale" > /dev/null; then
                # Если локаль найдена, проверяем, не совпадает ли она с текущей
                if [ "$new_locale" = "$current_locale" ]; then
                    echo "${colors[y]}Локаль '$new_locale' уже установлена в системе.${colors[x]}"
                    if confirm "${colors[y]}Всё равно применить её заново?${colors[x]}" "n"; then
                        break
                    else
                        echo "${colors[r]}Изменение локали отменено.${colors[x]}"
                        return
                    fi
                else
                    break
                fi
            else
                echo "${colors[r]}Локаль '$new_locale' не найдена. Используйте 'locale -a' для списка доступных локалей.${colors[x]}"
            fi
        done

        if grep -qi "Debian" /etc/os-release || grep -qi "Ubuntu" /etc/os-release; then
            echo "LANG=\"$new_locale\"" > /etc/default/locale
            echo "${colors[y]}Локаль '$new_locale' успешно установлена.${colors[x]}"
        else
            echo "${colors[r]}Ваша ОС не поддерживается для автоматической установки локали.${colors[x]}"
            return
        fi
    else
        echo "${colors[r]}Отмена установки локализации.${colors[x]}"
    fi
}

# 3. Функция для изменения часового пояса
setup_timezone() {
    echo "${colors[g]}3] Настройка часового пояса${colors[x]}"
    # Вывод текущего часового пояса
    local current_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ -z "$current_timezone" ]; then
        current_timezone="Не определён"
    fi
    echo "${colors[g]}Текущий часовой пояс: $current_timezone${colors[x]}"

    if confirm "${colors[y]}Хотите изменить часовой пояс?${colors[x]}" "n"; then
        timedatectl list-timezones | grep "^Europe/" | nl -s ") " -w 2 | pr -3 -t -w 80

        while true; do
            read -r -p "Введите номер часового пояса (по умолчанию 35 - Europe/Moscow, Enter для отмены): " choice

            # Если строка пустая, считаем это отказом
            if [ -z "$choice" ]; then
                echo "${colors[r]}Изменение часового пояса отменено (ввод пустой).${colors[x]}"
                return
            fi

            # Проверяем, является ли ввод числом
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                selected_timezone=$(timedatectl list-timezones | grep "^Europe/" | awk -v choice="$choice" "NR==choice {print}")
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

# 4. Функция для установки ПО
setup_software() {
    echo "${colors[g]}4] Установка минимального набора ПО${colors[x]}"

    if confirm "${colors[y]}Установить набор программ?${colors[x]}" "n"; then
        echo "${colors[r]}Вот список программ:${colors[x]}"
        echo
        echo "$standard_packages"
        echo
        while true; do
            read -e -i "$standard_packages" -p "${colors[r]}Можно добавить свои или изменить предложенный набор:${colors[x]} " user_input
            if [[ -n "$user_input" && "$user_input" =~ ^[a-zA-Z0-9[:space:]-]+$ ]]; then
                break
            else
                echo "${colors[r]}Список пакетов не может быть пустым и должен содержать только буквы, цифры, пробелы и дефисы.${colors[x]}"
            fi
        done
        apt install -y $user_input || echo "${colors[r]}Ошибка при установке пакетов.${colors[x]}"
        cp /usr/share/mc/syntax/sh.syntax /usr/share/mc/syntax/unknown.syntax
        echo "${colors[y]}Установка завершена.${colors[x]}"
    else
        echo "${colors[r]}Установка отменена.${colors[x]}"
    fi
}

# 5. Функция для настройки Chrony
setup_chrony() {
    echo "${colors[g]}5] Настройка Chrony${colors[x]}"

    # Проверка, установлен ли Chrony
    if ! command -v chronyc >/dev/null 2>&1 || ! [ -f /etc/chrony/chrony.conf ]; then
        echo "${colors[r]}Chrony не установлен или конфигурационный файл отсутствует.${colors[x]}"
        if confirm "${colors[y]}Установить Chrony?${colors[x]}" "y"; then
            apt update && apt install -y chrony || {
                echo "${colors[r]}Ошибка при установке Chrony.${colors[x]}"
                return
            }
            echo "${colors[y]}Chrony успешно установлен.${colors[x]}"
            
            # Создаем резервную копию оригинального конфига
            cp /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.original"
            
            # Добавляем серверы с "pool" и "iburst", сохраняя остальные настройки
            echo "$chrony_servers" | while IFS= read -r server; do
                if [ -n "$server" ]; then
                    echo "pool $server iburst" >> /etc/chrony/chrony.conf
                fi
            done
            
            # Запускаем и включаем службу
            systemctl enable --now chrony
            sleep 2
            
            systemctl restart chrony && {
                echo "${colors[y]}Применены серверы по умолчанию:${colors[x]}"
                echo "$chrony_servers"
                echo
                echo "${colors[y]}Текущие источники синхронизации:${colors[x]}"
                echo
                chronyc sources
                echo
            } || echo "${colors[r]}Ошибка при перезапуске Chrony после установки.${colors[x]}"
        else
            echo "${colors[r]}Установка Chrony отменена.${colors[x]}"
        fi
        return
    fi

    # Проверка состояния службы chrony
    if ! systemctl is-active --quiet chrony; then
        echo "${colors[r]}Служба chrony не запущена. Пытаемся запустить...${colors[x]}"
        systemctl start chrony
        sleep 2
        if ! systemctl is-active --quiet chrony; then
            echo "${colors[r]}Не удалось запустить службу chrony.${colors[x]}"
            return
        fi
    fi

    echo "${colors[y]}Текущие источники синхронизации:${colors[x]}"
    chronyc sources || echo "${colors[r]}Не удалось получить информацию об источниках синхронизации.${colors[x]}"
    echo

    echo "${colors[y]}Список NTP-серверов из конфигурации (/etc/chrony/chrony.conf):${colors[x]}"
    grep "^pool" /etc/chrony/chrony.conf || echo "${colors[r]}NTP-серверы в конфигурации не найдены.${colors[x]}"
    echo

    # Запрос на смену серверов
    if confirm "${colors[y]}Хотите сменить NTP-серверы в настройках?${colors[x]}" "n"; then
        local backup_file="/etc/chrony/chrony.conf.bak_$(date +%Y%m%d_%H%M%S)"
        cp /etc/chrony/chrony.conf "$backup_file"
        echo "${colors[y]}Создана резервная копия конфигурации: $backup_file${colors[x]}"

        local default_servers=$(echo "$chrony_servers" | tr '\n' '|' | sed 's/|$//')
        echo "${colors[y]}Текущие серверы (для редактирования):${colors[x]}"
        echo "${colors[c]}Введите новые NTP-серверы, разделяя их пробелом${colors[x]}"
        echo "${colors[c]}По умолчанию: ${default_servers}${colors[x]}"
        while true; do
            read -e -i "$default_servers" -p "${colors[y]}Ваш выбор: ${colors[x]}" input_servers
            if [[ -n "$input_servers" && "$input_servers" =~ ^[a-zA-Z0-9.-[:space:]]+$ ]]; then
                break
            else
                echo "${colors[r]}Серверы должны содержать только буквы, цифры, точки и дефисы, и не быть пустыми.${colors[x]}"
            fi
        done
        
        local new_servers=$(echo "$input_servers" | tr '|' '\n' | tr ' ' '\n' | grep -v '^$')
        if [ -n "$new_servers" ]; then
            local temp_conf=$(mktemp)
            grep -v "^pool" /etc/chrony/chrony.conf > "$temp_conf"
            echo "$new_servers" | while IFS= read -r server; do
                if [ -n "$server" ]; then
                    echo "pool $server iburst" >> "$temp_conf"
                fi
            done
            mv "$temp_conf" /etc/chrony/chrony.conf
            chmod 644 /etc/chrony/chrony.conf

            systemctl restart chrony && {
                if systemctl is-active --quiet chrony; then
                    echo "${colors[y]}NTP-серверы обновлены и Chrony перезапущен.${colors[x]}"
                    echo "${colors[y]}Обновлённые источники синхронизации:${colors[x]}"
                    chronyc sources
                    echo "${colors[y]}Новые серверы в конфигурации:${colors[x]}"
                    grep "^pool" /etc/chrony/chrony.conf
                else
                    echo "${colors[r]}Chrony перезапущен, но служба не активна.${colors[x]}"
                fi
            } || echo "${colors[r]}Ошибка при перезапуске Chrony.${colors[x]}"
        else
            echo "${colors[r]}Серверы не введены (пустой ввод), настройки остались без изменений.${colors[x]}"
        fi
    else
        echo "${colors[r]}Смена серверов отменена.${colors[x]}"
    fi
}

# 6. Функция для настройки доступа root через SSH без пароля с ключом
setup_ssh_keys() {
    echo "${colors[g]}6] Настройка доступа через SSH-ключи. Не закрывайте текущее окно SSH пока не убедитесь что доступ по ключу работает!!!${colors[x]}"

    if [ -f "$authorizedfile" ]; then
        echo "${colors[y]}Найден файл публичного ключа для удаленного доступа: $authorizedfile ${colors[x]}"
        local currsshauthkeys="$(cat $authorizedfile)"
        echo "${colors[y]}Его текущее содержимое: ${colors[x]}"
        echo "$currsshauthkeys"
    else
        echo "${colors[r]}Файл авторизованных ключей не найден. Он будет создан при необходимости.${colors[x]}"
    fi

    if confirm "${colors[y]}Хотите создать новую пару SSH-ключей или оставить как есть?${colors[x]}" "n"; then
        while true; do
            read -r -p "${colors[y]}Введите адрес своей электронной почты для привязки к SSH-ключу: ${colors[x]}" email
            if [[ -n "$email" && "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                break
            else
                echo "${colors[r]}Ошибка: введите корректный и непустой email (например, user@example.com).${colors[x]}"
            fi
        done

        read -r -p "${colors[y]}Введите путь к директории, где будут созданы ключи (по умолчанию ~/.ssh): ${colors[x]}" directory
        if [[ -z "$directory" ]]; then
            directory="$HOME/.ssh"
        else
            directory="${directory/#\~/$HOME}"
        fi

        if [ ! -d "$directory" ]; then
            echo "Директория не существует. Создаем её..."
            mkdir -p "$directory"
        fi

        while true; do
            key_path="$directory/id_$currhostname-$DATE"
            ssh-keygen -t rsa -b 4096 -C "$email" -f "$key_path" -N ""
            if [ $? -eq 0 ]; then
                echo "${colors[r]}Ключ успешно создан по пути: $key_path ${colors[x]}"
                apt install -y putty-tools > /dev/null 2>&1
                puttygen "$key_path" -o "$key_path.ppk"
                if [ $? -eq 0 ]; then
                    echo "${colors[y]}Ключ сконвертирован в $key_path.ppk${colors[x]}"
                    echo "${colors[y]}Данный ключ $key_path.ppk нужен для настройки доступа в программе PuTTY/KiTTY по ключу ${colors[x]}"
                    echo "${colors[y]}Скопируйте текст ниже в файл с расширением .ppk (например, id_$currhostname-$DATE.ppk) на вашем компьютере.${colors[x]}"
                    echo "${colors[y]}Убедитесь, что копируете текст полностью, который между дефисами, включая строки вроде PuTTY-User-Key-File-2: ssh-rsa и Private-MAC.${colors[x]}"
                    echo "${colors[y]}Содержимое файла $key_path.ppk:${colors[x]}"
                    echo "---------------------------------------------"
                    cat "$key_path.ppk"
                    echo "---------------------------------------------"
                    if confirm "${colors[y]}Вы можете удалить файл $key_path.ppk с сервера или оставить. Удалить?${colors[x]}" "y"; then
                        rm "$key_path.ppk"
                        echo "${colors[y]}Файл $key_path.ppk удалён с сервера.${colors[x]}"
                    else
                        echo "${colors[r]}Файл $key_path.ppk оставлен на сервере по пути: $key_path.ppk${colors[x]}"
                    fi
                else
                    echo "${colors[r]}Ошибка при конвертации ключа в .ppk${colors[x]}"
                fi
                break
            else
                echo "${colors[r]}Ошибка при создании ключа.${colors[x]}"
                if ! confirm "Повторить попытку?" "y"; then
                    echo "Отмена создания SSH-ключей."
                    return 1
                fi
            fi
        done

        if ! grep -q "$(cat "$key_path.pub")" "$authorizedfile"; then
            cat "$key_path.pub" >> "$authorizedfile"
            chmod 600 "$authorizedfile"
            echo "${colors[y]}Публичный ключ добавлен в $authorizedfile.${colors[x]}"
        else
            echo "${colors[y]}Публичный ключ уже существует в $authorizedfile.${colors[x]}"
        fi

        echo "${colors[y]}Настройка безопасности доступа root только через SSH.${colors[x]}"
        sed -i '0,/^#.*PermitRootLogin/s/^#\([[:space:]]*PermitRootLogin.*\)/\1/' "$sshconfigfile"
        sed -i '0,/^#.*PasswordAuthentication/s/^#\([[:space:]]*PasswordAuthentication.*\)/\1/' "$sshconfigfile"
        sed -i '0,/^#.*PermitEmptyPasswords/s/^#\([[:space:]]*PermitEmptyPasswords.*\)/\1/' "$sshconfigfile"
        sed -i '0,/^#.*PubkeyAuthentication/s/^#\([[:space:]]*PubkeyAuthentication.*\)/\1/' "$sshconfigfile"

        echo "${colors[y]}Изменено 'PermitRootLogin' на 'prohibit-password', 'PasswordAuthentication' на 'no', 'PermitEmptyPasswords' на 'no'. Вход по паролю для root отключен.${colors[x]}"
        echo "${colors[y]}Изменено 'PubkeyAuthentication' на 'yes'. Аутентификация по ключам включена.${colors[x]}"

        echo "${colors[r]}Перезапускаем SSH...${colors[x]}"
        systemctl restart ssh
        echo "${colors[y]}Настройка завершена! Убедитесь, что ключи правильно добавлены для доступа.${colors[x]}"
    else
        echo "${colors[r]}Создание SSH-ключей отменено. Продолжаем выполнение скрипта.${colors[x]}"
    fi
}

# 7. Функция для изменения порта SSH
change_ssh_port() {
    echo "${colors[g]}7] Изменение порта для SSH...${colors[x]}"
    echo

    local current_ssh_port=$(grep -E '^[[:space:]]*#?Port[[:space:]]+[0-9]+' "$sshconfigfile" | awk '{print $2}' | head -n 1)
    if [ -z "$current_ssh_port" ]; then
        current_ssh_port=22
        echo "${colors[y]}Порт SSH не указан в конфигурации. Предполагается стандартный порт 22.${colors[x]}"
    else
        echo "${colors[g]}Текущий порт SSH из конфигурации: $current_ssh_port${colors[x]}"
    fi

    if grep -qE '^[[:space:]]*#?Port[[:space:]]+[0-9]+' "$sshconfigfile"; then
        echo "${colors[g]}Проверяем, закомментирована строка 'Port' или нет...${colors[x]}"
        if grep -qE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshconfigfile"; then
            echo "Строка 'Port' уже раскомментирована."
        else
            echo "Строка 'Port' закомментирована. Раскомментируем и установим порт 22."
            sed -i 's/^[[:space:]]*#\(Port[[:space:]]*\)[0-9]*/\122/' "$sshconfigfile"
            current_ssh_port=22
        fi
    else
        echo "'Port' не найден в конфигурации. Добавляем его с значением 22."
        if [ -n "$(tail -c 1 "$sshconfigfile")" ]; then
            echo "" >> "$sshconfigfile"
        fi
        echo "Port 22" >> "$sshconfigfile"
        current_ssh_port=22
    fi

    echo "${colors[y]}Текущий порт SSH: $current_ssh_port${colors[x]}"
    echo "${colors[c]}Введите новый порт (22 или 1025-49150) или 'y' для случайного порта (1025-49150), или нажмите Enter для отмены:${colors[x]}"
    read -r -p "${colors[y]}Ваш выбор: ${colors[x]}" new_port_input

    if [ -z "$new_port_input" ]; then
        echo "${colors[r]}Изменение порта отменено. Оставляем текущий порт SSH: $current_ssh_port.${colors[x]}"
        ssh_port=$current_ssh_port
        return $ssh_port
    elif [[ "$new_port_input" =~ ^[Yy]$ ]]; then
        local random_port=$(( ( RANDOM % 48126 ) + 1025 ))
        sed -i "s/^[[:space:]]*Port[[:space:]]\+[0-9]*/Port $random_port/" "$sshconfigfile"
        echo "${colors[y]}Порт изменён на случайный: $random_port.${colors[x]}"
        echo "Перезапускаем SSH для применения изменений..."
        systemctl restart ssh
        ssh_port=$random_port
        return $ssh_port
    elif [[ "$new_port_input" =~ ^[0-9]+$ ]]; then
        if [ "$new_port_input" -eq 22 ] || { [ "$new_port_input" -ge 1025 ] && [ "$new_port_input" -le 49150 ]; }; then
            sed -i "s/^[[:space:]]*Port[[:space:]]\+[0-9]*/Port $new_port_input/" "$sshconfigfile"
            echo "${colors[y]}Порт изменён на: $new_port_input.${colors[x]}"
            echo "Перезапускаем SSH для применения изменений..."
            systemctl restart ssh
            ssh_port=$new_port_input
            return $ssh_port
        else
            echo "${colors[r]}Ошибка: порт должен быть 22 или в диапазоне 1025-49150. Оставляем текущий порт: $current_ssh_port.${colors[x]}"
            ssh_port=$current_ssh_port
            return $ssh_port
        fi
    else
        echo "${colors[r]}Ошибка: введите 'y' для случайного порта или число (22 или 1025-49150). Оставляем текущий порт: $current_ssh_port.${colors[x]}"
        ssh_port=$current_ssh_port
        return $ssh_port
    fi
}

# 8 Функция для настройки брандмауэр UFW
configure_ufw() {
    echo "${colors[g]}8] Первоначальная настройка брандмауэра UFW...${colors[x]}"
    echo

    local active_ssh_port=$(ss -tln | awk '$1 == "LISTEN" {split($4, a, ":"); if (a[2] ~ /^[0-9]+$/) print a[2]}' | grep -E '^(22|[1-4][0-9]{4})$' | head -n 1)
    if [ -z "$active_ssh_port" ]; then
        active_ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshconfigfile" | awk '{print $2}' | head -n 1)
        if [ -z "$active_ssh_port" ]; then
            active_ssh_port=22
            echo "${colors[y]}Не удалось определить активный порт SSH. Предполагается стандартный порт 22.${colors[x]}"
        else
            echo "${colors[y]}Обнаружен порт SSH из конфигурации: $active_ssh_port${colors[x]}"
        fi
    else
        echo "${colors[y]}Обнаружен активный порт SSH: $active_ssh_port${colors[x]}"
    fi

    local session_port=""
    if [ -n "$SSH_CONNECTION" ]; then
        session_port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
        echo "${colors[y]}Порт текущей SSH-сессии: $session_port${colors[x]}"
    fi

    echo "${colors[y]}Настройка UFW для порта SSH из скрипта: $ssh_port${colors[x]}"

    echo "Сброс настроек UFW по умолчанию"
    echo
    yes | ufw reset

    echo "Открываем порт 22, порт $ssh_port и активный порт $active_ssh_port..."
    ufw allow 22
    ufw allow "$ssh_port"
    ufw allow "$active_ssh_port"
    if [ -n "$session_port" ] && [ "$session_port" -ne "$ssh_port" ] && [ "$session_port" -ne "$active_ssh_port" ] && [ "$session_port" -ne 22 ]; then
        ufw allow "$session_port"
        echo "${colors[y]}Дополнительно открыт порт текущей сессии: $session_port${colors[x]}"
    fi
    local port_status="Порт 22, порт $ssh_port и активный порт $active_ssh_port открыты."

    echo
    echo "Включаем UFW..."
    ufw --force enable
    echo "UFW настроен."
    echo
    echo "Проверка состояния UFW:"
    ufw status verbose
    echo
    echo "$port_status"

    echo
    echo "Настройки применены. Пожалуйста, прежде чем завершить текущую сессию SSH, убедитесь, что вы можете подключиться по порту SSH $ssh_port."
    if [ "$ssh_port" -ne 22 ] || [ "$active_ssh_port" -ne 22 ]; then
        echo
        if confirm "${colors[y]}Порт 22 закрываем?${colors[x]}" "n"; then
            ufw deny 22
            echo "${colors[y]}Порт 22 закрыт. Остались открыты порт $ssh_port и активный порт $active_ssh_port.${colors[x]}"
            if [ -n "$session_port" ] && [ "$session_port" -ne "$ssh_port" ] && [ "$session_port" -ne "$active_ssh_port" ]; then
                echo "${colors[y]}Порт текущей сессии $session_port также остаётся открыт.${colors[x]}"
            fi
            echo
            echo "Проверка состояния UFW после закрытия порта 22:"
            ufw status verbose
        else
            echo "${colors[r]}Оставляем порт 22 открытым вместе с $ssh_port и $active_ssh_port.${colors[x]}"
            if [ -n "$session_port" ] && [ "$session_port" -ne "$ssh_port" ] && [ "$session_port" -ne "$active_ssh_port" ] && [ "$session_port" -ne 22 ]; then
                echo "${colors[r]}Порт текущей сессии $session_port также остаётся открыт.${colors[x]}"
            fi
            echo "${colors[r]}Не забудьте позже закрыть порт 22 вручную для повышения безопасности!${colors[x]}"
        fi
    else
        echo "${colors[y]}Порт SSH остался 22, дополнительных действий не требуется.${colors[x]}"
    fi
}

# 9. Функция для добавления нового пользователя
add_new_user() {
    echo "${colors[g]}9] Добавление пользователя без прав root${colors[x]}"
    if confirm "Хотите добавить нового пользователя?" "n"; then
        while true; do
            read -r -p "Введите имя пользователя: " new_user
            
            # Проверка на пустоту
            if [ -z "$new_user" ]; then
                echo "${colors[r]}Ошибка: имя пользователя не может быть пустым.${colors[x]}"
                continue
            fi
            
            # Проверка на допустимые символы
            if [[ ! "$new_user" =~ ^[a-zA-Z0-9_]+$ ]]; then
                echo "${colors[r]}Ошибка: имя должно содержать только буквы, цифры и '_'.${colors[x]}"
                continue
            fi
            
            # Проверка на существующего пользователя
            if id -u "$new_user" >/dev/null 2>&1; then
                echo "${colors[r]}Ошибка: пользователь '$new_user' уже существует.${colors[x]}"
                continue
            fi
            
            break
        done

        while true; do
            read -s -r -p "Введите пароль для пользователя '$new_user': " new_user_password
            echo
            if [ -n "$new_user_password" ]; then
                break
            else
                echo "${colors[r]}Ошибка: пароль не может быть пустым.${colors[x]}"
            fi
        done

        while true; do
            read -s -r -p "Повторите пароль: " new_user_password_confirm
            echo
            if [ "$new_user_password" = "$new_user_password_confirm" ]; then
                break
            else
                echo "${colors[r]}Ошибка: пароли не совпадают. Повторите ввод.${colors[x]}"
            fi
        done

        useradd -m -s /bin/bash "$new_user"
        echo "$new_user:$new_user_password" | chpasswd
        echo "${colors[y]}Пользователь '$new_user' создан с домашней директорией /home/$new_user.${colors[x]}"

        # Создаем обязательные скрытые папки
        mkdir -p "/home/$new_user"/{.config,.local/share}
        chown -R "$new_user:$new_user" "/home/$new_user"

        # Запрос на создание дополнительных папок
        echo "${colors[g]}Настройка дополнительных папок в домашней директории${colors[x]}"
        echo "${colors[y]}Пример возможных папок: backup projects documents${colors[x]}"
        
        if confirm "${colors[y]}Хотите создать дополнительные папки в /home/$new_user?${colors[x]}" "n"; then
            while true; do
                read -r -p "Введите список папок через пробел (например: backup projects): " custom_folders
                if [ -z "$custom_folders" ]; then
                    echo "${colors[r]}Не указаны папки для создания. Пропускаем.${colors[x]}"
                    break
                fi
                
                if [[ "$custom_folders" =~ ^[a-zA-Z0-9_[:space:]]+$ ]]; then
                    # Проверка каждой папки на существование
                    existing_folders=""
                    for folder in $custom_folders; do
                        if [ -d "/home/$new_user/$folder" ]; then
                            existing_folders+="$folder "
                        else
                            mkdir -p "/home/$new_user/$folder"
                            chown "$new_user:$new_user" "/home/$new_user/$folder"
                        fi
                    done
                    
                    if [ -n "$existing_folders" ]; then
                        echo "${colors[y]}Папки уже существуют: $existing_folders${colors[x]}"
                    fi
                    
                    created_folders=$(echo "$custom_folders" | tr ' ' '\n' | grep -v "$existing_folders" | tr '\n' ' ')
                    if [ -n "$created_folders" ]; then
                        echo "${colors[y]}Созданы папки: $created_folders${colors[x]}"
                    fi
                    break
                else
                    echo "${colors[r]}Ошибка: имена папок должны содержать только буквы, цифры и '_'.${colors[x]}"
                    echo "${colors[y]}Попробуйте снова. Пример: backup projects${colors[x]}"
                fi
            done
        else
            echo "${colors[r]}Создание дополнительных папок отменено.${colors[x]}"
        fi

        # Создаем .bashrc
        touch "/home/$new_user/.bashrc"
        chown "$new_user:$new_user" "/home/$new_user/.bashrc"
        echo "${colors[y]}Пользователь '$new_user' успешно настроен.${colors[x]}"
    else
        echo "${colors[r]}Отмена создания пользователя.${colors[x]}"
    fi
}

# 10. Функция для очистки apt кэша и истории команд
clean_apt_cache() {
    echo "${colors[g]}10] Очистка системного кэша и истории команд${colors[x]}"
    if confirm "${colors[y]}Хотите выполнить очистку кэша и истории?${colors[x]}" "n"; then
        echo "${colors[y]}Начата очистка apt кэша...${colors[x]}"
        apt clean 2>/dev/null
        
        echo "Очистка /var/cache/apt/archives/"
        rm -rf /var/cache/apt/archives/*
        
        echo "Очистка /var/lib/apt/lists/"
        rm -rf /var/lib/apt/lists/*
        
        # Очистка истории команд
        echo "Очистка истории команд"
        if [ -n "$BASH" ]; then
            # Очистка истории текущей сессии
            history -c
            
            # Очистка файла истории (если существует)
            if [ -f ~/.bash_history ]; then
                cat /dev/null > ~/.bash_history
            fi
            
            echo "${colors[y]}История команд текущей сессии и файл .bash_history очищены${colors[x]}"
        else
            echo "${colors[y]}Очистка истории доступна только в bash${colors[x]}"
        fi
        
        echo "${colors[y]}Кэш apt и история команд успешно очищены${colors[x]}"
        echo "Дата очистки: $(date)"
    else
        echo "${colors[r]}Очистка отменена${colors[x]}"
    fi
}

# 11. Функция для перезагрузки системы
reboot_system() {
    echo "${colors[g]}Если вы запустили этот пункт, значит все настройки завершены.${colors[x]}"
            echo "${colors[y]}Пришло время перезагрузить систему для применения изменений.${colors[x]}"
        echo
    if confirm "${colors[r]}Перезагрузить систему?${colors[x]}" "n"; then
        echo "${colors[r]}ПЕРЕЗАГРУЗКА СИСТЕМЫ ${colors[x]}"
        echo "${colors[g]}Спасибо за использование этого скрипта!${colors[x]}"
        reboot
    else
        echo "${colors[r]}Пропускаем перезагрузку системы. Не забудьте сделать это вручную!${colors[x]}"
        echo "${colors[g]}Спасибо за использование этого скрипта!${colors[x]}"
    fi
}

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo "${colors[r]}Этот скрипт должен быть запущен от имени root. Перезапустите его 'sudo bash ./script.sh' ${colors[x]}"
    exit 1
fi

# Меню
while true; do
    clear
    echo "${colors[g]}Настройка Debian/Ubuntu с помощью скрипта https://github.com/saym101/setup${colors[x]}"
    echo "${colors[r]}Запускайте этот скрипт c правами root. Используя команду su -l${colors[x]}"
    echo "${colors[r]}Задав предварительно пароль для root командой 'sudo passwd root'.${colors[x]}"
    echo
    echo "${colors[y]}Выберите номер нужного пункта. По умолчанию везде \"НЕТ\"${colors[x]}"
    echo "${colors[c]}1.${x}  ${g}Изменить hostname${x}"
    echo "${colors[c]}2.${x}  ${g}Изменить локаль${x}"
    echo "${colors[c]}3.${x}  ${g}Изменить часовой пояс${x}"
    echo "${colors[c]}4.${x}  ${g}Установить ПО${x}"
    echo "${colors[c]}5.${x}  ${g}Настроить Chrony${x}"
    echo "${colors[c]}6.${x}  ${g}Настроить SSH ключи${x}"
    echo "${colors[c]}7.${x}  ${g}Изменить порт SSH${x}"
    echo "${colors[c]}8.${x}  ${g}Настроить UFW${x}"
    echo "${colors[c]}9.${x}  ${g}Добавить пользователя${x}"
    echo "${colors[c]}10.${x} ${g}Очистим apt кеш и историю команд .bash_history${x}"
    echo "${colors[c]}11.${x} ${g}Перезагрузить систему${x}"
    echo "${colors[c]}0. Выход${x}"

    read -p "${colors[y]}Введите номер:${x} " choice

    case $choice in
        1) setup_hostname ;;
        2) setup_locale ;;
        3) setup_timezone ;;
        4) setup_software ;;
        5) setup_chrony ;;
        6) setup_ssh_keys ;;
        7) change_ssh_port ;;
        8) configure_ufw ;;
        9) add_new_user ;;
        10) clean_apt_cache ;;
        11) reboot_system ;;
        0) exit 0 ;;
        *) echo "Неверный выбор. Попробуйте еще раз." ;;
    esac

    read -p "${colors[y]}Нажмите Enter для продолжения...${colors[x]}"
done
