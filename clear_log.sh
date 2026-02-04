#!/usr/bin/env bash
set -euo pipefail

dir="${1:?usage: $0 <dir>}"
shopt -s nullglob

files=("$dir"/*.log)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "No .log files in: $dir"
  exit 0
fi

rm -f -- "${files[@]}"
echo "deleted ${#files[@]} log files in $dir"
