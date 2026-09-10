#!/usr/bin/env bash
# =====================================================================
# DB バックアップ (MariaDB / mysqldump)
#   平日 03:00 cron 想定:
#     0 3 * * * /path/to/platform/scripts/backup-db.sh >>/var/log/wp_backup.log 2>&1
# 保管先は環境変数 BACKUP_DIR で指定 (デフォルト: ../app/backup)
# 古いダンプは BACKUP_KEEP_DAYS (デフォルト 14 日) で自動削除
# =====================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
cd "${PLATFORM_DIR}"

# .env を読み込む (MYSQL_DATABASE 等)
load_env ./.env

BACKUP_DIR="${BACKUP_DIR:-${PLATFORM_DIR}/../app/backup}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
TS="$(date +%Y%m%d_%H%M%S)"

mkdir -p "${BACKUP_DIR}"

OUT="${BACKUP_DIR}/db_${TS}.sql.gz"

log "Dumping ${MYSQL_DATABASE} -> ${OUT}"
# 失敗判定は if で受ける。set -e に任せると途中で落ちたダンプが残り、
# しかも gzip としては正常に閉じているため下の gzip -t も通ってしまう。
if ! docker compose exec -T db sh -c \
       "exec mariadb-dump -uroot -p\"\${MARIADB_ROOT_PASSWORD}\" \
            --single-transaction --quick --routines --triggers \
            --default-character-set=utf8mb4 \
            \"\${MARIADB_DATABASE}\"" \
     | gzip -9 > "${OUT}"; then
  rm -f "${OUT}"
  die "mariadb-dump failed; partial dump removed"
fi

# 整合性検査 (gzip ヘッダだけでなく中身も)
if ! gzip -t "${OUT}"; then
  rm -f "${OUT}"
  die "dump verification failed for ${OUT}"
fi

log "OK: $(du -h "${OUT}" | awk '{print $1}')"

# 古い世代を削除
find "${BACKUP_DIR}" -type f -name "db_*.sql.gz" -mtime "+${BACKUP_KEEP_DAYS}" -print -delete
