# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make lint-cast … 立ち絵と小物の絵が揃っているか（novel.cast.json の表情の textures の登録・ファイル・縦横の比。make lint も流す）
#
# エンジンや java の場所はマシンごとに違うので、git に入れない local.mk に書く
# （make new-game / Studio が生成する。別のマシンで clone したら 1 度だけ書き直す）:
#   ENGINE := /abs/path/to/flix_game_engine   （Studio 同梱なら …/resources/engine）
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe）
# 既定の ../.. は「テンプレを engine リポの中でそのまま動かす」ための値。
-include local.mk
ENGINE ?= ../..

# 描き出せる場面の名前（source of truth は Shots.names。ここは使い方に出す写し）。
SHOTS := title nvl adv choice lane engawa night morning hold log load settings credits

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

# FlowVideo が書いたコマと音（$(1) のフォルダ）を、X に載せられる H.264 + AAC の mp4（$(2)）に束ねるシェルの 1 文。
# GPU で塗れた時は frames.mkv、塗れない時は連番 PNG。
flow-mp4 = fps=$$(cat $(1)/fps.txt); \
	if [ -f $(1)/frames.mkv ]; then frames="-i $(1)/frames.mkv"; else frames="-framerate $$fps -i $(1)/f%04d.png"; fi; \
	ffmpeg -y -loglevel error $$frames -f f64be -ar 44100 -ac 2 -i $(1)/audio.f64 \
	  -c:v libx264 -pix_fmt yuv420p -crf 20 -r $$fps -c:a aac -b:a 192k -shortest -movflags +faststart $(2)

# 見せ場をつないだ紹介の動画（e2e/showcase.flow → debug/video/showcase.mp4）。
# コマと音は FlowVideo が実機と同じ 1 フレームで書き、ここで mp4 に束ねる。
.PHONY: showcase-video
showcase-video:
	rm -rf debug/video/showcase
	FLOW=e2e/showcase.flow FLOW_OUT=debug/video/showcase $(HEADLESS_RUN) FlowVideo.play
	@$(call flow-mp4,debug/video/showcase,debug/video/showcase.mp4)
	@echo "rendered: debug/video/showcase.mp4"

# 付箋の頁（make tape FLOW=e2e/tape.flow → debug/tape/tape/index.html）。
# ① FlowVideo が flow を流してコマ・音（debug/video/<名前>）と tape.json を書き、② showcase-video と同じ ffmpeg で video.mp4 に束ね、
# ③ bin/fge tape が strip.jpg と index.html を作る。debug/tape/<名前> には頁に要る物（tape.json・video.mp4・strip.jpg・index.html）だけを置く。
# tape.json が書けない（同じ名前の mark・ノードをまたぐ flow）時は FlowVideo が理由を出し、ここで止める。
# flow が途中で止まった時も、そこまでの頁を作ってから止まった印（終了コード 1）を返す。
TAPE_NAME = $(basename $(notdir $(FLOW)))
.PHONY: tape
tape:
	@test -n "$(TAPE_NAME)" || { echo "make tape FLOW=e2e/<名前>.flow"; exit 2; }
	@rm -rf debug/video/$(TAPE_NAME) debug/tape/$(TAPE_NAME); mkdir -p debug/tape/$(TAPE_NAME); \
	 FLOW=$(FLOW) FLOW_OUT=debug/video/$(TAPE_NAME) $(HEADLESS_RUN) FlowVideo.play; code=$$?; \
	 test -f debug/video/$(TAPE_NAME)/tape.json || { echo "tape: debug/video/$(TAPE_NAME)/tape.json を書けなかった"; exit 1; }; \
	 cp debug/video/$(TAPE_NAME)/tape.json debug/tape/$(TAPE_NAME)/tape.json; \
	 { $(call flow-mp4,debug/video/$(TAPE_NAME),debug/tape/$(TAPE_NAME)/video.mp4); } || exit 1; \
	 "$(ENGINE)/bin/fge" tape --dir debug/tape/$(TAPE_NAME) || exit 1; \
	 exit $$code

# 立ち絵と小物（assets/novel.cast.json）の絵の登録と縦横の比を見る（読むだけ・標準の python3 で足りる）。
# 元の絵を縮めて縁を埋めるのは python3 art/cast/prepare.py <元の絵の置き場>（Pillow が要る）。
.PHONY: lint-cast
lint-cast:
	python3 art/cast/lint.py

lint: lint-cast
