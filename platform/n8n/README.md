# n8n — サーバーの状態を AI から照会し、異常をメールで知らせる

2 つの役割があります。

1. **MCP サーバー** — AI アシスタント（Claude Code など）から「WAF の検知結果を見せて」「証明書はいつまで有効?」と聞けるようにする
2. **定期実行** — 毎朝の運用ダイジェスト、WAF の閾値アラート

## 仕組み

```
[Claude Code] --MCP/HTTP--> [n8n (127.0.0.1:5678)] <-- Schedule Trigger (毎朝 7:00 / 毎時)
                                  |
                                  | Execute Command
                                  v
                        [scripts/*.sh]  ──> JSON / テキスト
                                  |
                                  v
        nginx ログ (ro) / fail2ban ログ (ro) / 証明書 (ro) / バックアップ (ro)
```

集計ロジックは n8n の中ではなく [`../scripts/`](../scripts/) のシェルスクリプトにあります。こうしている理由は次の 2 つです。

- ロジックを Git で管理・レビューでき、変更履歴が残る
- n8n を介さずコマンドラインからも同じ結果を得られる（障害時の切り分けが楽になる）

n8n は「AI からの呼び出しを受けてスクリプトを実行する」「決まった時刻にスクリプトを実行してメールする」だけの薄い層です。

スクリプトの共通部分（引数の検証、時刻計算、JSON 組み立て）は [`../scripts/lib/report-common.sh`](../scripts/lib/report-common.sh) にまとめてあります。bash 用の `lib/common.sh` とは別物です。n8n コンテナは Alpine で bash が無いため、これらのスクリプトは POSIX sh + awk だけで書いています（jq も使えません）。

## 公開されるツール（MCP）

| ツール名 | 引数 | 返すもの | 元データ |
|---|---|---|---|
| `waf_detections` | `hours`（24）, `recent`（10） | ModSecurity の遮断件数、攻撃元 IP・URI・ルール ID の上位、直近のブロック内容 | nginx error.log |
| `access_summary` | `hours`（24）, `limit`（10） | リクエスト数、ステータス別件数、アクセス元 IP・パス・UA の上位、404 が多いパス、時間帯別件数 | nginx access.log |
| `fail2ban_status` | `hours`（24）, `limit`（10） | 現在 BAN 中の IP と jail 別件数、期間内の新規 BAN / UNBAN、BAN 回数の多い IP | fail2ban.log |
| `cert_expiry` | `warn_days`（30） | ドメインごとの残り日数と失効日時（残りが短い順） | letsencrypt live/\*/cert.pem |

引数は n8n 側の式で整数に丸めたうえで、スクリプト側でも再度検証・上限クランプをしています（シェルへの値の混入と、レスポンスの肥大を防ぐため）。

聞き方の例:

- 「WAF の検知結果を見せて」「直近 1 週間で一番多い攻撃元 IP は?」
- 「404 が多いページは?」「5xx 出てない?」「どの bot が来てる?」
- 「今どの IP を BAN してる?」「WAF に何度も引っかかってるのに BAN されてない IP ある?」
- 「証明書の期限は?」「更新できてる?」

最後の 2 つのように、複数のツールを突き合わせる質問が AI に任せる価値のあるところです。

## 定期実行されるワークフロー

| ワークフロー | いつ | 何をするか |
|---|---|---|
| 運用ダイジェスト (毎朝メール) | 毎日 7:00 | `ops-digest.sh` の結果をメールで送る。冒頭に【要対応】、以下に WAF / fail2ban / 証明書 / アクセス / バックアップ / ディスクの要約 |
| WAF 閾値アラート (1時間ごと) | 毎時 5 分 | 直近 1 時間で同一 IP からの遮断が閾値（既定 30 件）を超えたらメールで送る |

このサーバーでは個人ブログ向けの自動投稿ワークフローも同じ n8n で動かしていますが、WordPress スタック本体とは関係がないため git 管理外にしています（[Git に入れるもの / 入れないもの](#git-に入れるもの--入れないもの)）。

閾値アラートは、同じ IP について既定 6 時間は再通知しません（スキャナは数日居座るため、毎時間同じメールが届くと読まれなくなる）。この状態は n8n のワークフロー静的データに持っています。

ダイジェストが【要対応】に挙げるのは次の場合です。

| 項目 | 既定の条件 | 変え方 |
|---|---|---|
| バックアップ | 最新が 48 時間より古い / 1 つも無い (WordPress DB・ファイル・デモ DB を別々に判定。デモ DB は置き場所がある時だけ) | `BACKUP_WARN_HOURS` |
| 証明書 | 残り 14 日以下 / 失効済みがある | `CERT_WARN_DAYS` |
| ディスク | 使用率 85% 以上 | `DISK_WARN_PCT` |
| WAF | 24 時間の遮断が 1500 件以上 | `WAF_WARN_BLOCKED` |
| nginx ログ | 500MB 以上（ローテート漏れ） | `LOG_WARN_MB` |
| fail2ban | WAF が 100 件以上遮断しているのに BAN が 0 件 | （固定） |
| fail2ban | ログが 6 時間以上更新されていない | `F2B_STALE_MIN` |

最後の 2 つは「守りが黙って止まっている」ことを拾うためのものです。

---

# セットアップ

## 1. 暗号化キーを用意する

`platform/.env` に次を追加します（`.env` は Git 管理外）。

```bash
echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" >> platform/.env
```

一度決めたら変更しないでください。変更すると n8n に登録済みの認証情報が復号できなくなります。

## 2. メールの宛先を設定する（通知を使う場合）

`platform/.env` に宛先を書きます。

```
OPS_ALERT_EMAIL_TO=you@example.com
```

送信には `.env` の `SMTP_*`（WordPress 用に用意しているもの）が必要です。**空のままだと通知ワークフローはメールを送れません。** MCP ツールだけなら設定は不要です。

## 3. 起動する

```bash
cd platform
docker compose --profile automation up -d n8n
```

`profile` を付けない通常の起動では立ち上がりません。

## 4. 初期設定（ブラウザ）

n8n は `127.0.0.1:5678` にしかバインドしていないため、手元の PC から直接は開けません。
ポート転送で手元に持ってきます。

**VS Code の Remote-SSH で接続している場合**（最も手軽）

「PORTS」パネルを開き、**Forward a Port** で `5678` を追加します。手元のブラウザで
`http://127.0.0.1:5678` が開きます。

**SSH で転送する場合**

```bash
ssh -p <SSH_PORT> -N -L 5678:127.0.0.1:5678 root@<サーバーのIP>
```

`<SSH_PORT>` は `platform/host-secrets.env` の `SSH_PORT` の値です（本リポジトリは
公開のため、実際のポート番号はここに書きません）。

つないだまま手元のブラウザで `http://127.0.0.1:5678` を開き、オーナーアカウントを
作成します。

## 5. ワークフローを取り込む

```bash
docker compose exec n8n n8n import:workflow --separate --input=/workflows
```

リポジトリにある 3 つのワークフロー（と、置いてあれば git 管理外のワークフロー）が入ります。取り込んだあとブラウザを再読み込みしてください。

> **更新で取り込み直すときの注意**
> `import:workflow` はワークフローを JSON の内容で置き換えます。リポジトリの JSON には
> 認証情報（Bearer / SMTP）を入れていないため、**取り込み直すと認証情報の選択が外れ、
> ワークフローは非アクティブになります。** 取り込み直したら、各ノードで認証情報を選び直し、
> 再度 Active にしてください。MCP の URL とトークン自体は変わりません。

## 6. MCP の認証情報を作って有効化する

1. トークンを生成しておく
   ```bash
   openssl rand -hex 32
   ```
2. 「サーバー運用ツール (MCP)」を開き、**MCP Server Trigger** ノードをダブルクリックする
3. **Authentication** が `Bearer Auth` になっていることを確認する（ワークフロー定義で
   指定済み）
4. **Credential for Bearer Auth** で **Create new credential** を選ぶ
5. **Bearer Token** の欄に手順1のトークンを貼り、保存する
   （この認証情報は `Authorization: Bearer <トークン>` ヘッダーを検証する）
6. ワークフローを **Active** にする
7. トリガーノードに表示される **Production URL** を控える（`http://127.0.0.1:5678/mcp/waf`）

認証なしのまま有効化しないでください。このエンドポイントはサーバー上でコマンドを実行します。

## 7. Claude Code に登録する

登録するコマンドは、Claude Code を**どこで動かしているか**で変わります。

**サーバー上で動かしている場合**（VS Code Remote-SSH や SSH 経由の CLI）

n8n と同じホストなので、ポート転送は不要です。

```bash
claude mcp add --transport http waf-n8n http://127.0.0.1:5678/mcp/waf \
  --header "Authorization: Bearer <手順6のトークン>"
```

**手元の PC で動かしている場合**

手順 4 のポート転送を維持したまま、同じコマンドで登録します。URL の `127.0.0.1:5678`
は転送されたポートを指します。**転送が切れるとツールも使えなくなる**点に注意してください。
常用するなら `~/.ssh/config` に書いて常時接続にしておくと楽です。

```
Host wp-server
  HostName <サーバーのIP>
  Port <SSH_PORT>
  User root
  LocalForward 5678 127.0.0.1:5678
  ServerAliveInterval 30
```

`--scope project` は使わないでください。プロジェクトスコープの設定は `.mcp.json` に書き出され、このリポジトリは公開されているためトークンが流出します。既定の local スコープ（`~/.claude.json`）のままにしてください。

## 8. メール送信の認証情報を作る（通知ワークフロー用）

n8n の認証情報にパスワードを直接書くと、n8n の DB（`n8n_data` ボリューム）にもう一つ秘密が増えます。
`.env` の値を**参照するだけ**にして、実体を増やさないようにします。

1. 「運用ダイジェスト (毎朝メール)」を開き、**メール送信** ノードをダブルクリックする
2. **Credential to connect with** → **Create new credential**（種類は SMTP）
3. 各欄に**式**として次を入れる（欄の右上の歯車から Expression に切り替える）

   | 欄 | 入れる式 |
   |---|---|
   | User | `{{ $env.SMTP_USER }}` |
   | Password | `{{ $env.SMTP_PASS }}` |
   | Host | `{{ $env.SMTP_HOST }}` |
   | Port | `{{ $env.SMTP_PORT }}` |
   | SSL/TLS | ポート 587 なら OFF（STARTTLS） |

4. 保存し、ワークフローを **Active** にする
5. 「WAF 閾値アラート (1時間ごと)」の **メール送信** ノードでも、同じ認証情報を選んで Active にする

差出人と宛先は `$env.SMTP_FROM_EMAIL` / `$env.OPS_ALERT_EMAIL_TO` をワークフロー側で参照しているので、入力は不要です。

> 式が使えるのは `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`（docker-compose.yml で明示）のためです。
> 素直にパスワードを直接入力しても動きますが、その場合は `.env` と n8n の両方を更新する必要があります。

送信テストは、ワークフローを開いて **Execute workflow** を押すのが確実です（スケジュールを待つ必要はありません）。

---

# スクリプト単体で使う

n8n を経由せずに同じ結果が得られます。障害時の切り分けはこちらが速いです。

```bash
platform/scripts/ops-digest.sh                       # 人が読む形式
platform/scripts/ops-digest.sh --format json         # 機械が読む形式

platform/scripts/waf-report.sh --hours 24
platform/scripts/access-summary.sh --hours 6 --limit 20
platform/scripts/fail2ban-status.sh --hours 168
platform/scripts/cert-expiry.sh --warn-days 14

<スクリプト> --help                                   # 引数と環境変数の一覧
```

`ops-digest.sh` 以外は stdout に JSON のみを出すため、`jq` にそのまま渡せます。

```bash
platform/scripts/waf-report.sh --hours 24 | jq '.top_ips'
platform/scripts/access-summary.sh --hours 1 | jq '.by_status'
```

ホストで実行したときと n8n コンテナで実行したときで、次の 2 点だけ挙動が変わります。

| | ホスト | n8n コンテナ |
|---|---|---|
| `fail2ban_status` の BAN 一覧 | `fail2ban-client` の現在値（正確） | ログの再生（ローテートで流れた古い BAN は欠ける）。`banned_source` で判別できる |
| `cert_expiry` の期限読み取り | `openssl` | `node`（`crypto.X509Certificate`）。結果は同じ |

# セキュリティ上の前提

- **ループバック限定**: `127.0.0.1:5678` にのみバインドしています。外部公開する場合は nginx 側で認証を追加し、`N8N_SECURE_COOKIE` の扱いを見直してください。
- **読み取り専用**: n8n へのマウントはすべて `:ro` です。WordPress の DB やアプリのデータには触れません。
  - `./scripts` … 実行するスクリプト
  - `nginx_logs` … error.log / access.log
  - `/var/log/fail2ban.log` … ファイル 1 個だけ
  - `./nginx_data/certs` … 証明書。`privkey*.pem` は 0600 で nginx（uid 101）所有のため、uid 1000 で動く n8n からは**読めません**。読めるのは `cert.pem` / `chain.pem` など公開情報だけです
  - `../app/backup` … バックアップの世代確認（ファイル名と日時だけ見る）
- **adm グループ**: `fail2ban.log` が `root:adm 0640` のため、コンテナに GID 4（adm）を足しています。マウントしたファイルを読むためのものであり、`cap_drop: ALL` の前提は変わりません。
- **Execute Command は強力**: このワークフローはサーバー上で任意のコマンドを実行できるノードを使っています。公開するツールを増やすときは、実行内容をスクリプト側に固定し、AI から渡る値は引数としてのみ受け取ってください。

# つまずきやすい点

### `Unrecognized node type: n8n-nodes-base.executeCommand`

n8n 2.x は Execute Command ノードを**既定で無効**にしています（`@n8n/config` の
`nodes.config` で `exclude` の初期値に入っている）。`docker-compose.yml` で
`NODES_EXCLUDE` を明示して外していますが、この変数は既定値を上書きするため、
`localFileTrigger` は明示的に残しています。

変更後は n8n の再起動に加えて、**ブラウザの再読み込み**が必要です（フロントエンドが
ノード定義をキャッシュしているため）。

### 管理画面に接続できない

n8n は `127.0.0.1:5678` にしかバインドしていないため、手元からは必ずポート転送を
経由します。つながらない場合は次の順に確認してください。

1. `localhost` ではなく `127.0.0.1` で開く（`localhost` が IPv6 に解決されると届かない）
2. VS Code の PORTS パネルで Local Address がずれていないか（5678 以外に割り当てられることがある）
3. SSH トンネルが切れていないか

### fail2ban のログが古いまま（`stale: true` / ダイジェストに警告が出る）

`/var/log/fail2ban.log` は週次でローテートされ、その方式は `create`（元のファイルを
リネームして新しいファイルを作る）です。n8n にはこのファイルを**ファイル 1 個として**
マウントしているため、ローテート後もコンテナ内は古い方の実体を掴んだままになり、
更新の止まったログを読み続けます。エラーは出ません。

`fail2ban-status.sh` はログの最終更新が 6 時間以上前なら `stale: true` を立て、
ダイジェストにも警告を出します。出たら再起動でマウントし直してください。

```bash
docker compose --profile automation restart n8n
```

### 集計期間がずれる（ログのタイムゾーン）

nginx はコンテナに TZ を渡していないため、ログは **UTC** で記録されます。一方ホストと
n8n コンテナは JST です。集計開始時刻をローカル時刻で作ると 9 時間ずれ、「直近 24 時間」
のつもりで直近 15 時間しか見ない、という取りこぼしが起きます（エラーにならず件数が
静かに減るだけなので気づきにくい）。

各スクリプトはログごとに基準を使い分けています。変更するときはここを崩さないでください。

| ログ | タイムゾーン | 指定 |
|---|---|---|
| nginx error.log | UTC | `WAF_LOG_TZ=utc`（既定） |
| nginx access.log | ログ行の `+0000` から自動判定 | `ACCESS_LOG_TZ` で上書き可 |
| fail2ban.log | ホストのローカル時刻 | `F2B_LOG_TZ=local`（既定） |

### access.log が大きくて集計が遅い / 一部しか集計されない

`access-summary.sh` は末尾から読み、集計期間の先頭に届くまで読む量を倍にしていきます
（16MiB から開始、上限 256MiB）。上限に達しても届かない場合は `scan.truncated` が
`true` になり、その旨が stderr に出ます。結果が一部であることは JSON から分かります。

なお `access.log` / `error.log` にはローテートの設定がありません。肥大化したら
ダイジェストが警告します（既定 500MB）。

# Git に入れるもの / 入れないもの

| | |
|---|---|
| コミットする | 運用系の `workflows/*.json`（`ops-tools-mcp` / `ops-digest-mail` / `waf-threshold-alert`）、この README、`../scripts/*.sh`、`docker-compose.yml` の定義 |
| コミットしない | `.env`（暗号化キー・SMTP・宛先）、Bearer トークン、n8n のデータ（`n8n_data` ボリューム内の認証情報 DB と暗号鍵）、このサーバー固有のワークフロー（個人ブログの自動投稿など。`.gitignore` に列挙し、環境変数は `docker-compose.demo.yml` 側で渡す） |

ワークフローの JSON には認証情報を含めていません（認証情報の ID は環境ごとに違うため）。
n8n のデータは名前付きボリュームに置いているため、リポジトリ配下には出てきません。
