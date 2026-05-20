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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PLATFORM_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: ${PLATFORM_DIR}/.env not found" >&2
  exit 1
fi

# .env を読み込む
# shellcheck source=scripts/lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
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

echo "[$(date -Iseconds)] Waiting for db + wordpress to be healthy..."
docker compose up -d db wordpress
# wp service が serve_started を待つ + db_healthy も待つ
for _ in $(seq 1 60); do
  if docker compose ps --status running --quiet db wordpress | wc -l | grep -q 2; then break; fi
  sleep 2
done

echo "[$(date -Iseconds)] Checking WordPress core install state..."
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

echo "[$(date -Iseconds)] Setting siteurl / home / locale / timezone..."
wp option update siteurl "${SITE_URL}"
wp option update home    "${SITE_URL}"
wp option update blogname        "${SITE_TITLE}"
wp option update blogdescription "Fullstack engineer in Tokyo."
wp option update timezone_string "Asia/Tokyo" || true
wp option update WPLANG "${WP_LOCALE}"        || true
wp language core install "${WP_LOCALE}"       || true
wp language core activate "${WP_LOCALE}"      || true

echo "[$(date -Iseconds)] Setting permalink structure..."
wp rewrite structure '/%postname%/' --hard

echo "[$(date -Iseconds)] Activating theme ${THEME_SLUG}..."
if wp theme is-installed "${THEME_SLUG}" >/dev/null 2>&1; then
  wp theme activate "${THEME_SLUG}"
else
  echo "  WARNING: theme '${THEME_SLUG}' not found in wp-content/themes/. Skipping."
fi

echo "[$(date -Iseconds)] Installing + activating plugins..."
for plugin in redis-cache wps-hide-login wordfence wp-mail-smtp; do
  if wp plugin is-installed "${plugin}" >/dev/null 2>&1; then
    echo "  -> ${plugin}: already installed, activating"
    wp plugin activate "${plugin}" || true
  else
    echo "  -> ${plugin}: installing"
    wp plugin install "${plugin}" --activate
  fi
done

echo "[$(date -Iseconds)] Enabling Redis object cache..."
if wp redis status 2>/dev/null | grep -q "Connected"; then
  echo "  -> already connected"
else
  wp redis enable || echo "  WARN: 'wp redis enable' failed (確認: REDIS_PASSWORD / WP_REDIS_HOST)"
fi

echo "[$(date -Iseconds)] Configuring WP Mail SMTP (skip if SMTP_HOST is empty)..."
if [[ -n "${SMTP_HOST:-}" && -n "${SMTP_USER:-}" && -n "${SMTP_PASS:-}" && -n "${SMTP_FROM_EMAIL:-}" ]]; then
  SMTP_AUTH_BOOL=$([[ "${SMTP_AUTH:-1}" == "1" ]] && echo true || echo false)
  WPMS_JSON=$(cat <<JSON
{
  "mail": {
    "mailer": "smtp",
    "from_email": "${SMTP_FROM_EMAIL}",
    "from_name": "${SMTP_FROM_NAME:-}",
    "from_email_force": true,
    "from_name_force": true,
    "return_path": false
  },
  "smtp": {
    "host": "${SMTP_HOST}",
    "port": ${SMTP_PORT:-587},
    "encryption": "${SMTP_ENCRYPTION:-tls}",
    "auth": ${SMTP_AUTH_BOOL},
    "autotls": true,
    "user": "${SMTP_USER}",
    "pass": "${SMTP_PASS}"
  }
}
JSON
)
  echo "${WPMS_JSON}" | wp option update wp_mail_smtp --format=json
  echo "  -> wp_mail_smtp configured (host=${SMTP_HOST}, from=${SMTP_FROM_EMAIL})"
else
  echo "  -> SMTP_HOST/USER/PASS/FROM_EMAIL のいずれかが空のため、WP Mail SMTP の自動設定はスキップ"
fi

echo "[$(date -Iseconds)] Flushing rewrite rules..."
wp rewrite flush --hard

echo "[$(date -Iseconds)] Done. Visit: ${SITE_URL}/wp-admin/"
