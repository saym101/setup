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
standard_packages="curl gnupg mc ufw htop iftop net-tools ca-certificates wget lynx language-pack-ru openssh-server openssh-client nano fail2ban chrony"
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
    local default="${2:-n}"  # По умолчанию "n"
    local answer

    while true; do
        read -r -p "${msg} [${default,,}] " answer
        answer="${answer:-$default}"  # Используем значение по умолчанию, если ввод пустой
        answer="${answer,,}"

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
    current_hostname=$(hostname)
    echo "Текущее имя хоста: $current_hostname"

    if confirm "${colors[y]}Хотите изменить имя хоста?${colors[x]}" "y"; then
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

        if grep -qi "debian" /etc/os-release; then
            echo "LANG=\"$new_locale\"" > /etc/default/locale
        else
            echo "LANG=$new_locale" > /etc/default/locale
        fi

        echo "${colors[y]}Локаль '$new_locale' успешно установлена.${colors[x]}"
    else
        echo "${colors[r]}Отмена установки локализации.${colors[x]}"
    fi
}

# 3. Функция для изменения часового пояса
setup_timezone() {
    if confirm "${colors[g]}3] Хотите изменить часовой пояс?${colors[x]}" "n"; then
        echo "Доступные часовые пояса:"
        timedatectl list-timezones | grep "^Europe/" | nl -s ") " -w 2 | pr -3 -t -w 80

        while true; do
            read -r -p "Введите номер часового пояса (по умолчанию 35 - Europe/Moscow): " choice
            choice=${choice:-35}

            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                selected_timezone=$(timedatectl list-timezones | grep "^Europe/" | awk -v choice="$choice" "NR==choice {print}")
                if [[ -n "$selected_timezone" ]]; then
                    timedatectl set-timezone "$selected_timezone"
                    echo "${colors[y]}Часовой пояс изменен на $selected_timezone.${colors[x]}"
                    break
                fi
            fi
            echo "${colors[r]}Некорректный ввод. Введите номер из списка.${colors[x]}"
        done
    else
        echo "${colors[r]}Процедура изменения часового пояса отменена.${colors[x]}"
    fi
}

# 4. Функция для установки репозиториев и обновления системы
setup_repositories() {
    echo "${colors[g]}4] Установка репозиториев и обновление системы${colors[x]}"

    if confirm "${colors[y]}Хотите сменить источник пакетов на xUSSR?${colors[x]}" "n"; then
        os_info=$(cat /etc/os-release)
        repos=""

        if echo "$os_info" | grep -q "Debian"; then
            debian_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d '"' -f 2)
            case "$debian_ver" in
                10) repos='deb http://mirror.docker.ru/debian buster main contrib non-free-firmware
deb http://mirror.docker.ru/debian-security buster/updates main contrib non-free-firmware
deb http://mirror.docker.ru/debian buster-updates main contrib non-free-firmware';;
                11) repos='deb http://mirror.docker.ru/debian bullseye main contrib non-free-firmware
deb http://mirror.docker.ru/debian bullseye-updates main contrib non-free-firmware
deb http://mirror.docker.ru/debian-security bullseye-security main contrib non-free-firmware';;
                12) repos='deb http://mirror.docker.ru/debian bookworm main contrib non-free-firmware
deb http://mirror.docker.ru/debian-security bookworm-security main contrib non-free-firmware
deb http://mirror.docker.ru/debian bookworm-updates main contrib non-free-firmware';;
                13) repos='deb http://mirror.docker.ru/debian trixie main contrib non-free-firmware
deb http://mirror.docker.ru/debian-security trixie-security main contrib non-free-firmware
deb http://mirror.docker.ru/debian trixie-updates main contrib non-free-firmware';;
                *) echo "${colors[r]}Неизвестная версия Debian. Продолжаем без изменений.${colors[x]}";;
            esac
        elif echo "$os_info" | grep -q "Ubuntu"; then
            ubuntu_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d '"' -f 2)
            case "$ubuntu_ver" in
                22.04) repos='deb http://mirror.yandex.ru/ubuntu/ jammy main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-security main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-updates main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-backports main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-proposed main restricted universe multiverse
deb http://archive.canonical.com/ubuntu/ jammy partner';;
                20.04) repos='deb http://mirror.yandex.ru/ubuntu/ focal main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-security main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-updates main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-backports main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-proposed main restricted universe multiverse
deb http://archive.canonical.com/ubuntu/ focal partner';;
                *) echo "${colors[r]}Неизвестная версия Ubuntu. Продолжаем без изменений.${colors[x]}";;
            esac
        else
            echo "${colors[r]}Неизвестная операционная система. Продолжаем без изменений.${colors[x]}"
        fi

        if [[ -n "$repos" ]]; then
            echo "$repos" > /etc/apt/sources.list
            echo "${colors[y]}Репозитории успешно обновлены.${colors[x]}"
            apt update && apt upgrade -y && apt full-upgrade -y && apt autoremove -y
        fi
    else
        echo "${colors[r]}Изменение репозиториев отменено.${colors[x]}"
    fi
}

# 5. Функция для установки ПО
setup_software() {
    echo "${colors[g]}5] Установка простого набора ПО${colors[x]}"

    if confirm "${colors[y]}Установить простой набор программ?${colors[x]}" "n"; then
        echo "${colors[r]}Список программ для установки:${colors[x]}"
        echo "$standard_packages"
        read -e -i "$standard_packages" -p "$(echo -e ${colors[g]}"Простой список программ. Можно что то удалить или добавить: "${colors[x]})" user_input
        apt install -y $user_input || echo "${colors[r]}Ошибка при установке пакетов.${colors[x]}"
        cp /usr/share/mc/syntax/sh.syntax /usr/share/mc/syntax/unknown.syntax
        echo "${colors[y]}Установка завершена.${colors[x]}"
    else
        echo "${colors[r]}Установка отменена.${colors[x]}"
    fi
}

# 6. Функция для настройки Chrony
setup_chrony() {
    echo "${colors[g]}6] Настройка Chrony${colors[x]}"

    if confirm "${colors[y]}Хотите настроить Chrony?${colors[x]}" "n"; then
        # Проверка установки Chrony через dpkg
        if ! dpkg -l | grep -q '^ii.*chrony'; then
            echo "${colors[r]}Chrony не установлен. Установите его и повторите попытку.${colors[x]}"
            return
        fi

        # Настройка Chrony
        sed -i '/^pool/d' /etc/chrony/chrony.conf
        echo "$chrony_servers" >> /etc/chrony/chrony.conf

        # Перезапуск Chrony
        systemctl restart chrony
        echo "${colors[y]}Chrony настроен и перезапущен.${colors[x]}"
        chronyc sources
    else
        echo "${colors[r]}Настройка Chrony отменена.${colors[x]}"
    fi
}

# Остальные функции остаются без изменений...

# === Основной код ===
if [[ $EUID -ne 0 ]]; then
    echo "${colors[r]}Этот скрипт должен быть запущен от имени root. Перезапустите его 'sudo bash ./script.sh'.${colors[x]}"
    exit 1
fi

# Меню
while true; do
    clear
    echo "${colors[g]}Настройка Debian/Ubuntu с помощью скрипта https://github.com/saym101/setup${colors[x]}"
    echo "${colors[r]}Запускайте этот скрипт c правами root. Или используя команду sudo${colors[x]}"
    echo "${colors[r]}для использования root напрямую, задайте пароль для root командой 'sudo passwd root'.${colors[x]}"
    echo
    echo "${colors[y]}Выберите номер нужного пункта:${colors[x]}"
    echo "${colors[c]}1.${x}  ${g}Изменить hostname${x}"
    echo "${colors[c]}2.${x}  ${g}Изменить локаль${x}"
    echo "${colors[c]}3.${x}  ${g}Изменить часовой пояс${x}"
    echo "${colors[c]}4.${x}  ${g}Изменить репозитории и обновить систему${x}"
    echo "${colors[c]}5.${x}  ${g}Установить ПО${x}"
    echo "${colors[c]}6.${x}  ${g}Настроить Chrony${x}"
    echo "${colors[c]}7.${x}  ${g}Настроить SSH ключи${x}"
    echo "${colors[c]}8.${x}  ${g}Изменить порт SSH и настроить UFW${x}"
    echo "${colors[c]}9.${x}  ${g}Добавить пользователя${x}"
    echo "${colors[c]}10.${x} ${g}Очистить apt кэш${x}"
    echo "${colors[c]}11.${x} ${g}Перезагрузить систему${x}"
    echo "${colors[c]}12.${x} ${g}Запустить выполнение всех пунктов по порядку${x}"
    echo "${colors[c]}0. Выход${x}"

    read -p "${colors[y]}Введите номер:${x} " choice

    case $choice in
        1) setup_hostname ;;
        2) setup_locale ;;
        3) setup_timezone ;;
        4) setup_repositories ;;
        5) setup_software ;;
        6) setup_chrony ;;
        7) setup_ssh_keys ;;
        8) configure_ssh_and_ufw ;;
        9) add_new_user ;;
        10) clean_apt_cache ;;
        11) reboot_system ;;
        12) run_all_steps ;;
        0) exit 0 ;;
        *) echo "Неверный выбор. Попробуйте еще раз." ;;
    esac

    read -p "${colors[y]}Нажмите Enter для продолжения...${x}"
done
