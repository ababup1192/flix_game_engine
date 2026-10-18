# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make atelier-preview … atelier/ の候補と assets/ の現行を debug/atelier/ に描き出す
#
# エンジンや java の場所はマシンごとに違うので、git に入れない local.mk に書く
# （make new-game / Studio が生成する。別のマシンで clone したら 1 度だけ書き直す）:
#   ENGINE := /abs/path/to/flix_game_engine   （Studio 同梱なら …/resources/engine）
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe）
# 既定の ../.. は「テンプレを engine リポの中でそのまま動かす」ための値。
-include local.mk
ENGINE ?= ../..

# 描き出せる場面の名前（source of truth は SceneRender.shotNames。ここは使い方に出す写し）。
SHOTS := title choice ending menu

# ENGINE の場所が違うと include ごと落ち、make は「そんなファイルは無い」としか言わない。
# 先に自前で見て、直し方の 1 行を出してから止める（この検査が無いと make status も塞がる）。
ifeq ($(shell test -f "$(ENGINE)/mk/game.mk" && echo ok),)
$(error ENGINE が見当たりません ($(ENGINE)/mk/game.mk が無い) — local.mk に「ENGINE := /abs/path/to/flix_game_engine」を書くか、make <対象> ENGINE=... で指定してください。Studio 同梱なら …/resources/engine)
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
