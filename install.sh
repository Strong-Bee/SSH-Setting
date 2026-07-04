#!/bin/bash

# ====================================================================
# FULL AUTO SETTING SSH CONFIGURATION (SUPPORTS SYSTEMD SOCKET ACT)
# ====================================================================

echo "====== Memulai Auto Konfigurasi SSH ======"

# 1. Backup konfigurasi asli untuk keamanan
echo "[1/6] Membuat backup sshd_config..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# 2. Mengubah konfigurasi utama menggunakan sed
echo "[2/6] Menerapkan konfigurasi baru di sshd_config (Port 2222, Listen 0.0.0.0)..."
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

# 3. FIX: Override Systemd SSH Socket (Solusi Khusus Ubuntu Modern agar Port 2222 Terbuka)
echo "[3/6] Memeriksa dan mengonfigurasi Systemd SSH Socket..."
if systemctl is-active --quiet ssh.socket || [ -d /lib/systemd/system/ssh.socket.d ] || [ -f /lib/systemd/system/ssh.socket ]; then
    echo "      -> Mengonfigurasi port 2222 pada systemd socket override..."
    sudo mkdir -p /etc/systemd/system/ssh.socket.d
    cat <<EOF | sudo tee /etc/systemd/system/ssh.socket.d/listen.conf > /dev/null
[Socket]
ListenStream=
ListenStream=2222
EOF
    echo "      -> Override systemd socket berhasil dibuat."
else
    echo "      -> Systemd socket tidak digunakan secara aktif, melewati langkah ini."
fi

# 4. Mengatur Firewall UFW internal jika aktif
echo "[4/6] Mengonfigurasi UFW Firewall untuk Port 2222..."
if command -v ufw &> /dev/null; then
    sudo ufw allow 2222/tcp > /dev/null
    sudo ufw reload > /dev/null
    echo "      -> Port 2222 berhasil diizinkan di UFW."
else
    echo "      -> UFW tidak terdeteksi, melewati langkah ini."
fi

# 5. Reload Daemon Systemd
echo "[5/6] Memuat ulang daemon systemd..."
sudo systemctl daemon-reload

# 6. Restart Layanan SSH (Mendukung Systemd Service & Socket)
echo "[6/6] Merestart layanan SSH..."
if systemctl is-active --quiet ssh.socket; then
    echo "      -> Mendeteksi SSH Socket Activation. Menghentikan socket lama dan memuat ulang..."
    sudo systemctl stop ssh.socket
    sudo systemctl stop ssh
    sudo systemctl restart ssh
    sudo systemctl start ssh.socket
else
    echo "      -> Mendeteksi SSH Service standar. Merestart service..."
    sudo systemctl restart ssh
fi

echo "====== Selesai! Silakan Coba Login via CMD ======"
echo "Perintah: ssh lintang@38.47.176.139 -p 2222"
