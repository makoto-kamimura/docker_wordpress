# 仕様 (Design)

Docker Compose 上にプロダクション運用に耐える WordPress スタックを構築するためのテンプレート。利用手順は [operation.md](./operation.md)、本番化チェックリストは [task.md](./task.md)。

## 1. 概要

* **ターゲット**: ポートフォリオサイト / 中規模ブログを **1 VM** で運用するスケール
* **基本方針**:
    1. **WAF (ModSecurity + OWASP CRS)** をリバースプロキシで前段に置き、WordPress を直接外部に晒さない
    2. **シークレットは `.env`**、コードに平文を持たせない
    3. **ネットワークを 2 段に分離** し、DB / Redis は外部からも nginx からも到達不可
    4. **すべてのコンテナにヘルスチェック・リソース制限・ログローテーション・最小権限** を適用
    5. **自動セットアップ・バックアップ・デプロイ・監視** までシェル + GitHub Actions で完結
* **同梱テーマ**: ポートフォリオ向け `tty-portfolio` (terminal / monospace minimal、Lighthouse 90+ / WCAG AA / dark mode / OGP + JSON-LD)

## 2. アーキテクチャ概要

```
                ┌──────────────────────────────────────┐
[Internet] ──→  │ Cloudflare (任意) — DDoS / cache     │ → public IP
                └──────────────────────────────────────┘
                              │ 443 / 80
                              ▼
          ╔══════════════════════════════════════════════════╗
          ║   nginx (OWASP ModSecurity + CRS)               ║
          ║   makoto-kamimura.com       → wordpress:80      ║
          ║   sales.makoto-kamimura.com → demo-sales-*      ║
          ║   inventory.m-k.com         → demo-inventory-*  ║
          ╚══════════╤══════════════════════════╤═══════════╝
                     │ frontend_network          │ proxy_network
                     ▼                           ▼
          ┌──────────────────────┐  ┌───────────────────────────────┐
          │   wordpress (Apache) │  │  demo-sales-api     :3000     │
          │   PHP 8.3 + Redis OC │  │  demo-sales-web     :3001     │
          └────────┬──────┬──────┘  │  demo-inventory-api :8000     │
          db:3306  │      │ redis:  │  demo-inventory-web :3001     │
                   ▼      ▼ 6379   │  demo-static        :80       │
      ╔═══════════════════════════╗ │  demo-todo          :3000     │
      ║  backend_network          ║ └───────────────────────────────┘
      ║  (internal: true)         ║        │                │
      ║  ┌─────────────────────┐  ║  demo_sales_backend   demo_inventory_backend
      ║  │ MariaDB 10.11 LTS   │  ║  (internal: true)     (internal: true)
      ║  └─────────────────────┘  ║  demo-sales-db(PG)    demo-inventory-db(MySQL)
      ║  ┌─────────────────────┐  ║
      ║  │ Redis 7.4 (auth)    │  ║
      ║  └─────────────────────┘  ║
      ║  ← phpmyadmin (admin)     ║  127.0.0.1:8888 (SSH tunnel)
      ║  ← wpcli      (cli)       ║
      ╚═══════════════════════════╝

  常駐 (docker-compose.yml)   : db / wordpress / redis / nginx / certbot
  デモ (docker-compose.demo.yml): demo-sales-{db,api,web} / demo-inventory-{db,api,web}
                                  demo-static / demo-todo
  profile=admin               : phpmyadmin (127.0.0.1:8888 のみ)
  profile=stats               : webalizer  (アクセスログ解析)
  profile=cli                 : wpcli      (wp-cli 経由の自動化)
  profile=monitoring          : uptime-kuma (127.0.0.1:3001 のみ、SSH トンネル管理)
```

## 3. ディレクトリ構成

```
docker_wordpress/
├── app/                                     # アプリケーション層 (永続データ + デモアプリ)
│   ├── wordpress/
│   │   ├── db_data/                         # 旧 MySQL 5.7 データ (移行用に温存)
│   │   ├── db_data_mariadb/                 # MariaDB 10.11 のデータ
│   │   └── wordpress_data/                  # wp-content / wp-config 等
│   ├── log_data/
│   │   ├── db_logs/                         # MariaDB のログ
│   │   └── wordpress_logs/                  # Apache のログ
│   ├── demo-static/                         # 静的 HTML デモ (nginx:alpine)
│   ├── demo-todo/                           # Node.js Todo SPA デモ
│   ├── docker_sales_management/             # Rails API + Next.js 売上管理デモ
│   │   └── app/{api,web}/Dockerfile
│   └── docker_inventory_management/         # Laravel API + Next.js 在庫管理デモ
│       ├── app/{backend,web}/
│       └── platform/docker/Dockerfile
├── platform/                                # 基盤層 (Docker / Nginx / 自動化)
│   ├── docker-compose.yml                   # コアサービス (9 サービス + profile)
│   ├── docker-compose.demo.yml              # デモアプリサービス (8 サービス)
│   ├── .env                                 # 本番用 secrets (git 管理外)
│   ├── .env.example                         # テンプレート
│   ├── nginx_conf/                          # Nginx 設定テンプレート (バージョン管理)
│   │   └── conf.d/
│   │       ├── default.conf.template        # 本番用 (envsubst で展開 → nginx_data/conf.d/)
│   │       ├── default.conf.public          # 手動コピー用 本番設定
│   │       ├── default.conf.local           # ローカル (自己署名)
│   │       ├── cloudflare-realip.conf       # CF 経由時の real_ip 補正
│   │       ├── demo-app.conf.template       # サブドメインデモ設定テンプレ
│   │       └── demo-app.conf.local.template
│   ├── nginx_data/                          # 実行時マウント (コンテナが読む)
│   │   ├── conf.d/                          # 実際に nginx が読む .conf
│   │   │   ├── default.conf                 # WordPress 本体 (envsubst 自動生成)
│   │   │   ├── sales.conf                   # sales.makoto-kamimura.com
│   │   │   ├── inventory.conf               # inventory.makoto-kamimura.com
│   │   │   ├── modsecurity.conf             # ModSecurity 有効化 (自動生成)
│   │   │   ├── logging.conf                 # アクセスログ設定 (自動生成)
│   │   │   └── demo-banner.inc              # デモ用ナビバー sub_filter include
│   │   ├── certs/live/                      # Let's Encrypt 証明書
│   │   │   ├── makoto-kamimura.com/
│   │   │   ├── sales.makoto-kamimura.com/
│   │   │   └── inventory.makoto-kamimura.com/
│   │   ├── html/                            # ACME challenge 用 webroot
│   │   └── modsec-rules/                    # CRS exclusion ルール
│   │       ├── REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf  # id:9500100 (カスタム)
│   │       └── RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf
│   ├── php_conf/
│   │   └── uploads.ini                      # PHP upload / OPcache / セッション設定
│   ├── log_data/
│   │   └── nginx_logs/                      # Nginx + ModSecurity ログ
│   └── scripts/
│       ├── init-dirs.sh                     # ディレクトリ作成 + nginx uid=101 向け権限設定
│       ├── backup-db.sh                     # mariadb-dump + gzip + 世代管理
│       ├── initial-setup.sh                 # wp-cli で初回構築を冪等実行
│       ├── update-cloudflare-ips.sh         # CF IP レンジ自動更新
│       └── deploy.sh                        # backup → pull → up → health → 自動 rollback
├── .github/
│   └── workflows/
│       ├── ci.yml                           # compose validate / shellcheck / Trivy
│       └── deploy.yml                       # workflow_dispatch で SSH デプロイ
├── doc/
│   ├── design.md                            # 本ファイル
│   ├── operation.md                         # 利用方法
│   ├── task.md                              # 本番化タスク (進捗付き)
│   ├── demo-apps.md                         # デモアプリ汎用追加手順
│   ├── demo-apps-sales.md                   # sales.makoto-kamimura.com 詳細
│   └── demo-apps-inventory.md              # inventory.makoto-kamimura.com 詳細
├── history.md                               # 開発・障害履歴
├── README.md
└── LICENSE
```

設計意図: **変化頻度の高いコンテンツ (`app/`)** と **比較的安定する基盤定義 (`platform/`)** を明確に分離。バックアップ対象は `app/` 配下、構成変更レビュー対象は `platform/` 配下。

## 4. サービス構成

### 4.0 コアサービス一覧

[platform/docker-compose.yml](../platform/docker-compose.yml) に 9 サービスを定義 (常駐 5 + profile 起動 4)。

| サービス | イメージ | profile | 役割 | 公開ポート |
| --- | --- | --- | --- | --- |
| `db`         | `mariadb:10.11.13`                   | 常駐         | DB                          | (内部のみ)         |
| `wordpress`  | `wordpress:6.7.2-php8.3-apache`      | 常駐         | WordPress 本体               | (内部のみ)         |
| `redis`      | `redis:7.4.2-alpine`                 | 常駐         | Object Cache                | (内部のみ)         |
| `nginx`      | `owasp/modsecurity-crs:nginx-alpine` | 常駐         | リバースプロキシ + WAF       | `80`, `443`        |
| `certbot`    | `certbot/certbot:v2.11.0`            | 常駐         | Let's Encrypt 更新ループ     | -                  |
| `phpmyadmin` | `phpmyadmin/phpmyadmin:5.2.1`        | `admin`      | DB 管理                     | `127.0.0.1:8888`   |
| `webalizer`  | `toughiq/webalizer:latest`           | `stats`      | アクセスログ解析             | (内部のみ)         |
| `wpcli`      | `wordpress:cli-2.10.0-php8.3`        | `cli`        | 自動化 / 運用                | (内部のみ)         |
| `uptime-kuma`| `louislam/uptime-kuma:1.23.13`       | `monitoring` | セルフホスト外形監視         | `127.0.0.1:3001`   |

### 4.0.1 デモアプリサービス一覧

[platform/docker-compose.demo.yml](../platform/docker-compose.demo.yml) に定義 (常駐 8 サービス)。

| サービス | イメージ | 役割 | ネットワーク |
| --- | --- | --- | --- |
| `demo-sales-db`        | `pgvector/pgvector:pg16`          | 売上管理 DB (PostgreSQL) | `demo_sales_backend` |
| `demo-sales-api`       | build (Rails API)                 | 売上管理 API             | `proxy_network`, `demo_sales_backend` |
| `demo-sales-web`       | build (Next.js)                   | 売上管理 フロントエンド   | `proxy_network`, `demo_sales_backend` |
| `demo-inventory-db`    | `mysql:8.0`                       | 在庫管理 DB (MySQL)      | `demo_inventory_backend` |
| `demo-inventory-api`   | build (Laravel API)               | 在庫管理 API             | `proxy_network`, `demo_inventory_backend` |
| `demo-inventory-web`   | build (Next.js)                   | 在庫管理 フロントエンド   | `proxy_network`, `demo_inventory_backend` |
| `demo-static`          | `nginx:alpine`                    | 静的 HTML デモ           | `proxy_network` |
| `demo-todo`            | `node:20-alpine`                  | Todo SPA デモ            | `proxy_network` |

### 4.1 db (MariaDB 10.11 LTS)

* **理由**: MySQL 5.7 は 2023-10 で EOL。MariaDB 10.11 は LTS で 2028 まで保守、ARM ネイティブ (`platform: linux/amd64` 不要)、WordPress 完全互換。
* **データ**: `../app/wordpress/db_data_mariadb` を `/var/lib/mysql` に bind。旧 MySQL 5.7 データは `../app/wordpress/db_data` に温存し、必要時にダンプ → リストアで移行。
* **認証情報**: 全て `.env` 経由 (`MYSQL_ROOT_PASSWORD` / `MYSQL_PASSWORD`)、初期生成は 40 文字ランダム。
* **ヘルスチェック**: `healthcheck.sh --connect --innodb_initialized` を 10s 間隔。
* **ネットワーク**: `backend_network` のみ。

### 4.2 wordpress

* **イメージ**: `wordpress:6.7.2-php8.3-apache` (タグ固定、`:latest` 禁止)
* **WORDPRESS_CONFIG_EXTRA** で wp-config.php に注入する定数:
    - `DISALLOW_FILE_EDIT=true` (管理画面からのテーマ/プラグイン編集禁止)
    - `FORCE_SSL_ADMIN=true`
    - `WP_AUTO_UPDATE_CORE='minor'`
    - `WP_DEBUG=false` / `WP_DEBUG_DISPLAY=false`
    - 8 つの Salt / NONCE キーを `getenv()` 経由で注入 (`.env` で管理、生成手順は `.env.example` に記載)
    - `WP_REDIS_HOST` / `WP_REDIS_PORT` / `WP_REDIS_PASSWORD` / `WP_CACHE=true`
    - `HTTP_X_FORWARDED_PROTO=https` から `$_SERVER['HTTPS']='on'` を補正
    - `HTTP_X_FORWARDED_FOR` から `$_SERVER['REMOTE_ADDR']` を補正
* **PHP 設定**: `platform/php_conf/uploads.ini` を `/usr/local/etc/php/conf.d/uploads.ini` に bind (upload 64M / memory 256M / OPcache 256MB / `expose_php=Off` / session cookie hardening)
* **公開**: `ports:` は持たず `expose: ["80"]` のみ — Nginx 経由でのみ到達可能
* **ネットワーク**: `frontend_network` + `backend_network`

### 4.3 redis (Object Cache)

* `requirepass` + `maxmemory 256mb` + `allkeys-lru`、永続化なし (`appendonly no`、`save ""`)
* `read_only: true` + `tmpfs:/tmp` + `cap_drop: ALL` でハードニング
* WordPress 側は `Redis Object Cache` プラグイン (initial-setup.sh が自動インストール + `wp redis enable`)
* **ネットワーク**: `backend_network` のみ

### 4.4 nginx (ModSecurity + CRS)

* **イメージ**: `owasp/modsecurity-crs:nginx-alpine`
* **PARANOIA=1**, `ANOMALY_INBOUND=10` / `ANOMALY_OUTBOUND=5` を環境変数で設定
* **CRS 例外**: `nginx_data/modsec-rules/` の 2 ファイルを CRS のプレースホルダにファイル単位マウント
    - `REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf` — `/wp-json/tty/v1/` エンドポイント向け XSS/SQLi 検出除外 (`id:9500100`)
    - `RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf` — site-health / wp-json / update.php への OUTBOUND 例外

> **⚠️ CRS ルール ID の予約帯について**
> OWASP CRS は下記 ID 帯を各アプリ専用として使用している。カスタムルールはこれらと重複してはならない。
> - `9001xxx` : Drupal exclusions (`REQUEST-903.9001-DRUPAL-EXCLUSION-RULES.conf`)
> - `9002xxx` : WordPress exclusions (`REQUEST-903.9002-WORDPRESS-EXCLUSION-RULES.conf`)
> - `9003xxx` : Nextcloud, `9004xxx` : DokuWiki, `9005xxx` : cPanel, `9006xxx` : XenForo
>
> **独自ルールは `9500000+` 番台を使用すること** (例: 現在の `id:9500100`)。
> 重複すると nginx 起動時に `Rule id: XXXXXX is duplicated` エラーが発生しサービスが起動しない。

* **Nginx 公開設定 (`default.conf.template`)**:
    - 80 → 443 の 301 リダイレクト
    - HTTP/2 enabled, TLSv1.2/1.3, Mozilla intermediate cipher, OCSP stapling, `session_tickets off`
    - セキュリティヘッダ: HSTS / X-Content-Type-Options / X-Frame-Options / Referrer-Policy / Permissions-Policy
    - `xmlrpc.php` / `wp-config.php` / `.htaccess` / `.git` / `.env` / `wp-content/uploads/*.php` を deny
    - `/wp-json/wp/v2/users` を 401 (ユーザ列挙対策)
    - 静的アセットに `Cache-Control: public, immutable` + 30d expire
* **Cloudflare 連携**: `cloudflare-realip.conf` を同梱 (全 IPv4/IPv6 + `CF-Connecting-IP`)、`scripts/update-cloudflare-ips.sh` で月次更新可
* **ハードニング**: `cap_drop: ALL` + 最小限 `cap_add`、`security_opt: no-new-privileges`
* **公開ポート**: ホストの 80, 443 (内部 8080, 8443)
* **ネットワーク**: `frontend_network` (コア定義) + `proxy_network` (`docker-compose.demo.yml` オーバーライドで追加)

> **proxy_network の追加方法**: `docker-compose.demo.yml` の nginx サービスブロックに `networks: [proxy_network]` を追記するオーバーライドで実現している。`docker-compose.yml` 本体は変更しない。

### 4.5 certbot

* 初回発行は `docker compose run --rm certbot certonly ...` (手動 / 自動化スクリプト経由)
* 常駐ループは 12 時間毎に `certbot renew --webroot --webroot-path=/usr/share/nginx/html --quiet` を実行
* `nginx_data/certs` を `/etc/letsencrypt` に bind、`nginx_data/html` を ACME challenge 用に共有
* `cap_drop: ALL` + `security_opt: no-new-privileges`

### 4.6 phpmyadmin (profile=admin)

* 通常停止。`docker compose --profile admin up -d phpmyadmin` で必要時のみ起動
* ホストには `127.0.0.1:8888` でのみバインド → SSH トンネル経由でアクセス
* `cap_drop: ALL` + 最小限 `cap_add`、`backend_network` のみ

### 4.7 webalizer (profile=stats)

* 通常停止。実行時に `docker compose --profile stats run --rm webalizer webalizer /logs/access.log`
* 解析結果を `nginx_data/html` 配下に出力

### 4.8 wpcli (profile=cli)

* `wordpress:cli-2.10.0-php8.3` を `www-data` (uid 33) で実行
* `wordpress_data` ボリュームを共有し、本番 WP と同じ `wp-config.php` を使う
* `cap_drop: ALL` + `security_opt: no-new-privileges`
* `scripts/initial-setup.sh` がこのサービスを使って:
    1. `wp core install`
    2. `siteurl/home/timezone/locale`
    3. `wp rewrite structure '/%postname%/' --hard`
    4. `wp theme activate tty-portfolio`
    5. プラグインインストール + 有効化: `redis-cache` / `wps-hide-login` / `wordfence` / `wp-mail-smtp`
    6. `wp redis enable`
    7. `.env` の `SMTP_*` から `wp_mail_smtp` オプション自動構成
    8. `wp rewrite flush --hard`

### 4.9 uptime-kuma (profile=monitoring)

* セルフホスト外形監視。`127.0.0.1:3001` バインド + SSH トンネル運用
* HTTP/Ping/DNS/Docker など 30 種類のモニタを登録可。Slack/Discord/Email/Webhook 通知に対応
* データは名前付きボリューム `uptime_kuma_data`

## 5. ネットワーク

| ネットワーク | driver | internal | 接続サービス |
| --- | --- | --- | --- |
| `frontend_network`        | `bridge` | false       | `nginx`, `wordpress`, `(uptime-kuma)` |
| `backend_network`         | `bridge` | **true**    | `db`, `redis`, `wordpress`, `(phpmyadmin)`, `(wpcli)` |
| `proxy_network`           | `bridge` | false       | `nginx`(demo.yml), `demo-sales-api/web`, `demo-inventory-api/web`, `demo-static`, `demo-todo` |
| `demo_sales_backend`      | `bridge` | **true**    | `demo-sales-db`, `demo-sales-api`, `demo-sales-web` |
| `demo_inventory_backend`  | `bridge` | **true**    | `demo-inventory-db`, `demo-inventory-api`, `demo-inventory-web` |

**接続ルール:**
* `backend_network` は `internal: true` — DB/Redis は外部からも nginx からも直接到達不可。
* `proxy_network` は `docker-compose.demo.yml` で定義。nginx はこのネットワーク経由でデモコンテナに転送する。
* `wordpress` のみ `frontend_network` + `backend_network` の両方に属するブリッジ役。
* デモアプリの DB (`demo-*-db`) は `proxy_network` に接続しない (`internal: true` の専用ネットワークのみ) — nginx から直接到達不可。
* デモアプリを新規追加する際は **必ず `proxy_network` に接続**すること。接続し忘れると nginx 起動時に `host not found in upstream` エラーが発生する。

## 6. ボリュームと bind マウント

bind マウントは `platform/` を基準とした相対パス。名前付きボリュームは Docker 管理領域。

**コアサービス**

| ボリューム | 種別 | ホスト側 | コンテナ側 |
| --- | --- | --- | --- |
| `db_data` | bind | `../app/wordpress/db_data_mariadb` | `/var/lib/mysql` |
| `wordpress_data` | bind | `../app/wordpress/wordpress_data` | `/var/www/html` |
| `db_logs` | bind | `../app/log_data/db_logs` | `/var/log/mysql` |
| `wordpress_logs` | bind | `../app/log_data/wordpress_logs` | `/var/log/apache2` |
| `nginx_logs` | named | - | `/var/log/nginx` |
| `redis_data` | named | - | `/data` |
| `uptime_kuma_data` | named | - | `/app/data` |

nginx 個別 bind マウント:
- `./nginx_data/conf.d` → `/etc/nginx/conf.d` (実適用 conf / 自動生成ファイルも含む)
- `./nginx_data/certs` → `/etc/nginx/certs:ro`
- `./nginx_data/html` → `/usr/share/nginx/html` (ACME webroot)
- `./nginx_data/modsec-rules/REQUEST-900-*.conf` → `/etc/modsecurity.d/owasp-crs/rules/REQUEST-900-*.conf:ro`
- `./nginx_data/modsec-rules/RESPONSE-999-*.conf` → `/etc/modsecurity.d/owasp-crs/rules/RESPONSE-999-*.conf:ro`
- `./nginx_conf/conf.d/default.conf.template` → `/etc/nginx/templates/conf.d/default.conf.template:ro`

> `nginx_data/conf.d/` はコンテナ起動時の envsubst テンプレート展開先でもある。`modsecurity.conf` / `logging.conf` / `default.conf` はコンテナが自動生成するため、root で手動上書きしてはならない（Permission denied で起動不可になる）。

**デモアプリ**

| ボリューム | 種別 | ホスト側 | コンテナ側 |
| --- | --- | --- | --- |
| `demo_sales_db_data` | named | - | `/var/lib/postgresql/data` |
| `demo_inventory_db_data` | named | - | `/var/lib/mysql` |
| demo-static html | bind | `../app/demo-static` | `/usr/share/nginx/html:ro` |
| demo-todo app | bind | `../app/demo-todo` | `/app` |
| demo-inventory-api | bind | `../app/docker_inventory_management/app/backend` | `/var/www` |

## 7. シークレット管理

* 認証情報・ドメイン・SMTP 等は `platform/.env` に集約 (git 管理外)
* `platform/.env.example` がテンプレ、初回は `cp .env.example .env` から開始
* 含まれる変数: `PUBLIC_DOMAIN`, `LETSENCRYPT_EMAIL`, `MYSQL_*`, `WP_TABLE_PREFIX`, `WP_AUTH_KEY` 〜 `WP_NONCE_SALT` (8 個の Salt), `REDIS_PASSWORD`, `SMTP_*`, `PMA_*`, `*_MEM_LIMIT`
* Salt 再生成コマンドは `.env.example` のコメント内に同梱

## 8. ハードニング適用一覧

| 項目 | db | wordpress | redis | nginx | certbot | phpmyadmin | wpcli |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| `no-new-privileges` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `cap_drop: [ALL]` | - | - | ✓ | ✓ | ✓ | ✓ | ✓ |
| `read_only: true` | - | - | ✓ | - | - | - | - |
| ヘルスチェック | ✓ | ✓ | ✓ | ✓ | - | - | - |
| リソース制限 | ✓ | ✓ | ✓ | ✓ | - | - | - |
| ログローテーション (json-file) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| ホスト直公開 | ✗ | ✗ | ✗ | 80/443 | ✗ | 127.0.0.1:8888 | ✗ |

db / wordpress (Apache) は実行時に複数の書き込み先 (`/var/lib/mysql`, `/var/www/html`, `/var/run` 等) が必須で `read_only` は実用不可。

## 9. 自動化スクリプト

| スクリプト | 目的 | 推奨実行 |
| --- | --- | --- |
| [`scripts/initial-setup.sh`](../platform/scripts/initial-setup.sh) | 初回構築冪等。WP install / siteurl / theme / plugins / Redis / SMTP | 初回 + 構成変更時 |
| [`scripts/backup-db.sh`](../platform/scripts/backup-db.sh) | mariadb-dump → gzip → `BACKUP_KEEP_DAYS` で世代管理 | 日次 cron |
| [`scripts/update-cloudflare-ips.sh`](../platform/scripts/update-cloudflare-ips.sh) | CF IP レンジを公式 API から取得 → 差分があれば nginx reload | 月次 cron (CF 有効時のみ) |
| [`scripts/deploy.sh`](../platform/scripts/deploy.sh) | backup → fetch → checkout → pull → up → health check → 自動 rollback → prune | 本番 SSH 上 / GitHub Actions から |

## 10. CI / CD

[.github/workflows/ci.yml](../.github/workflows/ci.yml) — push / PR / 週次:
* `docker compose config` (base + 全 profile)
* `shellcheck` (`platform/scripts`)
* Trivy 脆弱性スキャン (CRITICAL+HIGH, ignore-unfixed) を 8 イメージに対して並列実行

[.github/workflows/deploy.yml](../.github/workflows/deploy.yml) — `workflow_dispatch`:
* `ref` / `skip_backup` を入力
* `concurrency: deploy` で同時実行禁止
* SSH 経由で `scripts/deploy.sh` を呼び出し、失敗時は本番側で自動ロールバック

必要な GitHub Secrets: `DEPLOY_HOST` / `DEPLOY_USER` / `DEPLOY_SSH_KEY` / `DEPLOY_PORT` / `REPO_PATH`

## 11. 同梱テーマ `tty-portfolio`

[`app/wordpress/wordpress_data/wp-content/themes/tty-portfolio/`](../app/wordpress/wordpress_data/wp-content/themes/tty-portfolio) — Terminal / Monospace Minimal なポートフォリオテーマ。

* CPT: `work` (+ `tech` タクソノミー)、Demo URL / Repo URL / Demo ボタンラベル / Role / Period のメタ
* セクション: Hero (ターミナル風カード) / About / Skills / Works / Blog / Contact
* カスタマイザー: Hero / About / Contact / SEO の 4 パネル
* **A11y**: skip-link / `:focus-visible` / aria-current / `prefers-reduced-motion`
* **Dark/Light**: `prefers-color-scheme` + ☾/☀ トグル (localStorage 永続化、FOUC 防止スクリプト同梱)
* **SEO**: OGP / Twitter Cards / JSON-LD `@graph` (WebSite + Person + Article/CreativeWork) / `wp-sitemap.xml` (WP 標準)
* **パフォーマンス**: emoji / dashicons 除去、ブロックスタイル条件付き dequeue、画像 lazy + async decode、JS `defer`、Google Fonts `display=swap` + preconnect
* ライセンス: MIT

## 12. デモアプリ構成 (docker-compose.demo.yml)

### 12.1 設計方針

* **メイン compose を一切変更しない** — nginx への `proxy_network` 追加も `docker-compose.demo.yml` 内の nginx オーバーライドで行う。
* **デモコンテナはホスト側ポートを公開しない** — `expose:` のみ。必ず Nginx (WAF) を経由する。
* **DB は専用の `internal: true` ネットワークで隔離** — `proxy_network` に接続しない。
* **SSL 証明書は必ず事前取得** — `nginx_data/conf.d/<name>.conf` を置く前に certbot で取得する。証明書が存在しないと nginx が起動しない。

### 12.2 ルーティング設計

```
URL                                        nginx upstream
─────────────────────────────────────────  ────────────────────────────────
https://makoto-kamimura.com/               wordpress:80
https://sales.makoto-kamimura.com/         demo-sales-web:3001
https://sales.makoto-kamimura.com/api      demo-sales-api:3000
https://inventory.makoto-kamimura.com/     demo-inventory-web:3001
https://inventory.makoto-kamimura.com/api  demo-inventory-api:8000
```

### 12.3 稼働中デモアプリ詳細

**sales.makoto-kamimura.com** ([doc/demo-apps-sales.md](./demo-apps-sales.md))

| レイヤ | サービス名 | 技術 | ポート |
|---|---|---|---|
| フロントエンド | `demo-sales-web` | Next.js | 3001 |
| API | `demo-sales-api` | Ruby on Rails | 3000 |
| DB | `demo-sales-db` | PostgreSQL + pgvector | — |

**inventory.makoto-kamimura.com** ([doc/demo-apps-inventory.md](./demo-apps-inventory.md))

| レイヤ | サービス名 | 技術 | ポート |
|---|---|---|---|
| フロントエンド | `demo-inventory-web` | Next.js | 3001 |
| API | `demo-inventory-api` | Laravel (PHP 8.x) | 8000 |
| DB | `demo-inventory-db` | MySQL 8.0 | — |

**その他**

| サービス | 技術 | 役割 |
|---|---|---|
| `demo-static` | nginx:alpine | 静的 HTML / LP サンプル |
| `demo-todo` | node:20-alpine | Todo SPA デモ |

### 12.4 コンテナ再作成が必要なケース

以下を変更した場合、**実行中コンテナには自動反映されない**。`docker compose up -d` でコンテナを再作成する必要がある:

| 変更内容 | 再作成が必要なサービス |
|---|---|
| `networks:` に新ネットワークを追加/削除 | そのサービス |
| `environment:` の変数追加/変更 | そのサービス |
| `volumes:` のマウント変更 | そのサービス |
| `image:` / `build:` の変更 | そのサービス + `--build` フラグ |

```bash
# 設定変更を反映（影響サービスのみ再作成）
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d
```

`docker compose restart` はプロセスを再起動するだけでネットワーク/ボリューム設定は変わらない。

## 14. 拡張ポイント

| やりたいこと | 着手箇所 |
| --- | --- |
| サブドメインで別アプリを公開 | [demo-apps.md](./demo-apps.md) の手順に従い `docker-compose.demo.yml` と `nginx_data/conf.d/` に追加 |
| Cloudflare 前段化 | `cloudflare-realip.conf` を `nginx_data/conf.d/` にコピー + `nginx -s reload` |
| 監視通知 | Uptime Kuma 管理画面で Slack/Discord webhook を登録 |
| CRS の誤検知抑制 | `nginx_data/modsec-rules/*.conf` に範囲限定 `ctl:` ルール追記 (**ID は 9500000+ 番台**を使用) |
| プラグイン一括更新 | `docker compose --profile cli run --rm wpcli wp plugin update --all` を週次 cron |
| 新サブドメイン証明書 | `certbot certonly --webroot` で取得後、nginx conf を配置し `nginx -s reload` |

## 15. 動作確認環境

* macOS Sequoia (Apple Silicon) — Docker Desktop 4.x
* Ubuntu 22.04 LTS / 24.04 LTS — Docker Engine 27.x
* WordPress 6.7.x + PHP 8.3 + MariaDB 10.11 + Redis 7.4 + Nginx (ModSec + CRS 4.x)
