#!/bin/bash

# ==========================================
# FULL AUTO SETTING SSH CONFIGURATION
# ==========================================

echo "====== Memulai Auto Konfigurasi SSH ======"

# 1. Backup konfigurasi asli untuk keamanan
echo "[1/5] Membuat backup sshd_config..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# 2. Mengubah konfigurasi utama menggunakan sed
echo "[2/5] Menerapkan konfigurasi baru (Port 2222, Listen 0.0.0.0, PermitRoot)..."
# Hapus atau beri komentar pada ListenAddress lama jika ada yang spesifik
sudo sed -i 's/^ListenAddress.*/#&/' /etc/ssh/sshd_config

# Tambahkan atau ubah parameter yang dibutuhkan
sudo sed -i 's/^#\?Port.*/Port 2222/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
# Jika belum ada baris ListenAddress 0.0.0.0 sama sekali, tambahkan di bawah Port
if ! grep -q "^ListenAddress 0.0.0.0" /etc/ssh/sshd_config; then
    sudo sed -i '/Port 2222/a ListenAddress 0.0.0.0' /etc/ssh/sshd_config
fi

sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# 3. Mengatur Firewall UFW internal jika aktif
echo "[3/5] Mengonfigurasi UFW Firewall untuk Port 2222..."
if command -v ufw &> /dev/null; then
    sudo ufw allow 2222/tcp > /dev/null
    sudo ufw reload > /dev/null
    echo "      -> Port 2222 berhasil diizinkan di UFW."
else
    echo "      -> UFW tidak terdeteksi, melewati langkah ini."
fi

# 4. Reload Daemon Systemd
echo "[4/5] Memuat ulang daemon systemd..."
sudo systemctl daemon-reload

# 5. Restart Layanan SSH (Mendukung Systemd Service & Socket)
echo "[5/5] Merestart layanan SSH..."
# Cek apakah ssh.socket aktif (ciri khas Ubuntu/Debian baru)
if systemctl is-active --quiet ssh.socket; then
    echo "      -> Mendeteksi SSH Socket Activation. Merestart socket..."
    sudo systemctl stop ssh.socket
    sudo systemctl stop ssh
    sudo systemctl start ssh.socket
    sudo systemctl start ssh
else
    echo "      -> Mendeteksi SSH Service standar. Merestart service..."
    sudo systemctl restart ssh
fi

echo "====== Selesai! Silakan Coba Login via CMD ======"
echo "Perintah: ssh root@IP_VPS_ANDA -p 2222"
