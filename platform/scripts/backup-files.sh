#!/usr/bin/env bash
# =====================================================================
# ファイルのバックアップ (tar.gz)
#   毎日 03:20 cron 想定:
#     20 3 * * * /path/to/platform/scripts/backup-files.sh >>/var/log/files_backup.log 2>&1
#
#   DB ダンプだけでは記事の画像が戻らないため、アップロード済みファイルを別に取る。
#   WordPress のメディアは DB (wpmk_posts / wpmk_postmeta) にパスだけが入っていて、
#   実体は wp-content/uploads にある。
#
#   保管先: BACKUP_DIR/files (デフォルト: ../app/backup/files)
#   古い世代は FILES_BACKUP_KEEP_DAYS (デフォルト 14 日) で自動削除
#
#   既定の対象は WordPress の uploads だけ。docker-compose.demo.yml などで
#   追加したアプリのアップロード先も取るときは、platform/backup-files.targets
#   (git 管理外) に 1 行 1 対象で書く。書き方は 2 通り:
#     名前:path:<絶対パス>      … bind マウント / 通常のディレクトリ
#     名前:volume:<短い名前>    … docker の名前付きボリューム
#                                 (実体の場所は docker volume inspect で解決する。
#                                  /var/lib/docker/... を直書きすると docker の
#                                  data-root を変えたときに黙って空振りする)
#   空行と # で始まる行は無視する。
#
#   ⚠️ 稼働中のコンテナが書き込んでいる最中に固めるため、瞬間的な整合性までは
#      保証しない (電源断と同じ「その時点のファイル群」)。アップロードは
#      追記型でファイル単位に閉じているため、この粒度で足りると判断している。
#      MinIO なども同様。厳密に取るならコンテナを止めるか mc mirror を使うこと。
# =====================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BACKUP_DIR="${BACKUP_DIR:-${PLATFORM_DIR}/../app/backup}"
FILES_BACKUP_DIR="${FILES_BACKUP_DIR:-${BACKUP_DIR}/files}"
FILES_BACKUP_KEEP_DAYS="${FILES_BACKUP_KEEP_DAYS:-14}"
TS="$(date +%Y%m%d_%H%M%S)"

# 名前付きボリュームの実名は「<compose プロジェクト名>_<短い名前>」。
# プロジェクト名は既定でリポジトリのディレクトリ名になる。
VOLUME_PREFIX="${COMPOSE_PROJECT_NAME:-$(basename "${REPO_DIR}")}"

TARGETS=(
  "uploads:path:${REPO_DIR}/app/wordpress/wordpress_data/wp-content/uploads"
)

# このサーバー固有の追加対象 (git 管理外)
EXTRA_TARGETS_FILE="${FILES_BACKUP_TARGETS_FILE:-${PLATFORM_DIR}/backup-files.targets}"
if [[ -f "${EXTRA_TARGETS_FILE}" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "${line}" ]] && TARGETS+=("${line}")
  done < "${EXTRA_TARGETS_FILE}"
fi

mkdir -p "${FILES_BACKUP_DIR}"

failed=0
skipped=0
saved=0

for entry in "${TARGETS[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  kind="${rest%%:*}"
  ref="${rest#*:}"

  case "${kind}" in
    path)
      path="${ref}"
      ;;
    volume)
      vol="${VOLUME_PREFIX}_${ref}"
      if ! path="$(docker volume inspect "${vol}" --format '{{.Mountpoint}}' 2>/dev/null)"; then
        log "SKIP: ${name} (ボリューム ${vol} がありません)"
        skipped=$((skipped + 1))
        continue
      fi
      ;;
    *)
      warn "unknown target kind: ${kind} (${name})"
      failed=$((failed + 1))
      continue
      ;;
  esac

  if [[ ! -d "${path}" ]]; then
    log "SKIP: ${name} (${path} がありません)"
    skipped=$((skipped + 1))
    continue
  fi

  OUT="${FILES_BACKUP_DIR}/${name}_${TS}.tar.gz"
  log "Archiving ${path} -> ${OUT}"

  # 対象ディレクトリの中身を "." として固める (-C で中に入ってから相対パス)。
  #   - tar のフルパス警告と、復元時に / から展開される事故を避ける
  #   - bind でもボリューム (_data) でも中身の並びが同じになり、復元先を
  #     選ばない: tar -xzf <書庫> -C <戻したい場所>
  if ! tar -czf "${OUT}" -C "${path}" .; then
    rm -f "${OUT}"
    warn "archive failed: ${name}; partial archive removed"
    failed=$((failed + 1))
    continue
  fi

  # 中身まで読めるか確認する (gzip ヘッダだけでは途中切れを検出できない)
  if ! tar -tzf "${OUT}" > /dev/null; then
    rm -f "${OUT}"
    warn "archive verification failed: ${OUT}"
    failed=$((failed + 1))
    continue
  fi

  log "OK: ${name} $(du -h "${OUT}" | awk '{print $1}') ($(tar -tzf "${OUT}" | wc -l) エントリ)"
  saved=$((saved + 1))
done

# 古い世代を削除
find "${FILES_BACKUP_DIR}" -type f -name "*.tar.gz" -mtime "+${FILES_BACKUP_KEEP_DAYS}" -print -delete

log "done: saved=${saved} skipped=${skipped} failed=${failed}"
[[ "${failed}" -eq 0 ]] || die "${failed} 件のアーカイブに失敗しました"
