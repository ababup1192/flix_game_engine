#!/bin/bash
# libs/ は fetch.sh で取る（git には入れない）。
D=$(cd "$(dirname "$0")" && pwd)
export PATH=/Users/abab/Desktop/flix_game_engine/.devbox/nix/profile/default/bin:$PATH
CP=$(ls $D/libs/jwebgpu/*.jar | grep -v -E "dawn|wgpu_mac" | tr '\n' ':')$(ls $D/libs/lwjgl/*.jar | tr '\n' ':')
mkdir -p $D/out
javac -nowarn -d $D/out -cp "$CP" $(find $D/src -name '*.java')
