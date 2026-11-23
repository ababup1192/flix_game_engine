# java-resolve.sh — bin/flix と bin/headless-run が java と flix.jar の devbox を決める時に読む（. で読み込む）。
#
#   fge_resolve_java <engine のルート>   FGE_JAVA（java のパス）と FGE_JAVA_VERSION_OUT（java -version の出力）を決める
#   fge_devbox_bins <engine のルート>    devbox の profile の bin を、使う順に 1 行ずつ出す
#   fge_is_bundle <engine のルート>      配った engine（go/ が無い）か
#
# 順は JAVA → PATH の java → engine の .devbox の jdk → main の checkout の .devbox の jdk。どれも java -version が通る物だけ。
# 配った engine（go/ が無く mk/jdk.mk がある）では JAVA → ${FGE_HOME:-~/.flix_ge}/jdk/<配り元>-<版>/bin/java だけ。
# どちらも無ければ止めて「fge engines install <版>」を出し、返り値は 2。
# Go の側（go/internal/javacmd）も同じ順。片方を直したらもう片方も直す。
#
# WhyNot: 在るかどうか（command -v）で決めない。macOS には /usr/bin/java という「Java を入れてください」と言うだけの
# 入口が必ず在り、devbox の外（Studio の .app・素のターミナル・devbox の無い worktree）ではそれを掴んで止まる。
# WhyNot: main の checkout の .devbox は devbox.json が同じ時だけ借りる。.devbox は checkout ごとの生成物で worktree には無いが、
# jdk の版を替えた枝で前の版の jdk を使うと、フォントの計測がずれて描き出しのスナップショットが崩れる。

# fge_main_checkout は engine が git の worktree の時、main の checkout のルートを出す（git を起こさず .git と commondir を読む）。
fge_main_checkout() {
    [ -f "$1/.git" ] || return 0
    _fge_gitdir=$(sed -n 's/^gitdir: *//p' "$1/.git")
    case "$_fge_gitdir" in /*) ;; *) _fge_gitdir="$1/$_fge_gitdir" ;; esac
    [ -f "$_fge_gitdir/commondir" ] || return 0
    _fge_common=$(cat "$_fge_gitdir/commondir")
    case "$_fge_common" in /*) ;; *) _fge_common="$_fge_gitdir/$_fge_common" ;; esac
    (cd "$_fge_common/.." 2>/dev/null && pwd)
}

fge_devbox_bins() {
    echo "$1/.devbox/nix/profile/default/bin"
    _fge_main=$(fge_main_checkout "$1")
    if [ -n "$_fge_main" ] && [ "$_fge_main" != "$1" ] && cmp -s "$1/devbox.json" "$_fge_main/devbox.json"; then
        echo "$_fge_main/.devbox/nix/profile/default/bin"
    fi
}

# _fge_try_java は java -version が通れば FGE_JAVA と FGE_JAVA_VERSION_OUT を決める。
_fge_try_java() {
    [ -n "$1" ] || return 1
    _fge_out="$("$1" -version 2>&1)" || return 1
    FGE_JAVA=$1
    FGE_JAVA_VERSION_OUT=$_fge_out
}

fge_is_bundle() {
    [ -f "$1/Makefile" ] && [ ! -d "$1/go" ]
}

# _fge_mk_value <ファイル> <名前> は make の `名前 := 値` の値を出す。
_fge_mk_value() {
    sed -n "s/^[[:space:]]*$2[[:space:]]*[:?]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$1" | head -n 1
}

# WhyNot: 配った engine で JDK が無い時に PATH の java へ移らない — 何も言わずに別の JDK で描くと、
# フォントの計測がずれて絵が変わる。その原因に気づく手がかりも残らない。
_fge_resolve_bundle_java() {
    _fge_try_java "${JAVA:-}" && return 0
    _fge_vendor=$(_fge_mk_value "$1/mk/jdk.mk" FGE_JDK_VENDOR)
    _fge_jver=$(_fge_mk_value "$1/mk/jdk.mk" FGE_JDK_VERSION)
    _fge_ever=$(_fge_mk_value "$1/Makefile" VERSION)
    _fge_jdk="${FGE_HOME:-$HOME/.flix_ge}/jdk/$_fge_vendor-$_fge_jver/bin/java"
    _fge_try_java "$_fge_jdk" && return 0
    {
        echo "engine ${_fge_ever:-?} が使う JDK（$_fge_vendor-$_fge_jver）が手元にありません: $_fge_jdk"
        echo "  次: fge engines install ${_fge_ever:-<版>}（JAVA=<java のパス> で名指しもできる）"
    } >&2
    return 2
}

fge_resolve_java() {
    if fge_is_bundle "$1" && [ -f "$1/mk/jdk.mk" ]; then
        _fge_resolve_bundle_java "$1"
        return
    fi
    _fge_try_java "${JAVA:-}" && return 0
    _fge_try_java java && return 0
    while IFS= read -r _fge_bin; do
        _fge_try_java "$_fge_bin/java" && return 0
    done <<FGE_BINS
$(fge_devbox_bins "$1")
FGE_BINS
    return 1
}
