# Demo Apps (実稼働ポートフォリオ)

ポートフォリオ (WordPress) からリンクされる「実稼働デモアプリ」を、別コンテナ・別サブドメインで運用するための仕組み。

**原則: `platform/docker-compose.yml` (メイン) は一切変更しない。**
変更対象は `platform/docker-compose.demo.yml` と `platform/nginx_data/conf.d/` のみ。

---

## 1. 全体像

```
                      ┌────────────────────────────────────────────────┐
            80/443    │ Nginx (owasp/modsecurity-crs:nginx)            │
   ──────────────────▶│ + ModSecurity (WAF)                            │
                      │   - <your-domain>         → wordpress:80       │
                      │   - <app1>.<your-domain>  → demo-<app1>:<port> │
                      │   - <app2>.<your-domain>  → demo-<app2>:<port> │
                      └────────────┬───────────────────────────────────┘
                                   │ proxy_network (bridge)
                ┌──────────────────┼──────────────────────┐
                ▼                  ▼                       ▼
           wordpress          demo-<app1>             demo-<app2>
           (port 80)     (+ optional api/db)         (no host port)
                         (demo_<app1>_backend: internal)
```

* **デモコンテナはホスト側ポートを公開しない** (`ports:` を書かない)。
* Nginx が `proxy_network` 経由で内部 DNS (`http://<service>:<port>`) に転送する。
* `proxy_network` は `docker-compose.demo.yml` 内で定義する。メイン compose は触らない。
* WordPress の Work CPT (テーマ `tty-portfolio`) に Demo URL を登録するとフロントにリンクが出る。

---

## 2. ファイル構成

```
docker_wordpress/
├── app/
│   ├── <appname>/          ← git clone したアプリのソースをここに置く
│   │   ├── app/api/        │  (サブディレクトリ構成はアプリに依存)
│   │   ├── app/web/        │
│   │   └── ...             │
│   ├── <appname2>/         ← デモアプリ 2 つ目以降も同様に配置
│   └── wordpress/          ← WordPress 本体 (変更不要)
│
└── platform/
    ├── docker-compose.yml          ← メイン (変更しない)
    ├── docker-compose.demo.yml     ← デモサービスを追記する場所
    ├── nginx_conf/conf.d/
    │   ├── demo-app.conf.template          ← 本番 nginx 設定テンプレ
    │   └── demo-app.conf.local.template    ← ローカル開発用テンプレ
    └── nginx_data/conf.d/
        ├── default.conf            ← WordPress 本体 (自動生成・変更不要)
        └── <name>.conf             ← 追加するサブドメイン設定 (gitignore 済み)
```

| 種類 | パス | 役割 |
|---|---|---|
| compose (メイン) | `platform/docker-compose.yml` | **変更不要** |
| compose (デモ) | `platform/docker-compose.demo.yml` | デモサービスを追記する |
| nginx テンプレ (本番) | `platform/nginx_conf/conf.d/demo-app.conf.template` | サブドメイン HTTPS リバースプロキシ雛形 |
| nginx テンプレ (ローカル) | `platform/nginx_conf/conf.d/demo-app.conf.local.template` | ローカル開発用 HTTP 雛形 |
| nginx 実設定 | `platform/nginx_data/conf.d/<name>.conf` | 実際に nginx が読む設定 |
| Works メタ | `app/wordpress/.../themes/tty-portfolio/inc/work-meta.php` | Demo URL 等のメタフィールド定義 |

---

## 3. デモアプリを 1 つ追加する手順

例: `myapp.<your-domain>` でアプリを公開する。

> **具体的なアプリの追加例** は `doc/demo-apps-<appname>.md` (非公開) を参照。

### Step 1 — アプリのソースを置く

```bash
# app/ 配下に git clone する (またはすでにある場合はそのまま)
cd /path/to/docker_wordpress
git clone https://github.com/<you>/<appname> app/<appname>
```

ソース配置後のディレクトリイメージ:

```
app/<appname>/
├── Dockerfile        # あれば build: で使う
├── package.json      # または Gemfile 等
└── src/
```

### Step 2 — `docker-compose.demo.yml` にサービスを追記

`platform/docker-compose.demo.yml` の `services:` ブロックに追記する。
**既存サービス (nginx オーバーライド、他の demo-* 等) は残したまま追記する。**

```yaml
# ---------------------------------------------------------------------------
# <appname> デモ
# 公開 URL : https://<appname>.<your-domain>
# Nginx conf: nginx_data/conf.d/<appname>.conf
# ---------------------------------------------------------------------------
demo-<appname>:
  build:
    context: ../app/<appname>
    dockerfile: Dockerfile
  environment:
    NODE_ENV: production
  expose:
    - "3000"          # アプリが listen するポートに合わせる
  restart: unless-stopped
  networks:
    - proxy_network   # 必須。nginx から疎通するために必要
```

DB が必要な場合は専用の内部ネットワークを追加する:

```yaml
  demo-<appname>:
    ...
    networks:
      - proxy_network
      - demo_<appname>_backend   # ← 追加

  demo-<appname>-db:
    image: postgres:16-alpine
    ...
    networks:
      - demo_<appname>_backend   # ← DB は proxy_network に接続しない (外部疎通不可)

# ファイル末尾の networks: ブロックにも追記
networks:
  proxy_network:
    driver: bridge
  demo_<appname>_backend:     # ← 追加
    driver: bridge
    internal: true
```

#### ポイント
| 項目 | ルール |
|---|---|
| `ports:` | **書かない。** Nginx (WAF) を経由しないホスト公開経路ができる。 |
| `expose:` | アプリの listen ポートを書く (nginx が参照する内部ポート)。 |
| `networks: proxy_network` | **必須。** これがないと nginx からルーティングできない。 |
| DB コンテナ | `proxy_network` に接続しない。専用の `internal: true` ネットワークで分離する。 |
| `restart: unless-stopped` | 本番デモは常時稼働させる。 |

### Step 3 — nginx のサブドメイン設定を追加

#### 本番 (Let's Encrypt) の場合

```bash
cd platform/

# テンプレをコピーしてプレースホルダを置換 (Linux)
cp nginx_conf/conf.d/demo-app.conf.template nginx_data/conf.d/<appname>.conf
sed -i \
  -e 's/__SUBDOMAIN__/<appname>.<your-domain>/g' \
  -e 's/__SERVICE__/demo-<appname>/g' \
  -e 's/__PORT__/3000/g' \
  nginx_data/conf.d/<appname>.conf
```

API とフロントエンドで別サービスに分かれている場合は
`/api` → API サービス、`/` → Web サービスと振り分ける設定を追加する。

#### ローカル開発の場合

```bash
cp nginx_conf/conf.d/demo-app.conf.local.template nginx_data/conf.d/<appname>.local.conf
sed -i \
  -e 's/__SUBDOMAIN__/<appname>.localhost/g' \
  -e 's/__SERVICE__/demo-<appname>/g' \
  -e 's/__PORT__/3000/g' \
  nginx_data/conf.d/<appname>.local.conf
```

`.localhost` は多くの OS で `127.0.0.1` に自動解決される。されない場合は `/etc/hosts` に追記:

```
127.0.0.1 <appname>.localhost
```

### Step 4 — SSL 証明書を取得 (本番のみ)

DNS が `<appname>.<your-domain> → サーバー IP` を向いている前提で:

```bash
cd platform/

# nginx を一時的に起動して ACME チャレンジを受ける
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d nginx

# 証明書発行
docker compose run --rm certbot certonly --webroot \
  --webroot-path=/usr/share/nginx/html \
  -d <appname>.<your-domain>
```

証明書は `platform/nginx_data/certs/live/<appname>.<your-domain>/` に保存される。

### Step 5 — 起動・反映

```bash
cd platform/

# アプリをビルドして起動
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --build demo-<appname>

# nginx に新しいサブドメイン設定を反映
docker compose -f docker-compose.yml -f docker-compose.demo.yml restart nginx
```

毎回 `-f` を二重指定するのが煩わしい場合は `.env` に設定:

```bash
# platform/.env に追記
COMPOSE_FILE=docker-compose.yml:docker-compose.demo.yml
```

以降は `docker compose up -d` のみで OK。

### Step 6 — WordPress の Works に登録

1. `wp-admin` → 左サイドバー **Works** (ポートフォリオアイコン、Dashboard の直下)
   - 見当たらない場合は直接 URL: `https://<your-domain>/wp-admin/post-new.php?post_type=work`
2. タイトルに作品名を入力
3. サイドバーの **Demo / Repository** ボックスに入力:
   | フィールド | 入力例 |
   |---|---|
   | Demo URL | `https://<appname>.<your-domain>/` |
   | Demo button label | `Open live demo →` (省略可) |
   | Repository URL | `https://github.com/<you>/<appname>` |
   | Role / responsibilities | `フロントエンド / Rails API` 等 |
   | Period | `2025-01 〜 2025-03` 等 |
4. アイキャッチ画像を設定し **公開**
5. フロントページの Works セクションにカードが追加され、Demo URL ボタンが表示される

---

## 4. 実稼働例

現在稼働中のデモアプリの詳細は、アプリごとの非公開ドキュメント (`doc/demo-apps-<appname>.md`) を参照。

以下は API + フロントエンド + DB の 3 コンテナ構成のテンプレート:

| コンテナ | 役割 | ネットワーク |
|---|---|---|
| `demo-<appname>-web` | フロントエンド (例: Next.js port 3001) | `proxy_network`, `demo_<appname>_backend` |
| `demo-<appname>-api` | バックエンド API (例: Rails port 3000) | `proxy_network`, `demo_<appname>_backend` |
| `demo-<appname>-db` | DB (例: PostgreSQL) | `demo_<appname>_backend` のみ |

**nginx ルーティング例** (`nginx_data/conf.d/<appname>.conf`):

```
https://<appname>.<your-domain>/api  →  demo-<appname>-api:3000
https://<appname>.<your-domain>/     →  demo-<appname>-web:3001
```

**ソース配置例**:

```
app/<appname>/   ← git clone した場所
├── app/
│   ├── api/Dockerfile
│   └── web/Dockerfile
└── platform/    ← このアプリ単体の開発用 compose (本番では使わない)
```

**compose の build context** は `../app/<appname>/app/api` のようにリポジトリルートからの相対パスで指定する。

---

## 5. 注意点

| 項目 | 内容 |
|---|---|
| メイン compose | `docker-compose.yml` は変更しない。nginx の `proxy_network` 追加も `docker-compose.demo.yml` 内の nginx オーバーライドが担う。 |
| proxy_network | `docker-compose.demo.yml` の `networks:` ブロックで `driver: bridge` として定義する。`external: true` は不要。 |
| ポート公開禁止 | デモコンテナに `ports:` を書くとホストに穴が開き WAF をバイパスされる。`expose:` のみ使う。 |
| ModSecurity | サブドメインでも WAF が継承される。誤検知で 403 になる場合は `nginx_data/modsec-rules/` でルール除外。 |
| 証明書 | 1 サブドメイン 1 証明書。certbot renew ループが 12 時間ごとに自動更新する。 |
| データ永続化 | デモ DB 等のデータは named volume か `app/<name>/` 配下のバインドマウントで管理する。 |
| ログ | `docker logs <container>` または `app/log_data/` 配下にバインドして確認。 |
| git submodule | `app/<name>/` に別リポジトリを clone した場合、`.git/` が入れ子になる。必要なら submodule 化するか `.gitignore` に追記する。 |

---

## 6. 動作確認チェックリスト

```bash
cd platform/

# 1. サービスが起動しているか
docker compose -f docker-compose.yml -f docker-compose.demo.yml ps

# 2. nginx コンテナから内部で疎通できるか
docker exec docker_wordpress-nginx-1 \
  curl -sS -o /dev/null -w "%{http_code}\n" http://demo-<appname>:<port>/

# 3. 外部から HTTPS で疎通できるか
curl -sS -o /dev/null -w "%{http_code}\n" https://<appname>.<your-domain>/

# 4. ModSecurity でブロックされていないか (403 の場合)
docker compose -f docker-compose.yml -f docker-compose.demo.yml logs nginx | grep -i "<appname>"
```

---

## 7. トラブルシューティング

| 症状 | 原因候補 | 対処 |
|---|---|---|
| nginx が 502 Bad Gateway | デモコンテナ未起動 / proxy_network に未接続 | `docker compose ps` でコンテナ状態確認。`networks: proxy_network` が書かれているか確認。 |
| nginx が 403 Forbidden | ModSecurity が誤検知 | `nginx logs` で ModSecurity の `id` を確認し `nginx_data/modsec-rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf` に除外ルールを追記。 |
| HTTPS で証明書エラー | 証明書未発行 / パス違い | `nginx_data/certs/live/<subdomain>/` に `fullchain.pem` があるか確認。 |
| Works が wp-admin に表示されない | テーマキャッシュ | Redis フラッシュ後にブラウザをハードリフレッシュ。直接 URL: `wp-admin/edit.php?post_type=work` |
| compose up で「network not found」| proxy_network 未定義 | `docker-compose.demo.yml` の `networks:` に `proxy_network: driver: bridge` があるか確認。 |
