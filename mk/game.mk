# game.mk — ゲームの Makefile が include する共通部（run / test / check / 描き出し / status …）。
#
# ここに置くのは「どのゲームでも同じ物」だけ。ゲーム側の Makefile に残るのは
# ENGINE の場所・SHOTS・そのゲーム固有の口だけになる。
#
# WhyNot: 各ゲームへ写して配らない。写すと engine を直しても既に産まれたゲームへ届かず、
# upgrade-game が運ぶのは flix.toml の版と lib/ と agents-pack だけなので Makefile だけが
# 取り残される（実際に写経元から 200 行以上ずれたゲームが出た）。ゲームは既に
# $(ENGINE)/bin/... を直に叩いていて engine 無しでは動かないので、参照に変えても前提は増えない。
#
# 使う側の決まり:
#   include するより前に ENGINE を決めておくこと（-include local.mk → ENGINE ?= ... → include）。
#   SHOTS       … 描き出せる場面の名前（render の使い方に出す）
#   PALETTE     … 色票 JSON のパス。定義したゲームだけ palette の口が生える
#   RENDER_NOTE … render の使い方に足す 1 行（任意）
#
# help の一覧はターゲットの行末の「## 説明」（make help）と「### 説明」（make help-all だけ）から組む（書き方は mk/help.awk の頭）。

# $(wildcard) は空白入りパス (Studio.app 同梱の engine) を扱えないので shell の test で見る
ifeq ($(shell test -e "$(ENGINE)/bin/flix" -o -e "$(ENGINE)/bin/flix.jar" && echo ok),)
$(warning ENGINE が見当たりません ($(ENGINE)) — local.mk に「ENGINE := /path/to/flix_game_engine」を書くか、make <対象> ENGINE=... で指定してください)
endif

# ── OS で変わる物（Windows はラッパ（bash）が無いので、ここだけで分ける）─────────────
#   FLIX         … Flix コンパイラ。macOS/Linux はエンジンリポの bin/flix ラッパ（nix store の flix.jar 解決と JVM フラグ
#                  （-XstartOnFirstThread、test/render の headless）を面倒みる）。Windows は JRE の java で bin/flix.jar を直接叩く
#   HEADLESS_RUN … 描き出しの入口（render-all・render・ゲームの動画のターゲット）を流す前置き。後ろに入口の名前を 1 つ書く
#                  （`$(HEADLESS_RUN) SceneRender.all`）。macOS/Linux は bin/headless-run が jar を 1 回だけ作って
#                  使い回す（src・flix.toml・lib が変わった時だけ作り直す）ので、2 本目からはコンパイルしない。
#                  Windows は今までどおり毎回コンパイルして流す。描き出しでない長い計算（バランスのシミュレーションなど）も
#                  同じ前置きで流せる。深い再帰でスタックが足りなければ `HEADLESS_JAVA_OPTS=-Xss64m $(HEADLESS_RUN) 入口`
#   PLAY_RUN     … 遊ぶ入口。macOS/Linux は描き出しと同じ jar（bin/headless-run）からウィンドウありで流すので、src を変えていない
#                  2 回目からはコンパイルしない（internet_dungeon でウィンドウが開くまで flix run 36 秒 → 0.5 秒）。jar を作れない時は
#                  flix run で続ける（遊ぶのを止めない。描き出しのターゲットは止める）
#   FGE_FLIX_JAR … lint-flixlint が型を見るのに使う flix.jar（FLIXLINT_JAR の既定）
#   lib/cache    … Flix は Maven の取り物を <ゲーム>/lib/cache に決め打ちで置き、無ければ作って取りに行く。make を読む時に 1 回、
#                  共有の置き場（MVN_CACHE・既定は <ユーザーの cache>/flix_game_engine/mvn-cache）への symlink にする
#                  （symlink なら test 1 回で抜ける。移し方は engine の bin/mvn-cache-share.sh）
# WhyNot: lib/cache の symlink を bin/flix に任せない — Studio が同梱する engine の bin/flix は Studio の物で、この前処理を持たない。
# WhyNot: Windows で lib/cache を張らない — symlink は開発者モードでないと張れない。今まで通り lib/cache に取る。
ifeq ($(OS),Windows_NT)
JAVA   ?= java
# -Xss64m: View の式が深く入れ子になると、既定のスタックでは型検査が StackOverflow で落ちる。
# WhyNot: --sun-misc-unsafe-memory-access を付けない — ここの java は Studio が同梱する JRE 21 のことがあり、
# 21 はこの旗を知らず起動しない（版を見て付けるのは bash の bin/flix と headless-run だけ）。
FLIX   := "$(JAVA)" --enable-native-access=ALL-UNNAMED -Xss64m -jar "$(ENGINE)/bin/flix.jar"
HEADLESS_RUN ?= JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint
PLAY_RUN ?= $(FLIX) run
FGE_FLIX_JAR = $(ENGINE)/bin/flix.jar
FGE_NO_BASH := 1
else
FLIX   := "$(ENGINE)/bin/flix"
HEADLESS_RUN ?= JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" FLIX_CMD=$(FLIX) "$(ENGINE)/bin/headless-run"
PLAY_RUN ?= FGE_HEADLESS_FALLBACK=1 FLIX_CMD=$(FLIX) "$(ENGINE)/bin/headless-run" --window main
FGE_FLIX_JAR = $(shell FLIX_PRINT_JAR=1 "$(ENGINE)/bin/flix" 2>/dev/null)
$(shell [ -L lib/cache ] || [ ! -x "$(ENGINE)/bin/mvn-cache-share.sh" ] || "$(ENGINE)/bin/mvn-cache-share.sh" --pkg "$(CURDIR)")
endif

# 検査の道具 bin/fge を決めるシェルの 1 文（後ろで "$$fge" と呼ぶ）。ゲームに配った物を先に使い、無ければ engine の物。
# WhyNot: make を読む時に決めない — make status が bin/fge を配り直すので、流す時に見る。
FGE_PICK = fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"

# engine リポの中のテンプレートだけ、lint の前に engine の規約へのリンクを張る（下の lint-rules-link）。
# WhyNot: 規則の前提は読み込みの時に展開されるので、使う規則より前のここで決める。
ENGINE_ABS := $(abspath $(ENGINE))
ifneq ($(filter $(ENGINE_ABS)/templates/%,$(CURDIR)),)
LINT_RULES_LINK := lint-rules-link
endif

# 窓なしのゲームの常駐（HEADLESS_RESIDENT=1 の時に headless-run が起こす）を落とす。居なければ何もしない。
# WhyNot: render-all・reference-check・compare の最後に成否にかかわらず流すのは、まとめて描く口の後に
# JVM を 1 本抱えたまま寿命が切れるまで待たせないため（1 枚ずつの render は続けて呼ぶので残す）。
RESIDENT_STOP = if [ -x "$(ENGINE)/bin/fge-go" ]; then "$(ENGINE)/bin/fge-go" resident stop --dir . || true; fi

# help・hooks・api・module・mvn-cache-share はエンジンの Makefile と共有（mk/common.mk）。
# include は make の構文でクォートが効かず空白でパスが割れるので、空白を退避して渡す（Studio 同梱の engine は空白を含む）。
FGE_PREFIX := $(ENGINE)/
MVN_CACHE_SHARE := $(ENGINE)/bin/mvn-cache-share.sh
HELP_SRC := "$(ENGINE)/mk/game.mk" "$(ENGINE)/mk/common.mk"
HELP_HEAD = echo "共通のターゲット ($(ENGINE)/mk/game.mk):"
HELP_TAIL = echo ""; echo "make render の場面: $(SHOTS)"; $(if $(RENDER_NOTE),echo "  $(RENDER_NOTE)";) \
	echo "このゲーム固有のターゲットは Makefile の頭のコメントを見る。"
fge_space := $(subst ,, )
include $(subst $(fge_space),\$(fge_space),$(ENGINE))/mk/common.mk

.PHONY: status run debug font-bake test build dist-linux dist-macos dist-windows dist-all check flow flow-vocab render render-all gallery-sounds reference-check reference-update render-budget render-lint lint lint-doc-refs lint-record-wrap lint-flixlint lint-forbid lint-huge-methods lint-rules-link video-entries src check-docs-sync compare agent-eval agent-eval-compare agent-eval-release engine-upgrade web-pages-stage dashboard

##@ 遊ぶ・確かめる
# RUN_SECONDS=N を付けると N 秒でゲームを止める（run・debug。起動して確かめるだけの時。止め忘れでウィンドウが残らない）。
# SHOT=<場面> を付けると、ギャラリーの 1 枚（gallery/<場面>.png）と同じ World から DEBUG の起動で開き、F8 で止めた状態でウィンドウが出る
# （START=shot:<場面>。場面の名前は make render の SHOTS と同じ・App.withShots）。F8 で動き出す。
# WhyNot: kill でゲームの pid だけを止めない — headless-run が java を子として起こすので、子が残る。プロセスの組ごと止める。
# run・debug・render・render-all・check・test・flow の中身は bin/fge（Go）が持ち、ここは別名（Windows は make 無しで bin/fge を打つ）。
# FGE_RUN は、ゲームに配った bin/fge がこれらを持たない古い物なら engine の bin/fge を使う。ENGINE はこの make と同じ engine を渡す。
FGE_RUN = fge=bin/fge; "$$fge" --list 2>/dev/null | grep -qx headless || fge="$(ENGINE)/bin/fge"; ENGINE="$(ENGINE)" "$$fge"
# WITH_RUN_SECONDS = 続く sh の 1 行を、RUN_SECONDS が有れば N 秒でプロセスの組ごと止める形で、無ければそのまま流す（run と debug）。
ifeq ($(RUN_SECONDS),)
WITH_RUN_SECONDS = sh -c
else
WITH_RUN_SECONDS = perl -e '$$t = shift; $$p = fork; if (!$$p) { setpgrp(0, 0); exec @ARGV } $$timed = 0; $$SIG{ALRM} = sub { $$timed = 1; kill "TERM", -$$p; sleep 2; kill "KILL", -$$p }; alarm $$t; waitpid($$p, 0); exit($$timed ? 0 : $$? >> 8)' $(RUN_SECONDS) sh -c
endif
run: ## [SHOT=<場面>] [RUN_SECONDS=N] | ゲームを起動する（SHOT はギャラリーの 1 枚と同じ World から F8 で止めた状態で開く）
	@$(WITH_RUN_SECONDS) '$(FGE_RUN) run $(if $(SHOT),SHOT="$(SHOT)")'

debug: ## [RUN_SECONDS=N] | 保存即反映（watchFile）と F8 を有効にして起動する
	@$(WITH_RUN_SECONDS) '$(FGE_RUN) debug'

# 生成したアトラスはデスクトップの起動（glyphs が auto / used の時）とブラウザの書き出しと同じ形。起動はフォント・大きさ・engine が
# 合う時だけ読み、生成した後に足した字は今まで通り実行中に足す。初回は生成する入口の jar を組むので数分かかる。
# WhyNot: run の前に自動で作らない — 文言に 1 字足すたびに全部の字の作り直し（千字で 20 秒ほど）が起動の前に挟まる。
font-bake: ## | 出しうる字を前もって生成したフォントのアトラスを build/font-atlas/ へ作る（起動で初めて出る字の止まりが消える・新しければ何もしない・初回は数分）
	@"$(ENGINE)/bin/fge" font-bake . build/font-atlas --if-stale

# 前面でワークスペースのサーバー（127.0.0.1:8790）を立ててこのゲームの頁を開く。既に立っていればブラウザだけ開く。
# ゲームに配った bin/fge が dashboard --version を持たない古い物（と bin/fge の無い templates/*）なら engine の bin/fge を使う。
dashboard: ## | ダッシュボードを開く（AI が置いた絵・案を見て選んで返す・Tape の一覧。Ctrl-C で止める）
	@fge=bin/fge; "$$fge" dashboard --version >/dev/null 2>&1 || fge="$(ENGINE)/bin/fge"; "$$fge" dashboard

# check の全文は .test-logs/check.log に落とし、画面には要約だけ出す:
# 成功 = 1 行、失敗 = 最初のエラー全文 + 残りの file:line 一覧 + 処方箋 1 行
# (bin/fge explain-error が整形。全文が欲しいときは QUIET=0 make check かログを開く)。
# check は bin/fge checkd が flixlint の常駐（lint・refactor の索引と同じ）に頼み、答えの版をディスクと比べて使う。
# CHECKD=0 make check で素の check。
check: ## [CHECKD=0] [QUIET=0] | 型検査だけ（一番速い確認。常駐が居れば 2 回目からサブ秒）
	@$(FGE_RUN) check $(if $(CHECKD),CHECKD="$(CHECKD)") $(if $(QUIET),QUIET="$(QUIET)")

# 出力は .test-logs/test.log に落とし、緑なら末尾 5 行だけ見せる。
# make status が「最後にいつ・緑か赤か」をこの記録から読む。
#
# WhyNot: check の常駐（flixlint）に相乗りさせない。テストはゲームのコードを動かすので、固まり・System.exit・ウィンドウの
# 初期化が check と lint の常駐を巻き込む。常駐で組んで別の JVM で流す形も測ったが縮まず、コード生成でヒープが
# 常駐の線を超えた（flixlint の docs/design/checkd-freshness.md の C-T の記録）。
test: ## | テストを headless で流す（記録は .test-logs/）
	@$(FGE_RUN) test

build: ### | パッケージをビルドする
	$(FLIX) build

# 現状 1 画面 (テスト記録・スナップショット・チケット・git)。何も実行しない。
# .claude/settings.json の SessionStart フックがセッション開始時に毎回呼ぶ。
# pack が欠けたゲーム (sync-agents を配りきらない産み方をされた物) はここで配り直す —
# AGENTS.md がセッションの入口を必ずこの target にしているため、最初の 1 回で自己修復できる。
status: ## | 現状 1 画面（テスト記録・絵・チケット・git）。何も実行しない
	@if [ ! -f bin/fge ]; then \
		echo "[status] agents-pack が未配布です (bin/fge が無い) — $(ENGINE) から配り直します"; \
		$(MAKE) -C "$(ENGINE)" sync-agents GAME="$(CURDIR)" || { echo "[status] 配布に失敗 — engine リポで make sync-agents GAME=$(CURDIR) を実行してください"; exit 1; }; \
	fi
	@bin/fge status

# NOTES.md の先頭（引き継ぎ）を短く保つ。古い項を notes/<年-月>.md へ送る（捨てない）。
# コミット時は NOTES.md をステージすると bin/fge precommit が --check で止める。
.PHONY: notes-rotate
notes-rotate: ### | NOTES.md の先頭が長すぎたら古い項を notes/<年-月>.md へ送る（閾値は bin/lint-rules/notes-rotate.json）
	@bin/fge notes-rotate

# engine の版に追随する (flix.toml と lib/ の fpkg 差し替え + pack 配り直し + check)。
# status の「engine 版ズレ」を見たらこれ。中身は bin/fge engine-upgrade（TO= の決まりと、clone した engine で make upgrade-game へ回す所もそちら）。
engine-upgrade: ## [TO=<版>] | engine の版に追随する（status の「engine 版ズレ」を見たらこれ。TO= で新しい版へ上げる・配った engine の時）
	@ENGINE="$(ENGINE)" "$(ENGINE)/bin/fge" engine-upgrade $(if $(TO),TO="$(TO)") $(if $(REFERENCE),REFERENCE=1)

##@ 配る
# 配布物（Linux x64・macOS arm64・Windows x64）。jar は make run と同じ物（headless-run が src の変わった時だけ作り直す）。
# DIST_INCLUDE は実行時に作業場からの相対で読む物（jar の隣へ置く）。DIST_VERSION の既定はゲームの短いコミット。
DIST_INCLUDE ?= assets,project.json
DIST_ARGS = --dir . --include "$(DIST_INCLUDE)" $(if $(DIST_NAME),--name "$(DIST_NAME)") \
	$(if $(DIST_VERSION),--version "$(DIST_VERSION)") $(if $(DIST_OUT),--out "$(DIST_OUT)")
dist-linux: DIST_OS := linux
dist-macos: DIST_OS := macos
dist-windows: DIST_OS := windows
dist-all: DIST_OS := all
dist-linux dist-macos dist-windows dist-all: ## [DIST_OUT=] [DIST_VERSION=] [DIST_NAME=] [DIST_INCLUDE=] | jar・その OS の JRE・起動を build/dist/ へまとめる（置き方は engine の docs/dist.md）
ifeq ($(FGE_NO_BASH),1)
	@echo "[dist] Windows では作れません（jar を作る headless-run が bash）。macOS か Linux で流してください"; exit 1
else
	FLIX_CMD=$(FLIX) "$(ENGINE)/bin/headless-run" --build-only
	@"$(ENGINE)/bin/fge" font-bake . build/font-atlas --if-stale --no-gate \
		|| echo "[dist] フォントのアトラスを作れなかった — 作らずに配る（遊ぶ人の起動で初めて出る字が少し止まる）"
	"$(ENGINE)/bin/fge" dist $(DIST_OS) $(DIST_ARGS)
endif

# ブラウザ版を gh-pages の枝の <DEST>/ へ置いてコミットするまで（push は人。打つ 1 行と手元で開く手順を最後に出す）。
# 書き出しは build/web-pages へ毎回作り直す。音のファイル・sounds・deferred の音が 1 本でもあれば止める（配ってよい音だけなら AUDIO=ok）。
# SRC=<書き出し済みのフォルダ> なら書き出さずにそれを置く。中身と止める理由は $(ENGINE)/bin/web-pages-stage.sh の頭・docs/web-export.md。
web-pages-stage: ## DEST=<サブフォルダ> [SRC=<書き出し済み>] [AUDIO=ok] [BRANCH=] [PAGES_WT=] [NO_BROWSER_CHECK=1] | ブラウザ版を gh-pages の <DEST>/ に置いてコミット（音が残れば止める・push は人）
ifeq ($(FGE_NO_BASH),1)
	@echo "[web-pages-stage] Windows では流せません（bash の道具）。macOS か Linux で流してください"; exit 1
else
	@AUDIO="$(AUDIO)" BRANCH="$(BRANCH)" PAGES_WT="$(PAGES_WT)" NO_BROWSER_CHECK="$(NO_BROWSER_CHECK)" \
		"$(ENGINE)/bin/web-pages-stage.sh" "$(ENGINE)" "$(CURDIR)" "$(DEST)" "$(SRC)"
endif

##@ 描き出し
# 色票を持つゲームでは、入力が変わっていれば先に作り直してから描く。
# パレットなどの作り置きは、project.json の prebuild なら bin/fge が先に作り直す（PALETTE は project.json に移す前のゲームの分）。
render-all: $(PALETTE) ## | 全部 gallery/ へ描き出す（決定的）
	@$(FGE_RUN) render --all

# 1 枚だけ debug/<場面>.png へ描き出す（gallery/ は render-all だけが書く）。
# SHOTS を決めていないゲームは project.json の shots を読む（help の一覧と使い方に出す）。
SHOTS ?= $(shell fge=bin/fge; "$$fge" --list 2>/dev/null | grep -qx headless || fge="$(ENGINE)/bin/fge"; "$$fge" render --list 2>/dev/null)
render: ## SHOT=<場面> | 1 枚だけ debug/<場面>.png へ描き出す（場面の名前は一覧の最後）
	@if [ -z "$(SHOT)" ]; then \
		echo "usage: make render SHOT=<場面>   1 枚だけ debug/<場面>.png へ描き出す"; \
		$(if $(word 2,$(SHOTS)),echo "       make render SHOT=\"$(word 1,$(SHOTS)) $(word 2,$(SHOTS))\"  何枚か";) \
		echo "       make render-all           全部 gallery/ へ描き出す"; \
		echo "  場面: $(SHOTS)"; \
		$(if $(RENDER_NOTE),echo "  $(RENDER_NOTE)";) \
		exit 1; \
	fi
	@$(FGE_RUN) render SHOT="$(SHOT)"

# 音を目視できる 1 枚にする (debug/sounds.png と、BGM の WAV があれば debug/music.png)。
# 1 音 1 段で、波形とスペクトログラムに名前・長さ・サンプルレート・ピーク振幅が付く。
#
# WhyNot: gallery/ へは書かない。描き出した物は git に入れない決まりで、
# debug/ が目視用の置き場だから。
gallery-sounds: ## | 効果音を debug/sounds/ に集め、波形とスペクトログラムを debug/sounds.png に描く
	@$(FGE_PICK); \
	sfx=$$(ls assets/sfx/*.wav 2>/dev/null); \
	if [ -z "$$sfx" ]; then \
		echo "[gallery-sounds] assets/sfx/*.wav がありません (効果音を持つゲームなら先に make render-all)"; \
		exit 1; \
	fi; \
	mkdir -p debug/sounds; \
	cp $$sfx debug/sounds/; \
	"$$fge" waveform debug/sounds --out debug/sounds.png || exit 1; \
	music=$$(ls assets/music/*.wav assets/bgm/*.wav 2>/dev/null); \
	if [ -z "$$music" ]; then \
		echo "[gallery-sounds] BGM の WAV が無いので music.png は作りません"; \
	else \
		"$$fge" waveform $$music --out debug/music.png || exit 1; \
	fi

# 仕上げの確認: 基準の絵との差と、絵の値段（render-budget）。中身は bin/fge reference check。
reference-check: render-all ## | 描き出した絵をリファレンス画像とバイト比較し、絵の値段（render-budget）も見る
	@"$(ENGINE)/bin/fge" reference check; rc=$$?; $(RESIDENT_STOP); exit $$rc

# 基準を作り直す回はキャッシュを写さず全部塗り、前のキャッシュと突き合わせる（docs/render-cache.md）。
# 写した絵を基準にすると、キャッシュが汚れていた時にそれが正しい絵として固まる。
reference-update: export FGE_RENDER_CACHE := verify
reference-update: render-all ## [BUDGET=accept] | いまの gallery をリファレンス画像として更新する
	@"$(ENGINE)/bin/fge" reference update $(if $(BUDGET),BUDGET="$(BUDGET)")

# 絵の値段（1 場面が組んだ描き物の数）を、render-all が gallery/ に残した記録で裁く。描き直さないので軽い。
# 上限は engine の bin/lint-rules/check-render-budget.json・場面ごとの上限は reference/ITEMS.caps.tsv。
render-budget: ### | gallery/ の記録で 1 場面の描き物の数を予算と比べる（描き直さない・render-all の後）
	@$(FGE_PICK); "$$fge" check-render-budget .

# 基準の版（BASE）と今の作業場を同じ描き出しで並べる。SHOTS はゲームの Makefile が全場面の
# 一覧として持っているので、コマンドラインで渡された時だけ絞り込みとして読む。
# WhyNot: ゲームの bin/fge より $(ENGINE)/bin/fge を先に使うのは、このターゲットと道具の版を
# そろえるため（ゲームの bin/fge は sync-agents を流すまで古いままのことがある）。
compare: ## BASE=<ref> [SHOTS="a b" | VIDEOS="x-video"] [BASE_ENGINE=<版|パス>] | 基準の版と今を同じエンジン・同じ描き出しで並べ、差を debug/compare/ へ（index.html つき）
	@test -n "$(BASE)" || { echo "usage: make compare BASE=<ref> [SHOTS=\"a b\" | VIDEOS=\"x-video y-video\"] [BASE_ENGINE=<版|パス>]"; exit 1; }
	@fge="$(ENGINE)/bin/fge"; "$$fge" --list 2>/dev/null | grep -qx compare || fge=bin/fge; \
	"$$fge" compare --base "$(BASE)" \
	  $(if $(filter command line,$(origin SHOTS)),--shots "$(SHOTS)") \
	  $(if $(VIDEOS),--videos "$(VIDEOS)") \
	  $(if $(BASE_ENGINE),--base-engine "$(BASE_ENGINE)"); \
	rc=$$?; $(RESIDENT_STOP); exit $$rc

# パレット（Studio の編集画面が読む写し）。PALETTE を決めたゲームにだけ生えるターゲット。
# render のたびに無条件で走らせると、絵を描くのと同じだけのコンパイル時間を二重に払う。
# 入力の洗い出しに漏れがあったときは `make palette` で無条件に作り直す。
# Palette.write は中身が同じなら書き直さない（unchanged）ので、時刻は make が touch で新しくする
# （そうしないと写しが入力より古いまま残り、make のたびに Palette.write が走る）。
ifdef PALETTE
.PHONY: palette
$(PALETTE): $(PALETTE_DEPS)
	$(HEADLESS_RUN) Palette.write
	@touch $@

palette: ### | Studio が読む色の写し（PALETTE）を無条件に作り直す（PALETTE を決めたゲームだけ）
	$(HEADLESS_RUN) Palette.write
endif

##@ lint
# 検査の束。エンジンの軽い検査はここに前提として並べ、エンジンを上げると増えた検査もそのまま届く。
# ゲームの検査はゲームの Makefile に「lint: lint-view lint-palette」のような前提だけの 1 行で足す
# （make は前提だけの規則を 1 つにまとめる。レシピを書くと makefile-dup が止める）。
lint: render-lint lint-doc-refs lint-record-wrap lint-forbid $(if $(wildcard lint/rules.flix),lint-flixlint) ## | エンジンの軽い検査（render-lint・lint-doc-refs・lint-record-wrap・lint-forbid・lint/rules.flix があれば lint-flixlint）＋ゲームの Makefile が足した検査

# 描き出し（render / render-all）が場面ごとに書いた表を後から読み直して止める（描き直さないので軽い・上の lint が束ねる）。
# 字の被り・はみ出しの許す物は bin/lint-rules/text-audit.local.json の allow に理由つき、表の置き場と直し方の 1 行は
# bin/lint-rules/{text-audit,z-audit}.json（ゲームは .local.json で上書き）。表が無ければ見ずに通す。
# 動画の見回りの入口の写し（video-entries）は動画の口が無いゲームでは見ずに通す。
render-lint: $(LINT_RULES_LINK) ### | 描き出しが残した表を読み直す: 字の被り・はみ出し（text-audit）・z の外れ（z-audit）・動画の入口の写し（video-entries --check）
	@$(FGE_PICK); \
	code=0; "$$fge" text-audit --root . || code=1; "$$fge" z-audit --root . || code=1; \
	"$$fge" video-entries --check --root . || code=1; exit $$code

# 文書（docs/**/*.md・NOTES.md・AGENTS.local.md）が指す Mod.name・パス・path:行 が今のリポに在るか（上の lint が束ねる）。
# 古い記録の文書は bin/lint-rules/doc-refs.local.json の skip へ。コミットでは触った .md だけを precommit が見る。
lint-doc-refs: $(LINT_RULES_LINK) ### | docs/**/*.md・NOTES.md・AGENTS.local.md が指す Mod.name・パス・path:行 が実在するか
	@$(FGE_PICK); "$$fge" doc-refs --root .

# 古い書き方を 1 行の正規表現で止める（engine の forbid.json + ゲームの bin/lint-rules/forbid.local.json）。
lint-forbid: $(LINT_RULES_LINK) ### | 古い書き方を 1 行の正規表現で止める（engine の forbid.json + ゲームの forbid.local.json）
	@$(FGE_PICK); "$$fge" forbid --all --root .

# World の形（大きな record を包む・Doc と描く元は Resources へ・一番上の欄の数）と古い除外を見る。
# ゲームの除外は bin/lint-rules/record-wrap.local.json の exemptRules へ理由つき。
lint-record-wrap: $(LINT_RULES_LINK) ### | World の形（大きな record を包む・Doc と描く元は Resources へ・一番上の欄の数）と古い除外
	@$(FGE_PICK); "$$fge" record-wrap --all --root .

# JVM は bytecode が 8,000 バイトを超えるメソッドを JIT しないので、毎コマ通る関数が超えるとインタプリタのまま回る
# （engine の docs/performance.md の 13 節）。大きさはインライン展開の後に決まるので、遊ぶ時と同じ jar を数える。
# WhyNot: lint に束ねない — jar を作り直すと数十秒かかり、保存のたびに流す軽い検査の列に入れられない。
# Windows では流せない（jar を作る headless-run が bash）。
lint-huge-methods: $(LINT_RULES_LINK) ### | JVM が JIT しない大きさ（8,000 バイト超）の関数が無いか（jar を作るので lint には入れていない）
	@FLIX_CMD=$(FLIX) "$(ENGINE)/bin/headless-run" --build-only
	@$(FGE_PICK); "$$fge" huge-methods --root . build/headless/headless.jar

# engine リポの中のテンプレートは規約（bin/lint-rules/<名前>.json）を持たない（生成したゲームには new-game が写す）。
# 無い規約だけ engine の物へのリンクを張り、生成したゲームと同じ形で lint を流す。
# WhyNot: 道具ごとに「無ければ engine の規約を読む」を足さない — 規約を読む所が道具の数（30 余り）だけあり、1 つ漏れると黙ってずれる。
# WhyNot: 写さずにリンクにする — 写すと engine の規約を直しても古いまま残る。リンクは .gitignore で追跡しない。
lint-rules-link: ### | engine リポの中のテンプレートだけ、無い規約を engine の物へリンクする（lint の前提）
	@d=bin/lint-rules; mkdir -p "$$d"; \
	for f in "$(ENGINE_ABS)"/"$$d"/*.json; do \
	  n=$$(basename "$$f"); case "$$n" in *.local.json) continue;; esac; \
	  [ -e "$$d/$$n" ] || ln -s "$$f" "$$d/$$n"; \
	done

# ゲームの lint/rules.flix（依存の向き・View が World を受けない・テストの形）を flixlint で見る。flixlint の版と shim の jar は
# エンジンの hooks.json の checkd.server が決め、bin/fge flixlint-prepare がキャッシュへそろえる。数で止める規則の上限は
# lint/limits/<規則の id>.json（在れば渡す）。FLIXLINT_STAGE=typed で型を見る規則も（遅い）。
# WhyNot: flixlint を submodule で持つゲーム（flixlint/bin/flixlint がある）には定義しない。上限の基準の取り方まで
# そのゲームの Makefile が自前で持っていて、同じ名前の口を 2 つ書くと make が後の方で上書きする。
ifeq ($(wildcard flixlint/bin/flixlint),)
FLIXLINT_STAGE ?= resolved
FLIXLINT_JAR = $(FGE_FLIX_JAR)
lint-flixlint: ### [FLIXLINT_STAGE=typed] | lint/rules.flix の規則（View が World を受けない・依存の向き・テストの形）を型つきの AST で見る（上限は lint/limits/<規則>.json）
	@$(FGE_RUN) lint-flixlint FLIXLINT_STAGE=$(FLIXLINT_STAGE) $(if $(filter command line environment,$(origin FLIXLINT_JAR)),FLIXLINT_JAR=$(FLIXLINT_JAR))
endif

# 規約の配線ずれの軽い検査 (engine 版のうちゲームで見るべき 3 点だけ)。
# pre-commit (bin/fge precommit) が .md / .flix を触ったコミットで呼ぶ。生成はしない。
check-docs-sync: ### | 規約の配線ずれの軽い検査（CLAUDE.md・AGENTS.md の刻印・スキルの実在）
	@ok=1; \
	if ! grep -q '^@AGENTS.md' CLAUDE.md 2>/dev/null; then \
	  echo "[check-docs-sync] NG: CLAUDE.md は @AGENTS.md の 1 行にする (作り直しは engine 側の make sync-agents GAME=$(CURDIR))"; ok=0; \
	fi; \
	if ! head -n 1 AGENTS.md 2>/dev/null | grep -q 'generated by flix_game_engine agents-pack'; then \
	  echo "[check-docs-sync] NG: AGENTS.md に agents-pack の刻印がありません (手書きせず engine 側の sync-agents で作り直す)"; ok=0; \
	fi; \
	for s in $$(grep -o '\.claude/skills/[a-z][a-z0-9-]*' AGENTS.md 2>/dev/null | sed 's|.*/||' | sort -u); do \
	  if [ ! -f ".claude/skills/$$s/SKILL.md" ]; then \
	    echo "[check-docs-sync] NG: AGENTS.md が挙げるスキル $$s が .claude/skills にありません"; ok=0; \
	  fi; \
	done; \
	if [ "$$ok" = "1" ]; then echo "[check-docs-sync] OK"; else exit 1; fi

##@ flow・語彙
# flow（e2e/<名前>.flow）を画面なしで流す。入口はゲームの E2e.play（中身は Flow.Cli.main）。
# 描き出しの jar を使うので、flow を直して流し直すのに Flix を組み直さない（jar は src が変わった時だけ作り直す）。
# 語彙 e2e/vocab.json は毎回書き直す（bin/fge flow check が JVM なしで読む）。
flow: ## FLOW=e2e/<名前>.flow | flow を画面なしで最後まで流す（失敗は行番号つき。読むだけなら bin/fge flow check）
	@[ -n "$(FLOW)" ] || { echo "使い方: make flow FLOW=e2e/<名前>.flow（読むだけなら bin/fge flow check）"; exit 2; }
	@$(FGE_RUN) flow run "$(FLOW)"

flow-vocab: ### | flow の語彙 e2e/vocab.json を書き直す（bin/fge flow check が読む）
	$(HEADLESS_RUN) E2e.vocab

# 会話のシナリオ（assets/talk/*.yarn）の語彙（話し手・タグ・コードが開くノード）を、ゲームの Talk.vocab
# から assets/talk/vocab.json へ書き直す。bin/fge yarn build の check がこれを読む（版 2 の語彙は名前を Doc から集めるので、
# 書き直すのはコードの側の名前（コマンド）を変えた時だけ）。
.PHONY: talk-vocab
talk-vocab: ## | 会話のシナリオの語彙 assets/talk/vocab.json と vocab.std.json を書き直す（bin/fge yarn build が読む）
	$(HEADLESS_RUN) Talk.vocab

# 動画の見回りが流す入口の一覧（bin/lint-rules/video-entries.json の out）を Makefile の動画のターゲットから書き直す。
video-entries: ### | 動画の見回りが流す入口の一覧を Makefile の $(call video,…) から書き直す
	@$(FGE_PICK); "$$fge" video-entries --root .

##@ ゲームの src を引く
# ゲームの src/ の定義を 1 行で引く（make api Q= のゲーム版・正規表現だけの最小版・中身は bin/fge src）。例: make src Q=talkBackdrop
src: ## Q=<名前> | ゲームの src/ の pub 定義を 1 行で引く（.flix を丸読みする前にまずこれ）
	@"$(ENGINE)/bin/fge" src "$(Q)"

##@ エージェントの道具選びを測る
# 文書・スキル・早見表で、何も教えていないエージェントが正しい道具を選べるかを測る。
# お題は agent-eval/*.json（engine.json は engine から配られる共通・それ以外はゲーム固有）。
# claude -p を 1 お題 1 本（読むだけの道具で）走らせ、記録と表を debug/agent-eval/<LABEL>/ へ。
# engine の docs と engine_world/src は --add-dir で読めるようにする（早見表がそこを指すため）。
# WhyNot: heavy の鍵を取らない（bin/fge heavy でも包まない）のは、claude -p は返事を待つ間ほとんど
#   CPU を使わず、鍵を取ると数十分ほかの作業場の check・test・リリースを止めるため。
#   同時に走る claude -p の本数は、fge agent-eval がマシン全体の枠（/tmp/fge-agent-eval.slots・既定 3）で守る。
agent-eval: ### [ONLY=id,…] [LABEL=名前] | 何も教えていない claude にお題（agent-eval/*.json）を渡し、選んだ道具を採点して表に
	@ls agent-eval/*.json >/dev/null 2>&1 || { echo "[agent-eval] agent-eval/*.json がありません（engine 側で make sync-agents GAME=$(CURDIR)）"; exit 1; }
	@$(FGE_PICK); \
	"$$fge" agent-eval $(foreach f,$(wildcard agent-eval/*.json),--tasks $(f)) --add-dir "$(ENGINE)" \
		$(if $(ONLY),--only $(ONLY)) $(if $(LABEL),--label $(LABEL)) $(if $(JOBS),--jobs $(JOBS)) \
		$(if $(REPEAT),--repeat $(REPEAT))

# エンジンの版ごとの測り（リリースの後・make engine-upgrade の後に 1 回）。全部のお題を REPEAT 回流し、
# agent-eval/history/<版>.json（コミットする）に残して 1 つ前の版と比べ、下がったお題を出す。
# make status が最新の版を 1 行に出す。ログは debug/agent-eval/v<版>/。
# WhyNot: make release のゲートに入れないのは、claude を 60 本近く呼んで 20 分ほどかかり、
#   点にもぶれがあるため（止めるのではなく知らせる物）。
AGENT_EVAL_REPEAT ?= 3
agent-eval-release: ### [REPEAT=3] [OVERWRITE=1] | エンジンの版ごとに全部のお題を N 回 → agent-eval/history/<版>.json・前の版と比べる
	@ls agent-eval/*.json >/dev/null 2>&1 || { echo "[agent-eval] agent-eval/*.json がありません（engine 側で make sync-agents GAME=$(CURDIR)）"; exit 1; }
	@ver=$$(sed -n 's/^VERSION *:= *//p' "$(ENGINE)/Makefile" | head -1); \
	test -n "$$ver" || { echo "[agent-eval] $(ENGINE)/Makefile に VERSION が見当たりません"; exit 1; }; \
	$(FGE_PICK); \
	"$$fge" agent-eval $(foreach f,$(wildcard agent-eval/*.json),--tasks $(f)) --add-dir "$(ENGINE)" \
		--repeat $(or $(REPEAT),$(AGENT_EVAL_REPEAT)) --label "v$$ver" \
		--history agent-eval/history --version "$$ver" $(if $(JOBS),--jobs $(JOBS)) $(if $(OVERWRITE),--overwrite)

agent-eval-compare: ### A=<前> B=<後> | 2 回の点・トークン・ターン・読んだ数を並べる
	@test -n "$(A)" -a -n "$(B)" || { echo "usage: make agent-eval-compare A=<前の LABEL> B=<後の LABEL>"; exit 1; }
	@$(FGE_PICK); "$$fge" agent-eval --compare $(A) $(B)

##@ 同じマシンで何本も並んで作業するときの道具 (bin/fge)
##> bin/fge heavy <コマンド...> | 重い処理を枠 3 本で流す（render-all・動画・compare と Makefile の HEAVY_LONG は長い物として枠 1〜2 の 2 本まで・枠 3 は短い物だけ）。--status で持ち主と列・--history で待ちの合計
##> bin/fge use-engine <版|パス> | この作業場の local.mk と lib をそのエンジンへ。--status / --restore
##> bin/fge dashboard post <post.json> | 人に絵・案を見せる（素材ごと main の debug/dashboard/posts へ写す）。返事は bin/fge dashboard inbox・片付けは inbox が出す resolve <id>@<at>
##> bin/fge proposal build <proposal.json> | 案を選んでもらうページ（index.html）を組む。knobs で片付けの残りを数える

# 何も指定せず make と打ったらゲームが起動する（テンプレの元の既定と同じ）。
.DEFAULT_GOAL := run
