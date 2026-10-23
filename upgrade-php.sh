#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SCRIPT UPGRADE RUNTIME PHP OTOMATIS (APACHE2 & NGINX READY)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Jalankan skrip ini dengan hak akses root (sudo)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_FILE=""
BACKUP_DIR=""

# Prioritas pencarian metadata:
# 1. Parameter pertama skrip (jika diberikan path direktori atau file env)
if [ -n "${1:-}" ] && [ -f "$1/php_runtime_meta.env" ]; then
  META_FILE="$1/php_runtime_meta.env"
  BACKUP_DIR="$1"
elif [ -n "${1:-}" ] && [ -f "$1" ]; then
  META_FILE="$1"
  BACKUP_DIR=$(dirname "$1")
# 2. Folder backups lokal di dalam project ini (backups/latest)
elif [ -f "${SCRIPT_DIR}/backups/latest/php_runtime_meta.env" ]; then
  META_FILE="${SCRIPT_DIR}/backups/latest/php_runtime_meta.env"
  BACKUP_DIR=$(readlink -f "${SCRIPT_DIR}/backups/latest" 2>/dev/null || realpath "${SCRIPT_DIR}/backups/latest")
elif [ -f "${SCRIPT_DIR}/backup-latest/php_runtime_meta.env" ]; then
  META_FILE="${SCRIPT_DIR}/backup-latest/php_runtime_meta.env"
  BACKUP_DIR=$(readlink -f "${SCRIPT_DIR}/backup-latest" 2>/dev/null || realpath "${SCRIPT_DIR}/backup-latest")
# 3. Cari subfolder terbaru di dalam project/backups/
elif [ -d "${SCRIPT_DIR}/backups" ]; then
  LATEST_SUBDIR=$(find "${SCRIPT_DIR}/backups" -mindepth 1 -maxdepth 1 -type d ! -name "latest" 2>/dev/null | sort -r | head -n 1 || true)
  if [ -n "$LATEST_SUBDIR" ] && [ -f "${LATEST_SUBDIR}/php_runtime_meta.env" ]; then
    META_FILE="${LATEST_SUBDIR}/php_runtime_meta.env"
    BACKUP_DIR="$LATEST_SUBDIR"
  fi
# 4. Fallback ke /root/php-backup-latest jika dijalankan di VPS terpisah
elif [ -f "/root/php-backup-latest/php_runtime_meta.env" ]; then
  META_FILE="/root/php-backup-latest/php_runtime_meta.env"
  BACKUP_DIR=$(readlink -f "/root/php-backup-latest" 2>/dev/null || realpath "/root/php-backup-latest")
fi

if [ -z "$META_FILE" ] || [ ! -f "$META_FILE" ]; then
  echo "[-] Berkas metadata cadangan (php_runtime_meta.env) tidak ditemukan!"
  echo "[-] Jalankan backup-php.sh terlebih dahulu di dalam project ini sebelum upgrade."
  exit 1
fi

# shellcheck source=/dev/null
source "$META_FILE"

echo "=================================================="
echo "          UPGRADE RUNTIME PHP OTOMATIS            "
echo "=================================================="
echo "Versi Sumber Terdeteksi   : ${SOURCE_PHP_PATCH} (Family ${SOURCE_PHP_VER})"
echo "Folder Referensi Cadangan : ${BACKUP_DIR}"
echo "Web Server Terdeteksi     : Apache2=${HAS_APACHE:-false}, Nginx=${HAS_NGINX:-false}"
echo "Mode Apache               : ${APACHE_MODE:-none}"
echo "PHP-FPM Aktif             : ${HAS_FPM:-false}"
echo "--------------------------------------------------"

# ==========================================
# 1. PROMPT VERSI PHP TARGET
# ==========================================
TARGET_INPUT=""
if [ -n "${1:-}" ] && [[ "$1" =~ ^[0-9]+\.[0-9]+ ]]; then
  TARGET_INPUT="$1"
elif [ -n "${2:-}" ] && [[ "$2" =~ ^[0-9]+\.[0-9]+ ]]; then
  TARGET_INPUT="$2"
elif [ -n "${TARGET_PHP_VERSION:-}" ]; then
  TARGET_INPUT="${TARGET_PHP_VERSION}"
fi

if [ -z "$TARGET_INPUT" ]; then
  read -rp "Masukkan versi PHP target (contoh: 8.3, 8.4, 8.5): " TARGET_INPUT
fi

if [ -z "$TARGET_INPUT" ]; then
  echo "[-] Versi target tidak boleh kosong! Proses dibatalkan."
  exit 1
fi

TARGET_FAMILY=$(echo "$TARGET_INPUT" | awk -F. '{print $1"."$2}')

SYSTEM_ACTIVE_PHP=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
ALREADY_UPGRADED=false

if [ "$TARGET_FAMILY" = "$SYSTEM_ACTIVE_PHP" ]; then
  echo "[i] PHP ${TARGET_FAMILY} sudah aktif sebagai runtime sistem saat ini."
  echo "[+] Mode pelengkapan: Memeriksa kelengkapan modul dan menyelaraskan layanan..."
  ALREADY_UPGRADED=true
elif [ "$TARGET_FAMILY" = "$SOURCE_PHP_VER" ]; then
  echo "[i] Versi target (${TARGET_FAMILY}) sama dengan versi backup awal (${SOURCE_PHP_VER})."
  echo "[+] Menjalankan pemeriksaan kelengkapan modul dan konfigurasi..."
  ALREADY_UPGRADED=true
fi

echo "[+] Target Versi PHP Mayor.Minor : php${TARGET_FAMILY}"
echo "--------------------------------------------------"

# ==========================================
# 2. KONFIGURASI REPOSITORI APT (SURÝ)
# ==========================================
export DEBIAN_FRONTEND=noninteractive
echo "[+] Memperbarui repositori paket sistem..."
apt-get update -y
apt-get install -y software-properties-common ca-certificates lsb-release apt-transport-https curl gnupg

# Deteksi apakah sistem Ubuntu atau Debian
OS_DISTRO=$(lsb_release -is 2>/dev/null || grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

if [ "$OS_DISTRO" = "Ubuntu" ]; then
  if ! grep -qr "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    echo "[+] Menambahkan repositori PPA Ondrej PHP (Ubuntu)..."
    add-apt-repository ppa:ondrej/php -y
  fi
else
  # Debian Setup
  if [ ! -f /etc/apt/trusted.gpg.d/php.gpg ]; then
    echo "[+] Mengunduh GPG Key Sury PHP (Debian)..."
    curl -sSLo /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  fi
  DEB_CODENAME=$(lsb_release -cs 2>/dev/null || grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
  echo "deb https://packages.sury.org/php/ ${DEB_CODENAME} main" > /etc/apt/sources.list.d/php.list
fi
apt-get update -y

# ==========================================
# 3. INSTALASI PAKET INTI PHP
# ==========================================
echo "[+] Memeriksa paket inti php${TARGET_FAMILY}..."
CORE_PACKAGES=(
  "php${TARGET_FAMILY}-cli"
  "php${TARGET_FAMILY}-common"
  "php${TARGET_FAMILY}-readline"
)

# Jika FPM aktif atau Nginx ada atau Apache mode fpm_proxy, pasang FPM
if [ "${HAS_FPM:-false}" = true ] || [ "${HAS_NGINX:-false}" = true ] || [ "${APACHE_MODE:-none}" = "fpm_proxy" ]; then
  CORE_PACKAGES+=("php${TARGET_FAMILY}-fpm")
fi

# Jika Apache menggunakan mod_php tradisional, pasang modul apache
if [ "${HAS_APACHE:-false}" = true ] && [ "${APACHE_MODE:-none}" = "mod_php" ]; then
  CORE_PACKAGES+=("libapache2-mod-php${TARGET_FAMILY}")
fi

MISSING_CORE_PACKAGES=()
for core_pkg in "${CORE_PACKAGES[@]}"; do
  if ! dpkg -s "$core_pkg" >/dev/null 2>&1; then
    MISSING_CORE_PACKAGES+=("$core_pkg")
  fi
done

if [ ${#MISSING_CORE_PACKAGES[@]} -gt 0 ]; then
  echo "[+] Memasang paket inti yang belum terpasang: ${MISSING_CORE_PACKAGES[*]}"
  apt-get install -y --no-install-recommends "${MISSING_CORE_PACKAGES[@]}"
else
  echo "    - Seluruh paket inti php${TARGET_FAMILY} telah terpasang."
fi

# ==========================================
# 4. SINKRONISASI & INSTALASI EKSTENSI LENGKAP
# ==========================================
echo "[+] Menyelaraskan daftar ekstensi dengan versi sebelumnya..."
PACKAGES_TO_INSTALL=()

# Helper untuk memverifikasi apakah kandidat instalasi paket benar-benar tersedia (bukan virtual package)
is_package_installable() {
  local pkg="$1"
  if [[ ! "$pkg" =~ ^[a-z0-9.+-]+$ ]]; then
    return 1
  fi
  local candidate
  candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')
  if [ -n "$candidate" ] && [ "$candidate" != "(none)" ]; then
    return 0
  fi
  return 1
}

# Modul core/built-in PHP yang tidak memiliki paket terpisah pada PHP 8+
CORE_MODULES_REGEX="^(common|cli|fpm|opcache|readline|json|core|date|pcre|zlib|filter|hash|reflection|spl|standard|session|tokenizer|openssl|phar|posix|shmop|sockets|sysvmsg|sysvsem|sysvshm|ctype|libxml|iconv|zend.*|\[.*)$"

EXT_FILE="${BACKUP_DIR}/01-installed-extensions.txt"
[ ! -f "$EXT_FILE" ] && EXT_FILE="${BACKUP_DIR}/installed-extensions.txt"

if [ -f "$EXT_FILE" ]; then
  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext_lower" =~ $CORE_MODULES_REGEX ]]; then
      continue
    fi
    PKG="php${TARGET_FAMILY}-${ext_lower}"
    if is_package_installable "$PKG"; then
      PACKAGES_TO_INSTALL+=("$PKG")
    fi
  done < "$EXT_FILE"
fi

MOD_FILE="${BACKUP_DIR}/02-php-modules-runtime.txt"
[ ! -f "$MOD_FILE" ] && MOD_FILE="${BACKUP_DIR}/php-modules-runtime.txt"

if [ -f "$MOD_FILE" ]; then
  while IFS= read -r mod; do
    [ -z "$mod" ] && continue
    mod_lower=$(echo "$mod" | tr '[:upper:]' '[:lower:]')
    if [[ "$mod_lower" =~ $CORE_MODULES_REGEX ]]; then
      continue
    fi
    case "$mod_lower" in
      pdo_mysql|mysqli|mysqlnd) PKG="php${TARGET_FAMILY}-mysql" ;;
      pdo_pgsql|pgsql)         PKG="php${TARGET_FAMILY}-pgsql" ;;
      pdo_sqlite|sqlite3)      PKG="php${TARGET_FAMILY}-sqlite3" ;;
      simplexml|dom|xmlreader|xmlwriter) PKG="php${TARGET_FAMILY}-xml" ;;
      *)                        PKG="php${TARGET_FAMILY}-${mod_lower}" ;;
    esac

    if is_package_installable "$PKG"; then
      if [[ ! " ${PACKAGES_TO_INSTALL[*]:-} " =~ " ${PKG} " ]]; then
        PACKAGES_TO_INSTALL+=("$PKG")
      fi
    fi
  done < "$MOD_FILE"
fi

CORE_DEFAULTS=("curl" "mbstring" "xml" "zip" "bcmath" "intl")
for def in "${CORE_DEFAULTS[@]}"; do
  PKG="php${TARGET_FAMILY}-${def}"
  if is_package_installable "$PKG"; then
    if [[ ! " ${PACKAGES_TO_INSTALL[*]:-} " =~ " ${PKG} " ]]; then
      PACKAGES_TO_INSTALL+=("$PKG")
    fi
  fi
done

# Saring hanya modul/ekstensi yang belum terpasang di sistem
MISSING_EXTENSIONS=()
for ext_pkg in "${PACKAGES_TO_INSTALL[@]}"; do
  if ! dpkg -s "$ext_pkg" >/dev/null 2>&1; then
    MISSING_EXTENSIONS+=("$ext_pkg")
  fi
done

if [ ${#MISSING_EXTENSIONS[@]} -gt 0 ]; then
  echo "[+] Memasang modul/ekstensi yang belum terpasang: ${MISSING_EXTENSIONS[*]}"
  if ! apt-get install -y "${MISSING_EXTENSIONS[@]}"; then
    echo "[!] Sebagian paket ekstensi mengalami kendala instalasi massal, memasang modul valid satu per satu..."
    for pkg in "${MISSING_EXTENSIONS[@]}"; do
      apt-get install -y "$pkg" || echo "[-] Gagal memasang $pkg (dilewati)"
    done
  fi
else
  echo "    - Seluruh modul/ekstensi (${#PACKAGES_TO_INSTALL[@]} modul) telah lengkap terpasang di sistem."
fi

# ==========================================
# 5. SWITCH ALTERNATIVE CLI SISTEM
# ==========================================
echo "[+] Mengalihkan CLI default sistem ke PHP ${TARGET_FAMILY}..."
update-alternatives --set php "/usr/bin/php${TARGET_FAMILY}" 2>/dev/null || true
[ -f "/usr/bin/phar${TARGET_FAMILY}" ] && update-alternatives --set phar "/usr/bin/phar${TARGET_FAMILY}" 2>/dev/null || true
[ -f "/usr/bin/phar.phar${TARGET_FAMILY}" ] && update-alternatives --set phar.phar "/usr/bin/phar.phar${TARGET_FAMILY}" 2>/dev/null || true

# ==========================================
# 6. SINKRONISASI KONFIGURASI PHP.INI (AMAN PER SAPI)
# ==========================================
sync_ini_settings() {
  local src_ini="$1"
  local dst_ini="$2"
  local sapi_name="$3"

  if [ -f "$src_ini" ] && [ -f "$dst_ini" ]; then
    echo "[+] Menyinkronkan konfigurasi resource ${sapi_name} dari ${src_ini}..."
    
    get_val() {
      grep -E "^[[:space:]]*${1}[[:space:]]*=" "$src_ini" | tail -n 1 | awk -F'=' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//' || true
    }

    local mem_limit=$(get_val "memory_limit")
    local exec_time=$(get_val "max_execution_time")
    local post_max=$(get_val "post_max_size")
    local upload_max=$(get_val "upload_max_filesize")
    local timezone=$(get_val "date.timezone")
    local max_vars=$(get_val "max_input_vars")

    [ -n "$mem_limit" ]  && sed -i "s|^;*[[:space:]]*memory_limit = .*|memory_limit = ${mem_limit}|" "$dst_ini"
    [ -n "$exec_time" ]  && sed -i "s|^;*[[:space:]]*max_execution_time = .*|max_execution_time = ${exec_time}|" "$dst_ini"
    [ -n "$post_max" ]   && sed -i "s|^;*[[:space:]]*post_max_size = .*|post_max_size = ${post_max}|" "$dst_ini"
    [ -n "$upload_max" ] && sed -i "s|^;*[[:space:]]*upload_max_filesize = .*|upload_max_filesize = ${upload_max}|" "$dst_ini"
    [ -n "$timezone" ]   && sed -i "s|^;*[[:space:]]*date.timezone = .*|date.timezone = ${timezone}|" "$dst_ini"
    [ -n "$max_vars" ]   && sed -i "s|^;*[[:space:]]*max_input_vars = .*|max_input_vars = ${max_vars}|" "$dst_ini"

    echo "    - Konfigurasi ${sapi_name} berhasil diterapkan di ${dst_ini}"
  fi
}

CLI_SRC="${BACKUP_DIR}/loaded_ini/cli_php.ini"
[ ! -f "$CLI_SRC" ] && CLI_SRC="${BACKUP_DIR}/loaded_ini/php.ini.source"
sync_ini_settings "$CLI_SRC" "/etc/php/${TARGET_FAMILY}/cli/php.ini" "CLI"

FPM_SRC="${BACKUP_DIR}/loaded_ini/fpm_php.ini"
[ ! -f "$FPM_SRC" ] && FPM_SRC="$CLI_SRC"
sync_ini_settings "$FPM_SRC" "/etc/php/${TARGET_FAMILY}/fpm/php.ini" "FPM"

APACHE_SRC="${BACKUP_DIR}/loaded_ini/apache2_php.ini"
sync_ini_settings "$APACHE_SRC" "/etc/php/${TARGET_FAMILY}/apache2/php.ini" "Apache2"

# ==========================================
# 7. MIGRASI & TUNING POOL PHP-FPM
# ==========================================
TARGET_FPM_CONF="/etc/php/${TARGET_FAMILY}/fpm/pool.d/www.conf"
SOURCE_FPM_POOLS="${BACKUP_DIR}/fpm-pools"

if [ -d "/etc/php/${TARGET_FAMILY}/fpm/pool.d" ]; then
  echo "[+] Menyinkronkan konfigurasi pool FPM..."

  if [ -f "${SOURCE_FPM_POOLS}/www.conf" ] && [ -f "$TARGET_FPM_CONF" ]; then
    get_fpm_val() {
      grep -E "^[[:space:]]*${1}[[:space:]]*=" "${SOURCE_FPM_POOLS}/www.conf" | tail -n 1 | awk -F'=' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//' || true
    }

    OLD_PM=$(get_fpm_val "pm")
    OLD_MAX_CHILDREN=$(get_fpm_val "pm.max_children")
    OLD_START_SERVERS=$(get_fpm_val "pm.start_servers")
    OLD_MIN_SPARE=$(get_fpm_val "pm.min_spare_servers")
    OLD_MAX_SPARE=$(get_fpm_val "pm.max_spare_servers")
    OLD_TERM_TIMEOUT=$(get_fpm_val "request_terminate_timeout")

    [ -n "$OLD_PM" ]           && sed -i "s|^;*[[:space:]]*pm = .*|pm = ${OLD_PM}|" "$TARGET_FPM_CONF"
    [ -n "$OLD_MAX_CHILDREN" ] && sed -i "s|^;*[[:space:]]*pm.max_children = .*|pm.max_children = ${OLD_MAX_CHILDREN}|" "$TARGET_FPM_CONF"
    [ -n "$OLD_START_SERVERS" ] && sed -i "s|^;*[[:space:]]*pm.start_servers = .*|pm.start_servers = ${OLD_START_SERVERS}|" "$TARGET_FPM_CONF"
    [ -n "$OLD_MIN_SPARE" ]    && sed -i "s|^;*[[:space:]]*pm.min_spare_servers = .*|pm.min_spare_servers = ${OLD_MIN_SPARE}|" "$TARGET_FPM_CONF"
    [ -n "$OLD_MAX_SPARE" ]    && sed -i "s|^;*[[:space:]]*pm.max_spare_servers = .*|pm.max_spare_servers = ${OLD_MAX_SPARE}|" "$TARGET_FPM_CONF"
    [ -n "$OLD_TERM_TIMEOUT" ] && sed -i "s|^;*[[:space:]]*request_terminate_timeout = .*|request_terminate_timeout = ${OLD_TERM_TIMEOUT}|" "$TARGET_FPM_CONF"

    echo "    - Tuning performa FPM (pm.max_children=${OLD_MAX_CHILDREN:-default}) berhasil dimigrasi."
  fi

  if [ -d "$SOURCE_FPM_POOLS" ]; then
    for custom_pool in "$SOURCE_FPM_POOLS"/*.conf; do
      [ ! -f "$custom_pool" ] && continue
      pool_basename=$(basename "$custom_pool")
      if [ "$pool_basename" != "www.conf" ]; then
        echo "    - Menyalin custom pool: ${pool_basename}..."
        cp -a "$custom_pool" "/etc/php/${TARGET_FAMILY}/fpm/pool.d/"
        sed -i "s|php${SOURCE_PHP_VER}-fpm\.sock|php${TARGET_FAMILY}-fpm.sock|g" "/etc/php/${TARGET_FAMILY}/fpm/pool.d/${pool_basename}"
      fi
    done
  fi

  echo "[+] Menjalankan service php${TARGET_FAMILY}-fpm..."
  systemctl enable "php${TARGET_FAMILY}-fpm"
  systemctl restart "php${TARGET_FAMILY}-fpm"

  sleep 1
  TARGET_SOCK="/run/php/php${TARGET_FAMILY}-fpm.sock"
  if [ -S "$TARGET_SOCK" ]; then
    echo "    - Socket FPM baru terverifikasi aktif di: ${TARGET_SOCK}"
  else
    echo "    - [!] Peringatan: Socket ${TARGET_SOCK} belum terdeteksi. Memeriksa status systemd..."
    systemctl status "php${TARGET_FAMILY}-fpm" --no-pager || true
  fi
fi

# ==========================================
# 8. PERBARUI KONFIGURASI NGINX (AMAN MULTI-PHP)
# ==========================================
if [ "${HAS_NGINX:-false}" = true ] || [ -d "/etc/nginx" ]; then
  echo "[+] Memeriksa dan memperbarui konfigurasi Nginx (sites-available, sites-enabled, conf.d)..."
  
  NGINX_FILES_RAW=()
  NGINX_LIST="${BACKUP_DIR}/06-nginx-affected-vhosts.txt"
  [ ! -f "$NGINX_LIST" ] && NGINX_LIST="${BACKUP_DIR}/nginx-affected-vhosts.txt"
  if [ -f "$NGINX_LIST" ]; then
    while IFS= read -r conf_file; do
      [ -f "$conf_file" ] && NGINX_FILES_RAW+=("$conf_file")
    done < "$NGINX_LIST"
  fi

  # Pindai langsung direktori sites-available, sites-enabled, conf.d untuk fastcgi_pass socket lama
  while IFS= read -r live_file; do
    [ -f "$live_file" ] && NGINX_FILES_RAW+=("$live_file")
  done < <(grep -rEl "php.*${SOURCE_PHP_VER}.*fpm\.sock" /etc/nginx/sites-available/ /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null || true)

  # Ambil daftar unik berkas konfigurasi
  UNIQUE_NGINX_FILES=()
  if [ ${#NGINX_FILES_RAW[@]} -gt 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && UNIQUE_NGINX_FILES+=("$f")
    done < <(printf "%s\n" "${NGINX_FILES_RAW[@]}" | sort -u)
  fi

  UPDATED_COUNT=0
  for conf_file in "${UNIQUE_NGINX_FILES[@]:-}"; do
    if [ -f "$conf_file" ]; then
      sed -i -E "s|php${SOURCE_PHP_VER}-fpm\.sock|php${TARGET_FAMILY}-fpm.sock|g" "$conf_file"
      echo "    - VHost / konfigurasi Nginx diperbarui (fastcgi_pass): ${conf_file}"
      UPDATED_COUNT=$((UPDATED_COUNT + 1))
    fi
  done

  if [ "$UPDATED_COUNT" -eq 0 ]; then
    echo "    - Tidak ada berkas VHost yang memerlukan penggantian socket php${SOURCE_PHP_VER}-fpm.sock."
  fi

  echo "[+] Menjalankan validasi sintaks Nginx (sudo nginx -t)..."
  if nginx -t; then
    echo "[+] Me-restart layanan Nginx (sudo systemctl restart nginx)..."
    systemctl restart nginx
    echo "[✓] Nginx berhasil divalidasi dan di-restart dengan socket php${TARGET_FAMILY}-fpm."
  else
    echo "[-] [PERINGATAN] Validasi Nginx gagal! Periksa sintaks dengan 'nginx -t'."
  fi
fi

# ==========================================
# 9. PERBARUI KONFIGURASI APACHE2
# ==========================================
if [ "${HAS_APACHE:-false}" = true ] || [ -d "/etc/apache2" ]; then
  echo "[+] Memeriksa dan memperbarui integrasi Apache2..."

  if [ "${APACHE_MODE:-none}" = "mod_php" ]; then
    echo "    - Beralih dari mod_php${SOURCE_PHP_VER} ke mod_php${TARGET_FAMILY}..."
    a2dismod "php${SOURCE_PHP_VER}" 2>/dev/null || true
    a2enmod "php${TARGET_FAMILY}" 2>/dev/null || true
  fi

  if [ -d "/etc/apache2/conf-available" ]; then
    a2disconf "php${SOURCE_PHP_VER}-fpm" 2>/dev/null || true
    a2enconf "php${TARGET_FAMILY}-fpm" 2>/dev/null || true
  fi

  APACHE_FILES_RAW=()
  APACHE_LIST="${BACKUP_DIR}/07-apache-affected-vhosts.txt"
  if [ -f "$APACHE_LIST" ] && [ -s "$APACHE_LIST" ]; then
    while IFS= read -r conf_file; do
      [ -f "$conf_file" ] && APACHE_FILES_RAW+=("$conf_file")
    done < "$APACHE_LIST"
  fi

  while IFS= read -r live_apache_file; do
    [ -f "$live_apache_file" ] && APACHE_FILES_RAW+=("$live_apache_file")
  done < <(grep -rEl "php.*${SOURCE_PHP_VER}.*fpm\.sock" /etc/apache2/sites-available/ /etc/apache2/conf-available/ /etc/apache2/sites-enabled/ 2>/dev/null || true)

  UNIQUE_APACHE_FILES=()
  if [ ${#APACHE_FILES_RAW[@]} -gt 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && UNIQUE_APACHE_FILES+=("$f")
    done < <(printf "%s\n" "${APACHE_FILES_RAW[@]}" | sort -u)
  fi

  for conf_file in "${UNIQUE_APACHE_FILES[@]:-}"; do
    if [ -f "$conf_file" ]; then
      sed -i -E "s|php${SOURCE_PHP_VER}-fpm\.sock|php${TARGET_FAMILY}-fpm.sock|g" "$conf_file"
      echo "    - VHost / konfigurasi Apache2 diperbarui (SetHandler/proxy): ${conf_file}"
    fi
  done

  if command -v apache2ctl >/dev/null 2>&1; then
    echo "[+] Menjalankan validasi sintaks Apache2 (apache2ctl configtest)..."
    if apache2ctl configtest; then
      echo "[+] Me-restart layanan Apache2 (systemctl restart apache2)..."
      systemctl restart apache2
      echo "[✓] Apache2 berhasil divalidasi dan di-restart."
    else
      echo "[-] [PERINGATAN] Validasi konfigurasi Apache2 gagal!"
    fi
  elif command -v apachectl >/dev/null 2>&1; then
    echo "[+] Menjalankan validasi sintaks Apache (apachectl configtest)..."
    if apachectl configtest; then
      echo "[+] Me-restart layanan Apache..."
      systemctl restart apache2 2>/dev/null || systemctl restart httpd 2>/dev/null || true
      echo "[✓] Apache berhasil divalidasi dan di-restart."
    else
      echo "[-] [PERINGATAN] Validasi konfigurasi Apache gagal!"
    fi
  fi
fi

# ==========================================
# 10. PENGELOLAAN SERVICE PHP (MATIKAN LAMA & PASTIKAN AKTIF BARU)
# ==========================================
echo "[+] Menyelaraskan status layanan PHP (PHP-FPM)..."

# 1. Pastikan service PHP baru terpasang, diaktifkan di boot, dan berjalan
if [ -d "/etc/php/${TARGET_FAMILY}/fpm" ] || [ "${HAS_FPM:-false}" = true ]; then
  echo "    - Mengaktifkan dan menyalakan service php${TARGET_FAMILY}-fpm..."
  systemctl enable "php${TARGET_FAMILY}-fpm" 2>/dev/null || true
  systemctl restart "php${TARGET_FAMILY}-fpm"
  echo "    [✓] Service php${TARGET_FAMILY}-fpm aktif dan berjalan."
fi

# 2. Hentikan dan nonaktifkan service PHP lama agar menghemat RAM sistem
if systemctl is-active --quiet "php${SOURCE_PHP_VER}-fpm" 2>/dev/null || systemctl is-enabled --quiet "php${SOURCE_PHP_VER}-fpm" 2>/dev/null; then
  echo "    - Menghentikan dan menonaktifkan service php${SOURCE_PHP_VER}-fpm..."
  systemctl stop "php${SOURCE_PHP_VER}-fpm" 2>/dev/null || true
  systemctl disable "php${SOURCE_PHP_VER}-fpm" 2>/dev/null || true
  echo "    [✓] Service php${SOURCE_PHP_VER}-fpm lama berhasil dimatikan & dinonaktifkan."
  echo "    (Paket PHP ${SOURCE_PHP_VER} lama tetap tersimpan di sistem agar selalu siap untuk rollback jika dibutuhkan)."
fi

# ==========================================
# 11. INFORMASI BACKGROUND WORKER / CRON
# ==========================================
CRON_FILE="${BACKUP_DIR}/11-cron-jobs-detected.txt"
SUP_FILE="${BACKUP_DIR}/12-supervisor-workers-detected.txt"

if [ -s "$CRON_FILE" ] || [ -s "$SUP_FILE" ]; then
  echo "--------------------------------------------------"
  echo "[!] CATATAN WORKER & CRON SISTEM:"
  if [ -s "$CRON_FILE" ]; then
    echo "    - Terdapat pekerjaan Cron yang memanggil PHP (lihat ${CRON_FILE})."
  fi
  if [ -s "$SUP_FILE" ]; then
    echo "    - Terdapat worker Supervisor (lihat ${SUP_FILE})."
    echo "      Disarankan jalankan 'supervisorctl restart all' atau 'php artisan queue:restart'."
  fi
fi

cat <<EOF > "${BACKUP_DIR}/upgrade_history.env"
UPGRADE_TIMESTAMP="$(date +%Y%m%d%H%M%S)"
PREVIOUS_PHP_VER="${SOURCE_PHP_VER}"
UPGRADED_PHP_VER="${TARGET_FAMILY}"
EOF

echo "=================================================="
if [ "$ALREADY_UPGRADED" = true ]; then
  echo "[✓] PHP ${TARGET_FAMILY} ini telah berhasil terpasang dan seluruh konfigurasi telah lengkap!"
else
  echo "[✓] UPGRADE KE PHP ${TARGET_FAMILY} BERHASIL SELESAI!"
fi
echo "=================================================="
php -v
echo "--------------------------------------------------"
if [ -S "/run/php/php${TARGET_FAMILY}-fpm.sock" ]; then
  echo "Socket FPM Aktif : /run/php/php${TARGET_FAMILY}-fpm.sock"
fi
echo "Jika sewaktu-waktu ada kendala, Anda dapat menjalankan: ./rollback-php.sh"
echo "=================================================="