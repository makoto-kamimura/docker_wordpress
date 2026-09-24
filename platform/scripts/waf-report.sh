#!/bin/sh
# =====================================================================
# ModSecurity (WAF) 検知レポート
#   nginx の error.log から ModSecurity の検知行を抽出し、集計を JSON で返す。
#
#   例:
#     ./waf-report.sh                        # 直近 24 時間
#     ./waf-report.sh --hours 1 --recent 20  # 直近 1 時間、生ログ 20 件付き
#
#   出力は stdout に JSON のみ。診断メッセージは stderr に出す
#   (呼び出し元が JSON をそのままパースできるようにするため)。
#
#   lib/common.sh (bash) ではなく lib/report-common.sh (POSIX sh) を読むのは意図的:
#   このスクリプトは n8n コンテナ (Alpine / busybox, bash なし) からも
#   実行するため、POSIX sh + awk だけで完結させている。
# =====================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/report-common.sh
. "${SCRIPT_DIR}/lib/report-common.sh"

# 既定の入力は platform/log_data/nginx_logs/error.log (nginx_logs ボリュームの実体)。
# n8n コンテナからはマウント先が違うため WAF_LOG_FILE で上書きする。
LOG_FILE="${WAF_LOG_FILE:-${SCRIPT_DIR}/../log_data/nginx_logs/error.log}"

# nginx コンテナには TZ を渡していないため error.log は UTC で記録される。
# (ホストや n8n コンテナは JST なので、ローカル時刻で窓を切ると 9 時間ずれる)
LOG_TZ="${WAF_LOG_TZ:-utc}"

HOURS=24
LIMIT=10
RECENT=10
# error.log は数十 MB まで育つ。全走査を避けるため末尾のみ読む (既定 64MiB)。
MAX_BYTES="${WAF_MAX_BYTES:-67108864}"

usage() {
  cat >&2 <<'EOF'
Usage: waf-report.sh [options]

  --hours N    集計する時間範囲 (既定: 24)
  --limit N    top_rules / top_ips / top_uris の件数 (既定: 10)
  --recent N   recent に含める直近のブロック件数 (既定: 10)
  --log PATH   読み込む error.log のパス
  -h, --help   このヘルプ

環境変数 WAF_LOG_FILE / WAF_MAX_BYTES / WAF_LOG_TZ でも同じ指定ができる。
WAF_LOG_TZ はログ側のタイムゾーン (utc | local | +HHMM、既定 utc)。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours)  require_num --hours  "${2:-}"; HOURS="$2";  shift 2 ;;
    --limit)  require_num --limit  "${2:-}"; LIMIT="$2";  shift 2 ;;
    --recent) require_num --recent "${2:-}"; RECENT="$2"; shift 2 ;;
    --log)    LOG_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 不明な引数: $1" >&2; usage; exit 2 ;;
  esac
done

HOURS="$(clamp "$HOURS" 1 720)"
LIMIT="$(clamp "$LIMIT" 1 50)"
RECENT="$(clamp "$RECENT" 0 100)"

[ -r "$LOG_FILE" ] || { echo "ERROR: ログを読めません: $LOG_FILE" >&2; exit 1; }

# error.log の時刻表記は "YYYY/MM/DD HH:MM:SS" で、辞書順 = 時系列順。
# そのため awk では文字列比較でそのまま範囲を絞れる。
SINCE="$(since_stamp "$LOG_TZ" "$HOURS" '%Y/%m/%d %H:%M:%S')"
[ -n "$SINCE" ] || { echo "ERROR: 開始時刻を計算できませんでした" >&2; exit 1; }

GENERATED_AT="$(now_iso)"

TSV="$(mktemp)"
trap 'rm -f "$TSV"' EXIT INT TERM

# ---- 抽出 -----------------------------------------------------------
# error.log -> TSV (1 行 = ModSecurity の検知 1 件)
#   1 ts  2 ip  3 action  4 rule_id  5 severity  6 uri  7 msg  8 request  9 server  10 unique_id
#
# ModSecurity は 1 リクエストにつき、マッチしたルールごとに "Warning" 行を出し、
# 遮断した場合はさらに "Access denied" 行を出す。件数はこの両方を分けて数える。
read_tail "$LOG_FILE" "$MAX_BYTES" | grep -aF 'ModSecurity:' | awk -v since="$SINCE" "$AWK_TEXT"'
  # [key "value"] 形式の取り出し
  function tagval(line, key,   s) {
    if (match(line, "\\[" key " \"[^\"]*\"")) {
      s = substr(line, RSTART, RLENGTH)
      sub("^\\[" key " \"", "", s)
      sub("\"$", "", s)
      return s
    }
    return ""
  }
  # key: "value" 形式 (request など)
  function quoted(line, key,   s) {
    if (match(line, key ": \"[^\"]*\"")) {
      s = substr(line, RSTART, RLENGTH)
      sub("^" key ": \"", "", s)
      sub("\"$", "", s)
      return s
    }
    return ""
  }

  {
    ts = substr($0, 1, 19)
    if (ts < since) next

    # [client 1.2.3.4] を優先。無ければ末尾の client: 1.2.3.4 を使う。
    ip = ""
    if (match($0, /\[client [^]]*\]/)) {
      ip = substr($0, RSTART + 8, RLENGTH - 9)
    } else if (match($0, /client: [^,]*/)) {
      ip = substr($0, RSTART + 8, RLENGTH - 8)
    }

    if (index($0, "Access denied") > 0)      action = "blocked"
    else if (index($0, "ModSecurity: Warning") > 0) action = "warning"
    else                                     action = "other"

    server = ""
    if (match($0, /server: [^,]*/)) server = substr($0, RSTART + 8, RLENGTH - 8)

    # msg には検証エラーの全文が入ることがあり、そのままだと 1 件で数百文字になる
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
      ts, ip, action,
      tagval($0, "id"), tagval($0, "severity"),
      clean(tagval($0, "uri")), clean(tagval($0, "msg")),
      clean(quoted($0, "request")), clean(server),
      tagval($0, "unique_id")
  }
' > "$TSV"

# ---- JSON 組み立て --------------------------------------------------
count_where() { awk -F'\t' -v a="$1" "\$3 == a { n++ } END { print n + 0 }" "$TSV"; }
count_uniq()  { cut -f"$1" "$TSV" | grep -v '^$' | sort -u | wc -l | tr -d ' '; }

total="$(wc -l < "$TSV" | tr -d ' ')"
blocked="$(count_where blocked)"
warnings="$(count_where warning)"
uniq_ips="$(count_uniq 2)"
uniq_rules="$(count_uniq 4)"
uniq_reqs="$(count_uniq 10)"

# ルールは ID 単位でまとめる。msg には可変部分 (Total Score: N) が入るため、
# msg でグループ化すると同じルールがスコア違いで分裂してしまう。
top_rules="$(
  awk -F'\t' '
    $4 != "" {
      c[$4]++
      if (!($4 in sample)) sample[$4] = $7
    }
    END { for (k in c) printf "%d\t%s\t%s\n", c[k], k, sample[k] }
  ' "$TSV" | sort -rn | head -n "$LIMIT" | to_json_array rule_id msg_sample
)"
top_ips="$(topn "$TSV" 2 0 "$LIMIT"  | to_json_array ip)"
top_uris="$(topn "$TSV" 6 0 "$LIMIT" | to_json_array uri)"

# recent は遮断されたものを優先。無ければ警告を含めて直近を返す。
recent="$(
  { awk -F'\t' '$3 == "blocked"' "$TSV" | tail -n "$RECENT"
    [ "$blocked" -eq 0 ] && tail -n "$RECENT" "$TSV"
    true
  } | awk -F'\t' "$AWK_ESC"'
    {
      printf "%s{\"time\":\"%s\",\"ip\":\"%s\",\"action\":\"%s\",\"rule_id\":\"%s\",\"severity\":\"%s\",\"uri\":\"%s\",\"msg\":\"%s\",\"request\":\"%s\",\"server\":\"%s\"}",
        (NR > 1 ? ",\n      " : ""),
        esc($1), esc($2), esc($3), esc($4), esc($5), esc($6), esc($7), esc($8), esc($9)
    }
  '
)"

cat <<EOF
{
  "generated_at": "${GENERATED_AT}",
  "source": "$(basename "$LOG_FILE")",
  "window": { "hours": ${HOURS}, "since": "${SINCE}", "log_tz": "${LOG_TZ}" },
  "summary": {
    "events": ${total},
    "blocked": ${blocked},
    "warnings": ${warnings},
    "unique_requests": ${uniq_reqs},
    "unique_ips": ${uniq_ips},
    "unique_rules": ${uniq_rules}
  },
  "top_rules": [
      ${top_rules}
  ],
  "top_ips": [
      ${top_ips}
  ],
  "top_uris": [
      ${top_uris}
  ],
  "recent": [
      ${recent}
  ]
}
EOF
