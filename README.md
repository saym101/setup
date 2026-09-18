# 🚀 Debian/Ubuntu Server Setup & Admin Toolkit

*[Читать на русском](README_RU.md)*

A comprehensive, interactive Bash script for configuring and administering a Debian or Ubuntu server — initial setup (hostname, locale, timezone, SSH hardening, users) plus ongoing network, firewall, and MOTD management. Single self-contained file, menu-driven, colored output.

## ✨ Features

### 📦 Software
* Two independently editable package sets — a **recommended** baseline and a separate **diagnostic tools** set (`ethtool`, `mtr-tiny`, `net-tools`, `nmap`, `smartmontools`, `sysstat`, `tcpdump`, `tmux`, `qrencode`, `whois`) — plus an **"install everything"** option combining both lists into one editable prompt. Both are shown before install and editable inline (add/remove packages) without touching the code.
* The 7-Zip package name is resolved automatically (`p7zip-full` on Debian 12/Ubuntu 22.04-24.04, `7zip` starting with Debian 13/newer Ubuntu) — upstream renamed the package between releases, and hardcoding either name broke the whole install on part of the supported versions.
* If `tmux` ends up in the install, the script drops in a ready `/root/.tmux.conf` (mouse, 50k-line history, hostname/clock status bar, vi keybindings) and an idempotent session-autostart block in `/root/.bashrc`, printing a warning with the file paths afterward.

### 🌐 Network
A full network-configuration submenu that never assumes `eth0` and never guesses your setup:
* **Backend-aware:** detects whether the system is managed by **Netplan**, **NetworkManager**, **systemd-networkd**, or classic `/etc/network/interfaces`, and shows you which one before making any change.
* Static IPv4 / DHCP toggle, gateway, multi-server DNS (add/edit/remove), IPv6 (SLAAC/DHCPv6/static/disable), static routes, MTU, MAC address change (specific or random), DHCP client-id normalization, per-interface up/down, and a network service restart.
* **DNS survives the DHCP→static switch:** on the classic `interfaces` backend without the `resolvconf` package, `dns-nameservers` is silently ignored by ifupdown, and on systemd-resolved systems (Debian 13+) DNS is additionally registered via `resolvectl` — without this the server was left without DNS after switching to a static IP.
* **Disabling IPv6 survives reboots and doesn't get reverted by the network service:** persisted via `/etc/sysctl.d` plus the backend's own config (`nmcli ipv6.method`, a netplan override, `systemd-networkd`) — a bare `sysctl -w` isn't enough, since NetworkManager/netplan/networkd re-enable IPv6 on their own at the next reconnect.
* **DHCP client-id normalization:** cloud-init/Proxmox images send a DUID instead of the plain MAC to the DHCP server by default (showing up as a long hex string in your router's lease table) — this menu item forces the client-id back to the MAC for any backend.
* Full diagnostics submenu: `ip addr/link/route`, gateway/DNS checks, ping, open local ports, active connections, remote TCP port check.
* Hostname configuration lives here.
* **Safety net:** Netplan changes apply via `netplan try` (automatic rollback if not confirmed within 120s); other backends get a manual confirm-or-revert-from-backup window. Any change to IP/gateway/interface state made over an active SSH session shows an explicit warning before it's applied.

### 🌍 NTP
Timezone and `chrony` (NTP) configuration grouped in one submenu, plus a time-sync status check and a quick view of current Chrony sources.

### 🔒 Hardened SSH
* Generate RSA key pairs, convert to PPK (PuTTY), disable password auth and root password login.
* **SSH port change** goes through a full safety pipeline: validates the new port, checks nothing else is already listening on it, backs up `sshd_config`, test-loads the new config with `sshd -T`, only restarts SSH if that test passes, and automatically restores the backup on any failure. If UFW is active, it offers to open the new port before the change takes effect.
* The script tracks the **configured** SSH port separately from the port your **current session** is actually using, and warns whenever they diverge (e.g. right after a port change) — so a stale session doesn't trick you into locking yourself out.

### 🧱 UFW (Firewall)
Rebuilt as a full firewall-management console: service control, rule viewing, quick port/protocol rules, IP & subnet rules (including source→port), numbered rule deletion, interface rules, outgoing rules, routed/forward rules, a dedicated SSH-protection menu (allow current port, restrict to an IP/subnet, `ufw limit`), application profiles, logging levels, default policies, an advanced rule builder with a plain-English preview before anything is applied, and rule backup/restore.
* Enabling UFW always guarantees the **configured** SSH port has an allow rule first.
* Deleting or denying anything touching your SSH port, session port, or current client IP requires typing `YES` to confirm.

### 👤 User Management
Add new sudo users with automatic SSH key deployment and credentials logging (unchanged from the original workflow).

### 🛡 Fail2Ban
Protect SSH, Web, and Mail services from brute-force attacks with automatic port-conflict checking. The SSH jail always follows whatever port is currently configured — including a port you just changed in the same session.

### 🖥 Dynamic MOTD
Generates `/etc/update-motd.d/20-server-info`, an ASCII-bordered "server info" panel shown right after SSH login (OpenSSH, PuTTY, MobaXterm — all render it identically):
* Hostname, OS, kernel, uptime · network summary (default interface/IP/gateway) + SSH port · load, memory, disk (`/`) · UFW & Fail2Ban status · date/time — **every line individually toggleable**, with instant preview.
* Colors optional; borders are pure ASCII for maximum terminal compatibility.
* Enable/disable just flips the executable bit — your configuration is never lost. Uninstall removes only the files this module created; other scripts under `/etc/update-motd.d/` (e.g. the stock `10-uname`) are never touched automatically, though you can toggle them from the same menu.
* Local-only: no network calls, no `apt update`, generates in milliseconds.

### 🌐 Integrated Web Stack
This script seamlessly integrates with my custom LAMP/LEMP installer:
* **Project Link:** [saym101/-LAMP-Apache-Angie-PHP-](https://github.com/saym101/-LAMP-Apache-Angie-PHP-)
* **Stack:** Supports Apache, Angie (Nginx fork), and PHP.

---

## 🚀 Quick Start

> **Warning:** This script must be run as **root** or with **sudo** privileges.

1.  **Download the script:**
    ```bash
    wget https://raw.githubusercontent.com/saym101/setup/main/setup.sh
    ```

2.  **Make it executable:**
    ```bash
    chmod +x setup.sh
    ```

3.  **Run it:**
    ```bash
    ./setup.sh
    ```

---

## 🛠 Usage Details

### Logging
Off by default. Private key material (e.g. the PPK dump during SSH key setup) is printed to the screen, so a full transcript could leak a private key onto disk. Enable it only when debugging the script itself:
```bash
./setup.sh --log
```
This writes `setup_YYYY-MM-DD.log` (mode 600) in the current directory. Delete it once you're done.

### User Creation
When adding a new user, the script generates a temporary file in the `./login` directory containing the username, password, and paths to SSH keys. **Remember to download these and delete the file from the server!**

### ⚠ Leftover Secrets — Read This
The script generates unencrypted (no passphrase) private SSH keys and, for new users, prints a plaintext password — both end up on disk:

* **SSH keys (root):** the `.ppk` file is printed to the screen for you to copy, and the script offers to delete it afterward — but the *original* OpenSSH private key (`~/.ssh/<hostname>-<date>`) is **not** deleted automatically and stays on the server.
* **Add user:** the credentials file in `./login/<user>_temp_<date>.txt` contains the plaintext password *and* points at an unencrypted private key under `/home/<user>/.ssh/`. Neither is removed automatically.

Once you've copied a key/password to your own machine, **delete the server-side copy** — a private key that grants access to a server is not useful sitting unencrypted on that same server; it's just extra blast radius if the server is ever compromised.

### Security First
The script encourages best practices and actively resists SSH lockouts:
* Enforcing `prohibit-password` for Root via SSH.
* Suggesting non-standard SSH ports.
* Setting up Fail2Ban jails with long ban times (10h).
* Every network, SSH-port, and UFW change that could plausibly cut off your current session shows an explicit warning and asks for confirmation before it's applied — the script never silently performs an action likely to break SSH access.

---

## 📋 Requirements
* **OS:** Debian 12 (Bookworm) / 13 (Trixie), Ubuntu 22.04 / 24.04 LTS, 25.04, 25.10, 26.04 LTS. Other versions are untested — their support has either already ended or is about to.
* **Privileges:** Root access
* Network module auto-detects whatever backend is installed (Netplan / NetworkManager / systemd-networkd / ifupdown) — no extra packages required beyond what your OS already ships with.
