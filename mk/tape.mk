# tape.mk — flow を動画にしてテープの頁を作る口（make tape・make tape-publish）。FlowVideo を持つゲームの Makefile が game.mk の後に include する。
#
#   include $(subst $(space),\$(space),$(ENGINE))/mk/game.mk
#   include $(subst $(space),\$(space),$(ENGINE))/mk/tape.mk
#
# WhyNot: game.mk に入れない — FlowVideo（src/render/FlowVideo.flix）を持つのはサウンドノベルの系統だけで、
# ほかのゲームの make help に使えない口が並ぶ。写して配らないのは game.mk と同じ理由（engine を直しても既に産まれたゲームへ届かない）。
#
# ゲームごとに変えてよい物（include の前でも後でも ?= を上書きできる）:
#   TAPE_X264 / TAPE_AAC   テープの mp4 の映像と音の旗（flow-mp4 の 3 つ目と 4 つ目）
#   TAPE_AFTER_EXPORT      ブラウザ版を書き出した後に流すシェルの 1 文（書き出し先は $(TAPE_WEB)/out。例: 元の wav を外す）
#   TAPE_VIEWS・TAPE_PLAY・TAPE_JOBS・TAPE_KEEP_FRAMES・TAPE_WEB・TAPE_WEB_REUSE は下の説明

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
TAPE_AFTER_EXPORT ?=
HELP_SRC += "$(ENGINE)/mk/tape.mk"

# テープの頁（make tape FLOW=e2e/tape.flow → debug/tape/tape/index.html）。
# ① FlowVideo が flow を流してコマ・音（debug/video/<名前>）と tape.json を書き、② ffmpeg で video.mp4 に束ね、
# ③ bin/fge tape が strip.jpg と index.html を作る。debug/tape/<名前> には頁に要る物（tape.json・video.mp4・strip.jpg・index.html と、縦の分の tape-phone.json・video-phone.mp4・strip-phone.jpg）だけを置く。
# tape.json が書けない（同じ名前の mark・2 つ以上の .yarn にまたがる flow）時は FlowVideo が理由を出し、ここで止める。
# flow が途中で止まった時も、そこまでの頁を作ってから止まった印（終了コード 1）を返す。
# 分岐: 結末ごとに 1 本ずつ flow を書き（同じ始まりから別の選択肢を選ぶ）、make tape FLOWS="e2e/a.flow e2e/b.flow" で
# まとめて撮る。bin/fge tape --group が、選んだ道が分かれた所を分岐にして、頁のグラフの箱から隣の頁へつなぐ。
# 画面: 既定は縦（スマホを縦に持った時・FLOW_VIEW=phone）の 1 回だけ撮り、tape.json・video.mp4 に置く（頁は切り替えのボタンを出さない）。
# 2 つ並べて比べたい時だけ TAPE_VIEWS="phone pc"（縦の分は debug/video/<名前>-phone で撮り tape-phone.json・video-phone.mp4 に、PC の分は tape.json・video.mp4 に置き、頁は縦で開いて上のボタンで替える）。
# はじめから遊ぶ: 既定でゲームのブラウザ版も書き出し（bin/fge export-web）、各テープの play/ に写す。頁の上の「はじめから遊ぶ」がタイトルから開く。
# 後始末: mp4 に束ねたら元のコマ（debug/video/<名前>[-phone]・1 本で 8 GB を超えることがある）を消す。残すなら TAPE_KEEP_FRAMES=1
# （flow が途中で止まった時も残す）。同じ名前を撮り直す時は、前の debug/video・debug/tape の出力を先に消して置き換える。
# 書き出さないなら TAPE_PLAY=0（頁はボタンを出さない）。書き出しの作業フォルダと出口は TAPE_WEB（既定 /tmp/fge-tape-web/<ゲームのフォルダ名>）。
# 撮り直さない: 撮り終えた flow は debug/tape/<名前>/.shot に入力の指紋（git の HEAD・作業ツリーの差の中身・録画の jar・TAPE_VIEWS と符号化の旗）を書き、
# 次の make tape で指紋が同じなら録画を飛ばして頁だけ作り直す（書き出しが止まった後の打ち直しが数十秒で済む）。撮り直すなら TAPE_FRESH=1。
# 頁だけ: make tape-publish FLOW=…（か FLOWS=…）は録画に触らず、書き出し → TAPE_AFTER_EXPORT → 頁を作る。
TAPE_NAME = $(basename $(notdir $(FLOW)))
TAPE_VIEWS ?= phone
TAPE_PLAY ?= 1
TAPE_KEEP_FRAMES ?= 0
TAPE_FRESH ?= 0
# 速さ: 書き出しは --reuse で、写すゲームの全部・engine の束と jar・bin/fge の指紋が前と同じなら組まずに使い回す（組み直させるなら TAPE_WEB_REUSE=0）。
# 書き出しは録画と並べて裏で走らせ（ログは $(TAPE_WEB)/export.log）、録画は分岐の flow を並べて走らせる。同時に走るのは書き出しを含めて TAPE_JOBS 本まで（既定 2）。
# 今までの順（書き出しを済ませてから 1 本ずつ撮る）は TAPE_JOBS=1。並べても同じ flow から同じ tape.json とハッシュが出る（JVM も書き出し先も別）。
# Ctrl-C と撮れなかった時は、裏の書き出しと録画を子の java・ffmpeg ごと止める（tape-kill）。
# WhyNot: 並べる前に jar を作っておく — jar を作る時にゲームの語彙（assets/talk/vocab*.json）を書き直すので、書き出しが写す途中の物を拾う。
# WhyNot: 既定を 3 本以上にしない — 録画は GPU で塗り、ffmpeg も書き出しの TeaVM も全部のコアを使うので、負荷の高い機械で他の作業を止める。
TAPE_JOBS ?= 2
TAPE_WEB_REUSE ?= 1
# WhyNot: 書き出しの作業フォルダをゲームの下（既定の build/web-export）にしない — 組んだ所のパスが wasm に残り、公開した頁からユーザー名が読める。
TAPE_WEB ?= /tmp/fge-tape-web/$(notdir $(CURDIR))
tape-play = $(if $(filter 1,$(TAPE_PLAY)),--play $(TAPE_WEB)/out)
tape-export = "$(ENGINE)/bin/fge" export-web . --out "$(TAPE_WEB)/out" --work "$(TAPE_WEB)/work" $(if $(filter 1,$(TAPE_WEB_REUSE)),--reuse)
tape-after-export = $(if $(strip $(TAPE_AFTER_EXPORT)),{ $(TAPE_AFTER_EXPORT); },:)
# WhyNot: Windows（bash が無い）で jar を作り置かず並べもしない — headless-run が無く、入口ごとに flix run で組み直すので、並べると組むのが重なる。
tape-jar = $(if $(filter 1,$(FGE_NO_BASH)),:,$(HEADLESS_RUN) --build-only)
tape-jobs = $(if $(filter 1,$(FGE_NO_BASH)),1,$(TAPE_JOBS))
# WhyNot: kill を pid 1 つに送るだけにしない — bin/fge は fge-go へ exec し、その子の java（TeaVM・録画）は親が死んでも残って作業フォルダに書き続ける。
tape-kill = killtree() { for c in $$(pgrep -P $$1); do killtree $$c; done; kill $$1 2>/dev/null; }; for p in $(1); do killtree $$p; done
# 録画の入力の指紋を出すシェルの 1 文（作れない時は空 = いつも撮る）。
# WhyNot: flow のファイルだけを見ない — 台詞（assets の .yarn）・Doc・src のどれが変わっても同じ flow から違う動画になる。git の木と作業ツリーの差で全部を拾う。
# WhyNot: 録画の jar を指紋に入れる — engine を直して lib の束だけが替わった時は git の差に出ない（lib は git の外）。jar は src と lib が変わった時だけ作り直される。
tape-print = jar=build/headless/headless.jar; \
	if [ -f "$$jar" ] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then \
	  { git rev-parse HEAD; git diff HEAD --binary -- . ':!debug' ':!build' 2>/dev/null; \
	    git ls-files -o --exclude-standard -z -- . ':!debug' ':!build' 2>/dev/null | xargs -0 $(SHA256) 2>/dev/null; \
	    $(SHA256) < "$$jar"; echo "views=$(TAPE_VIEWS) x264=$(TAPE_X264) aac=$(TAPE_AAC)"; } | $(SHA256) | cut -c1-32; fi
SHA256 = $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo "shasum -a 256")
# 撮り終えた印が今の指紋と同じで、頁に要る物がそろっているか（$(1) = 名前・$$print = 今の指紋）。
tape-done = ( [ "$(TAPE_FRESH)" != 1 ] && [ -n "$$print" ] && [ "$$(cat debug/tape/$(1)/.shot 2>/dev/null)" = "$$print" ] || exit 1; \
	for v in $(TAPE_VIEWS); do suf=; [ "$(words $(TAPE_VIEWS))" -gt 1 ] && [ "$$v" = phone ] && suf=-phone; \
	  [ -f debug/tape/$(1)/tape$$suf.json ] && [ -f debug/tape/$(1)/video$$suf.mp4 ] || exit 1; done )
# 1 本の flow を撮って debug/tape/<名前> に置く（サブシェルで流す）。終わりの番号: 0 撮れた / 1 flow が途中で止まった / 2 撮れなかった。
# WhyNot: flow が途中で止まっても 2 にしない — そこまでの頁を作ってから、最後に終了コード 1 を返す（code）。
# WhyNot: 途中で止まった flow には撮り終えた印を書かない — 直して打ち直した時に止まった動画を使い回す。
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
	done; \
	if [ "$$code" = 0 ] && [ -n "$(3)" ]; then echo "$(3)" > debug/tape/$(2)/.shot; fi; exit $$code
# 頁を作るシェルの 1 文（録画の後と tape-publish）。
tape-page = if [ -n "$(FLOWS)" ]; then \
	   dirs=""; for f in $(FLOWS); do dirs="$$dirs debug/tape/$$(basename $$f .flow)"; done; \
	   "$(ENGINE)/bin/fge" tape --group $$dirs $(tape-play) || exit 1; \
	 else \
	   "$(ENGINE)/bin/fge" tape --dir debug/tape/$(TAPE_NAME) $(tape-play) || exit 1; \
	 fi
# 裏の書き出しが止まっていれば 1 度だけ知らせる（録画は続ける。撮り終えた物は次の make tape が使い回す）。
tape-export-watch = if [ -n "$$ew" ] && [ -z "$$ewtold" ] && [ -s "$(TAPE_WEB)/export.code" ] && [ "$$(cat "$(TAPE_WEB)/export.code")" != 0 ]; then \
	   ewtold=1; tail -8 "$(TAPE_WEB)/export.log"; \
	   echo "tape: ブラウザ版の書き出しが止まった（ログ $(TAPE_WEB)/export.log）。録画は撮り終えるまで続け、最後に止まる。直したら make tape-publish（録画は撮り直さない）"; fi
.PHONY: tape tape-publish tape-args
tape-args:
	@test -n "$(TAPE_NAME)$(FLOWS)" || { echo "make tape FLOW=e2e/<名前>.flow（分岐は FLOWS=\"e2e/a.flow e2e/b.flow\"）"; exit 2; }
	@test -z "$(FLOW)" -o -z "$(FLOWS)" || { echo "tape: FLOW と FLOWS はどちらか 1 つ（分岐は FLOWS だけに並べる）"; exit 2; }
	@dup=$$(for f in $(FLOWS); do basename $$f .flow; done | sort | uniq -d); \
	 test -z "$$dup" || { echo "tape: FLOWS に同じ名前の flow がある: $$dup（debug/tape/<名前> が重なるので名前を分ける）"; exit 2; }
	@for v in $(TAPE_VIEWS); do case "$$v" in pc|phone) ;; *) echo "tape: TAPE_VIEWS に並べるのは phone と pc（$$v は知らない）"; exit 2;; esac; done

tape: tape-args ## FLOW=e2e/<名前>.flow（か FLOWS="…"） [TAPE_FRESH=1] | flow を動画にしてテープの頁を作る（撮り終えた flow は入力が同じなら撮り直さない）
	@jobs=$(tape-jobs); t0=$$(date +%s); pids=""; ew=""; ewtold=""; \
	 trap '$(call tape-kill,$$(pgrep -P $$$$)); exit 130' INT TERM; \
	 $(tape-jar) || { echo "tape: 録画の jar を作れなかった"; exit 1; }; \
	 print=$$($(tape-print)); \
	 mkdir -p "$(TAPE_WEB)"; rm -f "$(TAPE_WEB)/export.code"; \
	 if [ "$(TAPE_PLAY)" = 1 ]; then \
	   if [ "$$jobs" -gt 1 ]; then \
	     echo "tape: ブラウザ版の書き出しを録画と並べて走らせる（ログ $(TAPE_WEB)/export.log）"; \
	     ( $(tape-export); echo $$? > "$(TAPE_WEB)/export.code" ) > "$(TAPE_WEB)/export.log" 2>&1 & ew=$$!; \
	   else \
	     $(tape-export) || { echo "tape: ブラウザ版を書き出せなかった（書き出さずに撮るなら TAPE_PLAY=0）"; exit 1; }; \
	     $(tape-after-export) || exit 1; \
	   fi; \
	 fi; \
	 names=""; \
	 for f in $(or $(FLOWS),$(FLOW)); do \
	   n=$$(basename $$f .flow); names="$$names $$n"; \
	   if $(call tape-done,$$n); then echo "[$$n] 前に撮った時と入力が同じなので撮らない（撮り直すなら TAPE_FRESH=1）"; echo 0 > "$(TAPE_WEB)/shoot-$$n.code"; continue; fi; \
	   while :; do busy=0; for p in $$pids $$ew; do kill -0 $$p 2>/dev/null && busy=$$((busy+1)); done; \
	     $(tape-export-watch); \
	     [ $$busy -lt $$jobs ] && break; sleep 1; done; \
	   rm -f "$(TAPE_WEB)/shoot-$$n.code"; \
	   { ( $(call tape-shoot,$$f,$$n,$$print) ); echo $$? > "$(TAPE_WEB)/shoot-$$n.code"; } 2>&1 | sed "s/^/[$$n] /" & pids="$$pids $$!"; \
	 done; \
	 while :; do left=0; for p in $$pids; do kill -0 $$p 2>/dev/null && left=1; done; \
	   $(tape-export-watch); [ $$left = 0 ] && break; sleep 1; done; \
	 for p in $$pids; do wait $$p; done; \
	 code=0; for n in $$names; do c=$$(cat "$(TAPE_WEB)/shoot-$$n.code" 2>/dev/null || echo 2); \
	   if [ "$$c" -ge 2 ]; then echo "tape: $$n を撮れなかった"; $(call tape-kill,$$ew); exit 1; fi; \
	   test "$$c" = 0 || code=1; done; \
	 echo "tape: 録画まで $$(( $$(date +%s) - t0 )) 秒"; \
	 if [ -n "$$ew" ]; then \
	   wait $$ew; \
	   [ "$$(cat "$(TAPE_WEB)/export.code" 2>/dev/null)" = 0 ] || { tail -30 "$(TAPE_WEB)/export.log"; echo "tape: ブラウザ版を書き出せなかった（ログ $(TAPE_WEB)/export.log）。直したら make tape-publish で頁だけ作る（録画は撮り直さない・書き出さずに撮るなら TAPE_PLAY=0）"; exit 1; }; \
	   grep '^export-web:' "$(TAPE_WEB)/export.log"; \
	   $(tape-after-export) || exit 1; \
	 fi; \
	 $(tape-page); \
	 echo "tape: $$(( $$(date +%s) - t0 )) 秒"; \
	 exit $$code

tape-publish: tape-args ## FLOW=…（か FLOWS="…"） | 録画に触らず、ブラウザ版の書き出しとテープの頁だけを作り直す（make tape が書き出しで止まった後）
	@for f in $(or $(FLOWS),$(FLOW)); do n=$$(basename $$f .flow); \
	   test -f debug/tape/$$n/tape.json || { echo "tape-publish: debug/tape/$$n/tape.json が無い（先に make tape で撮る）"; exit 2; }; done
	@if [ "$(TAPE_PLAY)" = 1 ]; then \
	   mkdir -p "$(TAPE_WEB)"; \
	   $(tape-export) || { echo "tape-publish: ブラウザ版を書き出せなかった（書き出さずに作るなら TAPE_PLAY=0）"; exit 1; }; \
	   $(tape-after-export) || exit 1; \
	 fi; \
	 $(tape-page)
