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

# FlowVideo が書いたコマと音（$(1) のフォルダ）を H.264 + AAC の mp4（$(2)）に束ねるシェルの 1 文。映像の旗は $(3)、音の旗は $(4)。
# GPU で塗れた時は frames.mkv（幅と高さは engine が偶数にそろえる）、塗れない時は連番 PNG（縦の design は 540×1169 のように奇数のまま）。
# WhyNot: crop を外さない — SoftRaster で塗った連番 PNG は奇数のままで、yuv420p の H.264 は幅と高さが偶数でないと ffmpeg が書かずに止まる。
flow-mp4 = fps=$$(cat $(1)/fps.txt); \
	if [ -f $(1)/frames.mkv ]; then frames="-i $(1)/frames.mkv"; else frames="-framerate $$fps -i $(1)/f%04d.png"; fi; \
	ffmpeg -y -loglevel error $$frames -f f64be -ar 44100 -ac 2 -i $(1)/audio.f64 \
	  -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2" $(3) -r $$fps $(4) -shortest -movflags +faststart $(2)
# テープ（make tape）の符号化: 字の頁が続くノベル向けに小さく（雨の降る 540×1170 の画面で 10 分 40 MB ほど・字は crf 20 と見分けがつかない）。
# 置き場（GitHub）は 1 ファイル 100 MB まで。bin/fge tape publish は 95 MB を超えた動画を同じ設定で縮めてから置く（go/internal/tape の ShrinkVideoArgs とそろえる）。
# WhyNot: crf 20 に戻さない — 雨や粒が動く画面は 1 分 75 MB になり、4 分で GitHub に置けなくなる。
# WhyNot: -preset veryfast にしない — 同じ大きさなら背景の雨がつぶれて汚い（字はどれも読める）。
TAPE_X264 ?= -c:v libx264 -preset slow -crf 32 -tune animation -pix_fmt yuv420p
TAPE_AAC ?= -c:a aac -b:a 96k
# 紹介の動画（make flow-video・showcase-video）の符号化: X に載せる物なので大きさより画質（X は 1 本 512 MB まで）。
VIDEO_X264 ?= -c:v libx264 -pix_fmt yuv420p -crf 20
VIDEO_AAC ?= -c:a aac -b:a 192k

# 見せ場をつないだ紹介の動画（e2e/showcase.flow → debug/video/showcase.mp4）。
# コマと音は FlowVideo が実機と同じ 1 フレームで書き、ここで mp4 に束ねる。
.PHONY: showcase-video
showcase-video:
	@$(MAKE) --no-print-directory flow-video FLOW=e2e/showcase.flow

# テープの頁（make tape FLOW=e2e/tape.flow → debug/tape/tape/index.html）。
# ① FlowVideo が flow を流してコマ・音（debug/video/<名前>）と tape.json を書き、② showcase-video と同じ ffmpeg で video.mp4 に束ね、
# ③ bin/fge tape が strip.jpg と index.html を作る。debug/tape/<名前> には頁に要る物（tape.json・video.mp4・strip.jpg・index.html と、縦の分の tape-phone.json・video-phone.mp4・strip-phone.jpg）だけを置く。
# tape.json が書けない（同じ名前の mark・2 つ以上の .yarn にまたがる flow）時は FlowVideo が理由を出し、ここで止める。
# flow が途中で止まった時も、そこまでの頁を作ってから止まった印（終了コード 1）を返す。
# 分岐: 結末ごとに 1 本ずつ flow を書き（同じ始まりから別の選択肢を選ぶ）、make tape FLOWS="e2e/a.flow e2e/b.flow" で
# まとめて撮る。bin/fge tape --group が、選んだ道が分かれた所を分岐にして、頁のグラフの箱から隣の頁へつなぐ。
# 画面: 既定は縦（スマホを縦に持った時・FLOW_VIEW=phone）の 1 回だけ撮り、tape.json・video.mp4 に置く（頁は切り替えのボタンを出さない）。
# このゲームは design が縦で、PC の画面も同じ縦の組みを真ん中に置くだけなので、PC の分を別に撮らない。
# WhyNot: 既定を pc（同じ 540×1170・マウス）にしない — テープはスマホで見てもらう頁で、指の入力（区分 Small・Touch）の見え方をそろえる。
# 2 つ並べて比べたい時だけ TAPE_VIEWS="phone pc"（縦の分は debug/video/<名前>-phone で撮り tape-phone.json・video-phone.mp4 に、PC の分は tape.json・video.mp4 に置き、頁は縦で開いて上のボタンで替える）。
# はじめから遊ぶ: 既定でゲームのブラウザ版も書き出し（bin/fge export-web）、各テープの play/ に写す。頁の上の「はじめから遊ぶ」がタイトルから開く。
# 後始末: mp4 に束ねたら元のコマ（debug/video/<名前>[-phone]・1 本で 8 GB を超えることがある）を消す。残すなら TAPE_KEEP_FRAMES=1
# （flow が途中で止まった時も残す）。同じ名前を撮り直す時は、前の debug/video・debug/tape の出力を先に消して置き換える。
# 書き出さないなら TAPE_PLAY=0（頁はボタンを出さない）。書き出しの作業フォルダと出口は TAPE_WEB（既定 /tmp/fge-tape-web/<ゲームのフォルダ名>）。
TAPE_NAME = $(basename $(notdir $(FLOW)))
TAPE_VIEWS = phone
TAPE_PLAY = 1
TAPE_KEEP_FRAMES = 0
# 速さ: 書き出しは --reuse で、写すゲームの全部・engine の束と jar・bin/fge の指紋が前と同じなら組まずに使い回す（組み直させるなら TAPE_WEB_REUSE=0）。
# 書き出しは録画と並べて裏で走らせ（ログは $(TAPE_WEB)/export.log）、録画は分岐の flow を並べて走らせる。同時に走るのは書き出しを含めて TAPE_JOBS 本まで（既定 2）。
# 今までの順（書き出しを済ませてから 1 本ずつ撮る）は TAPE_JOBS=1。並べても同じ flow から同じ tape.json とハッシュが出る（JVM も書き出し先も別）。
# Ctrl-C と撮れなかった時は、裏の書き出しと録画を子の java・ffmpeg ごと止める（tape-kill）。
# WhyNot: 並べる前に jar を作っておく — jar を作る時にゲームの語彙（assets/talk/vocab*.json）を書き直すので、書き出しが写す途中の物を拾う。
# WhyNot: 既定を 3 本以上にしない — 録画は GPU で塗り、ffmpeg も書き出しの TeaVM も全部のコアを使うので、負荷の高い機械で他の作業を止める。
TAPE_JOBS = 2
TAPE_WEB_REUSE = 1
# WhyNot: 書き出しの作業フォルダをゲームの下（既定の build/web-export）にしない — 組んだ所のパスが wasm に残り、公開した頁からユーザー名が読める。
TAPE_WEB = /tmp/fge-tape-web/$(notdir $(CURDIR))
tape-play = $(if $(filter 1,$(TAPE_PLAY)),--play $(TAPE_WEB)/out)
tape-export = "$(ENGINE)/bin/fge" export-web . --out "$(TAPE_WEB)/out" --work "$(TAPE_WEB)/work" $(if $(filter 1,$(TAPE_WEB_REUSE)),--reuse)
# WhyNot: Windows（bash が無い）で jar を作り置かず並べもしない — headless-run が無く、入口ごとに flix run で組み直すので、並べると組むのが重なる。
tape-jar = $(if $(filter 1,$(FGE_NO_BASH)),:,$(HEADLESS_RUN) --build-only)
tape-jobs = $(if $(filter 1,$(FGE_NO_BASH)),1,$(TAPE_JOBS))
# WhyNot: kill を pid 1 つに送るだけにしない — bin/fge は fge-go へ exec し、その子の java（TeaVM・録画）は親が死んでも残って作業フォルダに書き続ける。
tape-kill = killtree() { for c in $$(pgrep -P $$1); do killtree $$c; done; kill $$1 2>/dev/null; }; for p in $(1); do killtree $$p; done
# 1 本の flow を撮って debug/tape/<名前> に置く（サブシェルで流す）。終わりの番号: 0 撮れた / 1 flow が途中で止まった / 2 撮れなかった。
# WhyNot: flow が途中で止まっても 2 にしない — そこまでの頁を作ってから、最後に終了コード 1 を返す（code）。
tape-shoot = code=0; rm -rf debug/video/$(2) debug/video/$(2)-phone debug/tape/$(2); mkdir -p debug/tape/$(2); \
	for v in $(TAPE_VIEWS); do \
	  case "$$v" in pc) src=debug/video/$(2); suf="";; phone) src=debug/video/$(2)-phone; suf=-phone;; \
	    *) echo "tape: TAPE_VIEWS に並べるのは phone と pc（$$v は知らない）"; exit 2;; esac; \
	  test "$(words $(TAPE_VIEWS))" -gt 1 || suf=""; \
	  FLOW=$(1) FLOW_OUT=$$src FLOW_VIEW=$$v $(HEADLESS_RUN) FlowVideo.play || code=1; \
	  test -f $$src/tape.json || { echo "tape: $$src/tape.json を書けなかった"; exit 2; }; \
	  cp $$src/tape.json debug/tape/$(2)/tape$$suf.json; \
	  { $(call flow-mp4,$$src,debug/tape/$(2)/video$$suf.mp4,$(TAPE_X264),$(TAPE_AAC)); } || exit 2; \
	  test "$(TAPE_KEEP_FRAMES)" = 1 -o "$$code" = 1 || rm -rf $$src; \
	done; exit $$code
.PHONY: tape
tape:
	@test -n "$(TAPE_NAME)$(FLOWS)" || { echo "make tape FLOW=e2e/<名前>.flow（分岐は FLOWS=\"e2e/a.flow e2e/b.flow\"）"; exit 2; }
	@test -z "$(FLOW)" -o -z "$(FLOWS)" || { echo "tape: FLOW と FLOWS はどちらか 1 つ（分岐は FLOWS だけに並べる）"; exit 2; }
	@dup=$$(for f in $(FLOWS); do basename $$f .flow; done | sort | uniq -d); \
	 test -z "$$dup" || { echo "tape: FLOWS に同じ名前の flow がある: $$dup（debug/tape/<名前> が重なるので名前を分ける）"; exit 2; }
	@for v in $(TAPE_VIEWS); do case "$$v" in pc|phone) ;; *) echo "tape: TAPE_VIEWS に並べるのは phone と pc（$$v は知らない）"; exit 2;; esac; done
	@jobs=$(tape-jobs); t0=$$(date +%s); pids=""; ew=""; \
	 trap '$(call tape-kill,$$(pgrep -P $$$$)); exit 130' INT TERM; \
	 $(tape-jar) || { echo "tape: 録画の jar を作れなかった"; exit 1; }; \
	 mkdir -p "$(TAPE_WEB)"; \
	 if [ "$(TAPE_PLAY)" = 1 ]; then \
	   if [ "$$jobs" -gt 1 ]; then \
	     echo "tape: ブラウザ版の書き出しを録画と並べて走らせる（ログ $(TAPE_WEB)/export.log）"; \
	     ( $(tape-export) ) > "$(TAPE_WEB)/export.log" 2>&1 & ew=$$!; \
	   else \
	     $(tape-export) || { echo "tape: ブラウザ版を書き出せなかった（書き出さずに撮るなら TAPE_PLAY=0）"; exit 1; }; \
	   fi; \
	 fi; \
	 names=""; \
	 for f in $(or $(FLOWS),$(FLOW)); do \
	   n=$$(basename $$f .flow); names="$$names $$n"; \
	   while :; do busy=0; for p in $$pids $$ew; do kill -0 $$p 2>/dev/null && busy=$$((busy+1)); done; \
	     [ $$busy -lt $$jobs ] && break; sleep 1; done; \
	   rm -f "$(TAPE_WEB)/shoot-$$n.code"; \
	   { ( $(call tape-shoot,$$f,$$n) ); echo $$? > "$(TAPE_WEB)/shoot-$$n.code"; } 2>&1 | sed "s/^/[$$n] /" & pids="$$pids $$!"; \
	 done; \
	 for p in $$pids; do wait $$p; done; \
	 code=0; for n in $$names; do c=$$(cat "$(TAPE_WEB)/shoot-$$n.code" 2>/dev/null || echo 2); \
	   if [ "$$c" -ge 2 ]; then echo "tape: $$n を撮れなかった"; $(call tape-kill,$$ew); exit 1; fi; \
	   test "$$c" = 0 || code=1; done; \
	 echo "tape: 録画まで $$(( $$(date +%s) - t0 )) 秒"; \
	 if [ -n "$$ew" ]; then \
	   wait $$ew || { tail -30 "$(TAPE_WEB)/export.log"; echo "tape: ブラウザ版を書き出せなかった（ログ $(TAPE_WEB)/export.log・書き出さずに撮るなら TAPE_PLAY=0）"; exit 1; }; \
	   grep '^export-web:' "$(TAPE_WEB)/export.log"; \
	 fi; \
	 if [ -n "$(FLOWS)" ]; then \
	   dirs=""; for n in $$names; do dirs="$$dirs debug/tape/$$n"; done; \
	   "$(ENGINE)/bin/fge" tape --group $$dirs $(tape-play) || exit 1; \
	 else \
	   "$(ENGINE)/bin/fge" tape --dir debug/tape/$(TAPE_NAME) $(tape-play) || exit 1; \
	 fi; \
	 echo "tape: $$(( $$(date +%s) - t0 )) 秒"; \
	 exit $$code

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
