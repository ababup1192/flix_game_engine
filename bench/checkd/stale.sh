#!/usr/bin/env bash
# stale.sh — checkd の「古い答え」を数える（docs/checkd.md の作り直しの段 C-0・測る道具 1）。
#
#   bench/checkd/stale.sh <パッケージ> [往復の数=200] [壊すファイル=src/ の一番小さい .flix]
#
# 1 往復 = 壊す → すぐ checkd → 直す → すぐ checkd。壊した後の答えが緑（exit 0）・直した後の答えが赤（exit ≠ 0）なら、
# その答えは「書き換える前の中身」に対する答え = 古い答え。壊し方は、ファイルの終わりに型の合わない def を 1 行足すこと
# （直すのは元の中身へ戻すこと）。どの経路で答えたか（常駐 / 素の CLI へ落ちた）も CHECKD_DEBUG=1 の記録から分ける。
# 出力: 1 回ごとの行（往復・壊す/直す・期待・exit・秒・経路）を <パッケージ>/.checkd-c0/stale.tsv、最後に数のまとめを標準出力へ。
# 測る相手は作業場の写しにする（壊すファイルを書き換えるため）。止めても trap で元の中身へ戻す。
set -u
pkg=$(cd "${1:?パッケージのディレクトリを渡す}" && pwd)
rounds=${2:-200}
here=$(cd "$(dirname "$0")/../.." && pwd)
fge="$here/bin/fge"
target=${3:-$(cd "$pkg" && find src -name '*.flix' -type f -exec wc -c {} + | sort -n | awk '$2 != "total" {print $2; exit}')}
file="$pkg/$target"
[ -f "$file" ] || { echo "stale.sh: $file が無い" >&2; exit 2; }
out="$pkg/.checkd-c0"; mkdir -p "$out"
orig="$out/stale.orig"; cp "$file" "$orig"
restore() { cp "$orig" "$file"; }
# 止められたら終わる（EXIT の trap で元の中身へ戻す。INT・TERM で戻すだけにすると往復を続けてしまう）
trap restore EXIT
trap 'exit 130' INT TERM
log="$out/stale.tsv"
printf 'round\tstep\twant\texit\tseconds\tpath\n' > "$log"

# 1 回 checkd を流して「exit 秒 経路」を返す。経路は CHECKD_DEBUG の記録に「素の」があれば cli、無ければ daemon。
# 今の時刻（小数の秒。macOS の date は小数を出さないので bash 5 の EPOCHREALTIME、無ければ perl）。
now() { if [ -n "${EPOCHREALTIME:-}" ]; then echo "$EPOCHREALTIME"; else perl -MTime::HiRes=time -e 'printf "%.3f", time'; fi; }
run() {
    local t0 t1 code why
    t0=$(now)
    why=$(CHECKD_DEBUG=1 "$fge" checkd "$pkg" 2>&1 >/dev/null); code=$?
    t1=$(now)
    case "$why" in *素の*) path=cli ;; *) path=daemon ;; esac
    echo "$code $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') $path"
}

stale=0; wrong_path=0; begin=$(date +%s)
for r in $(seq 1 "$rounds"); do
    printf '\ndef checkdC0Broken(): Int32 = "c0"\n' >> "$file"
    read -r code secs path <<< "$(run)"
    [ "$code" = 0 ] && stale=$((stale + 1))
    [ "$path" = cli ] && wrong_path=$((wrong_path + 1))
    printf '%s\tbreak\tred\t%s\t%s\t%s\n' "$r" "$code" "$secs" "$path" >> "$log"
    restore
    read -r code secs path <<< "$(run)"
    [ "$code" != 0 ] && stale=$((stale + 1))
    [ "$path" = cli ] && wrong_path=$((wrong_path + 1))
    printf '%s\tfix\tgreen\t%s\t%s\t%s\n' "$r" "$code" "$secs" "$path" >> "$log"
done
end=$(date +%s)
checks=$((rounds * 2))
echo "[stale] $rounds 往復（check $checks 回）: 古い答え $stale 回・素の CLI へ落ちた $wrong_path 回・$((end - begin)) 秒（壊したファイル ${target}）"
awk -F'\t' 'NR > 1 { n[$2 FS $6]++; s[$2 FS $6] += $5 } END { for (k in n) { split(k, a, FS); printf "  %s %s: %d 回・平均 %.1f 秒\n", a[1], a[2], n[k], s[k] / n[k] } }' "$log" | sort
echo "  1 回ごとの記録: $log"
