#!/bin/bash

# =========================================
#          NGINX MANAGER v2.1
#       (Nginx + SSH Management)
# =========================================

# Warna untuk output terminal
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =========================================
# PERBAIKAN: Validasi root setelah definisi
# warna agar pesan error berwarna
# =========================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Harap jalankan script ini sebagai root (sudo).${NC}"
    exit 1
fi

# =========================================
# HELPER FUNCTIONS
# =========================================

pause() {
    echo ""
    read -p "Tekan [Enter] untuk kembali ke menu..."
}

# PERBAIKAN: Fungsi validasi domain agar tidak kosong
validate_domain() {
    local domain="$1"
    if [ -z "$domain" ]; then
        echo -e "${RED}Error: Nama domain tidak boleh kosong!${NC}"
        return 1
    fi
    # Validasi format domain sederhana
    if ! echo "$domain" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$'; then
        echo -e "${RED}Error: Format domain tidak valid!${NC}"
        return 1
    fi
    return 0
}

# PERBAIKAN: Fungsi cek apakah konfigurasi domain sudah ada
check_domain_exists() {
    local domain="$1"
    if [ -f "/etc/nginx/sites-available/$domain" ]; then
        echo -e "${YELLOW}Peringatan: Konfigurasi untuk $domain sudah ada dan akan ditimpa.${NC}"
        read -p "Lanjutkan? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "${YELLOW}Dibatalkan.${NC}"
            return 1
        fi
    fi
    return 0
}

# PERBAIKAN: Fungsi reload nginx dengan pengecekan syntax terlebih dahulu
safe_reload_nginx() {
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        return 0
    else
        echo -e "${RED}Error: Konfigurasi Nginx tidak valid! Reload dibatalkan.${NC}"
        nginx -t
        return 1
    fi
}

# =========================================
# HELPER: Nama service SSH (ssh atau sshd
# tergantung distro), dideteksi sekali saja
# =========================================
get_ssh_service() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^ssh.service"; then
        echo "ssh"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^sshd.service"; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

# PERBAIKAN: Fungsi validasi nomor port SSH
validate_ssh_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Port harus berupa angka!${NC}"
        return 1
    fi
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Error: Port harus antara 1-65535!${NC}"
        return 1
    fi
    return 0
}

# PERBAIKAN: Fungsi test syntax sshd_config sebelum restart
safe_restart_ssh() {
    local service_name
    service_name=$(get_ssh_service)
    if sshd -t 2>/tmp/sshd_test_err; then
        systemctl restart "$service_name"
        if systemctl is-active --quiet "$service_name"; then
            return 0
        else
            echo -e "${RED}Error: Service SSH gagal start setelah restart!${NC}"
            return 1
        fi
    else
        echo -e "${RED}Error: Konfigurasi sshd_config tidak valid! Restart dibatalkan.${NC}"
        cat /tmp/sshd_test_err
        rm -f /tmp/sshd_test_err
        return 1
    fi
}

# =========================================
# 1. Install Nginx
# =========================================
install_nginx() {
    clear
    echo -e "${YELLOW}[1] Menginstall Nginx...${NC}"
    echo "========================================="

    # PERBAIKAN: Cek apakah Nginx sudah terinstall
    if command -v nginx &>/dev/null; then
        echo -e "${YELLOW}Nginx sudah terinstall. Versi:${NC}"
        nginx -v
        read -p "Reinstall? (y/n): " reinstall
        if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
            echo -e "${YELLOW}Instalasi dibatalkan.${NC}"
            pause
            return
        fi
    fi

    apt update -y
    apt install -y nginx certbot python3-certbot-nginx

    # PERBAIKAN: Cek hasil instalasi
    if ! command -v nginx &>/dev/null; then
        echo -e "${RED}Gagal menginstall Nginx. Periksa koneksi internet atau repository.${NC}"
        pause
        return
    fi

    systemctl enable nginx
    systemctl start nginx
    echo -e "${GREEN}Nginx berhasil diinstall dan dijalankan!${NC}"
    echo -e "${CYAN}Versi Nginx: $(nginx -v 2>&1)${NC}"
    pause
}

# =========================================
# 2. Configure Website (Umum)
# =========================================
configure_website() {
    clear
    echo -e "${YELLOW}[2] Konfigurasi Website Umum${NC}"
    echo "========================================="

    read -p "Masukkan nama domain (contoh: example.com): " domain
    validate_domain "$domain" || { pause; return; }
    check_domain_exists "$domain" || { pause; return; }

    read -p "Masukkan direktori root (contoh: /var/www/html): " web_root
    if [ -z "$web_root" ]; then
        echo -e "${RED}Error: Direktori root tidak boleh kosong!${NC}"
        pause
        return
    fi

    mkdir -p "$web_root"
    # PERBAIKAN: Gunakan chown dengan -R hanya jika direktori ada
    if [ -d "$web_root" ]; then
        chown -R www-data:www-data "$web_root"
    fi

    # PERBAIKAN: Buat index.html default jika belum ada
    if [ ! -f "$web_root/index.html" ]; then
        cat <<EOF > "$web_root/index.html"
<!DOCTYPE html>
<html lang="id">
<head><meta charset="UTF-8"><title>Welcome to $domain</title></head>
<body><h1>Selamat datang di $domain</h1><p>Website Anda berjalan dengan baik!</p></body>
</html>
EOF
    fi

    cat <<EOF > /etc/nginx/sites-available/$domain
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;
    root $web_root;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml;
}
EOF

    # PERBAIKAN: Hapus symlink lama jika ada sebelum membuat yang baru
    rm -f /etc/nginx/sites-enabled/"$domain"
    ln -sf /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/"$domain"

    if safe_reload_nginx; then
        echo -e "${GREEN}Website $domain berhasil dikonfigurasi!${NC}"
        echo -e "${CYAN}Root: $web_root${NC}"
    fi
    pause
}

# =========================================
# 3. Configure Reverse Proxy
# =========================================
configure_reverse_proxy() {
    clear
    echo -e "${YELLOW}[3] Konfigurasi Reverse Proxy${NC}"
    echo "========================================="

    read -p "Masukkan nama domain (contoh: app.example.com): " domain
    validate_domain "$domain" || { pause; return; }
    check_domain_exists "$domain" || { pause; return; }

    read -p "Masukkan URL/Port backend (contoh: http://127.0.0.1:3000): " backend
    if [ -z "$backend" ]; then
        echo -e "${RED}Error: URL backend tidak boleh kosong!${NC}"
        pause
        return
    fi

    # PERBAIKAN: Validasi format backend URL
    if ! echo "$backend" | grep -qP '^https?://'; then
        echo -e "${RED}Error: URL backend harus dimulai dengan http:// atau https://${NC}"
        pause
        return
    fi

    # PERBAIKAN: Tambahkan timeout dan buffer settings yang optimal
    cat <<EOF > /etc/nginx/sites-available/$domain
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    # Logging
    access_log /var/log/nginx/${domain}_access.log;
    error_log  /var/log/nginx/${domain}_error.log;

    location / {
        proxy_pass $backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        # Timeout settings
        proxy_connect_timeout       60s;
        proxy_send_timeout          60s;
        proxy_read_timeout          60s;

        # Buffer settings
        proxy_buffer_size           128k;
        proxy_buffers               4 256k;
        proxy_busy_buffers_size     256k;
    }
}
EOF

    rm -f /etc/nginx/sites-enabled/"$domain"
    ln -sf /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/"$domain"

    if safe_reload_nginx; then
        echo -e "${GREEN}Reverse Proxy untuk $domain -> $backend berhasil dikonfigurasi!${NC}"
    fi
    pause
}

# =========================================
# 4. Configure PHP Website
# =========================================
configure_php_website() {
    clear
    echo -e "${YELLOW}[4] Konfigurasi PHP Website${NC}"
    echo "========================================="

    read -p "Masukkan nama domain: " domain
    validate_domain "$domain" || { pause; return; }
    check_domain_exists "$domain" || { pause; return; }

    read -p "Masukkan direktori root: " web_root
    if [ -z "$web_root" ]; then
        echo -e "${RED}Error: Direktori root tidak boleh kosong!${NC}"
        pause
        return
    fi

    read -p "Masukkan versi PHP-FPM (contoh: 8.1, 8.2, 8.3): " php_ver
    if [ -z "$php_ver" ]; then
        echo -e "${RED}Error: Versi PHP tidak boleh kosong!${NC}"
        pause
        return
    fi

    # PERBAIKAN: Validasi apakah socket PHP-FPM tersedia
    PHP_SOCK="/var/run/php/php${php_ver}-fpm.sock"
    if [ ! -S "$PHP_SOCK" ]; then
        echo -e "${YELLOW}Peringatan: Socket PHP-FPM $PHP_SOCK tidak ditemukan.${NC}"
        echo -e "${YELLOW}Pastikan php${php_ver}-fpm sudah terinstall dan berjalan.${NC}"
        read -p "Tetap lanjutkan konfigurasi? (y/n): " cont
        if [ "$cont" != "y" ] && [ "$cont" != "Y" ]; then
            pause
            return
        fi
    fi

    mkdir -p "$web_root"
    chown -R www-data:www-data "$web_root"

    cat <<EOF > /etc/nginx/sites-available/$domain
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;
    root $web_root;
    index index.php index.html index.htm;

    # Logging
    access_log /var/log/nginx/${domain}_access.log;
    error_log  /var/log/nginx/${domain}_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${php_ver}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;

        # Timeout untuk PHP
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout    300;
        fastcgi_read_timeout    300;
    }

    location ~ /\.ht {
        deny all;
    }

    # Tolak akses ke file sensitif
    location ~ /\.(git|env|svn) {
        deny all;
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
}
EOF

    rm -f /etc/nginx/sites-enabled/"$domain"
    ln -sf /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/"$domain"

    if safe_reload_nginx; then
        echo -e "${GREEN}PHP Website untuk $domain (PHP ${php_ver}) berhasil dikonfigurasi!${NC}"
    fi
    pause
}

# =========================================
# 5. Configure Static Website
# =========================================
configure_static_website() {
    clear
    echo -e "${YELLOW}[5] Konfigurasi Static Website${NC}"
    echo "========================================="

    read -p "Masukkan nama domain: " domain
    validate_domain "$domain" || { pause; return; }
    check_domain_exists "$domain" || { pause; return; }

    read -p "Masukkan direktori root: " web_root
    if [ -z "$web_root" ]; then
        echo -e "${RED}Error: Direktori root tidak boleh kosong!${NC}"
        pause
        return
    fi

    mkdir -p "$web_root"
    chown -R www-data:www-data "$web_root"

    if [ ! -f "$web_root/index.html" ]; then
        cat <<EOF > "$web_root/index.html"
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to $domain</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 80px; background: #f0f4f8; }
        h1 { color: #2d3748; } p { color: #718096; }
    </style>
</head>
<body>
    <h1>Selamat Datang di $domain</h1>
    <p>Website statis Anda berjalan dengan baik!</p>
</body>
</html>
EOF
    fi

    # PERBAIKAN: Tambahkan caching untuk file statis
    cat <<EOF > /etc/nginx/sites-available/$domain
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;
    root $web_root;
    index index.html;

    # Logging
    access_log /var/log/nginx/${domain}_access.log;
    error_log  /var/log/nginx/${domain}_error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Cache file statis
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
}
EOF

    rm -f /etc/nginx/sites-enabled/"$domain"
    ln -sf /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/"$domain"

    if safe_reload_nginx; then
        echo -e "${GREEN}Static Website $domain berhasil dikonfigurasi!${NC}"
        echo -e "${CYAN}Root: $web_root${NC}"
    fi
    pause
}

# =========================================
# 6. Install SSL (Let's Encrypt)
# =========================================
install_ssl() {
    clear
    echo -e "${YELLOW}[6] Install SSL Certbot${NC}"
    echo "========================================="

    read -p "Masukkan domain utama yang ingin dipasang SSL: " domain
    validate_domain "$domain" || { pause; return; }

    # PERBAIKAN: Cek apakah certbot tersedia
    if ! command -v certbot &>/dev/null; then
        echo -e "${RED}certbot tidak ditemukan! Install Nginx dulu (menu [1]).${NC}"
        pause
        return
    fi

    # PERBAIKAN: Cek apakah konfigurasi Nginx untuk domain ada
    if [ ! -f "/etc/nginx/sites-available/$domain" ]; then
        echo -e "${RED}Konfigurasi Nginx untuk $domain tidak ditemukan!${NC}"
        echo -e "${YELLOW}Buat konfigurasi website dulu (menu [2]-[5]).${NC}"
        pause
        return
    fi

    echo -e "${YELLOW}Memasang SSL untuk: $domain dan www.$domain${NC}"
    certbot --nginx -d "$domain" -d "www.$domain"

    # PERBAIKAN: Cek hasil certbot
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SSL berhasil dipasang untuk $domain!${NC}"
        echo -e "${CYAN}SSL akan diperbarui otomatis oleh certbot.timer${NC}"
    else
        echo -e "${RED}Gagal memasang SSL. Pastikan domain mengarah ke server ini.${NC}"
    fi
    pause
}

# =========================================
# 7. Renew SSL
# =========================================
renew_ssl() {
    clear
    echo -e "${YELLOW}[7] Memperbarui Sertifikat SSL...${NC}"
    echo "========================================="

    if ! command -v certbot &>/dev/null; then
        echo -e "${RED}certbot tidak ditemukan!${NC}"
        pause
        return
    fi

    # PERBAIKAN: Gunakan --dry-run untuk preview atau langsung renew
    read -p "Test renew dulu (dry-run)? (y/n): " dry
    if [ "$dry" = "y" ] || [ "$dry" = "Y" ]; then
        certbot renew --dry-run
    else
        certbot renew
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SSL berhasil diperbarui!${NC}"
    else
        echo -e "${RED}Gagal memperbarui SSL. Cek log certbot untuk detail.${NC}"
    fi
    pause
}

# =========================================
# 8. Backup Nginx
# =========================================
backup_nginx() {
    clear
    echo -e "${YELLOW}[8] Mengambil Backup Nginx...${NC}"
    echo "========================================="

    BACKUP_DIR="/root/nginx_backups"
    mkdir -p "$BACKUP_DIR"

    # PERBAIKAN: Cek apakah /etc/nginx ada sebelum backup
    if [ ! -d "/etc/nginx" ]; then
        echo -e "${RED}Direktori /etc/nginx tidak ditemukan! Nginx mungkin belum diinstall.${NC}"
        pause
        return
    fi

    BACKUP_NAME="nginx-backup-$(date +%F-%H%M%S).tar.gz"

    tar -czf "$BACKUP_DIR/$BACKUP_NAME" /etc/nginx 2>/dev/null

    if [ $? -eq 0 ]; then
        BACKUP_SIZE=$(du -sh "$BACKUP_DIR/$BACKUP_NAME" | cut -f1)
        echo -e "${GREEN}Backup berhasil disimpan!${NC}"
        echo -e "${CYAN}Lokasi : $BACKUP_DIR/$BACKUP_NAME${NC}"
        echo -e "${CYAN}Ukuran : $BACKUP_SIZE${NC}"
    else
        echo -e "${RED}Gagal membuat backup!${NC}"
    fi

    # Tampilkan daftar backup yang ada
    echo ""
    echo -e "${YELLOW}Daftar backup yang tersedia:${NC}"
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "Tidak ada backup lain."
    pause
}

# =========================================
# 9. Restore Backup
# =========================================
restore_backup() {
    clear
    echo -e "${YELLOW}[9] Restore Backup Nginx${NC}"
    echo "========================================="

    BACKUP_DIR="/root/nginx_backups"
    echo -e "${CYAN}Backup yang tersedia di $BACKUP_DIR:${NC}"
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "Tidak ada file backup ditemukan."
    echo ""

    read -p "Masukkan path penuh file backup (.tar.gz): " backup_file

    # PERBAIKAN: Validasi path kosong
    if [ -z "$backup_file" ]; then
        echo -e "${RED}Error: Path file tidak boleh kosong!${NC}"
        pause
        return
    fi

    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}File backup tidak ditemukan: $backup_file${NC}"
        pause
        return
    fi

    # PERBAIKAN: Konfirmasi sebelum restore
    echo -e "${RED}Peringatan! Restore akan menimpa konfigurasi Nginx yang ada!${NC}"
    read -p "Apakah Anda yakin ingin restore? (y/n): " konfirmasi
    if [ "$konfirmasi" != "y" ] && [ "$konfirmasi" != "Y" ]; then
        echo -e "${YELLOW}Restore dibatalkan.${NC}"
        pause
        return
    fi

    # PERBAIKAN: Backup konfigurasi saat ini sebelum restore
    echo -e "${YELLOW}Membuat backup konfigurasi saat ini sebelum restore...${NC}"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_DIR/pre-restore-$(date +%F-%H%M%S).tar.gz" /etc/nginx 2>/dev/null

    # PERBAIKAN: Gunakan rm lebih aman, hanya isi direktori bukan direktori itu sendiri
    rm -rf /etc/nginx/*
    tar -xzf "$backup_file" -C /

    if [ $? -eq 0 ]; then
        if safe_reload_nginx; then
            echo -e "${GREEN}Konfigurasi Nginx berhasil di-restore dari: $backup_file${NC}"
        fi
    else
        echo -e "${RED}Gagal melakukan restore!${NC}"
    fi
    pause
}

# =========================================
# 10. Restart Nginx
# =========================================
restart_nginx() {
    clear
    echo -e "${YELLOW}[10] Merestart Nginx Service...${NC}"
    echo "========================================="

    # PERBAIKAN: Test config dulu sebelum restart
    if ! nginx -t 2>/dev/null; then
        echo -e "${RED}Konfigurasi Nginx tidak valid! Restart dibatalkan.${NC}"
        nginx -t
        pause
        return
    fi

    systemctl restart nginx

    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}Nginx berhasil di-restart dan sedang berjalan.${NC}"
    else
        echo -e "${RED}Nginx gagal start! Cek log: journalctl -xe${NC}"
    fi
    pause
}

# =========================================
# 11. Reload Nginx
# =========================================
reload_nginx() {
    clear
    echo -e "${YELLOW}[11] Mereload Nginx Service...${NC}"
    echo "========================================="

    if safe_reload_nginx; then
        echo -e "${GREEN}Nginx berhasil di-reload.${NC}"
    fi
    pause
}

# =========================================
# 12. Test Configuration
# =========================================
test_config() {
    clear
    echo -e "${YELLOW}[12] Menguji Konfigurasi Nginx...${NC}"
    echo "========================================="
    nginx -t
    echo ""
    echo -e "${CYAN}Detail versi Nginx:${NC}"
    nginx -V 2>&1
    pause
}

# =========================================
# 13. Status Nginx
# =========================================
status_nginx() {
    clear
    echo -e "${YELLOW}[13] Status Layanan Nginx:${NC}"
    echo "========================================="
    systemctl status nginx --no-pager

    # PERBAIKAN: Tampilkan info tambahan
    echo ""
    echo -e "${CYAN}Sites Enabled:${NC}"
    ls /etc/nginx/sites-enabled/ 2>/dev/null || echo "Tidak ada site yang aktif."
    echo ""
    echo -e "${CYAN}Port yang digunakan Nginx:${NC}"
    ss -tlnp | grep nginx 2>/dev/null || netstat -tlnp 2>/dev/null | grep nginx || echo "Tidak dapat mendeteksi port."
    pause
}

# =========================================
# 14. List Website
# =========================================
list_websites() {
    clear
    echo -e "${YELLOW}[14] Daftar Website yang Dikonfigurasi${NC}"
    echo "========================================="

    echo -e "${CYAN}Sites Available:${NC}"
    if ls /etc/nginx/sites-available/ 2>/dev/null | grep -v "^default$"; then
        :
    else
        echo "Tidak ada site."
    fi

    echo ""
    echo -e "${CYAN}Sites Enabled (Aktif):${NC}"
    if ls /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "^default$"; then
        :
    else
        echo "Tidak ada site yang aktif."
    fi
    pause
}

# =========================================
# 15. Remove Website
# =========================================
remove_website() {
    clear
    echo -e "${YELLOW}[15] Hapus Konfigurasi Website${NC}"
    echo "========================================="

    # PERBAIKAN: Tampilkan daftar site yang ada
    echo -e "${CYAN}Site yang tersedia:${NC}"
    ls /etc/nginx/sites-available/ 2>/dev/null | grep -v "^default$" || echo "Tidak ada site."
    echo ""

    read -p "Masukkan nama domain yang ingin dihapus: " domain
    if [ -z "$domain" ]; then
        echo -e "${RED}Error: Nama domain tidak boleh kosong!${NC}"
        pause
        return
    fi

    # PERBAIKAN: Cek apakah domain ada sebelum hapus
    if [ ! -f "/etc/nginx/sites-available/$domain" ] && [ ! -L "/etc/nginx/sites-enabled/$domain" ]; then
        echo -e "${RED}Konfigurasi untuk $domain tidak ditemukan!${NC}"
        pause
        return
    fi

    echo -e "${RED}Peringatan! Ini akan menghapus konfigurasi Nginx untuk $domain.${NC}"
    read -p "Apakah Anda yakin? (y/n): " konfirmasi
    if [ "$konfirmasi" != "y" ] && [ "$konfirmasi" != "Y" ]; then
        echo -e "${YELLOW}Penghapusan dibatalkan.${NC}"
        pause
        return
    fi

    rm -f /etc/nginx/sites-enabled/"$domain"
    rm -f /etc/nginx/sites-available/"$domain"

    if safe_reload_nginx; then
        echo -e "${GREEN}Konfigurasi untuk $domain telah dihapus.${NC}"
    fi
    pause
}

# =========================================
# 16. Install SSH
# =========================================
install_ssh() {
    clear
    echo -e "${YELLOW}[16] Menginstall OpenSSH Server...${NC}"
    echo "========================================="

    if command -v sshd &>/dev/null; then
        echo -e "${YELLOW}OpenSSH Server sudah terinstall. Versi:${NC}"
        sshd -V 2>&1 | head -n 1
        read -p "Reinstall? (y/n): " reinstall
        if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
            echo -e "${YELLOW}Instalasi dibatalkan.${NC}"
            pause
            return
        fi
    fi

    apt update -y
    apt install -y openssh-server

    if ! command -v sshd &>/dev/null; then
        echo -e "${RED}Gagal menginstall OpenSSH Server. Periksa koneksi internet atau repository.${NC}"
        pause
        return
    fi

    local service_name
    service_name=$(get_ssh_service)
    systemctl enable "$service_name"
    systemctl start "$service_name"

    echo -e "${GREEN}OpenSSH Server berhasil diinstall dan dijalankan!${NC}"
    echo -e "${CYAN}Service: $service_name${NC}"
    echo -e "${CYAN}Versi  : $(sshd -V 2>&1 | head -n 1)${NC}"

    # PERBAIKAN: Ingatkan untuk cek firewall
    if command -v ufw &>/dev/null; then
        echo ""
        echo -e "${YELLOW}Terdeteksi UFW. Pastikan port SSH diizinkan, contoh: ufw allow 22/tcp${NC}"
    fi
    pause
}

# =========================================
# 17. Konfigurasi SSH Lengkap
# =========================================
configure_ssh() {
    clear
    echo -e "${YELLOW}[17] Konfigurasi SSH Lengkap${NC}"
    echo "========================================="

    if ! command -v sshd &>/dev/null; then
        echo -e "${RED}OpenSSH Server belum terinstall! Install dulu (menu [16]).${NC}"
        pause
        return
    fi

    local SSHD_CONFIG="/etc/ssh/sshd_config"
    if [ ! -f "$SSHD_CONFIG" ]; then
        echo -e "${RED}File $SSHD_CONFIG tidak ditemukan!${NC}"
        pause
        return
    fi

    # PERBAIKAN: Backup sshd_config sebelum diubah
    local BACKUP_DIR="/root/ssh_backups"
    mkdir -p "$BACKUP_DIR"
    local BACKUP_NAME="sshd_config-backup-$(date +%F-%H%M%S)"
    cp "$SSHD_CONFIG" "$BACKUP_DIR/$BACKUP_NAME"
    echo -e "${CYAN}Backup sshd_config disimpan di: $BACKUP_DIR/$BACKUP_NAME${NC}"
    echo ""

    # --- Port SSH ---
    read -p "Ubah port SSH? Masukkan port baru (kosongkan untuk lewati): " ssh_port
    if [ -n "$ssh_port" ]; then
        if validate_ssh_port "$ssh_port"; then
            sed -i '/^#\?Port /d' "$SSHD_CONFIG"
            echo "Port $ssh_port" >> "$SSHD_CONFIG"
            echo -e "${GREEN}Port SSH akan diubah ke $ssh_port${NC}"

            if command -v ufw &>/dev/null; then
                read -p "Izinkan port $ssh_port di UFW sekarang? (y/n): " allow_ufw
                if [ "$allow_ufw" = "y" ] || [ "$allow_ufw" = "Y" ]; then
                    ufw allow "$ssh_port"/tcp
                fi
            fi
        else
            echo -e "${YELLOW}Port tidak diubah karena tidak valid.${NC}"
        fi
    fi

    # --- Root Login ---
    echo ""
    echo -e "${CYAN}Opsi PermitRootLogin: yes / no / prohibit-password${NC}"
    read -p "Atur PermitRootLogin (kosongkan untuk lewati): " root_login
    if [ -n "$root_login" ]; then
        if [[ "$root_login" =~ ^(yes|no|prohibit-password)$ ]]; then
            sed -i '/^#\?PermitRootLogin /d' "$SSHD_CONFIG"
            echo "PermitRootLogin $root_login" >> "$SSHD_CONFIG"
            echo -e "${GREEN}PermitRootLogin diatur ke: $root_login${NC}"
        else
            echo -e "${RED}Nilai tidak valid, dilewati.${NC}"
        fi
    fi

    # --- Password Authentication ---
    echo ""
    read -p "Aktifkan Password Authentication? (y/n, kosongkan untuk lewati): " pass_auth
    if [ "$pass_auth" = "y" ] || [ "$pass_auth" = "Y" ]; then
        sed -i '/^#\?PasswordAuthentication /d' "$SSHD_CONFIG"
        echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
        echo -e "${GREEN}PasswordAuthentication diaktifkan.${NC}"
    elif [ "$pass_auth" = "n" ] || [ "$pass_auth" = "N" ]; then
        # PERBAIKAN: Peringatkan jika belum ada key based auth
        if [ ! -f "/root/.ssh/authorized_keys" ] && [ "$root_login" != "no" ]; then
            echo -e "${YELLOW}Peringatan: Tidak ditemukan /root/.ssh/authorized_keys.${NC}"
            echo -e "${YELLOW}Menonaktifkan password auth tanpa SSH key bisa mengunci akses Anda!${NC}"
            read -p "Tetap lanjutkan menonaktifkan Password Authentication? (y/n): " confirm_disable
            if [ "$confirm_disable" != "y" ] && [ "$confirm_disable" != "Y" ]; then
                echo -e "${YELLOW}Dilewati.${NC}"
            else
                sed -i '/^#\?PasswordAuthentication /d' "$SSHD_CONFIG"
                echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
                echo -e "${GREEN}PasswordAuthentication dinonaktifkan.${NC}"
            fi
        else
            sed -i '/^#\?PasswordAuthentication /d' "$SSHD_CONFIG"
            echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
            echo -e "${GREEN}PasswordAuthentication dinonaktifkan.${NC}"
        fi
    fi

    # --- Pubkey Authentication ---
    echo ""
    read -p "Aktifkan Pubkey Authentication? (y/n, kosongkan untuk lewati): " pubkey_auth
    if [ "$pubkey_auth" = "y" ] || [ "$pubkey_auth" = "Y" ]; then
        sed -i '/^#\?PubkeyAuthentication /d' "$SSHD_CONFIG"
        echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
        echo -e "${GREEN}PubkeyAuthentication diaktifkan.${NC}"
    elif [ "$pubkey_auth" = "n" ] || [ "$pubkey_auth" = "N" ]; then
        sed -i '/^#\?PubkeyAuthentication /d' "$SSHD_CONFIG"
        echo "PubkeyAuthentication no" >> "$SSHD_CONFIG"
        echo -e "${GREEN}PubkeyAuthentication dinonaktifkan.${NC}"
    fi

    # --- Max Auth Tries ---
    echo ""
    read -p "Atur MaxAuthTries (contoh: 3, kosongkan untuk lewati): " max_tries
    if [ -n "$max_tries" ] && [[ "$max_tries" =~ ^[0-9]+$ ]]; then
        sed -i '/^#\?MaxAuthTries /d' "$SSHD_CONFIG"
        echo "MaxAuthTries $max_tries" >> "$SSHD_CONFIG"
        echo -e "${GREEN}MaxAuthTries diatur ke: $max_tries${NC}"
    fi

    # --- Client Alive Interval (auto logout idle) ---
    echo ""
    read -p "Atur ClientAliveInterval detik, untuk auto-logout idle (kosongkan untuk lewati): " alive_interval
    if [ -n "$alive_interval" ] && [[ "$alive_interval" =~ ^[0-9]+$ ]]; then
        sed -i '/^#\?ClientAliveInterval /d' "$SSHD_CONFIG"
        echo "ClientAliveInterval $alive_interval" >> "$SSHD_CONFIG"
        sed -i '/^#\?ClientAliveCountMax /d' "$SSHD_CONFIG"
        echo "ClientAliveCountMax 2" >> "$SSHD_CONFIG"
        echo -e "${GREEN}ClientAliveInterval diatur ke: ${alive_interval}s${NC}"
    fi

    # --- Batasi user tertentu ---
    echo ""
    read -p "Batasi login SSH hanya untuk user tertentu? Masukkan username (pisahkan spasi, kosongkan untuk lewati): " allow_users
    if [ -n "$allow_users" ]; then
        sed -i '/^#\?AllowUsers /d' "$SSHD_CONFIG"
        echo "AllowUsers $allow_users" >> "$SSHD_CONFIG"
        echo -e "${GREEN}AllowUsers diatur ke: $allow_users${NC}"
    fi

    # --- Terapkan perubahan ---
    echo ""
    echo -e "${YELLOW}Menerapkan konfigurasi SSH...${NC}"
    if safe_restart_ssh; then
        echo -e "${GREEN}Konfigurasi SSH berhasil diterapkan!${NC}"
        echo -e "${CYAN}Backup konfigurasi lama: $BACKUP_DIR/$BACKUP_NAME${NC}"
        echo -e "${YELLOW}PENTING: Jangan tutup sesi SSH ini sebelum memverifikasi login baru berhasil di terminal lain!${NC}"
    else
        echo -e "${RED}Gagal menerapkan konfigurasi. Mengembalikan backup...${NC}"
        cp "$BACKUP_DIR/$BACKUP_NAME" "$SSHD_CONFIG"
        safe_restart_ssh
        echo -e "${YELLOW}Konfigurasi dikembalikan ke kondisi semula.${NC}"
    fi
    pause
}

# =========================================
# 18. Status SSH
# =========================================
status_ssh() {
    clear
    echo -e "${YELLOW}[18] Status Layanan SSH${NC}"
    echo "========================================="

    if ! command -v sshd &>/dev/null; then
        echo -e "${RED}OpenSSH Server tidak terinstall.${NC}"
        pause
        return
    fi

    local service_name
    service_name=$(get_ssh_service)
    systemctl status "$service_name" --no-pager

    echo ""
    echo -e "${CYAN}Port SSH yang aktif:${NC}"
    ss -tlnp 2>/dev/null | grep -i ssh || netstat -tlnp 2>/dev/null | grep -i ssh || echo "Tidak dapat mendeteksi port."

    echo ""
    echo -e "${CYAN}Pengaturan penting saat ini (sshd_config):${NC}"
    grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|MaxAuthTries|AllowUsers|ClientAliveInterval) " /etc/ssh/sshd_config 2>/dev/null || echo "Menggunakan nilai default (tidak ada override eksplisit)."
    pause
}

# =========================================
# 19. Uninstall Nginx (Clean)
# =========================================
uninstall_nginx() {
    clear
    echo -e "${RED}[19] Uninstall Nginx (Clean)${NC}"
    echo "========================================="
    echo -e "${RED}PERINGATAN! Ini akan menghapus Nginx dan SEMUA konfigurasinya secara permanen!${NC}"
    echo ""
    read -p "Ketik 'HAPUS' untuk konfirmasi: " konfirmasi
    if [ "$konfirmasi" != "HAPUS" ]; then
        echo -e "${YELLOW}Proses uninstall dibatalkan.${NC}"
        pause
        return
    fi

    # PERBAIKAN: Backup sebelum uninstall
    echo -e "${YELLOW}Membuat backup terakhir sebelum uninstall...${NC}"
    BACKUP_DIR="/root/nginx_backups"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_DIR/final-backup-$(date +%F-%H%M%S).tar.gz" /etc/nginx 2>/dev/null
    echo -e "${CYAN}Backup tersimpan di $BACKUP_DIR${NC}"

    systemctl stop nginx
    apt purge -y nginx nginx-common nginx-core nginx-full nginx-extras
    apt autoremove -y
    rm -rf /etc/nginx
    rm -rf /var/log/nginx

    echo -e "${GREEN}Nginx berhasil dihapus dari sistem.${NC}"
    echo -e "${CYAN}Backup konfigurasi tersimpan di: $BACKUP_DIR${NC}"
    pause
}

# =========================================
# 20. Uninstall SSH (Clean)
# =========================================
uninstall_ssh() {
    clear
    echo -e "${RED}[20] Uninstall SSH (Clean)${NC}"
    echo "========================================="
    echo -e "${RED}PERINGATAN SANGAT PENTING!${NC}"
    echo -e "${RED}Menghapus SSH akan MEMUTUS akses jarak jauh ke server ini melalui SSH.${NC}"
    echo -e "${RED}Jika ini satu-satunya cara Anda mengakses server (misal VPS tanpa console web),${NC}"
    echo -e "${RED}Anda bisa terkunci total dari server setelah proses ini selesai!${NC}"
    echo ""
    echo -e "${YELLOW}Pastikan Anda memiliki akses alternatif (console provider, KVM, dsb) sebelum lanjut.${NC}"
    echo ""

    if ! command -v sshd &>/dev/null; then
        echo -e "${YELLOW}OpenSSH Server tidak terdeteksi terinstall di sistem ini.${NC}"
        pause
        return
    fi

    read -p "Ketik 'HAPUS SSH' untuk konfirmasi: " konfirmasi
    if [ "$konfirmasi" != "HAPUS SSH" ]; then
        echo -e "${YELLOW}Proses uninstall dibatalkan.${NC}"
        pause
        return
    fi

    # PERBAIKAN: Backup konfigurasi SSH sebelum dihapus
    echo -e "${YELLOW}Membuat backup terakhir konfigurasi SSH sebelum uninstall...${NC}"
    BACKUP_DIR="/root/ssh_backups"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_DIR/final-ssh-backup-$(date +%F-%H%M%S).tar.gz" /etc/ssh 2>/dev/null
    echo -e "${CYAN}Backup tersimpan di $BACKUP_DIR${NC}"

    local service_name
    service_name=$(get_ssh_service)

    systemctl stop "$service_name" 2>/dev/null
    apt purge -y openssh-server
    apt autoremove -y
    rm -rf /etc/ssh

    echo -e "${GREEN}OpenSSH Server berhasil dihapus dari sistem.${NC}"
    echo -e "${CYAN}Backup konfigurasi tersimpan di: $BACKUP_DIR${NC}"
    echo -e "${YELLOW}Ingat: sesi SSH yang sedang berjalan mungkin masih aktif sampai ditutup manual.${NC}"
    pause
}

# =========================================
# MAIN MENU LOOP
# =========================================
while true; do
    clear
    echo "========================================="
    echo "           NGINX MANAGER v2.1            "
    echo "        $(date '+%Y-%m-%d %H:%M:%S')        "
    echo "========================================="
    echo ""
    echo -e " ${GREEN}--- Instalasi & Konfigurasi ---${NC}"
    echo -e " [1]  Install Nginx"
    echo -e " [2]  Configure Website (Umum)"
    echo -e " [3]  Configure Reverse Proxy"
    echo -e " [4]  Configure PHP Website"
    echo -e " [5]  Configure Static Website"
    echo ""
    echo -e " ${GREEN}--- SSL Management ---${NC}"
    echo -e " [6]  Install SSL (Let's Encrypt)"
    echo -e " [7]  Renew SSL"
    echo ""
    echo -e " ${GREEN}--- Backup & Restore ---${NC}"
    echo -e " [8]  Backup Nginx"
    echo -e " [9]  Restore Backup"
    echo ""
    echo -e " ${GREEN}--- Service Control ---${NC}"
    echo -e " [10] Restart Nginx"
    echo -e " [11] Reload Nginx"
    echo -e " [12] Test Configuration"
    echo -e " [13] Status Nginx"
    echo ""
    echo -e " ${GREEN}--- Website Management ---${NC}"
    echo -e " [14] List Website"
    echo -e " [15] Remove Website"
    echo ""
    echo -e " ${GREEN}--- SSH Management ---${NC}"
    echo -e " [16] Install SSH"
    echo -e " [17] Konfigurasi SSH Lengkap"
    echo -e " [18] Status SSH"
    echo ""
    echo -e " ${RED}--- Danger Zone ---${NC}"
    echo -e " [19] Uninstall Nginx (Clean)"
    echo -e " [20] Uninstall SSH (Clean)"
    echo ""
    echo -e " [0]  Exit"
    echo ""
    echo "========================================="
    read -p " Pilih menu [0-20]: " pilihan
    echo "========================================="

    case $pilihan in
        1)  install_nginx ;;
        2)  configure_website ;;
        3)  configure_reverse_proxy ;;
        4)  configure_php_website ;;
        5)  configure_static_website ;;
        6)  install_ssl ;;
        7)  renew_ssl ;;
        8)  backup_nginx ;;
        9)  restore_backup ;;
        10) restart_nginx ;;
        11) reload_nginx ;;
        12) test_config ;;
        13) status_nginx ;;
        14) list_websites ;;
        15) remove_website ;;
        16) install_ssh ;;
        17) configure_ssh ;;
        18) status_ssh ;;
        19) uninstall_nginx ;;
        20) uninstall_ssh ;;
        0)
            echo ""
            echo -e "${GREEN}Terima kasih telah menggunakan Nginx Manager v2.1!${NC}"
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Pilihan tidak valid! Silakan pilih antara 0-20.${NC}"
            sleep 2
            ;;
    esac
done
