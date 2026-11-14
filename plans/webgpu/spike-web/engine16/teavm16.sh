#!/bin/bash
# usage: teavm16.sh <system|nojdk> <input.jar> <outdir> [extra classpath jars before the input...]
# Runs the same step ③ as bin/fge export-web, but with TeaVM 0.16.0 through TeaVMTool (0.16 has no teavm-cli).
set -e
MODE=$1; IN=$2; OUT=$3; shift 3
W=$(cd "$(dirname "$0")/.." && pwd)
ENG=$(cd "$W/../../.." && pwd)
V=${TEAVM_V:-0.16.0}
JARS=$(ls $W/jars-$V/*.jar | tr '\n' ':')
TOOLS=$ENG/build/web-jar/fge-web-tools-$(sed -n "s/^VERSION := //p" $ENG/Makefile).jar
[ -n "$NOTOOLS" ] && TOOLS=$NOTOOLS
EXTRA=$(IFS=:; echo "$*")
mkdir -p $W/classes-buildengine-$V
javac --release 17 -cp "$JARS" -d $W/classes-buildengine-$V $W/tools/BuildEngine.java
rm -rf $OUT; mkdir -p $OUT
java -Xmx6g ${JOPTS} -cp "$W/classes-buildengine-$V:${EXTRA:+$EXTRA:}$TOOLS:$JARS$IN" BuildEngine $MODE Main $OUT
