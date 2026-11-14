#!/bin/bash
D=/private/tmp/claude-501/-Users-abab--claude-spares-spare-q72Ibn/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/webgpu-spike/pc
CP=$(ls $D/libs/jwebgpu/*.jar | grep -v -E "dawn|wgpu_mac" | tr '\n' ':')$(ls $D/libs/lwjgl/*.jar | tr '\n' ':')
mkdir -p $D/out
cd /Users/abab/Desktop/flix_game_engine && devbox run -- javac -nowarn -d $D/out -cp "$CP" $D/src/*.java
