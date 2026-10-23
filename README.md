# PHP VPS Backup, Upgrade & Rollback Tools 🚀

Perangkat skrip otomasi untuk mencadangkan (*backup*), memperbarui (*upgrade*), dan memulihkan (*rollback*) runtime PHP secara aman di lingkungan VPS produksi (Debian & Ubuntu) yang menggunakan **Apache2**, **Nginx**, maupun **kombinasi keduanya (Reverse Proxy)**.

---

## 🌟 Fitur Utama

1. **Penyimpanan Lokal di Dalam Project (`./backups/`) & Di-Ignore Git**:
   - Seluruh hasil cadangan tersimpan rapi di dalam folder project ini di subfolder `./backups/` dan **diabaikan oleh git** melalui `.gitignore`.
   - Skrip secara otomatis menyesuaikan hak akses kepemilikan file (*ownership*) ke user asli (`$SUDO_USER`) agar Anda dapat membuka, menyalin, dan mengedit file `.txt` tanpa kendala permission root.
   - Disediakan *shortcut symlink* instan di `./backups/latest` dan `./backup-latest`.
2. **Koleksi Laporan Berkas Teks (`.txt`) Terstruktur**:
   - Seluruh detail audit konfigurasi runtime diekspor menjadi file teks bernomor rapi yang mudah dibuka, dibaca, dan diinspeksi langsung dari direktori project.
3. **Dukungan Penuh Apache2 & Nginx**:
   - Mendeteksi mode Apache (`libapache2-mod-php` atau `php-fpm` via `proxy_fcgi`).
   - Otomatis melakukan *switch* modul Apache (`a2enmod`/`a2dismod` & `a2enconf`/`a2disconf`).
   - Melakukan penggantian socket Nginx secara aman tanpa merusak VirtualHost lain (aman untuk VPS *multi-PHP*).
4. **Isolasi Konfigurasi `php.ini` per SAPI**:
   - Memisahkan nilai batas memori (`memory_limit`), upload, dan timeout antara **CLI**, **FPM**, dan **Apache2** (mencegah kebocoran `memory_limit = -1` dari CLI ke web server yang berisiko OOM).
5. **Migrasi Tuning Performa Pool FPM (`pool.d/`)**:
   - Parameter `pm.max_children`, `pm.start_servers`, dan *custom pool* lama otomatis disinkronkan ke versi baru agar server tidak mengalami *502 Bad Gateway*.
6. **Deteksi Cron, Supervisor, & Systemd**:
   - Mendeteksi worker antrean (misal Laravel Horizon / Queue) dan cron job yang mengeksekusi PHP lama.
7. **Skrip Rollback 1-Klik (`rollback-php.sh`)**:
   - Jika aplikasi Anda mengalami kendala kompatibilitas pada PHP versi baru, Anda dapat kembali ke kondisi awal dalam hitungan detik.

---

## 📂 Struktur Berkas Hasil Backup di Project

Setiap kali Anda menjalankan `./backup-php.sh`, sebuah folder baru dibuat di `./backups/php-backup-<versi>-<timestamp>/` yang berisi:

```text
upgrade-php-tools/
├── backups/                                    # (Di-ignore oleh git)
│   ├── latest -> php-backup-8.1-20261023164000
│   └── php-backup-8.1-20261023164000/
│       ├── 00-RINGKASAN-SISTEM.txt            # Ringkasan eksekutif konfigurasi sistem
│       ├── 01-installed-extensions.txt        # Daftar ekstensi PHP aktif (format APT)
│       ├── 02-php-modules-runtime.txt         # Modul aktif dari runtime CLI (php -m)
│       ├── 03-all-php-apt-packages.txt        # Semua paket PHP terpasang dari dpkg
│       ├── 04-pecl-modules.txt                # Modul PECL tambahan (jika ada)
│       ├── 05-webserver-detected.txt          # Status Apache2, Nginx, & PHP-FPM
│       ├── 06-nginx-affected-vhosts.txt       # File VHost Nginx yang merujuk PHP ini
│       ├── 07-apache-affected-vhosts.txt      # File VHost/Config Apache2 yang merujuk PHP ini
│       ├── 08-apache-modules-detected.txt     # Modul Apache2 yang aktif
│       ├── 09-fpm-pools-detected.txt          # Socket & port listen pool FPM
│       ├── 10-php-ini-key-values.txt          # Tabel perbandingan parameter php.ini
│       ├── 11-cron-jobs-detected.txt          # Cron job yang memanggil PHP
│       ├── 12-supervisor-workers-detected.txt # Worker supervisor yang memanggil PHP
│       ├── 13-systemd-php-services.txt        # Service systemd yang memanggil PHP
│       ├── php_runtime_meta.env               # Metadata mesin untuk upgrade/rollback
│       ├── source_version.txt                 # String versi sumber
│       ├── config_tree/                       # Salinan lengkap direktori /etc/php/<versi>/
│       ├── loaded_ini/                        # File php.ini asli (cli, fpm, apache2)
│       ├── fpm-pools/                         # Salinan berkas /etc/php/<versi>/fpm/pool.d/
│       ├── nginx-backup/                      # Salinan file VHost Nginx asli
│       └── apache-backup/                     # Salinan file VHost Apache2 asli
├── .gitignore                                 # Mengabaikan folder backups/ & tarball
├── backup-php.sh
├── upgrade-php.sh
├── rollback-php.sh
└── README.md
```
Selain folder di atas, skrip juga otomatis membuat arsip terkompresi `.tar.gz` di dalam folder `backups/` untuk kemudahan *download* ke lokal.

---

## 🚀 Panduan Penggunaan

### 1. Berikan Hak Eksekusi
```bash
chmod +x backup-php.sh upgrade-php.sh rollback-php.sh
```

### 2. Langkah 1: Backup Runtime Saat Ini
Jalankan skrip backup dengan hak akses `sudo`:
```bash
sudo ./backup-php.sh
```
*Skrip akan mendeteksi versi PHP yang aktif, memindai Nginx, Apache2, modul, serta cron/worker, lalu menyimpan semua file `.txt` dan konfigurasi ke `./backups/` di dalam project ini.*

Anda dapat melihat ringkasan hasil backup kapan saja:
```bash
cat backups/latest/00-RINGKASAN-SISTEM.txt
cat backups/latest/10-php-ini-key-values.txt
```

---

### 3. Langkah 2: Upgrade ke Versi Target
Jalankan skrip upgrade:
```bash
sudo ./upgrade-php.sh
```
*Alur kerja skrip:*
1. Membaca metadata cadangan dari `./backups/latest` secara otomatis.
2. Meminta input versi target (misal: `8.3` atau `8.4`).
3. Menyiapkan repositori PPA Ondřej Surý (Ubuntu) atau Sury Debian.
4. Memasang PHP CLI, FPM, atau Apache module sesuai web server yang Anda gunakan.
5. Memasang seluruh modul/ekstensi yang sebelumnya aktif secara serentak.
6. Menyinkronkan nilai `php.ini` (CLI dari CLI, FPM dari FPM, Apache dari Apache).
7. Memigrasikan tuning `pm.max_children` di FPM `pool.d/www.conf`.
8. Memperbarui socket di Nginx dan/atau Apache2 dengan pengujian sintaks (`nginx -t` & `apache2ctl configtest`).
9. Menanyakan apakah service lama ingin dihentikan untuk menghemat RAM (paket lama tetap disimpan untuk keamanan).

---

### 4. Langkah 3: Rollback (Jika Dibutuhkan)
Jika website Anda mengalami *fatal error* atau ada *library legacy* yang belum kompatibel dengan versi PHP baru, Anda dapat kembali ke versi asal secara instan:
```bash
sudo ./rollback-php.sh
```
*Skrip ini akan:*
- Mengembalikan default CLI ke versi lama via `update-alternatives`.
- Menyalakan kembali service PHP-FPM versi lama.
- Memulihkan konfigurasi Nginx dan Apache2 ke kondisi sebelum upgrade.
- Me-reload web server tanpa merusak konfigurasi lainnya.

---

## 🛡️ Checklist Keamanan Produksi

- [x] Pastikan koneksi internet VPS stabil saat mengunduh paket.
- [x] Jika menggunakan Laravel, jalankan `php artisan queue:restart` setelah upgrade selesai.
- [x] Jika menggunakan Supervisor untuk worker background, jalankan `sudo supervisorctl restart all`.
- [x] Pastikan ekstensi khusus pihak ketiga (seperti IonCube Loader) diunduh ulang untuk versi PHP target jika aplikasi Anda memerlukannya.
