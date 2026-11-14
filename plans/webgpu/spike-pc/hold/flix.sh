#!/bin/bash
# usage: hold/flix.sh <check|run|build> — flix 0.78（devbox の nix store の jar）を JDK 21 で動かす。
cd "$(dirname "$0")"
"../guard.sh"
export PATH=/Users/abab/Desktop/flix_game_engine/.devbox/nix/profile/default/bin:$PATH
FLIXJAR=$(dirname "$(readlink -f "$(command -v flix)")")/../share/java/flix/flix.jar
java -Djava.awt.headless=true -jar "$FLIXJAR" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
