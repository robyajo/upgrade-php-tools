# Aturan & Panduan Agen AI — Skript Upgrade Php Tools

## Activity Sync — Lapor Kegiatan ke Portfolio (Wajib)

Setiap selesai mengerjakan perubahan yang **dirasakan pengguna** (fitur baru,
perbaikan bug, perubahan perilaku, rilis, deploy, hapus fitur), AI WAJIB
mencatat di berkas rilis lalu mengirim satu entri kegiatan ke portfolio
sebelum menyelesaikan tugas. Refactor internal, format, komentar, dan tes yang
tak terlihat pengguna: jangan kirim.

1. **Catatan Rilis Harian**: Tulis/perbarui berkas rilis `releases/YYYY-MM-DD-*.json` memakai skill
   `release-notes` (folder `.agents/skills/activity-sync/release-notes/`):
   konsolidasi 1 berkas JSON per hari, dwibahasa (id + en), bahasa pelayanan
   publik — bebas istilah teknis/library/framework/nama berkas internal.
2. **Sinkronisasi Otomatis**: Muat skill `activity-sync` (`.agents/skills/activity-sync/SKILL.md`) dan
   ikuti alur CRUD di sana:
   - Cek proyek: `GET /api/projects?key=<KEY>`
   - Kirim isi berkas rilis `releases/*.json` apa adanya lewat `POST /api/activities` dengan menambahkan `"project": {"name": "Skript Upgrade Php Tools"}`.
   - Verifikasi hasil pengiriman lewat `GET /api/activities?slug=<slug-proyek>&limit=3`.
3. **Kunci Akses API**: Kunci `X-project` proyek ini dibaca dari berkas
   `.agents/skills/activity-sync/.ACTIVITY_PROJECT_KEYS`. Berkas kunci ini
   **TIDAK BOLEH** di-commit ke Git dan **JANGAN** ditampilkan ke user kecuali diminta.
4. **Standar Bahasa Publik**: Setiap kiriman wajib dwibahasa (`id` + `en`), ramah pengguna,
   berorientasi pada nilai/manfaat bagi pengguna (bukan implementasi kode internal).
5. **Pelaporan**: Laporkan ringkasan kegiatan yang dikirim, ID kegiatan, dan hasil verifikasinya kepada pengguna.
