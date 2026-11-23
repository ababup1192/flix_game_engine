# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make palette … Studio 用の色の写し(assets/__NAME__.palette.json)を無条件に作り直す
#   make atelier-preview … atelier/ の候補と assets/ の現行を debug/atelier/ に描き出す
#
# engine の場所は次の順で決まる（Go の道具の ResolveEngineDir と同じ決まり）:
#   1. 環境変数 ENGINE  2. local.mk の ENGINE（git に入れない。engine を clone して直す人の上書き）
#   3. engine リポの中のテンプレートなら ../..  4. ${FGE_HOME:-~/.flix_ge}/engines/<flix.toml の flix_game_engine の版>
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe・local.mk に書く）
# WhyNot: local.mk に engine の固定のパスを書かせない — local.mk は git の外なので、版を上げた後も古い engine を読み続け、
# worktree とゲームを clone した別の機械には無い。git に入っている flix.toml の版から決めれば、どこでも同じ engine になる。
-include local.mk
FGE_VERSION := $(shell sed -n 's/^"github:ababup1192\/flix_game_engine"[^}]*version *= *"\([0-9.]*\)".*/\1/p' flix.toml)
ENGINE ?= $(if $(and $(wildcard ../../mk/game.mk),$(wildcard ../../templates)),../..,$(or $(FGE_HOME),$(HOME)/.flix_ge)/engines/$(FGE_VERSION))

# Studio 用の色の写し。入力（テーマ・sprite の Doc と、色を解く側のコード）が
# 写しより新しいときだけ作り直す。flix run は 1 回ごとにパッケージ全体をコンパイルし直すので、
# render のたびに無条件で走らせると、絵を描くのと同じだけのコンパイル時間を二重に払う。
# 入力の洗い出しに漏れがあったときは `make palette` で無条件に作り直す。
PALETTE      := assets/__NAME__.palette.json
PALETTE_DEPS := assets/__NAME__.theme.json assets/__NAME__.sprite.json \
                src/Palette.flix src/ThemeDoc.flix
# 描き出せる場面の名前（source of truth は Shots.names。ここは使い方に出す写し）。
# 場面を足したら Shots.names と一緒にここも足す。
SHOTS := main quit

# ENGINE の場所が違うと include ごと落ち、make は「そんなファイルは無い」としか言わない。
# 先に自前で見て、直し方の 1 行を出してから止める（この検査が無いと make status も塞がる）。
ifeq ($(shell test -f "$(ENGINE)/mk/game.mk" && echo ok),)
ifeq ($(ENGINE),$(or $(FGE_HOME),$(HOME)/.flix_ge)/engines/$(FGE_VERSION))
$(error $(if $(FGE_VERSION),engine $(FGE_VERSION) が手元にありません ($(ENGINE)) — fge engines install $(FGE_VERSION) を流してください,flix.toml から flix_game_engine の版を読めません — flix.toml の依存の行を直すか、local.mk に「ENGINE := /abs/path/to/flix_game_engine」を書いてください))
else
$(error ENGINE が見当たりません ($(ENGINE)/mk/game.mk が無い) — local.mk に「ENGINE := /abs/path/to/flix_game_engine」を書くか、make <対象> ENGINE=... で指定してください。Studio 同梱なら …/resources/engine)
endif
endif

# 共通の口（run / test / check / 描き出し / status …）はエンジンが持つ。
# 写しではないので、エンジンを上げると直しがそのまま届く。
# include は make の構文でクォートが効かず、空白でパスが分割される。
# Studio 同梱の engine は "/Applications/Flix GE Studio.app/…" と空白を含むので、
# 空白を退避してから渡す（レシピの中の $(ENGINE) は "" で括ってあるのでそのままでよい）。
space := $(subst ,, )
include $(subst $(space),\$(space),$(ENGINE))/mk/game.mk

.PHONY: atelier-preview

atelier-preview:
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint SceneRender.atelier

# コミットで .flix か lint/ を触ったら、lint/rules.flix の決まり（依存の向き・View が World を受けない・テストの形）も見る。
# flixlint を取れない時（オフラインの初回など）は止めずに知らせる（make lint-flixlint で後から流せる）。
.PHONY: precommit-local
precommit-local:
	@if grep -qE '\.flix$$|^lint/' "$(STAGED_FILE)"; then \
	  fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	  if "$$fge" flixlint-prepare > /dev/null; then $(MAKE) --no-print-directory lint-flixlint; \
	  else echo "[pre-commit] flixlint を用意できないので lint/rules.flix の検査は飛ばします（後で make lint-flixlint）"; fi; \
	fi
