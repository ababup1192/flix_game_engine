#!/bin/sh
# fpkg-store.sh — engine の束（fpkg と、それと組で読む toml・jar）を、中身のハッシュを名前に入れた不変の置き場
# （content-addressed store。npm / pnpm の store・Nix の store と同じ考え方）に置き、ゲームの lib から指させる。
#
#     bin/fpkg-store.sh put <名前> <版> <ファイル>...   置き場へ入れ、current/<名前> をそこへ向ける。エントリ（根からの相対）を出す
#     bin/fpkg-store.sh path <名前> [<ファイル名>]      current/<名前> の指すエントリの絶対パス（ファイル名を渡せばその中のファイル）。無ければ exit 1
#     bin/fpkg-store.sh link <パッケージ> <lib の中の行き先> <fpkg の名前> <toml の名前>
#                                                      パッケージの lib の束を current/engine_full のエントリへ張り替え、packages.lock の sha もそろえる
#     bin/fpkg-store.sh gc [--dry-run]                  どこからも指されていない古いエントリを消す
#     bin/fpkg-store.sh locked <コマンド>...            置き場の鍵を取ってコマンドを流す（make sync-engine-full・sync-engine-full-web・fpkg-store-gc）
#
# 置き場は <engine の根>/build/fpkg-store。エントリ 1 つは <名前>-<版>-<ハッシュ 16 字>/ のフォルダで、中のファイルは読むだけ（0444）。
# ハッシュは中のファイルの「名前・SHA-256」の一覧の SHA-256。同じ中身はいつも同じ名前になり、一度置いたエントリの中身は変わらない。
#
# 同時に読み書きしても壊れない根拠:
# - 置く側は .tmp-* のフォルダへ写してからハッシュを数え（写した物を数えるので、元を誰かが書き換えていても名前と中身が食い違わない）、
#   rename(2) で本来の名前へ移す。同じ名前が先に在れば rename は ENOTEMPTY で落ちるので、写した方を捨てる（中身は同じ）。
# - 元（artifact/package.fpkg・build の jar）を書くのは sync だけで、sync・put・gc は locked の鍵で 1 本ずつにする。
#   写す前に zip が最後まで読めるかも見るので、書きかけの束がエントリとして固まらない。
# - current/<名前> と lib の束の symlink は、一時の名前で張ってから rename で置き換える。読む側には古い先か新しい先のどちらかしか見えず、
#   「束が無い」瞬間が無い（ln -sfn は消してから張るので、その間に flix が見ると GitHub へ取りに行く）。
# - 作り直しは新しいエントリを足すだけで、古いエントリは消さない。build・export-web の途中の物は読み始めたエントリを最後まで読める。
# - 残る隙: link は fpkg・toml・packages.lock の順に 1 つずつ替えるので、その間に起きた templates の flix は lock の食い違いで 1 回落ちうる
#   （打ち直せば通る）。走っている flix が古い sha の lock を書き戻す道も、前の「lock を消す」形と同じく残る。
#
# 掃除の決まり（gc）: 消すのは、どこからも指されていないエントリのうち、名前ごとに新しい方から KEEP（既定 5）個より後ろで、
# 最後に置いてから FPKG_STORE_MIN_AGE_MIN（既定 1440 = 1 日）分より経った物だけ。指しているかは current/* と、
# この engine の templates/*・bench/* の lib の symlink で見る。ゲーム（~/Documents など）の lib は写しなので数えない。
#
# WhyNot: ゲームの lib の束をここへの symlink にしない（templates と bench だけが symlink）— ゲームは engine の外にあり、
# engine の掃除や worktree の片付けで先が消えると、そのゲームが黙って組めなくなる（use-engine の写しと同じ理由）。
# ゲームは engine-upgrade がエントリの中身を写し、ハッシュで入れ替えるかを決める。
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
store="$root/build/fpkg-store"
lockdir="$root/build/.fpkg-store.lock"
KEEP=${FPKG_STORE_KEEP:-5}
MIN_AGE_MIN=${FPKG_STORE_MIN_AGE_MIN:-1440}

usage() {
	sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

sha_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi | awk '{ print $1 }'
}

# WhyNot: mv を使わない — 行き先がフォルダだとその中へ入れてしまう。
rename_to() {
	perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

swap_link() {
	tmp="$(dirname "$2")/.$(basename "$2").tmp.$$"
	rm -f "$tmp"
	ln -s "$1" "$tmp" && rename_to "$tmp" "$2"
}

# エントリの名前から <名前> を取る（<名前>-<版>-<ハッシュ 16 字>）。
entry_name() {
	printf '%s' "$1" | sed -E 's/-[^-]+-[0-9a-f]{16}$//'
}

# WhyNot: 置き場が symlink（worktree-seed の古い形や手で張った物）なら、先へ書かずに自分の実体へ置き換える —
# 先は main の作業ツリーの build で、そこで export-web や build をしている人の束を書き換えることになる。
own_store() {
	if [ -L "$store" ]; then
		from=$(cd "$store" && pwd -P)
		rm -f "$store"
		mkdir -p "$store"
		[ -d "$from" ] && { /bin/cp -cR "$from/." "$store/" 2>/dev/null || /bin/cp -R "$from/." "$store/"; }
		echo "[fpkg-store] 置き場が $from への symlink だったので、自分の実体に置き換えました" >&2
	fi
	mkdir -p "$store/current"
}

# WhyNot: 鍵は mkdir — flock は macOS に無い。落ちたプロセスの鍵は中の pid が生きていなければ取り直す。
cmd_locked() {
	[ $# -ge 1 ] || usage
	mkdir -p "$root/build"
	waited=0
	while ! mkdir "$lockdir" 2>/dev/null; do
		pid=$(cat "$lockdir/pid" 2>/dev/null || true)
		# pid が空なのは mkdir の直後か、pid を書く前に落ちた鍵。後者だけを、フォルダが 1 分より古いことで見分ける。
		stale=
		if [ -n "$pid" ]; then
			kill -0 "$pid" 2>/dev/null || stale=1
		elif [ -n "$(find "$lockdir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
			stale=1
		fi
		# WhyNot: 古い鍵を rm で消さず rename で退ける — 待っている 2 本が同時に消すと、後の rm が先の 1 本の取り直した鍵まで消し、2 本とも鍵を持つ。
		if [ -n "$stale" ] && rename_to "$lockdir" "$lockdir.stale.$$" 2>/dev/null; then
			rm -rf "$lockdir.stale.$$"
			continue
		fi
		[ "$waited" -eq 0 ] && echo "[fpkg-store] 別の sync（pid ${pid:-?}）が置き場を使っています。終わるまで待ちます" >&2
		waited=$((waited + 1))
		sleep 2
	done
	echo $$ > "$lockdir/pid"
	trap 'rm -rf "$lockdir"' EXIT INT TERM HUP
	"$@"
	code=$?
	rm -rf "$lockdir"
	trap - EXIT INT TERM HUP
	return $code
}

cmd_put() {
	[ $# -ge 3 ] || usage
	name=$1
	ver=$2
	shift 2
	own_store
	tmp=$(mktemp -d "$store/.tmp-$name.XXXXXX") || exit 1
	for f in "$@"; do
		[ -f "$f" ] || { echo "error: $f がありません" >&2; rm -rf "$tmp"; exit 1; }
		cp "$f" "$tmp/" || { rm -rf "$tmp"; exit 1; }
	done
	if command -v unzip >/dev/null 2>&1; then
		for f in "$tmp"/*.fpkg "$tmp"/*.jar; do
			[ -f "$f" ] || continue
			unzip -tq "$f" >/dev/null 2>&1 || { echo "error: $(basename "$f") が zip として最後まで読めません（書きかけ）。置き場へ入れません" >&2; rm -rf "$tmp"; exit 1; }
		done
	fi
	digest=$(cd "$tmp" && for f in *; do printf '%s %s\n' "$f" "$(sha_of "$f")"; done | LC_ALL=C sort | sha_of - | cut -c1-16)
	entry="$name-$ver-$digest"
	chmod 0444 "$tmp"/*
	chmod 0755 "$tmp"
	if [ -d "$store/$entry" ]; then
		rm -rf "$tmp"
		touch "$store/$entry"
	elif ! rename_to "$tmp" "$store/$entry"; then
		rm -rf "$tmp"
		[ -d "$store/$entry" ] || { echo "error: $store/$entry へ移せません" >&2; exit 1; }
	fi
	swap_link "../$entry" "$store/current/$name" || exit 1
	echo "build/fpkg-store/$entry"
}

cmd_path() {
	[ $# -ge 1 ] || usage
	cur="$store/current/$1"
	[ -L "$cur" ] && [ -d "$cur" ] || exit 1
	dir=$(cd "$cur" && pwd -P) || exit 1
	if [ $# -ge 2 ]; then
		[ -f "$dir/$2" ] || exit 1
		echo "$dir/$2"
	else
		echo "$dir"
	fi
}

ups() {
	printf '%s' "$1" | awk -F/ '{ n = 0; for (i = 1; i <= NF; i++) if ($i != "" && $i != ".") n++; s = ""; for (i = 0; i < n; i++) s = s "../"; printf "%s", s }'
}

# WhyNot: 節が無ければ足さない — flix が版を解決する時に自分で足す。
align_lock() {
	[ -f "$1" ] || return 0
	tmp="$1.tmp.$$"
	awk -v head="[packages.\"github:ababup1192/flix_game_engine\".\"$2\"]" -v tsum="$3" -v fsum="$4" '
		/^[[:space:]]*\[/ { t = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); inside = (t == head) }
		inside && /^[[:space:]]*toml[[:space:]]*=/ { sub(/"sha256:[0-9a-f]*"/, "\"sha256:" tsum "\"") }
		inside && /^[[:space:]]*fpkg[[:space:]]*=/ { sub(/"sha256:[0-9a-f]*"/, "\"sha256:" fsum "\"") }
		{ print }' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
	if cmp -s "$1" "$tmp"; then rm -f "$tmp"; else rename_to "$tmp" "$1"; fi
}

cmd_link() {
	[ $# -eq 4 ] || usage
	pkg=${1%/}
	dest=${2%/}
	fpkg_name=$3
	toml_name=$4
	own_store
	entry=$(cmd_path engine_full) || { echo "error: 置き場に engine_full がありません。先に make sync-engine-full" >&2; exit 1; }
	case "$entry" in "$store"/*) ;; *) echo "error: $entry が $store の外です" >&2; exit 1 ;; esac
	[ -f "$entry/package.fpkg" ] && [ -f "$entry/flix.toml" ] || { echo "error: $entry に package.fpkg か flix.toml がありません" >&2; exit 1; }
	pkg_abs=$(cd "$root/$pkg" && pwd -P) || exit 1
	case "$pkg_abs" in "$root"/*) ;; *) echo "error: $pkg はこの engine の外です（lib の symlink は engine の中のパッケージだけ）" >&2; exit 1 ;; esac
	rel_pkg=${pkg_abs#"$root"/}
	mkdir -p "$pkg_abs/$dest"
	up=$(ups "$rel_pkg/$dest")
	rel_entry=${entry#"$root"/}
	swap_link "$up$rel_entry/package.fpkg" "$pkg_abs/$dest/$fpkg_name" || exit 1
	swap_link "$up$rel_entry/flix.toml" "$pkg_abs/$dest/$toml_name" || exit 1
	align_lock "$pkg_abs/packages.lock" "$(basename "$dest")" "$(sha_of "$entry/flix.toml")" "$(sha_of "$entry/package.fpkg")"
}

referenced() {
	for l in "$store"/current/*; do
		[ -L "$l" ] && basename "$(readlink "$l")"
	done
	for d in "$root"/templates/*/lib/github/ababup1192/flix_game_engine "$root"/bench/*/lib/github/ababup1192/flix_game_engine; do
		[ -d "$d" ] || continue
		find "$d" -type l 2>/dev/null | while read -r l; do
			t=$(readlink "$l")
			case "$t" in *build/fpkg-store/*) printf '%s\n' "$t" | sed 's|.*build/fpkg-store/||; s|/.*||' ;; esac
		done
	done
}

cmd_gc() {
	dry=
	[ "${1:-}" = --dry-run ] && dry=1
	[ -d "$store" ] && [ ! -L "$store" ] || return 0
	refs=$(referenced | sort -u)
	find "$store" -maxdepth 1 -name '.tmp-*' -type d -mmin +"$MIN_AGE_MIN" -exec rm -rf {} + 2>/dev/null
	removed=0
	kept=0
	for name in $(cd "$store" && ls -1d */ 2>/dev/null | sed 's|/$||' | grep -v '^current$' | while read -r e; do entry_name "$e"; echo; done | sort -u); do
		rank=0
		# mtime は置いた時刻か、同じ中身をもう一度置いた時刻（put が touch する）。
		for e in $(cd "$store" && ls -1td "$name"-*/ 2>/dev/null | sed 's|/$||'); do
			case "$e" in "$name"-*-????????????????) ;; *) continue ;; esac
			# WhyNot: 頭が同じ別の名前（engine_full と engine_full_web）を混ぜない。
			[ "$(entry_name "$e")" = "$name" ] || continue
			rank=$((rank + 1))
			if printf '%s\n' "$refs" | grep -qx "$e"; then kept=$((kept + 1)); continue; fi
			if [ "$rank" -le "$KEEP" ]; then kept=$((kept + 1)); continue; fi
			if [ -z "$(find "$store/$e" -maxdepth 0 -mmin +"$MIN_AGE_MIN" 2>/dev/null)" ]; then kept=$((kept + 1)); continue; fi
			if [ -n "$dry" ]; then
				echo "消す（--dry-run）  $e"
			else
				chmod -R u+w "$store/$e" 2>/dev/null
				rm -rf "$store/$e"
			fi
			removed=$((removed + 1))
		done
	done
	echo "[fpkg-store] 残した ${kept} 個・消した ${removed} 個（${store}）"
}

sub=${1:-}
[ -n "$sub" ] || usage
shift
case "$sub" in
	put) cmd_put "$@" ;;
	path) cmd_path "$@" ;;
	link) cmd_link "$@" ;;
	gc) cmd_gc "$@" ;;
	locked) cmd_locked "$@" ;;
	*) usage ;;
esac
