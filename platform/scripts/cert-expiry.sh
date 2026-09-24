#!/bin/sh
# =====================================================================
# TLS 証明書の有効期限レポート
#   Let's Encrypt の live/<ドメイン>/cert.pem を読み、残り日数を JSON で返す。
#
#   例:
#     ./cert-expiry.sh
#     ./cert-expiry.sh --warn-days 14
#
#   certbot の自動更新が失敗していても、更新ループはエラーを出し続けるだけで
#   誰も気づかない。残り日数を機械が読める形にしておくための薄いスクリプト。
#
#   期限の取り出しには openssl か node を使う (先に見つかった方)。
#     ホスト       : openssl あり
#     n8n コンテナ : openssl 無し / node あり (crypto.X509Certificate を使う)
#
#   出力は stdout に JSON のみ。診断メッセージは stderr に出す。
# =====================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/report-common.sh
. "${SCRIPT_DIR}/lib/report-common.sh"

CERT_DIR="${CERT_DIR:-${SCRIPT_DIR}/../nginx_data/certs}"
WARN_DAYS=30

usage() {
  cat >&2 <<'EOF'
Usage: cert-expiry.sh [options]

  --warn-days N  残り日数がこれ以下なら expiring_soon に数える (既定: 30)
  --dir PATH     Let's Encrypt のディレクトリ (既定: platform/nginx_data/certs)
  -h, --help     このヘルプ

環境変数 CERT_DIR でも同じ指定ができる。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --warn-days) require_num --warn-days "${2:-}"; WARN_DAYS="$2"; shift 2 ;;
    --dir) CERT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 不明な引数: $1" >&2; usage; exit 2 ;;
  esac
done

WARN_DAYS="$(clamp "$WARN_DAYS" 1 365)"
LIVE_DIR="${CERT_DIR}/live"

[ -d "$LIVE_DIR" ] || { echo "ERROR: live ディレクトリがありません: $LIVE_DIR" >&2; exit 1; }

# ---- 対象の証明書を集める -------------------------------------------
# certbot は再発行のたびに live/<domain>-0003 のような実ディレクトリを作り、
# live/<domain> をそこへのシンボリックリンクにする。両方を数えると同じ証明書が
# 二重に出るため、リンク先になっているディレクトリは除く。
LINKED=" "
for d in "$LIVE_DIR"/*; do
  [ -L "$d" ] || continue
  LINKED="${LINKED}$(basename "$(readlink "$d")") "
done

FILES="$(mktemp)"
trap 'rm -f "$FILES" "${FILES}.out"' EXIT INT TERM

for d in "$LIVE_DIR"/*; do
  [ -d "$d" ] || continue
  base="$(basename "$d")"
  case "$LINKED" in *" $base "*) continue ;; esac
  [ -r "${d}/cert.pem" ] || continue
  printf '%s\t%s\n' "$base" "${d}/cert.pem" >> "$FILES"
done

[ -s "$FILES" ] || { echo "ERROR: 読める証明書がありません: $LIVE_DIR" >&2; exit 1; }

# ---- 失効時刻 (エポック秒) を取り出す -------------------------------
if command -v openssl >/dev/null 2>&1; then
  READER=openssl
  while IFS="$(printf '\t')" read -r name path; do
    end="$(openssl x509 -enddate -noout -in "$path" 2>/dev/null | cut -d= -f2)"
    epoch="$(date -u -d "$end" +%s 2>/dev/null || echo '')"
    printf '%s\t%s\t%s\n' "$name" "${epoch:-0}" "$end"
  done < "$FILES" > "${FILES}.out"
elif command -v node >/dev/null 2>&1; then
  READER=node
  # node は 1 回の起動で全部読む (証明書ごとにプロセスを起こさない)
  cut -f2 "$FILES" | tr '\n' '\0' | xargs -0 node -e '
    const fs = require("fs");
    const { X509Certificate } = require("crypto");
    for (const p of process.argv.slice(1)) {
      try {
        const x = new X509Certificate(fs.readFileSync(p));
        console.log([p, Math.floor(Date.parse(x.validTo) / 1000), x.validTo].join("\t"));
      } catch (e) {
        console.log([p, 0, ""].join("\t"));
      }
    }
  ' | awk -F'\t' -v OFS='\t' '
      NR == FNR { name[$2] = $1; next }
      { print (name[$1] != "" ? name[$1] : $1), $2, $3 }
    ' "$FILES" - > "${FILES}.out"
else
  echo "ERROR: openssl も node も見つかりません (証明書の期限を読めません)" >&2
  exit 1
fi

NOW="$(date +%s)"
GENERATED_AT="$(now_iso)"

domains="$(
  awk -F'\t' -v now="$NOW" "$AWK_ESC"'
    $2 + 0 > 0 { printf "%d\t%s\t%s\t%s\n", int(($2 - now) / 86400), $1, $2, $3 }
    $2 + 0 <= 0 { printf "%d\t%s\t%s\t%s\n", -99999, $1, 0, "" }
  ' "${FILES}.out" | sort -n | awk -F'\t' "$AWK_ESC"'
    {
      printf "%s{\"domain\":\"%s\",\"days_left\":%s,\"not_after\":\"%s\",\"readable\":%s}",
        (NR > 1 ? ",\n      " : ""),
        esc($2),
        ($1 == -99999 ? "null" : $1),
        esc($4),
        ($1 == -99999 ? "false" : "true")
    }
  '
)"

total="$(wc -l < "${FILES}.out" | tr -d ' ')"
soon="$(awk -F'\t' -v now="$NOW" -v w="$WARN_DAYS" '
  $2 + 0 > 0 && int(($2 - now) / 86400) <= w { n++ } END { print n + 0 }' "${FILES}.out")"
expired="$(awk -F'\t' -v now="$NOW" '
  $2 + 0 > 0 && $2 < now { n++ } END { print n + 0 }' "${FILES}.out")"
unreadable="$(awk -F'\t' '$2 + 0 <= 0 { n++ } END { print n + 0 }' "${FILES}.out")"
min_days="$(awk -F'\t' -v now="$NOW" '
  $2 + 0 > 0 { d = int(($2 - now) / 86400); if (m == "" || d < m) m = d }
  END { print (m == "" ? "null" : m) }' "${FILES}.out")"

cat <<EOF
{
  "generated_at": "${GENERATED_AT}",
  "source": "${LIVE_DIR}",
  "reader": "${READER}",
  "summary": {
    "certificates": ${total},
    "min_days_left": ${min_days},
    "expiring_soon": ${soon},
    "warn_days": ${WARN_DAYS},
    "expired": ${expired},
    "unreadable": ${unreadable}
  },
  "domains": [
      ${domains}
  ]
}
EOF
