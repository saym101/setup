# 🚀 Debian/Ubuntu Initial Server Setup Script

*[Читать на русском](README_RU.md)*

A comprehensive, interactive Bash script designed to automate the initial configuration of a fresh Debian or Ubuntu server. It focuses on security, localization, and essential software installation.

## ✨ Features

This script provides a menu-driven interface to perform the following tasks:

* **System Localization:** Set custom Hostname, Locale, and Timezone.
* **Software Management:** Install a curated list of essential packages (git, curl, htop, etc.) and clean APT cache.
* **Time Sync:** Full configuration of `chrony` (NTP) with custom server support.
* **Hardened SSH:** * Generate RSA key pairs.
    * Convert keys to PPK format (for PuTTY).
    * Disable password authentication and root password login.
    * Change the default SSH port to a custom or random one.
* **Security:**
    * **UFW (Uncomplicated Firewall):** Interactive rule management.
    * **Fail2Ban:** Protect SSH, Web, and Mail services from brute-force attacks with automatic conflict checking.
* **User Management:** Add new sudo users with automatic SSH key deployment and credentials logging.
* **Web Stack:** Quick integration with external LAMP/LEMP installation scripts.

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
    sudo ./setup.sh
    ```

---

## 🛠 Usage Details

### Logging
Off by default. Private key material (e.g. the PPK dump in step 6) is printed to the screen, so a full transcript could leak a private key onto disk. Enable it only when debugging the script itself:
```bash
sudo bash setup.sh --log
```
This writes `setup_YYYY-MM-DD.log` (mode 600) in the current directory. Delete it once you're done.

### User Creation
When adding a new user, the script generates a temporary file in the `./login` directory containing the username, password, and paths to SSH keys. **Remember to download these and delete the file from the server!**

### ⚠ Leftover Secrets — Read This
The script generates unencrypted (no passphrase) private SSH keys and, for new users, prints a plaintext password — both end up on disk:

* **Step 6 (root SSH keys):** the `.ppk` file is printed to the screen for you to copy, and the script offers to delete it afterward — but the *original* OpenSSH private key (`~/.ssh/<hostname>-<date>`) is **not** deleted automatically and stays on the server.
* **Step 9 (add user):** the credentials file in `./login/<user>_temp_<date>.txt` contains the plaintext password *and* points at an unencrypted private key under `/home/<user>/.ssh/`. Neither is removed automatically.

Once you've copied a key/password to your own machine, **delete the server-side copy** — a private key that grants access to a server is not useful sitting unencrypted on that same server; it's just extra blast radius if the server is ever compromised.

### Security First
The script encourages best practices by:
* Enforcing `prohibit-password` for Root via SSH.
* Suggesting non-standard SSH ports.
* Setting up Fail2Ban jails with long ban times (10h).

---

## 📋 Requirements
* **OS:** Debian 10/11/12 or Ubuntu 20.04/22.04+
* **Privileges:** Root access
