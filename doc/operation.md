# 利用方法 (Operation)

WordPress 環境を立ち上げてから運用するまでの手順をまとめる。設計・各コンポーネントの仕様は [design.md](./design.md) を参照。本番化に残るタスク一覧は [task.md](./task.md) を参照。

> **前提**: 以降のコマンドは原則として `platform/` ディレクトリで実行する。
> `cd ./docker_wordpress/platform/` した状態を想定する。

## 0. アーキテクチャ概要 (2026 以降)

```
[Internet] --443/80--> nginx (modsecurity + frontend_network)
                          │
                          ├── 静的/動的 proxy → wordpress (frontend_network + backend_network)
                          │                                       │
                          │                                       └─ MariaDB 10.11 (backend_network: internal)
                          │
                          └── /.well-known/acme-challenge → nginx_data/html (Certbot 共有)
```

- WordPress / DB はホストにポート公開していない (Nginx 経由のみ)。
- `backend_network` は `internal: true` で外部疎通不可。
- 認証情報は `platform/.env` に集約 (git 管理外、[.env.example](../platform/.env.example) がテンプレ)。

## 1. 初回デプロイ

```bash
git clone https://github.com/makoto-kamimura/docker_wordpress.git
cd ./docker_wordpress/platform/

# 1) シークレットを用意
cp .env.example .env
vi .env                       # PUBLIC_DOMAIN / パスワード等を書き換え

# 2) Nginx 公開設定をドメインで実体化
sed "s/__DOMAIN__/$(grep '^PUBLIC_DOMAIN=' .env | cut -d= -f2)/g" \
    ./nginx_conf/conf.d/default.conf.public \
  > ./nginx_data/conf.d/default.conf

# 3) Let's Encrypt 証明書を初回発行 (DNS が当サーバを向いていること)
sudo docker compose up -d nginx           # ACME チャレンジ受付のため Nginx を先に起動
sudo docker compose run --rm certbot \
  certonly --webroot --webroot-path=/usr/share/nginx/html \
  --email "$(grep '^LETSENCRYPT_EMAIL=' .env | cut -d= -f2)" \
  --agree-tos --no-eff-email \
  -d "$(grep '^PUBLIC_DOMAIN=' .env | cut -d= -f2)"

# 4) 本起動
sudo docker compose up -d
sudo docker compose exec nginx nginx -s reload
```

ブラウザで `https://<PUBLIC_DOMAIN>/` にアクセスし WordPress 初期設定を行う。
完了後、[セキュリティ強化](#5-セキュリティ強化) と [task.md](./task.md) 残項目を順次対応。

## 1.5 MySQL 5.7 → MariaDB 10.11 移行 (既存データ保持の場合)

新 `docker-compose.yml` は `../app/wordpress/db_data_mariadb/` を新規データディレクトリとして使う。旧 `db_data/` (MySQL 5.7 InnoDB) はそのまま温存される。

```bash
# 1) 旧 MySQL 5.7 を一時的に起動してダンプを取得
docker run --rm \
  -v "$(pwd)/../app/wordpress/db_data:/var/lib/mysql" \
  --platform linux/amd64 \
  -e MYSQL_ROOT_PASSWORD=somewordpress \
  -d --name wp_mysql57_export mysql:5.7
sleep 20
docker exec wp_mysql57_export \
  mysqldump -uroot -psomewordpress --single-transaction --routines --triggers \
            --default-character-set=utf8mb4 wordpress > /tmp/wp_dump.sql
docker stop wp_mysql57_export

# 2) 新 MariaDB を起動
docker compose up -d db
sleep 30

# 3) ダンプを流し込む (.env の MYSQL_ROOT_PASSWORD で)
docker compose exec -T db \
  sh -c 'exec mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${MARIADB_DATABASE}"' \
  < /tmp/wp_dump.sql

# 4) siteurl / home を新ドメインに更新 (必要なら)
docker compose exec -T db \
  sh -c 'exec mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${MARIADB_DATABASE}"' <<SQL
UPDATE ${WP_TABLE_PREFIX:-wp_}options
   SET option_value='https://<PUBLIC_DOMAIN>'
 WHERE option_name IN ('siteurl','home');
SQL

# 5) 動作確認後、旧データを退避
mv ../app/wordpress/db_data ../app/wordpress/db_data.mysql57.bak
```

> 完全に切り捨てて新規構築する場合は `db_data_mariadb/` が空のまま `docker compose up -d` で WordPress 初期セットアップから始まる。

## 2. SSL/TLS 設定

### 2.1 公開環境 (Let's Encrypt)

[§1 初回デプロイ](#1-初回デプロイ) のステップ 2〜4 に統合済み。
証明書の自動更新は `certbot` コンテナが 12 時間ごとに `certbot renew --webroot` を実行する常駐ループで処理する。

サブドメインを追加する場合は [§7 デモアプリ](#7-デモアプリ-works-の追加) 参照。

### 2.2 ローカル環境 (自己署名証明書)

```bash
# 1. プライベートキー発行
openssl genpkey -algorithm RSA -out ./nginx_data/certs/privkey.pem -pkeyopt rsa_keygen_bits:2048

# 2. CSR 作成 (Common Name には localhost と入力)
openssl req -new -key ./nginx_data/certs/privkey.pem -out ./nginx_data/certs/cert.csr

# 3. 自己署名証明書発行
openssl x509 -req -days 365 \
  -in ./nginx_data/certs/cert.csr \
  -signkey ./nginx_data/certs/privkey.pem \
  -out ./nginx_data/certs/fullchain.pem

# 4. ローカル用 default.conf を配置
cp ./nginx_conf/conf.d/default.conf.local ./nginx_data/conf.d/default.conf

# 5. 反映
docker compose down && docker compose up -d
```

## 3. ログ確認

リバースプロキシのログ:
```bash
tail -f ./log_data/nginx_logs/access.log
tail -f ./log_data/nginx_logs/error.log
```

WordPress (Apache) のログ:
```bash
tail -f ../app/log_data/wordpress_logs/access.log
tail -f ../app/log_data/wordpress_logs/error.log
tail -f ../app/log_data/wordpress_logs/other_vhosts_access.log
```

DB のログ:
```bash
ls ../app/log_data/db_logs/
```

## 4. アクセスログ解析

### 4.1 Webalizer (同梱)

```bash
sudo docker compose exec webalizer webalizer /logs/access.log
```
解析結果は `nginx_data/html` 配下に出力される。

### 4.2 WordPress プラグイン (任意)

- Google Analytics
- Jetpack
- WP Statistics

## 5. セキュリティ強化

### 5.1 メンテナンスモード

a. `functions.php` で実装:
```php
function maintenance_mode() {
    if (!current_user_can('edit_themes') || !is_user_logged_in()) {
        wp_die('当サイトはメンテナンス中です。');
    }
}
add_action('get_header', 'maintenance_mode');
```

b. プラグイン: [LightStart – Maintenance Mode](https://ja.wordpress.org/plugins/wp-maintenance-mode/)

### 5.2 管理画面 URL の変更

> 設定した URL が新しい管理画面 URL になる。忘れるとログイン不可になるので注意。

a. `.htaccess` を編集:
```
<Files wp-login.php>
order deny,allow
deny from all
allow from xx.xx.xx.xx
</Files>
```

b. プラグイン: [WPS Hide Login](https://wordpress.org/plugins/wps-hide-login/)

### 5.3 基本認証の追加

> 認証を設定したページは検索エンジンにインデックスされなくなるので注意。

1. `.htpasswd` 作成
    - [パスワード生成ツール](https://www.luft.co.jp/cgi/htpasswd.php) などで生成
    - 例: `/home/username/.htpasswd` に配置
2. `wp-admin/.htaccess` を作成:
    ```
    AuthName "Restricted Area"
    AuthType Basic
    AuthUserFile /path/to/.htpasswd
    require valid-user
    ```

### 5.4 ログイン試行回数の制限

- プラグイン: [Wordfence Security](https://www.wordfence.com/) (自動更新有効化を推奨)

## 6. メンテナンスコマンド

| 目的 | コマンド |
| --- | --- |
| 全サービス起動 | `sudo docker compose up -d` |
| 全サービス停止 | `sudo docker compose down` |
| ボリュームごと初期化 | `sudo docker compose down -v` |
| 個別再起動 (例: nginx) | `sudo docker compose restart nginx` |
| Nginx 設定リロード | `sudo docker compose exec nginx nginx -s reload` |
| ログ追跡 | `sudo docker compose logs -f <service>` |
| シェル接続 (例: certbot) | `sudo docker compose exec certbot sh` |

## 7. デモアプリ (Works) の追加

ポートフォリオの `Works` から実稼働コンテナへリンクするための運用手順。設計の全体像と背景は [demo-apps.md](./demo-apps.md) を参照。

> **方針**: デモアプリは別コンテナ・サブドメインで公開し、ホスト側ポートは開けず、必ず Nginx (+ ModSecurity) を経由させる。

### 7.1 初回セットアップ (1 回だけ)

```bash
cd platform/
cp docker-compose.demo.yml.template docker-compose.demo.yml
```

毎回 `-f` 指定が面倒なら環境変数で固定:
```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.demo.yml
```

### 7.2 サブドメインの準備 (DNS / ワイルドカード証明書)

デモアプリは個別サブドメイン (`todo.example.com`, `lp.example.com` …) で公開する。最初のデモを追加する前に DNS と証明書方針を決めておく。

#### 7.2.1 DNS の設計

|              | A レコードを個別に作る                                        | ワイルドカード A レコード                                |
| ------------ | ------------------------------------------------------------- | -------------------------------------------------------- |
| レコード     | `todo.example.com A xx.xx.xx.xx` を毎回追加                   | `*.example.com A xx.xx.xx.xx` を 1 つ                    |
| 増設の手間   | 1 サブドメインごとに DNS 設定が必要                           | DNS は最初の 1 回のみ                                    |
| 証明書       | HTTP-01 (`certbot --webroot`) でサブドメインごとに発行可能   | DNS-01 + ワイルドカード証明書が必要                     |
| 推奨         | 公開するデモが固定で数個 (~5)                                 | デモを頻繁に増減する場合                                 |

> ルートドメイン (`example.com` → WordPress) は別に A レコードが必要。

#### 7.2.2 個別 A レコード方式の証明書発行

サブドメインごとに HTTP-01 で発行する。DNS が当サーバを向いていることを `dig todo.<取得したドメイン>` で確認した上で:

```bash
sudo docker compose run --rm certbot certonly --webroot \
  --webroot-path=/usr/share/nginx/html \
  -d todo.<取得したドメイン>
```

複数まとめて `-d` を並べることも可能:
```bash
sudo docker compose run --rm certbot certonly --webroot \
  --webroot-path=/usr/share/nginx/html \
  -d todo.<取得したドメイン> -d lp.<取得したドメイン>
```

成功すると `nginx_data/certs/live/<サブドメイン>/{fullchain,privkey}.pem` に格納される。
更新は同梱 certbot コンテナが 6 時間ごとに `certbot renew` を実行するので自動。

#### 7.2.3 ワイルドカード証明書方式 (DNS-01)

> DNS-01 はサーバから DNS API を叩いて TXT レコードを書く必要がある。DNS プロバイダ対応の certbot プラグインを入れるか、手動 (`--manual`) で実施する。

**手動の場合 (簡易):**
```bash
sudo docker compose run --rm certbot certonly --manual \
  --preferred-challenges=dns \
  -d "*.<取得したドメイン>" -d "<取得したドメイン>"
```
表示された TXT レコードを DNS に登録 → `dig _acme-challenge.<取得したドメイン> TXT` で伝播確認 → Enter で続行。
証明書は `nginx_data/certs/live/<ドメイン>/{fullchain,privkey}.pem` に格納される (ワイルドカード 1 枚で全サブドメインをカバー)。

> **注意**: `--manual` モードは自動更新できない。本番でワイルドカードを使う場合は DNS プロバイダ用プラグイン (`certbot-dns-route53`, `certbot-dns-cloudflare` 等) を入れた certbot イメージに差し替える。

#### 7.2.4 Nginx テンプレートの選択

[7.3](#73-デモアプリを-1-つ追加する) で使う `demo-app.conf.template` は、デフォルトで以下のパスを参照している:
```
/etc/nginx/certs/live/__SUBDOMAIN__/fullchain.pem
/etc/nginx/certs/live/__SUBDOMAIN__/privkey.pem
```

* 個別 A レコード方式 → そのまま `__SUBDOMAIN__` をサブドメイン FQDN に置換すれば一致する。
* ワイルドカード方式   → 全サブドメインで同じ証明書を参照する。テンプレ内の `ssl_certificate` パスを `/etc/nginx/certs/live/<ベースドメイン>/...` に書き換えて使う。

#### 7.2.5 サブドメイン一覧の確認

```bash
# 現在 Nginx に登録されているサブドメイン
grep -hE '^\s*server_name ' ./nginx_data/conf.d/*.conf | awk '{print $2}' | sed 's/;//' | sort -u

# 取得済み証明書の一覧
ls ./nginx_data/certs/live/
```

#### 7.2.6 Nginx 全体の有効性確認

新しい `*.conf` を置いた後、reload する前に構文チェックする:
```bash
sudo docker compose exec nginx nginx -t
```

`syntax is ok` / `test is successful` を確認してから `nginx -s reload`。

### 7.3 デモアプリを 1 つ追加する

例: TODO アプリを `todo.<取得したドメイン>` で公開する。

1. **アプリのソース配置**
    ```bash
    mkdir -p ../app/demo-todo
    # Dockerfile / ソースを ../app/demo-todo/ に置く
    ```

2. **`docker-compose.demo.yml` にサービスを追記**

    `demo-todo` ブロックを編集して `image:` / `command:` / `expose:` を実装に合わせる。
    **`ports:` は書かない** (ホストにポートを開けない=必ず Nginx 経由にする)。

3. **Nginx 用サブドメイン設定を生成**

    公開環境 (Let's Encrypt):
    ```bash
    cp ./nginx_conf/conf.d/demo-app.conf.template ./nginx_data/conf.d/todo.conf
    sudo vi ./nginx_data/conf.d/todo.conf
    ```
    vim 内で:
    ```
    :%s/__SUBDOMAIN__/todo.<取得したドメイン>/g
    :%s/__SERVICE__/demo-todo/g
    :%s/__PORT__/3000/g
    :wq
    ```

    ローカル検証 (HTTP のみ):
    ```bash
    cp ./nginx_conf/conf.d/demo-app.conf.local.template ./nginx_data/conf.d/todo.local.conf
    sudo vi ./nginx_data/conf.d/todo.local.conf
    # :%s/__SUBDOMAIN__/todo.localhost/g など
    ```
    `*.localhost` は多くの OS で 127.0.0.1 に解決される。されない場合は `/etc/hosts` に `127.0.0.1 todo.localhost` を追記。

4. **証明書発行** (公開環境のみ)

    DNS で `todo.<取得したドメイン>` が当サーバを指していることを確認した上で:
    ```bash
    sudo docker compose run --rm certbot certonly --webroot \
      --webroot-path=/usr/share/nginx/html \
      -d todo.<取得したドメイン>
    ```

5. **起動と反映**
    ```bash
    sudo docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d demo-todo
    sudo docker compose restart nginx
    # もしくは
    sudo docker compose exec nginx nginx -s reload
    ```

6. **WordPress (Works) にリンクを登録**

    `wp-admin > Works > 新規追加` → サイドの **Demo / Repository** ボックスで:
    - `Demo URL` … `https://todo.<取得したドメイン>/`
    - `Demo ボタンラベル` … 任意 (空ならデフォルト `Open live demo →`)
    - `Repository URL` … 任意

    公開すると Works カード/作品詳細ページに **● Open live demo →** ボタンが表示される。

### 7.4 動作確認

```bash
# サービスが起動しているか
sudo docker compose -f docker-compose.yml -f docker-compose.demo.yml ps

# Nginx から内部疎通 (200 が返れば OK)
sudo docker compose exec nginx \
  curl -sS -o /dev/null -w "%{http_code}\n" http://demo-todo:3000/

# 外部から HTTPS 疎通
curl -sS -o /dev/null -w "%{http_code}\n" https://todo.<取得したドメイン>/
```

### 7.4 デモアプリの削除

```bash
sudo docker compose -f docker-compose.yml -f docker-compose.demo.yml stop demo-todo
sudo docker compose -f docker-compose.yml -f docker-compose.demo.yml rm -f demo-todo
sudo rm ./nginx_data/conf.d/todo.conf
sudo docker compose restart nginx
# 必要なら証明書も削除
sudo docker compose run --rm certbot delete --cert-name todo.<取得したドメイン>
```

WordPress 側は対象 Work を `ゴミ箱` へ。

### 7.5 注意点

| 項目 | 内容 |
| --- | --- |
| ポート公開 | デモコンテナは `ports:` を書かない。ホスト側に穴が開き Nginx (WAF) を回避する経路ができてしまう。 |
| ネットワーク名 | `docker-compose.demo.yml` は `external: docker_wordpress_proxy_network` を参照している。compose プロジェクト名 (`docker_wordpress`) と一致させること。 |
| ModSecurity | サブドメインにも CRS が適用される。デモアプリで誤検知が出る場合は `nginx_data/modsec-rules/` でルールを調整。 |
| 証明書 | 1 サブドメイン 1 証明書。ワイルドカード証明書を使う場合は DNS-01 チャレンジに切り替える。 |

## 8. バックアップ運用

### 8.1 対象

| 対象 | 頻度 | 方法 |
| --- | --- | --- |
| DB (MariaDB) | 日次 | `platform/scripts/backup-db.sh` で `mariadb-dump` を gzip 圧縮 |
| `app/wordpress/wordpress_data/wp-content/` | 日次 | `rsync` で別ホスト/S3 |
| `app/demo-*/` | 変更時 | git or rsync |
| `platform/nginx_data/certs/` | 更新時 | `cp -a` でローテーション保管 |
| `platform/nginx_data/conf.d/`, `platform/.env` | 変更時 | 暗号化して別ストレージへ |

### 8.2 DB バックアップ (同梱スクリプト)

```bash
# 即時実行
./platform/scripts/backup-db.sh

# cron 例 (毎日 03:00, 保管先と保持期間は環境変数で上書き可)
0 3 * * * BACKUP_DIR=/var/backups/wp \
          BACKUP_KEEP_DAYS=30 \
          /path/to/docker_wordpress/platform/scripts/backup-db.sh \
          >> /var/log/wp_backup.log 2>&1
```

リストア:

```bash
gunzip -c db_YYYYMMDD_HHMMSS.sql.gz | \
  docker compose exec -T db sh -c \
    'exec mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${MARIADB_DATABASE}"'
```

> 四半期に 1 回はステージング環境で復元演習を実施し、リストア手順が動くことを検証する。

### 8.3 ログローテーション

Docker のコンテナログ (`docker logs`) は `docker-compose.yml` の `logging.options` で `max-size=10m / max-file=5` に制限済み。
一方、bind マウントされている以下のログは Docker 側のローテーション対象外なので、ホスト側 `logrotate` を設定する:

- `platform/log_data/nginx_logs/*.log`
- `app/log_data/wordpress_logs/*.log`
- `app/log_data/db_logs/*.log` (MariaDB の slow / error)

`/etc/logrotate.d/docker_wordpress` 例:

```
/path/to/docker_wordpress/platform/log_data/nginx_logs/*.log
/path/to/docker_wordpress/app/log_data/wordpress_logs/*.log
{
    daily
    rotate 14
    compress
    missingok
    notifempty
    sharedscripts
    postrotate
        docker compose -f /path/to/docker_wordpress/platform/docker-compose.yml \
          kill -s USR1 nginx wordpress 2>/dev/null || true
    endscript
}
```

## 9. オブジェクトキャッシュ (Redis)

`docker-compose.yml` には Redis 7 のサービスを同梱しており、`backend_network` 内 (`internal: true`) でのみ到達可能。
`WORDPRESS_CONFIG_EXTRA` 経由で `WP_REDIS_HOST` / `WP_REDIS_PORT` / `WP_REDIS_PASSWORD` を渡してあるので、WordPress 側は以下の手順で有効化:

```bash
# 1) Redis Object Cache プラグインを導入 (wp-admin > プラグイン > 新規追加 > "Redis Object Cache")
# 2) 設定ページから "Enable Object Cache" をクリック
# 3) 動作確認 (PHP)
sudo docker compose exec wordpress \
  php -r "var_dump(defined('WP_REDIS_HOST'), WP_REDIS_HOST);"
```

Redis 自身は `requirepass` 必須・`maxmemory 256mb` で `allkeys-lru` 動作。永続化は無効 (`appendonly no`) なのでキャッシュ用途のみ。
キャッシュをクリアしたい時:

```bash
sudo docker compose exec redis redis-cli -a "$REDIS_PASSWORD" FLUSHDB
```

## 10. 監視 / アラート

### 10.1 同梱の Uptime Kuma (推奨, セルフホスト)

`docker-compose.yml` には [Uptime Kuma](https://github.com/louislam/uptime-kuma) を profile=monitoring で同梱。127.0.0.1:3001 のみにバインドされ、SSH トンネル経由で管理する。

```bash
# 起動
sudo docker compose --profile monitoring up -d uptime-kuma

# 管理画面へアクセス (ローカルマシンから)
ssh -L 3001:127.0.0.1:3001 deployer@${PUBLIC_DOMAIN}
# ブラウザで http://127.0.0.1:3001/
```

初回アクセスで管理者ユーザ作成。HTTP(s) / Ping / DNS / Docker / Steam など 30 種類のモニタを登録できる。Slack / Discord / Email / Telegram / Webhook で通知も可能。

### 10.2 その他のツール (SaaS)

| レイヤ | 推奨ツール (無料寄り) | 推奨ツール (有償) |
| --- | --- | --- |
| 外形監視 (HTTPS 200) | UptimeRobot / Better Stack | Pingdom / Datadog Synthetics |
| 証明書期限監視 | `certbot certificates` を cron + Slack webhook | New Relic Synthetics |
| ホスト/コンテナメトリクス | Prometheus + Node Exporter + cAdvisor + Grafana | Datadog Agent / New Relic |
| ログ集約 | Grafana Loki + Promtail | Datadog Logs / Sumo Logic |
| WAF (ModSecurity) ログ | Loki に `modsec_audit.log` を集約 | Splunk |

最低限の外形監視は外部の SaaS に任せ、内側のメトリクスは将来必要になった時点で導入する流れで充分。

簡易ヘルスチェック cron 例 (失敗時に Slack 通知):

```bash
*/5 * * * * curl -fsS -o /dev/null https://makoto-kamimura.com/healthz || \
  curl -sS -X POST -H 'Content-Type: application/json' \
       -d '{"text":":fire: makoto-kamimura.com healthcheck FAILED"}' \
       "$SLACK_WEBHOOK_URL"
```

## 11. メール送信 (SMTP)

WordPress 標準の `mail()` は本番ではほぼ確実に届かない (送信元 IP が SPF/DKIM 未整備のため)。
本リポジトリにはメール用コンテナを含めない。以下のいずれかを採用:

| 方式 | 構成 | コスト |
| --- | --- | --- |
| Amazon SES | リレー先 SMTP として接続 | $0.10 / 1k 通 |
| SendGrid | API/SMTP どちらも可 | 100通/日 無料、以上は有料 |
| Mailgun | SMTP | 試用枠あり |
| 自前 Postfix | 別コンテナで Postfix + DKIM | 運用工数 大 |

設定手順 (SES 例):

1. AWS で SES の SMTP 認証情報を発行 (リージョン: ap-northeast-1)
2. SPF / DKIM レコードを DNS に追加し、ドメイン認証 (verified) を完了
3. `WP Mail SMTP` プラグインを WordPress に導入
    - Mailer: Other SMTP
    - Host: `email-smtp.ap-northeast-1.amazonaws.com`
    - Port: 587 (TLS)
    - Encryption: TLS
    - Auth: ON、SMTP Username / Password を入力
4. 送信元アドレスは認証済ドメインの `no-reply@makoto-kamimura.com` 等
5. 送信テスト (`WP Mail SMTP > Email Test`) を実行

### 11.1 自動セットアップ統合

`platform/.env` に SMTP_* を埋めた状態で `scripts/initial-setup.sh` を実行すると、WP Mail SMTP の `wp_mail_smtp` オプションを自動構成する (host / port / encryption / auth / user / pass / from_email / from_name)。空の場合はスキップ。

```env
SMTP_HOST=email-smtp.ap-northeast-1.amazonaws.com
SMTP_PORT=587
SMTP_ENCRYPTION=tls
SMTP_AUTH=1
SMTP_USER=AKIA...
SMTP_PASS=...
SMTP_FROM_EMAIL=no-reply@makoto-kamimura.com
SMTP_FROM_NAME=Makoto Kamimura
```

cutover 後にテスト送信:

```bash
docker compose --profile cli run --rm wpcli \
  wp eval 'wp_mail("test@example.com","ping","hello from $(hostname)");'
```

## 12. CDN / DDoS 緩和

本構成は単一 VM での Nginx 終端を想定しており、L7 DDoS にはほぼ無力。前段に CDN を置くことを強く推奨:

| CDN | 主機能 | コスト |
| --- | --- | --- |
| Cloudflare (Free) | L7 DDoS, 基本 WAF, キャッシュ, Bot Fight Mode | $0 |
| Cloudflare (Pro) | より細かい WAF / ページルール | $25/月 |
| Amazon CloudFront + WAF | カスタム WAF | 従量制 |

Cloudflare (Free) を使う場合の最短手順:

1. Cloudflare に `makoto-kamimura.com` をネームサーバ移管
2. DNS A レコードを当サーバ IP に向け、Proxy を **オレンジ (有効)** にする
3. SSL/TLS モード: **Full (Strict)** (Let's Encrypt が当サーバに残ったまま)
4. "Always Use HTTPS" を有効化
5. (任意) "Bot Fight Mode" / "Rate Limiting" / "Page Rules" でログイン画面に厳しめのレートリミット

### 12.1 Nginx real_ip 補正 (同梱)

`platform/nginx_conf/conf.d/cloudflare-realip.conf` に Cloudflare の全 IPv4/IPv6 レンジを `set_real_ip_from` 形式で同梱済 + `CF-Connecting-IP` を `real_ip_header` に指定済。

```bash
# Cloudflare 有効化時に反映
sudo cp ./nginx_conf/conf.d/cloudflare-realip.conf ./nginx_data/conf.d/
sudo docker compose exec nginx nginx -t \
  && sudo docker compose exec nginx nginx -s reload
```

IP レンジの自動更新スクリプトも同梱 (`./scripts/update-cloudflare-ips.sh`)。月次 cron で:

```cron
0 5 1 * * /path/to/platform/scripts/update-cloudflare-ips.sh \
          >> /var/log/cf_ip_update.log 2>&1
```

## 13. テーマ (tty-portfolio)

リポジトリ同梱の `app/wordpress/wordpress_data/wp-content/themes/tty-portfolio/` がデフォルトテーマ。

- **コンセプト**: Terminal / Monospace Minimal — `$ whoami` 風の Hero、`// works` のような見出し、`[ open works → ]` 風ボタン
- **カラー**: ダーク既定 (`#0d1117`) + ライト (`#fafaf7`) を `prefers-color-scheme` で自動切替、ヘッダの ☾/☀ トグルで手動切替 (localStorage 永続化)
- **CPT**: `work` (+ `tech` タクソノミー)、Demo URL / Repo URL / Demo ボタンラベル / Role / Period のメタ
- **A11y**: skip-link、`:focus-visible`、ARIA 属性、`prefers-reduced-motion` 対応
- **SEO**: OGP / Twitter Cards / JSON-LD (WebSite + Person + Article + CreativeWork)、`wp-sitemap.xml` (WP 標準)
- **パフォーマンス**: Google Fonts `display=swap` + `preconnect`、絵文字スクリプト除去、Gutenberg ブロックスタイルの条件付き dequeue、画像 `loading=lazy` + `decoding=async`、JS は `defer`

### 13.1 カスタマイズ箇所

外観 > カスタマイズ > 以下のセクション:

| セクション | 設定項目 |
| --- | --- |
| tty-portfolio: Hero | `whoami` コマンド / 表示名 / タグライン / CTA × 2 |
| tty-portfolio: About / Skills | About 本文 (HTML 可) / Skills `name:level` (1 行 1 件、`level=0-100`) |
| tty-portfolio: Contact | Email / GitHub / X / LinkedIn / Resume PDF URL |
| tty-portfolio: SEO / OGP | 既定 OG 画像 (1200×630) / X handle (`@xxx`) |

### 13.2 Works の登録

1. 管理画面 > Works > 新規追加
2. 本文に説明、アイキャッチに代表画像、サイドの **Demo / Repository** ボックスに以下を入力:
   - Demo URL: `https://demo.example.com/`
   - Demo button label: `Open live demo` (空ならデフォルト)
   - Repository URL: `https://github.com/...`
   - Role / Period: 担当範囲と期間
3. Tech Stack (技術タグ) を選択
4. 公開すると Works カード / Work 詳細ページに **● Open live demo →** ボタンが表示

## 14. wp-cli (自動化)

`docker-compose.yml` には `wpcli` サービス (profile=cli) を同梱。WordPress と同じ wordpress_data ボリュームを共有する。

```bash
# 任意の wp サブコマンド
docker compose --profile cli run --rm wpcli wp plugin list
docker compose --profile cli run --rm wpcli wp post list --post_type=work
docker compose --profile cli run --rm wpcli wp redis status
```

### 14.1 一括初期セットアップ

`platform/scripts/initial-setup.sh` が次を冪等に実行する:

1. `wp core install` (未インストール時のみ。パスワード未指定なら 24 文字ランダム生成)
2. `siteurl` / `home` を `https://${PUBLIC_DOMAIN}` に統一
3. 言語パック (`ja`) のインストール + 有効化、タイムゾーン `Asia/Tokyo`
4. パーマリンク `/%postname%/`
5. `tty-portfolio` テーマ有効化
6. プラグインインストール + 有効化: `redis-cache` / `wps-hide-login` / `wordfence` / `wp-mail-smtp`
7. `wp redis enable` で Object Cache を有効化
8. `wp rewrite flush --hard`

```bash
cd platform

# パスワードを指定するパターン (推奨)
ADMIN_USER=mkk \
ADMIN_PASS='Strong!Password#With-32-chars-or-more' \
ADMIN_EMAIL=m.kamimura.apple@gmail.com \
./scripts/initial-setup.sh

# .env の値だけで全部 (パスワードは自動生成され、コンソールに 1 回だけ表示される)
./scripts/initial-setup.sh
```

> 既にインストール済の環境では `wp core is-installed` で検出してスキップする。何度実行しても安全。

## 15. デプロイフロー (推奨)

本リポジトリにはデプロイ自動化は含まないが、本番運用では以下が一般的:

```
[ローカル] ─push→ [GitHub] ─PR/merge→ [main] ─SSH→ [本番 VM]
```

最小構成 (手動 SSH):

```bash
ssh deployer@makoto-kamimura.com
cd /srv/docker_wordpress
git fetch origin && git checkout origin/main
cd platform
docker compose pull
docker compose up -d --remove-orphans
docker compose ps          # ヘルスチェック確認
docker image prune -f
```

### 15.1 同梱の deploy.sh (本番サーバ実行用)

```bash
# 本番サーバ上で
REF=origin/main ./platform/scripts/deploy.sh
# あるいは特定タグ
REF=v1.2.3 ./platform/scripts/deploy.sh
```

挙動:
1. `backup-db.sh` を実行 (SKIP_BACKUP=1 で省略可)
2. `git fetch && git checkout ${REF}`
3. `docker compose pull && up -d --remove-orphans`
4. `${HEALTH_URL:-https://${PUBLIC_DOMAIN}/}` を `HEALTH_TIMEOUT=60` 秒以内に 2xx を返すか確認
5. 失敗時は直前コミットに自動巻き戻し + 再起動
6. 72h 以上未使用イメージを `docker image prune -f`

### 15.2 GitHub Actions (workflow_dispatch)

[.github/workflows/deploy.yml](../.github/workflows/deploy.yml) に手動トリガのデプロイワークフローを同梱。

GitHub 側に登録する Secrets:

| Secret | 内容 |
| --- | --- |
| `DEPLOY_HOST` | 本番サーバの FQDN / IP |
| `DEPLOY_USER` | SSH ユーザ (例: `deployer`) |
| `DEPLOY_SSH_KEY` | SSH 秘密鍵 PEM (改行含む) |
| `DEPLOY_PORT` | SSH ポート (未設定なら 22) |
| `REPO_PATH` | 本番サーバ上のリポジトリパス (例: `/srv/docker_wordpress`) |

`Actions → Deploy → Run workflow` で `ref` (デフォルト `origin/main`) を指定して実行。`concurrency: deploy` で同時実行禁止。失敗時のロールバックは `deploy.sh` 側で自動。

> WordPress プラグインのオートアップデートは `WP_AUTO_UPDATE_CORE=minor` のみ有効。プラグイン/テーマは管理画面または `wp plugin update --all` を週次 cron で。

