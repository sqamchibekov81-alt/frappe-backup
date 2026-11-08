# frappe-backup

Frappe bench serverlaridagi barcha saytlarning (ERPNext, HRMS va custom app'lar) database va fayllarini har kecha avtomatik ravishda Hetzner Storage Box'ga yuboradi.

- Vosita: [restic](https://restic.net). Backup shifrlangan va takrorlanmaydigan qilib saqlanadi.
- Vaqt: har kecha 01:00–02:00 (Toshkent vaqti). Har server shu oraliqdagi tasodifiy daqiqada boshlaydi.
- Saqlash: oxirgi 7 kunlik, 4 haftalik va 6 oylik nusxa. Muddat `/etc/frappe-backup.env` da o'zgartiriladi.
- Xabar: backup xato bilan tugasa, tanlangan Telegram user'larga oddiy matnli xabar boradi. Muvaffaqiyatli bo'lsa, xabar yuborilmaydi.

## Tizim qanday ishlaydi

```
 server-01 ─┐                                    Hetzner Storage Box
 server-02 ─┤   har kecha 01:00–02:00            ├─ uXXXXX-sub1/restic   ← server-01 (shifrlangan)
    ...     ├──── SSH/SFTP, port 23 ───────────► ├─ uXXXXX-sub2/restic   ← server-02
 server-10 ─┘                                    ├─ ...
      │                                          └─ + Hetzner'ning kunlik snapshot'lari
      │ faqat xato bo'lsa
      ▼
 Telegram → tanlangan user'lar
```

- **Har bir server o'zi mustaqil ishlaydi.** Markaziy server yo'q.
- Har kecha systemd timer `backup.sh` ni ishga tushiradi. U ishini tugatib, natijani o'zining Storage Box'dagi papkasiga yuboradi.
- Bir server ishlamay qolsa, qolganlariga ta'sir qilmaydi.

### Bir kechada nima bo'ladi

`backup.sh` quyidagi bosqichlarni ketma-ket bajaradi. Bosqich nomlari logda va Telegram xabarida shu ko'rinishda chiqadi:

| # | Bosqich | Nima qiladi |
|---|---|---|
| 1 | `lock` | Ikkita backup bir vaqtda ishlamasligini ta'minlaydi. Oldingi backup hali tugamagan bo'lsa, xato beradi |
| 2 | `papkani tayyorlash` | `/home/frappe/backup-staging` papkasini yaratadi yoki tozalaydi |
| 3 | `bench backup` | Shu bench'dagi **barcha saytlar** uchun `bench --site all backup --with-files` ni ishga tushiradi. Har sayt uchun database (`.sql.gz`), public va private fayllar (`.tar`) va site config (`encryption_key` bilan) yaratiladi. Bitta sayt yiqilsa, butun backup xato hisoblanadi |
| 4 | `meta fayllar` | Serverni qayta qurish uchun kerak bo'ladigan kichik fayllarni oladi: `apps.txt`, common site config, nginx/supervisor sozlamalari, `bench version`, crontab |
| 5 | `restic unlock` | Oldingi uzilib qolgan backup qoldirgan eskirgan lock'ni olib tashlaydi |
| 6 | `restic backup` | Papkani shifrlab Storage Box'ga yuboradi. Faqat oldin yuborilmagan bo'laklar ketadi. Natijada yangi snapshot paydo bo'ladi |
| 7 | `restic forget` | Saqlash qoidasidan (7/4/6) tashqaridagi eski snapshot'larni ro'yxatdan chiqaradi |
| 8 | `restic prune` / `restic check` | **Faqat yakshanba kunlari.** Hech bir snapshot'ga kerak bo'lmagan ma'lumotni o'chirib joy bo'shatadi va repo butunligini tekshiradi |
| 9 | `tozalash` | Vaqtinchalik papkani bo'shatadi, serverda disk joyi band bo'lib qolmaydi |

**Biror bosqich xato bersa:**
- keyingi bosqichlar bajarilmaydi;
- vaqtinchalik papka tozalanadi;
- `TG_CHAT_IDS` dagi har bir user'ga quyidagidek xabar boradi:

```
BACKUP XATO: server-03
Bosqich: bench backup
Vaqt: 2026-11-09 01:23:45
Kod: 1

Oxirgi log:
...logning oxirgi 15 qatori...
```

### Saqlash qoidasi qanday ishlaydi (7/4/6)

Masalan 6 oydan keyin Storage Box'da har server uchun quyidagi snapshot'lar turadi:
- oxirgi 7 kunning har biri;
- oxirgi 4 haftaning har biridan bittadan (haftaning oxirgi backup'i);
- oxirgi 6 oyning har biridan bittadan (oyning oxirgi backup'i).

Jami taxminan 17 ta. Fayllar bo'laklab saqlangani uchun 17 ta snapshot fayllarni 17 marta takror saqlamaydi. Database dump'lari esa har biri o'z hajmini egallaydi.

### Serverda nima qayerda turadi

| Yo'l | Nima |
|---|---|
| `/opt/frappe-backup/` | Shu repo (skriptlar) |
| `/etc/frappe-backup.env` | Server sozlamalari, Telegram token (600, root) |
| `/root/.restic-password` | restic paroli — **password manager'da nusxasi bo'lishi shart** (600) |
| `/root/.ssh/storagebox_ed25519`, `/root/.ssh/config` | Storage Box'ga ulanish kaliti va `Host storagebox` sozlamasi |
| `/etc/systemd/system/frappe-backup.timer` / `.service` | Har kechagi ishga tushirish |
| `/var/log/frappe-backup.log` | Har bir backup'ning to'liq logi (haftalik aylanadi, 8 hafta saqlanadi) |
| `/home/frappe/backup-staging/` | Vaqtinchalik papka. Backup paytida to'ladi, keyin bo'shatiladi |

Storage Box'da har sub-account papkasida bitta `restic/` papka turadi. Uning ichidagi `config`, `data/`, `index/`, `keys/`, `snapshots/` fayllari shifrlangan. **Ularga qo'lda tegmang.** Hamma ish faqat `restic` buyruqlari orqali qilinadi.

### Skriptlarni yangilash

Repo'da o'zgarish bo'lsa, har serverda yangilang:

```bash
cd /opt/frappe-backup && git pull
bash install.sh      # faqat systemd fayllari yoki restic versiyasi o'zgargan bo'lsa
```

`backup.sh` dagi o'zgarish keyingi kechadan o'zi kuchga kiradi.

## restic qanday ishlaydi

- **Bo'laklab saqlaydi.** restic fayllarni bo'laklarga bo'ladi va Storage Box'ga faqat oldin yuborilmagan bo'laklarni jo'natadi:
  - `files.tar` (yuklangan fayllar) kundan-kunga kam o'zgaradi, shuning uchun har kecha faqat yangi fayllar ketadi;
  - database dump (`.sql.gz`) siqilgan fayl. Baza o'zgargan joydan keyingi qismi qayta ketadi, shuning uchun ish kunlarida amalda katta qismi yuboriladi. Baza o'zgarmagan bo'lsa, deyarli hech narsa ketmaydi.
- **Har kecha bitta snapshot.** Har kechagi backup alohida snapshot bo'ladi. Istalgan kunning holatini tiklash mumkin.
- **Shifrlaydi.** Hamma narsa serverning o'zida AES-256 bilan shifrlanadi, keyin yuboriladi. Hetzner yoki boshqa birov ichini o'qiy olmaydi.
- **Parol muhim.** Shifr kaliti — repo paroli (`/root/.restic-password`). **Parol yo'qolsa, backup'ni ochib bo'lmaydi.** Uni password manager'da saqlang.

## Xavfsizlik

- **Har server uchun alohida sub-account va alohida restic parol.** Bitta server buzilsa ham, boshqa serverlarning backup'ini o'qiy yoki o'chira olmaydi.
- **Storage Box avtomatik snapshot'lari.** Bular Hetzner Console'da yoqiladi. Server orqali backup o'chirib yuborilsa ham, kechagi Hetzner snapshot'i qoladi.
- **Kirish.** Ulanish faqat SSH kalit bilan, port 23 orqali. Sozlama va parol fayllari faqat root o'qiy oladi (600).

## 1. Hetzner Storage Box (bir marta)

Hetzner Console → Storage Box'da quyidagilarni qiling:

1. **Sub-account'lar.** Har server uchun bittadan sub-account oching (server-01 → `uXXXXX-sub1`, …):
   - Har birining login, host va parolini yozib oling.
   - Har birida **SSH support** ni yoqing.
   - Server Hetzner tarmog'idan tashqarida bo'lsa (Contabo va boshqalar), **External reachability** ni ham yoqing.
2. **Snapshot'lar.** Storage Box uchun **avtomatik snapshot** ni yoqing, kuniga bir marta (masalan 05:00, backup'lar tugagandan keyin).

## 2. Telegram bot (bir marta)

1. @BotFather → `/newbot` qiling va **token** oling.
2. Xabar oladigan har bir user botga `/start` yozadi. Bu shart: bot avval o'zi yozolmaydi.
3. Ularning **chat_id**'sini oling. Ikki usul bor:
   - @userinfobot'ga yozish;
   - user `/start` yozgandan keyin `https://api.telegram.org/bot<TOKEN>/getUpdates` ni ochish va `"chat":{"id":...}` ni topish.
4. Token va chat_id'lar hamma serverda bir xil bo'ladi.

## 3. Har serverga o'rnatish

Root nomidan bajariladi:

```bash
git clone <repo-manzili> /opt/frappe-backup
cp /opt/frappe-backup/frappe-backup.env.example /etc/frappe-backup.env
nano /etc/frappe-backup.env
bash /opt/frappe-backup/install.sh
```

`nano` da to'ldiriladigan maydonlar:
- `SERVER_NAME`;
- `SB_USER` va `SB_HOST`: shu serverning sub-account'i;
- `TG_BOT_TOKEN` va `TG_CHAT_IDS`.

`install.sh` quyidagilarni qiladi:
1. restic'ni o'rnatadi. Versiya hamma serverda bir xil bo'lishi uchun qotirilgan.
2. SSH kalit yaratadi va uni Storage Box'ga o'rnatadi. Bunda **sub-account paroli bir marta so'raladi**.
3. Yangi restic parol yaratib, **ekranga bir marta chiqaradi**. Uni password manager'ga saqlab, `ha` deb yozasiz.
4. Repo'ni ochadi va har kechagi systemd timer'ni yoqadi.

`install.sh` ni qayta ishga tushirsa bo'ladi: bor kalit, parol va repo'ni qayta yaratmaydi.

## 4. Tekshirish (har serverda o'rnatgandan keyin)

```bash
/opt/frappe-backup/backup.sh --test-notify      # Telegram'ga TEST xabar kelishi kerak
systemctl start frappe-backup.service           # birinchi backup (katta DB'da biroz vaqt oladi)
tail -n 30 /var/log/frappe-backup.log           # oxirida "backup muvaffaqiyatli tugadi"
/opt/frappe-backup/restore.sh                   # snapshot'lar ro'yxati
systemctl list-timers frappe-backup.timer       # keyingi ishga tushish vaqti
```

Xato xabarini ham sinab ko'ring:
1. `/etc/frappe-backup.env` da `BENCH_DIR` ni vaqtincha noto'g'ri yo'lga o'zgartiring.
2. `systemctl start frappe-backup.service` ni ishga tushiring. Telegram'ga `BACKUP XATO` kelishi kerak.
3. `BENCH_DIR` ni qaytaring.

## 5. Kundalik nazorat

Xabar faqat xato bo'lganda keladi. Agar server umuman o'chib qolsa, hech qanday xabar kelmaydi. Shuning uchun haftasiga bir marta tekshirib turing:
- Hetzner Console'da Storage Box hajmi o'syaptimi;
- yoki serverda `/opt/frappe-backup/restore.sh` bilan oxirgi snapshot sanasi.

Kerakli hajmni taxminan shunday hisoblang:
- **har server uchun:** `DB.gz hajmi × 17` (7+4+6 snapshot) + fayllar (bir marta) + har kungi yangi fayllar;
- **aniq hajm:** birinchi backup'dan keyin `restic stats` bilan ko'riladi (pastdagi buyruqlar).

## 6. Tiklash

`restore.sh` snapshot'ni papkaga chiqaradi va har sayt uchun tayyor `bench restore` buyrug'ini ko'rsatadi. **Saytning o'ziga tegmaydi.**

### 6.1 Shu serverning o'zida

```bash
/opt/frappe-backup/restore.sh                # ro'yxat
/opt/frappe-backup/restore.sh latest         # yoki snapshot id'si
```

Keyin chiqqan buyruqni frappe user'da bajaring. `<SAYT>` o'rniga sayt nomini yozing:

```bash
su - frappe
cd ~/frappe-bench
bench --site <SAYT> restore /home/frappe/restore/.../...-database.sql.gz \
    --with-public-files .../...-files.tar \
    --with-private-files .../...-private-files.tar
bench --site <SAYT> migrate
```

`bench restore` haqida:
- MariaDB root parolini so'raydi.
- **Faqat mavjud saytga ishlaydi.** Sayt yo'q bo'lsa, `Site ... does not exist!` xatosi chiqadi. Bunday holda avval `bench new-site <SAYT>` qiling.

### 6.2 Server butunlay yo'qolganda (yangi serverga)

1. Yangi serverda frappe-bench va kerakli app'larni o'rnating. Ro'yxat backup ichida: `meta/apps.txt`, `meta/bench-version.txt`.
2. Repo'ni clone qiling va `/etc/frappe-backup.env` ni **eski serverniki bilan bir xil** to'ldiring: o'sha `SERVER_NAME` va sub-account.
3. **`install.sh` dan oldin** eski restic parolni password manager'dan olib, faylga yozing:
   ```bash
   (umask 077 && echo 'ESKI-PAROL' > /root/.restic-password)
   ```
4. `bash /opt/frappe-backup/install.sh` ni ishga tushiring. Yangi SSH kalit qo'shiladi, mavjud repo esa topiladi.
5. Saytni yarating va tiklang:
   - `bench new-site <SAYT>`;
   - `restore.sh latest`;
   - chiqqan `bench restore ...` buyrug'i.
6. **encryption_key.** Yangi sayt boshqa kalit bilan yaratiladi. Eskisini qo'ymasangiz, Password maydonlari (API parollar, email parollar va h.k.) ochilmaydi. Kalit `...-site_config_backup.json` faylidagi `encryption_key` qiymatida:
   ```bash
   bench --site <SAYT> set-config encryption_key '<eski-kalit>'
   bench --site <SAYT> clear-cache
   ```
7. nginx va supervisor sozlamalari kerak bo'lsa, ular backup'ning `meta/` papkasida turadi.

### 6.3 Oyiga bir marta: tiklash sinovi

Backup faqat undan tiklab ko'rilgandagina ishonchli. Oyiga bir marta `restore.sh latest` ni bajaring va test saytga (masalan lokal kompyuterda) `bench restore` qilib ko'ring.

## 7. Password manager'da saqlanadigan narsalar (har server uchun)

- restic paroli (`/root/.restic-password` ichidagi qiymat);
- Storage Box sub-account login, host va paroli;
- Storage Box asosiy account paroli. U bitta, hammasiga kiradi va faqat Hetzner Console uchun ishlatiladi.

## 8. Muammolar

| Belgi | Nima qilish kerak |
|---|---|
| `repository is already locked` | `backup.sh` har safar eskirgan lock'larni o'zi olib tashlaydi. Takrorlansa: `restic unlock` |
| Bosqich `lock` da xato | Oldingi backup hali tugamagan: `systemctl status frappe-backup.service` |
| Bosqich `bench backup` da xato | Logni ko'ring: MariaDB ishlayaptimi (`systemctl status mariadb`), disk to'lmaganmi (`df -h`) |
| Telegram xabari kelmaydi | User botga `/start` yozganmi? `backup.sh --test-notify` natijasini o'qing |
| `Permission denied (publickey)` | Hetzner Console'da sub-account uchun SSH support va External reachability yoqilganmi? So'ng `install.sh` ni qayta ishga tushiring |

restic buyruqlarini qo'lda ishlatish uchun root'da:

```bash
set -a; source /etc/frappe-backup.env; set +a
restic snapshots
restic stats --mode raw-data
restic check
```

## Lokal sinov natijasi (2026-11-08)

Sinov Mac'dagi frappe15-bench'da (11 sayt, ~7 GB baza) restic 0.19.1 bilan o'tkazildi. Storage Box o'rniga lokal repo ishlatildi.

| Sinov | Natija |
|---|---|
| Birinchi backup (`bench --site all backup --with-files` → restic) | 11 sayt, 49 soniya, repo'ga 391 MB |
| Ikkinchi backup (baza deyarli o'zgarmagan) | 46 soniya, repo'ga atigi 16 MB qo'shildi |
| `forget` / yakshanbalik `prune` + `check` | Xatosiz, `no errors were found` |
| Ataylab xato (noto'g'ri `BENCH_DIR`) | Bosqich `bench backup` deb ko'rsatildi, ikkala chat_id'ga xabar ketdi, vaqtinchalik papka tozalandi |
| `restore.sh latest` → `bench new-site` → `bench restore` (avtodata.local) | Jadvallar soni (722), qatorlar soni va 26 ta faylning md5'i asl sayt bilan bir xil |

Mac'da sinab bo'lmagan qismlar:
- Linux'ga xos `runuser`, `flock` va systemd timer;
- `install.sh` (apt, Storage Box'ga SSH kalit o'rnatish);
- haqiqiy Storage Box'ga SFTP orqali ulanish.

Bular birinchi serverda 4-bo'limdagi tekshiruvlar bilan sinaladi.

## Fayllar

| Fayl | Vazifasi |
|---|---|
| `backup.sh` | Tungi backup: `bench --site all backup --with-files` → `restic backup` → `forget`. Yakshanba kunlari qo'shimcha `prune` + `check` |
| `install.sh` | Serverga bir martalik o'rnatish |
| `restore.sh` | Snapshot'ni papkaga chiqarish va `bench restore` buyruqlarini ko'rsatish |
| `frappe-backup.env.example` | Sozlama namunasi → `/etc/frappe-backup.env` |
| `systemd/` | Har kechagi timer va service |

Backup'ga quyidagilar kiradi:
- har sayt uchun `*-database.sql.gz`, `*-files.tar`, `*-private-files.tar` va `*-site_config_backup.json`;
- `meta/` papkasi: `apps.txt`, common site config, supervisor/nginx sozlamalari, `bench version`, frappe crontab.

Frappe'ning o'z lokal backup'lari (`sites/*/private/backups`) bu tizimga bog'liq emas va o'zgarmaydi.
# frappe-backup
# frappe-backup
