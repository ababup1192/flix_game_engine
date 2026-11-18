#!/bin/bash
# ブラウザ版の書き出しの前に、ゲームを build/web-stage へ写し、曲を足す（曲のファイルは git に入れない）。
# usage: bin/web_stage.sh <曲のファイル（OGG）>
#   曲があれば build/web-stage/assets/bgm/firmament3_loop.ogg に写し、写した project.json の sounds（ループ）と
#   web.deferred（押して始めるのを待たずに後から取る）に足す。曲が無ければ音なしのまま写して 1 行言う。
# WhyNot: ゲームのフォルダの project.json に曲を書かない — 曲のファイルが無い手元では、書き出しも窓の起動も
# 「project.json の音が無い」で止まり、最終動画の撮り方まで巻き込む。
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
bgm=${1:-}
stage=build/web-stage
mkdir -p "$stage"
rsync -aL --delete --exclude build --exclude debug --exclude lib --exclude gallery --exclude reference --exclude saves ./ "$stage/"
# WhyNot: lib を写さない — 中の engine の束は置き場への相対の symlink で、写すと切れて公開の版を取りに行き、packages.lock と食い違って止まる。
ln -sfn "$PWD/lib" "$stage/lib"
# 昼の町だけを歩く版なので、夕方・夜・霧・炎・氷・最終動画の手順書の Doc は束に入れない（配る量が減り、使わない字をフォントへ求めない）。
(cd "$stage/assets" && rm -f fire*.json ice*.json town_night*.json town_dusk.json town_morning_fog*.json town_avenue*.map.json buildup.json final.json)
if [ -z "$bgm" ] || [ ! -f "$bgm" ]; then
  if [ -n "$bgm" ]; then echo "[web_stage] 曲が無いので音なしで書き出す: $bgm"; else echo "[web_stage] 音なしで書き出す（曲を入れるなら WEB_BGM=<曲のファイル>）"; fi
  exit 0
fi
mkdir -p "$stage/assets/bgm"
cp "$bgm" "$stage/assets/bgm/firmament3_loop.ogg"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 - "$stage/project.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["sounds"] = [s for s in d.get("sounds", []) if s.get("name") != "firmament3_loop"] + [
    {"name": "firmament3_loop", "path": "assets/bgm/firmament3_loop.ogg", "looping": True}]
web = d.setdefault("web", {})
web["deferred"] = sorted(set(web.get("deferred", []) + ["assets/bgm/*.ogg"]))
open(p, "w").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
EOF
echo "[web_stage] 曲を足した: $bgm → $stage/assets/bgm/firmament3_loop.ogg"
