#!/bin/bash
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Только функции SSH, без запуска главного меню и изменения реальных служб.
source <(sed -n '/^ssh_apply_listener()/,/^# 07\./p' "$1" | sed '$d')
declare -A colors=([r]="" [g]="" [y]="" [c]="" [x]="")
sshconfigfile="$tmp/sshd_config"
command_exists() { return 0; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
get_ssh_configured_port() { awk '/^Port / {print $2}' "$sshconfigfile"; }
backup_file() { cp "$1" "$tmp/backup"; echo "$tmp/backup"; }
restore_file() { cp "$2" "$1"; }
confirm() { return 0; }
ufw_is_installed() { return 1; }
sleep() { :; }
sshd() {
    if [ "$1" = -t ]; then
        [ "$scenario" != invalid ]
    else
        printf 'port %s\n' "$(get_ssh_configured_port)"
        [ "$scenario" != include ] || printf 'port 2222\n'
    fi
}
ss() {
    if [ "$1" = -H ]; then
        printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("sshd",pid=9,fd=3))\n' "$(cat "$tmp/listening")"
    fi
}
systemctl() {
    printf '%s\n' "$*" >> "$tmp/calls"
    case "$1" in
        is-active)
            if [ "${*: -1}" = ssh.socket ]; then [ "$socket" = 1 ]; else return 0; fi ;;
        show) echo "$killmode" ;;
        reload)
            [ "$scenario" != reload_fail ] || return 1
            if [ "$scenario" != stale ]; then get_ssh_configured_port > "$tmp/listening"; fi ;;
        restart)
            if [ "$scenario" = restart_fail ] && [ ! -f "$tmp/failed" ]; then
                touch "$tmp/failed"; return 1
            fi
            if [ "$scenario" != stale ]; then get_ssh_configured_port > "$tmp/listening"; fi ;;
        *) return 0 ;;
    esac
}
run_case() {
    scenario="$1"; socket="$2"; expected="$3"; killmode="${4:-process}"
    printf 'Port 22\n' > "$sshconfigfile"
    printf '22\n' > "$tmp/listening"
    : > "$tmp/calls"
    rm -f "$tmp/failed"
    ssh_port=22
    if change_ssh_port <<< 10057 > "$tmp/output" 2>&1; then result=0; else result=1; fi
    if [ "$result" != "$expected" ]; then cat "$tmp/output"; echo "FAIL: $scenario"; exit 1; fi
    if [ "$expected" = 0 ]; then
        [ "$(get_ssh_configured_port)" = 10057 ]
        [ "$(cat "$tmp/listening")" = 10057 ]
        [ "$ssh_port" = 10057 ]
        if [ "$socket" = 1 ]; then
            grep -q '^daemon-reload$' "$tmp/calls"
            grep -q '^stop ssh.service$' "$tmp/calls"
            grep -q '^restart ssh.socket$' "$tmp/calls"
            grep -q '^start ssh.service$' "$tmp/calls"
        else
            ! grep -q 'ssh.socket' <(grep -v '^is-active' "$tmp/calls")
        fi
    else
        [ "$(get_ssh_configured_port)" = 22 ]
        [ "$(cat "$tmp/listening")" = 22 ]
        ! grep -q 'SSH слушает TCP/10057' "$tmp/output"
    fi
    echo "PASS: $scenario socket=$socket"
}
run_case normal 0 0
run_case normal 1 0
run_case reload_fail 0 0
run_case restart_fail 1 1
run_case stale 1 1
run_case stale 0 1
run_case invalid 1 1
run_case include 1 1
run_case unsafe_killmode 1 1 control-group
# Отмена не изменяет файл и не трогает systemd.
: > "$tmp/calls"
change_ssh_port <<< "" > "$tmp/output"
[ ! -s "$tmp/calls" ]
echo 'PASS: cancel'
