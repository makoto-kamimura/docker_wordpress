# docker_wordpress

> Production-ready WordPress stack on Docker Compose — WAF, Redis, dark-mode portfolio theme, and one-command setup included.

[![CI](https://github.com/makoto-kamimura/docker_wordpress/actions/workflows/ci.yml/badge.svg)](https://github.com/makoto-kamimura/docker_wordpress/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Docker Compose v2](https://img.shields.io/badge/docker--compose-v2-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![WordPress 6.7](https://img.shields.io/badge/WordPress-6.7.2-21759B?logo=wordpress&logoColor=white)](https://wordpress.org/)
[![MariaDB 10.11 LTS](https://img.shields.io/badge/MariaDB-10.11_LTS-003545?logo=mariadb&logoColor=white)](https://mariadb.org/)
[![PHP 8.3](https://img.shields.io/badge/PHP-8.3-777BB4?logo=php&logoColor=white)](https://www.php.net/)
[![Redis 7](https://img.shields.io/badge/Redis-7.4-DC382D?logo=redis&logoColor=white)](https://redis.io/)
[![OWASP CRS](https://img.shields.io/badge/OWASP-ModSecurity_CRS-000000?logo=owasp&logoColor=white)](https://coreruleset.org/)

ポートフォリオ / 中規模ブログを **1 VM** で本番運用するために、よくある「とりあえず WordPress を Docker で動かしてみた」段階から、**WAF / シークレット分離 / ネットワーク二段分離 / 自動デプロイ / 監視** まで一通り入った状態にしたテンプレートです。同梱テーマ [`tty-portfolio`](./app/wordpress/wordpress_data/wp-content/themes/tty-portfolio/) は terminal / monospace minimal なポートフォリオ向け (Lighthouse 90+ / WCAG AA / dark mode / OGP + JSON-LD)。

## 🎯 何が入っているか

* **Reverse proxy + WAF** : Nginx + OWASP ModSecurity CRS (WordPress 用 exclusion 同梱)
* **Encrypted DB** : MariaDB 10.11 LTS (MySQL 5.7 EOL からの移行先)
* **Object cache** : Redis 7 with `requirepass`, read-only container
* **TLS** : Let's Encrypt + 自動更新ループ + TLSv1.2/1.3 + OCSP stapling + HSTS
* **Custom theme** : `tty-portfolio` (CPT `work` + Demo/Repo メタ + Customizer)
* **WP-CLI automation** : 初回セットアップ / プラグイン / Salt / SMTP を 1 コマンド
* **Backup** : `mariadb-dump` + gzip + 世代管理を cron 1 行で
* **Monitoring** : Uptime Kuma 同梱 (セルフホスト、SaaS アカウント不要)
* **Deploy** : `scripts/deploy.sh` + GitHub Actions `workflow_dispatch` で自動ロールバック付き
* **CI** : `docker compose config` / shellcheck / Trivy (8 イメージ脆弱性スキャン、週次)
* **Cloudflare ready** : `set_real_ip_from` の全レンジを同梱 + 月次 IP 更新スクリプト

## 🗂 構成サービス (9)

| サービス | イメージ | profile | 公開ポート |
| --- | --- | --- | --- |
| `db`         | `mariadb:10.11.13`                | 常駐         | 内部のみ            |
| `wordpress`  | `wordpress:6.7.2-php8.3-apache`   | 常駐         | 内部のみ            |
| `redis`      | `redis:7.4.2-alpine`              | 常駐         | 内部のみ            |
| `nginx`      | `owasp/modsecurity-crs:nginx-alpine` | 常駐      | **80 / 443**        |
| `certbot`    | `certbot/certbot:v2.11.0`         | 常駐         | -                   |
| `phpmyadmin` | `phpmyadmin/phpmyadmin:5.2.1`     | `admin`      | `127.0.0.1:8888`    |
| `webalizer`  | `toughiq/webalizer:latest`        | `stats`      | 内部のみ            |
| `wpcli`      | `wordpress:cli-2.10.0-php8.3`     | `cli`        | 内部のみ            |
| `uptime-kuma`| `louislam/uptime-kuma:1.23.13`    | `monitoring` | `127.0.0.1:3001`    |

外向きは **Nginx (443/80) だけ**。`db` / `redis` は `internal: true` の `backend_network` にのみ接続し、外部からも nginx からも直接到達不可。

## 🚀 クイックスタート (本番)

### 0. 前提

* Docker Engine 24+ または Docker Desktop 4.x (compose v2 同梱)
* GitHub から fork / clone 済み
* 公開ドメインの DNS A レコードを当サーバ IP に向けてある
* (任意) Cloudflare を前段に置くなら DNS は Cloudflare 経由で

### 1. シークレット設定

```bash
git clone https://github.com/makoto-kamimura/docker_wordpress.git
cd docker_wordpress/platform
cp .env.example .env
$EDITOR .env       # PUBLIC_DOMAIN / LETSENCRYPT_EMAIL / パスワード / Salt を埋める
```

`.env` には強パスワード生成コマンドのコメント付き。Salt キーは:

```bash
for k in WP_AUTH_KEY WP_SECURE_AUTH_KEY WP_LOGGED_IN_KEY WP_NONCE_KEY \
         WP_AUTH_SALT WP_SECURE_AUTH_SALT WP_LOGGED_IN_SALT WP_NONCE_SALT; do
  printf "%s=%s\n" "$k" "$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^*()_+=-' </dev/urandom | head -c 64)"
done
```

### 2. 証明書取得 → 起動

```bash
# ① ディレクトリ作成・権限設定 (初回のみ)
#    nginx コンテナ (uid=101) が conf.d へテンプレートを書き込めるよう準備
sudo ./scripts/init-dirs.sh

# ② ACME チャレンジ用に nginx を先に起動
sudo docker compose up -d nginx

# ③ Let's Encrypt 証明書を発行
#    --entrypoint="" で renew ループを無効にして certonly を直接実行
sudo docker compose run --rm --entrypoint="" certbot certbot certonly \
  --webroot \
  --webroot-path=/usr/share/nginx/html \
  --email "$(grep ^LETSENCRYPT_EMAIL .env | cut -d= -f2)" \
  --agree-tos --no-eff-email \
  -d "$(grep ^PUBLIC_DOMAIN .env | cut -d= -f2)"

# ④ 証明書を nginx コンテナ (uid=101) が読めるよう権限設定
#    certbot は root で証明書を作成するため chown が必要
sudo chown -R 101:101 nginx_data/certs/live nginx_data/certs/archive

# ⑤ 本番 Nginx 設定をドメインで実体化
sed "s/__DOMAIN__/$(grep ^PUBLIC_DOMAIN .env | cut -d= -f2)/g" \
  nginx_conf/conf.d/default.conf.public > nginx_data/conf.d/default.conf

# ⑥ 全サービス起動
sudo docker compose up -d
```

### 3. WordPress 初回構築 (wp-cli 自動化)

```bash
ADMIN_USER=yourname \
ADMIN_EMAIL=you@example.com \
./scripts/initial-setup.sh
```

これだけで:
- WordPress core install
- `siteurl/home/timezone/locale` 設定
- パーマリンク `/%postname%/`
- `tty-portfolio` テーマ有効化
- `redis-cache` / `wps-hide-login` / `wordfence` / `wp-mail-smtp` インストール + 有効化
- Redis Object Cache 有効化
- (`.env` に SMTP_* があれば) WP Mail SMTP 自動構成

`https://<your-domain>/wp-admin/` でログイン。

## 🛠 運用コマンド早見表

```bash
# サービス起動 / 停止
sudo docker compose up -d
sudo docker compose down

# 個別 profile
sudo docker compose --profile admin       up -d phpmyadmin   # 127.0.0.1:8888
sudo docker compose --profile monitoring  up -d uptime-kuma  # 127.0.0.1:3001
sudo docker compose --profile cli  run --rm wpcli wp plugin list

# DB バックアップ
./scripts/backup-db.sh                     # 即時
crontab -e   # 0 3 * * * /path/to/backup-db.sh

# デプロイ
REF=origin/main ./scripts/deploy.sh
# あるいは GitHub Actions の Run workflow から
```

詳細運用 (CDN 切替, SMTP, ログローテーション 等) は [doc/operation.md](doc/operation.md) を参照。

## 🎨 同梱テーマ tty-portfolio

[Terminal / monospace minimal なポートフォリオテーマ](./app/wordpress/wordpress_data/wp-content/themes/tty-portfolio/)。

* **Hero** : `$ whoami` 風のターミナルカード、ASCII プロンプト + 名前 + tagline + CTA
* **Sections** : Hero / About / Skills (progress bar) / Works / Blog / Contact
* **CPT** : `work` (Demo URL / Repository URL / ボタンラベル / Role / Period のメタ)
* **Customizer** : Hero / About / Contact / SEO の 4 セクション
* **Dark/Light** : 自動 + 手動トグル + localStorage、FOUC 防止
* **A11y** : skip-link / `:focus-visible` / aria-current / prefers-reduced-motion
* **SEO** : OGP / Twitter Cards / JSON-LD (WebSite + Person + Article + CreativeWork) / sitemap.xml
* **Perf** : emoji / dashicons 除去、ブロックスタイル条件付き dequeue、画像 lazy + async decode、JS `defer`

## 📁 ディレクトリ構成

```
docker_wordpress/
├── app/                                # 永続データ (DB / WP / ログ / デモアプリ)
│   └── wordpress/wordpress_data/wp-content/themes/tty-portfolio/
├── platform/                           # 基盤定義 (バージョン管理対象)
│   ├── docker-compose.yml              # 9 サービス + profile
│   ├── .env / .env.example             # 秘匿情報
│   ├── nginx_conf/conf.d/              # nginx テンプレ (.public / .local / cloudflare-realip)
│   ├── nginx_data/                     # 実行時マウント (証明書 / 適用済 conf / WAF rules)
│   ├── php_conf/uploads.ini            # PHP オーバーライド
│   └── scripts/
│       ├── init-dirs.sh            # 初回: ディレクトリ作成・権限設定
│       ├── backup-db.sh
│       ├── initial-setup.sh
│       ├── update-cloudflare-ips.sh
│       └── deploy.sh
├── .github/workflows/
│   ├── ci.yml                          # compose / shellcheck / Trivy
│   └── deploy.yml                      # workflow_dispatch (SSH 経由)
└── doc/
    ├── design.md                       # 仕様 (構成 / 各コンポーネント / ボリューム)
    ├── operation.md                    # 利用方法 (デプロイ / SSL / 運用 / セキュリティ)
    ├── task.md                         # 本番化チェックリスト (33/33 完了)
    └── demo-apps.md                    # サブドメインデモ追加手順
```

## 📚 ドキュメント

| | 内容 |
| --- | --- |
| **[doc/design.md](doc/design.md)** | アーキテクチャ図 / サービス仕様 / ネットワーク / ボリューム / シークレット / ハードニング / 自動化 |
| **[doc/operation.md](doc/operation.md)** | 初回デプロイ / SSL / MySQL→MariaDB 移行 / バックアップ / 監視 / SMTP / CDN / wp-cli / テーマ / デプロイ |
| **[doc/task.md](doc/task.md)** | 本番化チェックリスト (Critical 9 / High 12 / Medium 8 / Low 4) — 全 33 件完了 |
| **[doc/demo-apps.md](doc/demo-apps.md)** | サブドメインで別アプリ (静的 / Node 等) を Nginx + WAF 経由で公開する手順 |

## 🔒 セキュリティ設計のハイライト

* シークレットは `platform/.env` に集約 (`.gitignore` 済)
* WordPress / DB / Redis は **ホストにポートを開けない**。外部接点は Nginx の 443 のみ
* `backend_network` は `internal: true` で外部疎通不可
* OWASP CRS PARANOIA=1 + WordPress 用 exclusion 同梱 (admin-ajax / post.php / customize / wp-json / media-upload の誤検知を範囲限定で除外)
* nginx で `xmlrpc.php` / `wp-config.php` / `.git` / `.env` / `wp-content/uploads/*.php` を deny、`/wp-json/wp/v2/users` を 401 (ユーザ列挙対策)
* `WORDPRESS_CONFIG_EXTRA` で `DISALLOW_FILE_EDIT` / `FORCE_SSL_ADMIN` / `WP_AUTO_UPDATE_CORE='minor'` 注入
* Salt キーを `.env` から `getenv()` 経由で `wp-config.php` に注入 → ローテーション容易
* 全サービス `no-new-privileges:true`、Nginx / Redis / Certbot / phpMyAdmin / wpcli は `cap_drop: ALL`
* Redis は `read_only: true` + `tmpfs:/tmp`
* TLS: TLSv1.2/1.3、Mozilla intermediate cipher、OCSP stapling、`session_tickets off`、HSTS preload 可
* Container ログは json-file driver で `max-size=10m / max-file=5` に制限、bind マウントログは `logrotate` 設定例同梱
* Trivy で全イメージを週次脆弱性スキャン

## ❓ FAQ

**Q. なぜ MySQL 5.7 ではなく MariaDB 10.11 ?**
A. MySQL 5.7 は 2023-10 で EOL。MariaDB 10.11 は LTS で 2028 まで保守、`platform: linux/amd64` 不要 (ARM ネイティブ)、WordPress 完全互換。既存 MySQL 5.7 データからの移行手順は [operation.md §1.5](doc/operation.md) 参照。

**Q. 1 つの compose ファイルだとサービス多すぎでは ?**
A. profile で必要なものだけ起動できる構成です。最小構成は `db / wordpress / redis / nginx / certbot` の 5 サービス。phpMyAdmin と Uptime Kuma は普段停止、必要な時だけ `--profile admin` / `--profile monitoring` で立ち上げます。

**Q. デモアプリを追加したい**
A. [doc/demo-apps.md](doc/demo-apps.md) の手順で、サブドメインごとに別コンテナを `docker-compose.demo.yml` に追加し、Nginx (+ WAF) 経由で公開できます。ホスト側ポートは開けない設計。

**Q. Cloudflare を前段に置きたい**
A. `nginx_data/conf.d/cloudflare-realip.conf` をコピーして reload するだけ。全 IPv4/IPv6 レンジが同梱済で、`scripts/update-cloudflare-ips.sh` で月次更新可。`set_real_ip_from` + `CF-Connecting-IP` で `$remote_addr` が訪問者本来の IP になります。

**Q. ローカル開発はどうする ?**
A. `.env` の `PUBLIC_DOMAIN=localhost` にして、`nginx_conf/conf.d/default.conf.local`(自己署名証明書版) を `nginx_data/conf.d/default.conf` に配置すれば HTTPS でローカル動作します。詳細は [operation.md §2.2](doc/operation.md)。

## 🤝 Contributing

PR / Issue は GitHub Issues / Pull Requests へ。CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) で `docker compose config` + shellcheck + Trivy が走ります。

## 📝 License

[MIT](./LICENSE) — Makoto Kamimura
