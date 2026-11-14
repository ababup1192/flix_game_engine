#!/bin/bash
# 試作の jar を Maven Central から libs/ へ取る（前の試作と同じ物・同じ版）。
# runtime-desktop-jni_mac_arm64 は webgpu の pom の推移依存に出ないので名前で取る。
set -e
D=$(cd "$(dirname "$0")" && pwd)
C=https://repo1.maven.org/maven2
G=com/github/xpenatan
mkdir -p $D/libs/jwebgpu $D/libs/lwjgl
get() { [ -f "$2" ] || curl -fsSL -o "$2" "$1"; }
for a in webgpu-core webgpu-jni webgpu-desktop-jni webgpu-desktop-jni-dawn_mac_arm64 webgpu-desktop-jni-wgpu_mac_arm64; do
  get $C/$G/jWebGPU/$a/0.3.4/$a-0.3.4.jar $D/libs/jwebgpu/$a-0.3.4.jar
done
for a in api-core loader-core runtime-jni runtime-desktop-jni_mac_arm64; do
  get $C/$G/jParser/$a/1.2.8/$a-1.2.8.jar $D/libs/jwebgpu/$a-1.2.8.jar
done
for a in lwjgl lwjgl-glfw lwjgl-opengl; do
  get $C/org/lwjgl/$a/3.4.1/$a-3.4.1.jar $D/libs/lwjgl/$a-3.4.1.jar
  get $C/org/lwjgl/$a/3.4.1/$a-3.4.1-natives-macos-arm64.jar $D/libs/lwjgl/$a-3.4.1-natives-macos-arm64.jar
done
shasum -a 256 $D/libs/*/*.jar
