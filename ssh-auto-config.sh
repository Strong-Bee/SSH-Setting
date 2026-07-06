#!/bin/bash

# ==========================================================
# SSH Auto Configuration Script (versi perbaikan)
# Ubuntu 20.04 / 22.04 / 24.04
# ==========================================================
#
# Perbaikan dari versi sebelumnya:
#   - Validasi config (sshd -t) sebelum restart -> anti lockout
#   - Buka port firewall SEBELUM restart sshd, port lama tetap
#     dibiarkan terbuka sampai kamu konfirmasi login berhasil
#   - Menangani drop-in config Ubuntu (/etc/ssh/sshd_config.d/*)
#     yang bisa override PasswordAuthentication dkk
#   - apt upgrade non-interaktif (tidak nge-hang di prompt)
#   - Auto rollback ke config lama jika terjadi error
#   - Dukungan ufw / firewalld / iptables
#   - Opsi lewat argumen CLI, bukan cuma edit variabel
#   - Opsi install fail2ban
# ==========================================================

set -Eeuo pipefail

# ---------- Konfigurasi default (bisa dioverride via argumen) ----------
SSH_PORT=2222
ALLOW_ROOT="prohibit-password"   # yes | no | prohibit-password (lebih aman dari 'yes')
ALLOW_PASSWORD="yes"
INSTALL_FAIL2BAN="no"
BACKUP_FILE=""

usage() {
    cat <<USAGE
Pemakaian: $0 [opsi]

  -p PORT           Port SSH baru (default: ${SSH_PORT})
  -r yes|no|prohibit-password   Izinkan root login (default: ${ALLOW_ROOT})
  -a yes|no         Izinkan login password (default: ${ALLOW_PASSWORD})
  -f                Install & aktifkan fail2ban
  -h                Tampilkan bantuan ini

Contoh:
  $0 -p 2222 -r prohibit-password -a yes -f
USAGE
    exit 1
}

while getopts "p:r:a:fh" opt; do
    case "$opt" in
        p) SSH_PORT="$OPTARG" ;;
        r) ALLOW_ROOT="$OPTARG" ;;
        a) ALLOW_PASSWORD="$OPTARG" ;;
        f) INSTALL_FAIL2BAN="yes" ;;
        h) usage ;;
        *) usage ;;
    esac
done

echo "======================================"
echo "      SSH AUTO CONFIGURATION"
echo "======================================"

# ---------- Cek root ----------
if [ "$EUID" -ne 0 ]; then
    echo "Jalankan script ini sebagai root (sudo)."
    exit 1
fi

# ---------- Validasi input ----------
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Port tidak valid: ${SSH_PORT}"
    exit 1
fi

case "$ALLOW_ROOT" in
    yes|no|prohibit-password) ;;
    *) echo "Nilai -r harus yes/no/prohibit-password"; exit 1 ;;
esac

case "$ALLOW_PASSWORD" in
    yes|no) ;;
    *) echo "Nilai -a harus yes/no"; exit 1 ;;
esac

# Deteksi port yang sedang dipakai koneksi SSH saat ini (biar tidak bingung)
CURRENT_SSH_PORT="$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')"
if [ -n "$CURRENT_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]; then
    echo "Kamu sedang login lewat port ${CURRENT_SSH_PORT}, script akan pindah ke port ${SSH_PORT}."
    echo "Port lama TIDAK akan ditutup otomatis, supaya kamu tidak terkunci jika ada kesalahan."
fi

# ---------- Trap untuk rollback jika gagal ----------
rollback() {
    echo
    echo "!!! Terjadi error, mencoba rollback konfigurasi SSH..."
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" /etc/ssh/sshd_config
        systemctl restart ssh || systemctl restart sshd || true
        echo "Rollback selesai. Config lama dikembalikan dari: $BACKUP_FILE"
    else
        echo "Tidak ada file backup untuk di-rollback."
    fi
    exit 1
}
trap rollback ERR

echo "[1/10] Update package list..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

echo "[2/10] Install OpenSSH Server..."
apt-get install -y openssh-server

echo "[3/10] Enable SSH..."
systemctl enable ssh 2>/dev/null || systemctl enable sshd
systemctl start ssh 2>/dev/null || systemctl start sshd

echo "[4/10] Backup konfigurasi..."
BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)"
cp /etc/ssh/sshd_config "$BACKUP_FILE"
echo "Backup disimpan di: $BACKUP_FILE"

echo "[5/10] Menonaktifkan drop-in config yang bisa override (cloud-init dll)..."
if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -e "$f" ] || continue
        if grep -qiE 'PasswordAuthentication|PermitRootLogin' "$f" 2>/dev/null; then
            mv "$f" "${f}.disabled.$(date +%F-%H%M%S)"
            echo "  - Dinonaktifkan: $f (mengandung override yang konflik)"
        fi
    done
fi

echo "[6/10] Menulis konfigurasi SSH baru..."
cat > /etc/ssh/sshd_config << EOF
Port ${SSH_PORT}

Protocol 2

PermitRootLogin ${ALLOW_ROOT}
PasswordAuthentication ${ALLOW_PASSWORD}
PermitEmptyPasswords no

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

KbdInteractiveAuthentication no
UsePAM yes

X11Forwarding no
PrintMotd no
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2

Subsystem sftp /usr/lib/openssh/sftp-server
EOF

echo "[7/10] Validasi syntax konfigurasi (sshd -t)..."
if ! sshd -t; then
    echo "Konfigurasi tidak valid! Membatalkan sebelum restart..."
    false   # memicu trap rollback
fi
echo "Konfigurasi valid."

echo "[8/10] Konfigurasi Firewall (buka port baru dulu, port lama dibiarkan)..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "${SSH_PORT}/tcp" || true
    ufw reload || true
    echo "  - ufw: port ${SSH_PORT}/tcp diizinkan"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" || true
    firewall-cmd --reload || true
    echo "  - firewalld: port ${SSH_PORT}/tcp diizinkan"
elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT
    echo "  - iptables: rule ditambahkan untuk port ${SSH_PORT}/tcp (tidak persisten, cek iptables-persistent)"
else
    echo "  - Tidak ada firewall aktif terdeteksi, lewati langkah ini."
fi

echo "[9/10] Restart SSH..."
systemctl restart ssh 2>/dev/null || systemctl restart sshd

if [ "$INSTALL_FAIL2BAN" = "yes" ]; then
    echo "Menginstall fail2ban..."
    apt-get install -y fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban
fi

trap - ERR   # setelah restart sukses, matikan trap rollback

echo "[10/10] Status & Informasi Server"
systemctl --no-pager status ssh 2>/dev/null || systemctl --no-pager status sshd || true

PUBLIC_IP="$(curl -4 -s --max-time 3 ifconfig.me || curl -4 -s --max-time 3 icanhazip.com || hostname -I | awk '{print $1}')"

echo
echo "======================================"
echo "SELESAI"
echo "======================================"
echo "IP Server     : ${PUBLIC_IP}"
echo "SSH Port      : ${SSH_PORT}"
echo "Root Login    : ${ALLOW_ROOT}"
echo "Password Auth : ${ALLOW_PASSWORD}"
echo "Backup Config : ${BACKUP_FILE}"
echo
echo "PENTING: JANGAN tutup sesi SSH ini dulu."
echo "Buka terminal BARU dan test login dengan port baru:"
echo "  ssh -p ${SSH_PORT} root@${PUBLIC_IP}"
echo
echo "Kalau login baru berhasil, baru boleh tutup sesi lama"
echo "dan (opsional) tutup port SSH lama di firewall."
echo
echo "Cek port listening:"
ss -tlnp | grep -E "ssh|${SSH_PORT}" || true
echo "======================================"
