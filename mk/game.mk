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
# 常駐 checkd は bash ラッパー (bin/flix) しか起動を知らず、Windows の
# JAVA+flix.jar 経路では落ちる。checkd が教わるまで Windows では素の check を使う。
CHECKD := 0
# -Xss64m: View の式が深く入れ子になると、既定のスタックでは型検査が StackOverflow で落ちる。
FLIX   := "$(JAVA)" -Xss64m -jar "$(ENGINE)/bin/flix.jar"
else
FLIX   := "$(ENGINE)/bin/flix"
endif

.PHONY: help status run debug test build check render render-all gallery-sounds reference-check reference-update loc api src src-index hooks check-docs-sync compare

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
	@echo "  make status             現状 1 画面（テスト記録・絵・チケット・git）。何も実行しない"
	@echo "  make render SHOT=<場面>  1 枚だけ debug/<場面>.png へ描き出す"
	@echo "                          場面: $(SHOTS)"
	@echo "  make render-all         全部 gallery/ へ描き出す（決定的）"
	@echo "  make gallery-sounds     効果音を debug/sounds/ に集め、波形とスペクトログラムを debug/sounds.png に描く"
	@echo "  make reference-check    描き出した絵をリファレンス画像とバイト比較する"
	@echo "  make reference-update   いまの gallery をリファレンス画像として更新する"
	$(if $(PALETTE),@echo "  make palette            Studio が読む色の写し ($(PALETTE)) を無条件に作り直す")
	@echo "  make api Q=<名前>        エンジン API の型・引数を 1 行で引く（ソースを読む前にまずこれ）"
	@echo "  make src Q=<名前>        ゲームの src/ の pub 定義を 1 行で引く（.flix を丸読みする前にまずこれ）"
	@echo "  make src-index          src/ の pub 定義と各ファイル冒頭 doc の 1 行目を debug/src-index.md へ"
	@echo "  make loc                src/ + test/ の .flix 合計行数（上限 3,000 行）"
	@echo "  make engine-upgrade     engine の版に追随する（status の「engine 版ズレ」を見たらこれ）"
	@echo "  make hooks              コミット時のゲートをこの clone に配線する（clone ごとに 1 回）"
	@echo "  make compare BASE=<ref> [SHOTS=\"a b\" | VIDEOS=\"x-video\"]"
	@echo "                          基準の版と今を同じ描き出しで並べ、差を debug/compare/ へ（index.html つき）"
	@echo ""
	@echo "同じマシンで何本も並んで作業するときの道具 (bin/fge):"
	@echo "  bin/fge heavy <コマンド...>   重い処理を鍵 (/tmp/fge-heavy.lock) で 1 本ずつ流す。--status で持ち主と列"
	@echo "  bin/fge use-engine <版|パス>  この作業場の local.mk と lib をそのエンジンへ。--status / --restore"
	@echo ""
	@echo "このゲーム固有の口は Makefile の頭のコメントを見る。"

run:
	$(FLIX) run

debug:
	DEBUG=true $(FLIX) run

# 出力は .test-logs/test.log に落とし、緑なら末尾 5 行だけ見せる。
# make status が「最後にいつ・緑か赤か」をこの記録から読む。
#
# WhyNot: check と同じ常駐に相乗りさせない。常駐の repl は「常駐が全部太りきっても
# 物理メモリの 33% まで」の約束からヒープに蓋がしてあり (checkd/budget.go)、型検査は
# その中に収まるが、テストはコード生成と実行まで同じ repl に乗るので収まらない。
# 16GB・13,000 行での実測: 常駐 8:39 (CPU 49% = GC 待ち) / 素の test 2:20 (CPU 163%)。
# 常駐に乗せたいときだけ CHECKD=1 make test。
test:
	@mkdir -p .test-logs; rm -f .test-logs/test.fail
	@fge=bin/fge; [ -x "$$fge" ] || fge="$(ENGINE)/bin/fge"; \
	if [ "$(CHECKD)" = "1" ] && [ -x "$$fge" ]; then \
		"$$fge" checkd --test . > .test-logs/test.log 2>&1; \
	else \
		JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) test > .test-logs/test.log 2>&1; \
	fi; \
	if [ $$? = 0 ]; then \
		tail -5 .test-logs/test.log; \
	else \
		touch .test-logs/test.fail; tail -40 .test-logs/test.log; exit 1; \
	fi

build:
	$(FLIX) build

# check の全文は .test-logs/check.log に落とし、画面には要約だけ出す:
# 成功 = 1 行、失敗 = 最初のエラー全文 + 残りの file:line 一覧 + 処方箋 1 行
# (bin/fge explain-error が整形。全文が欲しいときは QUIET=0 make check かログを開く)。
# 常駐 (bin/fge checkd) が居れば 2 回目からサブ秒。CHECKD=0 make check で素の check。
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
	else echo "[api] '$(Q)' に当たりなし。$(ENGINE)/docs/module-index.md で別名を探す"; fi

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
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint SceneRender.all

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
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" SHOT="$(SHOT)" $(FLIX) run --entrypoint SceneRender.one

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

reference-check: render-all
	"$(ENGINE)/bin/reference-check.sh"

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
	  $(if $(BASE_ENGINE),--base-engine "$(BASE_ENGINE)")

# 色票（Studio の編集画面が読む写し）。PALETTE を決めたゲームにだけ口が生える。
# render のたびに無条件で走らせると、絵を描くのと同じだけのコンパイル時間を二重に払う。
# 入力の洗い出しに漏れがあったときは `make palette` で無条件に作り直す。
ifdef PALETTE
.PHONY: palette
$(PALETTE): $(PALETTE_DEPS)
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint Palette.write

palette:
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint Palette.write
endif

# 何も指定せず make と打ったらゲームが起動する（テンプレの元の既定と同じ）。
.DEFAULT_GOAL := run
