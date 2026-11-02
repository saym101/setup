#!/bin/bash
# Изолированные проверки: ни один настоящий сетевой сервис не вызывается.
set -eu
script="${1:-setup.sh}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
awk '/^network_interfaces_walk\(\)/ {copy=1} copy {print}
    /^network_networkd_edit_file\(\)/ {last=1} last && /^}/ {exit}' "$script" |
    sed "s|/etc/|$tmp/etc/|g; s|/run/|$tmp/run/|g; s|/lib/|$tmp/lib/|g" > "$tmp/functions"
source "$tmp/functions"
declare -A colors=([r]="" [g]="" [c]="" [y]="" [x]="")
# Windows Git Bash: пути внутри Python heredoc автоматически не конвертируются.
python3() {
    local body
    body=$(cat)
    if command -v cygpath >/dev/null; then
        body="${body//"$tmp"/$(cygpath -m "$tmp")}"
    fi
    printf '%s\n' "$body" | command "${PYTHON_BIN:-python3}" "$@"
}
command_exists() {
    case "$1" in
        ifquery) [ "$have_ifquery" = 1 ] ;;
        netplan) [ "$have_netplan" = 1 ] ;;
        *) return 0 ;;
    esac
}
systemctl() {
    case "${*: -1}" in
        systemd-networkd) [ "$nd_active" = 1 ] ;;
        NetworkManager) [ "$nm_active" = 1 ] ;;
        *) return 0 ;;
    esac
}
networkctl() {
    if [ "${2:-}" = ens3 ] && [ -n "$fixture_network_file" ]; then
        printf 'Network File: %s\nState: routable (configured)\n' "$fixture_network_file"
    else
        printf 'Network File: n/a\nState: routable (unmanaged)\n'
    fi
}
nmcli() {
    [ "${*: -1}" = "$nm_iface" ] || return 0
    case "$2" in
        GENERAL.CON-UUID) printf '%s\n' "$nm_uuid" ;;
        GENERAL.STATE) printf '%s\n' "$nm_state" ;;
    esac
}
ifquery() { [ "$ifquery_ok" = 1 ]; }
reset_case() {
    rm -rf "$tmp/etc" "$tmp/run" "$tmp/lib"
    mkdir -p "$tmp/etc/network/interfaces.d" "$tmp/run/network" "$tmp/etc/systemd/network" \
        "$tmp/etc/netplan" "$tmp/lib/netplan" "$tmp/run/netplan" \
        "$tmp/run/NetworkManager/system-connections" "$tmp/etc/NetworkManager/system-connections"
    printf 'auto lo\niface lo inet loopback\n' > "$tmp/etc/network/interfaces"
    : > "$tmp/run/network/ifstate"
    printf 'nameserver 9.9.9.9\n' > "$tmp/etc/resolv.conf"
    have_ifquery=1; have_netplan=1; ifquery_ok=1
    nd_active=0; nm_active=0; fixture_network_file=""; nm_iface=ens3
    nm_uuid=""; nm_state="100 (connected)"
}
assert_backend() {
    local expected="$1"
    network_detect_backend "${2:-ens3}" || :
    if [ "$NET_BACKEND" != "$expected" ]; then
        echo "FAIL: expected=$expected actual=$NET_BACKEND reason=$NET_BACKEND_REASON"
        exit 1
    fi
    echo "PASS: $case_name"
}
eni() {
    printf 'auto ens3\niface ens3 inet static\n    address 192.0.2.10/24\n' >> "$tmp/etc/network/interfaces"
}
nd() {
    nd_active=1
    fixture_network_file="$tmp/etc/systemd/network/05-provider.network"
    printf '[Match]\nName=ens3\n[Network]\nAddress=192.0.2.10/24\n' > "$fixture_network_file"
}
yaml_source() {
    cat > "$tmp/etc/netplan/50-cloud-init.yaml" <<'YAML'
network:
  version: 2
  ethernets:
    uplink:
      match:
        macaddress: "52:54:00:11:22:33"
      set-name: ens3
      dhcp4: true
YAML
}
netplan_nd() {
    nd_active=1
    fixture_network_file="$tmp/run/systemd/network/10-netplan-uplink.network"
    yaml_source
}
nm() {
    nm_active=1
    nm_uuid=12345678-1234-1234-1234-123456789abc
    printf '[connection]\nuuid=%s\n' "$nm_uuid" > "$tmp/etc/NetworkManager/system-connections/ethernet.nmconnection"
}
reset_case; case_name="ifupdown despite installed netplan"; eni
printf 'ens3=ens3\n' > "$tmp/run/network/ifstate"
assert_backend interfaces
[ "$NET_BACKEND_FILE" = "$tmp/etc/network/interfaces" ]

reset_case; case_name="native networkd uses actual file"; nd
assert_backend networkd
[ "$(network_networkd_target ens3)" = "$tmp/etc/systemd/network/05-provider.network" ]

reset_case; case_name="Debian or Ubuntu netplan/networkd, ID differs from device"; netplan_nd
assert_backend netplan
[ "$NET_CONFIG_ID" = uplink ] && [ "$NET_RENDERER" = networkd ]

reset_case; case_name="native NetworkManager UUID"; nm
assert_backend networkmanager
[ "$NET_NM_UUID" = "$nm_uuid" ]

reset_case; case_name="Netplan generated NetworkManager profile"; nm; yaml_source
rm "$tmp/etc/NetworkManager/system-connections/ethernet.nmconnection"
printf '[connection]\nuuid=%s\n' "$nm_uuid" > "$tmp/run/NetworkManager/system-connections/netplan-uplink.nmconnection"
assert_backend netplan
[ "$NET_RENDERER" = NetworkManager ]

reset_case; case_name="two managers on different interfaces"; nd; nm; nm_iface=ens4
assert_backend networkd ens3
assert_backend networkmanager ens4

reset_case; case_name="networkd plus active ifupdown conflict"; nd; eni
printf 'ens3=ens3\n' > "$tmp/run/network/ifstate"
assert_backend conflict
! network_require_backend ens3 >/dev/null

reset_case; case_name="networkd plus NetworkManager conflict"; nd; nm
assert_backend conflict

reset_case; case_name="stale ifstate without source is not owner"; nd
printf 'ens3=ens3\n' > "$tmp/run/network/ifstate"
assert_backend networkd

reset_case; case_name="inactive alternate interfaces configuration is reported"; nd; eni
assert_backend networkd
[ -n "$NET_BACKEND_WARNING" ]

reset_case; case_name="installed netplan and YAML alone do not identify owner"; yaml_source
assert_backend unknown

reset_case; case_name="generated file without source YAML"; netplan_nd
rm "$tmp/etc/netplan/50-cloud-init.yaml"
assert_backend unknown

reset_case; case_name="malformed YAML"; netplan_nd
printf 'network: [\n' > "$tmp/etc/netplan/50-cloud-init.yaml"
assert_backend unknown

reset_case; case_name="runtime YAML shadowing source is rejected"; netplan_nd
cp "$tmp/etc/netplan/50-cloud-init.yaml" "$tmp/run/netplan/50-cloud-init.yaml"
assert_backend unknown

reset_case; case_name="source include and cycle"; eni
mv "$tmp/etc/network/interfaces" "$tmp/etc/network/interfaces.d/eth.cfg"
printf 'source interfaces.d/*.cfg\n' > "$tmp/etc/network/interfaces"
printf 'source ../interfaces\n' >> "$tmp/etc/network/interfaces.d/eth.cfg"
assert_backend interfaces
[ "$NET_BACKEND_FILE" = "$tmp/etc/network/interfaces.d/eth.cfg" ]

reset_case; case_name="source-directory excludes backup files"; eni
mv "$tmp/etc/network/interfaces" "$tmp/etc/network/interfaces.d/ens3"
printf 'source-directory interfaces.d\n' > "$tmp/etc/network/interfaces"
cp "$tmp/etc/network/interfaces.d/ens3" "$tmp/etc/network/interfaces.d/ens3.bak"
assert_backend interfaces

reset_case; case_name="duplicate ifupdown sources"; eni
cp "$tmp/etc/network/interfaces" "$tmp/etc/network/interfaces.d/ens3"
printf 'source interfaces.d/*\n' >> "$tmp/etc/network/interfaces"
assert_backend conflict

reset_case; case_name="shared networkd match refused before editing"; nd
sed -i 's/Name=ens3/Name=en*/' "$fixture_network_file"
! network_require_backend ens3 >/dev/null
echo "PASS: $case_name"

reset_case; case_name="externally reflected NM profile does not claim interface"; nd; nm
nm_state="100 (connected (externally))"
assert_backend networkd

reset_case; case_name="ifquery missing is not silently assumed"; eni; have_ifquery=0
assert_backend unknown

reset_case; case_name="shared Netplan match refused"; netplan_nd
cat > "$tmp/etc/netplan/50-cloud-init.yaml" <<'YAML'
network:
  ethernets:
    uplink:
      match:
        name: "en*"
      dhcp4: true
YAML
assert_backend unknown

# До любого изменения runtime обязательна успешная проверка владельца.
for fn in network_disable_ipv6 network_enable_ipv6 network_change_mtu network_change_mac; do
    body=$(sed -n "/^$fn()/,/^}/p" "$script")
    guard=$(printf '%s\n' "$body" | grep -n 'network_require_backend' | head -1 | cut -d: -f1)
    write=$(printf '%s\n' "$body" | grep -nE '^[[:space:]]*(sysctl -w|rm -f|if ip link set)' | head -1 | cut -d: -f1)
    [ -n "$guard" ] && [ "$guard" -lt "$write" ]
done
echo 'PASS: backend guard precedes sysctl/ip/file writes'

reset_case; case_name="ambiguous NM profile source refused"; nm
cp "$tmp/etc/NetworkManager/system-connections/ethernet.nmconnection" "$tmp/run/NetworkManager/system-connections/netplan-other.nmconnection"
assert_backend unknown

reset_case; case_name="native networkd drop-in refused"; nd
mkdir -p "$fixture_network_file.d"
printf '[Network]\nDNS=9.9.9.9\n' > "$fixture_network_file.d/custom.conf"
! network_require_backend ens3 >/dev/null
echo "PASS: $case_name"

# Проверяем реальные writer-функции на файлах внутри временной папки.
for fn in network_apply_interfaces network_apply_networkd detect_system network_netplan_write_override; do
    sed -n "/^$fn()/,/^}/p" "$script" |
        sed "s|/etc/|$tmp/etc/|g; s|/run/|$tmp/run/|g; s|/lib/|$tmp/lib/|g" >> "$tmp/writers"
done
source "$tmp/writers"
backup_file() { cp "$1" "$1.backup"; printf '%s\n' "$1.backup"; }
ifdown() { :; }
ifup() { :; }
network_cidr_to_netmask() { echo 255.255.255.0; }
network_revert_interfaces() { return 1; }
network_revert_networkd() { return 1; }
running_via_ssh=0

reset_case; case_name="ifupdown writes included file and preserves IPv6/other auto entries"; eni
mv "$tmp/etc/network/interfaces" "$tmp/etc/network/interfaces.d/ens3"
printf 'auto lo ens3 ens4\niface ens3 inet6 auto\n' >> "$tmp/etc/network/interfaces.d/ens3"
printf 'source interfaces.d/*\n' > "$tmp/etc/network/interfaces"
assert_backend interfaces
network_apply_interfaces ens3 static 192.0.2.20 24 192.0.2.1 1.1.1.1
grep -q 'address 192.0.2.20' "$tmp/etc/network/interfaces.d/ens3"
grep -q '^iface ens3 inet6 auto$' "$tmp/etc/network/interfaces.d/ens3"
grep -q '^auto lo ens4$' "$tmp/etc/network/interfaces.d/ens3"
! grep -q '192.0.2.20' "$tmp/etc/network/interfaces"

reset_case; case_name="native networkd preserves IPv6 and unrelated settings"; nd
printf 'Address=2001:db8::1/64\nGateway=2001:db8::ff\nDHCP=yes\nDNS=9.9.9.9\nLLMNR=no\n' >> "$fixture_network_file"
assert_backend networkd
network_apply_networkd ens3 static 192.0.2.30 24 192.0.2.1 1.1.1.1
grep -q 'Address=2001:db8::1/64' "$fixture_network_file"
grep -q 'Gateway=2001:db8::ff' "$fixture_network_file"
grep -q '^DHCP=ipv6$' "$fixture_network_file"
grep -q '^LLMNR=no$' "$fixture_network_file"
grep -q '^Address=192.0.2.30/24$' "$fixture_network_file"
! grep -q '192.0.2.10' "$fixture_network_file"
! grep -q '^DNS=9.9.9.9$' "$fixture_network_file"

reset_case; case_name="netplan writer uses ID and per-interface renderer"; nm; yaml_source
rm "$tmp/etc/NetworkManager/system-connections/ethernet.nmconnection"
printf '[connection]\nuuid=%s\n' "$nm_uuid" > "$tmp/run/NetworkManager/system-connections/netplan-uplink.nmconnection"
assert_backend netplan
file=$(network_netplan_write_override ens3 static 192.0.2.40 24 192.0.2.1 1.1.1.1)
grep -q '^    uplink:$' "$file"
grep -q '^      renderer: NetworkManager$' "$file"
! grep -q '^  renderer:' "$file"

printf 'ID=debian\nVERSION_ID=13\nPRETTY_NAME="Debian 13"\n' > "$tmp/etc/os-release"
detect_system
[ "$SYSTEM_NAME" = "Debian 13" ] && [ "$SYSTEM_SUPPORTED" = 1 ]
printf 'ID=ubuntu\nVERSION_ID=24.04\nPRETTY_NAME="Ubuntu 24.04"\n' > "$tmp/etc/os-release"
detect_system
[ "$SYSTEM_NAME" = "Ubuntu 24.04" ] && [ "$SYSTEM_SUPPORTED" = 1 ]
printf 'ID=other\nVERSION_ID=1\nPRETTY_NAME="Other"\n' > "$tmp/etc/os-release"
detect_system
[ "$SYSTEM_SUPPORTED" = 0 ]
echo 'PASS: OS detection is independent from network backend'
