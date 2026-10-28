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
# Flix コンパイラの呼び方は OS で変える:
#   - macOS/Linux … エンジンリポの bin/flix ラッパ（nix store の flix.jar 解決と JVM フラグ
#     （-XstartOnFirstThread、test/render の headless）を面倒みる）
#   - Windows … ラッパ（bash）が無いので、JRE の java で bin/flix.jar を直接叩く

# $(wildcard) は空白入りパス (Studio.app 同梱の engine) を扱えないので shell の test で見る
ifeq ($(shell test -e "$(ENGINE)/bin/flix" -o -e "$(ENGINE)/bin/flix.jar" && echo ok),)
$(warning ENGINE が見当たりません ($(ENGINE)) — local.mk に「ENGINE := /path/to/flix_game_engine」を書くか、make <対象> ENGINE=... で指定してください)
endif
ifeq ($(OS),Windows_NT)
JAVA   ?= java
# checkd は flix.jar の場所を bash ラッパー (bin/flix) から引くので、Windows の JAVA+flix.jar 経路では
# 引けない。checkd が教わるまで Windows では素の check を使う。
CHECKD := 0
# -Xss64m: View の式が深く入れ子になると、既定のスタックでは型検査が StackOverflow で落ちる。
FLIX   := "$(JAVA)" -Xss64m -jar "$(ENGINE)/bin/flix.jar"
else
FLIX   := "$(ENGINE)/bin/flix"
endif

# 描き出しの入口（render-all・render・ゲームの動画の口）を流す前置き。後ろに入口の名前を 1 つ書く
# （`$(HEADLESS_RUN) SceneRender.all`）。macOS/Linux は bin/headless-run が jar を 1 回だけ作って
# 使い回す（src・flix.toml・lib が変わった時だけ作り直す）ので、2 本目からはコンパイルしない。
# Windows はラッパ（bash）が無いので今までどおり毎回コンパイルして流す。
# 描き出しでない長い計算（バランスのシミュレーションなど）も同じ前置きで流せる。深い再帰で
# スタックが足りなければ `HEADLESS_JAVA_OPTS=-Xss64m $(HEADLESS_RUN) 入口` のように java の旗を足す。
ifeq ($(OS),Windows_NT)
HEADLESS_RUN ?= JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint
else
HEADLESS_RUN ?= JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" FLIX_CMD=$(FLIX) "$(ENGINE)/bin/headless-run"
endif

# 窓なしのゲームの常駐（HEADLESS_RESIDENT=1 の時に headless-run が起こす）を落とす。居なければ何もしない。
# WhyNot: render-all・reference-check・compare の最後に成否にかかわらず流すのは、まとめて描く口の後に
# JVM を 1 本抱えたまま寿命が切れるまで待たせないため（1 枚ずつの render は続けて呼ぶので残す）。
RESIDENT_STOP = if [ -x "$(ENGINE)/bin/fge-go" ]; then "$(ENGINE)/bin/fge-go" resident stop --dir . || true; fi

.PHONY: help status run debug test build dist-linux dist-macos dist-windows dist-all check flow flow-check flow-vocab render render-all gallery-sounds reference-check reference-update render-budget render-lint lint lint-doc-refs lint-record-wrap lint-flixlint video-entries loc api module src src-index hooks check-docs-sync compare agent-eval agent-eval-compare agent-eval-release

# 共通の口の一覧。engine を上げるとここも一緒に新しくなる
# （ゲーム側の Makefile へ写さないので、口が増えても書き足しに回らなくて済む）。
# そのゲーム固有の口は、各 Makefile の頭のコメントを見る。
help:
	@echo "共通の口 ($(ENGINE)/mk/game.mk):"
	@echo "  make run                ゲームを起動する（ウィンドウが開く）"
	@echo "  make debug              保存即反映(watchFile)と F8 を有効にして起動"
	@echo "  make check              型検査だけ（一番速い確認。常駐が居れば 2 回目からサブ秒）"
	@echo "  make test               テストを headless で実行（記録は .test-logs/）"
	@echo "  make build              パッケージをビルドする"
	@echo "  make dist-linux / dist-macos / dist-windows / dist-all  [DIST_OUT=] [DIST_VERSION=] [DIST_NAME=] [DIST_INCLUDE=]"
	@echo "                          jar・その OS の JRE・起動を build/dist/<名前>-<コミット>-<OS>-<CPU>.<tar.gz|zip> へまとめる（置き方は engine の docs/dist.md）"
	@echo "  make status             現状 1 画面（テスト記録・絵・チケット・git）。何も実行しない"
	@echo "  make notes-rotate       NOTES.md の先頭が長すぎたら古い項を notes/<年-月>.md へ送る（閾値は bin/lint-rules/notes-rotate.json）"
	@echo "  make render SHOT=<場面>  1 枚だけ debug/<場面>.png へ描き出す"
	@echo "                          場面: $(SHOTS)"
	@echo "  make render-all         全部 gallery/ へ描き出す（決定的）"
	@echo "  make gallery-sounds     効果音を debug/sounds/ に集め、波形とスペクトログラムを debug/sounds.png に描く"
	@echo "  make reference-check    描き出した絵をリファレンス画像とバイト比較し、絵の値段（render-budget）も見る"
	@echo "  make render-budget      gallery/ の記録で 1 場面の描き物の数を予算と比べる（描き直さない・render-all の後）"
	@echo "  make reference-update   いまの gallery をリファレンス画像として更新する"
	@echo "  make render-lint        描き出しが残した表を読み直す: 字の被り・はみ出し（text-audit）・z の外れ（z-audit）・動画の入口の写し（video-entries --check）"
	@echo "  make lint-doc-refs      docs/**/*.md・NOTES.md・AGENTS.local.md が指す Mod.name・パス・path:行 が実在するか"
	@echo "  make lint-record-wrap   World の形（大きな record を包む・Doc と描く元は Resources へ・一番上の欄の数）と古い除外"
	@echo "  make lint-flixlint      lint/rules.flix の規則（View が World を受けない・依存の向き・テストの形）を型つきの AST で見る（上限は lint/limits/<規則>.json）"
	@echo "  make lint               エンジンの軽い検査（render-lint・lint-doc-refs・lint-record-wrap・lint/rules.flix があれば lint-flixlint）＋ゲームの Makefile が「lint: 口」で足した検査"
	@echo "  make video-entries      動画の見回りが流す入口の一覧を Makefile の \$$(call video,…) から書き直す"
	@echo "  make flow FLOW=e2e/<名前>.flow  flow を画面なしで最後まで流す（失敗は行番号つき。Flix は組み直さない）"
	@echo "  make flow-vocab         flow の語彙 e2e/vocab.json を書き直す（bin/fge flow check が読む）"
	$(if $(PALETTE),@echo "  make palette            Studio が読む色の写し ($(PALETTE)) を無条件に作り直す")
	@echo "  make talk-vocab         会話のシナリオの語彙 assets/talk/vocab.json を書き直す（bin/fge yarn build が読む）"
	@echo "  make api Q=<名前>        エンジン API の型・引数を 1 行で引く（ソースを読む前にまずこれ）"
	@echo "  make module Q=<語>       やりたいこと → エンジンのモジュールを 1 行ずつ引く（自前で書く前にまずこれ）"
	@echo "  make src Q=<名前>        ゲームの src/ の pub 定義を 1 行で引く（.flix を丸読みする前にまずこれ）"
	@echo "  make src-index          src/ の pub 定義と各ファイル冒頭 doc の 1 行目を debug/src-index.md へ"
	@echo "  make loc                src/ + test/ の .flix 合計行数（上限 3,000 行）"
	@echo "  make engine-upgrade     engine の版に追随する（status の「engine 版ズレ」を見たらこれ）"
	@echo "  make hooks              コミット時のゲートをこの clone に配線する（clone ごとに 1 回）"
	@echo "  make compare BASE=<ref> [SHOTS=\"a b\" | VIDEOS=\"x-video\"]"
	@echo "                          基準の版と今を同じエンジン・同じ描き出しで並べ、差を debug/compare/ へ（index.html つき）"
	@echo "                          基準側だけ別のエンジンにするなら BASE_ENGINE=<版|パス>"
	@echo "  make agent-eval [ONLY=id,…] [LABEL=名前]  何も教えていない claude にお題（agent-eval/*.json）を渡し、選んだ道具を採点して表に"
	@echo "  make agent-eval-compare A=前 B=後  2 回の点・トークン・ターン・読んだ数を並べる"
	@echo "  make agent-eval-release [REPEAT=3] [OVERWRITE=1]  エンジンの版ごとに全部のお題を N 回（鍵は取らない）→ agent-eval/history/<版>.json・前の版と比べる"
	@echo ""
	@echo "同じマシンで何本も並んで作業するときの道具 (bin/fge):"
	@echo "  bin/fge heavy <コマンド...>   重い処理を枠 3 本で流す (render-all・動画・compare と Makefile の HEAVY_LONG は長い物として枠 1〜2 の 2 本まで・枠 3 は短い物だけ)。--status で持ち主と列・--history で待ちの合計"
	@echo "  bin/fge use-engine <版|パス>  この作業場の local.mk と lib をそのエンジンへ。--status / --restore"
	@echo "  bin/fge proposal build <proposal.json>  案を選んでもらうページ (index.html) を組む。knobs で片付けの残りを数える"
	@echo ""
	@echo "このゲーム固有の口は Makefile の頭のコメントを見る。"

# 遊ぶ口。macOS/Linux は描き出しと同じ jar（bin/headless-run）から窓ありで流すので、src を変えていない 2 回目からは
# コンパイルしない（internet_dungeon で窓が開くまで flix run 36 秒 → 0.5 秒）。jar を作れない時は flix run で続ける
# （遊ぶのを止めない。描き出しの口は止める）。Windows はラッパ（bash）が無いので今までどおり flix run。
ifeq ($(OS),Windows_NT)
PLAY_RUN ?= $(FLIX) run
else
PLAY_RUN ?= FGE_HEADLESS_FALLBACK=1 FLIX_CMD=$(FLIX) "$(ENGINE)/bin/headless-run" --window main
endif

run:
	$(PLAY_RUN)

debug:
	DEBUG=true $(PLAY_RUN)

# 出力は .test-logs/test.log に落とし、緑なら末尾 5 行だけ見せる。
# make status が「最後にいつ・緑か赤か」をこの記録から読む。
#
# WhyNot: check の常駐（flixlint）に相乗りさせない。テストはゲームのコードを動かすので、固まり・System.exit・窓の
# 初期化が check と lint の常駐を巻き込む。常駐で組んで別の JVM で流す形も測ったが縮まず、コード生成でヒープが
# 常駐の線を超えた（flixlint の docs/design/checkd-freshness.md の C-T の記録）。
test:
	@mkdir -p .test-logs; rm -f .test-logs/test.fail
	@JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) test > .test-logs/test.log 2>&1; \
	if [ $$? = 0 ]; then \
		tail -5 .test-logs/test.log; \
	else \
		touch .test-logs/test.fail; tail -40 .test-logs/test.log; exit 1; \
	fi

build:
	$(FLIX) build

# 配布物（Linux x64・macOS arm64・Windows x64）。jar は make run と同じ物（headless-run が src の変わった時だけ作り直す）。
# DIST_INCLUDE は実行時に作業場からの相対で読む物（jar の隣へ置く）。DIST_VERSION の既定はゲームの短いコミット。
DIST_INCLUDE ?= assets,project.json
DIST_ARGS = --dir . --include "$(DIST_INCLUDE)" $(if $(DIST_NAME),--name "$(DIST_NAME)") \
	$(if $(DIST_VERSION),--version "$(DIST_VERSION)") $(if $(DIST_OUT),--out "$(DIST_OUT)")
dist-linux: DIST_OS := linux
dist-macos: DIST_OS := macos
dist-windows: DIST_OS := windows
dist-all: DIST_OS := all
dist-linux dist-macos dist-windows dist-all:
ifeq ($(OS),Windows_NT)
	@echo "[dist] Windows では作れません（jar を作る headless-run が bash）。macOS か Linux で流してください"; exit 1
else
	FLIX_CMD=$(FLIX) "$(ENGINE)/bin/headless-run" --build-only
	"$(ENGINE)/bin/fge" dist $(DIST_OS) $(DIST_ARGS)
endif

# check の全文は .test-logs/check.log に落とし、画面には要約だけ出す:
# 成功 = 1 行、失敗 = 最初のエラー全文 + 残りの file:line 一覧 + 処方箋 1 行
# (bin/fge explain-error が整形。全文が欲しいときは QUIET=0 make check かログを開く)。
# check は bin/fge checkd が flixlint の常駐（lint・refactor の索引と同じ）に頼み、答えの版をディスクと比べて使う。
# CHECKD=0 make check で素の check。
check:
	@mkdir -p .test-logs
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	if [ "$(CHECKD)" != "0" ] && [ -x "$$fge" ]; then \
		"$$fge" checkd . > .test-logs/check.log 2>&1; code=$$?; \
	else \
		$(FLIX) check > .test-logs/check.log 2>&1; code=$$?; \
	fi; \
	if [ "$(QUIET)" = "0" ] || [ ! -x "$$fge" ]; then \
		cat .test-logs/check.log; \
	else \
		"$$fge" explain-error --status $$code --log .test-logs/check.log < .test-logs/check.log; \
	fi; \
	exit $$code

# ロジックの大きさ。「全部読める大きさ」（上限 3,000 行）を保つための物差し。
loc:
	@find src test -name '*.flix' -print0 | xargs -0 wc -l | tail -1

# エンジン API の型・引数を 1 行で引く ($(ENGINE)/docs/api-digest の grep)。
# 例: make api Q=gradPolygon 。ソースの unzip や丸読みの前にまずこれ。
api:
	@test -n "$(Q)" || { echo "usage: make api Q=<関数名やモジュール名>"; exit 1; }
	@out=$$(grep -h -i -- "$(Q)" "$(ENGINE)/docs/api-digest/"*.md 2>/dev/null | head -40); \
	if [ -n "$$out" ]; then printf '%s\n' "$$out"; \
	else echo "[api] '$(Q)' に当たりなし。make module Q=<やりたいこと> で別名を探す"; fi

# やりたいこと → エンジンのモジュールを 1 行ずつ引く ($(ENGINE)/docs/modules/<分野>.md の grep)。
# 例: make module Q=スクロール 。当たった行に「分野のファイル:行番号」が付く。自前で書く前にまずこれ。
module:
	@test -n "$(Q)" || { echo "usage: make module Q=<やりたいこと・モジュール名の一部>"; exit 1; }
	@# WhyNot: engine.md（engine/src の下請け）を最後に引くのは、ゲームが使う engine_world の行を先に見せるため。
	@out=$$(grep -n -i -F -- "$(Q)" $$(ls "$(ENGINE)"/docs/modules/*.md | grep -v '/engine\.md$$') "$(ENGINE)/docs/modules/engine.md" 2>/dev/null | sed -f "$(ENGINE)/mk/module.sed" | head -40); \
	if [ -n "$$out" ]; then printf '%s\n' "$$out"; \
	else echo "[module] '$(Q)' に当たりなし。別の言い方で引き直すか、分野の目次 $(ENGINE)/docs/module-index.md から分野のファイルを開く"; fi

# ゲームの src/ の地図。pub の定義と各ファイル冒頭 doc の 1 行目を、ファイル別・行番号つきで
# debug/src-index.md へ書く（正規表現だけの最小版・数秒）。.flix を丸読みせずに位置を引くための物。
SRC_INDEX_AWK := $(ENGINE)/mk/src-index.awk
src-index:
	@mkdir -p debug
	@{ echo "# src index ($$(date '+%Y-%m-%d %H:%M'))"; \
	  echo ""; \
	  echo "make src-index の生成物。pub の定義と各ファイル冒頭 doc の 1 行目。手で編集しない。"; \
	  find src -name '*.flix' | sort | xargs awk -v FORMAT=md -f "$(SRC_INDEX_AWK)"; \
	} > debug/src-index.md
	@echo "[src-index] debug/src-index.md ($$(wc -l < debug/src-index.md | tr -d ' ') 行)"

# ゲームの src/ の定義を 1 行で引く（make api Q= のゲーム版）。例: make src Q=talkBackdrop
src:
	@test -n "$(Q)" || { echo "usage: make src Q=<関数名や型名>"; exit 1; }
	@out=$$(find src -name '*.flix' | sort | xargs awk -v FORMAT=flat -f "$(SRC_INDEX_AWK)" | grep -i -- "$(Q)" | head -40); \
	if [ -n "$$out" ]; then printf '%s\n' "$$out"; \
	else echo "[src] '$(Q)' の pub 定義なし。grep -n '$(Q)' -r src で使われ方を探す"; fi

# 色票を持つゲームでは、入力が変わっていれば先に作り直してから描く。
render-all: $(PALETTE)
	$(HEADLESS_RUN) SceneRender.all; rc=$$?; $(RESIDENT_STOP); exit $$rc

# 1 枚だけ debug/<場面>.png へ描き出す（gallery/ は render-all だけが書く）。
render:
	@if [ -z "$(SHOT)" ]; then \
		echo "usage: make render SHOT=<場面>   1 枚だけ debug/<場面>.png へ描き出す"; \
		$(if $(word 2,$(SHOTS)),echo "       make render SHOT=\"$(word 1,$(SHOTS)) $(word 2,$(SHOTS))\"  何枚か";) \
		echo "       make render-all           全部 gallery/ へ描き出す"; \
		echo "  場面: $(SHOTS)"; \
		$(if $(RENDER_NOTE),echo "  $(RENDER_NOTE)";) \
		exit 1; \
	fi
	SHOT="$(SHOT)" $(HEADLESS_RUN) SceneRender.one

# 音を目視できる 1 枚にする (debug/sounds.png と、BGM の WAV があれば debug/music.png)。
# 1 音 1 段で、波形とスペクトログラムに名前・長さ・サンプルレート・ピーク振幅が付く。
#
# WhyNot: gallery/ へは書かない。描き出した物は git に入れない決まりで、
# debug/ が目視用の置き場だから。
gallery-sounds:
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
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

# 仕上げの確認: 基準の絵との差（reference-check.sh）と、絵の値段（render-budget）。
reference-check: render-all
	@"$(ENGINE)/bin/reference-check.sh" && $(MAKE) --no-print-directory render-budget; rc=$$?; $(RESIDENT_STOP); exit $$rc

# 絵の値段（1 場面が組んだ描き物の数）を、render-all が gallery/ に残した記録で裁く。描き直さないので軽い。
# 上限は engine の bin/lint-rules/check-render-budget.json・場面ごとの上限は reference/ITEMS.caps.tsv。
render-budget:
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; "$$fge" check-render-budget .

# 描き出し（render / render-all）が場面ごとに書いた表を後から読み直して止める（描き直さないので軽い・下の lint が束ねる）。
# 字の被り・はみ出しの許す物は bin/lint-rules/text-audit.local.json の allow に理由つき、表の置き場と直し方の 1 行は
# bin/lint-rules/{text-audit,z-audit}.json（ゲームは .local.json で上書き）。表が無ければ見ずに通す。
# 動画の見回りの入口の写し（video-entries）は動画の口が無いゲームでは見ずに通す。
render-lint:
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	code=0; "$$fge" text-audit --root . || code=1; "$$fge" z-audit --root . || code=1; \
	"$$fge" video-entries --check --root . || code=1; exit $$code

# 文書（docs/**/*.md・NOTES.md・AGENTS.local.md）が指す Mod.name・パス・path:行 が今のリポに在るか（下の lint が束ねる）。
# 古い記録の文書は bin/lint-rules/doc-refs.local.json の skip へ。コミットでは触った .md だけを precommit が見る。
lint-doc-refs:
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; "$$fge" doc-refs --root .

# 検査の束。エンジンの軽い検査はここに前提として並べ、エンジンを上げると増えた検査もそのまま届く。
# ゲームの検査はゲームの Makefile に「lint: lint-view lint-palette」のような前提だけの 1 行で足す
# （make は前提だけの規則を 1 つにまとめる。レシピを書くと makefile-dup が止める）。
lint: render-lint lint-doc-refs lint-record-wrap $(if $(wildcard lint/rules.flix),lint-flixlint)

# World の形（大きな record を包む・Doc と描く元は Resources へ・一番上の欄の数）と古い除外を見る。
# ゲームの除外は bin/lint-rules/record-wrap.local.json の exemptRules へ理由つき。
lint-record-wrap:
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; "$$fge" record-wrap --all --root .

# ゲームの lint/rules.flix（依存の向き・View が World を受けない・テストの形）を flixlint で見る。flixlint の版と shim の jar は
# エンジンの hooks.json の checkd.server が決め、bin/fge flixlint-prepare がキャッシュへそろえる。数で止める規則の上限は
# lint/limits/<規則の id>.json（在れば渡す）。FLIXLINT_STAGE=typed で型を見る規則も（遅い）。
# WhyNot: flixlint を submodule で持つゲーム（flixlint/bin/flixlint がある）には定義しない。上限の基準の取り方まで
# そのゲームの Makefile が自前で持っていて、同じ名前の口を 2 つ書くと make が後の方で上書きする。
ifeq ($(wildcard flixlint/bin/flixlint),)
FLIXLINT_STAGE ?= resolved
ifeq ($(OS),Windows_NT)
FLIXLINT_JAR = $(ENGINE)/bin/flix.jar
else
FLIXLINT_JAR = $(shell FLIX_PRINT_JAR=1 "$(ENGINE)/bin/flix" 2>/dev/null)
endif
lint-flixlint:
	@[ -f lint/rules.flix ] || { echo "lint-flixlint: lint/rules.flix がありません（手本はテンプレートの lint/rules.flix）"; exit 2; }
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	prep=$$("$$fge" flixlint-prepare) || exit 2; eval "$$prep"; \
	"$$FLIXLINT_DIR/bin/flixlint" --flix-jar "$(FLIXLINT_JAR)" --shim "$$FLIXLINT_SHIM" --rules lint/rules.flix \
	  $(if $(wildcard lint/limits),--limits lint/limits) --stage $(FLIXLINT_STAGE) --build-dir build/flixlint src test
endif

# flow（e2e/<名前>.flow）を画面なしで流す。入口はゲームの E2e.play（中身は Flow.Cli.main）。
# 描き出しの jar を使うので、flow を直して流し直すのに Flix を組み直さない（jar は src が変わった時だけ作り直す）。
# 語彙 e2e/vocab.json は毎回書き直す（bin/fge flow check が JVM なしで読む）。
flow:
	@[ -n "$(FLOW)" ] || { echo "使い方: make flow FLOW=e2e/<名前>.flow（読むだけなら bin/fge flow check）"; exit 2; }
	FLOW="$(FLOW)" FLOW_MODE=run $(HEADLESS_RUN) E2e.play

flow-check:
	@[ -n "$(FLOW)" ] || { echo "使い方: make flow-check FLOW=e2e/<名前>.flow"; exit 2; }
	FLOW="$(FLOW)" FLOW_MODE=check $(HEADLESS_RUN) E2e.play

flow-vocab:
	$(HEADLESS_RUN) E2e.vocab

# 動画の見回りが流す入口の一覧（bin/lint-rules/video-entries.json の out）を Makefile の動画の口から書き直す。
video-entries:
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; "$$fge" video-entries --root .

# 基準を作り直す回はキャッシュを写さず全部塗り、前のキャッシュと突き合わせる（docs/render-cache.md）。
# 写した絵を基準にすると、キャッシュが汚れていた時にそれが正しい絵として固まる。
reference-update: export FGE_RENDER_CACHE := verify
reference-update: render-all
	"$(ENGINE)/bin/reference-update.sh"

# 現状 1 画面 (テスト記録・スナップショット・チケット・git)。何も実行しない。
# .claude/settings.json の SessionStart フックがセッション開始時に毎回呼ぶ。
# pack が欠けたゲーム (sync-agents を配りきらない産み方をされた物) はここで配り直す —
# AGENTS.md がセッションの入口を必ずこの target にしているため、最初の 1 回で自己修復できる。
status:
	@if [ ! -f bin/fge ]; then \
		echo "[status] agents-pack が未配布です (bin/fge が無い) — $(ENGINE) から配り直します"; \
		$(MAKE) -C "$(ENGINE)" sync-agents GAME="$(CURDIR)" || { echo "[status] 配布に失敗 — engine リポで make sync-agents GAME=$(CURDIR) を実行してください"; exit 1; }; \
	fi
	@bin/fge status

# NOTES.md の先頭（引き継ぎ）を短く保つ。古い項を notes/<年-月>.md へ送る（捨てない）。
# コミット時は NOTES.md をステージすると bin/fge precommit が --check で止める。
.PHONY: notes-rotate
notes-rotate:
	@bin/fge notes-rotate

# engine の版に追随する (flix.toml と lib/ の fpkg 差し替え + pack 配り直し + check)。
# status の「engine 版ズレ」を見たらこれ。実体は engine 側の upgrade-game。
engine-upgrade:
	@$(MAKE) -C "$(ENGINE)" upgrade-game GAME="$(CURDIR)"

# コミット時のゲート (描き出した絵の混入・矩形だけの View・規約の配線ずれを止める)。
# .git/hooks は git 管理外なので clone ごとに 1 回この配線が要る (status が未配線を知らせる)。
hooks:
	@git config core.hooksPath bin/githooks
	@echo "[hooks] 配線しました: pre-commit = bin/githooks/pre-commit (中身は bin/fge precommit)"

# 規約の配線ずれの軽い検査 (engine 版のうちゲームで見るべき 3 点だけ)。
# pre-commit (bin/fge precommit) が .md / .flix を触ったコミットで呼ぶ。生成はしない。
check-docs-sync:
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

# 基準の版（BASE）と今の作業場を同じ描き出しで並べる。SHOTS はゲームの Makefile が全場面の
# 一覧として持っているので、コマンドラインで渡された時だけ絞り込みとして読む。
# WhyNot: ゲームの bin/fge より $(ENGINE)/bin/fge を先に使うのは、この口と道具の版を
# そろえるため（ゲームの bin/fge は sync-agents を流すまで古いままのことがある）。
compare:
	@test -n "$(BASE)" || { echo "usage: make compare BASE=<ref> [SHOTS=\"a b\" | VIDEOS=\"x-video y-video\"] [BASE_ENGINE=<版|パス>]"; exit 1; }
	@fge="$(ENGINE)/bin/fge"; "$$fge" --list 2>/dev/null | grep -qx compare || fge=bin/fge; \
	"$$fge" compare --base "$(BASE)" \
	  $(if $(filter command line,$(origin SHOTS)),--shots "$(SHOTS)") \
	  $(if $(VIDEOS),--videos "$(VIDEOS)") \
	  $(if $(BASE_ENGINE),--base-engine "$(BASE_ENGINE)"); \
	rc=$$?; $(RESIDENT_STOP); exit $$rc

# 文書・スキル・早見表で、何も教えていないエージェントが正しい道具を選べるかを測る。
# お題は agent-eval/*.json（engine.json は engine から配られる共通・それ以外はゲーム固有）。
# claude -p を 1 お題 1 本（読むだけの道具で）走らせ、記録と表を debug/agent-eval/<LABEL>/ へ。
# engine の docs と engine_world/src は --add-dir で読めるようにする（早見表がそこを指すため）。
# WhyNot: heavy の鍵を取らない（bin/fge heavy でも包まない）のは、claude -p は返事を待つ間ほとんど
#   CPU を使わず、鍵を取ると数十分ほかの作業場の check・test・リリースを止めるため。
#   同時に走る claude -p の本数は、fge agent-eval がマシン全体の枠（/tmp/fge-agent-eval.slots・既定 3）で守る。
agent-eval:
	@ls agent-eval/*.json >/dev/null 2>&1 || { echo "[agent-eval] agent-eval/*.json がありません（engine 側で make sync-agents GAME=$(CURDIR)）"; exit 1; }
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	"$$fge" agent-eval $(foreach f,$(wildcard agent-eval/*.json),--tasks $(f)) --add-dir "$(ENGINE)" \
		$(if $(ONLY),--only $(ONLY)) $(if $(LABEL),--label $(LABEL)) $(if $(JOBS),--jobs $(JOBS)) \
		$(if $(REPEAT),--repeat $(REPEAT))

# エンジンの版ごとの測り（リリースの後・make engine-upgrade の後に 1 回）。全部のお題を REPEAT 回流し、
# agent-eval/history/<版>.json（コミットする）に残して 1 つ前の版と比べ、下がったお題を出す。
# make status が最新の版を 1 行に出す。ログは debug/agent-eval/v<版>/。
# WhyNot: make release のゲートに入れないのは、claude を 60 本近く呼んで 20 分ほどかかり、
#   点にもぶれがあるため（止めるのではなく知らせる物）。
AGENT_EVAL_REPEAT ?= 3
agent-eval-release:
	@ls agent-eval/*.json >/dev/null 2>&1 || { echo "[agent-eval] agent-eval/*.json がありません（engine 側で make sync-agents GAME=$(CURDIR)）"; exit 1; }
	@ver=$$(sed -n 's/^VERSION *:= *//p' "$(ENGINE)/Makefile" | head -1); \
	test -n "$$ver" || { echo "[agent-eval] $(ENGINE)/Makefile に VERSION が見当たりません"; exit 1; }; \
	fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	"$$fge" agent-eval $(foreach f,$(wildcard agent-eval/*.json),--tasks $(f)) --add-dir "$(ENGINE)" \
		--repeat $(or $(REPEAT),$(AGENT_EVAL_REPEAT)) --label "v$$ver" \
		--history agent-eval/history --version "$$ver" $(if $(JOBS),--jobs $(JOBS)) $(if $(OVERWRITE),--overwrite)

agent-eval-compare:
	@test -n "$(A)" -a -n "$(B)" || { echo "usage: make agent-eval-compare A=<前の LABEL> B=<後の LABEL>"; exit 1; }
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; "$$fge" agent-eval --compare $(A) $(B)

# 色票（Studio の編集画面が読む写し）。PALETTE を決めたゲームにだけ口が生える。
# render のたびに無条件で走らせると、絵を描くのと同じだけのコンパイル時間を二重に払う。
# 入力の洗い出しに漏れがあったときは `make palette` で無条件に作り直す。
# Palette.write は中身が同じなら書き直さない（unchanged）ので、時刻は make が touch で新しくする
# （そうしないと写しが入力より古いまま残り、make のたびに Palette.write が走る）。
ifdef PALETTE
.PHONY: palette
$(PALETTE): $(PALETTE_DEPS)
	$(HEADLESS_RUN) Palette.write
	@touch $@

palette:
	$(HEADLESS_RUN) Palette.write
endif

# 会話のシナリオ（assets/talk/*.yarn）の語彙（話し手・タグ・コードが開くノード）を、ゲームの Talk.vocab
# （正はコードの enum）から assets/talk/vocab.json へ書き直す。bin/fge yarn build の check がこれを読む。
.PHONY: talk-vocab
talk-vocab:
	$(HEADLESS_RUN) Talk.vocab

# 何も指定せず make と打ったらゲームが起動する（テンプレの元の既定と同じ）。
.DEFAULT_GOAL := run
