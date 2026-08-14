# 🚀 Debian/Ubuntu Server Setup & Admin Toolkit

*[Читать на русском](README_RU.md)*

A comprehensive, interactive Bash script for configuring and administering a Debian or Ubuntu server — initial setup (hostname, locale, timezone, SSH hardening, users) plus ongoing network, firewall, and MOTD management. Single self-contained file, menu-driven, colored output.

## ✨ Features

### 📦 Software
* Two independently editable package sets — a **recommended** baseline and a separate **diagnostic tools** set (`ethtool`, `nmap`, `tcpdump`, `net-tools`, `qrencode`) — both shown before install and editable inline (add/remove packages) without touching the code.

### 🌐 Network
A full network-configuration submenu that never assumes `eth0` and never guesses your setup:
* **Backend-aware:** detects whether the system is managed by **Netplan**, **NetworkManager**, **systemd-networkd**, or classic `/etc/network/interfaces`, and shows you which one before making any change.
* Static IPv4 / DHCP toggle, gateway, multi-server DNS (add/edit/remove), IPv6 (SLAAC/DHCPv6/static/disable), static routes, MTU, per-interface up/down, and a network service restart.
* Full diagnostics submenu: `ip addr/link/route`, gateway/DNS checks, ping, open local ports, active connections, remote TCP port check.
* Hostname configuration lives here.
* **Safety net:** Netplan changes apply via `netplan try` (automatic rollback if not confirmed within 120s); other backends get a manual confirm-or-revert-from-backup window. Any change to IP/gateway/interface state made over an active SSH session shows an explicit warning before it's applied.

### 🌍 Location
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
* **OS:** Debian 10/11/12 or Ubuntu 20.04/22.04+ (systemd-based)
* **Privileges:** Root access
* Network module auto-detects whatever backend is installed (Netplan / NetworkManager / systemd-networkd / ifupdown) — no extra packages required beyond what your OS already ships with.
