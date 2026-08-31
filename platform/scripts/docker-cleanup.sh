#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# docker-cleanup.sh
#
# Docker のビルドキャッシュと dangling イメージを定期的に掃除する（report.md T-10）。
# ビルドキャッシュが 81GB まで肥大しディスク使用率 80% に達した事象（T-1）の再発防止。
#
#   使い方:
#     ./docker-cleanup.sh              # ドライラン（既定。何も削除しない）
#     ./docker-cleanup.sh --apply      # 実際に削除する
#     KEEP_HOURS=336 ./docker-cleanup.sh --apply
#
# ---------------------------------------------------------------------------
# ⚠️ 絶対にやらないこと（意図的に実装していない）
#
#   1. docker volume prune
#        task_demo DB には実アカウントの実データが入っている。ボリュームは
#        「どれが何に紐づくか」を人間が 1 件ずつ確認してからでないと消せない。
#        自動化してはならない。
#
#   2. docker image prune -a
#        -a は「コンテナに使われていないイメージ」を全て消す。wordpress:cli-2.10.0-php8.3
#        のように compose の profile / CI からのみ参照される現役イメージが巻き添えになる。
#        本スクリプトは -a なしの dangling（タグなし）のみを対象にする。
# ---------------------------------------------------------------------------
set -uo pipefail

KEEP_HOURS="${KEEP_HOURS:-168}"          # これより新しいビルドキャッシュは残す（既定 7 日）
LOGFILE="${LOGFILE:-/var/log/docker-cleanup.log}"

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

if [ -f "$LOGFILE" ] && [ "$(stat -c %s "$LOGFILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -n 500 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
fi

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOGFILE"; printf '%s\n' "$*"; }

disk() { df -h / | awk 'NR==2{print $3" 使用 / 空き "$4" ("$5")"}'; }

[ "$APPLY" -eq 1 ] && mode="APPLY" || mode="DRY-RUN"
log "=== docker-cleanup 開始 (mode=$mode, KEEP_HOURS=$KEEP_HOURS) ==="

if ! docker info >/dev/null 2>&1; then
  log "❌ docker に接続できません。中止。"
  exit 1
fi

log "  実行前: $(disk)"
log "  実行前: $(docker system df --format '{{.Type}}={{.Size}}(回収可能 {{.Reclaimable}})' 2>/dev/null | tr '\n' ' ')"

if [ "$APPLY" -eq 1 ]; then
  # --- 1. ビルドキャッシュ（KEEP_HOURS より古いもの）------------------------
  out=$(docker builder prune --force --filter "until=${KEEP_HOURS}h" 2>&1)
  freed=$(printf '%s' "$out" | grep -oE 'Total:[[:space:]]*.*' | head -1)
  log "  [ビルドキャッシュ] ${freed:-回収なし}"

  # --- 2. dangling イメージ（タグなし。-a は使わない）----------------------
  out=$(docker image prune --force 2>&1)
  freed=$(printf '%s' "$out" | grep -oE 'Total reclaimed space:[[:space:]]*.*' | head -1)
  log "  [dangling イメージ] ${freed:-回収なし}"

  # --- 3. 停止済みコンテナ（restart: unless-stopped のため通常は存在しない）--
  out=$(docker container prune --force --filter "until=${KEEP_HOURS}h" 2>&1)
  freed=$(printf '%s' "$out" | grep -oE 'Total reclaimed space:[[:space:]]*.*' | head -1)
  log "  [停止済みコンテナ] ${freed:-回収なし}"
else
  bc=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | awk -F'\t' '$1=="Build Cache"{print $2}')
  im=$(docker images -qf dangling=true 2>/dev/null | wc -l)
  ct=$(docker ps -aq --filter status=exited --filter status=created 2>/dev/null | wc -l)
  log "  [ビルドキャッシュ] 回収可能 ${bc:-不明}（うち ${KEEP_HOURS}h より古い分が対象）"
  log "  [dangling イメージ] ${im} 件"
  log "  [停止済みコンテナ] ${ct} 件"
  log "  ※ドライランのため削除は実行していない"
fi

log "  実行後: $(disk)"

# ディスクが逼迫している場合は警告を残す（T-9 の監視が入るまでの暫定）
used=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if [ "$used" -ge 85 ]; then
  log "  ⚠️ 警告: 掃除後もディスク使用率 ${used}%。手動での棚卸しが必要（report.md T-3 / T-11 参照）"
fi

log "=== 完了 ==="
exit 0
