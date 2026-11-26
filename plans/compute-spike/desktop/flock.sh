#!/bin/bash
# デスクトップの compute スパイク（jWebGPU 0.3.4・Dawn）。jar は render_gl が使う共有の Maven の置き場から読む（取りに行かない）。
# usage: [MAIN=FlockBench] plans/compute-spike/desktop/flock.sh
set -e
D=$(cd "$(dirname "$0")" && pwd)
export PATH="${DEVBOX_BIN:-$(cd "$(dirname "$0")/../../.." && pwd)/.devbox/nix/profile/default/bin}:$PATH"
ORG=com/$(printf 'g%sthub' i)/xpenatan
M=${MVN_CACHE:-$HOME/Library/Caches/flix_game_engine/mvn-cache}/https/repo1.maven.org/maven2/$ORG
CP=""
for j in jWebGPU/webgpu-jni/0.3.4/webgpu-jni-0.3.4.jar \
         jWebGPU/webgpu-desktop-jni/0.3.4/webgpu-desktop-jni-0.3.4.jar \
         jWebGPU/webgpu-desktop-jni-dawn_mac_arm64/0.3.4/webgpu-desktop-jni-dawn_mac_arm64-0.3.4.jar \
         jParser/api-core/1.2.8/api-core-1.2.8.jar jParser/loader-core/1.2.8/loader-core-1.2.8.jar \
         jParser/runtime-jni/1.2.8/runtime-jni-1.2.8.jar jParser/runtime-desktop-jni_mac_arm64/1.2.8/runtime-desktop-jni_mac_arm64-1.2.8.jar; do
  [ -f "$M/$j" ] || { echo "missing $M/$j (render_gl を一度組むと置き場に入る)"; exit 1; }
  CP="$CP$M/$j:"
done
mkdir -p "$D/out"
javac -nowarn -d "$D/out" -cp "$CP" "$D"/src/*.java
exec java --enable-native-access=ALL-UNNAMED -Dspike.nativeDir="$D/out/natives" -cp "$D/out:$CP" "${MAIN:-ComputeSpike}" "$@"
