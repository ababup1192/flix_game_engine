#!/bin/bash
# usage: build.sh  — Flix → fatjar → engine's Rewrite → TeaVM 0.16 (wasm-gc) → site/
set -e
P=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$P/.." && pwd)
ENG=$(cd "$W/../../.." && pwd)
V=0.16.0
FLIX_JAR=${FLIX_JAR:-/nix/store/l5v7yg7ydxfaw3kl4wj6lmhx80zqxy3l-flix-0.78.0/share/java/flix/flix.jar}
EV=$(sed -n "s/^VERSION := //p" $ENG/Makefile)
mkdir -p $P/lib/external $P/classes $P/work
for j in jso jso-apis interop; do cp $W/jars-$V/teavm-$j-$V.jar $P/lib/external/; done
rm -rf $P/classes/*
javac --release 17 -encoding UTF-8 -cp "$W/jars-$V/teavm-jso-$V.jar:$W/jars-$V/teavm-jso-apis-$V.jar:$W/jars-$V/teavm-interop-$V.jar" -d $P/classes $(find $P/java -name '*.java')
jar --create --file $P/lib/external/wgpu-probe.jar -C $P/classes .
(cd $P && java -Xss64m -jar $FLIX_JAR build-fatjar) > $P/work/fatjar.log 2>&1 || { tail -40 $P/work/fatjar.log; exit 1; }
FAT=$(ls $P/artifact/*.jar | head -1)
java -cp "$W/jars-0.14.1/teavm-relocated-libs-asm-0.14.1.jar:$ENG/build/web-jar/fge-web-tools-$EV.jar" fge.teavmfix.Rewrite $FAT $P/work/rewritten.jar
bash $W/engine16/teavm16.sh ${MODE:-system} $P/work/rewritten.jar $P/site "$P/lib/external/wgpu-probe.jar" > $P/work/teavm.log 2>&1 || { tail -30 $P/work/teavm.log; exit 1; }
tail -4 $P/work/teavm.log
unzip -p $W/jars-$V/teavm-core-$V.jar org/teavm/backend/wasm/wasm-gc-runtime.js > $P/site/wasm-gc-runtime.js
cp $W/fi-site/index.html $P/site/index.html
ls -l $P/site
