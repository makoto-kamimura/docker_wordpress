#!/bin/sh
# =====================================================================
# nginx アクセスログ集計レポート
#   access.log を集計して JSON で返す。ステータス別の件数、よく叩かれた
#   パス、404 が多いパス、上位のアクセス元 IP / User-Agent、時間帯別の件数。
#
#   例:
#     ./access-summary.sh                          # 直近 24 時間
#     ./access-summary.sh --hours 1 --limit 20
#     ./access-summary.sh --hours 168 --include-internal
#
#   出力は stdout に JSON のみ。診断メッセージは stderr に出す。
#
#   前提にしているログ書式 (nginx_data/conf.d/logging.conf の log_format main):
#     $realip_remote_addr - $remote_user [$time_local] "$request"
#     $status $body_bytes_sent "$http_referer" "$http_user_agent"
#     "$http_x_forwarded_for"
#   末尾に項目を足した場合 (例: $request_time) もそのまま動く。
# =====================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/report-common.sh
. "${SCRIPT_DIR}/lib/report-common.sh"

LOG_FILE="${ACCESS_LOG_FILE:-${SCRIPT_DIR}/../log_data/nginx_logs/access.log}"

HOURS=24
LIMIT=10
INCLUDE_INTERNAL=0

# access.log は 200MB を超える。末尾から読み、集計期間の開始まで届いていなければ
# 読む量を倍にして読み直す (足りないまま集計すると件数が黙って少なく出る)。
START_BYTES="${ACCESS_START_BYTES:-16777216}"    # 16MiB から開始
MAX_BYTES="${ACCESS_MAX_BYTES:-268435456}"       # 256MiB で打ち切り

usage() {
  cat >&2 <<'EOF'
Usage: access-summary.sh [options]

  --hours N           集計する時間範囲 (既定: 24)
  --limit N           各ランキングの件数 (既定: 10)
  --include-internal  Docker 内部 / プライベート IP からのアクセスも集計に含める
                      (既定では wp-cron などの内部通信を除外し、件数だけ
                       summary.internal_requests に出す)
  --log PATH          読み込む access.log のパス
  -h, --help          このヘルプ

環境変数 ACCESS_LOG_FILE / ACCESS_MAX_BYTES / ACCESS_LOG_TZ でも指定できる。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours) require_num --hours "${2:-}"; HOURS="$2"; shift 2 ;;
    --limit) require_num --limit "${2:-}"; LIMIT="$2"; shift 2 ;;
    --include-internal) INCLUDE_INTERNAL=1; shift ;;
    --log)   LOG_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 不明な引数: $1" >&2; usage; exit 2 ;;
  esac
done

HOURS="$(clamp "$HOURS" 1 720)"
LIMIT="$(clamp "$LIMIT" 1 50)"

[ -r "$LOG_FILE" ] || { echo "ERROR: ログを読めません: $LOG_FILE" >&2; exit 1; }

# ---- 集計開始時刻 ---------------------------------------------------
# $time_local は nginx コンテナのローカル時刻で、末尾に UTC オフセットが付く
#   例: [23/Sep/2026:06:25:02 +0000]
# ログ自身が持っているオフセットを読み、それに合わせて開始時刻を作る。
LOG_TZ="${ACCESS_LOG_TZ:-}"
if [ -z "$LOG_TZ" ]; then
  LOG_TZ="$(tail -c 8192 "$LOG_FILE" \
    | sed -n 's/^[^[]*\[[^]]* \([+-][0-9][0-9][0-9][0-9]\)\].*/\1/p' | tail -1)"
  [ -n "$LOG_TZ" ] || LOG_TZ='+0000'
fi

# 比較用 (YYYYMMDDHHMMSS / 数値比較できる) と表示用
SINCE_CMP="$(since_stamp "$LOG_TZ" "$HOURS" '%Y%m%d%H%M%S')"
SINCE_DISP="$(since_stamp "$LOG_TZ" "$HOURS" '%d/%b/%Y:%H:%M:%S')"
[ -n "$SINCE_CMP" ] || { echo "ERROR: 開始時刻を計算できませんでした" >&2; exit 1; }

GENERATED_AT="$(now_iso)"

# ログ行の先頭にある時刻を YYYYMMDDHHMMSS に直す (awk と同じ変換)
AWK_TS='
  BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
    for (i = 1; i <= 12; i++) mon[mn[i]] = sprintf("%02d", i)
  }
  # busybox awk の正規表現は {n} 回数指定を扱えないことがあるため使わない
  function line_ts(line,   t, m) {
    if (!match(line, /\[[0-9][0-9]\/[A-Za-z][A-Za-z][A-Za-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) return ""
    t = substr(line, RSTART + 1, RLENGTH - 1)
    m = mon[substr(t, 4, 3)]
    if (m == "") return ""
    return substr(t, 8, 4) m substr(t, 1, 2) substr(t, 13, 2) substr(t, 16, 2) substr(t, 19, 2)
  }
'

# ---- 読む量を決める -------------------------------------------------
# 末尾 N バイトの先頭行が集計開始時刻より古ければ、その範囲で足りている。
file_size="$(wc -c < "$LOG_FILE")"
BYTES="$START_BYTES"
TRUNCATED=false
while [ "$BYTES" -lt "$file_size" ]; do
  first_ts="$(read_tail "$LOG_FILE" "$BYTES" | head -1 | awk "$AWK_TS"'{ print line_ts($0) }')"
  if [ -n "$first_ts" ] && [ "$first_ts" -lt "$SINCE_CMP" ]; then break; fi
  if [ "$BYTES" -ge "$MAX_BYTES" ]; then
    TRUNCATED=true
    echo "WARN: ${MAX_BYTES} バイトまで読みましたが集計期間の先頭に届きません (結果は一部のみ)" >&2
    break
  fi
  BYTES=$(( BYTES * 2 ))
  if [ "$BYTES" -gt "$MAX_BYTES" ]; then BYTES="$MAX_BYTES"; fi
done

TSV="$(mktemp)"
trap 'rm -f "$TSV" "${TSV}.f" "${TSV}.404"' EXIT INT TERM

# ---- 抽出 -----------------------------------------------------------
# access.log -> TSV
#   1 ts  2 ip  3 method  4 path  5 status  6 bytes  7 ua  8 hour  9 scope
#
# 行は " で分割する。nginx は値の中の " を \x22 に置換して書くため、
# 引用符の数は常に一定になる:
#   a[1]=先頭  a[2]=request  a[3]=status/bytes  a[4]=referer  a[6]=UA  a[8]=XFF
read_tail "$LOG_FILE" "$BYTES" | awk -v since="$SINCE_CMP" "$AWK_TS$AWK_TEXT"'
  {
    ts = line_ts($0)
    if (ts == "" || ts < since) next

    n = split($0, a, "\"")
    if (n < 4) next

    split(a[1], head, " ")
    ip = head[1]

    split(a[2], req, " ")
    method = req[1]
    uri    = req[2]
    if (method == "" || uri == "") next
    path = uri
    sub(/\?.*/, "", path)

    split(a[3], sb, " ")
    status = sb[1] + 0
    bytes  = sb[2] + 0

    ua = (n >= 6 ? a[6] : "")

    # Docker ブリッジ網や localhost からの通信 (wp-cron 等) は外部アクセスと分ける
    scope = "external"
    if (ip ~ /^127\./ || ip ~ /^10\./ || ip ~ /^192\.168\./ ||
        ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ || ip == "::1" || ip == "-")
      scope = "internal"

    printf "%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\n",
      ts, ip, clean(method, 16), clean(path, 200), status, bytes,
      clean(ua, 160), substr(ts, 1, 10), scope
  }
' > "$TSV"

internal_requests="$(awk -F'\t' '$9 == "internal" { n++ } END { print n + 0 }' "$TSV")"

if [ "$INCLUDE_INTERNAL" -eq 1 ]; then
  cp "$TSV" "${TSV}.f"
else
  awk -F'\t' '$9 == "external"' "$TSV" > "${TSV}.f"
fi
TSVF="${TSV}.f"

# ---- 集計 -----------------------------------------------------------
requests="$(wc -l < "$TSVF" | tr -d ' ')"
uniq_ips="$(cut -f2 "$TSVF" | grep -v '^$' | sort -u | wc -l | tr -d ' ')"
bytes_sent="$(awk -F'\t' '{ s += $6 } END { printf "%d", s + 0 }' "$TSVF")"

class_count() { awk -F'\t' -v c="$1" '$5 >= c && $5 < c + 100 { n++ } END { print n + 0 }' "$TSVF"; }
ok_2xx="$(class_count 200)"
red_3xx="$(class_count 300)"
err_4xx="$(class_count 400)"
err_5xx="$(class_count 500)"

# bot らしさは UA の自称でしか判断できない。参考値として件数だけ出す。
bot_requests="$(awk -F'\t' '
  { u = tolower($7) }
  u ~ /bot|crawl|spider|slurp|curl|wget|python-requests|go-http|scan/ { n++ }
  END { print n + 0 }
' "$TSVF")"

by_status="$(topn "$TSVF" 5 0 20         | to_json_array status)"
top_ips="$(topn "$TSVF" 2 0 "$LIMIT"     | to_json_array ip)"
top_paths="$(topn "$TSVF" 4 0 "$LIMIT"   | to_json_array path)"
top_methods="$(topn "$TSVF" 3 0 10       | to_json_array method)"
top_user_agents="$(topn "$TSVF" 7 0 "$LIMIT" | to_json_array user_agent)"

# 404 が多いパスは、スキャンされている入口か、こちらのリンク切れかの判断材料になる
awk -F'\t' '$5 == 404' "$TSVF" > "${TSV}.404"
top_404="$(topn "${TSV}.404" 4 0 "$LIMIT" | to_json_array path)"

# 時間帯別 (YYYYMMDDHH)。件数の急増を見るためのもの。
by_hour="$(
  awk -F'\t' '{ c[$8]++ } END { for (k in c) printf "%s\t%d\n", k, c[k] }' "$TSVF" \
  | sort | awk "$AWK_ESC"'
      {
        printf "%s{\"hour\":\"%s\",\"count\":%d}",
          (NR > 1 ? ",\n      " : ""),
          esc(substr($1,1,4) "-" substr($1,5,2) "-" substr($1,7,2) "T" substr($1,9,2)), $2
      }
    '
)"

cat <<EOF
{
  "generated_at": "${GENERATED_AT}",
  "source": "$(basename "$LOG_FILE")",
  "window": { "hours": ${HOURS}, "since": "${SINCE_DISP} ${LOG_TZ}", "log_tz": "${LOG_TZ}" },
  "scan": { "bytes_read": ${BYTES}, "file_bytes": ${file_size}, "truncated": ${TRUNCATED} },
  "summary": {
    "requests": ${requests},
    "unique_ips": ${uniq_ips},
    "bytes_sent": ${bytes_sent},
    "status_2xx": ${ok_2xx},
    "status_3xx": ${red_3xx},
    "status_4xx": ${err_4xx},
    "status_5xx": ${err_5xx},
    "bot_requests": ${bot_requests},
    "internal_requests": ${internal_requests},
    "internal_included": $( [ "$INCLUDE_INTERNAL" -eq 1 ] && echo true || echo false )
  },
  "by_status": [
      ${by_status}
  ],
  "top_ips": [
      ${top_ips}
  ],
  "top_paths": [
      ${top_paths}
  ],
  "top_404": [
      ${top_404}
  ],
  "top_methods": [
      ${top_methods}
  ],
  "top_user_agents": [
      ${top_user_agents}
  ],
  "by_hour": [
      ${by_hour}
  ]
}
EOF
