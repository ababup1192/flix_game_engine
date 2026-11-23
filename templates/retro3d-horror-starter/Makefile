# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く・WASD / 矢印で歩く・クリックでマウスの視点・Esc で放す / 終了の確認）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make render SHOT=<場面> … 1 枚だけ debug/<場面>.png へ描き出す（CPU で描く）
#   make sfx    … 効果音を全部合成し直して assets/sfx/ へ書く（src/render/SfxRender.flix）
#   make bundles … 校舎の glb を束（assets/school/bundle/）へまとめ直す
#   make web    … ブラウザ版を build/web へ書き出す（手元で開く手順は README の「ブラウザで遊ぶ」）
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

# WhyNot: パレットの作り置き（project.json の prebuild）を書かない — ドット絵の sprite.json を持たず、絵は PNG と glb のまま貼るので、作り直すパレットが無い。

# 描き出せる場面の名前（render の使い方に出す写し）と、パレットの作り置き・ゲーム固有の作業は project.json の
# shots・prebuild・tasks に書く（bin/fge が読むので Windows でも同じ。make <作業> は bin/fge task <作業> の別名）。

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

# 効果音を全部合成して assets/sfx/ へ書く（足音・戸・時計・空気・風・拾う・紙。src/render/SfxRender.flix）。
.PHONY: sfx
sfx:
	@$(FGE_RUN) task sfx

# 校舎を歩く所の動画 = debug/video/<OUT>.mp4（960×720・3D は 320×240 を補間なしで 3 倍・字は 3 倍の画素で描く・音なし）。手順は FLOW（撮るのは mark in_ / out_ の間だけ）。
#   make video FLOW=e2e/video/corridor.flow OUT=corridor
#   make videos … e2e/video/*.flow を全部撮る
# GPU で塗れれば mp4 を直に書き、SoftRaster に落ちた時（FGE_GPU=off・GL が作れない）は f0000.png … を書いてここで mp4 へ束ねる。
VIDEO_FLOW = $(or $(FLOW),e2e/video/corridor.flow)
VIDEO_OUT = $(or $(OUT),corridor)
VIDEO_FPS ?= 30
VIDEO_X264 ?= -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p
.PHONY: video videos
video:
	rm -f debug/video/$(VIDEO_OUT)/f*.png debug/video/$(VIDEO_OUT).mp4
	VIDEO_FPS=$(VIDEO_FPS) VIDEO_FLOW=$(VIDEO_FLOW) VIDEO_OUT=$(VIDEO_OUT) VIDEO_X264="$(VIDEO_X264)" $(HEADLESS_RUN) VideoRender.frames
	@if [ -f debug/video/$(VIDEO_OUT)/f0000.png ]; then \
	  ffmpeg -y -loglevel error -framerate $(VIDEO_FPS) -i debug/video/$(VIDEO_OUT)/f%04d.png $(VIDEO_X264) \
	    -movflags +faststart debug/video/$(VIDEO_OUT).mp4; fi
	@echo "[video] debug/video/$(VIDEO_OUT).mp4"

videos:
	@for f in e2e/video/*.flow; do n=$$(basename $$f .flow); $(MAKE) --no-print-directory video FLOW=$$f OUT=$$n || exit 1; done

# X に載せる 1 分の紹介の動画 = debug/video/trailer_x.mp4（960×720・30 fps・H.264 High・AAC 128 kbps 48 kHz ステレオ・-14 LUFS）。
# 場面の手順と音を置く時刻は tools/trailer.py（flows）が書き、場面を make video で撮り、tools/trailer.py（mix）がつなぐ。音は make sfx の合成音。
TRAILER_SCENES := entrance corridor classroom library girl toilet stairs teacher nurse vacant
.PHONY: trailer
trailer:
	$(PYTHON3) tools/trailer.py flows
	@for n in $(TRAILER_SCENES); do $(MAKE) --no-print-directory video FLOW=e2e/trailer/$$n.flow OUT=trailer_$$n || exit 1; done
	$(PYTHON3) tools/trailer.py mix

# コミットで .flix か lint/ を触ったら、lint/rules.flix の決まり（依存の向き・View が World を受けない・テストの形）も見る。
# flixlint を取れない時（オフラインの初回など）は止めずに知らせる（make lint-flixlint で後から流せる）。
.PHONY: precommit-local
precommit-local:
	@if grep -qE '\.flix$$|^lint/' "$(STAGED_FILE)"; then \
	  fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	  if "$$fge" flixlint-prepare > /dev/null; then $(MAKE) --no-print-directory lint-flixlint; \
	  else echo "[pre-commit] flixlint を用意できないので lint/rules.flix の検査は飛ばします（後で make lint-flixlint）"; fi; \
	fi

# 校舎の glb（建物 3 つ・小物 369 個）を、絵を重ねて持たない束 assets/school/bundle/*.glb へまとめる（ゲームが読むのは束）。
# 元の glb か layout.json を替えたら流す。束は git に入れる（デスクトップの起動・テスト・描き出しも束を読む）。
.PHONY: bundles bundles-check
bundles:
	@$(FGE_RUN) task bundles
bundles-check:
	@$(FGE_RUN) task bundles-check

# ブラウザ版を build/web へ書き出す（束を作り直してから。予算 web.startupBudget を超えたら止まる）。
# 手元で開く: "$(ENGINE)/bin/py3" -m http.server 8000 --bind 127.0.0.1 --directory build/web → http://127.0.0.1:8000/
.PHONY: web
web: bundles
	bin/fge export-web .
