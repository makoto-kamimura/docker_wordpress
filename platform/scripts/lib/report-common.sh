#!/bin/sh
# =====================================================================
# レポート系スクリプトの共通部品 (POSIX sh 専用 / source して使う)
#
#   waf-report.sh / access-summary.sh / fail2ban-status.sh /
#   cert-expiry.sh / ops-digest.sh が読み込む。
#
#   bash 用の lib/common.sh とは別に用意している理由:
#   これらのスクリプトは n8n コンテナ (Alpine / busybox, bash なし) からも
#   実行するため、POSIX sh + awk だけで完結させる必要がある。
#   jq も無いので JSON は自前で組み立てる。
# =====================================================================

# 月名 (%b) やソート順がロケールで揺れないようにする。
# awk はバイト単位で動くようになるため、文字列の切り詰めは utf8_trim() を通す。
LC_ALL=C
export LC_ALL

# ---- 引数の検証 -----------------------------------------------------

# 数値以外を弾く (AI や外部から渡される値をそのまま信用しない)
#   require_num --hours "$2"
require_num() {
  case "${2:-}" in
    ''|*[!0-9]*) echo "ERROR: $1 は 0 以上の整数で指定してください: ${2:-}" >&2; exit 2 ;;
  esac
}

# 値を範囲内に収める。AI から大きな値が来てもレスポンスが膨らまないようにする。
#   clamp <値> <下限> <上限>
clamp() {
  _cl_v=$1
  if [ "$_cl_v" -lt "$2" ]; then _cl_v=$2; fi
  if [ "$_cl_v" -gt "$3" ]; then _cl_v=$3; fi
  echo "$_cl_v"
}

# ---- 時刻 -----------------------------------------------------------
# ログのタイムスタンプが「どのタイムゾーンで書かれているか」はログごとに違う。
#   nginx (error.log / access.log) : コンテナに TZ を渡していないので UTC
#   fail2ban.log                   : ホストで動いているのでホストのローカル時刻 (JST)
#
# 一方このスクリプトは、ホスト (JST) からも n8n コンテナ (TZ=Asia/Tokyo) からも
# 実行される。集計開始時刻をローカル時刻で作ってしまうと UTC のログとは 9 時間ずれ、
# 「直近 24 時間」のつもりで直近 15 時間分しか見ない、という取りこぼしが起きる
# (エラーにならず件数が黙って減るだけなので気づきにくい)。
# そのため呼び出し側でログ側のタイムゾーンを必ず明示する。

# "+0900" -> 32400 / "-0500" -> -18000
#   先頭ゼロを落としてから計算する ($(( 09 )) は 8 進数扱いでエラーになるため)
tz_offset_seconds() {
  _tz_h=$(echo "$1" | cut -c2-3)
  _tz_m=$(echo "$1" | cut -c4-5)
  _tz_v=$(( ${_tz_h#0} * 3600 + ${_tz_m#0} * 60 ))
  case "$1" in -*) _tz_v=$(( 0 - _tz_v )) ;; esac
  echo "$_tz_v"
}

# 集計開始時刻を、ログと同じタイムゾーン・同じ書式で作る
#   since_stamp <utc|local|+HHMM> <時間数> <strftime 書式>
#
#   GNU date (ホスト) と busybox date (コンテナ) の両方で動くよう
#   "-d @エポック秒" だけを使う (busybox は -d "-1 hours" を解釈できない)。
since_stamp() {
  _st_epoch=$(( $(date +%s) - $2 * 3600 ))
  case "$1" in
    local) date -d "@${_st_epoch}" +"$3" ;;
    utc)   date -u -d "@${_st_epoch}" +"$3" ;;
    [+-][0-9][0-9][0-9][0-9])
      date -u -d "@$(( _st_epoch + $(tz_offset_seconds "$1") ))" +"$3" ;;
    *) echo "ERROR: 不明なタイムゾーン指定: $1" >&2; exit 1 ;;
  esac
}

now_iso() { date -Iseconds 2>/dev/null || date +'%Y-%m-%dT%H:%M:%S%z'; }

# ---- 大きなログの読み方 ---------------------------------------------
# access.log は 200MB を超える。毎回の全走査を避けるため末尾だけ読む。
#   read_tail <ファイル> <最大バイト数>
read_tail() {
  _rt_size=$(wc -c < "$1")
  if [ "$_rt_size" -gt "$2" ]; then
    # tail -c は行の途中で切れるため、壊れた先頭 1 行を落とす
    tail -c "$2" "$1" | tail -n +2
  else
    cat "$1"
  fi
}

# ---- awk 用のスニペット ---------------------------------------------

# JSON 文字列のエスケープ。
# gsub の置換文字列は再解釈されるため、1 文字ずつ組み立てる。
AWK_ESC='
  function esc(s,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\")      out = out "\\\\"
      else if (c == "\"") out = out "\\\""
      else if (c < " ")   out = out " "
      else                out = out c
    }
    return out
  }
'

# 値の整形 (タブ潰し + 長すぎる値の切り詰め)。
# shellcheck disable=SC2034  # 呼び出し元のスクリプトで使う
# LC_ALL=C のため substr はバイト単位で切る。マルチバイト文字の途中で切れると
# 壊れた UTF-8 が JSON に載り、受け取り側のパースが失敗するので末尾を削る。
AWK_TEXT='
  function utf8_trim(s,   c) {
    while (length(s) > 0) {
      c = substr(s, length(s), 1)
      if (c >= "\200" && c <= "\277") { s = substr(s, 1, length(s) - 1); continue }
      if (c >= "\300")                { s = substr(s, 1, length(s) - 1) }
      break
    }
    return s
  }
  function clean(s, max) {
    gsub(/\t/, " ", s)
    if (max == 0) max = 200
    if (length(s) > max) s = utf8_trim(substr(s, 1, max)) "…"
    return s
  }
'

# ---- 集計 -----------------------------------------------------------

# TSV の指定フィールドで件数を数え、多い順に n 件返す
#   topn <TSVファイル> <フィールド番号> <第2フィールド番号|0> <件数>
topn() {
  awk -F'\t' -v a="$2" -v b="$3" '
    $a != "" { c[ b > 0 ? $a "\t" $b : $a ]++ }
    END { for (k in c) printf "%d\t%s\n", c[k], k }
  ' "$1" | sort -rn | head -n "$4"
}

# topn の出力 (件数, キー1, キー2?) を JSON 配列の中身にする
#   to_json_array <キー1名> [キー2名]
to_json_array() {
  awk -F'\t' -v k1="$1" -v k2="${2:-}" "$AWK_ESC"'
    {
      printf "%s{\"%s\":\"%s\"", (NR > 1 ? ",\n      " : ""), k1, esc($2)
      if (k2 != "") printf ",\"%s\":\"%s\"", k2, esc($3)
      printf ",\"count\":%d}", $1
    }
  '
}

# ---- 自分たちが出した JSON を読み返す -------------------------------
# ops-digest.sh が各レポートの結果を組み合わせるために使う。
# 汎用の JSON パーサではない。ここのスクリプトが出力する
# 「1 要素 1 行」「"キー": 値 が 1 行に収まる」形式だけを前提にしている。

# "キー": 値 を 1 つ取り出す (stdin から)
#   json_get <キー名>
json_get() {
  awk -v key="$1" '
    BEGIN { pat = "\"" key "\" *: *" }
    match($0, pat) {
      rest = substr($0, RSTART + RLENGTH)
      if (substr(rest, 1, 1) == "\"") { sub(/^"/, "", rest); sub(/".*$/, "", rest) }
      else { sub(/[,}].*$/, "", rest); gsub(/ /, "", rest) }
      print rest
      exit
    }
  '
}

# "キー": [ ... ] の中身を 1 要素 1 行で取り出す (stdin から)
#   json_rows <配列キー名>
json_rows() {
  awk -v key="$1" '
    index($0, "\"" key "\": [") { inarr = 1; next }
    inarr && /^ *\]/            { inarr = 0 }
    inarr && /[^ ]/             { print }
  '
}

# json_rows の出力を "値 (件数), 値 (件数)" の 1 行にまとめる
#   fmt_top <文字列キー名>
fmt_top() {
  awk -v key="$1" '
    {
      v = ""; c = 0
      if (match($0, "\"" key "\":\"[^\"]*\""))
        v = substr($0, RSTART + length(key) + 4, RLENGTH - length(key) - 5)
      if (match($0, /"count":[0-9]+/))
        c = substr($0, RSTART + 8, RLENGTH - 8)
      if (v != "") printf "%s%s (%s)", (n++ ? ", " : ""), v, c
    }
    END { printf "\n" }
  '
}
