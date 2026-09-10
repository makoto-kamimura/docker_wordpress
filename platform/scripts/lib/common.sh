#!/usr/bin/env bash
# platform/scripts 共通の初期化
#
# 使い方（各スクリプトの冒頭で）:
#   # shellcheck source=lib/common.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# 提供するもの:
#   SCRIPT_DIR / PLATFORM_DIR / REPO_DIR  … 呼び出し元スクリプト基準の絶対パス
#   log / warn / die                      … "[ISO8601] メッセージ" 形式の出力
#   load_env                              … lib/load-env.sh
#
# docker-cleanup.sh / vscode-server-cleanup.sh は cron から単体で動かす前提で
# ログファイルへ独自形式で書くため、意図的にこれを読み込んでいない。

# BASH_SOURCE[1] は「このファイルを source したスクリプト」
# shellcheck disable=SC2034  # 呼び出し元で使う
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
# shellcheck disable=SC2034
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "${PLATFORM_DIR}/.." && pwd)"

log()  { echo "[$(date -Iseconds)] $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

# shellcheck source=lib/load-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/load-env.sh"
