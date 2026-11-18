#!/usr/bin/env bash
# make refactor-smoke の本体: engine の新しい型を使う小さなゲーム（testdata/refactor-smoke）で、checkd・bin/fge refactor・flixlint が
# 通るかを確かめる。engine の束は make sync-engine-full の置き場（build/fpkg-store/current）を使う。
#
#   bin/refactor-smoke.sh <版> <lib の中の行き先> <fpkg の名前> <toml の名前>
#
# 確かめる事:
#   1. checkd の常駐で check が通る
#   2. 束を張り替える（make sync-engine-full と同じ symlink の置き換え）と、次の check が古い常駐を止めて起こし直す
#   3. refactor search・usages（record の欄・enum の case）が場面のソースを引ける
#   4. flixlint の規則が facts を作り切り、違反 0 で終わる
# 起こした常駐は最後に止める。
set -uo pipefail
version=$1 subpath=$2 fpkg_name=$3 toml_name=$4
engine="$(cd "$(dirname "$0")/.." && pwd)"
fge="$engine/bin/fge"
work="$engine/build/refactor-smoke"
store="$engine/build/fpkg-store/current/engine_full"
log="$work/.smoke"
[ -f "$store/package.fpkg" ] || { echo "[refactor-smoke] $store に束が無い（先に make sync-engine-full）"; exit 2; }

[ ! -d "$work" ] || "$fge" checkd --stop "$work" >/dev/null 2>&1
rm -rf "$work"
mkdir -p "$work/lib" "$log"
cp -R "$engine/testdata/refactor-smoke/." "$work/"
printf '[package]\nversion = "0.1.0"\nflix = "0.80.0"\n\n[dependencies]\n"github:ababup1192/flix_game_engine" = { version = "%s", mount = "fge", security = "unrestricted" }\n' "$version" > "$work/flix.toml"
[ ! -d "$engine/lib/external" ] || cp -R "$engine/lib/external" "$work/lib/external"
link() { (cd "$engine" && bin/fpkg-store.sh link build/refactor-smoke "$subpath" "$fpkg_name" "$toml_name" >/dev/null); }
link || { echo "[refactor-smoke] 束を張れない"; exit 2; }

fail=0
ok() { echo "[refactor-smoke] OK  $1"; }
ng() { echo "[refactor-smoke] NG  $1（$2）"; fail=1; }
# expect <名前> <出力に含むべき字> <コマンド…>: 終了コード 0 で、出力に字を含む
expect() {
    local name=$1 want=$2; shift 2
    local out="$log/$name.log"
    (cd "$work" && "$@") > "$out" 2>&1
    local code=$?
    if [ "$code" -ne 0 ]; then ng "$name" "終了コード ${code}・${out}"
    elif ! grep -qF -- "$want" "$out"; then ng "$name" "「${want}」が出ない・${out}"
    else ok "$name"; fi
}

expect check "" "$fge" checkd .
sleep 1
link
expect check-after-relink "古い依存" "$fge" checkd .
expect search "Shot.shiftY" "$fge" refactor search shiftY
expect usages-field "src/Shot.flix" "$fge" refactor usages 'Camera3d.Camera3d#lensShift'
expect usages-case "src/Shot.flix" "$fge" refactor usages 'Scene3d.LightUnits.Physical'

prep="$(cd "$work" && "$fge" flixlint-prepare 2>"$log/flixlint-prepare.log")" || { ng flixlint "flixlint-prepare が落ちた・$log/flixlint-prepare.log"; prep=""; }
if [ -n "$prep" ]; then
    eval "$prep"
    jar="$(env FLIX_PRINT_JAR=1 "$engine/bin/flix")"
    expect flixlint "" "$FLIXLINT_DIR/bin/flixlint" --flix-jar "$jar" --shim "$FLIXLINT_SHIM" --rules lint/rules.flix --stage typed --build-dir build/flixlint src
fi

"$fge" checkd --stop "$work" >/dev/null 2>&1
if [ "$fail" -ne 0 ]; then
    echo "[refactor-smoke] 落ちた（ログ ${log}）"
    exit 1
fi
echo "[refactor-smoke] 全部通った"
