# tty-portfolio 開発履歴

## 概要

東京在住フルスタックエンジニアのポートフォリオサイト。
WordPress カスタムテーマ `tty-portfolio` をターミナル/CLI 風 UI で構築。

---

## 変更ログ

### v1.5.0 — コメントハイライト視認性改善

**変更ファイル**
- `style.css` — `.quote-anchor` スタイル刷新

**内容**
- `box-shadow: inset 3px 0 0 var(--accent)` によるテキスト左端アクセントバー（複数行ラップ対応）
- ハイライト背景を強化、hover 時にボーダー強調
- バッジを `// N` 形式（ターミナルコメント記法）に変更、上付き小文字表示

---

### v1.4.0 — コメント表示をインラインに移行 / 下部リスト廃止

**変更ファイル**
- `comments.php` — 下部コメントリスト・フォームを完全廃止
- `inc/comment-api.php` — `tty_get_comment_data()` 関数追加
- `inc/enqueue.php` — `ttyComment.comments` として承認済みコメントを JS に渡す
- `assets/js/main.js` — インラインハイライト + ポップオーバー IIFE 追加
- `style.css` — `.quote-anchor`・`.quote-badge`・`.quote-popover` スタイル追加

**内容**
- 承認済みコメントの引用テキストを記事本文内で検索し `<mark class="quote-anchor">` でハイライト
- カーソルを合わせる（またはタップ）とポップオーバーが引用箇所の上下に出現
- 同一箇所への複数コメントは 1 つのマークにまとめ、件数バッジを表示
- 引用テキストが見つからない場合（記事編集後など）は無視してエラーなし

---

### v1.3.0 — quote reply コメント機能 / IP ログ

**変更ファイル**
- `inc/comment-api.php` — 新規作成（REST エンドポイント + IP ログ）
- `inc/enqueue.php` — `ttyComment` オブジェクトを JS に localize
- `comments.php` — 標準コメントフォーム削除（リストのみ残存、後に完全廃止）
- `assets/js/main.js` — quote reply フローティングパネル実装
- `style.css` — `.quote-sel-btn`・`.quote-panel` スタイル追加
- `functions.php` — `inc/comment-api.php` の読み込み追加

**内容**

_UX フロー_
1. 記事本文のテキストを選択 → `> quote reply` ボタンが選択範囲上部に浮かぶ
2. クリックでフローティングパネルに切り替わり、引用テキストが表示される
3. `$ ` プロンプト付きテキストエリアにコメントを入力
4. Enter で送信 / Esc でキャンセル
5. 送信後「✓ sent — pending review」を表示してパネルが閉じる

_REST API: `POST /wp-json/tty/v1/comment`_
- 入力項目: コメント本文のみ（名前・メールなし、完全匿名）
- コメントは「承認待ち」で保存（管理者が wp-admin から承認）
- CSRF 保護: Referer ヘッダーによる同オリジン確認 + IP 単位 90 秒レートリミット
- IP・UA・タイムスタンプを `comment_meta` に記録
- `/var/log/apache2/tty_comment_ip.log` にも追記（TSV 形式）

---

### v1.2.0 — quote reply 基礎実装（後に v1.3.0 で置き換え）

_中間バージョン。v1.3.0 で仕様変更のため上書き。_

---

### v1.1.0 — タイプライター演出改善 / Works アーカイブ英語化

**変更ファイル**
- `page-contact.php` — lede を 2 つの `<span data-typewriter>` に分割
- `assets/js/main.js` — `convertStr` 関数修正、`finish()` に ancestor charwrap 対応追加
- `style.css` — `.lede-char`・`.lede-char.struck` 追加、モバイル responsive nowrap
- `archive.php` — Works/tech アーカイブのタイトルを英語出力に変更
- `functions.php` — `TTY_VERSION` を `1.0.0` → `1.1.0` に更新

**内容**

_タイプライター演出 (contact ページ)_
- 「以下のフォームよりお問い合わせください。」→ 「内容を確認の上、折り返しご連絡いたします。」の順に逐次タイプ
- 英語タイプ後、日本語変換と同時に英文を右端から比例削除する `convertStr` アルゴリズムを実装
- スマートフォンでは `white-space: normal` に切り替えて折り返し表示
- `data-charwrap` 親要素配下の子要素にも charwrap 処理が適用されるよう修正

_文字ストライク演出_
- コンタクトフォームへの入力文字数に比例して lede テキストに取り消し線が入る
- `.lede-char` スパンに `.struck` クラスをトグル

_Works アーカイブ_
- `is_post_type_archive('work')` → `echo 'works'`
- `is_tax('tech')` → `echo 'tech: ' . strtolower(term_name)`

---

### v1.0.0 — 初期リリース構成

**インフラ**
- Docker Compose: MariaDB 10.11 + WordPress 6.7.2 (PHP 8.3) + Redis 7.4 + Nginx (OWASP ModSecurity CRS) + Certbot
- WordPress はホストにポート非公開。Nginx (WAF) 経由のみアクセス可
- phpMyAdmin は `profile=admin` 時のみ `127.0.0.1:8888` にバインド

**テーマ構成**
```
tty-portfolio/
├── functions.php         # テーマブートストラップ、TTY_VERSION 管理
├── style.css             # CSS 変数ベースのデザインシステム
├── front-page.php        # トップページ
├── single.php            # 記事・制作物詳細
├── archive.php           # 記事・Works アーカイブ
├── page-contact.php      # お問い合わせページ
├── comments.php          # コメントテンプレート
├── assets/js/main.js     # テーマ JS（テーマトグル・タイプライター・スムーズスクロール）
└── inc/
    ├── enqueue.php       # スタイル・スクリプトのエンキュー
    ├── cpt.php           # カスタム投稿タイプ (work) / タクソノミー (tech)
    ├── work-meta.php     # Works メタボックス
    ├── customizer.php    # テーマカスタマイザー
    ├── template-helpers.php  # tty_work_card / tty_meta_line 等
    ├── seo.php           # OGP / JSON-LD
    ├── perf.php          # パフォーマンス最適化
    ├── a11y.php          # アクセシビリティ補助
    └── comment-api.php   # 匿名コメント REST API (v1.3.0 追加)
```

---

## インフラ修正履歴

### 2026-05-27 — nginx crash-loop 復旧（ModSecurity ルールID重複 / proxy_network 未接続 / SSL 証明書不足）

**症状**
- `https://makoto-kamimura.com/` への全アクセスが「接続拒否 (Connection Refused)」
- `docker_wordpress-nginx-1` コンテナが `Restarting (1)` ループ状態

**原因 (3 点)**

1. **ModSecurity ルールID `9001000` の重複**
   - `nginx_data/modsec-rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf` に追加した独自ルール `id:9001000` が、OWASP CRS 組み込みの Drupal 除外ルール（`/opt/owasp-crs/rules/REQUEST-903.9001-DRUPAL-EXCLUSION-RULES.conf`）と同一 ID だった。
   - nginx 起動時エラー: `"modsecurity_rules_file" directive Rule id: 9001000 is duplicated`

2. **`demo-sales-*` / `demo-todo` / `demo-static` が `proxy_network` に未接続**
   - `docker-compose.demo.yml` に `proxy_network` を追記した後、コンテナが再作成されていなかった。
   - nginx が `demo-sales-api` 等を名前解決できず `host not found in upstream` エラーが連続。

3. **`inventory.makoto-kamimura.com` の SSL 証明書が未発行**
   - `nginx_data/conf.d/inventory.conf` を追加していたが、対応する Let's Encrypt 証明書が未取得のまま nginx が起動しようとした。
   - nginx エラー: `cannot load certificate ".../inventory.makoto-kamimura.com/fullchain.pem"`

**修正手順**

| # | 対処 | 対象 |
|---|------|------|
| 1 | 独自ルール ID を `9001000` → `9500100` に変更 | `nginx_data/modsec-rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf` |
| 2 | `docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --remove-orphans` でコンテナ再作成 | `platform/` |
| 3 | certbot standalone で `inventory.makoto-kamimura.com` 証明書を発行（有効期限: 2026-08-25） | `nginx_data/certs/live/inventory.makoto-kamimura.com/` |

**再発防止策**
- **CRS 組み込み ID 帯を避ける**: OWASP CRS は `9001xxx`〜`9009xxx` を各アプリ (Drupal/WordPress/…) 用に予約済み。独自ルールは **`9500000+` 番台**を使う。
- **conf を追加する前に証明書を取得する**: `nginx_data/conf.d/<name>.conf` を置く前に `certbot certonly` を完了させること。nginx は起動時に全証明書ファイルを検証する。
- **compose 定義変更後は必ず再作成**: ネットワーク・環境変数・ボリューム等を compose で変更しても実行中コンテナには反映されない。`docker compose up -d` でコンテナを再作成する。

---

### 2026-05-27 — 現在の稼働構成スナップショット

**稼働サービス一覧 (2026-05-27 時点)**

| コンテナ名 | サービス | 起動時刻 | 状態 |
|---|---|---|---|
| docker_wordpress-nginx-1 | nginx (OWASP ModSec CRS) | 2026-05-27 | healthy |
| docker_wordpress-wordpress-1 | WordPress 6.7.2 / PHP 8.3 | 2026-05-23 | healthy |
| docker_wordpress-db-1 | MariaDB 10.11.13 | 2026-05-20 | healthy |
| docker_wordpress-redis-1 | Redis 7.4.2 | 2026-05-20 | healthy |
| docker_wordpress-certbot-1 | certbot v2.11.0 | 2026-05-21 | running |
| docker_wordpress-demo-sales-api-1 | Rails API (demo) | 2026-05-27 | running |
| docker_wordpress-demo-sales-web-1 | Next.js (demo) | 2026-05-27 | running |
| docker_wordpress-demo-sales-db-1 | PostgreSQL/pgvector (demo) | 2026-05-21 | healthy |
| docker_wordpress-demo-inventory-api-1 | Laravel API (demo) | 2026-05-27 | running |
| docker_wordpress-demo-inventory-web-1 | Next.js (demo) | 2026-05-27 | running |
| docker_wordpress-demo-inventory-db-1 | MySQL 8.0 (demo) | 2026-05-27 | healthy |
| docker_wordpress-demo-static-1 | nginx:alpine (静的HTML) | 2026-05-27 | running |
| docker_wordpress-demo-todo-1 | node:20-alpine (Todo SPA) | 2026-05-27 | running |

**取得済み SSL 証明書**

| ドメイン | 有効期限 |
|---|---|
| `makoto-kamimura.com` | 2026-08-?? |
| `sales.makoto-kamimura.com` | 2026-08-?? |
| `inventory.makoto-kamimura.com` | 2026-08-25 |

**ネットワーク構成**

| ネットワーク | internal | 接続コンテナ |
|---|---|---|
| `frontend_network` | false | nginx, wordpress |
| `backend_network` | **true** | wordpress, db, redis, (phpmyadmin), (wpcli) |
| `proxy_network` | false | nginx, demo-sales-api/web, demo-inventory-api/web, demo-static, demo-todo |
| `demo_sales_backend` | **true** | demo-sales-api, demo-sales-web, demo-sales-db |
| `demo_inventory_backend` | **true** | demo-inventory-api, demo-inventory-web, demo-inventory-db |

---

### 2026-05-23 — WordPress 管理画面セッション無効化の修正

**問題**
`docker-compose.yml` の `WORDPRESS_CONFIG_EXTRA` に `!defined()` ガードを追加したことで AUTH_KEY が誤ったデフォルト値になり、管理画面セッションが無効化。「All Posts」押下でトップページにリダイレクト。

**原因**
- `wp-config.php`: `define('AUTH_KEY', getenv_docker('WORDPRESS_AUTH_KEY', 'hardcoded'))`
- `WORDPRESS_AUTH_KEY` 環境変数が未設定 → ハードコードデフォルト値を使用
- `WORDPRESS_CONFIG_EXTRA` の `!defined('AUTH_KEY')` ガードにより上書きされず
- 正しい値を持つ `WP_AUTH_KEY` 環境変数が AUTH_KEY に反映されなかった

**修正**
`docker-compose.yml` の wordpress サービスに `WORDPRESS_AUTH_KEY: ${WP_AUTH_KEY}` 他 8 つのソルト変数を追加し、コンテナを再起動。

```yaml
WORDPRESS_AUTH_KEY:         ${WP_AUTH_KEY}
WORDPRESS_SECURE_AUTH_KEY:  ${WP_SECURE_AUTH_KEY}
WORDPRESS_LOGGED_IN_KEY:    ${WP_LOGGED_IN_KEY}
WORDPRESS_NONCE_KEY:        ${WP_NONCE_KEY}
WORDPRESS_AUTH_SALT:        ${WP_AUTH_SALT}
WORDPRESS_SECURE_AUTH_SALT: ${WP_SECURE_AUTH_SALT}
WORDPRESS_LOGGED_IN_SALT:   ${WP_LOGGED_IN_SALT}
WORDPRESS_NONCE_SALT:       ${WP_NONCE_SALT}
```

### 2026-05-23 — REST API JSON 破損の修正

**問題**
ブロックエディタでの投稿公開時に「返答が正しい JSON レスポンスではありません」エラー。

**原因**
`WORDPRESS_CONFIG_EXTRA` の `define(...)` が `wp-config.php` で定義済みの定数を再定義し、PHP Warning が JSON レスポンスの前に出力されていた。

**修正**
`WORDPRESS_CONFIG_EXTRA` 内の全 `define(...)` を `if (!defined(...)) define(...)` ガードに変更。

---

## ブログ投稿（初期コンテンツ）

| ID | タイトル | カテゴリ |
|----|---------|---------|
| 22 | Docker で始める WordPress 本番環境構築 | 技術メモ |
| 23 | tty-portfolio 制作ログ：ターミナル UI の設計と実装 | 制作ログ |
| 24 | 独学フルスタック学習ロードマップ 2025 | 学習記録 |
| 25 | 個人開発者がポートフォリオに「コメント機能」を実装すべき理由 | 意見・考察 |

投稿は WP-CLI 未使用のため `wp_insert_post()` / `wp_update_post()` を直接実行して登録・公開。
