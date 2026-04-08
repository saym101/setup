# 🚀 Debian/Ubuntu Initial Server Setup Script

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
All actions and outputs are automatically logged to a file named `setup_YYYY-MM-DD.log` in the current directory for later auditing.

### User Creation
When adding a new user, the script generates a temporary file in the `./login` directory containing the username, password, and paths to SSH keys. **Remember to download these and delete the file from the server!**

### Security First
The script encourages best practices by:
* Enforcing `prohibit-password` for Root via SSH.
* Suggesting non-standard SSH ports.
* Setting up Fail2Ban jails with long ban times (10h).

---

## 📋 Requirements
* **OS:** Debian 10/11/12 or Ubuntu 20.04/22.04+
* **Privileges:** Root access
