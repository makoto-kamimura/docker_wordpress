#!/usr/bin/env bash
# =====================================================================
# ホスト環境セットアップ (idempotent)
#   - fail2ban のインストールと設定適用
#   - SSH ポートの変更
#
# 使い方:
#   cd platform
#   cp host-secrets.env.example host-secrets.env   # 初回のみ・実値を記入
#   sudo ./scripts/setup-host.sh
#
# deploy.sh から自動的に呼ばれるため、通常は直接実行しない。
# SSH ポート変更後は必ず新しいポートで接続できることを確認すること。
#
# SSH ポートと管理者 IP は本リポジトリが public のため追跡対象に置かず、
# host-secrets.env（.gitignore 済み）から読み込む。
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAIL2BAN_SRC="${PLATFORM_DIR}/fail2ban"
SECRETS_FILE="${PLATFORM_DIR}/host-secrets.env"

log() { echo "[$(date -Iseconds)] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---- 0. ホスト固有設定の読み込みと検証 -------------------------------
# 値が欠けたまま先へ進むと SSH ポートを壊して締め出される恐れがあるため、
# 既定値へのフォールバックはせず必ず異常終了させる。
[[ -f "${SECRETS_FILE}" ]] || die "${SECRETS_FILE} がありません。
  cp ${PLATFORM_DIR}/host-secrets.env.example ${SECRETS_FILE}
  を実行し、SSH_PORT と FAIL2BAN_IGNOREIP_EXTRA を記入してください。"

# shellcheck source=/dev/null
source "${SECRETS_FILE}"

[[ -n "${SSH_PORT:-}" ]] || die "SSH_PORT が ${SECRETS_FILE} に未設定です"

# SSH_PORT はスペース区切りで複数指定できる（ポートローテーションの移行期間用）。
# 例) SSH_PORT="<旧> <新>" … 旧新を同時に待ち受け、疎通確認後に旧を外す
read -ra SSH_PORTS <<< "${SSH_PORT}"
(( ${#SSH_PORTS[@]} > 0 )) || die "SSH_PORT が空です"
for p in "${SSH_PORTS[@]}"; do
  [[ "${p}" =~ ^[0-9]+$ ]] || die "SSH_PORT に数値でない値: ${p}"
  (( p >= 1 && p <= 65535 )) || die "SSH_PORT が範囲外です: ${p}"
done
# fail2ban の port= は CSV 形式
SSH_PORTS_CSV="$(IFS=,; echo "${SSH_PORTS[*]}")"

[[ -n "${FAIL2BAN_IGNOREIP_EXTRA:-}" ]] \
  || die "FAIL2BAN_IGNOREIP_EXTRA が未設定です（管理者の接続元 IP は必須。空だと自分が BAN される）"

log "Loaded host config: SSH_PORT=[${SSH_PORTS[*]}], ignoreip extra=[${FAIL2BAN_IGNOREIP_EXTRA}]"
(( ${#SSH_PORTS[@]} > 1 )) && log "NOTE: SSH ポートを複数待ち受け中（ローテーション移行期間）"

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

# jail.local を展開してコピー
#   - %(here)s は fail2ban が jail.local の置き場所を指すため /etc/fail2ban に置く必要がある
#     → logpath の相対パスを実パスに書き換える
#   - __SSH_PORT__ / __IGNOREIP_EXTRA__ を host-secrets.env の値で埋める
NGINX_LOG_DIR="${PLATFORM_DIR}/log_data/nginx_logs"
sed \
  -e "s|%(here)s/../log_data/nginx_logs|${NGINX_LOG_DIR}|g" \
  -e "s|__SSH_PORT__|${SSH_PORTS_CSV}|g" \
  -e "s|__IGNOREIP_EXTRA__|${FAIL2BAN_IGNOREIP_EXTRA}|g" \
  "${FAIL2BAN_SRC}/jail.local" \
  > /etc/fail2ban/jail.local
chmod 600 /etc/fail2ban/jail.local

# プレースホルダの置換漏れがあれば設定不正なので止める
if grep -q '__SSH_PORT__\|__IGNOREIP_EXTRA__' /etc/fail2ban/jail.local; then
  die "jail.local のプレースホルダ置換に失敗しました"
fi

# カスタムフィルターをコピー
cp -v "${FAIL2BAN_SRC}/filter.d/"*.conf /etc/fail2ban/filter.d/

# デーモン設定（dbpurgeage 等）をコピー
cp -v "${FAIL2BAN_SRC}/fail2ban.local" /etc/fail2ban/fail2ban.local

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

# 現在の待ち受けポートは sshd の実効設定から取得する
# （ss だと sshd 以外の待ち受けを拾ってしまうため）
CURRENT_PORTS="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -un | tr '\n' ' ' | sed 's/ *$//')"
DESIRED_PORTS="$(printf '%s\n' "${SSH_PORTS[@]}" | sort -un | tr '\n' ' ' | sed 's/ *$//')"

if [[ "${CURRENT_PORTS}" == "${DESIRED_PORTS}" ]]; then
  log "SSH port already set to [${DESIRED_PORTS}], skipping"
else
  log "Changing SSH port: [${CURRENT_PORTS}] -> [${DESIRED_PORTS}]"

  # sshd_config.d でポートを明示指定（複数可）
  : > "${SSHD_CONF}"
  for p in "${SSH_PORTS[@]}"; do echo "Port ${p}" >> "${SSHD_CONF}"; done

  # systemd ソケットアクティベーション用オーバーライド
  mkdir -p "$(dirname "${SOCKET_OVERRIDE}")"
  {
    echo "[Socket]"
    echo "ListenStream="
    for p in "${SSH_PORTS[@]}"; do
      echo "ListenStream=0.0.0.0:${p}"
      echo "ListenStream=[::]:${p}"
    done
  } > "${SOCKET_OVERRIDE}"

  sshd -t
  log "sshd config OK. Restarting ssh.socket..."
  systemctl daemon-reload
  systemctl restart ssh.socket

  # 実際に待ち受けが立ったことを確認できなければ即ロールバック
  sleep 2
  for p in "${SSH_PORTS[@]}"; do
    if ! ss -tlnH | grep -qE ":${p}\b"; then
      log "!!! ポート ${p} が LISTEN していません。ロールバックします"
      rm -f "${SSHD_CONF}" "${SOCKET_OVERRIDE}"
      systemctl daemon-reload
      systemctl restart ssh.socket
      die "SSH ポート変更に失敗したため元の設定へ戻しました"
    fi
  done

  log "============================================================"
  log "  SSH listening on: ${DESIRED_PORTS}"
  log "  接続: ssh -p <port> root@<host>"
  log "  ※ 現在のセッションを閉じる前に、必ず別セッションで"
  log "     新ポートへの接続を確認すること。"
  log "  ※ VPS 提供元のパケットフィルタも新ポートの許可が必要な場合がある。"
  log "============================================================"
fi

log "setup-host.sh done."
