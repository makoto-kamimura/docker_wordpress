#!/usr/bin/env bash
# =====================================================================
# 本番デプロイスクリプト (本番サーバ上で実行)
#   - 直前に DB バックアップ
#   - git pull --ff-only (REF が指定されればその ref に checkout)
#   - docker compose pull / up -d --remove-orphans
#   - ヘルスチェック (nginx 起動 + HTTP/HTTPS 応答)
#   - 失敗時は元コミットに戻して再起動
#   - 古いイメージを掃除
#
# 環境変数:
#   REF              デプロイ対象 (デフォルト: origin/main)
#   SKIP_BACKUP=1    バックアップを省略 (CI で別途バックアップしている時)
#   HEALTH_URL       ヘルスチェック URL (デフォルト: https://${PUBLIC_DOMAIN}/)
#   HEALTH_TIMEOUT   タイムアウト秒 (デフォルト 60)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PLATFORM_DIR}/.." && pwd)"
cd "${REPO_DIR}"

# .env を読み込み (PUBLIC_DOMAIN 等)
# shellcheck source=scripts/lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
if [[ -f "${PLATFORM_DIR}/.env" ]]; then
  load_env "${PLATFORM_DIR}/.env"
fi

REF="${REF:-origin/main}"
HEALTH_URL="${HEALTH_URL:-https://${PUBLIC_DOMAIN:-localhost}/}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"

log() { echo "[$(date -Iseconds)] $*"; }

PREV_SHA="$(git rev-parse HEAD)"

# 1. バックアップ
if [[ "${SKIP_BACKUP:-0}" != "1" ]]; then
  log "Backing up database before deploy..."
  "${SCRIPT_DIR}/backup-db.sh"
else
  log "SKIP_BACKUP=1; skipping pre-deploy backup"
fi

# 2. git fetch + checkout
log "Fetching latest from origin..."
git fetch --prune origin

log "Checking out ${REF}..."
git -c advice.detachedHead=false checkout "${REF}"
NEW_SHA="$(git rev-parse HEAD)"
log "  previous=${PREV_SHA}  new=${NEW_SHA}"

# 3. docker compose pull / up
cd "${PLATFORM_DIR}"

# nginx_data/conf.d と certs の権限を毎回リセット (root で作業した後の権限ズレを防ぐ)
log "Fixing nginx_data permissions..."
"${SCRIPT_DIR}/init-dirs.sh"

log "Pulling images..."
docker compose pull --quiet

DEMO_OVERRIDE=""
[ -f docker-compose.demo.yml ] && DEMO_OVERRIDE="-f docker-compose.demo.yml"

log "Recreating services..."
# shellcheck disable=SC2086
docker compose -f docker-compose.yml ${DEMO_OVERRIDE} up -d --remove-orphans

# 4. ヘルスチェック
log "Health check (${HEALTH_URL}, timeout=${HEALTH_TIMEOUT}s)..."
START=$(date +%s)
while :; do
  if curl -fsSk -o /dev/null -m 5 "${HEALTH_URL}"; then
    log "  -> healthy"
    break
  fi
  if (( $(date +%s) - START >= HEALTH_TIMEOUT )); then
    log "ERROR: health check failed; rolling back to ${PREV_SHA}"
    cd "${REPO_DIR}"
    git -c advice.detachedHead=false checkout "${PREV_SHA}"
    cd "${PLATFORM_DIR}"
    docker compose up -d
    exit 1
  fi
  sleep 3
done

# 5. 後始末
log "Pruning unused images..."
docker image prune -f --filter "until=72h" >/dev/null

log "Deploy OK: ${PREV_SHA} -> ${NEW_SHA}"
