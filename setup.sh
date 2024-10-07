#!/bin/bash

# Делаем исполняемым chmod +x setup.sh
echo ""  # вывод пустой строки
echo -e "\e[31;1mПо умолчанию ответ на вопрос - нет. Иначе вписать туда - y\e[0m"
echo ""  # вывод пустой строки

# Функция для подтверждения действия (по умолчанию "нет")
confirm() {
    read -p "$1 [y/N]: " choice
    choice=${choice:-n}  # если нажато Enter, то по умолчанию выбирается "нет"
    case "$choice" in 
      y|Y ) return 0;;
      n|N ) return 1;;
      * ) echo "Пожалуйста, введите y или n."; confirm "$1";;
    esac
}

# Шаг 1: Узнаем версию системы
echo "Смотрим что за версия системы стоит..."
cat /etc/os-release
echo ""  # вывод пустой строки

# Шаг 2: Смена имени хоста
if confirm "Хотите изменить имя системы?"; then
    read -p "Введите новое имя хоста: " new_hostname
    hostnamectl set-hostname "$new_hostname"
    echo "Имя хоста изменено на $new_hostname"
    echo ""  # вывод пустой строки
fi

# Шаг 3: Резервное копирование sources.list
if confirm "Хотите сделать резервную копию файла /etc/apt/sources.list?"; then
    cp /etc/apt/sources.list /etc/apt/sources.list.bak
    echo "Резервная копия создана: /etc/apt/sources.list.bak"
    echo ""  # вывод пустой строки
fi

# Шаг 4: Узнаем версию Linux (Debian или Ubuntu) и обновляем репозитории
if confirm "Хотите проверить версию дистрибутива и обновить репозитории?"; then
    os_info=$(cat /etc/os-release)

    # Проверка на наличие Debian или Ubuntu
    if echo "$os_info" | grep -q "Debian"; then
        echo "Обнаружен Debian."
        # Внесение изменений в зависимости от версии Debian
        if echo "$os_info" | grep -q "10"; then
            echo "Устанавливаем репозитории для Debian 10 (Buster)."
            sh -c "echo \"deb http://mirror.docker.ru/debian buster main contrib non-free
deb http://mirror.docker.ru/debian-security buster/updates main contrib non-free
deb http://mirror.docker.ru/debian buster-updates main contrib non-free\" > /etc/apt/sources.list"
        elif echo "$os_info" | grep -q "11"; then
            echo "Устанавливаем репозитории для Debian 11 (Bullseye)."
            sh -c "echo \"deb http://mirror.docker.ru/debian bullseye main contrib non-free
deb http://mirror.docker.ru/debian bullseye-updates main contrib non-free
deb http://mirror.docker.ru/debian-security bullseye-security main contrib non-free\" > /etc/apt/sources.list"
        elif echo "$os_info" | grep -q "12"; then
            echo "Устанавливаем репозитории для Debian 12 (Bookworm)."
            sh -c "echo \"deb http://mirror.docker.ru/debian bookworm main contrib non-free
deb http://mirror.docker.ru/debian-security bookworm-security main contrib non-free
deb http://mirror.docker.ru/debian bookworm-updates main contrib non-free\" > /etc/apt/sources.list"
        elif echo "$os_info" | grep -q "13"; then
            echo "Устанавливаем репозитории для Debian 13 (Trixie)."
            sh -c "echo \"deb http://mirror.docker.ru/debian trixie main contrib non-free
deb http://mirror.docker.ru/debian-security trixie-security main contrib non-free
deb http://mirror.docker.ru/debian trixie-updates main contrib non-free\" > /etc/apt/sources.list"
        fi
    elif echo "$os_info" | grep -q "Ubuntu"; then
        echo "Обнаружен Ubuntu."
        # Внесение изменений в зависимости от версии Ubuntu
        if echo "$os_info" | grep -q "22.04"; then
            echo "Устанавливаем репозитории для Ubuntu 22.04 (Jammy)."
            sh -c "echo \"deb http://mirror.yandex.ru/ubuntu/ jammy main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-security main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-updates main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-backports main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-proposed main restricted universe multiverse
deb http://archive.canonical.com/ubuntu/ jammy partner\" > /etc/apt/sources.list"
        elif echo "$os_info" | grep -q "20.04"; then
            echo "Устанавливаем репозитории для Ubuntu 20.04 (Focal)."
            sh -c "echo \"deb http://mirror.yandex.ru/ubuntu/ focal main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-security main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-updates main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-backports main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-proposed main restricted universe multiverse
deb http://archive.canonical.com/ubuntu/ focal partner\" > /etc/apt/sources.list"
        fi
    else
        # Если версия дистрибутива неизвестна
        echo "Неизвестная версия дистрибутива. Текущая информация:"
        echo "$os_info" | grep "^NAME="

        # Запрос на продолжение или остановку скрипта
        if confirm "Продолжить выполнение скрипта без изменения репозиториев?"; then
            echo "Продолжаем выполнение скрипта без изменения репозиториев."
        else
            echo "Скрипт остановлен пользователем."
            exit 1
        fi
    fi
    echo ""  # вывод пустой строки
fi

# Шаг 5: Обновление системы
echo "."
if confirm "Хотите обновить систему?"; then
    apt update && apt yupgrade -y && apt full-upgrade -y && apt autoremove -y
echo "."
fi

# Шаг 6: Добавление пользователя
if confirm "Хотите добавить нового пользователя?"; then
    read -p "Введите имя нового пользователя: " username
    sudo adduser --home /home/$username $username
    usermod -aG sudo $username
    echo "Пользователь $username добавлен и включен в группу sudo."
echo "."
fi

# Шаг 7: Установка необходимого ПО
if confirm "Хотите установить минимально необходимое ПО?"; then
    apt install -y curl gnupg htop iftop ntpdate ntp network-manager net-tools ca-certificates wget lynx language-pack-ru openssh-server openssh-client xclip mc || true
    systemctl start ssh
# Копируем синтаксис МС для неизвестных файлов
    cp /usr/share/mc/syntax/sh.syntax /usr/share/mc/syntax/unknown.syntax
echo "."
fi


# Шаг 8: Настройка NTP
if confirm "Хотите настроить NTP?"; then
    # Список серверов NTP
    ntp_servers="pool 0.ru.pool.ntp.org
pool 1.ru.pool.ntp.org
pool 2.ru.pool.ntp.org
pool 3.ru.pool.ntp.org"

    # Закомментируем все существующие строки, содержащие 'pool' или 'server'
    sed -i '/^pool\|^server/s/^/#/' /etc/ntp.conf

    # Добавим новые NTP сервера в конец файла
    echo "$ntp_servers" >> /etc/ntp.conf

    echo "Старые серверы NTP закомментированы, новые серверы добавлены в /etc/ntp.conf."

    echo "перезапускаем ntpd"
     systemctl enable ntp || update-rc.d ntp defaults
     systemctl start ntp || service ntp start
echo "."
fi



# Шаг 9: Включение root через SSH
if confirm "Хотите включить root доступ по SSH?"; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sed -i 's/#\?\(PermitRootLogin\s*\).*$/\1 yes/' /etc/ssh/sshd_config
    systemctl restart sshd
echo "."
fi

# Шаг 10: Смена часового пояса
if confirm "Хотите изменить часовой пояс?"; then
    # Вывод текущей даты, часового пояса и локали
    date && timedatectl | grep 'Time zone' && echo && locale
echo "."
    # Список часовых поясов региона "Europe"
    echo "Выберите часовой пояс из региона Europe (по умолчанию Europe/Moscow):"
    timezones=($(timedatectl list-timezones | grep "^Europe/"))
    num_timezones=${#timezones[@]}

    # Показать пронумерованный список в два столбца
    for ((i = 0; i < num_timezones; i+=2)); do
        printf "%2d) %-25s" $((i+1)) "${timezones[i]}"
        if [[ $((i+1)) -lt $num_timezones ]]; then
            printf "%2d) %-25s\n" $((i+2)) "${timezones[i+1]}"
        else
            echo ""
        fi
    done

    # Получить ввод пользователя
    read -p "Введите номер часового пояса (по умолчанию 1 - Europe/Moscow): " choice
    choice=${choice:-1}

    # Проверка на допустимый ввод
    if [[ $choice -ge 1 && $choice -le $num_timezones ]]; then
        selected_timezone=${timezones[$((choice-1))]}
    else
        echo "Некорректный ввод. Устанавливается часовой пояс по умолчанию Europe/Moscow."
        selected_timezone="Europe/Moscow"
    fi

    # Установить выбранный часовой пояс
    timedatectl set-timezone "$selected_timezone"
    echo "Часовой пояс изменен на $selected_timezone."
echo "."
fi


# Шаг 11: Смена раскладки клавиатуры
if confirm "Хотите изменить раскладку клавиатуры и локаль?"; then
    dpkg-reconfigure locales
    dpkg-reconfigure keyboard-configuration
    dpkg-reconfigure console-setup
    echo 'FRAMEBUFFER=Y' >> /etc/initramfs-tools/initramfs.conf
    update-initramfs -u
echo "."
fi

# Шаг 12: Очистка системы
if confirm "Хотите очистить кэш и историю?"; then
    apt clean all && rm -fr /var/cache/*
    history -c && history -w
echo "."
fi

# Шаг 13: Перезагрузка
if confirm "Перезагрузить систему?"; then
    reboot
echo "."
fi

