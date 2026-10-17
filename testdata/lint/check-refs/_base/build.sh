#!/bin/sh
# 偽の engine リポを $1 に組む。check-refs が全て緑になる最小の形。
#
# WhyNot: 本物のリポから走らせないのは、check-refs が見に行く根を実行した場所から
# 決めるため。偽リポの中で走らせないと本物のリポを検査してしまう。
set -eu
R=$1
mkdir -p "$R"

# bundleRequired（bin/lint-rules/check-refs.json の一覧そのもの）。中身は見られないので空でよい。
for p in \
  Makefile flix.toml \
  bin/flix bin/checkd bin/explain-error bin/gen-api-digest.py \
  bin/reference-update.sh bin/reference-check.sh bin/check-render-budget.py \
  mk/game.mk bin/fge bin/lint-rules/view.json bin/img-digest.py bin/status.py \
  bin/lint-view.py bin/lint-palette.py bin/lint-sprite.py bin/lint-anim.py \
  bin/lint-audio.py bin/lint-images.py bin/lint-ui-overflow.py \
  bin/precommit.py bin/githooks/pre-commit bin/sync-agents.py bin/carve/carve.py \
  docs/api-digest.md docs/api-digest/engine.md docs/api-digest/engine_world.md \
  docs/api-digest/engine_tools.md docs/module-index.md \
  docs/doc-conventions.md docs/glossary.md docs/shader-doc.md docs/checkd.md \
  docs/modules/engine.md mk/module.sed docs/drawing-floor.md \
  docs/flix-conventions.md docs/error-handling.md \
  .claude/hooks/after-flix-edit.py .claude/hooks/session-diet.py \
  agents-pack/AGENTS.core.md agents-pack/settings.json agents-pack/manifest.json \
  agents-pack/codex-hooks.json agents-pack/rules/drawing.md agents-pack/rules/flix.md \
  templates/game-starter/Makefile \
  engine_full/flix.toml engine_full/artifact/engine_full.fpkg
do
  mkdir -p "$R/$(dirname "$p")"
  : > "$R/$p"
done

cat > "$R/Makefile" <<'EOF'
VERSION := 0.1.0

status:
	python3 bin/status.py

api:
	python3 bin/gen-api-digest.py > docs/api-digest.md
EOF

cat > "$R/agents-pack/manifest.json" <<'EOF'
{
  "version": 1,
  "copy": [
    {"src": "bin/fge", "dst": "bin/fge"},
    {"src": "bin/status.py", "dst": "bin/status.py"},
    {"src": "bin/checkd", "dst": "bin/checkd"},
    {"src": "bin/lint-view.py", "dst": "bin/lint-view.py"},
    {"src": "bin/precommit.py", "dst": "bin/precommit.py"},
    {"src": "bin/githooks/pre-commit", "dst": "bin/githooks/pre-commit"},
    {"src": ".claude/hooks/after-flix-edit.py", "dst": ".claude/hooks/after-flix-edit.py"},
    {"src": ".claude/hooks/session-diet.py", "dst": ".claude/hooks/session-diet.py"}
  ],
  "copyIfAbsent": [
    {"src": "agents-pack/settings.json", "dst": ".claude/settings.json"}
  ],
  "copyDirs": [
    {"src": "agents-pack/rules", "dst": ".claude/rules"}
  ]
}
EOF

cat > "$R/agents-pack/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command",
        "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/after-flix-edit.py\""}]},
      {"hooks": [{"type": "command",
        "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/session-diet.py\""}]}
    ]
  }
}
EOF

cat > "$R/agents-pack/AGENTS.core.md" <<'EOF'
# AGENTS

API の型は docs/api-digest.md を引く。逆引きは docs/module-index.md。
検査の呼び口は bin/fge の 1 本だけ。

絵の決まりは .claude/rules/drawing.md、Flix の決まりは .claude/rules/flix.md。
フックの配線は .claude/settings.json。
EOF

cat > "$R/mk/game.mk" <<'EOF'
ENGINE ?= /nonexistent

check:
	$(ENGINE)/bin/checkd $(CURDIR)

status:
	python3 $(ENGINE)/bin/status.py
EOF

cat > "$R/templates/game-starter/Makefile" <<'EOF'
ENGINE ?= /nonexistent
include $(ENGINE)/mk/game.mk

lint:
	python3 bin/lint-view.py src
EOF
: > "$R/templates/game-starter/flix.toml"
: > "$R/templates/game-starter/project.json"
mkdir -p "$R/templates/game-starter/reference" "$R/templates/game-starter/src"
: > "$R/templates/game-starter/reference/title.png"
: > "$R/templates/game-starter/src/Main.flix"
