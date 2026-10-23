#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SCRIPT BACKUP LINGKUNGAN PHP (APACHE2 & NGINX READY)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Jalankan skrip ini dengan hak akses root (sudo)."
  exit 1
fi

if ! command -v php >/dev/null 2>&1; then
  echo "[-] Binary PHP CLI tidak ditemukan di PATH sistem ini."
  exit 1
fi

# ==========================================
# 0. DETEKSI DIREKTORI PROJECT & PENYIMPANAN LOKAL
# ==========================================
# Dapatkan direktori tempat skrip ini berada (akar project)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_PARENT_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# Deteksi user asli yang memanggil sudo agar kepemilikan file tetap milik user tersebut
ACTUAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"

# ==========================================
# 1. ANALISIS LOKASI FISIK & RUNTIME PHP
# ==========================================
PHP_CLI_BIN=$(command -v php)
PHP_REAL_BIN=$(readlink -f "$PHP_CLI_BIN" 2>/dev/null || realpath "$PHP_CLI_BIN" 2>/dev/null || echo "$PHP_CLI_BIN")
CURRENT_PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
CURRENT_PHP_PATCH=$(php -r 'echo PHP_VERSION;')

LOADED_INI=$(php -r 'echo php_ini_loaded_file() ?: "";')
ADDITIONAL_INI_FILES=$(php -r 'echo php_ini_scanned_files() ?: "";')
EXTENSION_DIR=$(php -r 'echo ini_get("extension_dir") ?: "";')

if [ -n "$LOADED_INI" ]; then
  PHP_CONF_BASE=$(echo "$LOADED_INI" | sed -E 's#/(cli/|fpm/|apache2/|cgi/)?php\.ini$##')
  [ -z "$PHP_CONF_BASE" ] && PHP_CONF_BASE=$(dirname "$LOADED_INI")
else
  PHP_CONF_BASE="/etc/php/${CURRENT_PHP_VER}"
fi

# Target folder backup di dalam project
BACKUP_DIR="${BACKUP_PARENT_DIR}/php-backup-${CURRENT_PHP_VER}-${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

echo "=================================================="
echo "      ANALISIS RUNTIME PHP & PERSIAPAN BACKUP     "
echo "=================================================="
echo "[+] Lokasi Project          : ${SCRIPT_DIR}"
echo "[+] Folder Induk Backup     : ${BACKUP_PARENT_DIR}"
echo "[+] Folder Cadangan Sesi Ini: ${BACKUP_DIR}"
echo "[+] Pemilik Berkas (User)   : ${ACTUAL_USER}"
echo "[+] Versi PHP Saat Ini      : ${CURRENT_PHP_PATCH} (Family: ${CURRENT_PHP_VER})"
echo "[+] PHP CLI Binary          : ${PHP_CLI_BIN} -> ${PHP_REAL_BIN}"
echo "[+] Loaded php.ini (CLI)    : ${LOADED_INI:-"Default compiled-in"}"
echo "[+] Base Direktori Config   : ${PHP_CONF_BASE}"
echo "--------------------------------------------------"

# ==========================================
# 2. DETEKSI STATUS WEB SERVER & SAPI
# ==========================================
HAS_APACHE=false
HAS_NGINX=false
APACHE_MODE="none"
FPM_SOCKET_PATH=""
HAS_FPM=false

# Deteksi Nginx
if command -v nginx >/dev/null 2>&1 || [ -d "/etc/nginx" ]; then
  HAS_NGINX=true
fi

# Deteksi Apache2
if command -v apache2 >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1 || [ -d "/etc/apache2" ]; then
  HAS_APACHE=true
fi

# Deteksi PHP-FPM
if systemctl is-active --quiet "php${CURRENT_PHP_VER}-fpm" 2>/dev/null || [ -d "/etc/php/${CURRENT_PHP_VER}/fpm" ]; then
  HAS_FPM=true
  if [ -S "/run/php/php${CURRENT_PHP_VER}-fpm.sock" ]; then
    FPM_SOCKET_PATH="/run/php/php${CURRENT_PHP_VER}-fpm.sock"
  elif [ -S "/var/run/php/php${CURRENT_PHP_VER}-fpm.sock" ]; then
    FPM_SOCKET_PATH="/var/run/php/php${CURRENT_PHP_VER}-fpm.sock"
  fi
fi

# Deteksi Mode Apache2 (mod_php vs php-fpm proxy)
if [ "$HAS_APACHE" = true ]; then
  if [ -d "/etc/apache2/mods-enabled" ]; then
    if ls /etc/apache2/mods-enabled/php*.load >/dev/null 2>&1; then
      APACHE_MODE="mod_php"
    elif [ -f "/etc/apache2/mods-enabled/proxy_fcgi.load" ] || ls /etc/apache2/conf-enabled/php*-fpm.conf >/dev/null 2>&1; then
      APACHE_MODE="fpm_proxy"
    else
      APACHE_MODE="custom_or_fpm"
    fi
  fi
fi

# ==========================================
# 3. BACKUP FILE & FOLDER KONFIGURASI LENGKAP
# ==========================================
echo "[+] Mencadangkan pohon konfigurasi PHP..."

# 3.1 Simpan seluruh folder direktori konfigurasi PHP jika ada
if [ -d "$PHP_CONF_BASE" ]; then
  mkdir -p "${BACKUP_DIR}/config_tree"
  cp -a "$PHP_CONF_BASE" "${BACKUP_DIR}/config_tree/"
  echo "    - Direktori ${PHP_CONF_BASE} berhasil dicadangkan."
fi

# 3.2 Pisahkan file php.ini spesifik per SAPI (CLI, FPM, Apache2)
mkdir -p "${BACKUP_DIR}/loaded_ini"

CLI_INI="/etc/php/${CURRENT_PHP_VER}/cli/php.ini"
[ ! -f "$CLI_INI" ] && [ -n "$LOADED_INI" ] && CLI_INI="$LOADED_INI"
if [ -f "$CLI_INI" ]; then
  cp -a "$CLI_INI" "${BACKUP_DIR}/loaded_ini/cli_php.ini"
  echo "    - File CLI php.ini berhasil dicadangkan."
fi

FPM_INI="/etc/php/${CURRENT_PHP_VER}/fpm/php.ini"
if [ -f "$FPM_INI" ]; then
  cp -a "$FPM_INI" "${BACKUP_DIR}/loaded_ini/fpm_php.ini"
  echo "    - File FPM php.ini berhasil dicadangkan."
fi

APACHE_INI="/etc/php/${CURRENT_PHP_VER}/apache2/php.ini"
if [ -f "$APACHE_INI" ]; then
  cp -a "$APACHE_INI" "${BACKUP_DIR}/loaded_ini/apache2_php.ini"
  echo "    - File Apache2 php.ini berhasil dicadangkan."
fi

# 3.3 Backup pool konfigurasi FPM (pool.d)
if [ -d "/etc/php/${CURRENT_PHP_VER}/fpm/pool.d" ]; then
  mkdir -p "${BACKUP_DIR}/fpm-pools"
  cp -a "/etc/php/${CURRENT_PHP_VER}/fpm/pool.d/." "${BACKUP_DIR}/fpm-pools/"
  echo "    - Folder FPM pool.d berhasil diamankan."
fi

# 3.4 Backup berkas .ini tambahan (conf.d)
if [ -n "$ADDITIONAL_INI_FILES" ]; then
  mkdir -p "${BACKUP_DIR}/additional_ini"
  IFS=',' read -ra INI_ARRAY <<< "$ADDITIONAL_INI_FILES"
  for ini_file in "${INI_ARRAY[@]}"; do
    ini_file=$(echo "$ini_file" | xargs)
    if [ -f "$ini_file" ]; then
      cp --parents "$ini_file" "${BACKUP_DIR}/additional_ini/" 2>/dev/null || cp "$ini_file" "${BACKUP_DIR}/additional_ini/"
    fi
  done
  echo "    - ${#INI_ARRAY[@]} file konfigurasi tambahan (conf.d) berhasil disalin."
fi

# ==========================================
# 4. EKSPOR FILE-FILE INFORMASI TEKS (.TXT)
# ==========================================
echo "[+] Menghasilkan file-file ringkasan teks (.txt)..."

# 4.1 Ekstrak Modul Runtime & APT
php -m | sort -u > "${BACKUP_DIR}/02-php-modules-runtime.txt"

if command -v dpkg >/dev/null 2>&1; then
  dpkg -l | grep -E "^ii  php[0-9.]*-" | awk '{print $2}' > "${BACKUP_DIR}/03-all-php-apt-packages.txt" || true
  grep -E "^php${CURRENT_PHP_VER}-" "${BACKUP_DIR}/03-all-php-apt-packages.txt" | sed "s/php${CURRENT_PHP_VER}-//" > "${BACKUP_DIR}/01-installed-extensions.txt" || true
else
  touch "${BACKUP_DIR}/03-all-php-apt-packages.txt"
  touch "${BACKUP_DIR}/01-installed-extensions.txt"
fi

cp "${BACKUP_DIR}/01-installed-extensions.txt" "${BACKUP_DIR}/installed-extensions.txt"
cp "${BACKUP_DIR}/02-php-modules-runtime.txt" "${BACKUP_DIR}/php-modules-runtime.txt"

# 4.2 Ekstrak PECL modules
if command -v pecl >/dev/null 2>&1; then
  pecl list > "${BACKUP_DIR}/04-pecl-modules.txt" 2>&1 || true
else
  echo "PECL tidak terpasang di sistem ini." > "${BACKUP_DIR}/04-pecl-modules.txt"
fi

# 4.3 Webserver Detected
cat <<EOF > "${BACKUP_DIR}/05-webserver-detected.txt"
HAS_APACHE=${HAS_APACHE}
HAS_NGINX=${HAS_NGINX}
HAS_FPM=${HAS_FPM}
APACHE_MODE=${APACHE_MODE}
FPM_SOCKET_PATH=${FPM_SOCKET_PATH}
EOF

# 4.4 Periksa Nginx VHosts
touch "${BACKUP_DIR}/06-nginx-affected-vhosts.txt"
if [ "$HAS_NGINX" = true ] && [ -d "/etc/nginx" ]; then
  mkdir -p "${BACKUP_DIR}/nginx-backup"
  grep -rEl "(php.*${CURRENT_PHP_VER}.*fpm\.sock|php${CURRENT_PHP_VER})" /etc/nginx/sites-available/ /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ /etc/nginx/snippets/ /etc/nginx/nginx.conf 2>/dev/null | sort -u > "${BACKUP_DIR}/06-nginx-affected-vhosts.txt" || true
  
  if [ -s "${BACKUP_DIR}/06-nginx-affected-vhosts.txt" ]; then
    while IFS= read -r conf_file; do
      if [ -f "$conf_file" ]; then
        cp --parents "$conf_file" "${BACKUP_DIR}/nginx-backup/" 2>/dev/null || cp "$conf_file" "${BACKUP_DIR}/nginx-backup/"
      fi
    done < "${BACKUP_DIR}/06-nginx-affected-vhosts.txt"
    echo "    - $(wc -l < "${BACKUP_DIR}/06-nginx-affected-vhosts.txt") file konfigurasi Nginx berhasil dicadangkan."
  fi
fi
cp "${BACKUP_DIR}/06-nginx-affected-vhosts.txt" "${BACKUP_DIR}/nginx-affected-vhosts.txt"

# 4.5 Periksa Apache2 VHosts & Mods
touch "${BACKUP_DIR}/07-apache-affected-vhosts.txt"
touch "${BACKUP_DIR}/08-apache-modules-detected.txt"
if [ "$HAS_APACHE" = true ] && [ -d "/etc/apache2" ]; then
  mkdir -p "${BACKUP_DIR}/apache-backup"
  
  if command -v apache2ctl >/dev/null 2>&1; then
    apache2ctl -M > "${BACKUP_DIR}/08-apache-modules-detected.txt" 2>&1 || true
  elif command -v apachectl >/dev/null 2>&1; then
    apachectl -M > "${BACKUP_DIR}/08-apache-modules-detected.txt" 2>&1 || true
  fi

  grep -rEl "(php.*${CURRENT_PHP_VER}.*fpm\.sock|php${CURRENT_PHP_VER})" /etc/apache2/sites-available/ /etc/apache2/sites-enabled/ /etc/apache2/conf-available/ /etc/apache2/conf-enabled/ /etc/apache2/mods-enabled/ 2>/dev/null | sort -u > "${BACKUP_DIR}/07-apache-affected-vhosts.txt" || true
  
  if [ -s "${BACKUP_DIR}/07-apache-affected-vhosts.txt" ]; then
    while IFS= read -r conf_file; do
      if [ -f "$conf_file" ]; then
        cp --parents "$conf_file" "${BACKUP_DIR}/apache-backup/" 2>/dev/null || cp "$conf_file" "${BACKUP_DIR}/apache-backup/"
      fi
    done < "${BACKUP_DIR}/07-apache-affected-vhosts.txt"
    echo "    - $(wc -l < "${BACKUP_DIR}/07-apache-affected-vhosts.txt") file konfigurasi Apache2 berhasil dicadangkan."
  fi
fi

# 4.6 Periksa Pool FPM yang Terdeteksi
touch "${BACKUP_DIR}/09-fpm-pools-detected.txt"
if [ -d "${BACKUP_DIR}/fpm-pools" ]; then
  grep -E "^[[:space:]]*listen[[:space:]]*=" "${BACKUP_DIR}/fpm-pools/"*.conf 2>/dev/null > "${BACKUP_DIR}/09-fpm-pools-detected.txt" || true
fi

# 4.7 Ringkasan Nilai Kunci php.ini
extract_param_from_file() {
  local param="$1"
  local file="$2"
  if [ -f "$file" ]; then
    grep -E "^[[:space:]]*${param}[[:space:]]*=" "$file" | tail -n 1 | awk -F'=' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//' || echo "default"
  else
    echo "N/A"
  fi
}

cat <<EOF > "${BACKUP_DIR}/10-php-ini-key-values.txt"
==================================================================
RINGKASAN PARAMETER INTI PHP.INI (PHP ${CURRENT_PHP_VER})
==================================================================
Parameter                 | CLI                 | FPM                 | Apache2
--------------------------|---------------------|---------------------|---------------------
memory_limit              | $(extract_param_from_file "memory_limit" "${BACKUP_DIR}/loaded_ini/cli_php.ini") | $(extract_param_from_file "memory_limit" "${BACKUP_DIR}/loaded_ini/fpm_php.ini") | $(extract_param_from_file "memory_limit" "${BACKUP_DIR}/loaded_ini/apache2_php.ini")
max_execution_time        | $(extract_param_from_file "max_execution_time" "${BACKUP_DIR}/loaded_ini/cli_php.ini") | $(extract_param_from_file "max_execution_time" "${BACKUP_DIR}/loaded_ini/fpm_php.ini") | $(extract_param_from_file "max_execution_time" "${BACKUP_DIR}/loaded_ini/apache2_php.ini")
upload_max_filesize       | $(extract_param_from_file "upload_max_filesize" "${BACKUP_DIR}/loaded_ini/cli_php.ini") | $(extract_param_from_file "upload_max_filesize" "${BACKUP_DIR}/loaded_ini/fpm_php.ini") | $(extract_param_from_file "upload_max_filesize" "${BACKUP_DIR}/loaded_ini/apache2_php.ini")
post_max_size             | $(extract_param_from_file "post_max_size" "${BACKUP_DIR}/loaded_ini/cli_php.ini") | $(extract_param_from_file "post_max_size" "${BACKUP_DIR}/loaded_ini/fpm_php.ini") | $(extract_param_from_file "post_max_size" "${BACKUP_DIR}/loaded_ini/apache2_php.ini")
max_input_vars            | $(extract_param_from_file "max_input_vars" "${BACKUP_DIR}/loaded_ini/cli_php.ini") | $(extract_param_from_file "max_input_vars" "${BACKUP_DIR}/loaded_ini/fpm_php.ini") | $(extract_param_from_file "max_input_vars" "${BACKUP_DIR}/loaded_ini/apache2_php.ini")
date.timezone             | $(extract_param_from_file "date.timezone" "${BACKUP_DIR}/loaded_ini/cli_php.ini") | $(extract_param_from_file "date.timezone" "${BACKUP_DIR}/loaded_ini/fpm_php.ini") | $(extract_param_from_file "date.timezone" "${BACKUP_DIR}/loaded_ini/apache2_php.ini")
EOF

# 4.8 Deteksi Cron, Supervisor, & Systemd Services
touch "${BACKUP_DIR}/11-cron-jobs-detected.txt"
grep -rnE "(php|php${CURRENT_PHP_VER})" /etc/cron* /var/spool/cron/crontabs 2>/dev/null > "${BACKUP_DIR}/11-cron-jobs-detected.txt" || true

touch "${BACKUP_DIR}/12-supervisor-workers-detected.txt"
if [ -d "/etc/supervisor" ]; then
  grep -rnE "(php|php${CURRENT_PHP_VER})" /etc/supervisor/ 2>/dev/null > "${BACKUP_DIR}/12-supervisor-workers-detected.txt" || true
fi

touch "${BACKUP_DIR}/13-systemd-php-services.txt"
if [ -d "/etc/systemd/system" ]; then
  grep -rnE "ExecStart=.*(php|php${CURRENT_PHP_VER})" /etc/systemd/system/ 2>/dev/null > "${BACKUP_DIR}/13-systemd-php-services.txt" || true
fi

# 4.9 Ringkasan Eksekutif Sistem (00-RINGKASAN-SISTEM.txt)
cat <<EOF > "${BACKUP_DIR}/00-RINGKASAN-SISTEM.txt"
==================================================================
                 RINGKASAN HASIL CADANGAN PHP VPS
==================================================================
Waktu Pencadangan     : $(date '+%Y-%m-%d %H:%M:%S')
Lokasi Project        : ${SCRIPT_DIR}
Direktori Cadangan    : ${BACKUP_DIR}

1. RUNTIME PHP
   - Versi Terpasang  : ${CURRENT_PHP_PATCH} (Family: ${CURRENT_PHP_VER})
   - Binary CLI       : ${PHP_CLI_BIN}
   - Binary Asli      : ${PHP_REAL_BIN}
   - Base Direktori   : ${PHP_CONF_BASE}
   - Jumlah Modul     : $(wc -l < "${BACKUP_DIR}/02-php-modules-runtime.txt") modul aktif
   - Jumlah Paket APT : $(wc -l < "${BACKUP_DIR}/01-installed-extensions.txt") ekstensi terdeteksi

2. STATUS WEB SERVER
   - Apache2          : $( [ "$HAS_APACHE" = true ] && echo "Terdeteksi (Mode: ${APACHE_MODE})" || echo "Tidak terdeteksi" )
   - Nginx            : $( [ "$HAS_NGINX" = true ] && echo "Terdeteksi" || echo "Tidak terdeteksi" )
   - PHP-FPM          : $( [ "$HAS_FPM" = true ] && echo "Aktif (${FPM_SOCKET_PATH:-"Socket default"})" || echo "Tidak aktif" )

3. DAFTAR FILE TEKS (.TXT) DI FOLDER INI
   - 00-RINGKASAN-SISTEM.txt           : Ringkasan umum sistem (file ini)
   - 01-installed-extensions.txt       : Daftar nama ekstensi PHP (format APT)
   - 02-php-modules-runtime.txt        : Daftar modul aktif dari runtime (php -m)
   - 03-all-php-apt-packages.txt       : Seluruh paket PHP dari manajer dpkg
   - 04-pecl-modules.txt               : Modul PECL tambahan (jika ada)
   - 05-webserver-detected.txt         : Konfigurasi status web server
   - 06-nginx-affected-vhosts.txt      : VHost Nginx yang merujuk PHP ini
   - 07-apache-affected-vhosts.txt     : VHost/Config Apache2 yang merujuk PHP ini
   - 08-apache-modules-detected.txt    : Modul Apache yang aktif saat ini
   - 09-fpm-pools-detected.txt         : Konfigurasi listen pool FPM
   - 10-php-ini-key-values.txt         : Perbandingan parameter inti php.ini
   - 11-cron-jobs-detected.txt         : Pekerjaan Cron yang memanggil PHP
   - 12-supervisor-workers-detected.txt: Background worker supervisor
   - 13-systemd-php-services.txt       : Layanan sistem systemd terkait PHP
==================================================================
EOF

# ==========================================
# 5. SIMPAN METADATA UNTUK UPGRADE & ROLLBACK
# ==========================================
cat <<EOF > "${BACKUP_DIR}/php_runtime_meta.env"
SOURCE_PHP_VER="${CURRENT_PHP_VER}"
SOURCE_PHP_PATCH="${CURRENT_PHP_PATCH}"
SOURCE_PHP_CLI_BIN="${PHP_CLI_BIN}"
SOURCE_PHP_REAL_BIN="${PHP_REAL_BIN}"
SOURCE_LOADED_INI="${LOADED_INI}"
SOURCE_CONF_BASE="${PHP_CONF_BASE}"
SOURCE_EXTENSION_DIR="${EXTENSION_DIR}"
BACKUP_TIMESTAMP="${TIMESTAMP}"
SCRIPT_DIR="${SCRIPT_DIR}"
BACKUP_DIR="${BACKUP_DIR}"
ACTUAL_USER="${ACTUAL_USER}"
HAS_APACHE="${HAS_APACHE}"
HAS_NGINX="${HAS_NGINX}"
HAS_FPM="${HAS_FPM}"
APACHE_MODE="${APACHE_MODE}"
FPM_SOCKET_PATH="${FPM_SOCKET_PATH}"
EOF

echo "${CURRENT_PHP_VER}" > "${BACKUP_DIR}/source_version.txt"

# ==========================================
# 6. BUAT TARBALL (.TAR.GZ) & KELOLA SYMLINK LOKAL
# ==========================================
echo "[+] Mengompres arsip cadangan ke folder project..."
tar -czf "${BACKUP_DIR}.tar.gz" -C "${BACKUP_PARENT_DIR}" "$(basename "${BACKUP_DIR}")" 2>/dev/null || true

# Buat symlink latest di folder backups lokal dan di root project
ln -sfn "${BACKUP_DIR}" "${BACKUP_PARENT_DIR}/latest"
ln -sfn "${BACKUP_DIR}" "${SCRIPT_DIR}/backup-latest"

# Pointer sekunder di /root untuk kemudahan sistem
ln -sfn "${BACKUP_DIR}" /root/php-backup-latest 2>/dev/null || true

# ==========================================
# 7. SESUAIKAN KEPEMILIKAN FILE KE USER LOKAL
# ==========================================
if [ "$ACTUAL_USER" != "root" ]; then
  ACTUAL_GROUP=$(id -gn "$ACTUAL_USER" 2>/dev/null || echo "$ACTUAL_USER")
  echo "[+] Menyelaraskan hak akses file ke user ${ACTUAL_USER}:${ACTUAL_GROUP}..."
  chown -R "${ACTUAL_USER}:${ACTUAL_GROUP}" "${BACKUP_PARENT_DIR}" 2>/dev/null || true
  chown -h "${ACTUAL_USER}:${ACTUAL_GROUP}" "${SCRIPT_DIR}/backup-latest" 2>/dev/null || true
  chown "${ACTUAL_USER}:${ACTUAL_GROUP}" "${BACKUP_DIR}.tar.gz" 2>/dev/null || true
fi

echo "=================================================="
echo "[✓] Cadangan PHP berhasil diamankan di dalam project!"
echo "=================================================="
echo "[✓] Folder Cadangan : ${BACKUP_DIR}"
echo "[✓] Arsip Tarball   : ${BACKUP_DIR}.tar.gz"
echo "[✓] Shortcut Cepat  : ${BACKUP_PARENT_DIR}/latest"
echo "=================================================="
echo "Anda dapat melihat semua ringkasan teks di folder:"
echo "cat ${BACKUP_DIR}/00-RINGKASAN-SISTEM.txt"
echo "=================================================="