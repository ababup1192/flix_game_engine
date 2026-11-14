#!/usr/bin/env bash
# baseline.sh — 3 つのベンチ（sprite_stress・crowd2d・scene3d）の決まった組を順に回し、結果の行を 1 つのフォルダへ集める。
#
#   bench/baseline.sh <出力のフォルダ> [pc|web|all]     既定は all
#
# 出力: <出力>/pc.jsonl（1 行 = 1 区間。[bench] result の JSON に pass を足した物）と <出力>/web.jsonl（同じ形。cpu_* が付く）、
#       <出力>/web-env.jsonl（1 行 = 1 本。Chrome の版・viewport・query・描き手）。
# 同じ組を PASSES 回（既定 2）通して回す。同じ条件の 2 回の差が、その日のその機械の揺れ。
# ブラウザ版は先に make sync-engine-full-web。書き出し（make bench-web-export）はここで 1 回だけ流す。
#
# 環境変数: PASSES（通す回数）・COOL（1 本ごとの間の秒・既定 20）・FRAMES（1 区間で測るコマ数・既定 300）。
#
# WhyNot: 1 つのプロセスで全部の組を続けて回さない — 重い区間の直後の軽い区間は熱で遅く出る（sprite_stress/RESULTS.md）。
#   1 本ごとにプロセスを分け、数は軽い方から並べ、間を空ける。
# WhyNot: jq を使わない — devbox に入っていない。
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: bench/baseline.sh <出力のフォルダ> [pc|web|all]}
what=${2:-all}
passes=${PASSES:-2}
cool=${COOL:-20}
frames=${FRAMES:-300}
mkdir -p "$out"
out=$(cd "$out" && pwd)

# pc <ベンチ> <環境変数…> — make run を流し、結果の行を pc.jsonl へ足す。
pc() {
	local name=$1; shift
	echo "[baseline] pc $name $* (pass $pass)" >&2
	(cd "$engine/bench/$name" && env FRAMES="$frames" "$@" make --no-print-directory run 2>&1) \
		| sed -n "s/^\[bench\] result {/{\"pass\":$pass,/p" >> "$out/pc.jsonl"
	sleep "$cool"
}

# web <ベンチ> <query> — ヘッドレスの Chrome で測り、区間ごとの行を web.jsonl へ足す。
web() {
	local name=$1 query=$2 rows="$out/.rows.jsonl"
	echo "[baseline] web $name ?$query (pass $pass)" >&2
	rm -f "$rows"
	(cd "$engine" && make --no-print-directory bench-web BENCH="$name" BENCH_WEB_EXPORT=off ARGS="$query&frames=$frames" JSONL="$rows") \
		| sed 's/,"results":.*/}/; s/^{/{"bench":"'"$name"'",/' >> "$out/web-env.jsonl"
	sed "s/^{/{\"pass\":$pass,/" "$rows" >> "$out/web.jsonl"
	rm -f "$rows"
	sleep "$cool"
}

# field <pc|web> <つまみ…> — scene3d の物を並べた場面。つまみは n・shapes・mats・moving・alpha・shadow（小文字・= でつなぐ）。
field() {
	local target=$1; shift
	if [ "$target" = web ]; then
		local query="scene=field&repeat=2"
		for knob in "$@"; do query="$query&$knob"; done
		web scene3d "$query"
	else
		local vars=(SCENE=field REPEAT=2)
		for knob in "$@"; do
			case "${knob%%=*}" in
				n) vars+=("COUNT=${knob#*=}") ;;
				*) vars+=("$(printf '%s' "${knob%%=*}" | tr a-z A-Z)=${knob#*=}") ;;
			esac
		done
		pc scene3d "${vars[@]}"
	fi
}

fields() {
	field "$1" n=1000
	field "$1" n=5000
	field "$1" n=12000
	field "$1" n=12000 shapes=16 mats=16
	field "$1" n=12000 shapes=each
	field "$1" n=12000 moving=0
	field "$1" n=12000 moving=10
	field "$1" n=12000 shadow=1
	field "$1" n=12000 alpha=10
}

if [ "$what" = web ] || [ "$what" = all ]; then
	for name in sprite_stress crowd2d scene3d; do
		(cd "$engine" && make --no-print-directory bench-web-export BENCH="$name") >&2
	done
fi

if [ "$what" = pc ] || [ "$what" = all ]; then rm -f "$out/pc.jsonl"; fi
if [ "$what" = web ] || [ "$what" = all ]; then rm -f "$out/web.jsonl" "$out/web-env.jsonl"; fi
for pass in $(seq 1 "$passes"); do
	if [ "$what" = pc ] || [ "$what" = all ]; then
		pc sprite_stress TEX=1
		pc sprite_stress TEX=16
		pc sprite_stress TEX=256
		pc sprite_stress TEX=1 BLEND=alt COUNTS=5000
		pc sprite_stress TEX=1 DIAG=0
		pc sprite_stress
		pc crowd2d COUNTS=6000,10000,20000 SEARCH=grid
		pc scene3d REPEAT=2
		fields pc
	fi
	if [ "$what" = web ] || [ "$what" = all ]; then
		web sprite_stress "tex=1"
		web sprite_stress "tex=16"
		web sprite_stress "tex=256"
		web sprite_stress "tex=1&blend=alt&n=5000"
		web crowd2d "n=6000,10000,20000&search=grid"
		web scene3d "scene=room&repeat=2"
		fields web
	fi
done
echo "[baseline] $out" >&2
