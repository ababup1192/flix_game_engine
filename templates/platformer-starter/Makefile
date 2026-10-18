# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make palette … Studio 用の色の写し(assets/px.palette.json)を無条件に作り直す
#   make loc    … src/ + test/ の .flix 合計行数（上限 3,000 行）
#   make playtest … bot に通しで遊ばせて「走れるか・詰まらないか」を測る
#   make probe  … 面の読み込み・1 tick・タイル層の組み立てにかかる時間を測る
#
# エンジンや java の場所はマシンごとに違うので、git に入れない local.mk に書く
# （make new-game / Studio が生成する。別のマシンで clone したら 1 度だけ書き直す）:
#   ENGINE := /abs/path/to/flix_game_engine   （Studio 同梱なら …/resources/engine）
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe）
# 既定の ../.. は「テンプレを engine リポの中でそのまま動かす」ための値。
-include local.mk
ENGINE ?= ../..

# Studio のドット絵エディタに legend の意味色キーの実色を教える写し（生成物）。
# 色を変えたら作り直す — 忘れると編集画面だけ仮色になり、実機と配色が食い違う。
# 入力（テーマ・sprite の Doc と、色を解く側のコード）が写しより新しいときだけ作り直す。
# flix run は 1 回ごとにパッケージ全体をコンパイルし直すので、render のたびに無条件で
# 走らせると、絵を描くのと同じだけのコンパイル時間を二重に払う。
# 入力の洗い出しに漏れがあったときは `make palette` で無条件に作り直す。
PALETTE      := assets/px.palette.json
PALETTE_DEPS := assets/platformer.theme.json assets/px.sprite.json \
                src/Palette.flix src/Theme.flix
# 描き出せる場面の名前（source of truth は SceneRender.shotNames。ここは使い方に出す写し）。
SHOTS := title hill cave tower hitstop

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

.PHONY: playtest probe

playtest:
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint Playtest.all
probe:
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint Probe.all
