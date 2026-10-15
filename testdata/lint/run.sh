#!/bin/sh
# 負の見本（lint がちゃんと鳴るか・鳴らないか）の走らせ手。
#
#   sh testdata/lint/run.sh                     全ケースを走らせて expected.txt と突き合わせる
#   sh testdata/lint/run.sh --record            expected.txt を今の出力で作り直す
#   sh testdata/lint/run.sh <ケースのパス> ...   そのケースだけ
#   sh testdata/lint/run.sh --quiet             ok の行を出さず、最後の数と NG だけ
#
# 中身は POSIX sh と bin/fge だけ。Python は要らない。
#
# 1 ケース = testdata/lint/<検査名>/<ケース名>/ で、中身は
#   cmd.txt      走らせ方（POSIX sh。下の 3 つの環境変数が入っている）
#   expected.txt cmd.txt の stdout+stderr と、最後の行 `[exit=<終了コード>]`
#   その他       cmd.txt が使う入力（input.sprite.json / overlay/ / repo/ など）
#
# cmd.txt に渡る物:
#   ENGINE  このリポの根
#   CASE    そのケースのフォルダ（絶対パス）
#   WORK    そのケース専用の空の作業フォルダ（毎回作り直して毎回消す）
#
# カレントディレクトリは 2 通りある。ファイルを引数で渡すだけの検査はこのリポの根
# （出力に testdata/lint/... の相対パスがそのまま出るため）、偽リポを組む検査は
# ケースのフォルダ（出力に repo/... の相対パスが出るため）。
#
# 出力に $WORK の絶対パスを混ぜないこと（走らせるたびに変わって突き合わせが壊れる）。
set -u
ENGINE=$(cd "$(dirname "$0")/../.." && pwd)
export ENGINE

# 根から走らせる検査（ファイル 1 つを引数で渡せば鳴らせる）。
ROOT_CWD_TOOLS="sprite anim style jargon fallback ui-overflow view f32 explain-error hooks flix-reserved loop z-table"
# ケースのフォルダから走らせる検査（リポ全体を見るので使い捨ての偽リポを組む）。
CASE_CWD_TOOLS="check-refs api-diff check-render-budget check-api-index check-api-released precommit stage-engine fetch-engine palette audio images"

record=0
quiet=0
cases=""
for a in "$@"; do
  case $a in
    --record) record=1 ;;
    --quiet) quiet=1 ;;
    *) cases="$cases $a" ;;
  esac
done
if [ -z "$cases" ]; then
  for t in $ROOT_CWD_TOOLS $CASE_CWD_TOOLS; do
    cases="$cases $(find "$ENGINE/testdata/lint/$t" -name cmd.txt | sort | sed 's|/cmd.txt$||')"
  done
fi

ok=0
ng=0
for c in $cases; do
  if [ ! -f "$c/cmd.txt" ]; then
    echo "NG       $c (cmd.txt がありません)"
    ng=$((ng + 1))
    continue
  fi
  CASE=$(cd "$c" && pwd); export CASE
  tool=$(basename "$(dirname "$CASE")")
  cwd=$ENGINE
  for t in $CASE_CWD_TOOLS; do
    [ "$t" = "$tool" ] && cwd=$CASE
  done
  WORK=$(mktemp -d); export WORK
  out=$( (cd "$cwd" && sh "$CASE/cmd.txt") 2>&1; echo "[exit=$?]" )
  rm -rf "$WORK"
  if [ "$record" = 1 ]; then
    printf '%s\n' "$out" > "$CASE/expected.txt"
    echo "recorded ${CASE#$ENGINE/}"
    ok=$((ok + 1))
  elif printf '%s\n' "$out" | diff -u "$CASE/expected.txt" - > /dev/null 2>&1; then
    [ "$quiet" = 1 ] || echo "ok       ${CASE#$ENGINE/}"
    ok=$((ok + 1))
  else
    echo "FAIL     ${CASE#$ENGINE/}"
    printf '%s\n' "$out" | diff -u "$CASE/expected.txt" - | sed 's/^/    /'
    ng=$((ng + 1))
  fi
done

echo "$ok 件 ok / $ng 件 NG"
[ "$ng" = 0 ]
