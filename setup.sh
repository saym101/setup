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
chrony_servers="pool 0.ru.pool.ntp.org
pool 1.ru.pool.ntp.org
pool 2.ru.pool.ntp.org
pool 3.ru.pool.ntp.org"

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

# Функция создания домашнего каталога с папками
create_home_dir() {
    local username="$1"
    local home_dir="/home/$username"

    mkdir -p "$home_dir"/{.config,.local/share,Documents,Download,Backup,Music,Pictures,Video}
    touch "$home_dir/.bashrc"
}

# 1. Функция для установки hostname
setup_hostname() {
    echo "${colors[g]}1] Установка hostname${colors[x]}"
    local current_hostname=$(hostname)
    echo "Текущее имя хоста: $current_hostname"

    if confirm "${colors[y]}Хотите изменить имя хоста?${colors[x]}" "n"; then
        while true; do
            read -r -p "Введите новое имя хоста: " new_hostname
            [[ -n "$new_hostname" ]] && break
            echo "${colors[r]}Имя хоста не может быть пустым.${colors[x]}"
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
    locale | grep "^LANG="

    if confirm "${colors[y]}Меняем локаль?${colors[x]}" "n"; then
        read -r -p "Введите желаемую локаль (по умолчанию ru_RU.UTF-8): " new_locale
        new_locale=${new_locale:-"ru_RU.UTF-8"}

        if grep -qi "Debian" /etc/os-release || grep -qi "Ubuntu" /etc/os-release; then
            echo "LANG=\"$new_locale\"" > /etc/default/locale
        else
            echo "${colors[r]}Ваша ОС не поддерживается для автоматической установки локали.${colors[x]}"
            return
        fi

        echo "${colors[y]}Локаль '$new_locale' успешно установлена.${colors[x]}"
    else
        echo "${colors[r]}Отмена установки локализации.${colors[x]}"
    fi
}

# 3. Функция для изменения часового пояса
setup_timezone() {
    if confirm "${colors[g]}3] Хотите изменить часовой пояс?${colors[x]}" "n"; then
        timedatectl list-timezones | grep "^Europe/" | nl -s ") " -w 2 | pr -3 -t -w 80

        while true; do
            read -r -p "Введите номер часового пояса (по умолчанию 35 - Europe/Moscow): " choice
            choice=${choice:-35}

            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                selected_timezone=$(timedatectl list-timezones | grep "^Europe/" | awk -v choice="$choice" "NR==choice {print}")
                [[ -n "$selected_timezone" ]] && break
            fi
            echo "${colors[r]}Некорректный ввод. Введите номер из списка.${colors[x]}"
        done

        timedatectl set-timezone "$selected_timezone"
        echo "${colors[y]}Часовой пояс изменен на $selected_timezone.${colors[x]}"
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
        read -e -i "$standard_packages" -p "${colors[r]}Можно добавить свои или изменить предложенный набор:${colors[x]} " user_input
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

    # Проверка статуса Chrony и вывод текущих источников
    if dpkg -s chrony &> /dev/null; then
        echo "${colors[y]}Chrony установлен.${colors[x]}"
        echo "${colors[y]}Текущие источники синхронизации:${colors[x]}"
        echo
        chronyc sources
        echo
    else
        echo "${colors[r]}Chrony не установлен.${colors[x]}"
    fi

    # Вывод списка NTP-серверов из конфигурации
    echo "${colors[y]}Список NTP-серверов из конфигурации (/etc/chrony/chrony.conf):${colors[x]}"
    echo
    grep "^pool" /etc/chrony/chrony.conf || echo "${colors[r]}NTP-серверы в конфигурации не найдены.${colors[x]}"
    echo

    # Запрос на настройку Chrony
    if confirm "${colors[y]}Хотите настроить Chrony?${colors[x]}" "n"; then
        if ! dpkg -s chrony &> /dev/null; then
            echo "${colors[r]}Chrony не установлен.${colors[x]}"
            if confirm "${colors[y]}Установить Chrony?${colors[x]}" "y"; then
                apt install -y chrony || {
                    echo "${colors[r]}Ошибка при установке Chrony.${colors[x]}"
                    return
                }
                echo "${colors[y]}Chrony успешно установлен.${colors[x]}"
            else
                echo "${colors[r]}Установка Chrony отменена. Настройка невозможна без Chrony.${colors[x]}"
                return
            fi
        fi

        sed -i '/^pool/d' /etc/chrony/chrony.conf
        echo "$chrony_servers" >> /etc/chrony/chrony.conf

        systemctl restart chrony
        echo "${colors[y]}Chrony настроен и перезапущен.${colors[x]}"
        echo "${colors[y]}Обновлённые источники синхронизации:${colors[x]}"
        echo 
        chronyc sources
        echo
    else
        echo "${colors[r]}Настройка Chrony отменена.${colors[x]}"
    fi
}

# 6. Функция для настройки доступа root через SSH без пароля с ключом
setup_ssh_keys() {
    echo "${colors[g]}6] Настройка доступа через SSH-ключи. Не закрывайте текущее окно SSH пока не убедитесь что доступ по ключу работает!!!${colors[x]}"

    # Проверка наличия файла authorized_keys
    if [ -f "$authorizedfile" ]; then
        echo "${colors[y]}Найден файл публичного ключа для удаленного доступа: $authorizedfile ${colors[x]}"
        echo
        local currsshauthkeys="$(cat $authorizedfile)"
        echo "${colors[y]}Его текущее содержимое: ${colors[x]}"
        echo "$currsshauthkeys"
    else
        echo "${colors[r]}Файл авторизованных ключей не найден. Он будет создан при необходимости.${colors[x]}"
    fi

    # Запрос на создание ключей
    while true; do
        echo
        read -r -n 1 -p "${colors[y]} Хотите создать новую пару SSH-ключей или оставить как есть? (y/N): ${colors[x]}" -r
        echo

        # Установка значений по умолчанию
        if [[ -z $REPLY ]]; then
            REPLY='n'
        fi

        # Проверка на валидность ввода
        if [[ $REPLY =~ ^[YyNn]$ ]]; then
            break
        else
            echo "${colors[r]}Ошибка: пожалуйста, введите 'y' для да или 'n' для нет.${colors[x]}"
        fi
    done

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Получение данных от пользователя для нового ключа
        while true; do
            read -r -p "${colors[y]}Введите адрес своей электронной почты для привязки к SSH-ключу: ${colors[x]}" email

            # Валидация email
            if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                break
            else
                echo "${colors[r]}Ошибка: введён некорректный email. Пожалуйста, введите корректный адрес электронной почты.${colors[x]}"
            fi
        done

        # Запрашиваем путь к директории с установкой пути по умолчанию
        read -r -p "${colors[y]}Введите путь к директории, где будут созданы ключи (по умолчанию ~/.ssh): ${colors[x]}" directory

        # Используем путь по умолчанию, если пользователь нажал Enter
        if [[ -z "$directory" ]]; then
            directory="$HOME/.ssh"
        else
            # Заменяем ~ на полный путь
            directory="${directory/#\~/$HOME}"
        fi

        # Проверка существования директории
        if [ ! -d "$directory" ]; then
            echo "Директория не существует. Создаем её..."
            mkdir -p "$directory"
        fi

        # Создание SSH-ключей
        while true; do
            key_path="$directory/id_$currhostname-$DATE"
            ssh-keygen -t rsa -b 4096 -C "$email" -f "$key_path" -N ""

            # Проверка успешности создания ключа
            if [ $? -eq 0 ]; then
                echo "${colors[r]}Ключ успешно создан по пути: $key_path ${colors[x]}"
                
                # Установка putty-tools для конвертации
                apt install -y putty-tools > /dev/null 2>&1
                puttygen "$key_path" -o "$key_path.ppk"
                if [ $? -eq 0 ]; then
                    echo "${colors[y]}Ключ сконвертирован в $key_path.ppk${colors[x]}"
                    echo "${colors[y]}Данный ключ $key_path.ppk нужен для настройки доступа в программе PuTTY/KiTTY по ключу ${colors[x]}"
                    echo "${colors[y]}Скопируйте текст ниже в файл с расширением .ppk (например, id_$currhostname-$DATE.ppk) на вашем компьютере.${colors[x]}"
                    echo "${colors[y]}Убедитесь, что копируете текст полностью, который между дефисами, включая строки вроде PuTTY-User-Key-File-2: ssh-rsa и Private-MAC.${colors[x]}"
                    echo
                    echo "${colors[y]}Содержимое файла $key_path.ppk:${colors[x]}"
                    echo "---------------------------------------------"
                    cat "$key_path.ppk"
                    echo "---------------------------------------------"
                    echo
                    echo
                    echo
                    # Запрос на удаление файла
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
                read -p "Повторить попытку? [y/N]: " retry
                retry=${retry,,}
                if [[ $retry != 'y' ]]; then
                    echo "Отмена создания SSH-ключей."
                    exit 1
                fi
            fi
        done

        # Добавление публичного ключа в файл authorized_keys (с проверкой на дублирование)
        if ! grep -q "$(cat "$key_path.pub")" "$authorizedfile"; then
            cat "$key_path.pub" >> "$authorizedfile"
            chmod 600 "$authorizedfile"
            echo "${colors[y]}Публичный ключ добавлен в $authorizedfile.${colors[x]}"
        else
            echo "${colors[y]}Публичный ключ уже существует в $authorizedfile.${colors[x]}"
        fi

        echo "${colors[y]}Настройка безопасности доступа root только через SSH.${colors[x]}"
        echo
        # Изменяем первые четыре вхождения директив
        sed -i '0,/^#.*PermitRootLogin/s/^#\([[:space:]]*PermitRootLogin.*\)/\1/' "$sshconfigfile"
        sed -i '0,/^#.*PasswordAuthentication/s/^#\([[:space:]]*PasswordAuthentication.*\)/\1/' "$sshconfigfile"
        sed -i '0,/^#.*PermitEmptyPasswords/s/^#\([[:space:]]*PermitEmptyPasswords.*\)/\1/' "$sshconfigfile"
        sed -i '0,/^#.*PubkeyAuthentication/s/^#\([[:space:]]*PubkeyAuthentication.*\)/\1/' "$sshconfigfile"

        echo "${colors[y]}Изменено 'PermitRootLogin' на 'prohibit-password', 'PasswordAuthentication' на 'no', 'PermitEmptyPasswords' на 'no'. Вход по паролю для root отключен.${colors[x]}"
        echo "${colors[y]}Изменено 'PubkeyAuthentication' на 'yes'. Аутентификация по ключам включена.${colors[x]}"

        # Перезапуск SSHD
        echo "${colors[r]}Перезапускаем SSH...${colors[x]}"
        systemctl restart ssh
        echo
        echo "${colors[y]}Настройка завершена! Убедитесь, что ключи правильно добавлены для доступа.${colors[x]}"
        echo
    else
        echo "${colors[r]}Создание SSH-ключей отменено. Продолжаем выполнение скрипта.${colors[x]}"
        echo
    fi
}

# 7. Функция для изменения порта SSH
change_ssh_port() {
    echo "${colors[g]}7.1] Изменение порта для SSH...${colors[x]}"
    echo

    # Получение текущего значения порта SSH
    local current_ssh_port=$(grep '^ *Port ' "$sshconfigfile" | awk '{print $2}')

    # Проверка существования строки 'Port'
    if grep -q "^ *Port " "$sshconfigfile"; then
        echo "${colors[g]}Проверяем, закомментирована строка 'Port' или нет...${colors[x]}"

        if grep -q "^ *Port " "$sshconfigfile"; then
            echo "На данный момент комментирование 'Port' уже было снято."
            echo "Текущий порт SSH: $current_ssh_port"
        else
            echo "Строка с номером порта была закомментирована."
            echo "Снимаем комментарий."
            sed -i "/^ *#Port/c\Port 22" "$sshconfigfile"
            echo "Порт установлен на 22 используемый SSH по умолчанию"
            current_ssh_port=22
        fi
    else
        echo "'Port' не найден. Добавляем его и устанавливаем на 22."
        echo "Port 22" >> "$sshconfigfile"
        current_ssh_port=22
    fi

    # Запрос на изменение порта
    read -p "${colors[y]}Изменить текущий порт $current_ssh_port на случайный из диапазона 1025-49150? [y/N]: ${colors[x]}" -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Смена порта на случайный
        local random_port=$(( ( RANDOM % 48126 ) + 1025 ))
        sed -i "/^ *Port /c\Port $random_port" "$sshconfigfile"
        echo "Порт изменён на $random_port."
        echo "Перезапускаем SSH для применения изменений..."
        systemctl restart ssh
        return $random_port
    else
        echo "Оставляем текущий порт SSH: $current_ssh_port."
        return $current_ssh_port
    fi
}

# 7.2 Функция для настройки брандмауэр UFW
configure_ufw() {
    echo "${colors[g]}7.2] Первоначальная настройка брандмауэра UFW...${colors[x]}"
    echo

    # Сброс настроек по умолчанию
    echo "Сброс настроек UFW по умолчанию"
    echo
    yes | ufw reset

    # Получение текущего порта SSH
    local sshport=$1

    # Настройка UFW
    if [[ $sshport -eq 22 ]]; then
        echo "Оставляем 22 порт открытым..."
        ufw allow 22
        local port_status="Порт 22 открыт."
    else
        echo "Закрываем 22 порт и открываем порт $sshport..."
        ufw deny 22
        ufw allow "$sshport"
        local port_status="Порт 22 закрыт, открыт порт $sshport."
    fi

    # Включение UFW и вывод статуса
    echo
    echo "Включаем UFW..."
    ufw --force enable
    echo "UFW настроен."
    echo
    echo "Проверка состояния UFW:"
    ufw status verbose
    echo
    echo "$port_status"

    # Проверка подключения по новому порту
    echo
    echo "Настройки применены. Пожалуйста, убедитесь, что вы можете подключиться по новому порту SSH."
    echo
}

# 8. Функция для добавления нового пользователя
add_new_user() {
    echo "${colors[g]}8] Добавление пользователя без прав root.${colors[x]}"
    if confirm "Хотите добавить нового пользователя?" "n"; then
        while true; do
            read -r -p "Введите имя пользователя: " new_user
            if id -u "$new_user" >/dev/null 2>&1; then
                echo "${colors[r]}Пользователь '$new_user' уже существует. Введите другое имя.${colors[x]}"
            else
                break
            fi
        done

        read -s -r -p "Введите пароль для пользователя '$new_user': " new_user_password
        echo
        read -s -r -p "Повторите пароль: " new_user_password_confirm
        echo

        if [[ "$new_user_password" != "$new_user_password_confirm" ]]; then
            echo "${colors[r]}Пароли не совпадают. Отмена создания пользователя.${colors[x]}"
        else
            useradd -m -s /bin/bash "$new_user"
            echo "$new_user:$new_user_password" | chpasswd

            create_home_dir "$new_user"

            echo "${colors[y]}Пользователь '$new_user' успешно создан.${colors[x]}"
        fi
    else
        echo "${colors[r]}Отмена создания пользователя.${colors[x]}"
    fi
}

# 9. Функция для очистки apt кэша
clean_apt_cache() {
    echo "${colors[g]}9] Очищаем apt кэш${colors[x]}"
    if confirm "${colors[y]}Хотите очистить apt кэш?${colors[x]}" "n"; then
        apt clean all && rm -fr /var/cache/*
        echo
        echo "${colors[y]}Кэш очищен${colors[x]}"
    else
        echo "${colors[r]}Очистка кэша отменена${colors[x]}"
    fi
}

# 10. Функция для перезагрузки системы
reboot_system() {
    echo "${colors[y]}Настройка системы завершена.${colors[x]}"
    echo
    echo "${colors[g]}Настоятельно рекомендуется перезагрузить сейчас систему для применения изменений.${colors[x]}"
    echo
    read -p "${colors[r]}Перезагрузить систему? [y/N]: ${colors[x]}" -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "${colors[r]}ПЕРЕЗАГРУЗКА СИСТЕМЫ ${colors[x]}"
        echo
        echo "${colors[g]}Спасибо за использование этого скрипта!${colors[x]}"
        echo "reboot"
        reboot
    else
        echo
        echo "${colors[r]}Пропускаем перезагрузку системы. Не забудьте сделать это вручную!${colors[x]}"
        echo
        echo "${colors[g]}Спасибо за использование этого скрипта!${colors[x]}"
        echo
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
    echo "${colors[c]}7.1${x}  ${g}Изменить порт SSH${x}"
    echo "${colors[c]}7.2${x}  ${g}Настроить UFW${x}"
    echo "${colors[c]}8.${x}  ${g}Добавить пользователя${x}"
    echo "${colors[c]}9.${x}  ${g}Очистить apt кэш${x}"
    echo "${colors[c]}10.${x} ${g}Перезагрузить систему${x}"
    echo "${colors[c]}0. Выход${x}"

    read -p "${colors[y]}Введите номер:${x} " choice

    case $choice in
        1) setup_hostname ;;
        2) setup_locale ;;
        3) setup_timezone ;;
        4) setup_software ;;
        5) setup_chrony ;;
        6) setup_ssh_keys ;;
        7.1) change_ssh_port ;;
        7.2) 
            local sshport=$(grep '^ *Port ' "$sshconfigfile" | awk '{print $2}')
            configure_ufw "$sshport" ;;
        8) add_new_user ;;
        9) clean_apt_cache ;;
        10) reboot_system ;;
        0) exit 0 ;;
        *) echo "Неверный выбор. Попробуйте еще раз." ;;
    esac

    read -p "${colors[y]}Нажмите Enter для продолжения...${colors[x]}"
done
