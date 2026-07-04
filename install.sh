#!/usr/bin/env bash

# ==========================================================
# AUTO SSH CONFIGURATION
# Ubuntu 20.04 / 22.04 / 24.04
# Author : ChatGPT
# ==========================================================

set -e

CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

echo "=============================================="
echo "      AUTO SSH CONFIGURATION"
echo "=============================================="

# ----------------------------------------------------------
# Root Check
# ----------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Jalankan sebagai root."
    echo
    echo "Gunakan:"
    echo "sudo bash setup-ssh.sh"
    exit 1
fi

# ----------------------------------------------------------
# Backup
# ----------------------------------------------------------

echo
echo "[1/8] Backup konfigurasi..."

cp "$CONFIG" "$BACKUP"

echo "Backup tersimpan:"
echo "$BACKUP"

# ----------------------------------------------------------
# Fungsi Update Config
# ----------------------------------------------------------

update_config() {

    local KEY="$1"
    local VALUE="$2"

    if grep -qE "^[#[:space:]]*${KEY}\b" "$CONFIG"; then

        sed -i -E "s|^[#[:space:]]*${KEY}.*|${KEY} ${VALUE}|g" "$CONFIG"

    else

        echo "${KEY} ${VALUE}" >> "$CONFIG"

    fi

}

# ----------------------------------------------------------
# Update SSH Config
# ----------------------------------------------------------

echo
echo "[2/8] Mengatur konfigurasi SSH..."

update_config Port 22
update_config PermitRootLogin yes
update_config PasswordAuthentication yes
update_config PubkeyAuthentication yes
update_config ChallengeResponseAuthentication no
update_config KbdInteractiveAuthentication no
update_config PermitEmptyPasswords no
update_config UsePAM yes
update_config X11Forwarding yes
update_config PrintMotd no
update_config TCPKeepAlive yes
update_config ClientAliveInterval 300
update_config ClientAliveCountMax 2

# ----------------------------------------------------------
# Validasi
# ----------------------------------------------------------

echo
echo "[3/8] Validasi konfigurasi..."

if ! sshd -t; then

    echo
    echo "ERROR:"
    echo "Konfigurasi tidak valid."

    echo
    echo "Restore Backup..."

    cp "$BACKUP" "$CONFIG"

    exit 1

fi

echo "Konfigurasi OK."

# ----------------------------------------------------------
# Firewall
# ----------------------------------------------------------

echo
echo "[4/8] Firewall..."

if command -v ufw >/dev/null 2>&1; then

    ufw allow 22/tcp >/dev/null 2>&1 || true

    if ufw status | grep -q active; then
        ufw reload >/dev/null 2>&1
    fi

    echo "UFW OK."

else

    echo "UFW tidak ditemukan."

fi

# ----------------------------------------------------------
# Restart SSH
# ----------------------------------------------------------

echo
echo "[5/8] Restart SSH..."

systemctl daemon-reload

systemctl restart ssh

sleep 2

# ----------------------------------------------------------
# Status
# ----------------------------------------------------------

echo
echo "[6/8] Status SSH..."

if systemctl is-active --quiet ssh; then

    echo "SSH RUNNING"

else

    echo "SSH GAGAL."

    echo
    echo "Restore Backup..."

    cp "$BACKUP" "$CONFIG"

    systemctl restart ssh

    exit 1

fi

# ----------------------------------------------------------
# Listening Port
# ----------------------------------------------------------

echo
echo "[7/8] Port SSH..."

ss -tlnp | grep ssh || true

# ----------------------------------------------------------
# Public IP
# ----------------------------------------------------------

echo
echo "[8/8] Informasi Server..."

PRIVATE_IP=$(hostname -I | awk '{print $1}')

PUBLIC_IP=$(curl -4 -s --max-time 5 ifconfig.me || true)

echo
echo "=============================================="

echo "Private IP : $PRIVATE_IP"

if [[ -n "$PUBLIC_IP" ]]; then
    echo "Public  IP : $PUBLIC_IP"
fi

echo
echo "SSH Port   : 22"

echo
echo "=============================================="

echo "Login Root"

if [[ -n "$PUBLIC_IP" ]]; then

echo "ssh root@$PUBLIC_IP"

fi

echo
echo "=============================================="

echo "SELESAI"

echo "=============================================="
