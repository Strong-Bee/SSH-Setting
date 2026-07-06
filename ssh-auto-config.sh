#!/bin/bash

# ==========================================================
# SSH Auto Configuration Script (v2 - full otomatis + self-test)
# Ubuntu 20.04 / 22.04 / 24.04
# ==========================================================
#
# Tambahan dari versi sebelumnya:
#   - Auto generate SSH keypair (ed25519) untuk user target,
#     otomatis dipasang ke authorized_keys -> tidak perlu
#     ssh-copy-id manual, private key ditampilkan di akhir
#   - Self-test koneksi LOKAL (dari dalam server) ke port baru
#     sebelum dianggap sukses
#   - Self-test koneksi EKSTERNAL (canyouseeme.org) untuk
#     mendeteksi apakah port diblokir firewall provider/cloud
#     di luar jangkauan ufw/iptables server ini sendiri
#   - Idempotent: aman dijalankan berkali-kali
#   - Target user login bisa diatur via -u (bukan cuma root)
#   - Tetap: validasi config, rollback otomatis, drop-in config
#     handling, dukungan ufw/firewalld/iptables
# ==========================================================

set -Eeuo pipefail

# ---------- Konfigurasi default (bisa dioverride via argumen) ----------
SSH_PORT=2222
ALLOW_ROOT="prohibit-password"   # yes | no | prohibit-password
ALLOW_PASSWORD="yes"
INSTALL_FAIL2BAN="yes"
TARGET_USER="${SUDO_USER:-root}"
SKIP_EXTERNAL_TEST="no"
BACKUP_FILE=""

usage() {
    cat <<USAGE
Pemakaian: $0 [opsi]

  -p PORT           Port SSH baru (default: ${SSH_PORT})
  -u USER           User yang akan dipasangi SSH key (default: ${TARGET_USER})
  -r yes|no|prohibit-password   Izinkan root login (default: ${ALLOW_ROOT})
  -a yes|no         Izinkan login password (default: ${ALLOW_PASSWORD})
  -f                Skip install fail2ban (default: install)
  -x                Skip test eksternal (canyouseeme.org)
  -h                Tampilkan bantuan ini

Contoh:
  $0 -p 2222 -u lintang -r prohibit-password -a yes
USAGE
    exit 1
}

while getopts "p:u:r:a:fxh" opt; do
    case "$opt" in
        p) SSH_PORT="$OPTARG" ;;
        u) TARGET_USER="$OPTARG" ;;
        r) ALLOW_ROOT="$OPTARG" ;;
        a) ALLOW_PASSWORD="$OPTARG" ;;
        f) INSTALL_FAIL2BAN="no" ;;
        x) SKIP_EXTERNAL_TEST="yes" ;;
        h) usage ;;
        *) usage ;;
    esac
done

echo "======================================"
echo "      SSH AUTO CONFIGURATION v2"
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

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '${TARGET_USER}' tidak ditemukan di sistem ini."
    exit 1
fi

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
        systemctl restart ssh 2>/dev/null || systemctl restart sshd || true
        echo "Rollback selesai. Config lama dikembalikan dari: $BACKUP_FILE"
    else
        echo "Tidak ada file backup untuk di-rollback."
    fi
    exit 1
}
trap rollback ERR

echo "[1/12] Update package list..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

echo "[2/12] Install OpenSSH Server..."
apt-get install -y openssh-server

echo "[3/12] Enable SSH..."
systemctl enable ssh 2>/dev/null || systemctl enable sshd
systemctl start ssh 2>/dev/null || systemctl start sshd

echo "[4/12] Backup konfigurasi..."
BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)"
cp /etc/ssh/sshd_config "$BACKUP_FILE"
echo "Backup disimpan di: $BACKUP_FILE"

echo "[5/12] Menonaktifkan drop-in config yang bisa override (cloud-init dll)..."
if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -e "$f" ] || continue
        if grep -qiE 'PasswordAuthentication|PermitRootLogin|^Port' "$f" 2>/dev/null; then
            mv "$f" "${f}.disabled.$(date +%F-%H%M%S)"
            echo "  - Dinonaktifkan: $f (mengandung override yang konflik)"
        fi
    done
fi

echo "[6/12] Menyiapkan SSH key untuk user '${TARGET_USER}' (jika belum ada)..."
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SSH_DIR="${USER_HOME}/.ssh"
KEY_FILE="${SSH_DIR}/id_ed25519_autoconfig"
NEW_KEY_GENERATED="no"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ ! -f "$KEY_FILE" ]; then
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "${TARGET_USER}@autoconfig" >/dev/null
    NEW_KEY_GENERATED="yes"
    echo "  - Key baru dibuat: $KEY_FILE"
else
    echo "  - Key sudah ada, dipakai ulang: $KEY_FILE"
fi

touch "${SSH_DIR}/authorized_keys"
if ! grep -qF "$(cat "${KEY_FILE}.pub")" "${SSH_DIR}/authorized_keys" 2>/dev/null; then
    cat "${KEY_FILE}.pub" >> "${SSH_DIR}/authorized_keys"
    echo "  - Public key ditambahkan ke authorized_keys"
fi
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${TARGET_USER}:${TARGET_USER}" "$SSH_DIR"

echo "[7/12] Menulis konfigurasi SSH baru..."
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

echo "[8/12] Validasi syntax konfigurasi (sshd -t)..."
if ! sshd -t; then
    echo "Konfigurasi tidak valid! Membatalkan sebelum restart..."
    false
fi
echo "Konfigurasi valid."

echo "[9/12] Konfigurasi Firewall (buka port baru, port lama dibiarkan)..."
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
    echo "  - iptables: rule ditambahkan untuk port ${SSH_PORT}/tcp"
else
    echo "  - Tidak ada firewall aktif terdeteksi, lewati langkah ini."
fi

echo "[10/12] Restart SSH..."
systemctl restart ssh 2>/dev/null || systemctl restart sshd
sleep 1

if [ "$INSTALL_FAIL2BAN" = "yes" ]; then
    echo "  Menginstall fail2ban..."
    apt-get install -y fail2ban >/dev/null
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
fi

trap - ERR   # restart sukses, matikan trap rollback

echo "[11/12] Self-test koneksi LOKAL ke port ${SSH_PORT}..."
LOCAL_OK="no"
for i in 1 2 3 4 5; do
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${SSH_PORT}" 2>/dev/null; then
        LOCAL_OK="yes"
        break
    fi
    sleep 1
done

if [ "$LOCAL_OK" = "yes" ]; then
    echo "  -> OK, sshd merespons di 127.0.0.1:${SSH_PORT}"
else
    echo "  -> GAGAL. sshd TIDAK merespons secara lokal di port ${SSH_PORT}."
    echo "     Cek: systemctl status ssh   |   journalctl -u ssh -n 50"
fi

PUBLIC_IP="$(curl -4 -s --max-time 3 ifconfig.me || curl -4 -s --max-time 3 icanhazip.com || hostname -I | awk '{print $1}')"

echo "[12/12] Self-test koneksi EKSTERNAL (deteksi firewall provider/cloud)..."
EXTERNAL_RESULT="dilewati"
if [ "$SKIP_EXTERNAL_TEST" = "no" ] && [ "$LOCAL_OK" = "yes" ]; then
    EXTERNAL_RESULT="$(curl -s --max-time 8 "https://canyouseeme.org/api/query.php?ipaddress=${PUBLIC_IP}&port=${SSH_PORT}" 2>/dev/null || echo "gagal-cek")"
    if [ -z "$EXTERNAL_RESULT" ]; then
        EXTERNAL_RESULT="tidak-bisa-diverifikasi (coba manual di canyouseeme.org)"
    fi
fi

echo
echo "======================================"
echo "SELESAI"
echo "======================================"
echo "IP Server        : ${PUBLIC_IP}"
echo "SSH Port         : ${SSH_PORT}"
echo "Root Login       : ${ALLOW_ROOT}"
echo "Password Auth    : ${ALLOW_PASSWORD}"
echo "Backup Config    : ${BACKUP_FILE}"
echo "Test Lokal       : ${LOCAL_OK}"
echo "Test Eksternal   : ${EXTERNAL_RESULT}"
echo
echo "Cek port listening:"
ss -tlnp | grep -E "ssh|:${SSH_PORT} " || true
echo

if [ "$NEW_KEY_GENERATED" = "yes" ]; then
    echo "======================================"
    echo "PRIVATE KEY untuk login tanpa password"
    echo "(COPY seluruh isi di bawah ini ke file"
    echo " di client kamu, misal: id_ed25519_${TARGET_USER})"
    echo "======================================"
    cat "$KEY_FILE"
    echo "======================================"
    echo
    echo "Cara pakai di client:"
    echo "  1. Simpan isi di atas ke file, misal: ~/.ssh/id_ed25519_${TARGET_USER}"
    echo "  2. chmod 600 ~/.ssh/id_ed25519_${TARGET_USER}   (Linux/Mac)"
    echo "  3. ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519_${TARGET_USER} ${TARGET_USER}@${PUBLIC_IP}"
    echo
fi

echo "PENTING: JANGAN tutup sesi SSH yang sedang aktif ini dulu."
echo "Buka terminal/koneksi BARU dan test login dulu:"
echo "  ssh -p ${SSH_PORT} ${TARGET_USER}@${PUBLIC_IP}"
echo
if [ "$LOCAL_OK" = "yes" ] && echo "$EXTERNAL_RESULT" | grep -qi "unable\|closed\|blocked\|refused"; then
    echo "!!! PERHATIAN: port terlihat OK secara lokal, tapi test eksternal"
    echo "    menunjukkan kemungkinan diblokir dari luar."
    echo "    Ini biasanya berarti firewall di panel VPS/provider kamu"
    echo "    (bukan ufw/iptables di server ini) yang memblokir port ${SSH_PORT}."
    echo "    Cek dashboard provider VPS kamu untuk aturan firewall tambahan."
fi
echo "======================================"
