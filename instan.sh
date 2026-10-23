#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SCRIPT OTOMASI INSTAN RUNTIME PHP (BACKUP + UPGRADE / SYNC SEKALIGUS)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Jalankan skrip ini dengan hak akses root (sudo ./instan.sh)."
  exit 1
fi

if ! command -v php >/dev/null 2>&1; then
  echo "[-] Binary PHP CLI tidak ditemukan di PATH sistem ini."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
CURRENT_PHP_PATCH=$(php -r 'echo PHP_VERSION;')

echo "=================================================="
echo "      OTOMASI INSTAN RUNTIME PHP (ALL-IN-ONE)     "
echo "=================================================="
echo "[+] Versi PHP Saat Ini  : ${CURRENT_PHP_PATCH} (Family ${CURRENT_PHP_VER})"
echo "[+] Direktori Kerja     : ${SCRIPT_DIR}"
echo "--------------------------------------------------"

# Dapatkan target versi dari argumen pertama atau prompt interaktif
TARGET_INPUT="${1:-}"
if [ -z "$TARGET_INPUT" ]; then
  read -rp "Masukkan versi PHP target yang diinginkan (contoh: 8.3, 8.4, 8.5): " TARGET_INPUT
fi

if [ -z "$TARGET_INPUT" ]; then
  echo "[-] Versi target tidak boleh kosong! Proses dibatalkan."
  exit 1
fi

TARGET_FAMILY=$(echo "$TARGET_INPUT" | awk -F. '{print $1"."$2}')

# ------------------------------------------------------------------------------
# KASUS 1: Sistem SUDAH menggunakan versi target
# ------------------------------------------------------------------------------
if [ "$CURRENT_PHP_VER" = "$TARGET_FAMILY" ]; then
  echo ""
  echo "[i] Sistem Anda saat ini sudah menggunakan PHP ${TARGET_FAMILY}."
  echo "[+] Memeriksa apakah ada komponen yang kurang dan menyinkronkan layanan..."
  echo "--------------------------------------------------"
  
  "${SCRIPT_DIR}/upgrade-php.sh" "$TARGET_FAMILY"
  exit 0
fi

# ------------------------------------------------------------------------------
# KASUS 2: Sistem belum menggunakan versi target -> Backup lalu Upgrade
# ------------------------------------------------------------------------------
echo ""
echo "=================================================="
echo " [TAHAP 1/2] MENCADANGKAN SISTEM PHP ${CURRENT_PHP_VER} (backup-php.sh)"
echo "=================================================="
"${SCRIPT_DIR}/backup-php.sh"

echo ""
echo "=================================================="
echo " [TAHAP 2/2] MELAKUKAN UPGRADE KE PHP ${TARGET_FAMILY} (upgrade-php.sh)"
echo "=================================================="
"${SCRIPT_DIR}/upgrade-php.sh" "$TARGET_FAMILY"

echo ""
echo "=================================================="
echo "[✓] PROSES OTOMASI INSTAN SELESAI!"
echo "PHP ${TARGET_FAMILY} ini telah berhasil terpasang dan seluruh layanan aktif."
echo "=================================================="
