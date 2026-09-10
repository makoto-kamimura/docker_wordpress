#!/usr/bin/env bash
# =====================================================================
# 本番 cutover 用 初期セットアップ (idempotent)
# - WordPress core install (まだなら)
# - siteurl / home を本番 URL に合わせる
# - パーマリンクを /%postname%/ に
# - tty-portfolio テーマを有効化
# - 必須プラグインをインストール + 有効化:
#     redis-cache, wps-hide-login, wordfence, wp-mail-smtp
# - Redis Object Cache を有効化
# - rewrite flush
#
# 使い方:
#   cd platform
#   ./scripts/initial-setup.sh                       # 既存値で全部
#   ADMIN_USER=mkk ADMIN_PASS=... ./scripts/initial-setup.sh
# =====================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
cd "${PLATFORM_DIR}"

# .env を読み込む（無ければ load_env がエラー終了する）
load_env ./.env

# 必須環境変数
: "${PUBLIC_DOMAIN:?PUBLIC_DOMAIN is required (set in .env)}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL is required (set in .env)}"

SITE_URL="https://${PUBLIC_DOMAIN}"
ADMIN_USER="${ADMIN_USER:-mkk}"
ADMIN_EMAIL="${ADMIN_EMAIL:-${LETSENCRYPT_EMAIL}}"
ADMIN_PASS="${ADMIN_PASS:-}"
SITE_TITLE="${SITE_TITLE:-Makoto Kamimura}"
WP_LOCALE="${WP_LOCALE:-ja}"
THEME_SLUG="${THEME_SLUG:-tty-portfolio}"

if [[ -z "${ADMIN_PASS}" ]]; then
  ADMIN_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c 24)"
  ADMIN_PASS_GENERATED=1
fi

wp() {
  docker compose --profile cli run --rm -T wpcli wp --path=/var/www/html "$@"
}

log "Waiting for db + wordpress to be running..."
docker compose up -d db wordpress
# 2 サービスとも running になるまで最大 120 秒待つ。
# 待ち切れないまま進むと、後段の wp コマンドが原因の分かりにくいエラーで落ちる。
running=0
for _ in $(seq 1 60); do
  running="$(docker compose ps --status running --quiet db wordpress | wc -l)"
  (( running == 2 )) && break
  sleep 2
done
(( running == 2 )) || die "db / wordpress が起動しません (running=${running}/2)。docker compose ps で確認してください"

log "Checking WordPress core install state..."
if wp core is-installed >/dev/null 2>&1; then
  echo "  -> already installed"
else
  echo "  -> running wp core install"
  wp core install \
    --url="${SITE_URL}" \
    --title="${SITE_TITLE}" \
    --admin_user="${ADMIN_USER}" \
    --admin_password="${ADMIN_PASS}" \
    --admin_email="${ADMIN_EMAIL}" \
    --skip-email
  if [[ "${ADMIN_PASS_GENERATED:-0}" == "1" ]]; then
    echo ""
    echo "  ============================================="
    echo "   admin_user : ${ADMIN_USER}"
    echo "   admin_pass : ${ADMIN_PASS}"
    echo "  ============================================="
    echo "   ↑ パスワードはこのコンソールにしか出ません。"
    echo "     パスワードマネージャに保管してください。"
    echo ""
  fi
fi

log "Setting siteurl / home / locale / timezone..."
wp option update siteurl "${SITE_URL}"
wp option update home    "${SITE_URL}"
wp option update blogname        "${SITE_TITLE}"
wp option update blogdescription "Fullstack engineer in Tokyo."
wp option update timezone_string "Asia/Tokyo" || true
wp option update WPLANG "${WP_LOCALE}"        || true
wp language core install "${WP_LOCALE}"       || true
wp language core activate "${WP_LOCALE}"      || true

log "Setting permalink structure..."
wp rewrite structure '/%postname%/' --hard

log "Activating theme ${THEME_SLUG}..."
if wp theme is-installed "${THEME_SLUG}" >/dev/null 2>&1; then
  wp theme activate "${THEME_SLUG}"
else
  warn "theme '${THEME_SLUG}' not found in wp-content/themes/. Skipping."
fi

log "Installing + activating plugins..."
for plugin in redis-cache wps-hide-login wordfence wp-mail-smtp; do
  if wp plugin is-installed "${plugin}" >/dev/null 2>&1; then
    echo "  -> ${plugin}: already installed, activating"
    wp plugin activate "${plugin}" || true
  else
    echo "  -> ${plugin}: installing"
    wp plugin install "${plugin}" --activate
  fi
done

log "Enabling Redis object cache..."
if wp redis status 2>/dev/null | grep -q "Connected"; then
  echo "  -> already connected"
else
  wp redis enable || warn "'wp redis enable' failed (確認: REDIS_PASSWORD / WP_REDIS_HOST)"
fi

log "Configuring WP Mail SMTP (skip if SMTP_HOST is empty)..."
# JSON 文字列リテラル用に \ と " をエスケープする。
# SMTP パスワードにこれらの文字が含まれていると、素のまま埋め込んだ JSON が壊れる。
json_str() {
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

if [[ -n "${SMTP_HOST:-}" && -n "${SMTP_USER:-}" && -n "${SMTP_PASS:-}" && -n "${SMTP_FROM_EMAIL:-}" ]]; then
  SMTP_AUTH_BOOL=$([[ "${SMTP_AUTH:-1}" == "1" ]] && echo true || echo false)
  WPMS_JSON=$(cat <<JSON
{
  "mail": {
    "mailer": "smtp",
    "from_email": "$(json_str "${SMTP_FROM_EMAIL}")",
    "from_name": "$(json_str "${SMTP_FROM_NAME:-}")",
    "from_email_force": true,
    "from_name_force": true,
    "return_path": false
  },
  "smtp": {
    "host": "$(json_str "${SMTP_HOST}")",
    "port": ${SMTP_PORT:-587},
    "encryption": "$(json_str "${SMTP_ENCRYPTION:-tls}")",
    "auth": ${SMTP_AUTH_BOOL},
    "autotls": true,
    "user": "$(json_str "${SMTP_USER}")",
    "pass": "$(json_str "${SMTP_PASS}")"
  }
}
JSON
)
  echo "${WPMS_JSON}" | wp option update wp_mail_smtp --format=json
  echo "  -> wp_mail_smtp configured (host=${SMTP_HOST}, from=${SMTP_FROM_EMAIL})"
else
  echo "  -> SMTP_HOST/USER/PASS/FROM_EMAIL のいずれかが空のため、WP Mail SMTP の自動設定はスキップ"
fi

log "Flushing rewrite rules..."
wp rewrite flush --hard

log "Done. Visit: ${SITE_URL}/wp-admin/"
