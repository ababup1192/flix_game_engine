#!/usr/bin/env bash
# gl-capture.sh — テンプレートの場面を実機の GL（隠しウィンドウ）で起動し、頭の数コマの絵を撮って SHA-256 を控える。
#
#   bin/gl-capture.sh <出力のフォルダ> [<フォルダ>:<START の字> ...]   撮る（フォルダは engine の根から。場面を省くと下の既定の場面）
#   bin/gl-capture.sh --compare <A> <B> [--skip <フォルダ名> ...]       2 回の SHA を比べる（フォルダか SHA の一覧のファイル。違えば exit 1）
#                                                                      --skip は撮った物のフォルダ名（例 scene3d・rpg-starter__title）と完全に一致する場面を比べない
#
# 組む口: FLIX_GE_HIDDEN（framebuffer を design の大きさに固定）・FLIX_GE_FRAME_SHOT（swap の直前の絵を frame-N.png へ）・
# FLIX_GE_FIXED_DT（dt を固定。2 コマ目以降もバイトで比べられる）・FLIX_GE_MUTE・START（App.withStarts の場面から起動）。
# 撮る engine はゲームの lib の fpkg（engine の作業場では make sync-engine-full が配った物）。dt の固定を知らない古い fpkg で
# 撮ると 2 コマ目から揃わないので、起動のログに dt を固定した知らせの行が無ければ止める。
# 環境変数: FRAMES（撮るコマ数・既定 6）・DT（既定 1/60。off で固定しない＝実時間の dt。比べられるのは頭のコマだけになる）・
#           WAIT_SECONDS（jar を作った後の、1 場面の起動から撮り終えるまでの上限・既定 180）。
# 撮る間は、絵や時間を変えうる呼ぶ人の環境変数（下の reset_env）を外す。
#
# 出力: <出力>/<フォルダの名前>__<場面>（場面が空なら名前だけ）/frame-1.png … と <出力>/SHA256SUMS（行は「<SHA>  <名前>__<場面>/frame-N.png」）。
# START の字が空なら START を置かない（withStarts の無い物・bench/scene3d のように起動の場面が 1 つの物）。
# GL の絵は機械・ドライバで変わるので、比べるのは同じ機械で撮った 2 回どうし（基準の SHA を別の機械と比べない）。
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
skipped=""
sums_of() {
	local src
	if [ -d "$1" ]; then src="$1/SHA256SUMS"; else src="$1"; fi
	grep -v '^#' "$src" | awk -v skip="$skipped" 'BEGIN { n = split(skip, s, " "); for (i = 1; i <= n; i++) if (s[i] != "") drop[s[i]] = 1 }
		{ dir = $2; sub(/\/.*$/, "", dir); if (!(dir in drop)) print }'
}

if [ "${1:-}" = "--compare" ]; then
	if [ $# -lt 3 ]; then echo "usage: $0 --compare <A> <B> [--skip <フォルダ名> ...]" >&2; exit 2; fi
	a=$2 b=$3
	shift 3
	while [ $# -gt 0 ]; do
		if [ "$1" = --skip ] && [ $# -ge 2 ]; then skipped="$skipped$2 "; shift 2
		else echo "usage: $0 --compare <A> <B> [--skip <フォルダ名> ...]" >&2; exit 2; fi
	done
	[ -z "$skipped" ] || echo "[gl-capture] 比べない場面: $skipped"
	set -- --compare "$a" "$b"
	if diff -u <(sums_of "$2") <(sums_of "$3"); then
		echo "[gl-capture] 一致: $(sums_of "$2" | wc -l | tr -d ' ') 枚がバイトまで同じ"
		exit 0
	fi
	echo "[gl-capture] 違う絵がある（上の - が $2・+ が $3）" >&2
	exit 1
fi

if [ $# -lt 1 ]; then
	echo "usage: $0 <出力のフォルダ> [<フォルダ>:<START> ...] | --compare <A> <B>" >&2
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
if [ $# -gt 0 ]; then scenes=("$@"); else scenes=("${default_scenes[@]}"); fi

# 絵・時間・起動の道を変えうる環境変数。撮る時は外して、誰が撮っても同じ条件にする。
reset_env=(FLIX_GE_SPLASH_SHOT FLIX_GE_FRAME_STATS FLIX_GE_NO_SPLASH FLIX_GE_GLYPHS FLIX_GE_NO_FONT_CACHE
	FGE_SOFT_SERIAL DEBUG FLOW_RECORD HEADLESS_RESIDENT HEADLESS_JAVA_OPTS JAVA_TOOL_OPTIONS FLIX_GE_CACHE_DIR START)

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
	local n=$((frames + 1))
	while [ -e "$dir/frame-$n.png" ]; do rm -f "$dir/frame-$n.png"; n=$((n + 1)); done
}

captured=()
for scene in "${scenes[@]}"; do
	capture_one "${scene%%:*}" "${scene#*:}"
	start=${scene#*:}
	captured+=("$(basename "${scene%%:*}")${start:+__${start// /_}}")
done

# 今回撮った場面のフォルダだけを数える（同じ OUT に前の回の別の場面が残っていても混ぜない）。
(cd "$out" && for d in "${captured[@]}"; do ls "$d"/frame-*.png; done | sort -t/ -k1,1 -k2,2V | xargs shasum -a 256) > "$out/SHA256SUMS"
echo "[gl-capture] $(wc -l < "$out/SHA256SUMS" | tr -d ' ') 枚 → $out/SHA256SUMS"
