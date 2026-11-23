# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make lint-cast … 立ち絵と小物の絵が揃っているか（novel.cast.json の表情の textures の登録・ファイル・縦横の比。make lint も流す）
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

# 描き出せる場面の名前（source of truth は Shots.names。ここは使い方に出す写し）。
SHOTS := title nvl adv choice eaves studio invite ending still log load settings credits

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
# テープ（make tape・make tape-publish）と mp4 に束ねる flow-mp4 も engine が持つ（符号化の旗は TAPE_X264・TAPE_AAC で変える）。
include $(subst $(space),\$(space),$(ENGINE))/mk/tape.mk

# 紹介の動画（make flow-video・showcase-video）の符号化: X に載せる物なので大きさより画質（X は 1 本 512 MB まで）。
VIDEO_X264 ?= -c:v libx264 -pix_fmt yuv420p -crf 20
VIDEO_AAC ?= -c:a aac -b:a 192k

# 見せ場をつないだ紹介の動画（e2e/showcase.flow → debug/video/showcase.mp4）。
# コマと音は FlowVideo が実機と同じ 1 フレームで書き、ここで mp4 に束ねる。
.PHONY: showcase-video
showcase-video:
	@$(MAKE) --no-print-directory flow-video FLOW=e2e/showcase.flow

# 立ち絵と小物（assets/novel.cast.json）の絵の登録と縦横の比を見る（読むだけ・標準の python3 で足りる）。
# 元の絵を縮めて縁を埋めるのは python3 art/cast/prepare.py <元の絵の置き場>（Pillow が要る）。
.PHONY: lint-cast
lint-cast:
	$(PYTHON3) art/cast/lint.py

lint: lint-cast

# 1 本の flow を動画に（make flow-video FLOW=e2e/<名前>.flow か NAME=<名前> → debug/video/<名前>.mp4。コマ・音・tape.json は debug/video/<名前>/）。
FLOW ?= $(if $(NAME),e2e/$(NAME).flow)
.PHONY: flow-video
flow-video:
	@test -n "$(TAPE_NAME)" || { echo "使い方: make flow-video FLOW=e2e/<名前>.flow（か NAME=<名前>）"; exit 2; }
	rm -rf "debug/video/$(TAPE_NAME)"
	FLOW=$(FLOW) FLOW_OUT=debug/video/$(TAPE_NAME) $(HEADLESS_RUN) FlowVideo.play
	@$(call flow-mp4,debug/video/$(TAPE_NAME),debug/video/$(TAPE_NAME).mp4,$(VIDEO_X264),$(VIDEO_AAC))
	@echo "rendered: debug/video/$(TAPE_NAME).mp4"

# ── 移行の突き合わせ（engine の docs/migrate-diff.md）──
# 前の版（git worktree に出した古いコミット）で make migrate-baseline、新しい版で make migrate-new を流すと、
# 同じ flow の記録（tape.json・world の層のコマ・古いセーブの読み戻し）を bin/fge migrate diff が突き合わせる。
#   make migrate-baseline   前の版の記録を debug/migrate/baseline に撮る（flow ごとの video.mp4 は MIGRATE_VIDEO=1 の時）。基準が既にあれば止まる（撮り直すなら MIGRATE_OVERWRITE=1）
#                           比べのコマは画面なしの WebGPU で塗る（MIGRATE_PAINT=cpu で SoftRaster）。新しい撮りは基準と同じ描き手で塗り、描き手が違えば比べずに止める
#   make migrate-baseline BASELINE_FROM=<前の版のゲームのフォルダ>
#                           前の版で撮った debug/migrate/baseline を写すだけ（新しい版で撮らない）
#   make migrate-new        新しい版の記録を debug/migrate/new に撮り、突き合わせる（頁は debug/migrate/report/index.html）
#   make migrate-diff       撮り直さずに突き合わせだけ（migrate-accept.json を書き直した後。MIGRATE_DIFF_FLAGS=--strict など）
#   make migrate-video FLOW=e2e/<名前>.flow [OLD=<前の版のゲームのフォルダ>]
#                           前と後の動画を左右に並べる（debug/migrate/<名前>.sbs.mp4）。OLD が無ければ基準の video.mp4（MIGRATE_VIDEO=1 で撮った物）を前にする。
#                           OLD は flow-video の口があれば FLOW= と NAME= の両方を渡して撮り、無ければ tape FLOW= で撮った debug/tape/<名前>/video.mp4 を使う
# 古いセーブは前の版の flow が終わった時のセーブデータ（baseline/flows/<flow>/saves.json）で、両方の版がそれを読み戻す。
MIGRATE_FLOWS ?= $(wildcard e2e/*.flow)
MIGRATE_DIFF_FLAGS ?=
# 撮るのは engine の bin/fge migrate shoot（flow を並べて流し、続けて基準の古いセーブを読み戻す）。flow ごとの video.mp4 は MIGRATE_VIDEO=1 の時だけ束ねる
# （無い時は FLOW_VIDEO=off で全部のコマと音を書かない）。migrate-new は MIGRATE_ALL=off で frames/all を撮らない（diff は all の画素を比べない）。
# WhyNot: 基準でも all を省かない — 前の版の無い flow の頁に並べる絵と、migrate-video で見る文字の枠の元が無くなる。
# 比べのコマの PNG を塗る描き手は MIGRATE_PAINT=gpu|cpu（既定: 基準を撮る回は gpu = 画面なしの WebGPU・新しい撮りは基準と同じ描き手）。
migrate-shoot = HEADLESS_RUN='$(HEADLESS_RUN)' "$(ENGINE)/bin/fge" migrate shoot $(1) $(if $(filter 1,$(MIGRATE_VIDEO)),--video) $(if $(MIGRATE_PAINT),--paint $(MIGRATE_PAINT)) $(2) $(MIGRATE_FLOWS) || code=1
.PHONY: migrate-baseline migrate-new migrate-diff migrate-video
migrate-baseline:
	@if [ -n "$(BASELINE_FROM)" ]; then \
	   test -d "$(BASELINE_FROM)/debug/migrate/baseline/flows" || { echo "migrate-baseline: $(BASELINE_FROM)/debug/migrate/baseline が無い（前の版で make migrate-baseline を流す）"; exit 2; }; \
	   rm -rf debug/migrate/baseline; mkdir -p debug/migrate; cp -R "$(BASELINE_FROM)/debug/migrate/baseline" debug/migrate/baseline; \
	   echo "写した: $(BASELINE_FROM)/debug/migrate/baseline → debug/migrate/baseline"; exit 0; \
	 fi; \
	 if [ -d debug/migrate/baseline/flows ] && [ -z "$(MIGRATE_OVERWRITE)" ]; then \
	   echo "migrate-baseline: debug/migrate/baseline が既にある（新しい版で撮ると前の版の基準が消える。撮り直すなら MIGRATE_OVERWRITE=1）"; exit 2; \
	 fi; \
	 code=0; $(call migrate-shoot,baseline,$(if $(MIGRATE_OVERWRITE),--overwrite)); exit $$code
migrate-new:
	@test -d debug/migrate/baseline/flows || { echo "migrate-new: debug/migrate/baseline が無い（前の版で make migrate-baseline を流して BASELINE_FROM= で写す）"; exit 2; }
	@code=0; MIGRATE_ALL=$${MIGRATE_ALL:-off}; export MIGRATE_ALL; $(call migrate-shoot,new); "$(ENGINE)/bin/fge" migrate diff debug/migrate/baseline debug/migrate/new $(MIGRATE_DIFF_FLAGS) || code=1; exit $$code
migrate-diff:
	"$(ENGINE)/bin/fge" migrate diff debug/migrate/baseline debug/migrate/new $(MIGRATE_DIFF_FLAGS)
migrate-video:
	@test -n "$(TAPE_NAME)" || { echo "使い方: make migrate-video FLOW=e2e/<名前>.flow [OLD=<前の版のゲームのフォルダ>]"; exit 2; }
	@old="debug/migrate/baseline/flows/$(TAPE_NAME)/video.mp4"; \
	 if [ -n "$(OLD)" ]; then \
	   if $(MAKE) -C "$(OLD)" -n flow-video FLOW=$(FLOW) NAME=$(TAPE_NAME) >/dev/null 2>&1; then \
	     $(MAKE) -C "$(OLD)" flow-video FLOW=$(FLOW) NAME=$(TAPE_NAME) || exit 1; old="$(OLD)/debug/video/$(TAPE_NAME).mp4"; \
	   else \
	     $(MAKE) -C "$(OLD)" tape FLOW=$(FLOW) || exit 1; old="$(OLD)/debug/tape/$(TAPE_NAME)/video.mp4"; \
	   fi; \
	 fi; \
	 test -f "$$old" || { echo "migrate-video: 前の版の動画 $$old が無い（前の版で make migrate-baseline MIGRATE_VIDEO=1 を流すか OLD= を渡す）"; exit 2; }; \
	 $(MAKE) --no-print-directory flow-video FLOW=$(FLOW) || exit 1; \
	 "$(ENGINE)/bin/fge" migrate video --old "$$old" --new "debug/video/$(TAPE_NAME).mp4" --out "debug/migrate/$(TAPE_NAME).sbs.mp4" --tape "debug/video/$(TAPE_NAME)/tape.json"
