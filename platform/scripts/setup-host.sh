#!/usr/bin/env bash
# =====================================================================
# ホスト環境セットアップ (idempotent)
#   - fail2ban のインストールと設定適用
#   - SSH ポートの変更
#
# 使い方:
#   cd platform
#   sudo ./scripts/setup-host.sh
#
# deploy.sh から自動的に呼ばれるため、通常は直接実行しない。
# SSH ポート変更後は必ず新しいポートで接続できることを確認すること。
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAIL2BAN_SRC="${PLATFORM_DIR}/fail2ban"
SSH_PORT=__SSH_PORT__

log() { echo "[$(date -Iseconds)] $*"; }

# ---- 1. fail2ban インストール ----------------------------------------
if ! command -v fail2ban-client &>/dev/null; then
  log "Installing fail2ban..."
  apt-get update -qq
  apt-get install -y fail2ban
else
  log "fail2ban already installed: $(fail2ban-client --version 2>&1 | head -1)"
fi

# ---- 2. fail2ban 設定をリポジトリからコピー --------------------------
log "Applying fail2ban config from repo..."

# jail.local を絶対パスに展開してコピー
# %(here)s はfail2ban が jail.local の置き場所を指すため /etc/fail2ban に置く必要がある
# logpath の相対パスを実パスに書き換えてからコピー
NGINX_LOG_DIR="${PLATFORM_DIR}/log_data/nginx_logs"
sed \
  "s|%(here)s/../log_data/nginx_logs|${NGINX_LOG_DIR}|g" \
  "${FAIL2BAN_SRC}/jail.local" \
  > /etc/fail2ban/jail.local

# カスタムフィルターをコピー
cp -v "${FAIL2BAN_SRC}/filter.d/"*.conf /etc/fail2ban/filter.d/

log "Reloading fail2ban..."
systemctl enable fail2ban
systemctl restart fail2ban
# 起動完了を待ってからステータス確認
sleep 2
fail2ban-client status | head -5

# ---- 3. SSH ポート変更 -----------------------------------------------
# Ubuntu 22.04+ はソケットアクティベーション方式のため、
# sshd_config だけでなく ssh.socket のオーバーライドも必要
SSHD_CONF=/etc/ssh/sshd_config.d/port.conf
SOCKET_OVERRIDE=/etc/systemd/system/ssh.socket.d/override.conf
CURRENT_PORT="$(ss -tlnp | grep -E 'sshd|systemd' | grep -oP ':\K\d+' | sort -u | head -1)"

if [[ "${CURRENT_PORT}" == "${SSH_PORT}" ]]; then
  log "SSH port already set to ${SSH_PORT}, skipping"
else
  log "Changing SSH port: ${CURRENT_PORT} -> ${SSH_PORT}"

  # sshd_config.d でポートを明示指定
  echo "Port ${SSH_PORT}" > "${SSHD_CONF}"

  # systemd ソケットアクティベーション用オーバーライド
  mkdir -p "$(dirname "${SOCKET_OVERRIDE}")"
  cat > "${SOCKET_OVERRIDE}" << EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF

  sshd -t
  log "sshd config OK. Restarting ssh.socket..."
  systemctl daemon-reload
  systemctl restart ssh.socket

  log "============================================================"
  log "  SSH port changed to ${SSH_PORT}."
  log "  次回から: ssh -p ${SSH_PORT} root@<host>"
  log "  VSCode Remote SSH の Host 設定に Port ${SSH_PORT} を追加してください。"
  log "============================================================"
fi

log "setup-host.sh done."
