#!/usr/bin/env bash
# =====================================================================
# DB バックアップ (MariaDB / mysqldump)
#   平日 03:00 cron 想定:
#     0 3 * * * /path/to/platform/scripts/backup-db.sh >>/var/log/wp_backup.log 2>&1
# 保管先は環境変数 BACKUP_DIR で指定 (デフォルト: ../app/backup)
# 古いダンプは BACKUP_KEEP_DAYS (デフォルト 14 日) で自動削除
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PLATFORM_DIR}"

# .env を読み込む (MYSQL_ROOT_PASSWORD 等)
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
else
  echo "ERROR: ${PLATFORM_DIR}/.env not found" >&2
  exit 1
fi

BACKUP_DIR="${BACKUP_DIR:-${PLATFORM_DIR}/../app/backup}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
TS="$(date +%Y%m%d_%H%M%S)"

mkdir -p "${BACKUP_DIR}"

OUT="${BACKUP_DIR}/db_${TS}.sql.gz"

echo "[$(date -Iseconds)] Dumping ${MYSQL_DATABASE} -> ${OUT}"
docker compose exec -T db sh -c \
  "exec mariadb-dump -uroot -p\"\${MARIADB_ROOT_PASSWORD}\" \
       --single-transaction --quick --routines --triggers \
       --default-character-set=utf8mb4 \
       \"\${MARIADB_DATABASE}\"" \
  | gzip -9 > "${OUT}"

# 整合性検査 (gzip ヘッダだけでなく中身も)
if ! gzip -t "${OUT}"; then
  echo "ERROR: dump verification failed for ${OUT}" >&2
  rm -f "${OUT}"
  exit 1
fi

echo "[$(date -Iseconds)] OK: $(du -h "${OUT}" | awk '{print $1}')"

# 古い世代を削除
find "${BACKUP_DIR}" -type f -name "db_*.sql.gz" -mtime "+${BACKUP_KEEP_DAYS}" -print -delete
