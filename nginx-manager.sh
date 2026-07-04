#!/bin/bash

# =========================================
#          NGINX MANAGER v2.0
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
# 16. Uninstall Nginx (Clean)
# =========================================
uninstall_nginx() {
    clear
    echo -e "${RED}[16] Uninstall Nginx (Clean)${NC}"
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
# MAIN MENU LOOP
# =========================================
while true; do
    clear
    echo "========================================="
    echo "           NGINX MANAGER v2.0            "
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
    echo -e " ${RED}--- Danger Zone ---${NC}"
    echo -e " [16] Uninstall Nginx (Clean)"
    echo ""
    echo -e " [0]  Exit"
    echo ""
    echo "========================================="
    read -p " Pilih menu [0-16]: " pilihan
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
        16) uninstall_nginx ;;
        0)
            echo ""
            echo -e "${GREEN}Terima kasih telah menggunakan Nginx Manager v2.0!${NC}"
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Pilihan tidak valid! Silakan pilih antara 0-16.${NC}"
            sleep 2
            ;;
    esac
done
