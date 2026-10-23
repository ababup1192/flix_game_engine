#!/usr/bin/env bash
# {{.Game}} を起動する（{{.OSLabel}}）。どこから呼んでもよい。
#
# 書く物（saves/・debug/・logs/）は解いた場所でなく {{.DataLabel}} に置く。
# 解いた場所は読むだけ（assets/・project.json は symlink で見せる）。
#
# 環境変数:
{{- if .Linux}}
#   FGE_WAYLAND=1     Wayland でウィンドウを開く（既定は X11。DISPLAY が無い時だけ Wayland に任せる）
{{- end}}
#   FGE_JAVA_OPTS     java へ足す旗（既定の旗の後ろに付くので上書きできる。例: -Xmx2g）
#   FGE_DATA_DIR      書く物の置き場を替える
#   FGE_ENTRY         流す入口（既定 main = 遊ぶ。描き出しの入口を渡すとウィンドウなしで確かめられる）
set -eu

here=$(cd "$(dirname "$(readlink -f "$0")")/{{.ToRoot}}" && pwd)
game={{.Game}}
data="${FGE_DATA_DIR:-{{.DataDefault}}}"
cache="{{.CacheDefault}}"
mkdir -p "$data/logs" "$cache/lwjgl"
data=$(cd "$data" && pwd)

log="$data/logs/run.log"
[ -f "$log" ] && mv -f "$log" "$data/logs/run.prev.log"
if [ -t 1 ]; then
    exec > >(tee "$log") 2>&1
else
    exec >"$log" 2>&1
fi
echo "[run] $(date '+%F %T') game=$here data=$data"

# ゲームは作業場からの相対で読み書きする（assets/・project.json・saves/）。
# WhyNot: 解いた場所へ cd しない — 読むだけの場所（Steam の取り込み先・macOS の隔離された .app）に置かれると saves/ を作れない。
for f in "$here"/game/*; do
    name=$(basename "$f")
    [ "$name" = game.jar ] && continue
    # WhyNot: symlink でない物を残して続けない — 古い assets のまま何も言わずに動くと、版を上げても直らない。
    if [ -e "$data/$name" ] && [ ! -L "$data/$name" ]; then
        echo "[run] $data/$name が symlink ではありません。古い写しなら消してから起動し直してください" >&2
        exit 1
    fi
    ln -sfn "$f" "$data/$name"
done
cd "$data"
{{- if .Linux}}

# WhyNot: GLFW に X11 か Wayland かを任せない — Gamescope（ゲームモード）は Xwayland でウィンドウを受け、
# Wayland のウィンドウは飾り（libdecor）の有無で出方が変わる。X11 にそろえて両方のモードで同じに出す。
if [ "${FGE_WAYLAND:-}" != 1 ] && [ -n "${DISPLAY:-}" ]; then
    unset WAYLAND_DISPLAY
fi
{{- end}}

export FGE_ENTRY="${FGE_ENTRY:-main}"
# WhyNot: LWJGL の native を一時置き場へ解かせない — /tmp を noexec で載せる Linux があり、そこでは dlopen が落ちる。
# shellcheck disable=SC2086
exec "$here/jre/bin/java" {{.JavaFlags}}-Xss32m -XX:MaxRAMPercentage=50 \
    -Dorg.lwjgl.system.SharedLibraryExtractPath="$cache/lwjgl" \
    ${FGE_JAVA_OPTS:-} -jar "$here/game/game.jar"
