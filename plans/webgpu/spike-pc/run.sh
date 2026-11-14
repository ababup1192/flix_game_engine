#!/bin/bash
# usage: run.sh <MainClass> [jvm opts via JOPTS] args...
D=/private/tmp/claude-501/-Users-abab--claude-spares-spare-q72Ibn/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/webgpu-spike/pc
BACK=${BACK:-wgpu}
CP=$D/out:$(ls $D/libs/jwebgpu/*.jar | grep -v -E "dawn|wgpu_mac|webgpu-core" | tr '\n' ':')$D/libs/jwebgpu/webgpu-desktop-jni-$BACK\_mac_arm64-0.3.4.jar:$(ls $D/libs/lwjgl/*.jar | tr '\n' ':')
rm -rf "${TMPDIR:-/tmp}/jParser$USER"
cd /Users/abab/Desktop/flix_game_engine && devbox run -- java $JOPTS --enable-native-access=ALL-UNNAMED -Djwebgpu.backend=$BACK -cp "$CP" "$@"
