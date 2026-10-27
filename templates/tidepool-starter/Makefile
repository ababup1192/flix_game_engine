# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make palette … Studio 用の色の写し(assets/tidepool.palette.json)を無条件に作り直す
#   make solve   … 面を解いて最少手数・解き方・面の指紋を assets/tidepool.levels.json に書く（深さは SOLVE_DEPTH）
#   make video   … 遊ぶ所を音つきの動画にする = debug/video/tidepool.mp4（題名 → 面 1・3・5 → 全面クリア。VIDEO_FPS=30 か 60）
#
# エンジンや java の場所はマシンごとに違うので、git に入れない local.mk に書く
# （make new-game / Studio が生成する。別のマシンで clone したら 1 度だけ書き直す）:
#   ENGINE := /abs/path/to/flix_game_engine   （Studio 同梱なら …/resources/engine）
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe）
# 既定の ../.. は「テンプレを engine リポの中でそのまま動かす」ための値。
-include local.mk
ENGINE ?= ../..

# Studio 用の色の写し。入力（テーマ・sprite の Doc と、色を解く側のコード）が
# 写しより新しいときだけ作り直す。flix run は 1 回ごとにパッケージ全体をコンパイルし直すので、
# render のたびに無条件で走らせると、絵を描くのと同じだけのコンパイル時間を二重に払う。
# 入力の洗い出しに漏れがあったときは `make palette` で無条件に作り直す。
PALETTE      := assets/tidepool.palette.json
PALETTE_DEPS := assets/tidepool.theme.json assets/tidepool.sprite.json \
                src/Palette.flix src/ThemeDoc.flix
# 描き出せる場面の名前（source of truth は SceneRender.shotNames。ここは使い方に出す写し）。
# 場面を足したら SceneRender.shotNames と一緒にここも足す。
SHOTS := title play flood dam clear washed ending quit

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

.PHONY: solve video

# 面ごとに、深さ SOLVE_DEPTH までの幅優先で最少手数と手の列を探し、levels の Doc に par・solution・solvedHash を書く。
# 重いのでテストの道から外してある（テストは solvedHash が今の面の中身と同じかだけを見る）。
SOLVE_DEPTH ?= 40
solve:
	SOLVE_DEPTH=$(SOLVE_DEPTH) $(HEADLESS_RUN) Solve.main

# コミットで .flix か lint/ を触ったら、lint/rules.flix の決まり（依存の向き・View が World を受けない・テストの形）も見る。
# flixlint を取れない時（オフラインの初回など）は止めずに知らせる（make lint-flixlint で後から流せる）。
.PHONY: precommit-local
precommit-local:
	@if grep -qE '\.flix$$|^lint/' "$(STAGED_FILE)"; then \
	  fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	  if "$$fge" flixlint-prepare > /dev/null; then $(MAKE) --no-print-directory lint-flixlint; \
	  else echo "[pre-commit] flixlint を用意できないので lint/rules.flix の検査は飛ばします（後で make lint-flixlint）"; fi; \
	fi

# 動画の口の共通部: 連番のフォルダを消す（FGE_VIDEO_PAINT で一部だけ塗る時は残す）→ 入口を流す → フォルダごとに mp4 へ束ねる。
#   $(call video,入口,debug/video/ の下のフォルダ…,fps,ffmpeg の出力の旗,出力名の後ろに足す字)
#   入口はフォルダにコマ（SoftRaster は f0000.png …・GPU は frames.mkv）と音（audio.wav）を書く。
#   入口へ渡す環境変数は、口ごとに VIDEO_ENV を target-specific に置く。
VIDEO_FPS ?= 30
# 書き出しは 1280×720 にそろえる（VIDEO_SCALE=1 で描いた 640×360 のコマは拡大する）。
VIDEO_SCALE ?= 2
VIDEO_X264 ?= -vf scale=1280:720:flags=lanczos -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p
define mix
	for r in $(1); do d=debug/video/$${r}; \
	  if [ -f $$d/frames.mkv ]; then src="-i $$d/frames.mkv"; else src="-framerate $(2) -i $$d/f%04d.png"; fi; \
	  ffmpeg -y -loglevel error $$src -i $$d/audio.wav $(VIDEO_X264) $(3) -c:a aac -b:a 160k -ar 44100 \
	    -shortest -movflags +faststart debug/video/$${r}$(4).mp4 || exit 1; \
	  echo "[video] debug/video/$${r}$(4).mp4"; done
endef
define video
	$(if $(FGE_VIDEO_PAINT),,rm -rf $(addprefix debug/video/,$(2)))
	$(VIDEO_ENV) $(HEADLESS_RUN) $(1)
	$(call mix,$(2),$(3),$(4),$(5))
endef

# 遊ぶ所を音つきで = debug/video/tidepool.mp4（1280×720）。手は flow で World に流し、音は同じコマの出来事とミキサーから混ぜる。
# GPU の無い所（SoftRaster）は水のシェーダーを画素ごとに塗るので遅い: 4 コアで VIDEO_SCALE=1（640×360 を拡大・字が少しにじむ）が
# 1 コマ約 3 秒・全体で約 1.7 時間、倍率 2 はその数倍。途中で止まったら make video FGE_VIDEO_PAINT=frames:A-B で残りだけ塗り足す。
# 鳴った時刻の表は debug/video/tidepool/sfx.txt、流した手順は debug/video/tidepool/video.flow。
video: VIDEO_ENV = VIDEO_FPS=$(VIDEO_FPS) VIDEO_SCALE=$(VIDEO_SCALE)
video:
	$(call video,VideoRender.frames,tidepool,$(VIDEO_FPS))
