# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#
# エンジンや java の場所はマシンごとに違うので、git に入れない local.mk に書く
# （make new-game / Studio が生成する。別のマシンで clone したら 1 度だけ書き直す）:
#   ENGINE := /abs/path/to/flix_game_engine   （Studio 同梱なら …/resources/engine）
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe）
# 既定の ../.. は「テンプレを engine リポの中でそのまま動かす」ための値。
-include local.mk
ENGINE ?= ../..

# 描き出せる場面の名前（source of truth は SceneRender.shotNames。ここは使い方に出す写し）。
SHOTS := title nvl adv choice lane engawa night morning log load settings credits

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

# 見せ場をつないだ紹介の動画（e2e/showcase.flow → debug/video/showcase.mp4。X に載せられる H.264 + AAC）。
# コマと音は FlowVideo が実機と同じ 1 フレームで書き、ここで mp4 に束ねる（GPU で塗れた時は frames.mkv、塗れない時は連番 PNG）。
.PHONY: showcase-video
showcase-video:
	rm -rf debug/video/showcase
	FLOW=e2e/showcase.flow FLOW_OUT=debug/video/showcase $(HEADLESS_RUN) FlowVideo.play
	@dir=debug/video/showcase; fps=$$(cat $$dir/fps.txt); \
	 if [ -f $$dir/frames.mkv ]; then frames="-i $$dir/frames.mkv"; else frames="-framerate $$fps -i $$dir/f%04d.png"; fi; \
	 ffmpeg -y -loglevel error $$frames -f f64be -ar 44100 -ac 2 -i $$dir/audio.f64 \
	   -c:v libx264 -pix_fmt yuv420p -crf 20 -r $$fps -c:a aac -b:a 192k -shortest -movflags +faststart debug/video/showcase.mp4
	@echo "rendered: debug/video/showcase.mp4"
