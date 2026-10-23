#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SCRIPT ROLLBACK RUNTIME PHP (PEMULIHAN INSTAN KE VERSI SEBELUMNYA)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Jalankan skrip ini dengan hak akses root (sudo)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_FILE=""
BACKUP_DIR=""

if [ -n "${1:-}" ] && [ -f "$1/php_runtime_meta.env" ]; then
  META_FILE="$1/php_runtime_meta.env"
  BACKUP_DIR="$1"
elif [ -n "${1:-}" ] && [ -f "$1" ]; then
  META_FILE="$1"
  BACKUP_DIR=$(dirname "$1")
elif [ -f "${SCRIPT_DIR}/backups/latest/php_runtime_meta.env" ]; then
  META_FILE="${SCRIPT_DIR}/backups/latest/php_runtime_meta.env"
  BACKUP_DIR=$(readlink -f "${SCRIPT_DIR}/backups/latest" 2>/dev/null || realpath "${SCRIPT_DIR}/backups/latest")
elif [ -f "${SCRIPT_DIR}/backup-latest/php_runtime_meta.env" ]; then
  META_FILE="${SCRIPT_DIR}/backup-latest/php_runtime_meta.env"
  BACKUP_DIR=$(readlink -f "${SCRIPT_DIR}/backup-latest" 2>/dev/null || realpath "${SCRIPT_DIR}/backup-latest")
elif [ -d "${SCRIPT_DIR}/backups" ]; then
  LATEST_SUBDIR=$(find "${SCRIPT_DIR}/backups" -mindepth 1 -maxdepth 1 -type d ! -name "latest" 2>/dev/null | sort -r | head -n 1 || true)
  if [ -n "$LATEST_SUBDIR" ] && [ -f "${LATEST_SUBDIR}/php_runtime_meta.env" ]; then
    META_FILE="${LATEST_SUBDIR}/php_runtime_meta.env"
    BACKUP_DIR="$LATEST_SUBDIR"
  fi
elif [ -f "/root/php-backup-latest/php_runtime_meta.env" ]; then
  META_FILE="/root/php-backup-latest/php_runtime_meta.env"
  BACKUP_DIR=$(readlink -f "/root/php-backup-latest" 2>/dev/null || realpath "/root/php-backup-latest")
fi

if [ -z "$META_FILE" ] || [ ! -f "$META_FILE" ]; then
  echo "[-] Berkas metadata cadangan (php_runtime_meta.env) tidak ditemukan!"
  echo "[-] Tidak dapat menentukan konfigurasi versi PHP asal untuk pemulihan."
  exit 1
fi

# shellcheck source=/dev/null
source "$META_FILE"

UPGRADED_PHP_VER=""
if [ -f "${BACKUP_DIR}/upgrade_history.env" ]; then
  # shellcheck source=/dev/null
  source "${BACKUP_DIR}/upgrade_history.env"
fi

echo "=================================================="
echo "          ROLLBACK RUNTIME PHP SISTEM             "
echo "=================================================="
echo "Versi Asal Pemulihan      : PHP ${SOURCE_PHP_VER} (${SOURCE_PHP_PATCH})"
echo "Versi yang Di-upgrade     : ${UPGRADED_PHP_VER:-"Belum tercatat (versi saat ini)"}"
echo "Folder Arsip Sumber       : ${BACKUP_DIR}"
echo "Web Server Terkait        : Apache2=${HAS_APACHE:-false}, Nginx=${HAS_NGINX:-false}"
echo "--------------------------------------------------"

read -rp "Yakin ingin mengembalikan seluruh konfigurasi ke PHP ${SOURCE_PHP_VER}? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "[-] Rollback dibatalkan oleh pengguna."
  exit 0
fi

# ==========================================
# 1. KEMBALIKAN CLI ALTERNATIVES
# ==========================================
echo "[+] Mengembalikan CLI default ke PHP ${SOURCE_PHP_VER}..."
if [ -f "/usr/bin/php${SOURCE_PHP_VER}" ]; then
  update-alternatives --set php "/usr/bin/php${SOURCE_PHP_VER}" 2>/dev/null || true
  [ -f "/usr/bin/phar${SOURCE_PHP_VER}" ] && update-alternatives --set phar "/usr/bin/phar${SOURCE_PHP_VER}" 2>/dev/null || true
  [ -f "/usr/bin/phar.phar${SOURCE_PHP_VER}" ] && update-alternatives --set phar.phar "/usr/bin/phar.phar${SOURCE_PHP_VER}" 2>/dev/null || true
fi

# ==========================================
# 2. AKTIFKAN KEMBALI PHP-FPM ASAL
# ==========================================
if [ "${HAS_FPM:-false}" = true ] || systemctl list-unit-files | grep -q "php${SOURCE_PHP_VER}-fpm" || systemctl list-unit-files | grep -q "php5-fpm"; then
  echo "[+] Mengaktifkan dan menyalakan kembali service FPM asal..."
  systemctl enable "php${SOURCE_PHP_VER}-fpm" 2>/dev/null || true
  systemctl restart "php${SOURCE_PHP_VER}-fpm" 2>/dev/null || true
  systemctl enable "php5-fpm" 2>/dev/null || true
  systemctl restart "php5-fpm" 2>/dev/null || true
fi

# Matikan FPM yang sempat di-upgrade jika ada
if [ -n "$UPGRADED_PHP_VER" ] && systemctl is-active --quiet "php${UPGRADED_PHP_VER}-fpm" 2>/dev/null; then
  echo "[+] Menonaktifkan service php${UPGRADED_PHP_VER}-fpm..."
  systemctl stop "php${UPGRADED_PHP_VER}-fpm" 2>/dev/null || true
  systemctl disable "php${UPGRADED_PHP_VER}-fpm" 2>/dev/null || true
fi

# ==========================================
# 3. KEMBALIKAN KONFIGURASI NGINX
# ==========================================
if [ "${HAS_NGINX:-false}" = true ] && [ -d "/etc/nginx" ]; then
  echo "[+] Memulihkan konfigurasi Nginx..."
  
  if [ -d "${BACKUP_DIR}/nginx-backup" ]; then
    cp -a "${BACKUP_DIR}/nginx-backup/." / 2>/dev/null || true
    echo "    - Berkas konfigurasi VHost Nginx dipulihkan dari arsip backup."
  elif [ -n "$UPGRADED_PHP_VER" ]; then
    find /etc/nginx/sites-available/ /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ -type f -exec sed -i -E "s|php${UPGRADED_PHP_VER}-fpm\.sock|php${SOURCE_PHP_VER}-fpm.sock|g" {} + 2>/dev/null || true
  fi

  echo "[+] Memvalidasi sintaks Nginx (sudo nginx -t)..."
  if nginx -t; then
    echo "[+] Me-restart layanan Nginx (sudo systemctl restart nginx)..."
    systemctl restart nginx
    echo "[✓] Nginx berhasil divalidasi dan di-restart."
  else
    echo "[-] [PERINGATAN] Validasi Nginx gagal! Periksa sintaks dengan 'nginx -t'."
  fi
fi

# ==========================================
# 4. KEMBALIKAN KONFIGURASI APACHE2
# ==========================================
if [ "${HAS_APACHE:-false}" = true ] && [ -d "/etc/apache2" ]; then
  echo "[+] Memulihkan konfigurasi Apache2..."

  if [ "${APACHE_MODE:-none}" = "mod_php" ]; then
    [ -n "$UPGRADED_PHP_VER" ] && a2dismod "php${UPGRADED_PHP_VER}" 2>/dev/null || true
    a2enmod "php${SOURCE_PHP_VER}" 2>/dev/null || a2enmod "php5" 2>/dev/null || true
  fi

  if [ -d "/etc/apache2/conf-available" ]; then
    [ -n "$UPGRADED_PHP_VER" ] && a2disconf "php${UPGRADED_PHP_VER}-fpm" 2>/dev/null || true
    a2enconf "php${SOURCE_PHP_VER}-fpm" 2>/dev/null || a2enconf "php5-fpm" 2>/dev/null || true
  fi

  if [ -d "${BACKUP_DIR}/apache-backup" ]; then
    cp -a "${BACKUP_DIR}/apache-backup/." / 2>/dev/null || true
    echo "    - Berkas VHost Apache2 dipulihkan dari arsip backup."
  fi

  if command -v apache2ctl >/dev/null 2>&1; then
    echo "[+] Memvalidasi sintaks Apache2 (apache2ctl configtest)..."
    if apache2ctl configtest; then
      systemctl restart apache2
      echo "[✓] Apache2 berhasil divalidasi dan di-restart."
    fi
  elif command -v apachectl >/dev/null 2>&1; then
    echo "[+] Memvalidasi sintaks Apache (apachectl configtest)..."
    if apachectl configtest; then
      systemctl restart apache2 2>/dev/null || systemctl restart httpd 2>/dev/null || true
      echo "[✓] Apache berhasil divalidasi dan di-restart."
    fi
  fi
fi

echo "=================================================="
echo "[✓] PROSES ROLLBACK BERHASIL!"
echo "=================================================="
php -v
echo "Sistem telah sepenuhnya dikembalikan ke konfigurasi PHP ${SOURCE_PHP_VER}."
echo "=================================================="
