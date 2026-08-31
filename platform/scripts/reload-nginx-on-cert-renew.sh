#!/usr/bin/env bash
# =====================================================================
# 証明書が更新されていたら nginx をリロードする (cron 用 / idempotent)
#
# 背景:
#   certbot コンテナからは docker API に触れないため、nginx を直接
#   reload できない。そこで certbot の --deploy-hook がフラグファイル
#   (nginx_data/certs/.reload-needed) を作成し、このスクリプトがホスト
#   側 cron から拾って graceful reload する。
#   これが無いと、更新に成功しても nginx は起動時に読んだ古い証明書を
#   掴んだままになり、期限切れの証明書を配信し続ける。
#
#   フラグ置き場に webroot (nginx_data/html) を使わないこと。
#   webroot は HTTP で公開されるため、内部状態が外から見えてしまう。
#
# 設置済み cron: /etc/cron.d/cert-reload (15 分おき)
# 手動実行も可 (フラグが無ければ何もしない)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PLATFORM_DIR}"

FLAG="nginx_data/certs/.reload-needed"

if [ ! -f "${FLAG}" ]; then
  exit 0
fi

echo "[$(date -Is)] 証明書の更新を検出。nginx をリロードします。"

# 設定が壊れている状態で reload すると無停止のはずが失敗するため、先に検証する
if ! docker compose exec -T nginx nginx -t; then
  echo "[$(date -Is)] ERROR: nginx -t に失敗。リロードを中止します (フラグは残す)。"
  exit 1
fi

docker compose exec -T nginx nginx -s reload
rm -f "${FLAG}"

echo "[$(date -Is)] リロード完了。"
