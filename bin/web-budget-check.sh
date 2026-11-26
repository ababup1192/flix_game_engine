#!/bin/bash
# export-web のログの「遊べるまで（すぐ押した時・4G）: 約 X 秒 / 予算 Y 秒」を読み、予算を超えたら exit 1、余裕が 1 秒を切ったら知らせる。
# 使い方: bin/web-budget-check.sh <名前> <export-web のログ>
# WhyNot: bundle.json を web-check に掛けない — web-load-check は --draft で書き出すので、web-check は draft のマーカーで拒む。
set -euo pipefail
name="$1"; log="$2"
line=$(grep -m1 '遊べるまで（すぐ押した時' "$log" || true)
if [ -z "$line" ]; then
  echo "[web-budget] $name: 書き出しのログに遊べるまでの見込みの行が無い（$log）"
  exit 1
fi
read -r est budget < <(printf '%s\n' "$line" | sed -n 's/.*約 \([0-9.]*\) 秒 \/ 予算 \([0-9.]*\) 秒.*/\1 \2/p')
if [ -z "${est:-}" ] || [ -z "${budget:-}" ]; then
  echo "[web-budget] $name: 見込みの行の形が読めない: $line"
  exit 1
fi
verdict=$(awk -v e="$est" -v b="$budget" 'BEGIN { if (e > b) print "over"; else if (b - e < 1.0) print "near"; else print "ok" }')
case "$verdict" in
  over) echo "[web-budget] $name: 遊べるまで約 $est 秒が予算 $budget 秒を超えた（起動で取る物を後回しにするか減らす・docs/startup.md）"; exit 1 ;;
  near) echo "[web-budget] $name: 遊べるまで約 $est 秒 / 予算 $budget 秒 — 余裕が 1 秒を切った（知らせるだけ）" ;;
  *)    echo "[web-budget] $name: 遊べるまで約 $est 秒 / 予算 $budget 秒" ;;
esac
