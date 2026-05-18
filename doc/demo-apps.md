# Demo Apps (実稼働ポートフォリオ)

ポートフォリオ (WordPress) からリンクされる「実稼働デモアプリ」を、別コンテナ・別サブドメインで運用するための仕組み。

## 1. 全体像

```
                      ┌────────────────────────────────────────────┐
            80/443    │ Nginx (owasp/modsecurity-crs:nginx)        │
   ───────────────────▶│ + ModSecurity (WAF)                         │
                      │   - example.com         → wordpress:80      │
                      │   - todo.example.com    → demo-todo:3000    │
                      │   - lp.example.com      → demo-static:80    │
                      └────────────┬───────────────────────────────┘
                                   │ proxy_network (bridge)
                ┌─────────┬────────┼────────┬──────────────┐
                ▼         ▼        ▼        ▼              ▼
              wordpress   db   demo-todo  demo-static    ... 追加デモ
              (port 80)        (no host port — internal only)
```

* デモコンテナはホスト側ポートを **公開しない** (`ports:` を書かない)。
* Nginx が `proxy_network` 経由で内部 DNS (`http://<service>:<port>`) に転送する。
* WordPress 側の Work CPT には「Demo URL」フィールドがあり、サブドメインを指す。

## 2. ファイル構成

| 種類        | パス                                                                  | 役割                                |
| ----------- | --------------------------------------------------------------------- | ----------------------------------- |
| compose     | `platform/docker-compose.demo.yml.template`                           | デモサービス追加用オーバーライド    |
| nginx (SSL) | `platform/nginx_conf/conf.d/demo-app.conf.template`                   | サブドメイン HTTPS リバースプロキシ |
| nginx (HTTP)| `platform/nginx_conf/conf.d/demo-app.conf.local.template`             | ローカル開発用 HTTP のみ            |
| theme       | `app/wordpress/wordpress_data/wp-content/themes/diy-fullstack/inc/work-meta.php` | Demo URL / Repository URL のメタ    |

## 3. デモアプリを 1 つ追加する手順

例: TODO アプリを `todo.example.com` (本番) / `todo.localhost` (ローカル) で公開する。

### 3.1 アプリのソースを置く

```
app/demo-todo/
├── Dockerfile         # 任意。テンプレ例は node:20-alpine をそのまま使う
├── package.json
└── src/...
```

### 3.2 compose にサービスを追加

初回のみテンプレをコピー:

```bash
cd platform/
cp docker-compose.demo.yml.template docker-compose.demo.yml
```

`docker-compose.demo.yml` の `demo-todo` ブロックを編集し、`image:` / `command:` / `expose:` を実装に合わせて書き換える。`ports:` は書かない (内部のみ)。

### 3.3 Nginx のサブドメイン設定を追加

#### 本番 (Let's Encrypt) の場合

```bash
cd platform/
cp nginx_conf/conf.d/demo-app.conf.template nginx_data/conf.d/todo.conf
sed -i '' -e 's/__SUBDOMAIN__/todo.example.com/g' \
          -e 's/__SERVICE__/demo-todo/g' \
          -e 's/__PORT__/3000/g' \
          nginx_data/conf.d/todo.conf
```

Linux の場合は `sed -i` の `''` を取り除く。

その後 certbot で証明書発行 (DNS が `todo.example.com → サーバ IP` に向いている前提):

```bash
docker compose run --rm certbot certonly --webroot \
  --webroot-path=/usr/share/nginx/html \
  -d todo.example.com
```

#### ローカル開発の場合

```bash
cp nginx_conf/conf.d/demo-app.conf.local.template nginx_data/conf.d/todo.local.conf
sed -i '' -e 's/__SUBDOMAIN__/todo.localhost/g' \
          -e 's/__SERVICE__/demo-todo/g' \
          -e 's/__PORT__/3000/g' \
          nginx_data/conf.d/todo.local.conf
```

`.localhost` ドメインは多くの OS で自動的に `127.0.0.1` に解決される。されない場合は `/etc/hosts` に追加:

```
127.0.0.1 todo.localhost
```

### 3.4 起動

```bash
cd platform/
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d
docker compose restart nginx   # 設定を反映
```

`docker-compose.demo.yml` を毎回 `-f` 指定するのが面倒なら、環境変数 `COMPOSE_FILE` に書く:

```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.demo.yml
```

### 3.5 WordPress 側にリンクを登録

1. `wp-admin > Works > 新規追加`
2. サイドの **Demo / Repository** ボックスで `Demo URL` に `https://todo.example.com/` を入力
3. 公開すると Works カードと作品詳細ページに **● Open live demo →** ボタンが表示される

## 4. 追加サービスを増やす場合

`docker-compose.demo.yml` に `demo-<name>` サービスを追記し、`nginx_data/conf.d/<name>.conf` を作るだけ。
ベース compose (`docker-compose.yml`) は変更不要。

```bash
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d demo-<name>
docker compose restart nginx
```

## 5. 注意点

| 項目 | 内容 |
| --- | --- |
| ネットワーク名 | `docker-compose.demo.yml` 側で `external: true` + `name: docker_wordpress_proxy_network` を指定済み。compose プロジェクト名 (`docker_wordpress`) と一致させること。 |
| ポート公開 | デモコンテナは `ports:` を書かない。書いたらホスト側に穴が開き、Nginx (WAF) を経由しない経路ができてしまう。 |
| ModSecurity | サブドメインでも継承される。誤検知で 403 になる場合は `nginx_data/modsec-rules/` でルール調整。 |
| ログ | 各デモアプリのログは `app/log_data/` 配下にバインドするか、`docker logs <container>` で確認。 |
| 証明書 | 1サブドメイン1証明書。ワイルドカード証明書を使う場合は DNS-01 チャレンジが必要。 |
| バックアップ対象 | デモアプリのデータは `app/demo-<name>/` 配下に集約しておくと `app/` 一括バックアップで完結する。 |

## 6. 参考: 動作確認チェックリスト

```bash
# 1. デモコンテナが起動しているか
docker compose -f docker-compose.yml -f docker-compose.demo.yml ps

# 2. Nginx から内部で疎通するか
docker exec docker_wordpress-nginx-1 \
  curl -sS -o /dev/null -w "%{http_code}\n" http://demo-todo:3000/

# 3. 外部から HTTPS で疎通するか
curl -sS -o /dev/null -w "%{http_code}\n" https://todo.example.com/
```
