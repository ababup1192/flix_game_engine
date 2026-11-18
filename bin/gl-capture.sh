#!/usr/bin/env bash
# gl-capture.sh — テンプレートの場面を実機の窓（隠しウィンドウ）で起動し、頭の数コマの絵を撮って SHA-256 を控える。
#
#   bin/gl-capture.sh <出力のフォルダ> [<フォルダ>:<START の字> ...]   撮る（フォルダは engine の根から。場面を省くと下の既定の場面）。描き手は既定の
#                                                                      WebGPU（FLIX_GE_BACKEND=webgpu）。起動のログに '[backend] webgpu:' が無い（GL へ落ちた）・
#                                                                      起動の後に足せなかった字の知らせがある時は止める
#   bin/gl-capture.sh --backend gl|webgpu <出力のフォルダ> [...]       描き手を選んで撮る（gl は FLIX_GE_BACKEND=gl の GL の backend）
#   bin/gl-capture.sh --compare <A> <B> [--skip <フォルダ名> ...]       2 回の SHA を比べる（フォルダか SHA の一覧のファイル。違えば exit 1）
#                                                                      --skip は撮った物のフォルダ名（例 scene3d・rpg-starter__title）と完全に一致する場面を比べない
#   --only <名前>（撮る時は出力のフォルダの前・比べる時は --skip と同じ所。何度でも）  撮る場面と比べる行をその名前だけにする。名前は撮った物の
#                                                                      フォルダ名（rpg-starter__title）か、その __ の前（rpg-starter = その場面全部）
#
# 組む口: FLIX_GE_HIDDEN（framebuffer を design の大きさに固定）・FLIX_GE_FRAME_SHOT（swap の直前の絵を frame-N.png へ）・
# FLIX_GE_FIXED_DT（dt を固定。2 コマ目以降もバイトで比べられる）・FLIX_GE_MUTE・START（App.withStarts の場面から起動）。
# 撮る engine はゲームの lib の fpkg（engine の作業場では make sync-engine-full が配った物）。dt の固定を知らない古い fpkg で
# 撮ると 2 コマ目から揃わないので、起動のログに dt を固定した知らせの行が無ければ止める。
# 環境変数: CAPTURE_GLYPHS（FLIX_GE_GLYPHS に置く値・--backend webgpu の既定は used・ほかは置かない）・FRAMES（撮るコマ数・既定 6）・DT（既定 1/60。off で固定しない＝実時間の dt。比べられるのは頭のコマだけになる）・
#           WAIT_SECONDS（jar を作った後の、1 場面の起動から撮り終えるまでの上限・既定 180）。
# 撮る間は、絵や時間を変えうる呼ぶ人の環境変数（下の reset_env）を外す。
#
# 出力: <出力>/<フォルダの名前>__<場面>（場面が空なら名前だけ）/frame-1.png … と <出力>/SHA256SUMS（行は「<SHA>  <名前>__<場面>/frame-N.png」）。
# START の字が空なら START を置かない（withStarts の無い物・bench/scene3d のように起動の場面が 1 つの物）。
# GL と WebGPU の絵は機械・ドライバ（WebGPU は Dawn の版も）で変わるので、比べるのは同じ機械で撮った 2 回どうし（基準の SHA を別の機械と比べない）。
#
# 揃わない物: マウスの位置は実のカーソルを読む。撮っている間はマウスを触らない（hover で絵が変わる場面がある）。
# --compare が落ちたら、まずその回にマウスを動かしていないかを疑う（docs/flow.md の「実機の dt を固定する」）。
#
# WhyNot: rpg・ノベルの menu を既定に入れない — START の登録簿に menu を開いた始まりが無い（開くには操作の記録が要り、C6 の仕事）。
# WhyNot: fps3d_lab などリポジトリの外のゲームを既定に入れない — その場の lib は自分の版の engine で、写して lib を替えると
# 撮る物がゲームの版と別物になる。3D の実機の道は bench/scene3d で撮る。
# WhyNot: game-starter を既定に入れない — テンプレの src に make new-game が埋める字（__WW__ など）が残っていて、
# その場では組めない。
# WhyNot: ゲームの終わりを待たない — 撮る口は 64 枚で止まるだけで、ゲームは閉じない。FRAMES+1 枚目が出たら
# （FRAMES 枚目を書き終えた印）プロセスの組ごと止める。headless-run が java を子として起こすので、子だけ残さない。
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)

default_scenes=(
	"templates/rpg-starter:title"
	"templates/rpg-starter:field"
	"templates/rpg-starter:battle"
	"templates/rpg-starter:talk"
	"templates/sound-novel-starter:title"
	"templates/sound-novel-starter:talk"
	"templates/tidepool-starter:title"
	"templates/tidepool-starter:level"
	"bench/scene3d:"
)

# 比べる相手はフォルダ（中の SHA256SUMS）か SHA の一覧のファイル（bench/baseline/<版>/gl-capture.sha256）。# の行と、
# skipped（空白で区切ったフォルダ名。撮る時に START の空白は _ にしてある）に入る場面の行は読まない。
# only（空白で区切った名前）が空でなければ、その名前のフォルダ（か __ の前がその名前のフォルダ）の行だけを読む。
# WhyNot: 基準のファイルの側も絞る — 基準は全部の場面を持つので、撮った場面だけと比べると必ず食い違う。
skipped=""
only=""
sums_of() {
	local src
	if [ -d "$1" ]; then src="$1/SHA256SUMS"; else src="$1"; fi
	grep -v '^#' "$src" | awk -v skip="$skipped" -v only="$only" 'BEGIN { n = split(skip, s, " "); for (i = 1; i <= n; i++) if (s[i] != "") drop[s[i]] = 1
			m = split(only, o, " "); for (i = 1; i <= m; i++) if (o[i] != "") keep[o[i]] = 1 }
		{ dir = $2; sub(/\/.*$/, "", dir); head = dir; sub(/__.*$/, "", head)
		  if (!(dir in drop) && (m == 0 || (dir in keep) || (head in keep))) print }'
}
# 撮った物のフォルダ名 $1 が only に入るか。
selected() {
	[ -z "$only" ] && return 0
	local o
	for o in $only; do
		[ "$1" = "$o" ] || [ "${1%%__*}" = "$o" ] && return 0
	done
	return 1
}

if [ "${1:-}" = "--compare" ]; then
	if [ $# -lt 3 ]; then echo "usage: $0 --compare <A> <B> [--skip <フォルダ名> ...]" >&2; exit 2; fi
	a=$2 b=$3
	shift 3
	while [ $# -gt 0 ]; do
		if [ "$1" = --skip ] && [ $# -ge 2 ]; then skipped="$skipped$2 "; shift 2
		elif [ "$1" = --only ] && [ $# -ge 2 ]; then only="$only$2 "; shift 2
		else echo "usage: $0 --compare <A> <B> [--skip <フォルダ名> ...] [--only <名前> ...]" >&2; exit 2; fi
	done
	[ -z "$skipped" ] || echo "[gl-capture] 比べない場面: $skipped"
	[ -z "$only" ] || echo "[gl-capture] 比べる場面だけ: $only"
	set -- --compare "$a" "$b"
	if diff -u <(sums_of "$2") <(sums_of "$3"); then
		echo "[gl-capture] 一致: $(sums_of "$2" | wc -l | tr -d ' ') 枚がバイトまで同じ"
		exit 0
	fi
	echo "[gl-capture] 違う絵がある（上の - が $2・+ が $3）" >&2
	exit 1
fi

backend=webgpu
if [ "${1:-}" = "--backend" ]; then
	if [ $# -lt 2 ] || { [ "$2" != gl ] && [ "$2" != webgpu ]; }; then echo "usage: $0 --backend gl|webgpu <出力のフォルダ> …" >&2; exit 2; fi
	backend=$2
	shift 2
fi
while [ "${1:-}" = "--only" ] && [ $# -ge 2 ]; do only="$only$2 "; shift 2; done

if [ $# -lt 1 ]; then
	echo "usage: $0 [--backend gl|webgpu] <出力のフォルダ> [<フォルダ>:<START> ...] | --compare <A> <B>" >&2
	exit 2
fi

"$engine/bin/check-fpkg-fresh.sh"
out=$1
shift
mkdir -p "$out"
out=$(cd "$out" && pwd)
frames=${FRAMES:-6}
# 撮る口は 64 枚で止まり、FRAMES+1 枚目を撮り終えた印に使うので 63 まで。
if [ "$frames" -lt 1 ] || [ "$frames" -gt 63 ]; then echo "error: FRAMES は 1〜63（撮る口の上限が 64 枚）: $frames" >&2; exit 2; fi
dt=${DT:-1/60}
wait_seconds=${WAIT_SECONDS:-180}
if [ $# -gt 0 ]; then all_scenes=("$@"); else all_scenes=("${default_scenes[@]}"); fi
scenes=()
for scene in "${all_scenes[@]}"; do
	start=${scene#*:}
	if selected "$(basename "${scene%%:*}")${start:+__${start// /_}}"; then scenes+=("$scene"); fi
done
if [ ${#scenes[@]} -eq 0 ]; then echo "[gl-capture] --only $only に当たる場面がありません（名前は rpg-starter か rpg-starter__title の形）" >&2; exit 2; fi

# 絵・時間・起動の道を変えうる環境変数。撮る時は外して、誰が撮っても同じ条件にする。
reset_env=(FLIX_GE_SPLASH_SHOT FLIX_GE_FRAME_STATS FLIX_GE_NO_SPLASH FLIX_GE_GLYPHS FLIX_GE_NO_FONT_CACHE
	FGE_SOFT_SERIAL DEBUG FLOW_RECORD HEADLESS_RESIDENT HEADLESS_JAVA_OPTS JAVA_TOOL_OPTIONS FLIX_GE_CACHE_DIR START
	FLIX_GE_BACKEND FLIX_GE_WEBGPU_FAIL)
# 起動の時に用意する字（FLIX_GE_GLYPHS）。--backend webgpu の既定は used（出しうる字を起動の時に先に作る。webgpu の基準と make webgpu-v1-check の GL との比べが、この並びのアトラスで撮ってある）。
# GL と画素で比べる時は、GL の側も同じ CAPTURE_GLYPHS で撮る（字のアトラスの並びが変わるので、GLYPHS の無い撮り置きの SHA とは比べない）。
glyphs=${CAPTURE_GLYPHS:-}
if [ "$backend" = webgpu ] && [ -z "$glyphs" ]; then glyphs=used; fi

capture_one() {
	local game=$1 start=$2
	local dir="$out/$(basename "$game")${start:+__${start// /_}}"
	rm -rf "$dir"
	mkdir -p "$dir"
	echo "[gl-capture] ${game} START=\"${start}\" → ${dir}"
	(
		# WhyNot: set -e に任せない — `( … ) || { … }` の左のサブシェルでは bash が set -e を効かせない。
		cd "$engine/$game" || exit 1
		unset "${reset_env[@]}"
		export FLIX_GE_HIDDEN=1 FLIX_GE_MUTE=1 FLIX_GE_FRAME_SHOT="$dir"
		if [ -n "$start" ]; then export START="$start"; else unset START; fi
		if [ "$dt" = off ]; then unset FLIX_GE_FIXED_DT; else export FLIX_GE_FIXED_DT="$dt"; fi
		export FLIX_GE_BACKEND="$backend"
		if [ -n "$glyphs" ]; then export FLIX_GE_GLYPHS="$glyphs"; fi
		export FLIX_CMD="$engine/bin/flix"
		# WhyNot: jar を作る時間を撮る時間の上限に入れない — 作り直しは 30 秒〜数分かかり、初回だけ撮れなかった扱いになる。
		"$engine/bin/headless-run" --build-only > "$dir/build.log" 2>&1 || exit 1
		perl -e '
			my ($limit, $marker) = (shift, shift);
			my $pid = fork;
			if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec: $!" }
			# 子は別のプロセスの組にいて端末の Ctrl-C が届かないので、止められた時は組ごと止めてから抜ける。
			$SIG{INT} = $SIG{TERM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; exit 130 };
			my $waited = 0;
			while (!-e $marker && $waited < $limit * 10) {
				if (waitpid($pid, 1) > 0) { kill "TERM", -$pid; exit 3 }
				select(undef, undef, undef, 0.1); $waited++;
			}
			kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; waitpid($pid, 0);
			exit(-e $marker ? 0 : 4);
		' "$wait_seconds" "$dir/frame-$((frames + 1)).png" "$engine/bin/headless-run" --window main \
			> "$dir/run.log" 2>&1
	) || {
		echo "[gl-capture] ${game} ${start}: ${frames} コマ撮れなかった（${dir}/build.log と run.log）" >&2
		tail -20 "$dir/build.log" "$dir/run.log" 2>/dev/null >&2
		return 1
	}
	if [ "$dt" != off ] && ! grep -aq '\[lwjgl\] FLIX_GE_FIXED_DT:' "$dir/run.log"; then
		echo "[gl-capture] ${game}: 起動のログに dt を固定した知らせが無い（lib の engine が古い？ engine では make sync-engine-full）" >&2
		return 1
	fi
	# WhyNot: --backend webgpu の撮り物を起動のログを見ずに受けない — WebGPU を使えずに GL へ落ちた絵を「WebGPU の絵」として比べてしまう。
	if [ "$backend" = webgpu ]; then
		if ! grep -aq '\[backend\] webgpu:' "$dir/run.log"; then
			echo "[gl-capture] ${game}: 起動のログに '[backend] webgpu:' が無い（GL へ落ちた。${dir}/run.log）" >&2
			grep -a '\[backend\]' "$dir/run.log" >&2 || true
			return 1
		fi
		if grep -aq '起動の後に足せなかった字' "$dir/run.log"; then
			echo "[gl-capture] ${game}: WebGPU が起動の後に字を足せなかった（字の欠けた絵。${dir}/run.log）" >&2
			return 1
		fi
	fi
	local n=$((frames + 1))
	while [ -e "$dir/frame-$n.png" ]; do rm -f "$dir/frame-$n.png"; n=$((n + 1)); done
}

# WhyNot: 撮る前にセーブを脇へ移して戻す形にしない — 途中で落ちると人のセーブが戻らない。見つけたら止めて、外すのは人に任せる。
saves_found=
for scene in "${scenes[@]}"; do
	for f in "$engine/${scene%%:*}"/saves/*.json; do
		[ -e "$f" ] && saves_found="$saves_found $f"
	done
done
if [ -n "$saves_found" ]; then
	echo "[gl-capture] セーブがあると起動の絵（タイトルの「つづきから」など）が変わるので止めた。外してから撮る:" >&2
	printf '%s\n' $saves_found | sort -u | sed 's/^/  /' >&2
	exit 2
fi

captured=()
for scene in "${scenes[@]}"; do
	capture_one "${scene%%:*}" "${scene#*:}"
	start=${scene#*:}
	captured+=("$(basename "${scene%%:*}")${start:+__${start// /_}}")
done

# 今回撮った場面のフォルダだけを数える（同じ OUT に前の回の別の場面が残っていても混ぜない）。
(cd "$out" && for d in "${captured[@]}"; do ls "$d"/frame-*.png; done | sort -t/ -k1,1 -k2,2V | xargs shasum -a 256) > "$out/SHA256SUMS"
echo "[gl-capture] $(wc -l < "$out/SHA256SUMS" | tr -d ' ') 枚 → $out/SHA256SUMS"
