#!/bin/bash
# usage: [BACK=dawn|wgpu] [JOPTS=...] [NATIVE_DIR=<dir>] [CLEAN_JPARSER=1] run.sh <MainClass> args...
# NATIVE_DIR を渡すと、jWebGPU がネイティブを開く場所をその下に分ける（Gpu.init が java.io.tmpdir を一時的に差し替える）。
D=$(cd "$(dirname "$0")" && pwd)
"$D/guard.sh"
export PATH=/Users/abab/Desktop/flix_game_engine/.devbox/nix/profile/default/bin:$PATH
BACK=${BACK:-dawn}
CP=$D/out:$(ls $D/libs/jwebgpu/*.jar | grep -v -E "dawn|wgpu_mac|webgpu-core" | tr '\n' ':')$D/libs/jwebgpu/webgpu-desktop-jni-$BACK\_mac_arm64-0.3.4.jar:$(ls $D/libs/lwjgl/*.jar | tr '\n' ':')
[ -n "$CLEAN_JPARSER" ] && rm -rf "${TMPDIR:-/tmp}/jParser$USER"
EXTRA=""
[ -n "$NATIVE_DIR" ] && EXTRA="-Dspike.nativeDir=$NATIVE_DIR"
exec java $JOPTS $EXTRA --enable-native-access=ALL-UNNAMED -Djwebgpu.backend=$BACK -cp "$CP" "$@"
