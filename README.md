# setup.sh
# Настройка Debian\Ubuntu при первой загрузке

### Ссылка для копирования скрипта 
```
wget://https://raw.githubusercontent.com/saym101/setup/main/setup.sh
```
Что умеет скрипт.

1. Меняет hostname
2. Меняет locale По умолчанию скрипт применяет ru_RU.UTF-8
3. Изменяем часовой пояс. По умолчанию скрипт примменяет - Europe/Moscow
4. Установка новых репозиториев xUSSR и обновление системы
   http://mirror.docker.ru/ для Debian систем 10,11,12,13 версий систем
   http://mirror.yandex.ru/ для Ubuntu систем 20.04 22.4 версий систем
6. Установка необходимого ПО
   Можно остаить как есть, можно изменить на свой, можно что то добавить или удалить. У каждого свой вкус.
   По умолчанию используется такой набор: curl gnupg  mc ufw htop iftop ntpdate ntp network-manager net-tools ca-certificates wget lynx language-pack-ru openssh-server openssh-client xclip
8. Настройка NTP сервиса
   Меняет сервера которые используются по умолчанию на эти:
   	pool 0.ru.pool.ntp.org
	pool 1.ru.pool.ntp.org
	pool 2.ru.pool.ntp.org
	pool 3.ru.pool.ntp.org
10. Настройка доступа root через SSH без пароля с ключом.
    Генерирует пару ключей. Прописывает публичный в .ssh/authorized_keys Путь можно сменить. Запрещает доступ а систему через пароль и открывает доступ по ключу.
    Поэтому надо осторожнее, что бы не потерять доступ к системе используя Putty\Kitty
12. Изменение порта для SSH. Настройка UFW
    Позволяет сменить текущий или используемый по умолчанию 22 порт SSH, на случайный из диапазона 1025-49150. Или применить свой любимый порт.
    Откройте новую сессию SSH с установленным новым портом и если получается подключится, выйдите из старой сессии и. перейдите для работы в новой.
12.1 UFW настройки. Оставит по умолчанию 22 порт, если не стали менять порт. Или поменяет на новый порт и закроет доступ на 22 порт. 
13. Добавляем нового пользователя и создаём домашний каталог с папками. Домашней папке будут созданы следующие коталоги.
14. Можно закомментировать ненужное или добавить по аналогии свой.
  mkdir -p "$home_dir/.config"
  mkdir -p "$home_dir/.local"
  mkdir -p "$home_dir/.local/share"
  mkdir -p "$home_dir/Documents"
  mkdir -p "$home_dir/Download"
  mkdir -p "$home_dir/Backup"  
  mkdir -p "$home_dir/Music"
  mkdir -p "$home_dir/Pictures"
  mkdir -p "$home_dir/Video" 
15. Очищаем apt кэш.
16. Перезагрузка компьютера
