#!/bin/bash
# usage: build.sh <teavm version> <MainClass> <outdir> [src files...]
set -e
V=$1; MAIN=$2; OUT=$3; shift 3
W=$(cd "$(dirname "$0")" && pwd)
JARS=$(ls $W/jars-$V/*.jar | tr '\n' ':')
rm -rf $W/classes-$V-$MAIN $OUT; mkdir -p $W/classes-$V-$MAIN $OUT
javac --release 17 -encoding UTF-8 -cp "$JARS" -d $W/classes-$V-$MAIN "$@"
javac --release 17 -cp "$JARS" -d $W/classes-$V-$MAIN $W/tools/Build.java
java -Xmx2g -cp "$W/classes-$V-$MAIN:$JARS" Build $MAIN $OUT
unzip -p $W/jars-$V/teavm-core-$V.jar org/teavm/backend/wasm/wasm-gc-runtime.js > $OUT/wasm-gc-runtime.js
ls -l $OUT
