#!/bin/sh
# 偽の engine リポを $1 に組む。check-api-index.py が緑になる最小の形。
#
# check-api-index.py は ROOT を __file__ から決めるので、見に行く先を差し替える口が無い。
# 偽リポの bin/ へ check-api-index.py を写して、そこから走らせる。
set -eu
R=$1
mkdir -p "$R/bin" "$R/engine/src" "$R/engine_world/src" "$R/engine_tools/src" "$R/docs/modules"

cat > "$R/engine/src/App.flix" <<'EOF'
mod App {
    pub def run(): Unit = ()
    pub def frame(): Unit = ()
}
EOF

cat > "$R/engine_world/src/Board.flix" <<'EOF'
mod Board {
    pub def make(): Unit = ()
}
EOF

cat > "$R/engine_tools/src/Bakery.flix" <<'EOF'
mod Bakery {
    pub def bake(): Unit = ()
}
EOF

cat > "$R/docs/modules/engine.md" <<'EOF'
# engine の索引

- App — 走らせる入口。App.run で始める
EOF

cat > "$R/docs/module-index.md" <<'EOF'
# engine_world の索引

- Board — 盤。Board.make で組む
- 絵の焼き出しは Bakery.bake
EOF
