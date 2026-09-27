#!/bin/sh
# =====================================================================
# サーバー運用ダイジェスト
#   WAF 検知 / fail2ban / 証明書の残日数 / DB バックアップ / ディスク使用率を
#   1 つにまとめる。毎朝これだけ見れば状況が分かる、という位置づけ。
#
#   例:
#     ./ops-digest.sh                  # 人が読む形式 (メール本文向け)
#     ./ops-digest.sh --format json    # 機械が読む形式
#     ./ops-digest.sh --hours 168
#
#   各項目の集計そのものは個別スクリプトに任せ、ここは寄せ集めと閾値判定だけ行う。
#   個別スクリプトが 1 つ失敗しても、そこだけ「取得できませんでした」にして
#   残りは出す (1 箇所の不調でダイジェスト全体が届かないと、かえって気づけない)。
#
#   閾値を超えた項目は冒頭の【要対応】にまとめる。ここが空なら読み飛ばしてよい。
# =====================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/report-common.sh
. "${SCRIPT_DIR}/lib/report-common.sh"

HOURS=24
FORMAT=text
TOPN=5

# 既定値。n8n コンテナからはマウント先が違うため環境変数で上書きする
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/../../app/backup}"
DEMO_BACKUP_DIR="${DEMO_BACKUP_DIR:-${BACKUP_DIR}/demo}"
FILES_BACKUP_DIR="${FILES_BACKUP_DIR:-${BACKUP_DIR}/files}"

# 閾値
BACKUP_WARN_HOURS="${BACKUP_WARN_HOURS:-48}"   # 最新バックアップがこれより古ければ要対応
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"           # ディスク使用率
CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"         # 証明書の残り日数
# 集計期間内の遮断件数。平常時でも 1 日 300〜500 件は遮断しているため
# (2026-09 実測: 24h 514 / 72h 平均 383 / 168h 平均 308)、平常時に鳴らない
# 値として平均の約 4 倍を既定にしている。個別の IP を早く知りたい場合は
# ダイジェストではなく WAF 閾値アラート (1時間ごと) の方で拾う。
WAF_WARN_BLOCKED="${WAF_WARN_BLOCKED:-1500}"
LOG_WARN_MB="${LOG_WARN_MB:-500}"              # nginx ログのサイズ

usage() {
  cat >&2 <<'EOF'
Usage: ops-digest.sh [options]

  --hours N        集計する時間範囲 (既定: 24)
  --format FMT     text (既定) | json
  --top N          各ランキングに載せる件数 (既定: 5)
  -h, --help       このヘルプ

閾値は環境変数で変えられる:
  BACKUP_WARN_HOURS (48) / DISK_WARN_PCT (85) / CERT_WARN_DAYS (14)
  WAF_WARN_BLOCKED (1500) / LOG_WARN_MB (500)

入力の場所も環境変数で変えられる:
  WAF_LOG_FILE / ACCESS_LOG_FILE / F2B_LOG_FILE / CERT_DIR
  BACKUP_DIR / DEMO_BACKUP_DIR / FILES_BACKUP_DIR
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours)  require_num --hours "${2:-}"; HOURS="$2"; shift 2 ;;
    --top)    require_num --top   "${2:-}"; TOPN="$2";  shift 2 ;;
    --format) FORMAT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 不明な引数: $1" >&2; usage; exit 2 ;;
  esac
done

HOURS="$(clamp "$HOURS" 1 720)"
TOPN="$(clamp "$TOPN" 1 20)"
case "$FORMAT" in text|json) ;; *) echo "ERROR: --format は text か json: $FORMAT" >&2; exit 2 ;; esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
ALERTS="${WORK}/alerts"
: > "$ALERTS"

alert() { echo "$1" >> "$ALERTS"; }

# 個別スクリプトを実行する。失敗しても続行し、理由を stderr の 1 行目から拾う。
#   run_report <名前> <コマンド...>
run_report() {
  _rr_name=$1; shift
  if "$@" > "${WORK}/${_rr_name}.json" 2> "${WORK}/${_rr_name}.err"; then
    echo ok > "${WORK}/${_rr_name}.status"
  else
    echo fail > "${WORK}/${_rr_name}.status"
    : > "${WORK}/${_rr_name}.json"
  fi
}

ok() { [ "$(cat "${WORK}/$1.status")" = ok ]; }
why() { head -1 "${WORK}/$1.err" 2>/dev/null || echo '原因不明'; }
get() { json_get "$2" < "${WORK}/$1.json"; }

# ---- 各レポートを集める ---------------------------------------------
run_report waf  "${SCRIPT_DIR}/waf-report.sh"      --hours "$HOURS" --limit "$TOPN" --recent 0
run_report acc  "${SCRIPT_DIR}/access-summary.sh"  --hours "$HOURS" --limit "$TOPN"
run_report f2b  "${SCRIPT_DIR}/fail2ban-status.sh" --hours "$HOURS" --limit "$TOPN"
run_report cert "${SCRIPT_DIR}/cert-expiry.sh"     --warn-days 30

ok waf  || alert "WAF レポートを取得できませんでした: $(why waf)"
ok acc  || alert "アクセスログ集計を取得できませんでした: $(why acc)"
ok f2b  || alert "fail2ban の状況を取得できませんでした: $(why f2b)"
ok cert || alert "証明書の有効期限を取得できませんでした: $(why cert)"

# ---- バックアップ ---------------------------------------------------
# 3 系統ある (WordPress DB / デモ DB / ファイル)。それぞれ別の cron なので、
# 1 つだけ止まっても他は動き続ける。まとめず別々に見る。

# backup_stat <ディレクトリ> <グロブ>
#   -> "総数<TAB>最新ファイル名<TAB>経過時間<TAB>最新回の合計バイト<TAB>最新回の本数<TAB>最新回の時刻"
#
#   デモ DB は 1 回で 6 本、ファイルは 5 本を同じタイムスタンプで書く。
#   「最新の 1 ファイル」だけを見せると、たまたま最後に書かれた小さい書庫
#   (空の financial_uploads など) が代表になってしまい実態が分からない。
#   そのため最新のタイムスタンプを持つ一群をまとめて数える。
#
#   ディレクトリ自体が無ければ総数 -1 (まだ一度も動いていない / 対象外)
backup_stat() {
  if [ ! -d "$1" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' -1 '' -1 0 0 ''
    return 0
  fi
  # ls を使うのは更新時刻順が必要なため (find では並べ替えに別コマンドが要る)。
  # バックアップのファイル名はスクリプトが付けており、空白などは入らない。
  # shellcheck disable=SC2012,SC2086
  _bs_count="$(ls -1 "$1"/$2 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$_bs_count" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' 0 '' -1 0 0 ''
    return 0
  fi
  # shellcheck disable=SC2012,SC2086
  _bs_file="$(ls -1t "$1"/$2 2>/dev/null | head -1)"
  _bs_age="$(( ( $(date +%s) - $(stat -c %Y "$_bs_file") ) / 3600 ))"

  # ファイル名末尾の _YYYYMMDD_HHMMSS を取り出し、同じものを持つ一群を数える
  _bs_ts="$(echo "${_bs_file##*/}" | sed -n 's/.*_\([0-9]\{8\}_[0-9]\{6\}\)\..*$/\1/p')"
  if [ -n "$_bs_ts" ]; then
    _bs_batch=0
    _bs_bytes=0
    for _bs_f in "$1"/*_"${_bs_ts}".*; do
      [ -f "$_bs_f" ] || continue
      _bs_batch=$(( _bs_batch + 1 ))
      _bs_bytes=$(( _bs_bytes + $(wc -c < "$_bs_f") ))
    done
    _bs_at="$(echo "$_bs_ts" | sed 's/\(....\)\(..\)\(..\)_\(..\)\(..\)../\1-\2-\3 \4:\5/')"
  else
    _bs_batch=1
    _bs_bytes="$(wc -c < "$_bs_file" | tr -d ' ')"
    _bs_at=''
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_bs_count" "${_bs_file##*/}" "$_bs_age" "$_bs_bytes" "$_bs_batch" "$_bs_at"
}

# col <stat行> <列番号>
col() { echo "$1" | cut -f"$2"; }

# backup_alert <ラベル> <stat行> <場所> <必須か 1/0>
#   必須でない系統 (デモ / ファイル) は、保存先が無い間は黙っている。
#   一度でも取れていれば以降は他と同じ基準で古さを見る。
backup_alert() {
  _ba_count="$(col "$2" 1)"
  _ba_age="$(col "$2" 3)"
  if [ "$_ba_count" -lt 0 ]; then
    if [ "$4" -eq 1 ]; then alert "$1 のバックアップ先がありません (${3})"; fi
  elif [ "$_ba_count" -eq 0 ]; then
    alert "$1 のバックアップが 1 つもありません (${3})"
  elif [ "$_ba_age" -gt "$BACKUP_WARN_HOURS" ]; then
    alert "$1 の最新バックアップが ${_ba_age} 時間前です (cron が動いていない可能性)"
  fi
  return 0
}

wp_bk="$(backup_stat "$BACKUP_DIR" '*.sql.gz')"
demo_bk="$(backup_stat "$DEMO_BACKUP_DIR" '*.sql.gz')"
files_bk="$(backup_stat "$FILES_BACKUP_DIR" '*.tar.gz')"

backup_alert "WordPress DB" "$wp_bk"    "$BACKUP_DIR"       1
backup_alert "デモ DB"      "$demo_bk"  "$DEMO_BACKUP_DIR"  0
backup_alert "ファイル"     "$files_bk" "$FILES_BACKUP_DIR" 0

# ---- ディスク -------------------------------------------------------
# 集計対象のログが置かれているファイルシステムを見る
# (ホストでも n8n コンテナでも、実体はホストのディスク)
DISK_PATH="${DISK_PATH:-$(dirname "${WAF_LOG_FILE:-${SCRIPT_DIR}/../log_data/nginx_logs/error.log}")}"
[ -d "$DISK_PATH" ] || DISK_PATH=/
disk_line="$(df -P "$DISK_PATH" 2>/dev/null | tail -1)"
disk_fs="$(echo "$disk_line"   | awk '{ print $1 }')"
disk_pct="$(echo "$disk_line"  | awk '{ gsub(/%/, "", $5); print $5 + 0 }')"
disk_avail="$(echo "$disk_line" | awk '{ printf "%.1f", $4 / 1048576 }')"
if [ "$disk_pct" -ge "$DISK_WARN_PCT" ]; then
  alert "ディスク使用率が ${disk_pct}% です (${DISK_PATH})"
fi

# ---- nginx ログのサイズ ---------------------------------------------
log_mb() { [ -r "$1" ] && awk -v b="$(wc -c < "$1")" 'BEGIN { printf "%.0f", b / 1048576 }' || echo 0; }
err_log="${WAF_LOG_FILE:-${SCRIPT_DIR}/../log_data/nginx_logs/error.log}"
acc_log="${ACCESS_LOG_FILE:-${SCRIPT_DIR}/../log_data/nginx_logs/access.log}"
err_mb="$(log_mb "$err_log")"
acc_mb="$(log_mb "$acc_log")"
if [ "$err_mb" -ge "$LOG_WARN_MB" ]; then
  alert "error.log が ${err_mb}MB あります (ローテートを確認)"
fi
if [ "$acc_mb" -ge "$LOG_WARN_MB" ]; then
  alert "access.log が ${acc_mb}MB あります (ローテートを確認)"
fi

# ---- 閾値判定 (レポートの中身) --------------------------------------
waf_blocked=0; waf_ips=0; waf_warn=0
if ok waf; then
  waf_blocked="$(get waf blocked)"
  waf_warn="$(get waf warnings)"
  waf_ips="$(get waf unique_ips)"
  if [ "$waf_blocked" -ge "$WAF_WARN_BLOCKED" ]; then
    alert "WAF の遮断が ${HOURS} 時間で ${waf_blocked} 件あります"
  fi
fi

f2b_banned=0; f2b_new=0; f2b_src=''
if ok f2b; then
  f2b_banned="$(get f2b currently_banned)"
  f2b_new="$(get f2b bans_in_window)"
  f2b_src="$(get f2b banned_source)"
  # WAF が大量に遮断しているのに BAN が 0 件なら、fail2ban が動いていない疑い
  if [ "$f2b_banned" -eq 0 ] && [ "$waf_blocked" -ge 100 ]; then
    alert "WAF は ${waf_blocked} 件遮断しているのに fail2ban の BAN が 0 件です (fail2ban の停止を確認)"
  fi
  # ローテート後にコンテナが古いログを掴んだままになっていないか
  if [ "$(get f2b stale)" = true ]; then
    alert "fail2ban のログが $(get f2b idle_minutes) 分間更新されていません (docker compose restart n8n でマウントし直す)"
  fi
fi

cert_min=''; cert_soon=0; cert_expired=0
if ok cert; then
  cert_min="$(get cert min_days_left)"
  cert_soon="$(get cert expiring_soon)"
  cert_expired="$(get cert expired)"
  if [ "$cert_expired" -gt 0 ]; then
    alert "失効済みの証明書が ${cert_expired} 件あります"
  fi
  case "$cert_min" in
    ''|null) ;;
    *) if [ "$cert_min" -le "$CERT_WARN_DAYS" ]; then
         alert "証明書の残りが最短 ${cert_min} 日です (自動更新の失敗を確認)"
       fi ;;
  esac
fi

acc_req=0; acc_5xx=0; acc_4xx=0; acc_bot=0
if ok acc; then
  acc_req="$(get acc requests)"
  acc_5xx="$(get acc status_5xx)"
  acc_4xx="$(get acc status_4xx)"
  acc_bot="$(get acc bot_requests)"
fi

alert_count="$(wc -l < "$ALERTS" | tr -d ' ')"
GENERATED_AT="$(now_iso)"

# =====================================================================
# 出力
# =====================================================================
backup_json() {
  printf '{ "dir": "%s", "latest": "%s", "age_hours": %s, "latest_run": { "at": "%s", "files": %s, "bytes": %s }, "files_total": %s }' \
    "$1" "$(col "$2" 2)" "$(col "$2" 3)" \
    "$(col "$2" 6)" "$(col "$2" 5)" "$(col "$2" 4)" "$(col "$2" 1)"
}

if [ "$FORMAT" = json ]; then
  alerts_json="$(awk "$AWK_ESC"'{ printf "%s\"%s\"", (NR > 1 ? ",\n    " : ""), esc($0) }' "$ALERTS")"
  embed() { if ok "$1"; then cat "${WORK}/$1.json"; else printf '{ "error": "%s" }' "$(why "$1" | tr '"' "'")"; fi; }
  cat <<EOF
{
  "generated_at": "${GENERATED_AT}",
  "window_hours": ${HOURS},
  "alerts": [
    ${alerts_json}
  ],
  "backup": {
    "wordpress_db": $(backup_json "$BACKUP_DIR" "$wp_bk"),
    "demo_db": $(backup_json "$DEMO_BACKUP_DIR" "$demo_bk"),
    "files": $(backup_json "$FILES_BACKUP_DIR" "$files_bk")
  },
  "disk": { "path": "${DISK_PATH}", "filesystem": "${disk_fs}", "used_percent": ${disk_pct}, "avail_gb": ${disk_avail} },
  "logs": { "error_log_mb": ${err_mb}, "access_log_mb": ${acc_mb} },
  "waf": $(embed waf),
  "access": $(embed acc),
  "fail2ban": $(embed f2b),
  "certificates": $(embed cert)
}
EOF
  exit 0
fi

# ---- テキスト (メール本文) ------------------------------------------
fmt_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if      (b >= 1073741824) printf "%.1f GB", b / 1073741824
    else if (b >= 1048576)    printf "%.1f MB", b / 1048576
    else if (b >= 1024)       printf "%.1f KB", b / 1024
    else                      printf "%d B", b
  }'
}

echo "============================================================"
echo " サーバー運用ダイジェスト  $(date '+%Y-%m-%d %H:%M')  (直近 ${HOURS} 時間)"
echo "============================================================"
echo

echo "【要対応】"
if [ "$alert_count" -eq 0 ]; then
  echo "  特にありません"
else
  sed 's/^/  - /' "$ALERTS"
fi
echo

echo "■ WAF (ModSecurity)"
if ok waf; then
  echo "   遮断 ${waf_blocked} 件 / 警告 ${waf_warn} 件 / 攻撃元 ${waf_ips} IP"
  echo "   多い攻撃元 : $(json_rows top_ips  < "${WORK}/waf.json" | fmt_top ip)"
  echo "   狙われた URI: $(json_rows top_uris < "${WORK}/waf.json" | fmt_top uri)"
else
  echo "   取得できませんでした: $(why waf)"
fi
echo

echo "■ fail2ban"
if ok f2b; then
  echo "   現在 BAN 中 ${f2b_banned} 件 / この期間の新規 BAN ${f2b_new} 件 (取得元: ${f2b_src})"
  echo "   jail 別     : $(json_rows currently_banned_by_jail < "${WORK}/f2b.json" | fmt_top jail)"
  echo "   BAN が多い IP: $(json_rows top_banned_ips < "${WORK}/f2b.json" | fmt_top ip)"
else
  echo "   取得できませんでした: $(why f2b)"
fi
echo

echo "■ 証明書 (残り日数の短い順 / 30 日以内 ${cert_soon} 件)"
if ok cert; then
  json_rows domains < "${WORK}/cert.json" | awk '
    {
      d = ""; n = ""; a = ""
      if (match($0, /"domain":"[^"]*"/))     d = substr($0, RSTART + 10, RLENGTH - 11)
      if (match($0, /"days_left":[-0-9]+/))  n = substr($0, RSTART + 12, RLENGTH - 12)
      if (match($0, /"not_after":"[^"]*"/))  a = substr($0, RSTART + 13, RLENGTH - 14)
      if (d != "") printf "   %-34s %4s 日  (%s)\n", d, (n == "" ? "?" : n), a
    }'
else
  echo "   取得できませんでした: $(why cert)"
fi
echo

echo "■ アクセス"
if ok acc; then
  echo "   ${acc_req} リクエスト / 4xx ${acc_4xx} / 5xx ${acc_5xx} / bot 名乗り ${acc_bot}"
  echo "   多いアクセス元: $(json_rows top_ips  < "${WORK}/acc.json" | fmt_top ip)"
  echo "   404 が多い URI: $(json_rows top_404  < "${WORK}/acc.json" | fmt_top path)"
else
  echo "   取得できませんでした: $(why acc)"
fi
echo

echo "■ バックアップ"
# ラベルは表示幅 12 に揃えて渡す。LC_ALL=C の printf はバイト数で桁を詰めるため、
# 全角を含むラベルを %-14s のような書式で揃えると崩れる。
backup_line() { # backup_line <ラベル(幅そろえ済み)> <stat行> <場所>
  _bl_count="$(col "$2" 1)"
  if [ "$_bl_count" -gt 0 ]; then
    printf '   %s : %s に %s 本  %s  (%s 時間前)  保存 %s 本\n' \
      "$1" "$(col "$2" 6)" "$(col "$2" 5)" "$(fmt_bytes "$(col "$2" 4)")" \
      "$(col "$2" 3)" "$_bl_count"
  elif [ "$_bl_count" -eq 0 ]; then
    printf '   %s : %s に見つかりません\n' "$1" "$3"
  else
    printf '   %s : 未取得 (%s がありません)\n' "$1" "$3"
  fi
}
backup_line "WordPress DB" "$wp_bk"    "$BACKUP_DIR"
# デモ DB (docker-compose.demo.yml でアプリを足した構成向け) は、置き場所がある時だけ出す
if [ "$(col "$demo_bk" 1)" -ge 0 ]; then
  backup_line "デモ DB     " "$demo_bk"  "$DEMO_BACKUP_DIR"
fi
backup_line "ファイル    " "$files_bk" "$FILES_BACKUP_DIR"
echo

echo "■ ディスク / ログ"
echo "   ${disk_fs}  ${disk_pct}% 使用  空き ${disk_avail} GB  (${DISK_PATH})"
echo "   nginx ログ: error.log ${err_mb}MB / access.log ${acc_mb}MB"
echo
echo "------------------------------------------------------------"
echo "詳しく見る: platform/scripts/{waf-report,access-summary,fail2ban-status,cert-expiry}.sh"
echo "生成: ${GENERATED_AT}"
