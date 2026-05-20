#!/usr/bin/env bash
# .env を安全に読み込む共通関数
#
# 使い方:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/load-env.sh"
#   load_env /path/to/.env
#
# 背景:
#   `source .env` は Salt キー等の値に () ! $ が含まれると bash 構文エラーになる。
#   行単位で export することで特殊文字を含む値にも対応する。

load_env() {
  local env_file="${1:-./.env}"

  if [[ ! -f "$env_file" ]]; then
    echo "ERROR: ${env_file} not found" >&2
    return 1
  fi

  local _line _key _val
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ "$_line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$_line" =~ ^([^=]+)=(.*)$ ]]; then
      _key="${BASH_REMATCH[1]}"
      _val="${BASH_REMATCH[2]}"
      _val="${_val#\"}" ; _val="${_val%\"}"
      _val="${_val#\'}" ; _val="${_val%\'}"
      export "$_key=$_val"
    fi
  done < "$env_file"
}
