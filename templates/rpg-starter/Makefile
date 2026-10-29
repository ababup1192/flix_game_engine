# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make render SHOT=<場面> … 1 枚だけ debug/<場面>.png へ描き出す
#   make render-all          … 全部 gallery/ へ描き出す
#
# エンジンや java の場所はマシンごとに違うので、git に入れない local.mk に書く
# （make new-game / Studio が生成する。別のマシンで clone したら 1 度だけ書き直す）:
#   ENGINE := /abs/path/to/flix_game_engine   （Studio 同梱なら …/resources/engine）
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe）
# 既定の ../.. は「テンプレを engine リポの中でそのまま動かす」ための値。
-include local.mk
ENGINE ?= ../..

# 描き出せる場面の名前（source of truth は SceneRender.shotNames。ここは使い方に出す写し）。
# 場面を足したら SceneRender.shotNames と一緒にここも足す。
SHOTS := title village quest join world cave dungeon1 dungeon2 dungeon3 battle magic item equip boss clear ending

# WhyNot: 色票（assets/rpg.palette.json）は FC の色をそのまま並べた原本で、生成物ではない。
# PALETTE を決めると game.mk が Palette.write で作り直しに行くので、ここでは決めない。

# ENGINE の場所が違うと include ごと落ち、make は「そんなファイルは無い」としか言わない。
# 先に自前で見て、直し方の 1 行を出してから止める（この検査が無いと make status も塞がる）。
ifeq ($(shell test -f "$(ENGINE)/mk/game.mk" && echo ok),)
$(error ENGINE が見当たりません ($(ENGINE)/mk/game.mk が無い) — local.mk に「ENGINE := /abs/path/to/flix_game_engine」を書くか、make <対象> ENGINE=... で指定してください。Studio 同梱なら …/resources/engine)
endif

# 共通の口（run / test / check / 描き出し / status …）はエンジンが持つ。
# include は make の構文でクォートが効かず、空白でパスが分割されるので、空白を退避してから渡す。
space := $(subst ,, )
include $(subst $(space),\$(space),$(ENGINE))/mk/game.mk

# コミットで .flix か lint/ を触ったら、lint/rules.flix の決まり（依存の向き・View が World を受けない・テストの形）も見る。
# flixlint を取れない時（オフラインの初回など）は止めずに知らせる（make lint-flixlint で後から流せる）。
.PHONY: precommit-local
precommit-local:
	@if grep -qE '\.flix$$|^lint/' "$(STAGED_FILE)"; then \
	  fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	  if "$$fge" flixlint-prepare > /dev/null; then $(MAKE) --no-print-directory lint-flixlint; \
	  else echo "[pre-commit] flixlint を用意できないので lint/rules.flix の検査は飛ばします（後で make lint-flixlint）"; fi; \
	fi

# 自動の通しプレイ（タイトルからエンディングを見てタイトルへ戻るまで。方針は src/sim/Bot.flix）→ debug/bot.md。詰んだら終了コード 1。
#   make bot                  5 本（種 0..4）
#   make bot BOT_RUNS=1 BOT_SEED=7
BOT_RUNS ?= 5
BOT_SEED ?= 0
.PHONY: bot balance
bot:
	BOT_RUNS=$(BOT_RUNS) BOT_SEED=$(BOT_SEED) $(HEADLESS_RUN) BotRun.play

# つり合いのシミュレーション（戦いだけを BattleActs.resolveRound で回す。src/sim/BalanceSim.flix）→ debug/balance.md。
# テストではなく知らせる口（終了コードはいつも 0）。BALANCE_SEEDS で 1 組あたりの種の数を下げられる（既定 500）。
BALANCE_SEEDS ?= 500
balance:
	BALANCE_SEEDS=$(BALANCE_SEEDS) $(HEADLESS_RUN) BalanceSim.play
