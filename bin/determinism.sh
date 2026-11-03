#!/usr/bin/env bash
# determinism.sh — 決定性の門（make determinism）: 実機の道で遊んだ記録が、画面なしの再生で同じ World になるか。
#
#   bin/determinism.sh [<フォルダ>:<台本> ...]   場面を省くと下の既定（テンプレ 3 本）
#
# 1 本ごとに:
#   (a) 記録: 隠しウィンドウ（FLIX_GE_HIDDEN）の DEBUG の起動に、台本（FLIX_GE_INPUT_SCRIPT。実機のキー・マウスの代わり）を流す。
#       dt は実時間のまま（FLIX_GE_FIXED_DT を付けない）。App が記録（FLOW_RECORD）に 60 コマごとの指紋と、閉じる時の
#       最後の指紋と World 全体の要約（expect world=）を書き、台本を流し終えた周で自分で閉じる。
#   (b) 再生: その記録を画面なしで流す（make flow と同じ E2e.play）。記録の expect が全部立てば、実機のループが
#       記録に無い形で World を変えていない（記録し忘れた読み直し・request・F8・固定刻みの持ち越し・窓の閉じる要求）。
#       再生は下の replays の行ごとに別の JVM で流し、どれも通ることと、最後の行（指紋）が同じことを見る。
#
# この門が拾わない物: 記録に残るのは frameOf を通した後の Frame なので、frameOf や押した瞬間の検出の誤りは記録にも再生にも
# 同じに入る（App の純粋な関数のテストの仕事）。GLFW のキーの読み替えも通らない（LwjglInput のテストの仕事）。
# 窓を開くので CI には載せない。リリースの全量のゲートで回す（先に make sync-engine-full）。
#
# 出力: build/determinism/<フォルダの名前>/record.flow（記録）・run.log（記録の起動）・replay-<名前>.log（再生）。
# WhyNot: game-starter を既定に入れない — テンプレの src に make new-game が埋める字（__WW__ など）が残っていて、その場では組めない。
# WhyNot: リポジトリの外のゲーム（night_apartment など）を既定に入れない — その場の lib は自分の版の engine。引数で渡せば流せる。
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
wait_seconds=${WAIT_SECONDS:-300}

default_targets=(
	"templates/rpg-starter:testdata/determinism/rpg-starter.flow"
	"templates/sound-novel-starter:testdata/determinism/sound-novel-starter.flow"
	"templates/tidepool-starter:testdata/determinism/tidepool-starter.flow"
)

# 再生の仕方（名前|java へ足す旗）。どの行でも記録の expect が全部立ち、最後の指紋の行が同じこと。
# 並列の度合いを変えた行は、Par（C10a）が入った後にここへ 1 行足す: "one-cpu|-XX:ActiveProcessorCount=1"
replays=(
	"default|"
)

# 絵・時間・起動の道を変えうる呼ぶ人の環境変数。記録と再生では外して、誰が流しても同じ条件にする。
reset_env=(FLIX_GE_SPLASH_SHOT FLIX_GE_FRAME_STATS FLIX_GE_FRAME_SHOT FLIX_GE_FIXED_DT FLIX_GE_GLYPHS FLIX_GE_NO_FONT_CACHE
	FGE_SOFT_SERIAL HEADLESS_RESIDENT HEADLESS_JAVA_OPTS JAVA_TOOL_OPTIONS FLIX_GE_CACHE_DIR START DEBUG_HTTP_PORT FLOW FLOW_MODE)

if [ $# -gt 0 ]; then targets=("$@"); else targets=("${default_targets[@]}"); fi
"$engine/bin/check-fpkg-fresh.sh"

# 起動の時に読むセーブ（saves/）は App を組む外の値で、画面なしの再生（E2e）は空のセーブで組む。記録と再生の間だけ外し、終わったら戻す。
# WhyNot: セーブを World 全体の要約から外さない — 遊ぶ間に書く進行の値なので、外すと台本が書いたセーブの食い違いを拾えない。
saves_aside=()
restore_saves() {
	local entry dir aside
	for entry in "${saves_aside[@]+"${saves_aside[@]}"}"; do
		dir=${entry%%|*}
		aside=${entry#*|}
		rm -rf "${dir:?}"
		mv "$aside" "$dir"
	done
	saves_aside=()
}
trap restore_saves EXIT

failed=()
check_one() {
	local game=$1 script=$2
	local name out
	name=$(basename "$game")
	out="$engine/build/determinism/$name"
	# WhyNot: 前の回が強く止められて外したセーブが残っている時に消して進まない — 中身は本物のセーブ。
	if [ -d "$out/saves-aside" ]; then
		echo "[determinism] ${game}: 前の回で外したセーブが $out/saves-aside に残っている。$game/saves へ戻してから流し直す" >&2
		return 1
	fi
	rm -rf "$out"
	mkdir -p "$out"
	case "$script" in /*) ;; *) script="$engine/$script" ;; esac
	if [ -d "$engine/$game/saves" ]; then
		mv "$engine/$game/saves" "$out/saves-aside"
		mkdir -p "$engine/$game/saves"
		if [ -e "$out/saves-aside/.gitkeep" ]; then cp "$out/saves-aside/.gitkeep" "$engine/$game/saves/"; fi
		saves_aside+=("$engine/$game/saves|$out/saves-aside")
	fi
	echo "[determinism] ${game} ← ${script#"$engine"/}"
	(
		cd "$engine/$game" || exit 1
		unset "${reset_env[@]}"
		export FLIX_CMD="$engine/bin/flix"
		"$engine/bin/headless-run" --build-only > "$out/build.log" 2>&1 || exit 1
		# WhyNot: 閉じるのを待つ上限を置く — 台本を読めない・ループが閉じない時に、門が窓を残したまま固まらない。
		DEBUG=1 FLIX_GE_HIDDEN=1 FLIX_GE_MUTE=1 FLIX_GE_INPUT_SCRIPT="$script" FLOW_RECORD="$out/record.flow" \
		perl -e '
			my $limit = shift;
			my $pid = fork;
			if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec: $!" }
			$SIG{INT} = $SIG{TERM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; exit 130 };
			local $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; exit 4 };
			alarm $limit;
			waitpid($pid, 0);
			exit($? >> 8);
		' "$wait_seconds" "$engine/bin/headless-run" --window main > "$out/run.log" 2>&1
	) || { echo "[determinism] ${game}: 記録の起動が終わらなかった・落ちた（$out/build.log と run.log）" >&2; tail -20 "$out/run.log" >&2 || true; return 1; }
	if grep -q '^# world 全体の要約を取れなかった' "$out/record.flow" 2>/dev/null; then
		echo "[determinism] ${game}: 閉じる時に World 全体の要約を取れなかった（$(grep '^# world 全体の要約を取れなかった' "$out/record.flow")）" >&2
		return 1
	fi
	if ! grep -q '^expect world=' "$out/record.flow" 2>/dev/null; then
		echo "[determinism] ${game}: 記録に expect world= が無い（台本を流し終えて閉じていない。$out/run.log）" >&2
		tail -20 "$out/run.log" >&2 || true
		return 1
	fi
	# 台本の手が実機の入力として届いたか（届かなければ記録は何も押していない wait だけになり、それも再生と一致してしまう）。
	if ! grep -Eq '^(tap|hold|release) ' "$out/record.flow" || ! grep -q 'focus=0' "$out/record.flow"; then
		echo "[determinism] ${game}: 記録に台本の手（tap・hold・release と focus=0）が無い（台本が実機の入力の代わりになっていない）" >&2
		return 1
	fi
	local first="" line entry label opts
	for entry in "${replays[@]}"; do
		label=${entry%%|*}
		opts=${entry#*|}
		if ! (cd "$engine/$game" && unset "${reset_env[@]}" && FLIX_CMD="$engine/bin/flix" HEADLESS_JAVA_OPTS="$opts" \
				FLOW="$out/record.flow" FLOW_MODE=run "$engine/bin/headless-run" E2e.play) > "$out/replay-$label.log" 2>&1; then
			echo "[determinism] ${game}: 再生（${label}）が記録と食い違った（$out/replay-$label.log）" >&2
			grep -A3 '^FAIL' "$out/replay-$label.log" >&2 || tail -20 "$out/replay-$label.log" >&2
			return 1
		fi
		line=$(grep '^ok ' "$out/replay-$label.log" | tail -1)
		if [ -z "$first" ]; then first=$line
		elif [ "$line" != "$first" ]; then
			echo "[determinism] ${game}: 再生（${label}）の終わりが前の再生と違う: ${line} / ${first}" >&2
			return 1
		fi
	done
	restore_saves
	echo "[determinism] ok ${game}: $(grep -c '^expect ' "$out/record.flow") 個の expect が ${#replays[@]} 通りの再生で立った（$(grep '^expect world=' "$out/record.flow")）"
}

for target in "${targets[@]}"; do
	check_one "${target%%:*}" "${target#*:}" || failed+=("${target%%:*}")
done
if [ ${#failed[@]} -gt 0 ]; then
	echo "[determinism] 食い違った: ${failed[*]}" >&2
	exit 1
fi
echo "[determinism] 全部一致（${#targets[@]} 本）"
