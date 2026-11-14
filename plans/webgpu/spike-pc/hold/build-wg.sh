#!/bin/bash
# spike/wgpu/*.java を lib/external/spike-wg.jar にする（../libs/ の jWebGPU に対して組む）。
H=$(cd "$(dirname "$0")" && pwd)
L=$H/../libs/jwebgpu
export PATH=/Users/abab/Desktop/flix_game_engine/.devbox/nix/profile/default/bin:$PATH
rm -rf $H/wgout && mkdir -p $H/wgout $H/lib/external
CP=$L/webgpu-jni-0.3.4.jar:$L/api-core-1.2.8.jar:$L/loader-core-1.2.8.jar:$L/runtime-jni-1.2.8.jar
javac -nowarn --release 21 -d $H/wgout -cp $CP $H/spike/wgpu/*.java && jar cf $H/lib/external/spike-wg.jar -C $H/wgout .
