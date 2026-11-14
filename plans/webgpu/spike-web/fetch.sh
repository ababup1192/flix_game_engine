#!/bin/bash
arts="classlib cli core interop jso jso-apis jso-impl metaprogramming-api metaprogramming-impl platform tooling relocated-libs-asm relocated-libs-asm-analysis relocated-libs-asm-commons relocated-libs-asm-tree relocated-libs-asm-util relocated-libs-commons-cli relocated-libs-commons-io relocated-libs-hppc relocated-libs-rhino"
for v in 0.14.1 0.16.0; do mkdir -p jars-$v; for a in $arts; do curl -fsSL -o jars-$v/teavm-$a-$v.jar https://repo1.maven.org/maven2/org/teavm/teavm-$a/$v/teavm-$a-$v.jar || echo FAIL $v $a; done
curl -fsSL -o jars-$v/commons-io-2.20.0.jar https://repo1.maven.org/maven2/commons-io/commons-io/2.20.0/commons-io-2.20.0.jar
curl -fsSL -o jars-$v/joda-time-2.12.2.jar https://repo1.maven.org/maven2/joda-time/joda-time/2.12.2/joda-time-2.12.2.jar
curl -fsSL -o jars-$v/jzlib-1.1.3.jar https://repo1.maven.org/maven2/com/jcraft/jzlib/1.1.3/jzlib-1.1.3.jar; done
