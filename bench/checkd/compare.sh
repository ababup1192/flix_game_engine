#!/usr/bin/env bash
# compare.sh — checkd の答えと素の CLI（flix check）の答えを比べる（docs/checkd.md の作り直しの段 C-0・測る道具 2）。
#
#   bench/checkd/compare.sh <パッケージ> [壊すファイル=src/ の一番小さい .flix]
#
# 場合ごとに（そのまま・型の誤り・構文の誤り・知らない名前・使わない def）、checkd と素の flix check を同じ中身で流し、
# 終了コードと出力（色・経過の行・依存の解決の行を落とした物）が同じかを比べる。違えば差を <パッケージ>/.checkd-c0/ に残す。
set -u
pkg=$(cd "${1:?パッケージのディレクトリを渡す}" && pwd)
here=$(cd "$(dirname "$0")/../.." && pwd)
fge="$here/bin/fge"
target=${2:-$(cd "$pkg" && find src -name '*.flix' -type f -exec wc -c {} + | sort -n | awk '$2 != "total" {print $2; exit}')}
file="$pkg/$target"
out="$pkg/.checkd-c0"; mkdir -p "$out"
orig="$out/compare.orig"; cp "$file" "$orig"
# 止められたら終わる（EXIT の trap で元の中身へ戻す）
trap 'cp "$orig" "$file"' EXIT
trap 'exit 130' INT TERM
flix=$(grep -E '^\s*ENGINE\s*[?:]*=' "$pkg/local.mk" 2>/dev/null | sed -E 's/^[^=]*=\s*//' | tail -1)/bin/flix
[ -x "$flix" ] || flix="$here/bin/flix"

# 出力をそろえる: 色を落とし、依存の解決（字下げの付いた行も）・経過の秒・checkd の経過の行と、終わりの空行を外す
# （素の CLI は終わりに空行を 1 つ出し、checkd の scrub はそれを落とす。中身の差ではない）。
norm() {
    sed -E 's/\x1b\[[0-9;]*m//g' | grep -vE '^\s*(Found|Resolving|Downloading|Running|Dependency|Cached|Adding)|^\[checkd\]' \
        | sed -E 's/[0-9]+(\.[0-9]+)?(ms|s)\b/<t>/g' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

cases="clean type syntax name unused"
apply() {
    cp "$orig" "$file"
    case "$1" in
        clean)  ;;
        type)   printf '\ndef checkdC0Type(): Int32 = "c0"\n' >> "$file" ;;
        syntax) printf '\ndef checkdC0Syntax(: Int32 = 1\n' >> "$file" ;;
        name)   printf '\ndef checkdC0Name(): Int32 = checkdC0NoSuchName\n' >> "$file" ;;
        unused) printf '\ndef checkdC0Unused(): Int32 = { let x = 1; 2 }\n' >> "$file" ;;
    esac
}
same=0; diff=0; fallback=0
for c in $cases; do
    apply "$c"
    CHECKD_DEBUG=1 "$fge" checkd "$pkg" > "$out/compare-$c.checkd.raw" 2> "$out/compare-$c.checkd.why"; dcode=$?
    # checkd が素の CLI へ落ちて答えたなら、比べても CLI と CLI になる（常駐の数の上限・追いつけない書き換えなど）。
    if grep -q '素の' "$out/compare-$c.checkd.why"; then path=cli; fallback=$((fallback + 1)); else path=daemon; fi
    (cd "$pkg" && "$flix" check) > "$out/compare-$c.cli.raw" 2>&1; ccode=$?
    norm < "$out/compare-$c.checkd.raw" > "$out/compare-$c.checkd.txt"
    norm < "$out/compare-$c.cli.raw" > "$out/compare-$c.cli.txt"
    if [ "$dcode" = "$ccode" ] && cmp -s "$out/compare-$c.checkd.txt" "$out/compare-$c.cli.txt"; then
        same=$((same + 1)); echo "  $c: 同じ（exit ${dcode}・checkd は ${path}）"
    else
        diff=$((diff + 1)); echo "  $c: 違う（checkd exit ${dcode}（${path}）・CLI exit ${ccode}。差は diff $out/compare-$c.checkd.txt $out/compare-$c.cli.txt）"
    fi
done
echo "[compare] 同じ ${same}・違う ${diff}・checkd が素の CLI へ落ちた ${fallback}（壊したファイル ${target}）"
