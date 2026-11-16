#!/bin/sh
# link-tree.sh — フォルダの中のファイルを、別のフォルダへファイル単位の symlink で並べる（フォルダの形はそのまま）。
#
# 使い方: bin/link-tree.sh [--relative] [--only-missing] [--name <glob>] <元> <先>
#   --relative      symlink の中身を相対パスにする（<元> と <先> はリポの根からの相対で渡し、根で流す）。
#                   無い時は <元> をそのまま前に付ける（絶対パスで渡す）。
#   --only-missing  もう symlink がある所は触らない。
#   --name <glob>   当たる名前の物だけ（例 '*.flix'）。無い時はファイル全部。
#
# WhyNot: フォルダごとの symlink 1 本にしない — Flix のソースの走査がフォルダの symlink をたどらない。
# WhyNot: 相対の深さを realpath で求めない — macOS の古い realpath に --relative-to が無い。<先> の / の数から数える。
set -eu

relative=0
only_missing=0
name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --relative) relative=1; shift ;;
    --only-missing) only_missing=1; shift ;;
    --name) name="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "link-tree.sh: 知らない旗 $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [ $# -ne 2 ]; then
  echo "使い方: bin/link-tree.sh [--relative] [--only-missing] [--name <glob>] <元> <先>" >&2
  exit 2
fi
from="$1"
to="$2"

list() {
  if [ -n "$name" ]; then (cd "$from" && find . -name "$name"); else (cd "$from" && find . -type f); fi
}

list | sed 's|^\./||' | while read -r f; do
  d=$(dirname "$f")
  if [ "$d" = "." ]; then dir="$to"; else dir="$to/$d"; fi
  link="$dir/$(basename "$f")"
  if [ "$only_missing" = 1 ] && [ -L "$link" ]; then continue; fi
  mkdir -p "$dir"
  if [ "$relative" = 1 ]; then
    depth=$(printf '%s' "$dir" | tr -cd '/' | wc -c | tr -d ' ')
    up=$(printf '../%.0s' $(seq 0 "$depth"))
    ln -sfn "$up$from/$f" "$link"
  else
    ln -sfn "$from/$f" "$link"
  fi
done
