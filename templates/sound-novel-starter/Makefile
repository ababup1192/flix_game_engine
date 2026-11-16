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
SHOTS := title nvl adv choice eaves studio invite ending still hold log load settings credits

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
	@$(MAKE) --no-print-directory flow-video FLOW=e2e/showcase.flow

# テープの頁（make tape FLOW=e2e/tape.flow → debug/tape/tape/index.html）。
# ① FlowVideo が flow を流してコマ・音（debug/video/<名前>）と tape.json を書き、② showcase-video と同じ ffmpeg で video.mp4 に束ね、
# ③ bin/fge tape が strip.jpg と index.html を作る。debug/tape/<名前> には頁に要る物（tape.json・video.mp4・strip.jpg・index.html）だけを置く。
# tape.json が書けない（同じ名前の mark・2 つ以上の .yarn にまたがる flow）時は FlowVideo が理由を出し、ここで止める。
# flow が途中で止まった時も、そこまでの頁を作ってから止まった印（終了コード 1）を返す。
# 分岐: 結末ごとに 1 本ずつ flow を書き（同じ始まりから別の選択肢を選ぶ）、make tape FLOWS="e2e/a.flow e2e/b.flow" で
# まとめて撮る。bin/fge tape --group が、選んだ道が分かれた所を分岐にして、頁のグラフの箱から隣の頁へつなぐ。
TAPE_NAME = $(basename $(notdir $(FLOW)))
# WhyNot: flow が途中で止まっても exit しない — そこまでの頁を作ってから、最後に終了コード 1 を返す（code）。
tape-shoot = rm -rf debug/video/$(2) debug/tape/$(2); mkdir -p debug/tape/$(2); \
	FLOW=$(1) FLOW_OUT=debug/video/$(2) $(HEADLESS_RUN) FlowVideo.play || code=1; \
	test -f debug/video/$(2)/tape.json || { echo "tape: debug/video/$(2)/tape.json を書けなかった"; exit 1; }; \
	cp debug/video/$(2)/tape.json debug/tape/$(2)/tape.json; \
	{ $(call flow-mp4,debug/video/$(2),debug/tape/$(2)/video.mp4); } || exit 1
.PHONY: tape
tape:
	@test -n "$(TAPE_NAME)$(FLOWS)" || { echo "make tape FLOW=e2e/<名前>.flow（分岐は FLOWS=\"e2e/a.flow e2e/b.flow\"）"; exit 2; }
	@test -z "$(FLOW)" -o -z "$(FLOWS)" || { echo "tape: FLOW と FLOWS はどちらか 1 つ（分岐は FLOWS だけに並べる）"; exit 2; }
	@dup=$$(for f in $(FLOWS); do basename $$f .flow; done | sort | uniq -d); \
	 test -z "$$dup" || { echo "tape: FLOWS に同じ名前の flow がある: $$dup（debug/tape/<名前> が重なるので名前を分ける）"; exit 2; }
	@code=0; \
	 if [ -n "$(FLOWS)" ]; then \
	   dirs=""; \
	   for f in $(FLOWS); do n=$$(basename $$f .flow); $(call tape-shoot,$$f,$$n); dirs="$$dirs debug/tape/$$n"; done; \
	   "$(ENGINE)/bin/fge" tape --group $$dirs || exit 1; \
	 else \
	   $(call tape-shoot,$(FLOW),$(TAPE_NAME)); \
	   "$(ENGINE)/bin/fge" tape --dir debug/tape/$(TAPE_NAME) || exit 1; \
	 fi; \
	 exit $$code

# 立ち絵と小物（assets/novel.cast.json）の絵の登録と縦横の比を見る（読むだけ・標準の python3 で足りる）。
# 元の絵を縮めて縁を埋めるのは python3 art/cast/prepare.py <元の絵の置き場>（Pillow が要る）。
.PHONY: lint-cast
lint-cast:
	python3 art/cast/lint.py

lint: lint-cast

# 1 本の flow を動画に（make flow-video FLOW=e2e/<名前>.flow か NAME=<名前> → debug/video/<名前>.mp4。コマ・音・tape.json は debug/video/<名前>/）。
FLOW ?= $(if $(NAME),e2e/$(NAME).flow)
.PHONY: flow-video
flow-video:
	@test -n "$(TAPE_NAME)" || { echo "使い方: make flow-video FLOW=e2e/<名前>.flow（か NAME=<名前>）"; exit 2; }
	rm -rf "debug/video/$(TAPE_NAME)"
	FLOW=$(FLOW) FLOW_OUT=debug/video/$(TAPE_NAME) $(HEADLESS_RUN) FlowVideo.play
	@$(call flow-mp4,debug/video/$(TAPE_NAME),debug/video/$(TAPE_NAME).mp4)
	@echo "rendered: debug/video/$(TAPE_NAME).mp4"

# ── 移行の突き合わせ（engine の docs/migrate-diff.md）──
# 前の版（git worktree に出した古いコミット）で make migrate-baseline、新しい版で make migrate-new を流すと、
# 同じ flow の記録（tape.json・world の層のコマ・古いセーブの読み戻し）を bin/fge migrate diff が突き合わせる。
#   make migrate-baseline   前の版の記録を debug/migrate/baseline に撮る（flow ごとの video.mp4 も）。基準が既にあれば止まる（撮り直すなら MIGRATE_OVERWRITE=1）
#   make migrate-baseline BASELINE_FROM=<前の版のゲームのフォルダ>
#                           前の版で撮った debug/migrate/baseline を写すだけ（新しい版で撮らない）
#   make migrate-new        新しい版の記録を debug/migrate/new に撮り、突き合わせる（頁は debug/migrate/report/index.html）
#   make migrate-diff       撮り直さずに突き合わせだけ（migrate-accept.json を書き直した後。MIGRATE_DIFF_FLAGS=--strict など）
#   make migrate-video FLOW=e2e/<名前>.flow [OLD=<前の版のゲームのフォルダ>]
#                           前と後の動画を左右に並べる（debug/migrate/<名前>.sbs.mp4）。OLD が無ければ基準の video.mp4 を前にする。
#                           OLD は flow-video の口があれば FLOW= と NAME= の両方を渡して撮り、無ければ tape FLOW= で撮った debug/tape/<名前>/video.mp4 を使う
# 古いセーブは前の版の flow が終わった時のセーブデータ（baseline/flows/<flow>/saves.json）で、両方の版がそれを読み戻す。
MIGRATE_FLOWS ?= $(wildcard e2e/*.flow)
MIGRATE_DIFF_FLAGS ?=
# WhyNot: 撮る途中の全フレームのコマを記録のフォルダに置かない — 突き合わせに要らない PNG が数千枚残る。debug/video で mp4 に束ねてから消す。
migrate-shoot = rm -rf "debug/migrate/$(1)"; mkdir -p "debug/migrate/$(1)"; \
	for f in $(MIGRATE_FLOWS); do \
	  n=$$(basename $$f .flow); rec="debug/migrate/$(1)/flows/$$n"; rm -rf "debug/video/migrate-$(1)-$$n"; \
	  FLOW=$$f FLOW_OUT="debug/video/migrate-$(1)-$$n" MIGRATE_OUT="$$rec" $(HEADLESS_RUN) FlowVideo.play || code=1; \
	  { $(call flow-mp4,debug/video/migrate-$(1)-$$n,$$rec/video.mp4); } || code=1; rm -rf "debug/video/migrate-$(1)-$$n"; \
	done; \
	for s in debug/migrate/baseline/flows/*/saves.json; do \
	  test -f "$$s" || continue; \
	  MIGRATE_SAVE="$$s" MIGRATE_OUT="debug/migrate/$(1)/saves" MIGRATE_NAME=$$(basename $$(dirname $$s)) $(HEADLESS_RUN) FlowVideo.restore || code=1; \
	done
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
	 code=0; $(call migrate-shoot,baseline); exit $$code
migrate-new:
	@test -d debug/migrate/baseline/flows || { echo "migrate-new: debug/migrate/baseline が無い（前の版で make migrate-baseline を流して BASELINE_FROM= で写す）"; exit 2; }
	@code=0; $(call migrate-shoot,new); "$(ENGINE)/bin/fge" migrate diff debug/migrate/baseline debug/migrate/new $(MIGRATE_DIFF_FLAGS) || code=1; exit $$code
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
	 test -f "$$old" || { echo "migrate-video: 前の版の動画 $$old が無い（前の版で make migrate-baseline を流すか OLD= を渡す）"; exit 2; }; \
	 $(MAKE) --no-print-directory flow-video FLOW=$(FLOW) || exit 1; \
	 "$(ENGINE)/bin/fge" migrate video --old "$$old" --new "debug/video/$(TAPE_NAME).mp4" --out "debug/migrate/$(TAPE_NAME).sbs.mp4" --tape "debug/video/$(TAPE_NAME)/tape.json"
