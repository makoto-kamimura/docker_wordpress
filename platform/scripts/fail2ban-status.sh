#!/bin/sh
# =====================================================================
# fail2ban 状況レポート
#   現在 BAN 中の IP と、直近の BAN / UNBAN を集計して JSON で返す。
#
#   例:
#     ./fail2ban-status.sh              # 直近 24 時間
#     ./fail2ban-status.sh --hours 168
#
#   現在 BAN 中の一覧は 2 通りの取り方がある:
#     fail2ban-client … ホストで実行した場合。現在の状態そのもので正確。
#     ログの再生       … n8n コンテナから実行した場合。fail2ban.log の
#                        Ban / Restore Ban / Unban を順に適用して求める。
#                        ローテートで流れた分は追えないため、古い BAN
#                        (recidive は最大 4 週間) を取りこぼすことがある。
#   どちらで求めたかは JSON の banned_source に入れる。
#
#   出力は stdout に JSON のみ。診断メッセージは stderr に出す。
# =====================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/report-common.sh
. "${SCRIPT_DIR}/lib/report-common.sh"

LOG_FILE="${F2B_LOG_FILE:-/var/log/fail2ban.log}"

# fail2ban はホストで動いているため、ログの時刻はホストのローカル時刻 (JST)
LOG_TZ="${F2B_LOG_TZ:-local}"

HOURS=24
LIMIT=10
BANNED_MAX=200   # currently_banned に並べる上限 (件数は常に正確に出す)

usage() {
  cat >&2 <<'EOF'
Usage: fail2ban-status.sh [options]

  --hours N   recent_bans / top_banned_ips の集計範囲 (既定: 24)
  --limit N   各ランキングの件数 (既定: 10)
  --log PATH  読み込む fail2ban.log のパス
  -h, --help  このヘルプ

環境変数 F2B_LOG_FILE / F2B_LOG_TZ でも同じ指定ができる。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours) require_num --hours "${2:-}"; HOURS="$2"; shift 2 ;;
    --limit) require_num --limit "${2:-}"; LIMIT="$2"; shift 2 ;;
    --log)   LOG_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 不明な引数: $1" >&2; usage; exit 2 ;;
  esac
done

HOURS="$(clamp "$HOURS" 1 720)"
LIMIT="$(clamp "$LIMIT" 1 50)"

[ -r "$LOG_FILE" ] || {
  echo "ERROR: fail2ban のログを読めません: $LOG_FILE" >&2
  echo "       (n8n コンテナから実行する場合は docker-compose.yml のマウントを確認)" >&2
  exit 1
}

SINCE="$(since_stamp "$LOG_TZ" "$HOURS" '%Y-%m-%d %H:%M:%S')"
GENERATED_AT="$(now_iso)"

# ---- ログが生きているかの確認 ---------------------------------------
# fail2ban.log は logrotate の create 方式 (週次) でローテートされる。
# n8n コンテナにはこのファイルを 1 個だけバインドマウントしているため、
# ローテート後もコンテナ内は「古い方の実体」を掴んだままになり、
# 更新の止まったログを読み続けてしまう (エラーは出ない)。
# fail2ban は Found 行を常時書いているので、更新が長時間止まっていれば
# ローテート後のマウントずれとみなして stale を立てる。
#   直し方: docker compose restart n8n (再起動でマウントし直される)
STALE_MIN="${F2B_STALE_MIN:-360}"
LOG_AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0) ) / 60 ))
STALE=false
if [ "$LOG_AGE_MIN" -gt "$STALE_MIN" ]; then
  STALE=true
  echo "WARN: ${LOG_FILE} が ${LOG_AGE_MIN} 分間更新されていません (ローテート後のマウントずれの可能性)" >&2
fi

EVENTS="$(mktemp)"     # 1 行 = BAN/UNBAN イベント: ts jail action ip
BANNED="$(mktemp)"     # 1 行 = 現在 BAN 中: jail ip since
trap 'rm -f "$EVENTS" "$BANNED"' EXIT INT TERM

# ---- ログからイベントを取り出す -------------------------------------
# 例:
#   2026-09-23 06:18:46,598 fail2ban.actions [274]: NOTICE  [nginx-modsecurity] Ban 1.2.3.4
#   2026-09-23 09:13:43,236 fail2ban.actions [274]: NOTICE  [nginx-modsecurity] Unban 1.2.3.4
# ローテート済みのログも読めるなら古い順に連結する (現在 BAN 中の再現精度が上がる)。
{
  for f in "${LOG_FILE}.4.gz" "${LOG_FILE}.3.gz" "${LOG_FILE}.2.gz" "${LOG_FILE}.1.gz"; do
    [ -r "$f" ] && zcat "$f" 2>/dev/null || true
  done
  for f in "${LOG_FILE}.4" "${LOG_FILE}.3" "${LOG_FILE}.2" "${LOG_FILE}.1"; do
    [ -r "$f" ] && cat "$f" || true
  done
  cat "$LOG_FILE"
} | awk '
  # [jail] Ban 1.2.3.4 / [jail] Unban ... / [jail] Restore Ban ...
  # 先に出てくる [PID] は "] Ban " が続かないためマッチしない
  match($0, /\[[^]]+\] (Ban|Unban|Restore Ban) /) {
    seg = substr($0, RSTART, RLENGTH)
    jail = seg; sub(/^\[/, "", jail); sub(/\].*/, "", jail)
    act = seg;  sub(/^\[[^]]+\] /, "", act); sub(/ +$/, "", act)
    if (act == "Restore Ban") act = "Ban"
    ip = $NF
    if (ip !~ /^[0-9a-fA-F.:]+$/) next
    printf "%s %s\t%s\t%s\t%s\n", $1, substr($2, 1, 8), jail, act, ip
  }
' > "$EVENTS"

# ---- 現在 BAN 中 ----------------------------------------------------
BANNED_SOURCE=log
if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
  BANNED_SOURCE=fail2ban-client
  jails="$(fail2ban-client status 2>/dev/null \
    | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' \t' | tr ',' ' ')"
  for j in $jails; do
    fail2ban-client status "$j" 2>/dev/null \
      | sed -n 's/.*Banned IP list:[[:space:]]*//p' \
      | tr ' ' '\n' | grep -v '^$' \
      | awk -v j="$j" '{ print j "\t" $1 }'
  done > "$BANNED"
else
  # Ban / Unban を古い順に適用して、今も残っている組み合わせを求める
  awk -F'\t' '
    $3 == "Ban"   { banned[$2 SUBSEP $4] = $1 }
    $3 == "Unban" { delete banned[$2 SUBSEP $4] }
    END {
      for (k in banned) {
        split(k, p, SUBSEP)
        printf "%s\t%s\t%s\n", p[1], p[2], banned[k]
      }
    }
  ' "$EVENTS" | sort > "$BANNED"
fi

currently_banned="$(wc -l < "$BANNED" | tr -d ' ')"

# ---- 集計 -----------------------------------------------------------
RECENT="$(mktemp)"
trap 'rm -f "$EVENTS" "$BANNED" "$RECENT"' EXIT INT TERM
awk -F'\t' -v since="$SINCE" '$1 >= since' "$EVENTS" > "$RECENT"

bans_in_window="$(awk -F'\t'   '$3 == "Ban"   { n++ } END { print n + 0 }' "$RECENT")"
unbans_in_window="$(awk -F'\t' '$3 == "Unban" { n++ } END { print n + 0 }' "$RECENT")"

banned_by_jail="$(
  awk -F'\t' '{ c[$1]++ } END { for (k in c) printf "%d\t%s\n", c[k], k }' "$BANNED" \
  | sort -rn | to_json_array jail
)"

banned_list="$(
  head -n "$BANNED_MAX" "$BANNED" | awk -F'\t' "$AWK_ESC"'
    {
      printf "%s{\"jail\":\"%s\",\"ip\":\"%s\"", (NR > 1 ? ",\n      " : ""), esc($1), esc($2)
      if ($3 != "") printf ",\"banned_at\":\"%s\"", esc($3)
      printf "}"
    }
  '
)"

BANS="$(mktemp)"
trap 'rm -f "$EVENTS" "$BANNED" "$RECENT" "$BANS"' EXIT INT TERM
awk -F'\t' '$3 == "Ban"' "$RECENT" > "$BANS"

top_banned_ips="$(topn "$BANS" 4 0 "$LIMIT" | to_json_array ip)"

recent_bans="$(
  tail -n "$LIMIT" "$BANS" | awk -F'\t' "$AWK_ESC"'
    {
      printf "%s{\"time\":\"%s\",\"jail\":\"%s\",\"ip\":\"%s\"}",
        (NR > 1 ? ",\n      " : ""), esc($1), esc($2), esc($4)
    }
  '
)"

# jail の一覧は fail2ban-client が使えるならその出力を、使えないなら
# ログに現れた jail を使う (後者は BAN が一度も出ていない jail が載らない)
jail_list="$(
  # shellcheck disable=SC2086  # jail 名を空白で分割したいので引用しない
  { [ -n "${jails:-}" ] && printf '%s\n' $jails
    cut -f2 "$EVENTS"
    true
  } | sort -u | grep -v '^$' | awk "$AWK_ESC"'
    { printf "%s\"%s\"", (NR > 1 ? ", " : ""), esc($0) }
  '
)"

cat <<EOF
{
  "generated_at": "${GENERATED_AT}",
  "source": "$(basename "$LOG_FILE")",
  "banned_source": "${BANNED_SOURCE}",
  "log": { "path": "${LOG_FILE}", "idle_minutes": ${LOG_AGE_MIN}, "stale": ${STALE} },
  "window": { "hours": ${HOURS}, "since": "${SINCE}", "log_tz": "${LOG_TZ}" },
  "summary": {
    "currently_banned": ${currently_banned},
    "bans_in_window": ${bans_in_window},
    "unbans_in_window": ${unbans_in_window},
    "listed": $( [ "$currently_banned" -gt "$BANNED_MAX" ] && echo "$BANNED_MAX" || echo "$currently_banned" )
  },
  "jails": [ ${jail_list} ],
  "currently_banned_by_jail": [
      ${banned_by_jail}
  ],
  "currently_banned": [
      ${banned_list}
  ],
  "top_banned_ips": [
      ${top_banned_ips}
  ],
  "recent_bans": [
      ${recent_bans}
  ]
}
EOF
