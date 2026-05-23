#!/usr/bin/env bash
# =====================================================================
# 初回デプロイ前の準備スクリプト (idempotent)
#
# 実行内容:
#   1. ランタイムディレクトリの作成
#   2. nginx コンテナ (uid=101) への書き込み権限設定
#      - nginx_data/conf.d     : テンプレートから設定ファイルを生成するため
#      - nginx_data/certs      : 証明書ファイルの読み取りに必要
#      - log_data/nginx_logs   : アクセスログ・エラーログ書き込みに必要
#   3. modsec-rules プレースホルダファイルの存在確認・修正
#
# 使い方:
#   cd platform
#   sudo ./scripts/init-dirs.sh
#
# 注意: git pull 後や証明書更新後にも再実行することで権限ズレを防げる。
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PLATFORM_DIR}"

# owasp/modsecurity-crs:nginx-alpine の nginx ユーザー UID/GID
NGINX_UID=101
NGINX_GID=101

echo "[1/3] ランタイムディレクトリを作成..."

mkdir -p nginx_data/conf.d
mkdir -p nginx_data/html
mkdir -p nginx_data/certs
mkdir -p log_data/nginx_logs

echo "[2/3] nginx コンテナが書き込み/読み取りできるよう権限を設定..."

# conf.d: ディレクトリと既存ファイルを再帰的に chown する。
# root でファイルを作成・コピーした後にこのスクリプトを再実行すれば権限ズレが直る。
chown -R "${NGINX_UID}:${NGINX_GID}" nginx_data/conf.d

# certs: Let's Encrypt の privkey.pem は 600 のため nginx ユーザー所有が必要
# certbot が証明書を (再)発行した後や git pull 後も再実行すること
if [ -d nginx_data/certs/live ] || [ -d nginx_data/certs/archive ]; then
  chown -R "${NGINX_UID}:${NGINX_GID}" nginx_data/certs/live nginx_data/certs/archive 2>/dev/null || true
fi

# nginx_logs: アクセスログ・エラーログの書き込みに必要
chown "${NGINX_UID}:${NGINX_GID}" log_data/nginx_logs

echo "[3/3] modsec-rules プレースホルダファイルを確認..."

for conf_file in \
  nginx_data/modsec-rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf \
  nginx_data/modsec-rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf
do
  if [ -d "${conf_file}" ]; then
    echo "  修正: ディレクトリ → ファイルに変換: ${conf_file}"
    rm -rf "${conf_file}"
    touch "${conf_file}"
  elif [ ! -f "${conf_file}" ]; then
    echo "  作成: ${conf_file}"
    touch "${conf_file}"
  else
    echo "  OK: ${conf_file}"
  fi
done

echo ""
echo "セットアップ完了。次のステップ:"
echo "  sudo docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d"
