#!/bin/bash
clear
# Цвета для вывода
r=`tput setaf 1`  # красный
g=`tput setaf 2`  # зеленый
y=`tput setaf 3`  # желтый
c=`tput setaf 6`  # циановый
p=`tput setaf 5`  # фиолетовый
x=`tput sgr0`     # сброс цвета
b=`tput bold`     # жирный текст

# Текущие настройки
currhostname=$(cat /etc/hostname)
authorizedfile="/root/.ssh/authorized_keys"
sshconfigfile="/etc/ssh/sshd_config"
currusers=$(awk -F: '$3 >= 1000 && $6 ~ /^\/home/ {print $1}' /etc/passwd)
DATE=$(date "+%Y-%m-%d")

echo
echo "${g}Настройка Debian\Ubuntu с помощью скрипта https://github.com/saym101/setup ${x}"
echo
echo "${g}Запускайте этот скрипт только из под sudo или root пользователя. su -l ${x}"
echo "${g}Задав предварительно пароль для root коммандой 'sudo passwd root' ${x}"
echo

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo "${r}Этот скрипт должен быть запущен от имени root. Перезапустите его 'sudo bash ./script.sh' ${x}"
		exit
fi
###################################################################################

#1 Установка hostname
echo "${g}1] Установка hostname ${x}"

# Функция для запроса подтверждения с обработкой ошибок и валидацией ввода
confirm() {
  local msg="$1"
  local default="$2"
  local answer

  while true; do
    read -r -p "${msg} [${default,,}] " answer
    answer="${answer,,}" # Приводим ответ к нижнему регистру

    if [[ -z "$answer" ]]; then
      answer="${default,,}"
    fi

    if [[ "$answer" =~ ^(y|n)$ ]]; then
      break
    else
      echo "${r}Неверный ввод. Пожалуйста, введите 'y' или 'n'.${x}"
    fi
  done

  [[ "$answer" == "y" ]]
}

# Получаем текущее имя хоста
current_hostname=$(hostname)

# Запрашиваем у пользователя, хочет ли он изменить имя хоста
echo "Текущее имя хоста: $current_hostname"
if confirm "Хотите изменить имя хоста?" "y|n"; then

  # Получаем новое имя хоста
  while true; do
    read -r -p "Введите новое имя хоста: " new_hostname
    [[ -n "$new_hostname" ]] && break
    echo "${r}Имя хоста не может быть пустым.${x}"
  done

  # Обновляем /etc/hostname
  echo "$new_hostname" > /etc/hostname

  # Обновляем /etc/hosts: заменяем имя хоста после 127.0.1.1
  sed -i "s/^\(127\.0\.1\.1\)\s.*$/\1 $new_hostname/" /etc/hosts

  # Применяем новое имя хоста
  hostname $new_hostname

  echo "${y}Имя хоста успешно изменено на $new_hostname.${x}"
else
  echo "${r}Отмена изменения имени хоста.${x}"
fi
###################################################################################

# 2. Установка корректной локали
echo "${g}2] Устанавливаем корректную локаль... ${x}"
echo "${g}Текущая локаль: ${x}"
echo ""
locale | grep "^LANG=" # Выводим только строку LANG
echo ""

# Ввод и проверка изменения локали
while true; do
    read -r -p "Меняем локаль? [y/N] " response
    response=${response,,} # Преобразуем в нижний регистр
    [[ -z $response ]] && response="n" # Если введено пустое значение, по умолчанию "n"

    case $response in
        y|yes)
            # Запрашиваем у пользователя новую локаль
            read -r -p "Введите желаемую локаль (по умолчанию ru_RU.UTF-8): " new_locale
            # Если ничего не введено, устанавливаем локаль по умолчанию
            new_locale=${new_locale:-"ru_RU.UTF-8"}
            
            # Устанавливаем локаль в зависимости от системы
            if grep -qi "debian" /etc/os-release; then
                echo "LANG=\"$new_locale\"" > /etc/default/locale
            else
                echo "LANG=$new_locale" > /etc/default/locale
            fi
            
            echo "${y}Локаль '$new_locale' успешно установлена.${x}"
            break
            ;;
        n|no)
            echo "${r}Отмена установки локализации.${x}"
            break
            ;;
        *)
            echo "${r}Неверный выбор. Попробуйте еще раз.${x}"
            ;;
    esac
done
###################################################################################

# 3. Изменяем часовой пояс
read -r -p "${g} 3] Хотите изменить часовой пояс? [y/N] ${x}" response
response=${response,,} # Преобразуем в нижний регистр
response=$(tr -dc '[yn]' <<< "$response")

# Цикл проверки ввода
while true; do
    if [[ $response =~ ^[yn]$ ]]; then
        break
    else
        echo "${r}Неверный выбор. Пожалуйста, введите 'y' или 'n'.${x}"
        read -r -p "3] Хотите изменить часовой пояс? [y/N] " response
        response=${response,,} # Преобразуем в нижний регистр
        response=$(tr -dc '[yn]' <<< "$response")
    fi
done

if [[ $response == 'y' ]]; then
    # ... (вывод текущей даты и часового пояса)

    # Список часовых поясов региона "Europe"
    echo "Выберите часовой пояс из региона Europe (по умолчанию 35 - Europe/Moscow):"

    # Вывод пронумерованного списка часовых поясов в три колонки
    timedatectl list-timezones | grep "^Europe/" | nl -s ") " -w 2 | pr -3 -t -w 80 

    # Получить ввод пользователя
    while true; do 
        read -p "Введите номер часового пояса. По умолчанию: 35) Europe/Moscow.: " choice

        # Если ввод пустой, устанавливаем значение по умолчанию (35)
        if [[ -z "$choice" ]]; then
            choice=35 
        fi

        # Проверка на допустимый ввод
        if ! [[ "$choice" =~ ^[0-9]+$ ]] ; then
            echo "${r}Некорректный ввод. Введите номер из списка.${x}" 
            continue
        fi

        selected_timezone=$(timedatectl list-timezones | grep "^Europe/" | awk -v choice="$choice"  "NR==choice {print}")

        if [[ -z "$selected_timezone" ]]; then
            echo "${r}Некорректный ввод. Введите номер из списка.${x}" 
        else
            break
        fi
    done

    # Установить выбранный часовой пояс
    timedatectl set-timezone "$selected_timezone"
    echo "${y}Часовой пояс изменен на $selected_timezone.${x}"
    echo 
else
    echo "${r}Процедура изменения часового пояса отменена.${x}"
fi
###################################################################################

# 4. Установка новых репозиториев xUSSR и обновление системы
echo "${g}4] Установка репозиториев и обновление системы${x}"
echo ""
while true; do
    read -r -p "${g} Хотите сменить источник пакетов на xUSSR? [y/N]${x} " response
    response=${response,,} # Преобразуем в нижний регистр

    if [[ $response == 'n' || $response == 'no' ]]; then
        echo "${r}Изменение репозиториев отменено. Продолжаем выполнение скрипта без изменений.${x}"
        break # Выходим из цикла, если ответ "нет"
    elif [[ $response == 'y' || $response == 'yes' ]]; then
        # Получаем информацию о системе
        os_info=$(cat /etc/os-release)

        ## Определяем систему и соответствующие репозитории
        if echo "$os_info" | grep -q "Debian"; then
            debian_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d '"' -f 2)
            case "$debian_ver" in
                10)  # Debian 10
                    repos='deb http://mirror.docker.ru/debian buster main contrib non-free
deb http://mirror.docker.ru/debian-security buster/updates main contrib non-free
deb http://mirror.docker.ru/debian buster-updates main contrib non-free';;
                11)  # Debian 11
                    repos='deb http://mirror.docker.ru/debian bullseye main contrib non-free
deb http://mirror.docker.ru/debian bullseye-updates main contrib non-free
deb http://mirror.docker.ru/debian-security bullseye-security main contrib non-free';;
                12)  # Debian 12
                    repos='deb http://mirror.docker.ru/debian bookworm main contrib non-free
deb http://mirror.docker.ru/debian-security bookworm-security main contrib non-free
deb http://mirror.docker.ru/debian bookworm-updates main contrib non-free';;
                13)  # Debian 13
                    repos='deb http://mirror.docker.ru/debian trixie main contrib non-free
deb http://mirror.docker.ru/debian-security trixie-security main contrib non-free
deb http://mirror.docker.ru/debian trixie-updates main contrib non-free';;
                *)   # Неизвестная версия Debian
                    echo "${r}Неизвестная версия Debian. Текущая информация:${x}"
                    echo "$os_info" | grep "^VERSION_ID="
                    echo "${y}Продолжаем выполнение без изменений репозиториев.${x}"
                    repos=''
                    ;;
            esac
        elif echo "$os_info" | grep -q "Ubuntu"; then
            ubuntu_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d '"' -f 2)
            case "$ubuntu_ver" in
                22.04)  # Ubuntu 22.04
                    repos='deb http://mirror.yandex.ru/ubuntu/ jammy main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-security main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-updates main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-backports main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ jammy-proposed main restricted universe multiverse
deb http://archive.canonical.com/ubuntu/ jammy partner';;
                20.04)  # Ubuntu 20.04
                    repos='deb http://mirror.yandex.ru/ubuntu/ focal main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-security main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-updates main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-backports main restricted universe multiverse
deb http://mirror.yandex.ru/ubuntu/ focal-proposed main restricted universe multiverse
deb http://archive.canonical.com/ubuntu/ focal partner';;
                *)      # Неизвестная версия Ubuntu
                    echo "${r}Неизвестная версия Ubuntu. Текущая информация:${x}"
                    echo "$os_info" | grep "^VERSION_ID="
                    echo "${y}Продолжаем выполнение без изменений репозиториев.${x}"
                    repos=''
                    ;;
            esac
        else
            echo "${r}Неизвестная операционная система. Текущая информация:${x}"
            echo "$os_info" | grep "^NAME="
            echo "${y}Продолжаем выполнение без изменений репозиториев.${x}"
            repos=''
        fi

        # Обновление системы ТОЛЬКО если репозитории были изменены
        if [[ -n $repos ]]; then 
            echo "${g} Обновление системы после смены источника пакетов${x}"
            echo "${r} Внимание! Сейчас будет выполнено обновление системы с обновлением репозиториев.${x}"
echo ""
            apt update && apt upgrade -y && apt full-upgrade -y && apt autoremove -y
            echo ""
        fi
        break # Выходим из цикла, если ответ "да" и обновление выполнено
    else
        echo "Неверный ввод. Пожалуйста, введите 'y' (yes) или 'n' (no)."
    fi
done

echo ""

###################################################################################

# 5. Установка необходимого ПО
echo "${g} 5] Установка минимального набора ПО${x}"
standard_packages="curl gnupg htop iftop ntpdate ntp network-manager net-tools ca-certificates wget lynx language-pack-ru openssh-server openssh-client xclip mc ufw"

# Запрос на установку до вывода списка
while true; do
    read -p "Установить набор стандартных программ? [y/N]: " install_confirmation
    install_confirmation=${install_confirmation,,} # Преобразуем в нижний регистр

    if [[ $install_confirmation == 'y' ]]; then
        # Вывод стандартного списка программ и предложение редактировать его
        echo "${r}Список программ для установки:${x}"
        echo "$standard_packages"
        echo

        # Предварительное заполнение пользовательского списка программ
        echo -e "${y}Отредактируйте список программ для установки (или нажмите Enter для использования предложенного): ${x}"
        read -e -i "$standard_packages" user_input 

        # Выполняем установку
        apt install -y $user_input || echo "${r}Ошибка при установке пакетов.${x}"
        # Копируем синтаксис МС для неизвестных файлов
        cp /usr/share/mc/syntax/sh.syntax /usr/share/mc/syntax/unknown.syntax
        echo "${y}Установка завершена.${x}"
        break # Выходим из цикла после установки
    elif [[ $install_confirmation == 'n' || -z $install_confirmation ]]; then
        echo "${r}Установка отменена.${x}"
        break # Выходим из цикла, если установка отменена
    else
        echo "${r}Неверный ввод. Пожалуйста, введите 'y' для продолжения или 'n' для отмены.${x}"
    fi
done

###################################################################################

# 6. Настройка NTP сервиса
echo "${g} 7] Настройка NTP сервиса.${x}"
# Функция для запроса подтверждения
confirm() {
    local msg="$1"
    while true; do
        read -r -p "${msg} [y/N] " response
        response=${response,,} # Преобразуем в нижний регистр

        if [[ $response == 'y' || $response == 'yes' ]]; then
            return 0  # true
        elif [[ $response == 'n' || $response == 'no' || -z $response ]]; then 
            return 1  # false
        else
            echo "${r} Неверный ввод. Пожалуйста, введите 'y' или 'n'. ${x}"
        fi
    done
}

# Настройка NTP сервиса

echo "${g} 6] Настройка NTP ${x}"
if confirm "${y}Хотите настроить NTP? ${x}"; then
    # Список серверов NTP
    ntp_servers="pool 0.ru.pool.ntp.org
pool 1.ru.pool.ntp.org
pool 2.ru.pool.ntp.org
pool 3.ru.pool.ntp.org"

    # Закомментируем все существующие строки, содержащие 'pool' или 'server' с учетом пробелов
    sed -i '/^[[:space:]]*pool\|^[[:space:]]*server/s/^/#/' /etc/ntp.conf

    # Добавим новые NTP сервера в конец файла
    echo "$ntp_servers" >> /etc/ntp.conf

    echo "${y}Старые серверы NTP закомментированы, новые серверы добавлены в /etc/ntp.conf.${x}"

    echo "${r}Перезапускаем NTP${x}"
systemctl restart ntp || service restart ntp
    echo "."

    # Вывод ntpq -p
    echo "${y} Информация о синхронизации времени: ${x}"
    ntpq -p
    echo "."
fi

###################################################################################

# 7. Настройка доступа root через SSH без пароля с ключом.
echo ""
echo "${g} 7] Настройка доступа через SSH-ключи.${x}"

# Проверка наличия файла authorized_keys
if [ -f "$authorizedfile" ]; then
    echo "${y}Найден файл публичного ключа для удаленного доступа: $authorizedfile ${x}"
  echo
    currsshauthkeys="$(cat $authorizedfile)"
    echo "${y}Его текущее содержимое: ${x}"
    echo
    echo "$currsshauthkeys"
else
    echo "${r}Файл авторизованных ключей не найден. Он будет создан при необходимости.${x}"
fi

# Запрос на создание ключей
while true; do
    echo
    read -p "${y} Хотите создать новую пару SSH-ключей или оставить как есть? (y/N): ${x}" -n 1 -r
    echo

    # Установка значений по умолчанию
    if [[ -z $REPLY ]]; then
        REPLY='n'
    fi

    # Проверка на валидность ввода
    if [[ $REPLY =~ ^[YyNn]$ ]]; then
        break
    else
        echo "${r}Ошибка: пожалуйста, введите 'y' для да или 'n' для нет.${x}"
    fi
done

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Получение данных от пользователя для нового ключа
    while true; do
        read -r -p "${y}Введите адрес своей электронной почты для привязки к SSH-ключу: ${x}" email

        # Валидация email
        if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo "${r}Ошибка: введён некорректный email. Пожалуйста, введите корректный адрес электронной почты.${x}"
        fi
    done

    # Запрашиваем путь к директории с установкой пути по умолчанию
    read -r -p "${y}Введите путь к директории, где будут созданы ключи (по умолчанию ~/.ssh): ${x}" directory

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
            echo "${r}Ключ успешно создан по пути: $key_path ${x}"
            break
        else
            echo "${r}Ошибка при создании ключа.${x}"
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
        echo "${y}Публичный ключ добавлен в $authorizedfile.${x}"
    else
        echo "${y}Публичный ключ уже существует в $authorizedfile.${x}"
    fi

    echo "${y}Настройка безопасности доступа root только через SSH.${x}"
    echo
     # Изменяем первые четыре вхождения директив
sed -i '0,/^#.*PermitRootLogin/s/^#\([[:space:]]*PermitRootLogin.*\)/\1/' $sshconfigfile
sed -i '0,/^#.*PermitRootLogin/s/^#\([[:space:]]*PermitRootLogin.*\)/\1/' $sshconfigfile || echo "${r}Ошибка: не удалось изменить PermitRootLogin${x}"
sed -i '0,/^#.*PasswordAuthentication/s/^#\([[:space:]]*PasswordAuthentication.*\)/\1/' $sshconfigfile
sed -i '0,/^#.*PasswordAuthentication/s/^#\([[:space:]]*PasswordAuthentication.*\)/\1/' $sshconfigfile || echo "${r}Ошибка: не удалось изменить PermitRootLogin${x}"
sed -i '0,/^#.*PermitEmptyPasswords/s/^#\([[:space:]]*PermitEmptyPasswords.*\)/\1/' $sshconfigfile
sed -i '0,/^#.*PermitEmptyPasswords/s/^#\([[:space:]]*PermitEmptyPasswords.*\)/\1/' $sshconfigfile || echo "${r}Ошибка: не удалось изменить PermitRootLogin${x}"
sed -i '0,/^#.*PubkeyAuthentication/s/^#\([[:space:]]*PubkeyAuthentication.*\)/\1/' $sshconfigfile
sed -i '0,/^#.*PubkeyAuthentication/s/^#\([[:space:]]*	.*\)/\1/' $sshconfigfile || echo "${r}Ошибка: не удалось изменить PermitRootLogin${x}"


    echo "${y}Изменено 'PermitRootLogin' на 'prohibit-password', 'PasswordAuthentication' на 'no', 'PermitEmptyPasswords' на 'no'. Вход по паролю для root отключен.${x}"
    echo "${y}Изменено 'PubkeyAuthentication' на 'yes'. Аутентификация по ключам включена.${x}"

    # Перезапуск SSHD
    echo "${r}Перезапускаем SSH...${x}"
 #   systemctl restart ssh 
    echo
    echo "${y}Настройка завершена! Убедитесь, что ключи правильно добавлены для доступа.${x}"
    echo ""	
else
    echo "${r}Создание SSH-ключей отменено. Продолжаем выполнение скрипта.${x}"
    echo ""
fi

###################################################################################

# 8. Изменение порта для SSH. Настройка UFW
function configure_ssh_port() {
    echo
    echo "8] Изменение порта для SSH... Первоначальная настройка UFW..."
    echo

    # Получение текущего значения порта SSH
    current_ssh_port=$(grep '^ *Port *' "$sshconfigfile" | awk '{print $2}')

    # Проверка существования строки 'Port'
    if grep -Fq "Port " "$sshconfigfile"; then
        echo "Проверяем, закомментирована строка 'Port' или нет..."

        # Проверка синтаксиса строки 'Port'
        if grep -Eq '^ *Port ' "$sshconfigfile"; then
            echo "На данный момент комментирование 'Port' уже было снято."
            echo "Текущий порт SSH: $current_ssh_port"
        else
            echo "Строка с номером порта была закомментирована."
            echo "Снимаем комментарий."
            sed -i "/^ *#Port/c\Port 22" "$sshconfigfile"
            echo "Порт установлен на 22"
            current_ssh_port=22  # Обновляем текущий порт после снятия комментария
        fi
    else
        echo "'Port' не найден. Добавляем его и устанавливаем на 22."
        echo "Port 22" >> "$sshconfigfile"
        current_ssh_port=22
    fi

    # Запрос на изменение порта
    read -p "Изменить текущий порт $current_ssh_port на случайный из диапазона 1025-49150? (Y/n): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Смена порта на случайный
        random_port=$(( ( RANDOM % 48126 ) + 1025 ))
        sed -i "/^ *Port /c\Port $random_port" "$sshconfigfile"
        echo "Порт изменён на $random_port."
        sshport=$random_port
    else
        # Оставляем текущий порт
        echo "Оставляем текущий порт SSH: $current_ssh_port."
        sshport=$current_ssh_port
    fi
}

# Вызов функции настройки порта SSH
configure_ssh_port

# Перезапуск SSH
echo "Перезапускаем SSH для применения изменений..."
systemctl restart ssh
echo

# Настройка UFW
echo
# Сброс настроек по умолчанию
echo "Сброс настроек UFW по умолчанию"
echo
yes | ufw reset

# Настройка UFW
if [[ $sshport -eq 22 ]]; then
    echo "Оставляем 22 порт открытым..."
    ufw allow 22
    port_status="Порт 22 открыт."
else
    echo "Закрываем 22 порт и открываем порт $sshport..."
    ufw deny 22
    ufw allow "$sshport"
    port_status="Порт 22 закрыт, открыт порт $sshport."
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

###################################################################################

# 9. Добавление нового пользователя
echo "9] Добавление пользователя без прав root."
# Функция подтверждения
confirm() {
  local input
  while true; do
    read -p "$1 (Y/n): " -n 1 -r
    echo
    input=$REPLY
    if [[ $input =~ ^[Yy]$ ]]; then
      return 0
    elif [[ $input =~ ^[Nn]$ ]]; then
      return 1
    else
      echo "Неверный ввод. Пожалуйста, введите 'Y' или 'n'."
    fi
  done
}

# Функция создания домашнего каталога с папками
create_home_dir() {
  local username="$1"
  local home_dir="/home/$username"

  # Создание домашнего каталога
  mkdir -p "$home_dir"

  # Создание папок в домашнем каталоге
  mkdir -p "$home_dir/.config"
  mkdir -p "$home_dir/.local"
  mkdir -p "$home_dir/.local/share"
  mkdir -p "$home_dir/Documents"
  mkdir -p "$home_dir/Download"
  mkdir -p "$home_dir/Backup"  
#  mkdir -p "$home_dir/Music"
#  mkdir -p "$home_dir/Pictures"
#  mkdir -p "$home_dir/Video"

  # Создание пустого файла .bashrc
  touch "$home_dir/.bashrc"
}

####################################################################################

# 10. Добавление нового пользователя
echo "10] Добавление пользователя без прав root."
echo "Текущие пользователи: $currusers"

while true; do
  if confirm "Хотите добавить нового пользователя?"; then
    read -p "Введите имя нового пользователя: " username

    # Проверка имени пользователя
    if id -u "$username" >/dev/null 2>&1; then
      echo "Пользователь $username уже существует. Попробуйте другое имя."
    else
      # Добавление пользователя
      sudo useradd --home /home/$username $username
      sudo usermod -aG sudo $username

      # Создание домашнего каталога с папками
      create_home_dir "$username"

      echo "Пользователь $username добавлен и включен в группу sudo."
      echo "Создан домашний каталог с папками."
      break # Выход из цикла, если пользователь добавлен
    fi
  else
    break # Выход из цикла, если пользователь отказался добавлять пользователя
  fi
done

###################################################################################

# Очистка системы
echo "${g}Очищаем apt кэш.${x}"
    apt clean all && rm -fr /var/cache/*
echo ""


echo "${g}${g}Настройка завершена.${x}${x}${x}${x}${x}${x}"
echo
echo "${g}Настоятельно рекомендуется перезагрузить сейчас систему для применения изменений.${x}${x}${x}${x}${x}"
echo
read -p "${r}Перезагрузить систему? (Y/n): " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "${r}ПЕРЕЗАГРУЗКА СИСТЕМЫ${x}${x}${x}${x}"
    echo
    echo "${g}Спасибо за использование этого скрипта!${x}${x}${x}"
    echo "reboot"
    reboot
else
    echo
    echo "${r}Пропускаем перезагрузку системы. Не забудьте сделать это вручную!${x}${x}"
    echo
    echo "${g}Спасибо за использование этого скрипта!${x}"
    echo
fi
