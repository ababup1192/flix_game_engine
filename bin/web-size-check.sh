#!/bin/bash
# ブラウザ版の wasm（classes.wasm.br）の大きさを、testdata/web-size.tsv に記録したテンプレートごとの値と比べる。
# 使い方: bin/web-size-check.sh <名前> <書き出したフォルダ> [--update]
#   記録より WEB_SIZE_GROWTH（既定 3）% を超えて大きければ exit 1。記録に無い名前は知らせるだけで通す。
#   --update は今の大きさで記録の行を書き換える（増えを受け入れる時。理由はコミットに書く）。
# WhyNot: classes.wasm（生）でなく .br を比べる — 頁が取りに行くのは .br で、生は名前の区画などで揺れ、圧縮後の増えと比が合わない。
set -euo pipefail
name="$1"; dir="$2"; mode="${3:-}"
table="$(dirname "$0")/../testdata/web-size.tsv"
growth="${WEB_SIZE_GROWTH:-3}"
br="$dir/classes.wasm.br"
[ -f "$br" ] || { echo "[web-size] $name: $br が無い（書き出しが .br を作っていない）"; exit 1; }
now=$(wc -c < "$br" | tr -d ' ')

if [ "$mode" = --update ]; then
  rows=$(grep -v '^#' "$table" | grep -v "^$name	" || true)
  head=$(grep '^#' "$table" || true)
  { [ -n "$head" ] && printf '%s\n' "$head"; { [ -n "$rows" ] && printf '%s\n' "$rows"; printf '%s\t%s\n' "$name" "$now"; } | sort; } > "$table.new"
  mv "$table.new" "$table"
  echo "[web-size] $name: 記録を $now バイトにした"
  exit 0
fi

base=$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$table")
if [ -z "$base" ]; then
  echo "[web-size] $name: 記録が無い（$now バイト）。門にするなら bin/web-size-check.sh $name $dir --update"
  exit 0
fi
limit=$(( base * (100 + growth) / 100 ))
pct=$(awk -v a="$now" -v b="$base" 'BEGIN { printf "%+.1f", (a - b) * 100 / b }')
if [ "$now" -gt "$limit" ]; then
  echo "[web-size] $name: classes.wasm.br が $now バイト（記録 $base から ${pct}%・上限 +${growth}%）。"
  echo "  増えた所は bin/fge wasm-size $dir --diff <前の書き出し> で見る。受け入れるなら make web-size-update WEB_LOAD_GAMES=<ゲーム> WEB_EXPORT=off（理由をコミットに書く）"
  exit 1
fi
echo "[web-size] $name: $now バイト（記録 $base から ${pct}%・上限 +${growth}%）"
