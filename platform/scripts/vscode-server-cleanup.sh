#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# vscode-server-cleanup.sh
#
# 一定時間アイドルな VS Code Server（server-main.js）のセッションを停止する。
# `--enable-remote-auto-shutdown` が効かず旧セッションが積み上がる問題への対策。
#
#   使い方:
#     ./vscode-server-cleanup.sh              # ドライラン（既定。何も停止しない）
#     ./vscode-server-cleanup.sh --apply      # 実際に停止する
#     IDLE_HOURS=48 ./vscode-server-cleanup.sh --apply
#
# アイドル判定は「そのセッションのログディレクトリの最終更新時刻」で行う。
# VS Code Server は接続中は継続的にログを書くため、書き込みが止まっている
# = クライアントが切断済み、と判断できる。
#
# 安全装置（いずれかに該当したら停止しない）:
#   1. ログの最終更新が IDLE_HOURS 以内
#   2. 最も新しく活動したセッション（＝現行セッション）は常に除外
#   3. ログディレクトリを特定できない（判断がつかないものは触らない）
#   4. IDLE_HOURS 以内に起動した子プロセスを持つ（作業中の可能性）
# ---------------------------------------------------------------------------
set -uo pipefail

IDLE_HOURS="${IDLE_HOURS:-24}"
LOGDIR_ROOT="${LOGDIR_ROOT:-/root/.vscode-server/data/logs}"
LOGFILE="${LOGFILE:-/var/log/vscode-server-cleanup.log}"
GRACE_SECONDS="${GRACE_SECONDS:-10}"

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

threshold=$(( IDLE_HOURS * 3600 ))
now=$(date +%s)

# ログが肥大しないよう 1MB を超えたら切り詰める
if [ -f "$LOGFILE" ] && [ "$(stat -c %s "$LOGFILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -n 500 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
fi

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOGFILE"; printf '%s\n' "$*"; }

[ "$APPLY" -eq 1 ] && mode="APPLY" || mode="DRY-RUN"
log "=== vscode-server-cleanup 開始 (mode=$mode, IDLE_HOURS=$IDLE_HOURS) ==="

# --- 対象セッションの列挙 -------------------------------------------------
mapfile -t servers < <(pgrep -f 'out/server-main\.js' 2>/dev/null)
if [ "${#servers[@]}" -eq 0 ]; then
  log "server-main.js プロセスなし。終了。"
  exit 0
fi

# セッション PID → ログディレクトリ を解決する
#   1) 子孫プロセスの --logsPath 引数から取得（確実）
#   2) 取れない場合はプロセス起動時刻に一致するログディレクトリ名から推定
resolve_logdir() {
  local pid=$1 d=""
  # 子孫の --logsPath を探す
  local kids
  kids=$(pgrep -P "$pid" 2>/dev/null)
  for k in $pid $kids $(for kk in $kids; do pgrep -P "$kk" 2>/dev/null; done); do
    d=$(tr '\0' '\n' < "/proc/$k/cmdline" 2>/dev/null | grep -A1 -x -- '--logsPath' | tail -1)
    [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }
    d=$(tr '\0' '\n' < "/proc/$k/cmdline" 2>/dev/null | grep -oE -- "--logsPath=[^ ]+" | cut -d= -f2-)
    [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  # 起動時刻から推定（±90 秒以内に作られたログディレクトリ）
  local started
  started=$(stat -c %Y "/proc/$pid" 2>/dev/null) || return 1
  for cand in "$LOGDIR_ROOT"/*/; do
    [ -d "$cand" ] || continue
    local ct; ct=$(stat -c %Y "$cand" 2>/dev/null) || continue
    local diff=$(( ct - started )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
    [ "$diff" -le 90 ] && { printf '%s' "${cand%/}"; return 0; }
  done
  return 1
}

# ログディレクトリ配下の最終更新時刻（epoch）
last_activity() {
  find "$1" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1
}

# --- 各セッションを評価 ---------------------------------------------------
declare -A ACT LOGD
newest_pid=""; newest_ts=0

for pid in "${servers[@]}"; do
  d=$(resolve_logdir "$pid") || { LOGD[$pid]=""; continue; }
  LOGD[$pid]="$d"
  ts=$(last_activity "$d"); [ -z "$ts" ] && ts=0
  ACT[$pid]=$ts
  if [ "$ts" -gt "$newest_ts" ]; then newest_ts=$ts; newest_pid=$pid; fi
done

killed=0; kept=0
for pid in "${servers[@]}"; do
  d="${LOGD[$pid]:-}"
  if [ -z "$d" ]; then
    log "  [保持] PID $pid : ログディレクトリを特定できず（安全側に倒して保持）"
    kept=$((kept+1)); continue
  fi

  ts="${ACT[$pid]:-0}"
  idle=$(( now - ts ))
  idle_h=$(( idle / 3600 )); idle_m=$(( (idle % 3600) / 60 ))

  if [ "$pid" = "$newest_pid" ]; then
    log "  [保持] PID $pid : 最も新しく活動したセッション（アイドル ${idle_h}h${idle_m}m）"
    kept=$((kept+1)); continue
  fi

  if [ "$idle" -lt "$threshold" ]; then
    log "  [保持] PID $pid : アイドル ${idle_h}h${idle_m}m < ${IDLE_HOURS}h"
    kept=$((kept+1)); continue
  fi

  # 子孫に IDLE_HOURS 以内に起動したプロセスがあれば作業中とみなす
  recent_child=0
  for k in $(pgrep -P "$pid" 2>/dev/null); do
    cs=$(stat -c %Y "/proc/$k" 2>/dev/null) || continue
    [ $(( now - cs )) -lt "$threshold" ] && { recent_child=1; break; }
  done
  if [ "$recent_child" -eq 1 ]; then
    log "  [保持] PID $pid : ${IDLE_HOURS}h 以内に起動した子プロセスあり（作業中の可能性）"
    kept=$((kept+1)); continue
  fi

  rss=$( (ps -o rss= -p "$pid"; for k in $(pgrep -P "$pid" 2>/dev/null); do ps -o rss= -p "$k"; done) 2>/dev/null | awk '{s+=$1} END {printf "%d", s/1024}')
  if [ "$APPLY" -eq 1 ]; then
    log "  [停止] PID $pid : アイドル ${idle_h}h${idle_m}m / 約 ${rss}MB / logs=$(basename "$d")"
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 "$GRACE_SECONDS"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then
      log "         SIGTERM で終了せず → SIGKILL"
      kill -KILL "$pid" 2>/dev/null
    fi
    killed=$((killed+1))
  else
    log "  [停止対象] PID $pid : アイドル ${idle_h}h${idle_m}m / 約 ${rss}MB / logs=$(basename "$d")  ※ドライランのため実行せず"
    killed=$((killed+1))
  fi
done

log "=== 完了: 停止$([ "$APPLY" -eq 1 ] || echo '対象') ${killed} 件 / 保持 ${kept} 件 ==="
exit 0
