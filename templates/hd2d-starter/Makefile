# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く・矢印キーか WASD で歩く・Esc で終了の確認）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make render SHOT=<場面> … 1 枚だけ debug/<場面>.png へ描き出す（CPU で描くので 1 枚 10 秒ほど）
#   make render-all          … 全部 gallery/ へ描き出す
#   make flow FLOW=e2e/walk.flow … 画面なしで歩きの手順を流す
#
# 描き方の重さは環境変数で差し替える: make run SHADOW_MAP=2048 DOF=0 POST=0
#
# エンジンや java の場所はマシンごとに違うので、git に入れない local.mk に書く
# （make new-game / Studio が生成する。別のマシンで clone したら 1 度だけ書き直す）:
#   ENGINE := /abs/path/to/flix_game_engine   （Studio 同梱なら …/resources/engine）
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe）
# 既定の ../.. は「テンプレを engine リポの中でそのまま動かす」ための値。
-include local.mk
ENGINE ?= ../..

# 描き出せる場面の名前（source of truth は Shots.names。ここは使い方に出す写し）。
# 場面を足したら Shots.names と一緒にここも足す。
SHOTS := title start avenue quit

# WhyNot: 色票（PALETTE）を決めない — ドット絵の sprite.json を持たず、板の絵は PNG のまま貼るので、作り直す色票が無い。

# ENGINE の場所が違うと include ごと落ち、make は「そんなファイルは無い」としか言わない。
# 先に自前で見て、直し方の 1 行を出してから止める（この検査が無いと make status も塞がる）。
ifeq ($(shell test -f "$(ENGINE)/mk/game.mk" && echo ok),)
$(error ENGINE が見当たりません ($(ENGINE)/mk/game.mk が無い) — local.mk に「ENGINE := /abs/path/to/flix_game_engine」を書くか、make <対象> ENGINE=... で指定してください。Studio 同梱なら …/resources/engine)
endif

# 共通の口（run / test / check / 描き出し / status …）はエンジンが持つ。
# include は make の構文でクォートが効かず、空白でパスが分割されるので、空白を退避してから渡す。
space := $(subst ,, )
include $(subst $(space),\$(space),$(ENGINE))/mk/game.mk

# WhyNot: lint/rules.flix（flixlint の層の決まり）を持たない — flixlint 0.9.0 はこのテンプレートが使う engine の 3D の口
# （Scene3d.LightUnits・Camera3d.lensShift）を解けず、事実を集める所で止まる。flixlint が追いついたら tidepool-starter の物を写す。
