<div dir="rtl">

# PostgreSQL 17: داده‌ی تست حجیم، استقرار Single و کلاستر HA، و DR

این پروژه سه بخش دارد:

1. **`script.sh`**: یک دیتابیس تست واقعی‌نما می‌سازد: **۱۰۰ جدول × ۳۰ ستون × ۱۰ میلیون ردیف (در مجموع) ≈ ۱۵ گیگ**.
2. **دو استقرار با docker compose در سطح production:**
   - `single/docker-compose.yml`: یک نود PostgreSQL 17
   - `cluster/docker-compose.yml`: کلاستر سه‌نودی با **Patroni + etcd + HAProxy** و failover خودکار
3. **`dr.sh`**: بکاپ و بازیابی با **pgBackRest**، شامل بازیابی تا یک لحظه‌ی مشخص (PITR)، تمرین DR، بازسازی کامل کلاستر و تست failover.
4. **`monitoring/`**: پایش نود single با **postgres_exporter + pgbackrest_exporter + Prometheus + Grafana**، به همراه ۱۴ قانون هشدار (بخش ۵-۱).

همه‌ی سناریوهای این سند واقعاً روی همین فایل‌ها اجرا و تأیید شده‌اند. نتیجه‌ها در [بخش ۹](#results) آمده است.

---

## ۱. ساختار پروژه

<div dir="ltr">

```
postgresql-data-HA-DR/
├── script.sh                  # test data generator (generate | verify | estimate | drop)
├── dr.sh                      # backup / restore / PITR / failover operations
├── lib.sh                     # shared helpers (.env, health waits, leader lookup)
├── .env.example               # passwords template (.env is generated on first start)
├── image/Dockerfile           # postgres:17-bookworm + pgBackRest + Patroni
├── single/
│   ├── docker-compose.yml     # single node
│   ├── up.sh / down.sh
│   └── conf/                  # postgresql.conf, pg_hba.conf, pgbackrest.conf, initdb.sh
├── cluster/
│   ├── docker-compose.yml     # etcd x3 + Patroni/PostgreSQL x3 + HAProxy
│   ├── up.sh / down.sh
│   ├── patroni/               # Dockerfile, patroni.yml.tmpl, entrypoint, bootstrap scripts
│   ├── haproxy/haproxy.cfg
│   └── pgbackrest/pgbackrest.conf
└── monitoring/                # for the single node
    ├── docker-compose.yml     # postgres_exporter, pgbackrest_exporter, Prometheus, Grafana
    ├── up.sh / down.sh
    ├── pgbackrest-exporter/   # Dockerfile: exporter binary on top of pgha/postgres:17
    ├── prometheus/            # prometheus.yml, alerts.yml, alerts_test.yml (promtool)
    └── grafana/               # provisioned datasource + dashboards/postgresql.json
```

</div>

## ۲. پیش‌نیازها

| مورد | حداقل |
|---|---|
| Docker و Docker Compose (`docker compose` یا `docker-compose`) | Docker 24 به بالا |
| دیسک آزاد | single: حدود ۴۰ گیگ (۱۵ گیگ داده، WAL، بکاپ و آرشیو). کلاستر: حدود ۸۰ گیگ (سه کپی از داده، آرشیو و بکاپ) |
| RAM | single: ۸ گیگ (limit تنظیم‌شده). کلاستر: ۳ × ۴ گیگ |
| CPU | هرچه بیشتر، تولید داده سریع‌تر (موازی) |
| اینترنت در اولین build | برای `apt` (مخزن رسمی PostgreSQL) و pull کردن imageها |

> ⚠️ **WSL2 / Docker Desktop:** دستور `df /` داخل WSL یک دیسک مجازی حدود ۱ ترابایتی نشان می‌دهد. ولی داده واقعاً در فایل `ext4.vhdx` روی درایو ویندوز (معمولاً C:) نوشته می‌شود. این فایل **بزرگ می‌شود ولی خودبه‌خود کوچک نمی‌شود.** اجرای همزمان single و کلاستر با ۱۵ گیگ داده، به همراه WAL، آرشیو، بکاپ و restore-test، حدود **۱۴۰ گیگ** فضا لازم دارد و در تست ما درایو C: را پر کرد. برای همین `up.sh`، `script.sh generate` و `dr.sh restore-test` قبل از شروع، فضای آزاد را **روی همان درایو ویندوز** چک می‌کنند و در صورت کمبود متوقف می‌شوند. اگر vhdx روی درایو دیگری است، `WSL_VHDX_DRIVE=/mnt/d` را تنظیم کنید. برای رد کردن چک: `SKIP_DISK_CHECK=1`. بعد از پاک کردن داده، برای کوچک کردن فایل vhdx این مراحل را انجام دهید: `wsl --shutdown` و سپس در PowerShell با دسترسی ادمین `Optimize-VHD -Path <ext4.vhdx> -Mode Full` (یا `wsl --manage <distro> --set-sparse true`).

نصب `psql` روی ماشین **لازم نیست**. اگر نصب نباشد، `script.sh` خودش psql داخل image را اجرا می‌کند.

---

## ۳. شروع سریع

<div dir="ltr">

```bash
cd /home/soroush/infra/postgresql-data-HA-DR

# --- single node --------------------------------------------------------
./single/up.sh                    # build + start + pgBackRest stanza, prints the logins
./script.sh generate              # 100 tables / 30 columns / 10M rows / ~15 GB
./dr.sh single backup full        # first backup

# --- 3-node cluster -----------------------------------------------------
./cluster/up.sh
./script.sh generate --target cluster
./dr.sh cluster backup full
```

</div>

در اولین اجرا، فایل `.env` با رمزهای تصادفی ساخته می‌شود و هر دو استقرار از آن استفاده می‌کنند. رمزها را این‌طور ببینید:

<div dir="ltr">

```bash
cat .env
```

</div>

| کاربر | کاربرد |
|---|---|
| `postgres` | superuser، رمز `POSTGRES_SUPERUSER_PASSWORD` |
| `app` | کاربر برنامه و مالک دیتابیس `appdb`، رمز `APP_PASSWORD`. `script.sh` با همین کاربر کار می‌کند |
| `replicator` | فقط replication، رمز `POSTGRES_REPLICATION_PASSWORD` |

| آدرس | چیست |
|---|---|
| `127.0.0.1:5432` | single |
| `127.0.0.1:6432` | کلاستر، **خواندن و نوشتن** (HAProxy به سمت primary فعلی) |
| `127.0.0.1:6433` | کلاستر، **فقط خواندن** (HAProxy به سمت replicaها، round-robin) |
| `http://127.0.0.1:7000` | صفحه‌ی وضعیت HAProxy |

> پورت‌ها فقط روی `127.0.0.1` باز می‌شوند. برای دسترسی از شبکه، `BIND_ADDRESS=0.0.0.0` را در `.env` تنظیم کنید (و فایروال را فراموش نکنید).
>
> single و کلاستر پورت‌های جدا دارند و می‌توانند همزمان اجرا شوند.

---

## ۴. `script.sh`: ساخت دیتابیس ۱۵ گیگی

### ۴-۱. چه چیزی ساخته می‌شود

- اسکیما `bench` با جدول‌های `bench.t001` تا `bench.t100`.
- هر جدول **۳۰ ستون** و **۱۰۰٬۰۰۰ ردیف** دارد، یعنی در مجموع **۱۰٬۰۰۰٬۰۰۰ ردیف**.
- داده‌ها پرحجم ولی **متعادل** هستند: همه‌ی جدول‌ها هم‌اندازه‌اند (حدود ۱۵۰ مگ برای هر جدول) و هر ردیف حدود ۱.۶KB است. طول متن‌ها برای هر ردیف ±۲۵٪ تصادفی است، پس داده یکنواخت و مصنوعی به نظر نمی‌رسد.

| گروه | ستون‌ها |
|---|---|
| کلید | `id` (bigint PK)، `uid` (uuid)، `customer_code` |
| اشخاص | `first_name`، `last_name`، `email`، `phone`، `birth_date` |
| مکان | `country`، `city`، `address`، `postal_code`، `ip_address` (inet) |
| عددی | `status`، `quantity`، `unit_price`، `total_amount` (numeric)، `discount_rate` (real)، `score` (double) |
| وضعیت و زمان | `category`، `is_active`، `created_at`، `updated_at` (timestamptz)، `version` |
| ساختاریافته | `tags` (text[])، `attributes` (jsonb) |
| حجیم | `description` و `notes` (متن کلمه‌ای)، `payload` (hex تصادفی)، `checksum` |

ایندکس‌ها: کلید اصلی (PK) به اضافه‌ی ایندکس روی `created_at` و روی `customer_code` در هر جدول.

### ۴-۲. چطور حجم دقیقاً حدود ۱۵ گیگ می‌شود؟

حجم هر ردیف روی دیسک فقط به طول متن بستگی ندارد. هدر ردیف، تعداد ردیف‌هایی که در هر صفحه‌ی ۸KB جا می‌شود و ایندکس‌ها هم اثر دارند. برای همین اسکریپت قبل از شروع **calibration** انجام می‌دهد: روی همان سرور یک جدول نمونه با ۵۰۰۰ ردیف می‌سازد، حجم واقعی هر ردیف را اندازه می‌گیرد و طول متن‌ها را با جستجوی دودویی (bisection) طوری تنظیم می‌کند که هر ردیف حدود `15 GiB / 10M = 1610` بایت شود.

ستون‌های متنی `STORAGE EXTERNAL` دارند (بدون فشرده‌سازی)، تا حجم قابل پیش‌بینی بماند.

### ۴-۳. دستورها

<div dir="ltr">

```bash
./script.sh generate                       # single (127.0.0.1:5432)
./script.sh generate --target cluster      # cluster, through HAProxy :6432
./script.sh verify                         # exact row count per table, 30 columns, sizes
./script.sh verify --port 6433             # same check on a cluster REPLICA (replication proof)
./script.sh estimate                       # calibrate and print the plan only
./script.sh drop                           # DROP SCHEMA bench CASCADE
```

</div>

| گزینه | پیش‌فرض | توضیح |
|---|---|---|
| `--tables` | 100 | تعداد جدول‌ها |
| `--rows` | 10000000 | **مجموع** ردیف‌ها، که بین جدول‌ها تقسیم می‌شود |
| `--size-gb` | 15 | حجم هدف (عدد اعشاری هم قبول می‌کند، مثلاً `0.5`) |
| `--jobs` | نصف هسته‌ها، حداکثر ۸ | تعداد loaderهای موازی |
| `--chunk` | 25000 | تعداد ردیف در هر تراکنش INSERT (واحد resume) |
| `--target` | single | مقصد پیش‌فرض: `single` (پورت ۵۴۳۲) یا `cluster` (پورت ۶۴۳۲) |
| `--host` / `--port` / `--user` / `--password` / `--db` | از `.env` | اتصال به هر PostgreSQL دلخواه |
| `--schema` | bench | نام اسکیما |
| `--force` | | اسکیمای موجود را پاک می‌کند و از اول می‌سازد |

مثال برای یک تست کوچک و سریع:

<div dir="ltr">

```bash
./script.sh generate --tables 10 --rows 100000 --size-gb 0.15 --force
```

</div>

### ۴-۴. مراحل اجرا و قابلیت ادامه (resume)

1. اتصال را چک می‌کند. اگر مقصد replica باشد، کار را متوقف می‌کند.
2. توابع کمکی و جدول‌های `bench.load_log` و `bench.load_meta` را می‌سازد.
3. calibration را اجرا می‌کند و نتیجه را در `load_meta` ذخیره می‌کند.
4. ۱۰۰ جدول را می‌سازد.
5. بارگذاری: هر chunk یک `INSERT ... SELECT generate_series` است که **همراه ثبتش در `load_log` در یک تراکنش** اجرا می‌شود. chunkها با `xargs -P` موازی اجرا می‌شوند. `synchronous_commit=off` فقط برای همین تراکنش‌ها تنظیم می‌شود.
6. ایندکس‌های ثانویه و `VACUUM ANALYZE` (موازی).
7. `verify`.

اگر اجرا قطع شود (Ctrl+C، ری‌استارت یا قطعی)، کافی است **همان دستور را دوباره اجرا کنید.** chunkهای تمام‌شده دوباره بارگذاری نمی‌شوند و هیچ ردیفی تکراری نمی‌شود.

---

## ۵. استقرار Single (`single/docker-compose.yml`)

ویژگی‌های production:

| موضوع | تنظیم |
|---|---|
| image | `postgres:17-bookworm` رسمی به همراه pgBackRest (از مخزن PGDG) |
| initdb | `--data-checksums`، UTF8، و locale از نوع **builtin** (`C.UTF-8`، که در PG17 جدید است: سریع و بدون وابستگی به نسخه‌ی glibc) |
| امنیت | `scram-sha-256`، کاربر برنامه‌ی جدا، کاربر replication جدا، پورت فقط روی 127.0.0.1 |
| حافظه | `shared_buffers=2GB`، `effective_cache_size=6GB`، `work_mem=32MB`، `maintenance_work_mem=512MB` |
| WAL | `wal_compression=lz4`، `max_wal_size=8GB`، `checkpoint_timeout=15min` |
| آرشیو | `archive_mode=on` و `archive_command=pgbackrest archive-push`، به صورت async |
| SSD | `random_page_cost=1.1`، `effective_io_concurrency=200` |
| پایش | `pg_stat_statements`، `track_io_timing`، لاگ کوئری‌های بالای ۱ ثانیه |
| container | healthcheck، `restart: unless-stopped`، limit به میزان ۴ CPU و ۸ گیگ، `shm_size: 1g`، `ulimit nofile`، توقف با SIGINT و ۲ دقیقه فرصت، چرخش لاگ (۵ × ۵۰ مگ) |
| volumeها | `pgdata` (داده) و `pgbackrest-repo` (بکاپ و آرشیو) جدا از هم |

تنظیمات در `single/conf/postgresql.conf` است و برای سخت‌افزار خودتان آن را عوض کنید: معمولاً `shared_buffers` حدود ۲۵٪ RAM و `effective_cache_size` حدود ۷۵٪.

<div dir="ltr">

```bash
./single/up.sh                                   # start (idempotent)
docker exec -it -u postgres pg-single psql -d appdb
docker logs -f pg-single
./single/down.sh                                 # stop, keep data
./single/down.sh --wipe                          # stop + DELETE data and backups
```

</div>

> **مهم برای DR:** در single، فایل `postgresql.conf` از `single/conf` mount می‌شود و **داخل بکاپ نیست.** هنگام بازیابی (`dr.sh`) همین فایل استفاده می‌شود. اگر روی سرور دیگری بازیابی می‌کنید، پوشه‌ی `single/conf` را هم داشته باشید. بدون آن، PostgreSQL با پیش‌فرض‌های initdb بالا می‌آید و recovery را متوقف می‌کند، چون مثلاً `max_connections=100` کمتر از مقدار سرور اصلی (۲۰۰) است. این دقیقاً در تست ما رخ داد و اسکریپت برای همین اصلاح شده است.

### ۵-۱. مانیتورینگ (`monitoring/`)

<div dir="ltr">

```
pg-single ──► postgres_exporter (:9187) ──┐
                                          ├──► Prometheus (:9090, alerts.yml) ──► Grafana (:3000)
backup repo ─► pgbackrest_exporter (:9854)┘
 (volume, read-only)
```

</div>

| جزء | نقش |
|---|---|
| `postgres_exporter` v0.18.1 | با نقش فقط‌خواندنی `monitor` (عضو `pg_monitor`) وصل می‌شود. وضعیت سرور، اتصال‌ها، TPS، cache hit، قفل‌ها، WAL، آرشیو، checkpointها و **pg_stat_statements** (همراه متن کوئری) را می‌دهد |
| `pgbackrest_exporter` v0.21.0 | `pgbackrest info` را هر ۶۰ ثانیه روی مخزن بکاپ اجرا می‌کند: سن آخرین بکاپ، حجم، مدت و خطا. مخزن **read-only** mount می‌شود |
| Prometheus v3.7.2 | نگهداری ۱۵ روز و **حداکثر ۲ گیگ** (به خاطر محدودیت دیسک) |
| Grafana 12.2 | datasource و داشبورد «PostgreSQL single node» (۳۰ پنل) خودکار provision می‌شوند و داشبورد صفحه‌ی اصلی است |

<div dir="ltr">

```bash
./monitoring/up.sh              # needs ./single/up.sh first; creates the monitor role (idempotent)
# Grafana    http://127.0.0.1:3000   admin / GRAFANA_ADMIN_PASSWORD from .env
# Prometheus http://127.0.0.1:9090/alerts
./monitoring/down.sh            # stop (keeps metrics)
./monitoring/down.sh --wipe     # also delete Prometheus/Grafana data (never the DB or backups)

# unit tests for the alert rules
docker run --rm --entrypoint promtool -v "$PWD/monitoring/prometheus:/p" -w /p \
       prom/prometheus:v3.7.2 test rules alerts_test.yml
```

</div>

`up.sh` دو رمز `MONITOR_PASSWORD` و `GRAFANA_ADMIN_PASSWORD` را به صورت تصادفی به `.env` اضافه می‌کند.

**بخش‌های داشبورد:** نمای کلی (UP، uptime، حجم، درصد اتصال، cache hit، سن آخرین بکاپ و آخرین full، خطای آرشیو)، بار کاری (تراکنش و ردیف در ثانیه، اتصال‌ها به تفکیک state، طولانی‌ترین تراکنش، قفل‌ها، deadlock و فایل temp)، ذخیره‌سازی (حجم دیتابیس، حجم `pg_wal` در برابر `max_wal_size`، checkpointهای timed و requested، نرخ آرشیو)، بکاپ‌ها، و ۱۰ کوئری سنگین و ۱۰ کوئری پرتکرار.

**هشدارها** (`monitoring/prometheus/alerts.yml`):

| هشدار | شرط |
|---|---|
| `PostgresDown` / `PostgresExporterDown` | دیتابیس یا یکی از exporterها بیشتر از ۱ تا ۲ دقیقه در دسترس نیست |
| `PostgresRestarted` | سرور در ۵ دقیقه‌ی اخیر ری‌استارت شده است |
| `PostgresConnectionsHigh` | بیش از ۸۰٪ از `max_connections` به مدت ۵ دقیقه پر است |
| `PostgresLongTransaction` | تراکنش active یا idle in transaction بیش از ۱۰ دقیقه باز مانده است |
| `PostgresDeadlocks` / `PostgresCacheHitRatioLow` | deadlock رخ داده، یا cache hit زیر ۹۰٪ است (فقط وقتی خواندن از دیسک واقعاً زیاد است) |
| `WalArchivingFailing` | `archive_command` مدام خطا می‌دهد، پس PITR ناقص می‌شود |
| `WalDirectoryLarge` | حجم `pg_wal` از ۱.۵ برابر `max_wal_size` بیشتر شده. یعنی WAL بازیافت نمی‌شود و دیسک پر خواهد شد |
| `BackupTooOld` / `FullBackupTooOld` | آخرین بکاپ قدیمی‌تر از ۶ ساعت، یا آخرین full قدیمی‌تر از ۸ روز است (مطابق `dr.sh single cron`) |
| `BackupFailed` / `BackupRepoUnhealthy` | آخرین بکاپ خطا دارد، یا stanza یا مخزن سالم نیست |

> در این پروژه Alertmanager نیست و هشدارها در `http://127.0.0.1:9090/alerts` دیده می‌شوند. برای ارسال به ایمیل، Slack یا Telegram، یک Alertmanager و بلوک `alerting:` را به `prometheus.yml` اضافه کنید. مانیتورینگ فعلاً فقط برای single است.

> چرا image رسمی `woblerr/pgbackrest_exporter` مستقیم استفاده نشده؟ entrypoint آن وقتی با root اجرا شود، روی `/var/lib/pgbackrest` دستور `chown -R` اجرا می‌کند و مالکیت مخزن بکاپ را عوض می‌کند. pgBackRest داخل آن هم نسخه‌ی 2.56 است، در حالی که مخزن ما با 2.59.3 نوشته شده. برای همین فقط باینری exporter روی image خودمان (`pgha/postgres:17`) کپی می‌شود و با کاربر postgres اجرا می‌شود.

---

## ۶. کلاستر سه‌نودی (`cluster/docker-compose.yml`)

### ۶-۱. معماری

<div dir="ltr">

```
                 clients
        rw :6432 │       │ ro :6433
             ┌───▼───────▼───┐
             │    HAProxy    │  health check = Patroni REST API (:8008)
             └───┬───┬───┬───┘  /primary -> 200 only on the leader
                 │   │   │       /replica -> 200 only on healthy replicas
         ┌───────┘   │   └───────┐
     ┌───▼───┐   ┌───▼───┐   ┌───▼───┐
     │  pg1  │◄──┤  pg2  ├──►│  pg3  │   PostgreSQL 17 + Patroni
     │Leader │   │ Sync  │   │Replica│   streaming replication
     └───┬───┘   └───┬───┘   └───┬───┘   (1 synchronous standby)
         │  leader lock / state  │
     ┌───▼───────────▼───────────▼───┐
     │   etcd1    etcd2    etcd3     │   consensus (quorum 2 of 3)
     └───────────────────────────────┘
         │ WAL archive + backups (primary)
     ┌───▼──────────────┐
     │ pgBackRest repo  │  (shared volume)
     └──────────────────┘
```

</div>

| جزء | نقش |
|---|---|
| **etcd** (۳ نود) | ذخیره‌ی وضعیت کلاستر و قفل leader. با از دست رفتن یک نود هم کار می‌کند (quorum دو از سه) |
| **Patroni** | روی هر نود PostgreSQL را مدیریت می‌کند: انتخاب leader، failover خودکار، برگرداندن نود قدیمی با `pg_rewind`، و ساختن replica جدید |
| **synchronous_mode** | هر commit روی primary منتظر می‌ماند تا **یک** standby آن را دریافت کند. در failover هیچ تراکنش commit‌شده‌ای از دست نمی‌رود (RPO=0). اگر هیچ standbyی نماند، نوشتن ادامه پیدا می‌کند (`synchronous_mode_strict: false`) |
| **HAProxy** | آدرس ثابت برای برنامه‌ها. بعد از failover خودش ترافیک را به primary جدید می‌فرستد و sessionهای نود از کار افتاده را می‌بندد |
| **pgBackRest** | فقط primary آرشیو می‌کند. بکاپ روی primary فعلی گرفته می‌شود و `dr.sh` خودش آن را پیدا می‌کند |

### ۶-۲. دستورها

<div dir="ltr">

```bash
./cluster/up.sh                              # start, waits for 1 leader + 2 streaming replicas
./dr.sh cluster status                       # patronictl list
docker exec -it pg1 patronictl -c /tmp/patroni.yml list
docker exec -it pg1 patronictl -c /tmp/patroni.yml edit-config   # change DCS settings
./dr.sh cluster switchover                   # planned primary change (maintenance)
./dr.sh cluster failover-test                # crash test (see section 8)
./cluster/down.sh  |  ./cluster/down.sh --wipe
```

</div>

تنظیمات مشترک PostgreSQL مثل حافظه و WAL در `bootstrap.dcs` فایل `cluster/patroni/patroni.yml.tmpl` هستند. این تنظیمات فقط **در اولین راه‌اندازی** وارد etcd می‌شوند. بعد از آن با `patronictl edit-config` تغییرشان دهید، نه با ویرایش فایل.

### ۶-۳. اتصال برنامه‌ها

<div dir="ltr">

```
# writes (always the current primary)
postgresql://app:<APP_PASSWORD>@127.0.0.1:6432/appdb
# reads that may be slightly behind (replicas)
postgresql://app:<APP_PASSWORD>@127.0.0.1:6433/appdb
# or libpq multi-host without HAProxy:
postgresql://app:<pw>@pg1:5432,pg2:5432,pg3:5432/appdb?target_session_attrs=read-write
```

</div>

### ۶-۴. در production واقعی (سه سرور)

این compose همه‌چیز را روی یک ماشین اجرا می‌کند، که برای تست و staging مناسب است. برای HA واقعی:
- `etcdN` و `pgN` را روی **سه سرور جدا** اجرا کنید. سرویس‌ها همین‌ها هستند، فقط روی هر سرور یکی، و در `ETCD_INITIAL_CLUSTER` و `connect_address` آدرس IP سرورها را بگذارید.
- HAProxy را روی سرورهای برنامه یا به صورت دوتایی با keepalived و VIP اجرا کنید.
- مخزن pgBackRest را **بیرون از این سه سرور** بگذارید (بخش ۷-۵).

---

## ۷. بکاپ و DR با pgBackRest (`dr.sh`)

### ۷-۱. مفاهیم

| اصطلاح | معنی |
|---|---|
| **full** | کپی کامل |
| **diff** | تغییرات نسبت به آخرین full |
| **incr** | تغییرات نسبت به آخرین بکاپ از هر نوع |
| **آرشیو WAL** | هر تغییر در دیتابیس (WAL) حداکثر ۶۰ ثانیه بعد (`archive_timeout`) در مخزن ذخیره می‌شود. همین امکان بازیابی تا **هر لحظه‌ی دلخواه** (PITR) را می‌دهد |
| **retention** | ۲ بکاپ full نگه داشته می‌شود (و ۶ diff). بکاپ‌ها و WALهای قدیمی‌تر خودکار پاک می‌شوند |
| فشرده‌سازی | `zstd`. بکاپ‌ها با `repo1-bundle` و `repo1-block` برای incr کوچک‌اند |

### ۷-۲. دستورها

<div dir="ltr">

```bash
./dr.sh single  backup full          # or diff / incr (default incr; first one is always full)
./dr.sh single  info                 # backups + WAL range
./dr.sh single  check                # is archiving working?
./dr.sh cluster backup full          # runs on the current primary automatically
./dr.sh single  cron                 # suggested crontab (full weekly, diff daily, incr 4h, weekly drill)
```

</div>

### ۷-۳. تمرین DR بدون دست زدن به سرور اصلی (`restore-test`)

<div dir="ltr">

```bash
./dr.sh single restore-test                                   # newest backup + all WAL
./dr.sh single restore-test --time "2026-10-08 10:30:00+00"   # point in time
./dr.sh cluster restore-test
```

</div>

این دستور مراحل زیر را انجام می‌دهد:
1. یک container **موقت** می‌سازد.
2. بکاپ را در آن restore می‌کند.
3. PostgreSQL را با WAL replay بالا می‌آورد. در این نسخه آرشیو خاموش است، پس سرور اصلی تحت تأثیر قرار نمی‌گیرد.
4. صبر می‌کند تا promote شود.
5. تعداد جدول‌ها و ردیف‌ها و حجم را گزارش می‌دهد.
6. همه‌چیز را پاک می‌کند.

این تمرین را هر هفته اجرا کنید (cron). بکاپی که بازیابی‌اش تست نشده، بکاپ نیست. برای دیباگ، `KEEP=1 ./dr.sh ...` container را نگه می‌دارد.

### ۷-۴. بازیابی واقعی

**single، برگرداندن به یک لحظه‌ی مشخص (مثلاً بعد از یک `DELETE` اشتباه):**

<div dir="ltr">

```bash
./dr.sh single pitr --time "2026-10-08 10:30:00+00" --yes
./dr.sh single backup full            # always take a new full backup after a PITR
```

</div>

**کلاستر، بازسازی کامل از بکاپ** (از دست رفتن همه‌ی نودها، خرابی منطقی داده یا PITR کل کلاستر):

<div dir="ltr">

```bash
./dr.sh cluster restore-cluster --yes                                  # newest state
./dr.sh cluster restore-cluster --time "2026-10-08 10:30:00+00" --yes  # point in time
./dr.sh cluster backup full
```

</div>

این دستور این مراحل را انجام می‌دهد:
1. pg1 تا pg3 را متوقف می‌کند.
2. وضعیت کلاستر را از etcd پاک می‌کند.
3. داده‌ی هر سه نود را پاک می‌کند.
4. **pg1 را با bootstrap از pgBackRest** راه‌اندازی می‌کند (`PATRONI_BOOTSTRAP=pgbackrest`) تا restore و replay شود و Leader شود.
5. pg2 و pg3 را دوباره از روی pg1 clone می‌کند.

### ۷-۵. مخزن بکاپ در production

در این پروژه مخزن یک docker volume روی **همان ماشین** است. این برای تست کافی است، ولی **DR واقعی نیست**، چون اگر دیسک یا سرور از بین برود بکاپ هم از بین می‌رود. در production `repo1` را روی S3، MinIO یا RustFS بگذارید:

<div dir="ltr">

```ini
[global]
repo1-type=s3
repo1-s3-endpoint=s3.company.local
repo1-s3-bucket=pg-backups
repo1-s3-region=us-east-1
repo1-s3-key=<access-key>
repo1-s3-key-secret=<secret-key>
repo1-s3-uri-style=path
repo1-path=/pg-cluster
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=<long-random-passphrase>
```

</div>

می‌توانید یک **repo2** هم در دیتاسنتر دوم اضافه کنید. pgBackRest به هر دو می‌نویسد.

---

## ۸. failover: چه اتفاقی می‌افتد؟

<div dir="ltr">

```bash
./dr.sh cluster failover-test
```

</div>

این تست مراحل زیر را انجام می‌دهد:
1. یک ردیف را از طریق HAProxy روی پورت 6432 commit می‌کند.
2. container مربوط به primary را با `docker kill` از بین می‌برد (شبیه‌سازی crash).
3. مدام تلاش به نوشتن می‌کند تا primary جدید جواب دهد و زمان قطعی را اندازه می‌گیرد.
4. بررسی می‌کند که ردیف commit‌شده‌ی قبل از crash **وجود دارد**.
5. نود قدیمی را دوباره start می‌کند. این نود خودش به‌عنوان replica برمی‌گردد (با `pg_rewind` در صورت نیاز).

**زمان failover** حدود `ttl` (۳۰ ثانیه) به اضافه‌ی چند ثانیه است. برای سریع‌تر شدن، مقدار `ttl` را کمتر کنید (مثلاً ۲۰) و `loop_wait` را ۵ بگذارید (با `patronictl edit-config`). هزینه‌اش failover‌های اشتباه بیشتر در شبکه‌ی ناپایدار است.

---

<a id="results"></a>

## ۹. نتیجه‌ی تست‌ها (اجرا شده روی همین فایل‌ها، 2026-10-08)

**محیط تست:** WSL2، ۲۸ هسته، ۳۰ گیگ RAM، دیسک SSD، Docker 29، PostgreSQL 17.11، Patroni 4.1.5، pgBackRest 2.59.3.

### ۹-۱. ساخت دیتابیس کامل روی single

| مورد | نتیجه |
|---|---|
| تعداد جدول و ستون | **۱۰۰ جدول، هر کدام ۳۰ ستون** |
| تعداد ردیف | **۱۰٬۰۰۰٬۰۰۰** (هر جدول دقیقاً ۱۰۰٬۰۰۰) |
| حجم دیتابیس | **۱۵ GB** (جدول‌ها ۱۴ GB و ایندکس‌ها ۸۶۱ MB)، **۱۶۰۹ بایت به ازای هر ردیف** (هدف ۱۶۱۰)، حدود ۱۵۳ MB برای هر جدول |
| زمان بارگذاری | ۶۳۳ ثانیه با ۸ job موازی |
| زمان ایندکس و VACUUM ANALYZE | ۹۶ ثانیه |
| **زمان کل** | **۱۲ دقیقه** |

### ۹-۲. بکاپ و DR روی ۱۵ گیگ داده (single)

| مورد | نتیجه |
|---|---|
| بکاپ full | **۵۸ ثانیه**. حجم در مخزن **۵.۹ GB** (zstd) |
| `restore-test` (بازیابی کامل) | فایل‌ها در ۳۰ ثانیه restore شدند و نسخه در ۳۳ ثانیه promote شد. **۱۰۰ جدول، ۱۰M ردیف و ۱۵ GB** بازیابی و تأیید شد |
| PITR در محیط آزمایشی (`restore-test --time T`) | فقط ردیف قبل از T برگشت و تراکنش بعد از T کنار گذاشته شد (`recovery stopping before commit`) |
| بازیابی کامل بدون `--time` | هر دو ردیف (قبل و بعد از T) برگشتند |
| `pitr --time T --yes` روی دیتابیس زنده | دیتابیس به لحظه‌ی T برگشت و timeline جدید (۲) ساخته شد. بکاپ full بعدی و `check` موفق بودند |

### ۹-۳. کلاستر

| سناریو | نتیجه |
|---|---|
| راه‌اندازی | ۳ نود etcd سالم. یک Leader، یک Sync Standby و یک Replica، همه در حال streaming |
| نوشتن از HAProxy و خواندن از replica | داده‌ای که روی پورت 6432 نوشته شد، روی replica (پورت 6433) با همان تعداد ردیف خوانده شد |
| **failover** (kill کردن primary) | نوشتن بعد از **۳۸ ثانیه** دوباره ممکن شد. ردیف commit‌شده‌ی قبل از crash **از دست نرفت**. نود قدیمی خودکار به‌عنوان replica برگشت |
| `restore-cluster --time T` | کل کلاستر در **۱۴ ثانیه** از بکاپ بازسازی شد. فقط داده‌ی قبل از T ماند و هر سه نود برگشتند. بازیابی از روی چند timeline (۱ تا ۳) عبور کرد |
| ری‌استارت کامل ماشین میزبان | کلاستر خودش بالا آمد، Leader انتخاب شد و replicaها دوباره stream کردند |
| **resume در `script.sh`** | بارگذاری کامل ۱۵ گیگ روی کلاستر دو بار با ری‌استارت ماشین قطع شد. هر بار با اجرای دوباره‌ی همان دستور، کار از chunk بعدی ادامه پیدا کرد (۸۰ از ۴۰۰ chunk، سپس ۶۴ chunk دیگر) و ردیف تکراری ساخته نشد |

#### تست کلاستر در مقیاس بزرگ (۵ گیگ، اجرای دوباره روی Docker خالی)

اجرای ۱۵ گیگی روی کلاستر دو بار با ری‌استارت ماشین قطع شد. علت ری‌استارت پر شدن درایو C: بود (هشدار بخش ۲ را ببینید). برای همین تست کلاستر با **۵ گیگ** تکرار شد: ۱۰۰ جدول × ۳۰ ستون با **۳٬۳۳۰٬۰۰۰ ردیف** و همان حجم ۱۶۱۳ بایت برای هر ردیف.

| مورد | نتیجه |
|---|---|
| `script.sh generate --target cluster` | ۳٬۳۳۰٬۰۰۰ ردیف (هر جدول دقیقاً ۳۳٬۳۰۰) در **۵ دقیقه و ۲۷ ثانیه**، با synchronous replication |
| `verify` روی replica (پورت 6433) | همان ۳٬۳۳۰٬۰۰۰ ردیف و ۱۰۰ جدول |
| بکاپ full | **۲۲ ثانیه**، از ۵ گیگ داده به **۲ گیگ** در مخزن |
| failover (kill کردن primary) | نوشتن بعد از **۲۸ ثانیه** دوباره ممکن شد. **هیچ داده‌ای از دست نرفت.** نود قدیمی خودکار به‌عنوان replica برگشت |
| `restore-test` | فایل‌ها در ۹ ثانیه restore شدند و نسخه در ۱۳ ثانیه promote شد. ۱۰۰ جدول و ۳٬۳۳۰٬۰۰۰ ردیف بازیابی و تأیید شد |
| حداقل فضای آزاد C: در طول تست | ۸۸ گیگ (از ۱۳۵). یک watchdog هر ۱۵ ثانیه فضا را می‌پایید |

برای ۱۵ گیگ کامل روی کلاستر حدود ۱۰۰ گیگ فضای آزاد واقعی لازم است.

### ۹-۴. single با ۵ گیگ داده و مانیتورینگ (2026-10-10)

برای کم کردن مصرف دیسک، single با `down.sh --wipe` پاک و با ۵ گیگ داده از نو ساخته شد: `./script.sh generate --rows 3333300 --size-gb 5`.

| مورد | نتیجه |
|---|---|
| ساخت داده | **۳٬۳۳۳٬۳۰۰ ردیف** (هر جدول ۳۳٬۳۳۳)، ۱۰۰ جدول × ۳۰ ستون، **۵.۱ GB** و ۱۶۱۰ بایت برای هر ردیف. زمان کل **۲۰۱ ثانیه** (بارگذاری ۱۶۴ ثانیه). `verify` موفق بود |
| بکاپ full | **۱۴ ثانیه**، از ۵.۱ گیگ داده به ۲.۱ گیگ در مخزن |
| حجم volumeهای داکر | از **۴۰ گیگ به ۱۸ گیگ** رسید: `pgdata` ۱۲.۵ گیگ (۵ گیگ داده به همراه WAL تا سقف `max_wal_size=8GB`) و مخزن بکاپ ۵.۷ گیگ |
| بار کاری pgbench (۳ دقیقه، ۸ کلاینت، خواندن با PK، اسکن بازه‌ای و UPDATE) | **۴۳۴۰ TPS**، تأخیر میانگین ۱.۸ ms، بدون خطا |
| کوئری‌های داشبورد | هر ۳۸ کوئری داشبورد روی Prometheus داده برگرداندند. کوئری از مسیر Grafana و health datasource هم OK بود |
| تست واحد هشدارها (`promtool test rules`) | ۶ سناریو موفق: DB down، خطای آرشیو، رشد `pg_wal`، بکاپ قدیمی (و قدیمی نبودن full)، اتصال بالای ۸۰٪، و تراکنش idle in transaction |
| تست واقعی (`docker stop pg-single`) | `PostgresDown` بعد از **۹۰ ثانیه** firing شد. بعد از start، این هشدار رفع شد و `PostgresRestarted` firing شد. `dr.sh single check` هم OK بود |

> فایل vhdx در WSL خودبه‌خود کوچک نمی‌شود. پس فضای آزاد درایو C: بعد از پاک کردن عوض نمی‌شود، ولی آن ۲۲ گیگ داخل vhdx دوباره قابل استفاده است. برای پس گرفتن واقعی فضا، `Optimize-VHD` را در بخش ۲ ببینید.

دو مشکل هم در این مرحله پیدا شد:
- collector `long_running_transactions` در postgres_exporter 0.18.1 وقتی تراکنش بازی نیست، هر بار با خطای `converting NULL to float64` شکست می‌خورد. این collector حذف شد و هشدار تراکنش طولانی حالا از `pg_stat_activity_max_tx_duration` استفاده می‌کند.
- در 0.18 متن کوئری روی متریک جداگانه‌ی `pg_stat_statements_query_id` است، نه روی خود متریک‌های زمان و تعداد. پنل‌ها با `* on (queryid) group_left (query)` آن را join می‌کنند.

### ۹-۵. مشکل‌هایی که در تست پیدا و اصلاح شد

1. **بازیابی single بدون فایل conf:** فایل `postgresql.conf` بیرون از PGDATA بود و در بکاپ نیامد. نسخه‌ی بازیابی‌شده با `max_connections=100` بالا آمد و PostgreSQL recovery را متوقف کرد. حالا `dr.sh` همان فایل conf را استفاده می‌کند (بخش ۵).
2. **session آویزان در HAProxy بعد از crash:** resolver داکر نام نود از کار افتاده را حذف می‌کرد. در نتیجه HAProxy سرور را به حالت `MAINT` می‌برد، نه `DOWN`، و sessionهای آن نود بسته نمی‌شد. با `hold nx/obsolete` اصلاح شد.
3. **calibration حجم:** تنظیم خطی به خاطر جهش تعداد ردیف در هر صفحه‌ی ۸KB دقیق نبود. با جستجوی دودویی جایگزین شد و خطا حالا زیر ۱٪ است.

---

## ۱۰. عیب‌یابی

| علامت | راه حل |
|---|---|
| `script.sh`: `cannot connect` | سرویس را بالا بیاورید (`./single/up.sh`) و پورت و `--target` را چک کنید |
| `script.sh`: `read-only replica` | برای نوشتن از پورت 6432 استفاده کنید (`--target cluster`) |
| `script.sh`: `already holds a dataset with another shape` | از `--force` استفاده کنید یا `--schema` دیگری بدهید |
| `dr.sh check` خطای آرشیو می‌دهد | `docker exec -u postgres pg-single pgbackrest --stanza=main stanza-create`. لاگ‌ها در `/var/log/pgbackrest` داخل container هستند |
| کلاستر Leader ندارد | `docker logs pg1`، و `docker exec etcd1 etcdctl endpoint health --cluster` |
| HAProxy اتصال را رد می‌کند | صفحه‌ی `http://127.0.0.1:7000` را ببینید: کدام نود UP است؟ |
| یک replica عقب مانده یا خراب است | `docker exec pg1 patronictl -c /tmp/patroni.yml reinit pg-cluster pg3` |
| حجم WAL زیاد شده | `./dr.sh <mode> check`. اگر آرشیو کار نکند، WAL پاک نمی‌شود |
| Grafana داده نشان نمی‌دهد | `http://127.0.0.1:9090/targets`: آیا هر سه target در حالت UP هستند؟ اگر `postgres` در حالت DOWN است، `./monitoring/up.sh` را دوباره اجرا کنید تا نقش `monitor` و رمز آن هماهنگ شود |
| پنل‌های بکاپ خالی هستند | تا اولین بکاپ داده‌ای نیست: `./dr.sh single backup full`. exporter هر ۶۰ ثانیه به‌روز می‌شود |

## ۱۱. پاک کردن همه‌چیز

<div dir="ltr">

```bash
./monitoring/down.sh --wipe
./single/down.sh --wipe
./cluster/down.sh --wipe
docker image rm pgha/pgbackrest-exporter:0.21.0 pgha/patroni:17 pgha/postgres:17
rm .env
```

</div>

</div>
