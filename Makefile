# Flix ゲームエンジン モノレポの workspace コマンド
#
# 構成:
#   engine/       ─ 契約層 flix_engine_core（Game/Audio effect・共有描画型・土台型・描画語彙）
#   render_gl/    ─ engine（契約層）を実装する GL バックエンド
#   engine_world/ ─ App/World/UI ランタイム。ゲームが利用する
#   engine_tools/ ─ ヘッドレス描き出し/reference 工具箱。ゲームが利用する
#   engine_full/  ─ 上4つのソースを1つに集めた自己完結の全部入り flix_game_engine（配布物）
#   templates/    ─ 新しいゲームの写し元。各テンプレは `cd templates/<name> && flix ...` で直接動く
#
# Makefile に集約するのは workspace 横断の配布作業だけ:
#   `make sync` … engine の上に載る 3 層の検査用の作業場 (.layers/) を張り、engine_full を
#                  集約して build-pkg し、templates / bench の lib/github/ababup1192/flix_game_engine/<version>/
#                  に相対 symlink を張る (cp ではなく ln -sf)。symlink にすることで engine_full を
#                  作り直せば即座に反映され、例題側で stale な fpkg を持ち回らなくて済む。

# Flix コンパイラは bin/flix ラッパー経由で呼ぶ。ラッパーが devbox (flix.nix) の
# flix コマンドと手動配置 bin/flix.jar のどちらを使うかを解決し、JVM フラグ
# (-XstartOnFirstThread、`test` サブコマンド時の -Djava.awt.headless=true) も
# サブコマンドに応じて自動で付ける。フラグの理由は bin/flix 内のコメント参照。
FLIX      := $(CURDIR)/bin/flix
FLIX_TEST := $(CURDIR)/bin/flix

# 全パッケージ共通のバージョン (lockstep)。sync 先ディレクトリ名や release の
# asset 名に使う。make bump FROM=x TO=y で各 flix.toml と一緒に上げる。
VERSION := 0.108.0

# engine は契約層 (依存ゼロ)。render_gl / engine_world / engine_tools はその上に載る層。
ENGINE_DIR       := engine
RENDER_GL_DIR    := render_gl
ENGINE_WORLD_DIR := engine_world
ENGINE_TOOLS_DIR := engine_tools

# engine の上に載る 3 層は、engine のソースと自分のソースを 1 本の木に束ねて組む
# (make sync-layers が .layers/<層>/ にファイル単位の symlink を張る)。
# WhyNot: engine の fpkg を lib/ に置いて依存させないのは、Flix 0.78 から依存パッケージの名前が
# `use flix_engine_core::X` からしか届かなくなったため。同じソースをルートと engine_full でも
# 1 本の木として組むので、ソースに mount 名を書くと片方が必ず落ちる。
LAYER_PKGS := $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR)
LAYER_ROOT := .layers
LAYER_DIRS := $(addprefix $(LAYER_ROOT)/,$(LAYER_PKGS))

# engine_full は engine / render_gl / engine_world / engine_tools のソースを1つに集めた
# 自己完結の全部入りパッケージ (依存ゼロ・LWJGL ネイティブ自前)。ゲームはこれ1つだけを
# 依存にでき、公開も既存リポ flix_game_engine の Release 1つで完結する
# (推移先の別リポを見に行かない)。配布名は flix_game_engine でリポ名と一致させる。
ENGINE_FULL_DIR       := engine_full
ENGINE_FULL_FPKG_SRC  := $(ENGINE_FULL_DIR)/artifact/package.fpkg
# 配った版（Release の zip・Studio の同梱）は、組み立て（bin/lint-rules/stage-engine.json）で fpkg を
# engine_full.fpkg へ付け替え、Go のソース go/ を運ばない（組んだ bin/fge-go を運ぶ。Release の zip は 5 種・Studio の同梱は 1 本）。
# new-game と sync-fge-go はこの 2 つで、リポの作業コピーか配った版かを見分けて同じ口で動く。
ENGINE_FULL_FPKG_BUNDLED := $(ENGINE_FULL_DIR)/artifact/engine_full.fpkg
IS_BUNDLE := $(shell test -d go || echo 1)
# new-game が種付けに使う fpkg（作業コピーは組んだ package.fpkg・配った版は付け替えた engine_full.fpkg）。
ENGINE_FULL_FPKG_SEED := $(if $(IS_BUNDLE),$(ENGINE_FULL_FPKG_BUNDLED),$(ENGINE_FULL_FPKG_SRC))
ENGINE_FULL_TOML_SRC  := $(ENGINE_FULL_DIR)/flix.toml
# ゲームへ写す束と toml を決めるシェルの 1 文（fpkg= と toml= を置く）。作業コピーは置き場（bin/fpkg-store.sh・make sync-engine-full が入れる）の
# 今のエントリ（無いことは engine-full-fresh が止める）、配った版は付け替えた engine_full.fpkg。
# WhyNot: make の変数で 2 回引かない — 間に sync-engine-full が current を替えると、束と toml を別のエントリから取る。
ifeq ($(IS_BUNDLE),1)
ENGINE_FULL_GAME_FILES = fpkg="$(ENGINE_FULL_FPKG_BUNDLED)"; toml="$(ENGINE_FULL_TOML_SRC)"
else
ENGINE_FULL_GAME_FILES = entry=$$(bin/fpkg-store.sh path engine_full) || { echo "error: 置き場に engine_full がありません。make sync-engine-full" >&2; exit 1; }; \
	fpkg="$$entry/package.fpkg"; toml="$$entry/flix.toml"
endif
ENGINE_FULL_SUBPATH   := lib/github/ababup1192/flix_game_engine/$(VERSION)
ENGINE_FULL_FPKG_NAME := flix_game_engine-$(VERSION).fpkg
ENGINE_FULL_TOML_NAME := flix_game_engine-$(VERSION).toml

# make lint ONLY=a,b・make bench B=a,b の区切り。
comma := ,

# help・hooks・api・module・mvn-cache-share はゲームの mk/game.mk と共有 (mk/common.mk)。違いはエンジンの置き場の前置きだけ。
# make api は digest にあってまだ出していない名前を後ろに知らせる (bin/fge check-api-released)。digest は作業ツリーの
# src/ から作るので未リリースの宣言も載り、ゲームは版を固定した fpkg を引くため、digest を信じて書くとコンパイルで落ちる。
# WhyNot: 2>/dev/null を付けない — この検査は digest の嘘を見えるようにする物で、何も知らせずに死ぬ形は自己矛盾になる (|| true は助言だから止めない)。
FGE_PREFIX :=
MVN_CACHE_SHARE := bin/mvn-cache-share.sh
HELP_SRC := Makefile mk/common.mk
HELP_HEAD = echo "エンジンの作業場のターゲット（ゲームの側は make -C <ゲーム> help）:"
HELP_TAIL = echo ""; echo "絵の差を数で要約するのは bin/fge digest A B（2 枚かフォルダ。目で見る前にまずこれ）"
HELP_ALL_TAIL = echo ""; echo "lint の名前 (make lint ONLY=<名前>,…): $(LINT_NAMES)"; \
	echo "bench の名前 (make bench B=<名前>,…): $(BENCH_NAMES)"
API_AFTER = bin/fge check-api-released "$(Q)" || true

# .flix をファイル単位の symlink で別の木へ並べる（sync-engine-full・sync-root-src・gen-light3d・engine_full_web）。
LINK_FLIX := bin/link-tree.sh --name '*.flix'


##@ 現状・型検査・片付け
# セッション立ち上げの固定費を数百トークンに抑える口。SessionStart フックが毎回呼ぶので
# 実行や変更は一切せず、残っている記録 (.test-logs/ スナップショット チケット git) を集めるだけ。
.PHONY: status
status: ## | 現状 1 画面（テスト記録・スナップショット・チケット・git）。何も実行しない
	@bin/fge status

# 新しい git worktree へ、git の外の依存 (各パッケージの lib・bin/flix.jar・bin/fge-go・build/gl-jar・fpkg) を
# main の作業ツリーから張る。WT を省くとこの作業ツリー自身。張り方の理由は bin/worktree-seed.sh。
.PHONY: worktree-seed
worktree-seed: ## [WT=<worktree>] | 新しい worktree へ git の外の依存（lib・flix.jar・fge-go・gl-jar・fpkg）を main から張る（Studio の worktree も可）
	@bin/worktree-seed.sh "$(or $(WT),$(CURDIR))" $(MAIN)

# flix check を Ctrl-C で中断すると lib/cache/.../*.lock が残り、
# 次回 Maven リゾルバが「他プロセスが取得中」と誤認して無限待ちになる。
# ルートから `find .` すると worktree や巨大な build/ まで stat して数分固まるので、
# 走査先はパッケージ配下だけに絞り、build/ は枝ごと prune する (lock は lib/cache だけにある)。
# 消すのは -delete でなく -exec rm にする: BSD find の -delete は暗黙に -depth を立て、
# すると -prune が無効化されて GB 級の build/ を全部歩き数分固まる (元の 7 分ハングの正体)。
LOCK_DIRS := $(ENGINE_DIR) $(wildcard $(LAYER_DIRS)) $(ENGINE_FULL_DIR) $(wildcard templates/*) $(wildcard bench/*)
# 共有の置き場 (make mvn-cache-share) は find が symlink の先へ降りないので別に歩く。
# WhyNot: 置き場では開いているプロセスの居る lock を消さない — 置き場は他の worktree やゲームの flix と共有で、
# 取っている最中の lock を消すと 2 つのプロセスが同じ .part に書く。
MVN_CACHE_DIR = $(shell bin/mvn-cache-share.sh --print-dir)
.PHONY: clean-locks
clean-locks: ### | flix check の中断で残った Maven cache の *.lock を消す
	@{ find $(LOCK_DIRS) -type d -name build -prune -o \( -path "*/lib/cache/*" -name "*.lock" -print -exec rm -f {} + \) 2>/dev/null; \
	   [ ! -d "$(MVN_CACHE_DIR)" ] || find "$(MVN_CACHE_DIR)" -name '*.lock' 2>/dev/null | while read -r f; do \
	     lsof "$$f" >/dev/null 2>&1 || { rm -f "$$f"; echo "$$f"; }; done; } | awk 'END { print NR " lock(s) removed" }'

# engine の全パッケージ (ルートの src/ の symlink 集) を 1 つの木として型検査する。bin/fge refactor の --apply の後の
# 確かめ (refactor.json の verify) もこれを流す。CHECKD=0 で素の flix check・QUIET=0 で全文。
# WhyNot: 足りない symlink を先に張るのは、パッケージに足したファイルが検査から漏れて緑に見えるため。
.PHONY: check
check: sync-root-src-missing ## [CHECKD=0] [QUIET=0] | engine の全パッケージ（ルートの src/）を型検査する（bin/fge refactor の --apply の後の確かめもこれ）
	@mkdir -p .test-logs
	@if [ "$(CHECKD)" != "0" ]; then bin/fge checkd . > .test-logs/check.log 2>&1; code=$$?; \
	else "$(FLIX)" check > .test-logs/check.log 2>&1; code=$$?; fi; \
	if [ "$(QUIET)" = "0" ]; then cat .test-logs/check.log; \
	else bin/fge explain-error --status $$code --log .test-logs/check.log < .test-logs/check.log; fi; \
	exit $$code

# テンプレ・bench・engine 自身のパッケージの build/ を消す。build/ は呼ぶたび足されるだけで減らないので、
# 消さずにいると engine_world が 2.1GB / 49 万ファイルまで育つ (実測)。テストが速くなる分は 2 割ほどで、主な理由はディスク。
# もう一度 flix を流せば build/ は作り直される (incremental compile は失われる)。
PKG_DIRS := $(ENGINE_DIR) $(LAYER_DIRS)
.PHONY: clean-game-builds
clean-game-builds: ### | templates/*/build/ と bench/*/build/ と engine のパッケージの build/ を消す
	@removed=0; \
	for d in templates/*/build bench/*/build $(addsuffix /build,$(PKG_DIRS)); do \
		if [ -d "$$d" ]; then \
			rm -rf "$$d"; \
			echo "[clean-game-builds] removed $$d"; \
			removed=$$((removed + 1)); \
		fi \
	done; \
	echo "[clean-game-builds] $$removed build dir(s) removed"

# ── テスト ────────────────────────────────────────────────
# 検査・生成の対象になるテンプレ。game-starter だけ外すのは、あれが __NAME__ / __W__ の
# トークンを入れたままの写し元で、そのままではコンパイルできないため
# (トークンを置換したコピー側で make new-game が check / test / render を通す)。
TEMPLATE_DIRS := $(filter-out templates/game-starter,$(wildcard templates/*))
# テストを持つ bench（ALL=1 とリリースの門で流す）。ほかの bench は test/ を持たない。
BENCH_TEST_DIRS := bench/hd2d_town

# make test は engine と 3 層を流す。ALL=1 でテンプレート（TEMPLATE_DIRS）も、JOBS=<数> で並べて流す。
# WhyNot: テンプレートを既定に入れない —— テンプレートのコンパイルがエンジンのテストの約半分を占め、
#   エンジンを直すたびに払うには重い。退行はリリース前の全量と new-game の産声の確認で拾う。
# engine の上の 3 層は .layers/ の作業場で回す (張り方は sync-layers)。
TEST_DIRS := $(ENGINE_DIR) $(LAYER_DIRS)
# 1 つのパッケージ ($$dir) のテストを流す形 (test・test-<名前> が共有する)。
PKG_TEST = (cd "$$dir" && "$(CURDIR)/bin/with-sample-tests" . "$(FLIX_TEST)" test)
# WhyNot: JOBS と ALL をシェルの環境から受けない — 環境に JOBS がある機械で make test が黙って並列になる。コマンド行から来た時だけ効かせる。
TEST_JOBS := $(if $(filter command line,$(origin JOBS)),$(JOBS),1)
# PKGS="<名前…>" は選んだパッケージだけ（名前の引き方は test-% と同じ。bin/fge test-select が束ねる）。
TEST_PKGS := $(if $(filter command line,$(origin PKGS)),$(PKGS))
TEST_PKG_DIR = $(if $(filter $(1),$(LAYER_PKGS)),$(LAYER_ROOT)/$(1),$(if $(wildcard templates/$(1)/flix.toml),templates/$(1),$(if $(wildcard bench/$(1)/flix.toml),bench/$(1),$(if $(wildcard $(1)/flix.toml),$(1)))))
TEST_RUN_DIRS := $(if $(TEST_PKGS),$(foreach p,$(TEST_PKGS),$(call TEST_PKG_DIR,$(p))),$(TEST_DIRS) $(if $(and $(filter command line,$(origin ALL)),$(ALL)),$(TEMPLATE_DIRS) $(BENCH_TEST_DIRS)))
TEST_UNKNOWN_PKGS := $(strip $(foreach p,$(TEST_PKGS),$(if $(call TEST_PKG_DIR,$(p)),,$(p))))

##@ テスト
# 逐次（JOBS=1）は最初の赤で止める。並列はパッケージごとにログを .test-logs/ に残し、赤があれば最後にログの末尾を出す。
# 並列の xargs は -I でなく -n1 + $$0 渡し (BSD xargs の -I は置換後の引数が 255 バイト制限で、
# スクリプトに埋めると「command line cannot be assembled」で 1 本も走らない)。
# 「1 本も走っていないのに green」の偽陽性は実行数ガードで落とす。
# WhyNot: 逐次も xargs -P 1 にしない — xargs は子が非 0 で返しても次へ進み、最初の赤で止まらない。
.PHONY: test
test: sync-layers ## [ALL=1] [JOBS=<数>] | engine と 3 層のテスト（ALL=1 でテンプレートとテストを持つ bench も・JOBS で並べて流す。並列のログは .test-logs/）
	@case "$(TEST_JOBS)" in ''|0|*[!0-9]*) echo "[test] JOBS は 1 以上の数にする（JOBS=$(TEST_JOBS)）"; exit 2;; esac; \
	$(if $(and $(TEST_PKGS),$(filter command line,$(origin ALL))),echo "[test] PKGS と ALL は一緒に使えない"; exit 2;) \
	$(if $(TEST_UNKNOWN_PKGS),echo "[test] 知らないパッケージ（flix.toml が無い）: $(TEST_UNKNOWN_PKGS)"; exit 2;) \
	if [ "$(TEST_JOBS)" = 1 ]; then \
		for dir in $(TEST_RUN_DIRS); do \
			if [ -f "$$dir/flix.toml" ]; then \
				echo "===== $$dir ====="; \
				$(PKG_TEST) || exit 1; \
			fi \
		done; \
		exit 0; \
	fi; \
	mkdir -p .test-logs; \
	$(if $(TEST_PKGS),for dir in $(TEST_RUN_DIRS); do n=$$(printf "%s" "$$dir" | tr / _ | tr -d .); rm -f ".test-logs/$$n.log" ".test-logs/$$n.fail"; done; ,rm -f .test-logs/*.log .test-logs/*.fail;) \
	printf '%s\n' $(TEST_RUN_DIRS) | xargs -P $(TEST_JOBS) -n 1 sh -c ' \
		dir="$$0"; [ -f "$$dir/flix.toml" ] || exit 0; \
		name=$$(printf "%s" "$$dir" | tr / _ | tr -d .); \
		if $(PKG_TEST) > ".test-logs/$$name.log" 2>&1; then \
			echo "[test] PASS $$dir"; \
		else \
			echo "[test] FAIL $$dir"; touch ".test-logs/$$name.fail"; \
		fi'; \
	ran=0; failed=""; for dir in $(TEST_RUN_DIRS); do n=$$(printf "%s" "$$dir" | tr / _ | tr -d .); \
		[ -f ".test-logs/$$n.log" ] && ran=$$((ran + 1)); [ -f ".test-logs/$$n.fail" ] && failed="$$failed .test-logs/$$n"; done; \
	if [ "$$ran" -eq 0 ]; then echo "[test] 1 本も実行されていない (xargs 失敗の疑い)"; exit 1; fi; \
	if [ -n "$$failed" ]; then \
		echo "===== 失敗したパッケージのログ末尾 ====="; \
		for base in $$failed; do echo "--- $$base"; tail -40 "$$base.log"; done; \
		exit 1; \
	fi; \
	echo "[test] all green ($$ran packages)"

# リリースの門の全量（テンプレートを含む・並列）。逐次に倒すのは make release JOBS=1。
OLD_PAR_JOBS := $(or $(TEST_PAR_JOBS),6)# 古い書き方: TEST_PAR_JOBS は 1 リリース後に消す
RELEASE_TEST_JOBS = $(or $(if $(filter command line,$(origin JOBS)),$(JOBS)),$(OLD_PAR_JOBS))
.PHONY: test-release
test-release: ### [JOBS=6] | リリースの門のテスト（make test ALL=1 JOBS=6 と同じ）
	@$(MAKE) --no-print-directory test ALL=1 JOBS=$(RELEASE_TEST_JOBS)

# 古い書き方: test-par・test-all・test-par-all は 1 リリース後に消す
.PHONY: test-all test-par test-par-all
test-all: ### | 古い口（make test ALL=1 を呼ぶ）
	@echo "[test] 次から make test ALL=1"
	@$(MAKE) --no-print-directory test ALL=1
test-par: ### | 古い口（make test JOBS=6 を呼ぶ）
	@echo "[test] 次から make test JOBS=$(OLD_PAR_JOBS)"
	@$(MAKE) --no-print-directory test JOBS=$(OLD_PAR_JOBS)
test-par-all: ### | 古い口（make test ALL=1 JOBS=6 を呼ぶ）
	@echo "[test] 次から make test ALL=1 JOBS=$(OLD_PAR_JOBS)"
	@$(MAKE) --no-print-directory test ALL=1 JOBS=$(OLD_PAR_JOBS)

# 個別テスト: make test-rpg-starter (templates/ を先に探し、無ければルート直下のパッケージ名)
# engine の上の 3 層は .layers/<層> の作業場で流す (make test と同じ。張り方は sync-layers)。
# 出力は .test-logs/ に落とし (並列の make test と同じ命名)、緑なら末尾 5 行だけ見せる。
# make status が「最後にいつ・どれが緑/赤だったか」をこの記録から読む。
# WhyNot: 層を素のフォルダで流さない — 層のフォルダは engine のソースを持たず、use flix_engine_core の名前が解けずに落ちる。
$(addprefix test-,$(LAYER_PKGS)): sync-layers
test-%: ## <名前> | 1 つだけテスト（例: make test-rpg-starter / test-engine / test-engine_world）
	@mkdir -p .test-logs; \
	$(if $(filter $*,$(LAYER_PKGS)),dir="$(LAYER_ROOT)/$*",if [ -d "templates/$*" ]; then dir="templates/$*"; elif [ -d "bench/$*" ]; then dir="bench/$*"; else dir="$*"; fi); \
	name=$$(printf "%s" "$$dir" | tr / _ | tr -d .); \
	rm -f ".test-logs/$$name.fail"; \
	if $(PKG_TEST) > ".test-logs/$$name.log" 2>&1; then \
		tail -5 ".test-logs/$$name.log"; \
	else \
		touch ".test-logs/$$name.fail"; tail -40 ".test-logs/$$name.log"; exit 1; \
	fi

##@ 描き出し
# ── render ────────────────────────────────────────────────
# 各テンプレのギャラリー・効果音などの生成物を一括で描き出し直す。
# 対象は「Makefile に render-all ターゲットを持つ template」だけ。
# テンプレ側の素の `render` は場面名 (SHOT) を要求して失敗するので、ここからは必ず render-all を打つ。
# $$dir のテンプレが render-all を持つか (自前で書いたか game.mk を取り込んだか)。
HAS_RENDER_ALL = [ -f "$$dir/Makefile" ] && grep -qE "^render-all:|mk/game.mk" "$$dir/Makefile"
.PHONY: render-all
render-all: ## | render-all を持つ全 template の生成物を描き出し直す
	@for dir in $(TEMPLATE_DIRS:%=%/); do \
		if $(HAS_RENDER_ALL); then \
			echo "===== $$dir ====="; \
			(cd "$$dir" && make render-all) || exit 1; \
		fi \
	done

# 素の render は打ち間違いなので、どのターゲットを打てばいいかを出して止める（テンプレ側と同じ形）。
.PHONY: render
render: ### | 打ち間違いの受け（使い方を出して止める）
	@echo "usage: make render-all                        全 template を描き出す"; \
	echo "       make render-changed                    git で変更のあった template だけ描き出す"; \
	echo "       make -C templates/<name> render SHOT=<場面>   その template の 1 枚だけ描き出す"; \
	exit 1

# 変更のあったテンプレだけを描き出す。全量 (make render-all) はテンプレのコンパイルが
# コアを使い切って実時間 150 秒かかるが、触ったテンプレ 1 本なら 20〜40 秒で済む。
# 判定は 2 段:
#   1. engine 側 (engine / render_gl / engine_world / engine_tools) に変更があれば全テンプレ。
#      土台の変更はどのテンプレの絵にも効きうるので、ここで絞ると退行を見落とす
#   2. そうでなければ、そのテンプレのディレクトリ配下に変更のある物だけ
# 変更の有無は git status (未追跡ファイルも含む) で見る。
# リリース前と engine を直した後の退行検知には全量が要るので、make render-all の代わりにはしない。
RENDER_ENGINE_DIRS := $(ENGINE_DIR) $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR)
.PHONY: render-changed
render-changed: ## | git で変更のあった template だけ描き出す（engine 側に変更があれば全テンプレ）
	@if [ -n "$$(git status --porcelain -- $(RENDER_ENGINE_DIRS))" ]; then \
		echo "[render-changed] engine 側に変更あり → 全テンプレが対象"; \
		targets="$(TEMPLATE_DIRS)"; \
	else \
		targets=""; \
		for dir in $(TEMPLATE_DIRS); do \
			if [ -n "$$(git status --porcelain -- "$$dir")" ]; then targets="$$targets $$dir"; fi; \
		done; \
	fi; \
	ran=0; \
	for dir in $$targets; do \
		if $(HAS_RENDER_ALL); then \
			echo "===== $$dir ====="; \
			(cd "$$dir" && make render-all) || exit 1; \
			ran=$$((ran + 1)); \
		fi \
	done; \
	if [ "$$ran" -eq 0 ]; then echo "[render-changed] 変更のあったテンプレはありません (全量は make render-all)"; \
	else echo "[render-changed] done ($$ran templates)"; fi

# 並列の描き出し。テンプレ同士は生成物が交わらないので同時に走れる。ログ・失敗の扱いは並列の make test と同じ。
RENDER_PAR_JOBS ?= 4
.PHONY: render-par
render-par: ### [RENDER_PAR_JOBS=4] | make render-all を並べて流す
	@mkdir -p .test-logs; rm -f .test-logs/render-*.log .test-logs/render-*.fail; \
	for dir in $(TEMPLATE_DIRS:%=%/); do \
		if $(HAS_RENDER_ALL); then echo "$$dir"; fi; \
	done | xargs -P $(RENDER_PAR_JOBS) -n 1 sh -c ' \
		dir="$$0"; name=$$(basename "$$dir"); \
		if (cd "$$dir" && make render-all) > ".test-logs/render-$$name.log" 2>&1; then \
			echo "[render-par] DONE $$dir"; \
		else \
			echo "[render-par] FAIL $$dir"; touch ".test-logs/render-$$name.fail"; \
		fi'; \
	ran=$$(ls .test-logs/render-*.log 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$ran" -eq 0 ]; then echo "[render-par] 1 本も実行されていない (xargs 失敗の疑い)"; exit 1; fi; \
	if ls .test-logs/render-*.fail > /dev/null 2>&1; then \
		echo "===== 失敗した描き出しのログ末尾 ====="; \
		for f in .test-logs/render-*.fail; do base=$${f%.fail}; echo "--- $$base"; tail -40 "$$base.log"; done; \
		exit 1; \
	fi; \
	echo "[render-par] all done ($$ran templates)"

# 直した絵の「前 (リファレンス画像)」と「後 (gallery)」を左右に並べて <dir>/debug/diff/ に描き出す。
# bench はバイトが違うことしか言わないので、どこがどう変わったかを目で追えるようにする物。
# 描き出すのは変わった絵だけ — どれが変わったかは cmp が決め、名前だけ工具へ渡す。
#
# リファレンス画像の PNG は git 管理外（追跡するのは SHA256SUMS.txt だけ）なので、clone 直後は
# 「前」が手元に無い。その時は一度 make render-all && make reference-update で今の絵を基準に置く。
.PHONY: diff
diff: sync-layers ## DIR=<dir> | 直す前（リファレンス画像）と後（gallery）を左右に並べて <dir>/debug/diff/ に描き出す
	@test -n "$(DIR)" || { echo "使い方: make diff DIR=templates/rpg-starter"; exit 1; }
	@ls "$(DIR)"/reference/*.png > /dev/null 2>&1 || { \
		echo "[diff] $(DIR)/reference に比べる前の絵がありません。"; \
		echo "       リファレンス画像の PNG は git 管理外です。まず make -C $(DIR) render-all && make -C $(DIR) reference-update で基準を置いてください。"; \
		exit 1; }
	@names=$$(cd "$(DIR)" && for f in gallery/*.png; do \
		n=$$(basename "$$f"); \
		if [ ! -f "reference/$$n" ]; then echo "[diff] 比べる前がありません (新しい場面): $$n" >&2; \
		elif ! cmp -s "$$f" "reference/$$n"; then printf '%s,' "$$n"; fi; \
	done); \
	if [ -z "$$names" ]; then echo "[diff] 変わった絵はありません"; else \
		cd $(LAYER_ROOT)/$(ENGINE_TOOLS_DIR) && DIFF_DIR="$(abspath $(DIR))" DIFF_NAMES="$$names" \
			JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" "$(FLIX)" run --entrypoint ReferenceDiff.pairs; \
	fi

##@ 描き手の門と bench
# ── bench へ渡すだけのターゲット ───────────────────────────────────
# 使い方は make bench B=<名前>[,<名前>…]（例: make bench B=crowd2d-bench COUNTS=6000,20000）。
# gl-parity だけはリリースの門（RELEASE_GATES）と baseline-check が名前で呼ぶので make gl-parity でも流せる。
# 表の 1 行は「bench/ の下のフォルダ その Makefile のターゲット…」。ウィンドウを開く物と時間を測る物は CI に載せない。
#   gl-parity           GL と SoftRaster が同じ絵を出すかを隠しウィンドウで突き合わせる。A 段階（バイト一致）に不一致があれば exit 1。
#                       描く道（render_gl / SoftRaster / Frame / ShaderEval）を触ったら回す。リリースの門の 1 つ（RELEASE_GATES）
#   gl-parity-cpu       gl-parity の全部の場面を CPU で温めてから描き、1 枚の時間の中央値を bench/gl_parity/build/cpu-time.tsv へ（ウィンドウは開かない）。
#                       基準は bench/baseline/<版>/gl-parity-cpu.tsv。時間は機械と負荷で揺れるので門にはせず、同じ機械で前後を並べて見る
#   webgpu-check        WebGPU の PC の実装（Dawn）を Flix から通して描き、読み戻した画素を期待と比べる（上限・三角形と面の向き・readRgba・
#                       firstInstance の 20,000 本・device の取り直し・2 プロセス同時・GLFW のウィンドウ）。GPU の要る門。先に make sync-engine-full
#   shader-cache-soak   数値だけが違う Spec を 200 本投げ、シェーダープログラムのキャッシュが上限で頭打ちになるか（ShaderCache / ShaderGen を触ったら）
#   scene3d-still       3D の場面の固定の部屋を CPU で bench/scene3d/debug/room.png に描く（ウィンドウは開かない）
#   scene3d-bench       同じ部屋を実機のウィンドウで毎コマ描き、1 コマの p50 / p95 を出す（つまみは bench/scene3d/Makefile の頭）
#   scene3d-cpu         同じ部屋を CPU で温めてから何回か描き、1 枚の時間の中央値を出す（still の時間はキャッシュの写しを含むので比べに使わない）
#   crowd2d-cpu         2D の敵の群れの規則だけを回し、近くを探す処理を全部と比べる形と SpatialGrid で比べる（FlowField の比べも出す）
#   crowd2d-bench       同じ群れを実機のウィンドウで描き、1 コマ・規則・描く時間の p50 / p95 を出す（COUNTS=6000,20000 SEARCH=grid FRAMES=300）
#   sprite-stress-bench 2D のスプライトを数だけ実機のウィンドウで描き、1 コマの avg / p50 / p95 / p99 を出す（COUNTS=… TEX=16 BLEND=alt）
BENCH_TO_gl-parity           := gl_parity run
BENCH_TO_gl-parity-cpu       := gl_parity cpu-time
BENCH_TO_webgpu-check        := webgpu_check check run two window
BENCH_TO_shader-cache-soak   := shader_cache_soak run
BENCH_TO_scene3d-still       := scene3d still
BENCH_TO_scene3d-bench       := scene3d run
BENCH_TO_scene3d-cpu         := scene3d cpu-time
BENCH_TO_crowd2d-cpu         := crowd2d cpu-time
BENCH_TO_crowd2d-bench       := crowd2d run
BENCH_TO_sprite-stress-bench := sprite_stress run
BENCH_NAMES := $(sort $(patsubst BENCH_TO_%,%,$(filter BENCH_TO_%,$(.VARIABLES))))

# 名前 1 つを bench/<フォルダ> の make へ渡す 1 文。
bench_sh = $(MAKE) -C bench/$(firstword $(BENCH_TO_$1)) $(wordlist 2,$(words $(BENCH_TO_$1)),$(BENCH_TO_$1))
B_RUN := $(subst $(comma), ,$(B))

.PHONY: bench gl-parity
bench: ### B=<名前>[,<名前>…] | bench へ渡すだけのターゲット（つまみは後ろに並べる。名前は make help-all の最後）
	@$(if $(B_RUN),,echo "使い方: make bench B=<名前>（名前: $(BENCH_NAMES)）"; exit 2)
	@$(if $(filter-out $(BENCH_NAMES),$(B_RUN)),echo "[bench] 知らない名前: $(filter-out $(BENCH_NAMES),$(B_RUN))（名前: $(BENCH_NAMES)）"; exit 2)
	@set -e; $(foreach n,$(B_RUN),$(call bench_sh,$n);)

gl-parity:
	@$(call bench_sh,gl-parity)

##> make gl-parity | GL と SoftRaster が同じ絵を出すかを隠しウィンドウで突き合わせ（不一致で exit 1。make bench B=gl-parity と同じ）

# WebGPU の 2D の描き手 (V1・plans/webgpu-v1.md の 8.1) の PC の門。順に:
#   1. 画面なし: bench/webgpu_v1 で GlOffscreen と同じ場面を描いて比べる (箱・スプライト・幕・放射の絵・字・Pass・生成の絵。WebGPU の誤りの数と submit の数も見る)
#   2. 実機の窓 (隠して起動): rpg-starter の title を --backend webgpu で 2 回撮り、SHA が同じ
#   3. GL と WebGPU: 同じ場面を CAPTURE_GLYPHS=used の GL でも撮り、bin/fge pixel-diff で比べる
#   4. bench/gl_parity の V1 の scene を WebGPU で流し、SoftRaster と GL に比べる
#   5. bench/webgpu_v2（3D の比べ・render_gl の pub でない関数を呼ぶ）が組めるかだけを見る（流すのは make -C bench/webgpu_v2 run）
# 許す差は bench/webgpu_v1/tolerance.tsv (既定 0・字は 2/255)。どれかが落ちれば exit 1。GPU の要る門なので CI には載せない。先に make sync-engine-full。
WEBGPU_V1_OUT := build/webgpu-v1
WEBGPU_V1_TOL := bench/webgpu_v1/tolerance.tsv
.PHONY: webgpu-v1-check webgpu-v1-check-web
webgpu-v1-check: ### | WebGPU の 2D の描き手の PC の門（画面なしの比べ・実機のウィンドウの 2 回・GL との pixel-diff・gl_parity の V1 の scene。NG で exit 1）
	@$(MAKE) -C bench/webgpu_v1 run
	@rm -rf $(WEBGPU_V1_OUT)/w1 $(WEBGPU_V1_OUT)/w2 $(WEBGPU_V1_OUT)/gl
	@bin/gl-capture.sh --backend webgpu $(WEBGPU_V1_OUT)/w1 templates/rpg-starter:title
	@bin/gl-capture.sh --backend webgpu $(WEBGPU_V1_OUT)/w2 templates/rpg-starter:title
	@bin/gl-capture.sh --compare $(WEBGPU_V1_OUT)/w1 $(WEBGPU_V1_OUT)/w2
	@CAPTURE_GLYPHS=used bin/gl-capture.sh --backend gl $(WEBGPU_V1_OUT)/gl templates/rpg-starter:title
	@bad=; for f in $(WEBGPU_V1_OUT)/gl/rpg-starter__title/frame-*.png; do n=$$(basename $$f .png); \
		bin/fge pixel-diff $$f $(WEBGPU_V1_OUT)/w1/rpg-starter__title/$$n.png --name rpg-starter__title --tolerance $(WEBGPU_V1_TOL) \
			--out $(WEBGPU_V1_OUT)/diff/title-$$n.png || bad="$$bad $$n"; \
	done; [ -z "$$bad" ] || { echo "[webgpu-v1-check] GL と違う:$$bad"; exit 1; }
	@$(MAKE) -C bench/gl_parity webgpu
	@$(MAKE) -C bench/webgpu_v2 check
	@echo "[webgpu-v1-check] OK"

# 同じ V1 の門のブラウザ版: rpg-starter を書き出し、web-capture --dev capture:6 の頁を webgl2・既定（WebGPU）・WebGPU の無い頁
# (navigator.gpu と GPU* の大域の名前を消した頁・bench/webgpu_v1/web/nogpu-head.html) で撮って比べる。
# 既定の頁の renderer に webgpu: が無い・webgl2 の頁か WebGPU の無い頁の renderer に webgpu: がある・WebGL2 の絵と違う、のどれかで exit 1。
# PC の WebGPU (make webgpu-v1-check の w1) があれば、それとも比べる (alpha は見ない)。書き出しを省くなら WEB_EXPORT=off。先に make sync-engine-full-web。
WEBGPU_V1_WEB := $(WEBGPU_V1_OUT)/web
# WhyNot: /bin/sh に任せない — pipefail を持たない sh（古い dash など）では撮れなかった回が通る。
webgpu-v1-check-web: SHELL := /bin/bash
webgpu-v1-check-web: ### [WEB_EXPORT=off] | 同じ門のブラウザ版（rpg-starter の 6 コマ目を webgl2・既定の WebGPU・WebGPU の無い頁で撮って比べる）
	@if [ "$(WEB_EXPORT)" != off ]; then bin/fge export-web templates/rpg-starter --out $(WEBGPU_V1_WEB)/rpg; fi
	@page=$(WEBGPU_V1_WEB)/rpg; { sed -n 1,3p $$page/index.html; cat bench/webgpu_v1/web/nogpu-head.html; sed -n '4,$$p' $$page/index.html; } > $$page/nogpu.html
	@# WhyNot: 前の回の絵と記録を残したまま撮らない — 撮れなかった回に前の絵で比べて緑になる。
	@rm -f $(WEBGPU_V1_WEB)/gl.png $(WEBGPU_V1_WEB)/gl.log $(WEBGPU_V1_WEB)/webgpu.png $(WEBGPU_V1_WEB)/webgpu.log $(WEBGPU_V1_WEB)/nogpu.png $(WEBGPU_V1_WEB)/nogpu.log
	@set -e -o pipefail; for row in "gl|index.html|capture:6,deferred:all,webgl2" "webgpu|index.html|capture:6,deferred:all" "nogpu|nogpu.html|capture:6,deferred:all"; do \
		IFS='|' read -r name url dev <<< "$$row"; \
		bin/fge web-capture "$$url" $(WEBGPU_V1_WEB)/$$name.png --dir $(WEBGPU_V1_WEB)/rpg --dev "$$dev" --size 640x600 --wait 90 | tee $(WEBGPU_V1_WEB)/$$name.log \
			|| { echo "[webgpu-v1-check-web] $$name を撮れなかった ($(WEBGPU_V1_WEB)/$$name.log)"; exit 1; }; \
	done
	@grep -q 'renderer: webgpu:' $(WEBGPU_V1_WEB)/webgpu.log || { echo "[webgpu-v1-check-web] 既定の頁が WebGPU で描いていない"; exit 1; }
	@grep -q 'renderer: ' $(WEBGPU_V1_WEB)/gl.log && ! grep -q 'renderer: webgpu:' $(WEBGPU_V1_WEB)/gl.log \
		|| { echo "[webgpu-v1-check-web] webgl2 の頁が WebGL2 で描いたと名乗っていない ($(WEBGPU_V1_WEB)/gl.log)"; exit 1; }
	@grep -q 'renderer: ' $(WEBGPU_V1_WEB)/nogpu.log && ! grep -q 'renderer: webgpu:' $(WEBGPU_V1_WEB)/nogpu.log \
		|| { echo "[webgpu-v1-check-web] WebGPU の無い頁が WebGL2 で描いたと名乗っていない ($(WEBGPU_V1_WEB)/nogpu.log)"; exit 1; }
	@bin/fge pixel-diff $(WEBGPU_V1_WEB)/gl.png $(WEBGPU_V1_WEB)/webgpu.png --name rpg-starter__title --tolerance $(WEBGPU_V1_TOL) --out $(WEBGPU_V1_WEB)/diff-webgpu.png
	@bin/fge pixel-diff $(WEBGPU_V1_WEB)/gl.png $(WEBGPU_V1_WEB)/nogpu.png --name nogpu --out $(WEBGPU_V1_WEB)/diff-nogpu.png
	@if [ -f $(WEBGPU_V1_OUT)/w1/rpg-starter__title/frame-6.png ]; then \
		bin/fge pixel-diff $(WEBGPU_V1_WEB)/webgpu.png $(WEBGPU_V1_OUT)/w1/rpg-starter__title/frame-6.png --ignore-alpha \
			--name rpg-starter__title-web-vs-pc --tolerance $(WEBGPU_V1_TOL) --out $(WEBGPU_V1_WEB)/diff-web-vs-pc.png; \
	else echo "[webgpu-v1-check-web] PC の WebGPU の絵が無いので比べない (先に make webgpu-v1-check)"; fi
	@echo "[webgpu-v1-check-web] OK"

# 同じ門のブラウザ版 (navigator.gpu・TeaVM の JSO)。ウィンドウを使わない門を PC と同じ Flix のコード (bench/webgpu_check/src/Checks.flix) で
# ヘッドレスの Chrome に流し、canvas の描き先も見る。結果の JSON は build/bench-web/webgpu_check.json。どれかが NG なら exit 1。
# 先に make sync-engine-full-web。書き出しを省いて頁だけ開き直すなら BENCH_WEB_EXPORT=off。
WEBGPU_CHECK_WEB_OUT := build/bench-web/webgpu_check.json
.PHONY: webgpu-check-web
webgpu-check-web: ### [BENCH_WEB_EXPORT=off] | webgpu-check をブラウザの実装（navigator.gpu）でヘッドレスの Chrome に流す
	@$(MAKE) --no-print-directory bench-web BENCH=webgpu_check OUT=$(WEBGPU_CHECK_WEB_OUT)
	@grep -q '"name":"webgpu-check","ok":true' $(WEBGPU_CHECK_WEB_OUT) \
	  || { echo "[webgpu-check-web] NG あり ($(WEBGPU_CHECK_WEB_OUT))"; exit 1; }
	@echo "[webgpu-check-web] OK ($(WEBGPU_CHECK_WEB_OUT))"

# PC とブラウザで同じ画素か: 同じ機械で両方の門を流し、三角形 2 枚と firstInstance の絵の digest を並べて比べる。違えば exit 1。
WEBGPU_CHECK_PC_OUT := build/bench-web/webgpu_check-pc.txt
WEBGPU_CHECK_SAME   := triangle-cull-back triangle-cull-none first-instance
.PHONY: webgpu-check-same
webgpu-check-same: webgpu-check-web ### | PC とブラウザの門を同じ機械で流し、三角形と firstInstance の絵の digest が同じかを比べる
	@mkdir -p $(dir $(WEBGPU_CHECK_PC_OUT))
	@$(MAKE) --no-print-directory -C bench/webgpu_check run > $(WEBGPU_CHECK_PC_OUT) 2>&1 \
	  || { echo "[webgpu-check-same] PC の門が NG ($(WEBGPU_CHECK_PC_OUT))"; exit 1; }
	@bad=; for n in $(WEBGPU_CHECK_SAME); do \
		pc=$$(grep "^RESULT $$n " $(WEBGPU_CHECK_PC_OUT) | grep -oE 'digest=-?[0-9]+'); \
		web=$$(grep -oE "\"name\":\"$$n\"[^}]*" $(WEBGPU_CHECK_WEB_OUT) | grep -oE 'digest=-?[0-9]+'); \
		echo "[webgpu-check-same] $$n PC $${pc:-無い} ブラウザ $${web:-無い}"; \
		if [ -z "$$pc" ] || [ "$$pc" != "$$web" ]; then bad="$$bad $$n"; fi; \
	done; \
	[ -z "$$bad" ] || { echo "[webgpu-check-same] 違う:$$bad"; exit 1; }; \
	echo "[webgpu-check-same] OK"

# 3 つのベンチが共通に使う BenchRun.flix・BenchEnv.flix (bench/common) を各ベンチの src へ写す。直すのは bench/common の物。
.PHONY: bench-common
bench-common: ### | bench/common の BenchRun.flix・BenchEnv.flix を 3 つのベンチの src へ写す
	@for b in sprite_stress crowd2d scene3d; do cp bench/common/BenchRun.flix bench/common/BenchEnv.flix bench/$$b/src/; done
	@echo "[bench-common] bench/common の 2 本を 3 つのベンチの src へ写した"

# ベンチのブラウザ版。bench-web-export は bench/<BENCH> を build/bench-web/<BENCH> へ書き出し、結果を頁の上と window.__bench に出す
# script (bench/common/bench-overlay.js) を index.html に差し込む。bench-web は書き出してからヘッドレスの Chrome で開き、測り終えた結果を JSON で出す。
# つまみは URL の query (ARGS)。スマホでは build/bench-web/<BENCH> を静的なサーバーで配り、index.html?<ARGS> を開く。
# 先に make sync-engine-full-web (engine を直したら流し直す)。書き出しに数分かかるので、つまみだけ替える時は BENCH_WEB_EXPORT=off。
# WhyNot: script を engine_web の index.html に入れない — ゲームの頁にベンチの表示が入る。
BENCH_WEB_DIR     = build/bench-web/$(BENCH)
BENCH_WEB_SIZE_sprite_stress := 960x720
BENCH_WEB_SIZE_crowd2d       := 1280x720
BENCH_WEB_SIZE_scene3d       := 960x540
BENCH_WEB_SIZE   ?= $(or $(BENCH_WEB_SIZE_$(BENCH)),960x540)
BENCH_WEB_WAIT_webgpu_check := 120
BENCH_WEB_WAIT   ?= $(or $(BENCH_WEB_WAIT_$(BENCH)),600)
# WhyNot: webgpu_check の書き出しで ⑨ を流さない — ⑨ は App のコマ（?capture）を待つが、この頁はコマを回さず門を流して終わる。wasm を読めるかは門そのものが見る。
BENCH_WEB_EXPORT_FLAGS_webgpu_check := --no-browser-check
.PHONY: bench-web-export bench-web
bench-web-export: ### BENCH=<名前> | ベンチをブラウザ版へ書き出し、結果を出す script を差し込む（build/bench-web/<名前>）
	@if [ ! -d "bench/$(BENCH)/web" ]; then echo "usage: make bench-web-export BENCH=<sprite_stress|crowd2d|scene3d|webgpu_check>"; exit 2; fi
	@bin/fge export-web bench/$(BENCH) --out $(BENCH_WEB_DIR) $(BENCH_WEB_EXPORT_FLAGS_$(BENCH))
	@cp bench/common/bench-overlay.js $(BENCH_WEB_DIR)/bench-overlay.js
	@perl -0pi -e 's|</body>|<script src="bench-overlay.js"></script>\n</body>|' $(BENCH_WEB_DIR)/index.html
	@grep -q 'bench-overlay.js' $(BENCH_WEB_DIR)/index.html || { echo "[bench-web-export] index.html に </body> が無く、script を差し込めない"; exit 1; }
	@echo "[bench-web-export] $(BENCH_WEB_DIR)（静的なサーバーで配って index.html?<つまみ> を開く）"

bench-web: ### BENCH=<名前> [ARGS='n=20000&tex=16'] [OUT=<file>] | ベンチ（sprite_stress / crowd2d / scene3d）をヘッドレスの Chrome で測って JSON を出す
	@if [ "$(BENCH_WEB_EXPORT)" != off ]; then $(MAKE) --no-print-directory bench-web-export BENCH=$(BENCH); fi
	@bin/fge web-bench $(BENCH_WEB_DIR) --query '$(ARGS)' --size $(BENCH_WEB_SIZE) --wait $(BENCH_WEB_WAIT) $(if $(OUT),--out $(OUT)) $(if $(JSONL),--jsonl $(JSONL))

# 光の式の木 (engine の LightModel3d) から CPU の描き手が回す関数 (engine_tools/src/gen/SoftRaster3dLight.flix) を作り直す。
# 木を直したらこれを流す。入っている物と木が食い違うと engine_tools の TestSoftRaster3dLight が落ちる。
# WhyNot: engine_tools の作業場で流さない — 木を直して生成する関数の引数が変わると、入っている古い生成物と呼ぶ側
# (SoftRaster3d) が食い違い、engine_tools 全体は組めない。engine と書き出す口 (SoftRaster3dLightGen) だけを束ねて流す。
.PHONY: gen-light3d
gen-light3d: ### | 光の式の木（LightModel3d）から CPU の光の関数 engine_tools/src/gen/SoftRaster3dLight.flix と確かめ用の test/gen/SoftRaster3dLightCases.flix を作り直す
	@dir="$(LAYER_ROOT)/light3d-gen"; rm -rf "$$dir/src"; mkdir -p "$$dir/src"; \
	ln -sfn "$(CURDIR)/engine_tools/flix.toml" "$$dir/flix.toml"; \
	$(LINK_FLIX) "$(CURDIR)/$(ENGINE_DIR)/src" "$$dir/src/engine"; \
	ln -sfn "$(CURDIR)/engine_tools/test/SoftRaster3dLightGen.flix" "$$dir/src/SoftRaster3dLightGen.flix"
	cd "$(LAYER_ROOT)/light3d-gen" && "$(FLIX)" run --entrypoint SoftRaster3dLightGen.write

# 外のゲームの写し (bin/check-external.sh の既定の顔ぶれ) に今の engine_full を当てて flix check し、基準
# (BASELINE の external.tsv) で通っていたのに止まった物と、基準に無かったエラーだけを出す。ゲームのフォルダは汚さない。
# 先に make sync-engine-full。版を上げる段の終わりに回し、増えた物を移行メモで説明できるかを見る。
BASELINE ?= bench/baseline/0.76.0
.PHONY: check-external
check-external: ### [BASELINE=<dir>] | 外のゲームの写しを今の engine で型検査し、基準（bench/baseline/）から増えたエラーだけ出す
	@mkdir -p build/check-external
	@EXTERNAL_UPGRADES=$(BASELINE)/upgrade bin/check-external.sh build/check-external/now.tsv && \
		bin/check-external.sh --compare $(BASELINE)/external.tsv build/check-external/now.tsv

# 今の描き出しを基準 (PARITY_BASELINE) と比べる (bin/baseline-check.sh): gl-parity の行と絵の SHA・3D の部屋の CPU の絵。
# GALLERY=1 でテンプレの render-all も流し、gallery の絵 (前から reference-check が落ちる場面も) を比べる (基準は GALLERY_BASE か PARITY_BASELINE)。
# ONLY_2D=1 は 3D の場面の行と絵・式の行・room.png を除いて比べ、ONLY_KNOWN=1 は基準に無い名前の行と絵を飛ばす。
# COMPARE_MAX=<控えのフォルダ> は 3D の各行の差の数と max を控えの gl-parity.txt と並べて出す (知らせるだけ)。
# 先に make sync-engine-full。段の終わりと、描き手を触った後に回す。
# WhyNot: 描き出しの基準を BASELINE と分ける — BASELINE は check-external と upgrade の基準で、3D の絵だけを撮り直す版で動かすと外のゲームの基準まで替わる。
PARITY_BASELINE ?= bench/baseline/0.79.0
.PHONY: baseline-check
baseline-check: ### [GALLERY=1] [ONLY_2D=1] [ONLY_KNOWN=1] [GALLERY_BASE=<dir>] [COMPARE_MAX=<dir>] | gl-parity の行と絵・3D の部屋の CPU の絵（とテンプレの gallery）を基準（PARITY_BASELINE）と比べる
	@mkdir -p build/baseline
	@bin/check-fpkg-fresh.sh
	@# WhyNot: gl-parity が exit 1 でも止めない — 差の数が許容を超えた行も、基準との違いとして下で並べて見せる。組めずに止まった時は行が無いので下が落とす。
	@$(MAKE) --no-print-directory gl-parity > build/baseline/gl-parity.log 2>&1; echo "[baseline] make gl-parity の終わり: $$?"
	@FGE_RENDER_CACHE=off $(MAKE) --no-print-directory bench B=scene3d-still > build/baseline/scene3d-still.log 2>&1
	@if [ -n "$(GALLERY)" ]; then for t in rpg-starter sound-novel-starter tidepool-starter; do \
		$(MAKE) --no-print-directory -C templates/$$t render-all > build/baseline/render-$$t.log 2>&1 || exit 1; done; fi
	@bin/baseline-check.sh $(PARITY_BASELINE) build/baseline/gl-parity.log $(if $(GALLERY),--gallery) $(if $(GALLERY_BASE),--gallery-base $(GALLERY_BASE)) \
		$(if $(ONLY_2D),--only-2d) $(if $(ONLY_KNOWN),--only-known) $(if $(COMPARE_MAX),--compare-max $(COMPARE_MAX))

# 開発の道具（App.DevTools）の smoke (bin/smoke-devtools.sh): テンプレ (SMOKE_TEMPLATE・既定 rpg-starter) を隠しウィンドウの DEBUG で起こし、
# 名簿に載る・命令口が /help・/halt・/step・/resume・/perf に答える・flow の記録ができる・閉じたら名簿から消える、を確かめる。
# 先に make sync-engine-full。App のループや開発の道具を触ったら回す。
.PHONY: smoke-devtools
smoke-devtools: ### [SMOKE_TEMPLATE=<テンプレ>] | 隠しウィンドウの DEBUG 起動で、名簿・命令（/help・/halt・/step・/resume・/perf）・flow の記録・閉じた後の名簿を確かめる
	@bin/smoke-devtools.sh $(SMOKE_TEMPLATE)

# 決定性の門 (bin/determinism.sh): テンプレを隠しウィンドウの DEBUG で起こして台本 (testdata/determinism/*.flow) を流し、
# 書いた記録を画面なしで再生して指紋と World 全体の要約が同じかを見る。窓を開くので CI には載せない。先に make sync-engine-full。
.PHONY: determinism
determinism: ### [TARGETS="<フォルダ>:<シナリオ> …"] | 隠しウィンドウのテンプレにシナリオを流して記録を書き、画面なしの再生が同じ World になるか（リリースの前）
	@bin/determinism.sh $(TARGETS)

# 実機の窓の絵をテンプレの場面ごとに撮る (bin/gl-capture.sh)。隠しウィンドウ・FLIX_GE_FIXED_DT で dt を固定し、
# 頭の 6 コマの SHA-256 を <OUT>/SHA256SUMS に控える。check は 2 回撮ってバイトで比べる (同じ起動で同じ絵になるか)。
# WhyNot: 2 回撮りの比べは緩めない — 同じ機械・同じ engine で揺れるのは決まった絵を出せていない証拠。緩めるのは基準との比べだけ。
# 描き手は既定の WebGPU。BACKEND=gl で GL の backend を撮る（基準は描き手ごとに別のファイル）。
# 撮るのはテンプレと bench の lib の engine なので、先に make sync-engine-full (engine のソースが fpkg より新しければ止まる)。
# 絵は機械とドライバで変わるので、比べるのは同じ機械で撮った物どうし。render_gl を触ったら check を回す。
.PHONY: gl-capture gl-capture-check
GL_CAPTURE_BACKEND = $(or $(BACKEND),webgpu)
gl-capture: ### OUT=<dir> [BACKEND=gl] | テンプレの場面を隠しウィンドウ・dt 固定で頭の 6 コマ撮り、SHA-256 を控える
	@if [ -z "$(OUT)" ]; then echo "usage: make gl-capture OUT=<出力のフォルダ> [BACKEND=gl]"; exit 2; fi
	@bin/gl-capture.sh --backend $(GL_CAPTURE_BACKEND) "$(OUT)"

# WhyNot: gl-capture の基準を BASELINE と分ける — 3D の GL の絵は C2 の後で 1 画素変わり、gl-capture の基準だけを撮り直す版がある。
# WhyNot: 基準を 1 つのファイルにしない — M2 と M4 Pro で 54 枚のうち 30 枚がずれ、別の機械の基準との差が毎回の門に混ざった。
# WhyNot: WebGPU の基準の名前に jWebGPU の版を入れずに置かない — 版を上げると Dawn が替わり絵が変わりうる。名前に入れておけば、
#   版を上げた木では基準が無いと言って止まり（2 回撮りの一致だけ）、撮り直すまで古い Dawn の基準と比べない。
GL_CAPTURE_MACHINE ?= $(shell sysctl -n machdep.cpu.brand_string 2>/dev/null | tr 'A-Z ' 'a-z-')
GL_CAPTURE_BASELINE_GL ?= bench/baseline/0.96.0/gl-capture-$(GL_CAPTURE_MACHINE).sha256
GL_CAPTURE_BASELINE_WEBGPU ?= bench/baseline/0.99.0/gl-capture-webgpu-jwebgpu$(GL_JAR_JWEBGPU)-$(GL_CAPTURE_MACHINE).sha256
GL_CAPTURE_BASELINE_FILE ?= $(if $(filter gl,$(GL_CAPTURE_BACKEND)),$(GL_CAPTURE_BASELINE_GL),$(GL_CAPTURE_BASELINE_WEBGPU))
# 基準の絵（PNG）は git の外の手元に置く（全部で 14 MB ほど・生成した絵は git に入れない決まり）。基準の SHA と同じバイトの絵が撮れた回に
# gl-capture-check が置き、SHA が基準と違うコマだけこの絵と画素で比べる（物差しは docs/backend-parity.md の「小さい差で通す」）。
GL_CAPTURE_BASELINE_IMAGES ?= build/gl-capture/baseline/$(notdir $(basename $(GL_CAPTURE_BASELINE_FILE)))
# SCENES は撮った物のフォルダ名（rpg-starter__title）か、テンプレートのフォルダ名（rpg-starter = その場面全部）を , で並べる。
GL_CAPTURE_ONLY = $(foreach n,$(subst $(comma), ,$(SCENES)),--only $(n))
gl-capture-check: ### [BACKEND=gl] [BASE=off] [SKIP=<フォルダ名>] [SCENES=<名前>,…] | 同じ場面を 2 回撮って 2 コマ目以降までバイトで比べ、基準とも比べる（基準との小さい差は通す・超えたら exit 1）
	@rm -rf build/gl-capture/a build/gl-capture/b
	@bin/gl-capture.sh --backend $(GL_CAPTURE_BACKEND) $(GL_CAPTURE_ONLY) build/gl-capture/a && bin/gl-capture.sh --backend $(GL_CAPTURE_BACKEND) $(GL_CAPTURE_ONLY) build/gl-capture/b && \
		bin/gl-capture.sh --compare build/gl-capture/a build/gl-capture/b $(if $(SKIP),--skip $(SKIP)) $(GL_CAPTURE_ONLY)
	@if [ "$(BASE)" = off ]; then :; \
	elif [ -f "$(GL_CAPTURE_BASELINE_FILE)" ]; then bin/fge gl-capture-baseline-check $(GL_CAPTURE_BASELINE_FILE) $(GL_CAPTURE_BASELINE_IMAGES) build/gl-capture/a \
		--diff-dir build/gl-capture/diff $(if $(SKIP),--skip $(SKIP)) $(GL_CAPTURE_ONLY); \
	else echo "[gl-capture] この機械 ($(GL_CAPTURE_MACHINE)) の $(GL_CAPTURE_BACKEND) の基準 ($(GL_CAPTURE_BASELINE_FILE)) が無いので、2 回撮りの一致だけを見た（撮るなら make gl-capture-baseline）"; fi

# この機械の基準を今の絵で撮る（撮った絵は 2 回撮りで一致した物だけ）。WebGPU の基準の頭には、撮った時の adapter の行（Dawn の名乗り）を # で残す。
.PHONY: gl-capture-baseline
gl-capture-baseline: ### [BACKEND=gl] | この機械の gl-capture の基準を今の絵で撮る（WebGPU は bench/baseline/<版>/gl-capture-webgpu-jwebgpu<版>-<機械>.sha256）
	@if [ -n "$(SCENES)" ]; then echo "[gl-capture] 基準は全部の場面で撮る（SCENES= を外す）"; exit 2; fi
	@$(MAKE) --no-print-directory gl-capture-check BASE=off
	@mkdir -p $(dir $(GL_CAPTURE_BASELINE_FILE))
	@{ grep -ah '^\[backend\] webgpu:' build/gl-capture/a/*/run.log 2>/dev/null | head -1 | sed 's/^/# /'; cat build/gl-capture/a/SHA256SUMS; } > $(GL_CAPTURE_BASELINE_FILE)
	@rm -rf $(GL_CAPTURE_BASELINE_IMAGES) && mkdir -p $(GL_CAPTURE_BASELINE_IMAGES)
	@rsync -a --include='*/' --include='frame-*.png' --exclude='*' build/gl-capture/a/ $(GL_CAPTURE_BASELINE_IMAGES)/
	@echo "[gl-capture] 基準を書いた: $(GL_CAPTURE_BASELINE_FILE)（基準の絵は $(GL_CAPTURE_BASELINE_IMAGES)）"

# ── Go 版の検査 (画素・波形を扱う層) ────────────────────────
# 置き場は go/。標準ライブラリだけで書いてあり、go.sum は空のままが正しい。
# CGO_ENABLED=0 を固定するのは、CGO が有効だとクロスコンパイルに相手側の
# ツールチェーンが要るようになり、Mac 1 台で全部を出す前提が崩れるため。
GO_OSARCH := darwin/arm64 darwin/amd64 linux/amd64 linux/arm64 windows/amd64

# 記号情報を落として 6.1M → 4.2M。デバッガ用の情報だけが消え、panic の出方は変わらない
# (落ちた場所の関数名は実行時のメタデータから出るので読める)。
GO_LDFLAGS := -s -w

# 配る先ごとのバイナリの置き場。変数にしてあるのは、この先が実在するパスでないため
# (fge-go-<os>-<arch> は組み立ててから初めて決まる)。check-refs は $( で始まる字を
# 「組み立てる物」と見て実在を問わない — 直に書くと毎回「実在しません」で赤くなる。
GO_DIST := bin/dist

##@ Go の道具
.PHONY: go-build
go-build: ## | go/ を bin/fge-go と、配る先ごとの 5 種にビルドする（go を直したら）
	@cd go && CGO_ENABLED=0 go build -ldflags="$(GO_LDFLAGS)" -o ../bin/fge-go .
	@for pair in $(GO_OSARCH); do \
		os=$${pair%%/*}; arch=$${pair##*/}; \
		ext=""; [ "$$os" = "windows" ] && ext=".exe"; \
		(cd go && CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch \
			go build -ldflags="$(GO_LDFLAGS)" -o ../$(GO_DIST)/fge-go-$$os-$$arch$$ext .) || exit 1; \
		echo "  $(GO_DIST)/fge-go-$$os-$$arch$$ext"; \
	done

# sync-fge-go が組むのは手元の OS/CPU の 1 本だけ（GO_OSARCH=$(GO_HOST)）。5 種そろえるのは go-build（bundle-zip・リリース）。
# WhyNot: = で置く（:= にしない）のは、go env を呼ぶのをこの口を使う時だけにするため。
# WhyNot: 配った engine（go/ が無い）では引かない — レシピを展開するだけで sh が「cd: can't cd to go」を出す（sync-fge-go は先に抜ける）。
GO_HOST = $(if $(IS_BUNDLE),,$(shell cd go && go env GOOS)/$(shell cd go && go env GOARCH))
.PHONY: go-test
# FRESH=<名前>,… はその分を -count=1 で流す（テストが exec する子の読むファイルを go の test cache が追わないため）。名前の . は main。
# PKG も FRESH も無ければ全部。bin/fge test-select は PKG と FRESH を重ねずに渡す。
GO_PKG_PATHS = $(foreach n,$(subst $(comma), ,$(1)),$(if $(filter .,$(n)),.,./internal/$(n)/...))
go-test: ### [PKG=<名前>,…] [FRESH=<名前>,…] | go/ のテスト（PKG は go/internal/<名前>・. は main。どちらも無ければ全部）
	@cd go && $(if $(PKG)$(FRESH),true,CGO_ENABLED=0 go test ./...) \
	$(if $(PKG),&& CGO_ENABLED=0 go test $(call GO_PKG_PATHS,$(PKG))) \
	$(if $(FRESH),&& CGO_ENABLED=0 go test -count=1 $(call GO_PKG_PATHS,$(FRESH)))

# arm64 の Mac で x86-64 の結果を確かめる（Rosetta）。arm64 は a*b+c を FMA にまとめることがあり、
# 包み忘れると境目の画素だけが Mac と Windows でずれる（px の積は float64(…) か dot で包む）。
.PHONY: go-test-amd64
go-test-amd64: ### | arm64 の Mac で x86-64 の結果を確かめる（Rosetta。px の FMA のずれ）
	@cd go && CGO_ENABLED=0 GOARCH=amd64 go test ./internal/px ./internal/pxlib ./internal/anim

# engine の新しい型を使う小さなゲーム（testdata/refactor-smoke）で、checkd・bin/fge refactor・flixlint が通るかを確かめる。
# 束は make sync-engine-full の置き場の物を使う（engine を直したら先に sync-engine-full）。中身は bin/refactor-smoke.sh。
# WhyNot: bench やテンプレートで確かめない。それぞれの lib の束と常駐の状態が残っていて、道具の誤りと古い束の誤りを見分けられない。
.PHONY: refactor-smoke
refactor-smoke: ### | engine の新しい型を使う小さな場面で checkd（束の張り替えで常駐を起こし直す）・refactor search / usages・flixlint が通るか
	@bin/refactor-smoke.sh $(VERSION) $(ENGINE_FULL_SUBPATH) $(ENGINE_FULL_FPKG_NAME) $(ENGINE_FULL_TOML_NAME)

##@ lint
# ── lint ──────────────────────────────────────────────────
# 中身はどれも bin/fge の検査で、規約は bin/lint-rules/<名前>.json。使い方は make lint ONLY=<名前>[,<名前>…]。
#   palette        ドット絵の legend の意味色キーが Studio から実色に解けるか（解けないと編集画面が仮色で塗る）
#   audio          音名が SfxRender の名・project.json・コードの 3 か所でそろっているか（ずれても音が鳴らないだけで気づけない）
#   jargon         コメント・文章に独自の比喩語が混ざっていないか（語は bin/lint-rules/jargon.json の words）
#   fallback       読み込みの途中で bug! していないか（許すのは *OrBug の中だけ。docs/error-handling.md の決まり 2）
#   f32            engine の pub 面に Float32 が出ていないか（Float32 は GL / OpenAL / STB の境界の内側だけ）
#   z-table        z を数で決める所がパッケージに 1 か所か（散ると同じ数を取り合う。docs/z-bands.md）
#   forbid         古い書き方を 1 行の正規表現で止め、代わりの物を出す（bin/lint-rules/forbid.json）
#   max-lines      engine の src の .flix の行数の上限（超えた物は max-lines.json の exempt）
#   value-discard  値を let _ = で捨てていないか（純粋な式だと Flix が呼び出しごと消す。docs/error-handling.md の決まり 3）
#   quadratic      fold の中で蓄積を作り直す二乗の形（docs/performance.md「二乗を書かない」）
#   hoist          ループの外に置いた式をラムダの中へ Flix が書き写す形（docs/performance.md）
#   record-wrap    World が直接持つ大きな record を enum で包んでいるか（docs/flix-conventions.md「型の設計」）
#   state-shape    状態の持ち方（Bool の欄の数・Option[Bool]・名指しの enum への case _・View の効果）
#   doc-refs       docs/・agents-pack の文書と .flix のコメントが指す Mod.name・パス・path:行 が実在するか
#   view           View が矩形と円だけになっていないか（絵の下限）
#   images         git に入れる絵が増えすぎていないか（描き出した絵が紛れ込んでいないか）
#   sprite         ドット絵の画素の並び（浮き・塊の分裂・階段・細長さ・色数）
#   anim           コマ間の飛び・体積・接地と 4 方向のそろい
#   ui             ui.json の text の折り返し宣言漏れ（固定幅の枠 + wrap/fit なし。実寸は測らない）
#   loop           ループ GIF の継ぎ目（最終コマ→0 コマ）。描き出し済みのコマが前提なので手で回す
#   load-copy      render_gl の LwjglLoad と engine_tools の HeadlessLoad の写し（pool とデコーダー）が同じか
#   huge-methods   JVM が JIT しない大きさ（8,000 バイト超）の関数を jar から数える（JARS=<jar…>）
#
# 名前ごとの bin/fge のサブコマンドと引数。LINT_SELF_TEST の物は先に --self-test を通す（自己テストが壊れた lint には門番をさせない）。
LINT_CMD_palette       := palette
LINT_CMD_audio         := audio
LINT_CMD_jargon        := jargon --all
LINT_CMD_fallback      := fallback --all
LINT_CMD_f32           := f32
LINT_CMD_z-table       := z-table --all
LINT_CMD_forbid        := forbid --all
LINT_CMD_max-lines     := max-lines --all
LINT_CMD_value-discard := value-discard --all
LINT_CMD_quadratic     := quadratic --all
LINT_CMD_hoist         := hoist --all
LINT_CMD_record-wrap   := record-wrap --all
LINT_CMD_state-shape   := state-shape --all
LINT_CMD_doc-refs      := doc-refs
LINT_CMD_view          := view
LINT_CMD_images        := images
LINT_CMD_sprite        := sprite
LINT_CMD_anim          := anim
LINT_CMD_ui            := ui-overflow
LINT_CMD_loop          := loop
LINT_SELF_TEST := fallback f32 sprite anim ui loop

# bytecode が 8,000 バイトを超えるメソッドはインタプリタのまま回る (docs/performance.md の 13 節)。超えていて良い物は huge-methods.json の exempt。
# 表の 1 行に収まらない検査は LINT_SH_<名前> にシェルの 1 文で書く。
# WhyNot: 既定の束に入れない — 見るのは組んだ jar で、ソースを直しても jar を作り直すまで結果が変わらない。
# WhyNot: jar をここで作らない — Flix は main から届く関数だけを jar に入れるので、どの jar を見るかは測る場面で決まる。ベンチを流した後に打つ。
HUGE_METHODS_JARS ?= $(wildcard bench/sprite_stress/artifact/*.jar bench/crowd2d/artifact/*.jar bench/scene3d/build/headless/headless.jar)
LINT_SH_huge-methods = jars="$(if $(JARS),$(JARS),$(HUGE_METHODS_JARS))"; \
	if [ -z "$$jars" ]; then echo "[lint huge-methods] 見る jar がありません。ベンチを 1 回流すか JARS=<jar> で渡してください"; exit 2; fi; \
	bin/fge huge-methods $$jars

# LwjglLoad と HeadlessLoad は層が互いを見ないので同じ部分を 2 つ持つ。毎コミットの precommit-local もこの 1 文を使う。
LINT_SH_load-copy = copy_of() { sed -n -e '/def pollMillis/p' -e '/PNG \/ JPEG を javax.imageio/,$$p' "$$1"; }; \
	if [ "$$(copy_of render_gl/src/LwjglLoad.flix)" != "$$(copy_of engine_tools/src/HeadlessLoad.flix)" ]; then \
	  echo "[lint load-copy] NG: LwjglLoad と HeadlessLoad の写し（pollMillis と「PNG / JPEG を javax.imageio」から下）が違います。片方を直したらもう片方へ写す（層が互いに見えないので 2 つ持つ）"; exit 1; \
	fi; echo "[lint load-copy] OK"

# テンプレートの lint/rules.flix（依存の向き・View が World を受けない・テストの形）を、そのテンプレートの make lint-flixlint で見る。
# 1 本 7 秒ほどで CPU を多く使うので、既定の束には入れない。コミットでは precommit-local が、触ったテンプレートの分だけ流す。
# WhyNot: game-starter を入れない — src に make new-game が埋める字（__WW__ など）が残っていて読めない（TEMPLATE_DIRS が外している）。
# WhyNot: $(MAKE) でなく make と書く — precommit は make -q で口の有無を見て、$(MAKE) の行は -q でも走る。
TEMPLATE_RULES_DIRS := $(patsubst %/lint/rules.flix,%,$(wildcard $(addsuffix /lint/rules.flix,$(TEMPLATE_DIRS))))
LINT_SH_template-rules = for t in $(TEMPLATE_RULES_DIRS); do \
	  echo "[lint template-rules] $$t"; (cd "$$t" && make -s --no-print-directory lint-flixlint) || exit 1; \
	done

LINT_NAMES := $(sort $(patsubst LINT_CMD_%,%,$(filter LINT_CMD_%,$(.VARIABLES))) $(patsubst LINT_SH_%,%,$(filter LINT_SH_%,$(.VARIABLES))))
# 名前 1 つの検査のシェルの 1 文。
lint_sh = $(if $(LINT_CMD_$1),$(if $(filter $1,$(LINT_SELF_TEST)),bin/fge $(firstword $(LINT_CMD_$1)) --self-test >/dev/null && )bin/fge $(LINT_CMD_$1),$(LINT_SH_$1))

# ONLY が無い時は、今 0 件の物を 1 回で流す（コミット時のフックは触ったファイルだけを見るので、全量はここで見る）。
# WhyNot: quadratic・fallback・jargon を既定の束にまだ入れない — 全量では前からの当たりが残っていて、ここが毎回赤になる。
# WhyNot: 名前ごとのターゲットに分けて依存に並べない — make -j で並べると出力が混ざり、どの lint が落ちたか読めない。
# WhyNot: 1 本ずつサブシェルで流す — 検査の 1 文が exit しても、後ろの lint の当たりを 1 回で見たい。
LINT_DEFAULT := forbid max-lines value-discard hoist record-wrap state-shape doc-refs z-table f32 load-copy
LINT_RUN := $(if $(ONLY),$(subst $(comma), ,$(ONLY)),$(LINT_DEFAULT))
.PHONY: lint
lint: ## [ONLY=<名前>,…] | 検査をまとめて流す（無ければ今 0 件の 10 本）。名前は make help-all の最後
	@$(if $(filter-out $(LINT_NAMES),$(LINT_RUN)),$(error [lint] 知らない名前: $(filter-out $(LINT_NAMES),$(LINT_RUN))（名前: $(LINT_NAMES)）))failed=""; \
	$(foreach n,$(LINT_RUN),( $(call lint_sh,$n) ) || failed="$$failed $n"; ) \
	if [ -n "$$failed" ]; then echo "[lint] 落ちた物:$$failed"; exit 1; fi; \
	echo "[lint] OK"

##@ 起動画面の素材
# ── 起動画面の素材 ────────────────────────────────────────
# 組み込みフォント (ASCII の 1bit ビットマップ) とロゴを engine/src/render2d/BootFontData.flix へ
# 作り直す。fpkg は .flix しか運べないので、生成物はコミットする。
# 起動画面の文言に新しい字を足したとき・ロゴを差し替えたときだけ回す。
# PREVIEW=<dir> を付けると、作った結果を目視用の PNG でも書き出す。
.PHONY: boot-font
boot-font: ### [PREVIEW=<dir>] | 組み込みフォントとロゴを engine/src/render2d/BootFontData.flix へ作り直す
	@java bin/BootFontGen.java $(if $(PREVIEW),--preview $(PREVIEW))

# GL の層の jar（render_gl/java の GlContext と LWJGL 版・録る版）を組み、使う所の lib/external へ置く。
# flix.toml の [jar-dependencies] は同じ名前の jar を Release から取る形で書いてあるが、Flix は lib/external に同じ名前の
# ファイルがあると取りに行かないので、作業コピーではここで置いた物が使われる。java/ を直したら make sync で置き直す。
# 名前と置き場（Release のタグ fge-gl-<ハッシュ>）は render_gl/java の中身と組み方のハッシュで決まる。java/ を直したら
# make gl-jar-pin で 3 つの flix.toml を書き換え、make gl-jar-publish（main への push で gl-jar.yml も流す）で置き場を作る。
# WhyNot: Flix のソースに書かない — Java の interface と実装は Flix で書けず（Flix の new は WASM で 1.5 倍遅い）、jar で運ぶしかない。
# WhyNot: LWJGL を Flix の lib/cache から借りない — 空の作業コピーでは jar を組む前に Flix の依存の解決が要り、その解決がこの jar を要る。
# WhyNot: 置き場をエンジンの版のリリースにしない — 版を上げてからそのリリースを出すまで main の flix.toml が無い物を指し、
# 外の CI と新しい clone が 404 で落ちる。
# WhyNot: jar のバイト列でなくソースのハッシュにする — jar は組んだ JDK の版（MANIFEST の Created-By・javac の出力）で変わり、
# 機械ごとに pin の検査が食い違う。
# WhyNot: ハッシュの前に CR を落とす — Windows の autocrlf の clone だけ別のハッシュになり、門が誤って止まる。
GL_JAR_SRC  := $(sort $(shell find $(RENDER_GL_DIR)/java -name '*.java' 2>/dev/null))
GL_JAR_CHECK := $(RENDER_GL_DIR)/java-check/GlConstantsCheck.java
GL_JAR_LWJGL := 3.4.1
# WebGPU の PC の実装（render_gl/java/fge/webgpu/dawn）を組む相手。版は 3 つの flix.toml の jWebGPU の行と同じにする。
GL_JAR_JWEBGPU := 0.3.4
GL_JAR_JPARSER := 1.2.8
GL_JAR_JAVA_RELEASE := 17
GL_JAR_HASH := $(if $(GL_JAR_SRC),$(shell { for f in $(GL_JAR_SRC); do echo "== $$f"; tr -d '\r' < "$$f"; done; \
	echo "release $(GL_JAR_JAVA_RELEASE) lwjgl $(GL_JAR_LWJGL) jwebgpu $(GL_JAR_JWEBGPU) jparser $(GL_JAR_JPARSER)"; } | shasum -a 256 | cut -c1-12))
GL_JAR_TAG  := fge-gl-$(GL_JAR_HASH)
GL_JAR_NAME := $(GL_JAR_TAG).jar
GL_JAR      := build/gl-jar/$(GL_JAR_NAME)
GL_JAR_REPO := ababup1192/flix_game_engine
GL_JAR_URL  := https://github.com/$(GL_JAR_REPO)/releases/download/$(GL_JAR_TAG)/$(GL_JAR_NAME)
GL_JAR_PIN_LINE := "$(GL_JAR_NAME)" = "url:$(GL_JAR_URL)"
GL_JAR_TOMLS := flix.toml $(RENDER_GL_DIR)/flix.toml $(ENGINE_FULL_DIR)/flix.toml
GL_JAR_DEPS := build/gl-jar/deps/lwjgl-$(GL_JAR_LWJGL).jar build/gl-jar/deps/lwjgl-opengl-$(GL_JAR_LWJGL).jar
GL_JAR_DEPS += build/gl-jar/deps/webgpu-jni-$(GL_JAR_JWEBGPU).jar \
	$(foreach m,api-core loader-core runtime-jni,build/gl-jar/deps/$(m)-$(GL_JAR_JPARSER).jar)
# WhyNot: 自分の .devbox だけを見ない — worktree は .devbox を持たないことが多く、無い道の javac を叩いて Error 127 で止まる。main の作業コピーの devbox も探す。
JAVAC := $(shell if javac -version >/dev/null 2>&1; then echo javac; else \
	main=$$(dirname "$$(git -C "$(CURDIR)" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null); \
	for d in "$(CURDIR)" "$$main"; do j="$$d/.devbox/nix/profile/default/bin/javac"; if [ -x "$$j" ]; then echo "$$j"; exit 0; fi; done; \
	echo $(CURDIR)/.devbox/nix/profile/default/bin/javac; fi)
# JDK の道具を呼ぶ形（$(call JDK,javac) / java / jar）。PATH に javac が無い時は devbox の JDK の隣の物。
JDK = $(if $(filter javac,$(JAVAC)),$1,"$(dir $(JAVAC))$1")
# Maven Central から jar を 1 本取る（引数は maven2/ より後ろのパス）。
define MAVEN_JAR
@mkdir -p $(dir $@)
curl -fsSL -o $@ https://repo1.maven.org/maven2/$1
endef
GL_JAR_USERS = $(LAYER_ROOT)/$(RENDER_GL_DIR) . $(ENGINE_FULL_DIR) \
	$(shell for d in templates/*/ bench/*/; do grep -qs 'ababup1192/flix_game_engine"' "$$d/flix.toml" && echo "$${d%/}"; done)

build/gl-jar/deps/lwjgl-%-$(GL_JAR_LWJGL).jar:
	$(call MAVEN_JAR,org/lwjgl/lwjgl-$*/$(GL_JAR_LWJGL)/lwjgl-$*-$(GL_JAR_LWJGL).jar)

build/gl-jar/deps/lwjgl-$(GL_JAR_LWJGL).jar:
	$(call MAVEN_JAR,org/lwjgl/lwjgl/$(GL_JAR_LWJGL)/lwjgl-$(GL_JAR_LWJGL).jar)

build/gl-jar/deps/webgpu-jni-$(GL_JAR_JWEBGPU).jar:
	$(call MAVEN_JAR,com/github/xpenatan/jWebGPU/webgpu-jni/$(GL_JAR_JWEBGPU)/webgpu-jni-$(GL_JAR_JWEBGPU).jar)

build/gl-jar/deps/%-$(GL_JAR_JPARSER).jar:
	$(call MAVEN_JAR,com/github/xpenatan/jParser/$*/$(GL_JAR_JPARSER)/$*-$(GL_JAR_JPARSER).jar)

##@ GL の層の jar
.PHONY: gl-jar gl-jar-pin gl-jar-pin-check gl-jar-publish
# WhyNot: ハッシュが空のまま進めない — fge-gl-.jar という名前で組み、pin がそれを書き込む。
GL_JAR_HASH_OK = test -n "$(GL_JAR_HASH)" || { echo "[gl-jar] $(RENDER_GL_DIR)/java の *.java が見つからないか shasum が無く、ハッシュが取れません"; exit 1; }

# WhyNot: --date を外さない — 外すと組むたびに中の時刻が変わり、同じソースでも別のバイトになる。
$(GL_JAR): $(GL_JAR_SRC) $(GL_JAR_CHECK) $(GL_JAR_DEPS)
	@$(GL_JAR_HASH_OK)
	@# jWebGPU の版は Java の定数（ネイティブの置き場の名前）・3 つの flix.toml・ここの GL_JAR_JWEBGPU の 5 か所でそろえる。
	@v=$$(sed -n 's/.*JWEBGPU_VERSION = "\(.*\)";/\1/p' $(RENDER_GL_DIR)/java/fge/webgpu/dawn/DawnWebGpu.java); \
	 bad=$$(grep -H 'jWebGPU:' $(GL_JAR_TOMLS) bench/webgpu_check/flix.toml | grep -v "= *\"$(GL_JAR_JWEBGPU)\""); \
	 [ "$$v" = "$(GL_JAR_JWEBGPU)" ] && [ -z "$$bad" ] || { echo "[gl-jar] jWebGPU の版がそろっていません: Java=$$v Makefile=$(GL_JAR_JWEBGPU) $$bad"; exit 1; }
	@rm -rf build/gl-jar/classes && mkdir -p build/gl-jar/classes
	$(call JDK,javac) --release $(GL_JAR_JAVA_RELEASE) -encoding UTF-8 -d build/gl-jar/classes \
		-cp "$(subst $(eval) ,:,$(GL_JAR_DEPS))" $(GL_JAR_SRC)
	@# 定数の打ち間違いは絵の比べでは場所が分かりにくいので、組んだ所で LWJGL の定数と突き合わせる。
	@rm -rf build/gl-jar/check && mkdir -p build/gl-jar/check
	$(call JDK,javac) --release $(GL_JAR_JAVA_RELEASE) -encoding UTF-8 -d build/gl-jar/check \
		-cp "build/gl-jar/classes:$(subst $(eval) ,:,$(GL_JAR_DEPS))" $(RENDER_GL_DIR)/java-check/GlConstantsCheck.java
	$(call JDK,java) -cp "build/gl-jar/check:build/gl-jar/classes" GlConstantsCheck
	$(call JDK,jar) --create --file $@ --date=2000-01-01T00:00:00Z -C build/gl-jar/classes .

# WhyNot: 前の名前の jar を lib/external から消してから置く — 残すと中身の違う同じクラスが 2 つ classpath に載り、どちらが効くか読めない。
gl-jar: $(GL_JAR) ### | GL の層の jar（render_gl/java）を組み、使う所の lib/external へ置く
	@find build/gl-jar -maxdepth 1 -name 'fge-gl-*.jar' ! -name '$(GL_JAR_NAME)' -exec rm -f {} +
	@for d in $(GL_JAR_USERS); do mkdir -p "$$d/lib/external"; rm -f "$$d/lib/external"/fge-gl-*.jar; cp -p $(GL_JAR) "$$d/lib/external/$(GL_JAR_NAME)"; done
	@echo "[gl-jar] $(GL_JAR) を $(words $(GL_JAR_USERS)) か所の lib/external へ置いた"
	@$(MAKE) --no-print-directory -s gl-jar-pin-check >/dev/null 2>&1 \
	  || echo "[gl-jar] flix.toml の jar の行が $(GL_JAR_NAME) を指していません。コミットの前に make gl-jar-pin"

gl-jar-pin: ### | render_gl/java を直した後、3 つの flix.toml の GL の層の jar の行を置き場 fge-gl-<ハッシュ> へ向ける
	@$(GL_JAR_HASH_OK)
	@for f in $(GL_JAR_TOMLS); do \
		grep -q '^"fge-gl-[^"]*\.jar" *= *"url:' "$$f" || { echo "[gl-jar-pin] $$f に fge-gl の行がありません"; exit 1; }; \
		GL_JAR_PIN_LINE='$(GL_JAR_PIN_LINE)' perl -pi -e 's|^"fge-gl-[^"]*\.jar" *= *"url:[^"]*"|$$ENV{GL_JAR_PIN_LINE}|' "$$f"; \
	done
	@echo "[gl-jar-pin] $(words $(GL_JAR_TOMLS)) つの flix.toml を $(GL_JAR_TAG) へ向けた"

gl-jar-pin-check: ### | flix.toml の jar の行がいまの render_gl/java を指しているか（release と precommit の門）
	@$(GL_JAR_HASH_OK)
	@bad=; for f in $(GL_JAR_TOMLS); do grep -qxF '$(GL_JAR_PIN_LINE)' "$$f" || bad="$$bad $$f"; done; \
	 [ -z "$$bad" ] || { echo "[gl-jar-pin-check] render_gl/java の中身 ($(GL_JAR_TAG)) と違う jar を指しています:$$bad"; \
	   echo "  make gl-jar-pin で書き換え、make gl-jar-publish で置き場を作ってください"; exit 1; }

# 手で流すときは GL_JAR_TARGET の commit を先に push し、render_gl/java をその commit と同じにしておく。
# WhyNot: --prerelease と --latest=false — 付けないとこれが「最新のリリース」になり、bin/fge fetch-engine が
# releases/latest でエンジンの版でなくこれを拾う。
# WhyNot: create が落ちても見直す — gl-jar.yml と release-publish が同時に作りに来ると片方が already exists で落ち、
# 版の公開が途中で止まる。
GL_JAR_TARGET ?= $(RELEASE_SHA)
gl-jar-publish: gl-jar-pin-check $(GL_JAR) ### | 置き場の Release fge-gl-<ハッシュ> を作って jar を載せる（あれば何もしない。main への push で gl-jar.yml も流す）
	@has_jar() { gh release view $(GL_JAR_TAG) --repo $(GL_JAR_REPO) --json assets -q '.assets[].name' 2>/dev/null | grep -qxF '$(GL_JAR_NAME)'; }; \
	 if has_jar; then echo "[gl-jar-publish] $(GL_JAR_TAG) に $(GL_JAR_NAME) はもうあります"; exit 0; fi; \
	 if gh release view $(GL_JAR_TAG) --repo $(GL_JAR_REPO) >/dev/null 2>&1; then \
	   gh release upload $(GL_JAR_TAG) --repo $(GL_JAR_REPO) "$(GL_JAR)" || has_jar || exit 1; \
	 else \
	   gh release create $(GL_JAR_TAG) --repo $(GL_JAR_REPO) --target $(GL_JAR_TARGET) \
	     --title "$(GL_JAR_TAG)" --prerelease --latest=false \
	     --notes "GL の層の jar（render_gl/java）。名前のハッシュは render_gl/java の中身と組み方から make が出す。flix.toml の [jar-dependencies] がここを指す。" \
	     "$(GL_JAR)" || { sleep 5; has_jar; } || exit 1; \
	 fi; \
	 echo "[gl-jar-publish] $(GL_JAR_TAG) に $(GL_JAR_NAME) を載せた"

# bin/fge precommit の localGate が呼ぶ。
# WhyNot: ステージした一覧で絞らない — 一覧は消したファイルを含まず、java を消しただけのコミットを見逃す。検査は 1 秒もかからない。
# WhyNot: レシピで $(MAKE) を呼ばない — precommit は make -q で口の有無を見るが、$(MAKE) の行は -q でも走り、
# pin のずれが「口が壊れている」と読まれて門が黙って開く。
.PHONY: precommit-local
# テンプレートの lint/rules.flix は、ステージした物（STAGED_FILE・1 行 1 つ）にそのテンプレートのファイルがある時だけ流す（1 本 7 秒ほど）。
precommit-local: gl-jar-pin-check ### | bin/fge precommit が流すエンジンの門（gl-jar-pin-check・LwjglLoad と HeadlessLoad の写し・触ったテンプレートの lint/rules.flix）
	@$(LINT_SH_load-copy)
	@if [ -n "$(STAGED_FILE)" ] && [ -f "$(STAGED_FILE)" ]; then \
	  for t in $(TEMPLATE_RULES_DIRS); do \
	    if grep -q "^$$t/" "$(STAGED_FILE)"; then \
	      echo "[precommit-local] $$t の lint/rules.flix"; (cd "$$t" && make -s --no-print-directory lint-flixlint) || exit 1; \
	    fi; \
	  done; \
	fi

##@ 配る（engine_full・ブラウザ版）
.PHONY: sync
# WhyNot: ブラウザ版の束（sync-engine-full-web）も入れる — 別の口にしておくと版を上げても誰も流さず、置き場の current が前の版のまま残り、
# ゲームの export-web（make tape の「はじめから遊ぶ」）が版の違う jar を探して止まる。
sync: clean-locks sync-layers sync-engine-full sync-engine-full-web sync-root-src ## | 層の作業場を張り、engine_full と engine_full_web を build-pkg して templates / bench と置き場に配る

# engine_full は engine / render_gl / engine_world / engine_tools のソースを1つに集めた
# 自己完結パッケージ (依存ゼロ)。ルート src/ と同じくファイル単位の symlink で4パッケージの
# .flix を engine_full/src/ に集約してから build-pkg し、最後に full を使う templates / bench へ配る。
# ディレクトリ symlink は Flix のソース走査に追従されないため、必ずファイル単位で張る。
# エンジンに .flix を追加/削除/改名したら再実行して集約を更新する (sync-root-src と同じ運用)。
# WhyNot: 中身を置き場の鍵（bin/fpkg-store.sh locked）の内側で流す — 2 本の sync が重なると、片方の build-pkg が書いている
# 途中の package.fpkg をもう片方が置き場へ写し、壊れた束が不変のエントリとして固まってゲームへ広がる。gc も同じ鍵の内側。
.PHONY: sync-engine-full sync-engine-full-unlocked
sync-engine-full: ## | engine_full だけ src を集めて型検査・build-pkg・配る（templates / bench へ）
	@bin/fpkg-store.sh locked $(MAKE) --no-print-directory sync-engine-full-unlocked

sync-engine-full-unlocked: gl-jar ### | sync-engine-full の中身（置き場の鍵を取らない。直に打たない）
	@for pkg in $(ROOT_SRC_PKGS); do rm -rf "$(ENGINE_FULL_DIR)/src/$$pkg"; done; \
	for pkg in $(ROOT_SRC_PKGS); do $(LINK_FLIX) --relative "$$pkg/src" "$(ENGINE_FULL_DIR)/src/$$pkg" || exit 1; done; \
	find $(ENGINE_FULL_DIR)/src -type l | awk 'END { print "[sync-engine-full] " NR " source symlink(s)" }'
	# 固める前に型検査する。build-pkg はソースを zip にするだけで、コンパイルが通るかを
	# 見ない。ここで検査しないと、壊れたエンジンが fpkg → Studio 同梱 → /Applications まで
	# 全部 exit 0 で運ばれ、誰かが新しいゲームを産んだ時に初めて落ちる。
	# WhyNot: 常駐 (bin/fge checkd) は使わない。symlink で束ねたこのパッケージでは常駐が
	# 偽の緑を返す (checkd 自身がこの形を見つけたら素の CLI へ落ちるようにしてある)。
	@echo "[sync-engine-full] 固める前に型検査"
	cd $(ENGINE_FULL_DIR) && "$(FLIX)" check
	@# WhyNot: symlink の package.fpkg を消してから組む — worktree-seed の古い形で main の build を指していると、build-pkg がその先（main）へ書く。
	@[ ! -L $(ENGINE_FULL_FPKG_SRC) ] || rm -f $(ENGINE_FULL_FPKG_SRC)
	cd $(ENGINE_FULL_DIR) && "$(FLIX)" build-pkg
	@# WhyNot: lib から engine_full/artifact/package.fpkg を直に指さない — 次の build-pkg がそれを書き換えている間に、
	@# 別のテンプレートの build が半分の束を読む。置き場（bin/fpkg-store.sh）のエントリは置いた後は変わらず、張り替えは rename で一度に替わる。
	@# WhyNot: packages.lock を消さず sha をそろえる — 消すと、走っている build が古い sha で書き戻した lock と区別が付かない。
	@entry=$$(bin/fpkg-store.sh put engine_full $(VERSION) $(ENGINE_FULL_FPKG_SRC) $(ENGINE_FULL_TOML_SRC)) || exit 1; \
	 echo "[sync-engine-full] 置き場 $$entry"
	@for dir in templates/*/ bench/*/; do \
		toml="$$dir/flix.toml"; \
		if [ -f "$$toml" ] && grep -q 'ababup1192/flix_game_engine"' "$$toml"; then \
			bin/fpkg-store.sh link "$$dir" "$(ENGINE_FULL_SUBPATH)" "$(ENGINE_FULL_FPKG_NAME)" "$(ENGINE_FULL_TOML_NAME)" || exit 1; \
			echo "[sync-engine-full] $${dir}$(ENGINE_FULL_SUBPATH)"; \
		fi \
	done
	@bin/fpkg-store.sh gc

# ── ブラウザ版の束（engine_full_web）──────────────────────────
# engine_full と同じソースの木に engine_web（WebLayer・WebFs・WebAssets）を足した 2 本目の束。書き出しの道具（bin/fge export-web）だけが使う。
# デスクトップの engine_full・テンプレの依存は 1 バイトも変えない（描く手順の本体は pub でない mod のままで、同じ束の中の WebLayer から呼ぶ）。
# 生成物なので build/ の下に作る。flix.toml は engine_full の物に TeaVM の JSO と fge-web の jar を足して作る（版を二重に持たない）。
WEB_DIR          := engine_web
WEB_FULL_DIR     := build/engine_full_web
TEAVM_VERSION    := 0.16.0
WEB_JAR_NAME     := fge-web-$(VERSION).jar
WEB_JAR          := build/web-jar/$(WEB_JAR_NAME)
WEB_JAR_SRC      := $(shell find $(WEB_DIR)/java -name '*.java' 2>/dev/null)
WEB_JAR_DEPS     := $(foreach m,jso jso-apis interop,build/web-jar/deps/teavm-$(m)-$(TEAVM_VERSION).jar)

build/web-jar/deps/teavm-%-$(TEAVM_VERSION).jar:
	$(call MAVEN_JAR,org/teavm/teavm-$*/$(TEAVM_VERSION)/teavm-$*-$(TEAVM_VERSION).jar)

$(WEB_JAR): $(WEB_JAR_SRC) $(WEB_JAR_DEPS) $(GL_JAR)
	@rm -rf build/web-jar/classes && mkdir -p build/web-jar/classes
	$(call JDK,javac) --release $(GL_JAR_JAVA_RELEASE) -encoding UTF-8 -d build/web-jar/classes \
		-cp "$(GL_JAR):$(subst $(eval) ,:,$(WEB_JAR_DEPS))" $(WEB_JAR_SRC)
	$(call JDK,jar) --create --file $@ --date=2000-01-01T00:00:00Z -C build/web-jar/classes .

# TeaVM の穴の手当て（classlib に無い類の shim と、jar のバイトコードの付け替え Rewrite）と、TeaVM を呼ぶ BuildWasm。書き出しの道具が TeaVM の classpath の頭に置く。
WEB_TOOLS_JAR      := build/web-jar/fge-web-tools-$(VERSION).jar
WEB_TOOLS_SRC      := $(shell find $(WEB_DIR)/teavm/java -name '*.java' 2>/dev/null)
WEB_TOOLS_DEPS     := $(foreach m,relocated-libs-asm core tooling,build/web-jar/deps/teavm-$(m)-$(TEAVM_VERSION).jar)

# WhyNot: fge.web.EmbeddedCodec を tools の jar へ写さない — 同じ類が TeaVM の classpath に 2 つ載り、どちらが有効になるか読めない。Embed は fge-web.jar を classpath に足して使う。
$(WEB_TOOLS_JAR): $(WEB_TOOLS_SRC) $(WEB_TOOLS_DEPS) $(WEB_JAR)
	@rm -rf build/web-jar/tools-classes && mkdir -p build/web-jar/tools-classes
	$(call JDK,javac) --release $(GL_JAR_JAVA_RELEASE) -encoding UTF-8 -d build/web-jar/tools-classes \
		-cp "$(subst $(eval) ,:,$(WEB_TOOLS_DEPS)):$(WEB_JAR)" $(WEB_TOOLS_SRC)
	$(call JDK,jar) --create --file $@ --date=2000-01-01T00:00:00Z -C build/web-jar/tools-classes .

.PHONY: web-jar sync-engine-full-web sync-engine-full-web-unlocked
web-jar: $(WEB_JAR) $(WEB_TOOLS_JAR) ### | ブラウザ版の束が使う fge-web と fge-web-tools の jar を組む

# 鍵の内側で流す理由は sync-engine-full と同じ（jar の組み直しも鍵の内側に入る）。
sync-engine-full-web: ### | ブラウザ版の束（engine_full + engine_web）を build/engine_full_web に組み、置き場へ入れる（bin/fge export-web が使う）
	@bin/fpkg-store.sh locked $(MAKE) --no-print-directory sync-engine-full-web-unlocked

sync-engine-full-web-unlocked: gl-jar web-jar ### | sync-engine-full-web の中身（置き場の鍵を取らない。直に打たない）
	@rm -rf $(WEB_FULL_DIR)/src && mkdir -p $(WEB_FULL_DIR)/src $(WEB_FULL_DIR)/lib/external
	@# engine_full にだけある物（src/full: VideoOut・GpuShot）も入れる。ゲームの src がそれを use するので、無いと型検査で止まる。
	@for pkg in $(ROOT_SRC_PKGS) $(WEB_DIR) $(ENGINE_FULL_DIR)/src/full; do \
		root="$$pkg/src"; [ -d "$$root" ] || root="$$pkg"; name=$$(basename "$$pkg"); \
		$(LINK_FLIX) "$(CURDIR)/$$root" "$(WEB_FULL_DIR)/src/$$name" || exit 1; \
	done
	@awk -v web='"$(WEB_JAR_NAME)" = "url:https://github.com/ababup1192/flix_game_engine/releases/download/v$(VERSION)/$(WEB_JAR_NAME)"' \
	     -v jso='"org.teavm:teavm-jso" = "$(TEAVM_VERSION)"\n"org.teavm:teavm-jso-apis" = "$(TEAVM_VERSION)"\n"org.teavm:teavm-interop" = "$(TEAVM_VERSION)"' \
	     '{ print } /^\[jar-dependencies\]/ { print web } /^\[mvn-dependencies\]/ { print jso }' \
	     $(ENGINE_FULL_TOML_SRC) > $(WEB_FULL_DIR)/flix.toml
	@rm -f $(WEB_FULL_DIR)/lib/external/fge-gl-*.jar $(WEB_FULL_DIR)/lib/external/$(WEB_JAR_NAME)
	@cp -p $(GL_JAR) $(WEB_JAR) $(WEB_FULL_DIR)/lib/external/
	@rm -f $(WEB_FULL_DIR)/packages.lock
	@find $(WEB_FULL_DIR)/src -type l | awk 'END { print "[sync-engine-full-web] " NR " source symlink(s)" }'
	cd $(WEB_FULL_DIR) && "$(FLIX)" check
	@[ ! -L $(WEB_FULL_DIR)/artifact/package.fpkg ] || rm -f $(WEB_FULL_DIR)/artifact/package.fpkg
	cd $(WEB_FULL_DIR) && "$(FLIX)" build-pkg
	@# WhyNot: jar もエントリに入れる — make gl-jar・web-jar が build/ の jar を組み直している間に、別のゲームの書き出しが数分後に tools の jar を読む。
	@entry=$$(bin/fpkg-store.sh put engine_full_web $(VERSION) $(WEB_FULL_DIR)/artifact/package.fpkg $(WEB_FULL_DIR)/flix.toml \
	   $(GL_JAR) $(WEB_JAR) $(WEB_TOOLS_JAR)) || exit 1; \
	 echo "[sync-engine-full-web] 置き場 $$entry"
	@bin/fpkg-store.sh gc

# 束の置き場（build/fpkg-store）の掃除。sync-engine-full と sync-engine-full-web の終わりにも走る。決まりは bin/fpkg-store.sh の頭。
.PHONY: fpkg-store-gc
fpkg-store-gc: ### [DRY=1] | 束の置き場（build/fpkg-store）から、どこからも指されていない古いエントリを消す
	@bin/fpkg-store.sh locked bin/fpkg-store.sh gc $(if $(DRY),--dry-run,)

##@ リリース
# ── リリース ──────────────────────────────────────────────
# 自己完結の全部入り engine_full を build-pkg し、既存リポ flix_game_engine の GitHub Release に
# fpkg と flix.toml を添付する。利用側は github:ababup1192/flix_game_engine の1行でこのバージョンを引く。
# 依存ゼロなので公開はこの1リポで完結する (推移先の別リポは不要)。
#
# 流れ (公開は CI の 1 本。手元は門だけ):
#   1) make bump FROM=<旧> TO=<新>   … 全 flix.toml と VERSION を一括更新 → commit → main へ push
#   2) make release (= make release-verify) … sync → test-release(全量ゲート) → gl-parity(A 段階の全一致) を手元で通し、
#                                          通した commit を release/verified.txt に書く
#   3) release/verified.txt を commit → main へ push
#   4) GitHub の Actions で release を main で手で起動 … CI が make release-publish で組んで gh release
#   終了後、lib/ を消したコピーで外部 fetch を検証する。
#
# WhyNot: 手元で配る物を組まない。stage-engine は作業ツリーを写すので、git の管理外の debug/・gallery/・
# packages.lock まで同梱 zip に入る (0.67.0・0.68.0 は templates/tidepool-starter/debug/video で 1.2 GB)。
# CI のきれいな checkout から組んだ物だけを正にする。
#
# release-guard の安全策:
#   - engine ソースが未コミットだと配布 fpkg がどのコミットにも対応しなくなるため中断する。
# 並列のテストに不審な挙動があれば逐次にフォールバックする (make release JOBS=1)。
# WhyNot: 配った engine（git の外）では引かない — make を起こすたびに「fatal: not a git repository」が出る。公開は clone した engine でしか打たない。
RELEASE_SHA := $(if $(IS_BUNDLE),,$(shell git rev-parse HEAD))
# 古い書き方: TEST= は 1 リリース後に消す（渡された時だけ、その口をテストの門に使う）
RELEASE_TEST := $(if $(filter command line,$(origin TEST)),$(TEST),test-release)
$(if $(and $(filter command line,$(origin TEST)),$(filter 0,$(MAKELEVEL))),$(info [release] 古い書き方: TEST= は次から付けない（逐次は make release JOBS=1）))
.PHONY: release-guard
release-guard: ### | 公開の前の安全策（未コミット・壊れた flix.toml・flix.jar の版・追随の材料・jar の行）
	@# WhyNot: 追随の材料も未コミット検査に入れるのは、bump が生成した物をコミットし
	@# 忘れるとタグの中身に材料が入らず、後からそのバージョンを取り出しても空になるため。
	@# 見る範囲は配る物すべて（go/・agents-pack/・bin/lint-rules/・mk/ など bin/lint-rules/stage-engine.json
	@# が載せる道。一覧は bin/fge stage-engine --sources が出す）。一部だけ見ると、未コミットの変更が
	@# zip にだけ入ってタグには入らない。
	@srcs=$$(bin/fge stage-engine --sources) || { echo "[release] 配る物の一覧を読めません (bin/fge stage-engine --sources)"; exit 1; }; \
	 dirty=$$(git status --porcelain -- $(ROOT_SRC_PKGS) docs/migrations $$srcs); \
	 if [ -n "$$dirty" ]; then \
	   echo "[release] engine ソースが未コミットです。commit してから実行してください:"; echo "$$dirty"; exit 1; \
	 fi
	@# ゲーム側 lib の flix.toml はここへの symlink なので、別プロセスの依存解決が
	@# symlink 越しに中身を空にしてしまうことがある。壊れたまま build-pkg へ進まない。
	@for f in $(ROOT_SRC_PKGS:%=%/flix.toml) $(ENGINE_FULL_DIR)/flix.toml; do \
	   grep -q '^version' "$$f" || { echo "[release] $$f が壊れています (package.version が無い)。git checkout -- $$f で復元してください"; exit 1; }; \
	 done
	@# WhyNot: 全量ゲートの前に flix.jar の在処を見るのは、同梱 zip がこれを要るため。
	@# 後ろで気づくと、10 分以上かけたテストの後に落ちて全部やり直しになる。
	@test -n "$(BUNDLE_FLIX_JAR)" -a -f "$(BUNDLE_FLIX_JAR)" \
	  || { echo "[release] flix.jar が見つかりません (同梱 zip が作れません)。BUNDLE_FLIX_JAR= で場所を指定してください"; exit 1; }
	@$(MAKE) --no-print-directory check-bundle-flix
	@# 追随の材料が bump のときのままか。API を触るコミットが bump の後に入ると古くなる。
	@bin/fge migration-notes --check
	@# render_gl/java を直したのに flix.toml の jar の行を書き換え忘れると、lib/ の無い所は古い jar で組まれる。
	@$(MAKE) --no-print-directory gl-jar-pin-check
	@echo "[release] v$(VERSION) を $(RELEASE_SHA) で公開します"
# Studio の NewGame.flix は AGENTS.md の組み立て（bin/fge sync-agents）を Flix で持ち直している。
# sync-agents の出力の形を変えた版を出すと、Studio の CI（check-agents-parity）がその版の同梱で落ちる。
# WhyNot: engine の go test で形を固めるだけにしないのは、固めた期待値ごと書き換えれば通り、
# Studio 側の直し忘れは止まらないため（0.35.36 で実際に落ちた）。公開の前に Studio の実物と突き合わせる。
# Studio の clone が無い所では STUDIO=none で飛ばせる（飛ばしたことは出力に残る）。
# WhyNot: 1 か所に決め打ちしないのは、clone を置き直すたびに release が止まり、毎回 STUDIO= を足すことになるため。
STUDIO_CANDIDATES := $(abspath $(CURDIR)/../flix_ge_studio) $(HOME)/Desktop/flix_ge_studio
STUDIO ?= $(or $(patsubst %/Makefile,%,$(firstword $(wildcard $(addsuffix /Makefile,$(STUDIO_CANDIDATES))))),$(firstword $(STUDIO_CANDIDATES)))
.PHONY: studio-parity
studio-parity: ### [STUDIO=<パス>|none] | Studio の check-agents-parity をこの engine で流す（Studio は凍結中なので release-verify の門から外してある）
	@if [ "$(STUDIO)" = "none" ]; then echo "[release] STUDIO=none: Studio との AGENTS の突き合わせを飛ばしました"; exit 0; fi; \
	 test -f "$(STUDIO)/Makefile" || { echo "[release] Studio の clone が見つかりません ($(STUDIO)・探した所: $(STUDIO_CANDIDATES))。STUDIO=<パス> で指定するか、無い環境なら STUDIO=none"; exit 1; }; \
	 git -C "$(STUDIO)" fetch -q origin main \
	   && [ "$$(git -C "$(STUDIO)" rev-parse HEAD)" = "$$(git -C "$(STUDIO)" rev-parse origin/main)" ] \
	   || { echo "[release] Studio の clone ($(STUDIO)) が origin/main と違います。git -C $(STUDIO) pull --ff-only で最新にしてから"; exit 1; }; \
	 echo "[release] Studio ($(STUDIO)) の check-agents-parity をこの engine で流します"; \
	 env -u JOBS -u ALL -u TEST -u SUITE -u ONLY $(MAKE) --no-print-directory -C "$(STUDIO)" MAKEOVERRIDES= check-agents-parity ENGINE="$(CURDIR)" \
	   || { echo "[release] sync-agents の出力が Studio の server/src/NewGame.flix とずれています。Studio 側も同じ変更を入れて main へ push してから公開してください"; exit 1; }
# gl-parity も全量ゲートの一員 — GL と SoftRaster の絵の退行はテストに出ないため。
# WhyNot: studio-parity を門に入れない — Studio は凍結中（plans/dashboard.md の 7 節）。凍結を解いたら戻す。
RELEASE_GATES := release-guard sync $(RELEASE_TEST) gl-parity
.PHONY: release
release: release-verify ### [JOBS=1] | release-verify と同じ

# 手元で門を通し、通した commit を印に書く。公開は CI の release-publish がする。
# WhyNot: 印に commit を書き、CI はそこから HEAD までの差が印だけかを見る。版やテストの名前だけだと、
# 門を通した後に入った変更も同じ印で出てしまう。
RELEASE_MARKER := release/verified.txt
.PHONY: release-verify
release-verify: $(RELEASE_GATES) ## [STUDIO=none] [JOBS=1] | リリースの門を手元で通し、通した commit を release/verified.txt に書く（公開は CI の release-publish）
	@mkdir -p $(dir $(RELEASE_MARKER))
	@printf 'version %s\nsha %s\ngates %s\nat %s\n' "$(VERSION)" "$(RELEASE_SHA)" "$(RELEASE_GATES)" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > $(RELEASE_MARKER)
	@echo "[release-verify] v$(VERSION) の門を $(RELEASE_SHA) で通しました。次は:"
	@echo "  git add $(RELEASE_MARKER) && git commit -m 'release: v$(VERSION) の門を通した' && git push"
	@echo "  → GitHub の Actions で release を main で起動 (CI が make release-publish を流す)"

# CI が公開の前に見る: 印の版が VERSION と同じ・印の commit から HEAD までの差が印だけ・タグがまだ無い。
.PHONY: release-marker-check
release-marker-check: ### | CI が公開の前に見るマーカー（版・commit から HEAD までの差・タグ）
	@test -f $(RELEASE_MARKER) || { echo "[release] $(RELEASE_MARKER) がありません。手元で make release-verify を通して commit してください"; exit 1; }
	@ver=$$(sed -n 's/^version //p' $(RELEASE_MARKER)); sha=$$(sed -n 's/^sha //p' $(RELEASE_MARKER)); \
	 [ "$$ver" = "$(VERSION)" ] || { echo "[release] 印の版 $$ver が Makefile の VERSION $(VERSION) と違います。make release-verify をやり直してください"; exit 1; }; \
	 git cat-file -e "$$sha^{commit}" 2>/dev/null || { echo "[release] 印の commit $$sha が履歴にありません (checkout の fetch-depth が浅いか、push していない)"; exit 1; }; \
	 git merge-base --is-ancestor "$$sha" HEAD || { echo "[release] 印の commit $$sha が HEAD の祖先ではありません"; exit 1; }; \
	 extra=$$(git diff --name-only "$$sha" HEAD -- . ':(exclude)$(RELEASE_MARKER)'); \
	 [ -z "$$extra" ] || { echo "[release] 門を通した $$sha の後に変わったファイルがあります。make release-verify をやり直してください:"; echo "$$extra"; exit 1; }; \
	 if git ls-remote --exit-code --tags origin "refs/tags/v$(VERSION)" >/dev/null 2>&1; then echo "[release] v$(VERSION) のタグがもうあります"; exit 1; fi; \
	 echo "[release] 印を確かめました: v$$ver は $$sha で門を通し、その後の変更は印だけ"

# CI が流す公開。テストは手元の release-verify が通した物を印で受け取る。
# WhyNot: CI で全量テストを流し直さない。描き出しのスナップショットは OS と JRE のフォントの差で CI ではずれる。
# studio-parity も Studio の clone が要るので手元の門に任せる。
.PHONY: release-publish
release-publish: release-marker-check ### | CI が流す公開（マーカーを確かめて組み、gh release）
	@# WhyNot: go-build を先に置く。release-guard が呼ぶ bin/fge は bin/fge-go を要り、CI の checkout には無い。
	@$(MAKE) --no-print-directory go-build
	@$(MAKE) --no-print-directory release-guard
	@$(MAKE) --no-print-directory sync
	@# WhyNot: gl-jar.yml に任せきらない — あちらが落ちていても、版を出す時に flix.toml が指す jar の置き場は必ず埋まる。
	@$(MAKE) --no-print-directory gl-jar-publish
	@# 後半は配る物を組んで Release に付ける。GL の層の jar は版の Release に添えない（flix.toml は置き場 fge-gl-<ハッシュ> を指す）。
	cd $(ENGINE_FULL_DIR) && "$(FLIX)" build-pkg
	@# WhyNot: build-pkg の後に置くのは、zip の中身に engine_full.fpkg が入るため。
	@# 先に組むと 1 つ前のバージョンの fpkg を配ってしまう。
	$(MAKE) bundle-zip
	$(MAKE) --no-print-directory release-fge-assets
	gh release create v$(VERSION) --repo ababup1192/flix_game_engine --target $(RELEASE_SHA) \
	  --title "v$(VERSION)" --generate-notes \
	  "$(ENGINE_FULL_FPKG_SRC)#$(ENGINE_FULL_FPKG_NAME)" \
	  "$(ENGINE_FULL_TOML_SRC)#$(ENGINE_FULL_TOML_NAME)" \
	  "$(BUNDLE_ZIP)" "$(BUNDLE_SUMS)" \
	  $(RELEASE_FGE_FILES)
	@echo "[release] v$(VERSION) を CI から公開しました。外部 fetch 検証: lib/ を消したサンプルで github:ababup1192/flix_game_engine v$(VERSION) を引けるか確認してください"
	@echo "[release] 任意: ゲームを追随させた後に make agent-eval-release で道具の選び方を測り、前の版と比べる（約 20 分・下がったお題が出る。docs/agent-eval.md）"

# ── 全体の fge（install.sh が入れる物）────────────────────
# Release に fge-<os>-<arch>（go-build の bin/dist/fge-go-<os>-<arch> を改名した物。Windows は .exe 付き）・fge-SHA256SUMS.txt・
# 版を埋めた install.sh と install.ps1（Windows）を添える。
# WhyNot: 今の SHA256SUMS.txt に足さない — 凍結した Studio の self-update がその 1 行の形を読む。別のファイルにする。
# WhyNot: arm64 の Windows を入れない — 後に回した（plans/windows.md 13 節）。
RELEASE_FGE_DIR     := build/release-fge
RELEASE_FGE_TARGETS := darwin-amd64 darwin-arm64 linux-amd64 linux-arm64 windows-amd64.exe
RELEASE_FGE_FILES    = $(addprefix $(RELEASE_FGE_DIR)/,$(addprefix fge-,$(RELEASE_FGE_TARGETS)) fge-SHA256SUMS.txt install.sh install.ps1)
.PHONY: release-fge-assets
release-fge-assets: ### | Release に添える全体の fge（fge-<os>-<arch>・fge-SHA256SUMS.txt・版を埋めた install.sh と install.ps1）を build/release-fge に組む
	@rm -rf "$(RELEASE_FGE_DIR)" && mkdir -p "$(RELEASE_FGE_DIR)"
	@for t in $(RELEASE_FGE_TARGETS); do \
	   src="$(GO_DIST)/fge-go-$$t"; \
	   [ -f "$$src" ] || { echo "!! $$src がありません (make go-build)"; exit 1; }; \
	   cp "$$src" "$(RELEASE_FGE_DIR)/fge-$$t" && chmod 755 "$(RELEASE_FGE_DIR)/fge-$$t" || exit 1; \
	 done
	@cd "$(RELEASE_FGE_DIR)" && shasum -a 256 $(addprefix fge-,$(RELEASE_FGE_TARGETS)) > fge-SHA256SUMS.txt
	@sed 's/^FGE_VERSION=.*/FGE_VERSION=$(VERSION)/' bin/install.sh > "$(RELEASE_FGE_DIR)/install.sh"
	@grep -qx 'FGE_VERSION=$(VERSION)' "$(RELEASE_FGE_DIR)/install.sh" \
	  || { echo "!! bin/install.sh に FGE_VERSION= の行がありません"; exit 1; }
	@sed "s/^\$$FgeVersion = .*/\$$FgeVersion = '$(VERSION)'/" bin/install.ps1 > "$(RELEASE_FGE_DIR)/install.ps1"
	@grep -qxF "\$$FgeVersion = '$(VERSION)'" "$(RELEASE_FGE_DIR)/install.ps1" \
	  || { echo "!! bin/install.ps1 に \$$FgeVersion = の行がありません"; exit 1; }
	@echo "[release-fge-assets] $(RELEASE_FGE_FILES)"

# ── 同梱用 zip ────────────────────────────────────────────
# Studio に同梱する engine 一式を、そのまま Release に添えられる zip にする。
# 中身の一覧は bin/lint-rules/stage-engine.json が source of truth で、組み立ても最後の照合も
# bin/fge stage-engine が持つ (Studio の make stage-engine・ci/package-windows.ps1 と同じ口)。
#
# Maven の取り物 (lib/cache)・LWJGL の natives・flixlint の本体と shim の jar は入れる。
# WhyNot: Studio 側の種 (@maven-seed) に任せない — Studio を通らずに install.sh と fge engines install で始める人は、
# 種が無いとゲームを作るたびに Maven Central と GitHub へ取りに行き、続けて作ると 429 で止まる。
#
# flix.jar は devbox profile が指す nix store の実体から借りる (Studio の FLIX_JAR と同じ
# 見つけ方)。手で置いた bin/flix.jar が古いことがあるので既定にしない。
BUNDLE_ZIP   := flix_game_engine-engine-v$(VERSION).zip
BUNDLE_STAGE := build/bundle/engine
BUNDLE_SUMS  := SHA256SUMS.txt
BUNDLE_NATIVES := build/bundle/natives
BUNDLE_MVN_CACHE := build/bundle/mvn-cache
BUNDLE_FLIXLINT := build/bundle/flixlint
BUNDLE_FLIX_JAR ?= $(shell real=$$(readlink -f .devbox/nix/profile/default/bin/flix 2>/dev/null); \
                     [ -n "$$real" ] && echo "$$(dirname $$(dirname $$real))/share/java/flix/flix.jar")
BUNDLE_FLIX_WRAPPER ?= bin/flix
.PHONY: bundle-zip check-bundle-flix
# 同梱する flix.jar の版が devbox.json の版と同じか。
# WhyNot: 置き場の有無だけで通さないのは、devbox install をし忘れた profile が古い flix を
# 指したままでも jar は在るため。0.35.5 はこれで 0.75.1 を配り、Studio でゲームが一切
# ビルドできなくなった (ゲームの flix.toml が求める版に届かない)。
check-bundle-flix: ### | 同梱する flix.jar の版が devbox.json の版と同じか
	@want=$$(grep -o 'flix_[0-9]*_[0-9]*_[0-9]*' devbox.json | head -n 1 | sed 's/^flix_//; s/_/./g'); \
	 java=.devbox/nix/profile/default/bin/java; [ -x "$$java" ] || java=java; \
	 got=$$("$$java" -jar "$(BUNDLE_FLIX_JAR)" --version 2>/dev/null | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -n 1); \
	 if [ -z "$$want" ] || [ "$$want" != "$$got" ]; then \
	   echo "[release] 同梱する flix.jar の版 ($${got:-読めない}) が devbox.json の版 ($${want:-読めない}) と違います: $(BUNDLE_FLIX_JAR)"; \
	   echo "[release] devbox install で profile を直してから組み直してください"; exit 1; \
	 fi; \
	 echo "[release] 同梱する flix.jar: $$got (devbox.json と一致)"
# WhyNot: 組む前に必ず go-build を通すのは、検査データ (bin/lint-rules/*.json) が git の
# 作業ツリーから、検査の中身 (bin/dist の fge-go) が前に組んだ物から来るため。
# 別々の経路なので、バイナリだけ古いまま配ると「宣言はあるのに入口が無い」バンドルになり、
# 配った先の precommit が毎回 exit 2 で止まる (0.32.0 の flix-reserved がこれ)。
bundle-zip: go-build ### | Studio に同梱する engine 一式を zip に固める（Release に添える）
	@test -n "$(BUNDLE_FLIX_JAR)" -a -f "$(BUNDLE_FLIX_JAR)" \
	  || (echo "!! flix.jar が見つかりません (BUNDLE_FLIX_JAR= で場所を指定してください)" && exit 1)
	@$(MAKE) --no-print-directory check-bundle-flix
	rm -rf build/bundle "$(BUNDLE_ZIP)" "$(BUNDLE_SUMS)"
	@# WhyNot: render_gl/lib/external を丸ごと渡さない — Maven の jar（LWJGL の本体など）は lib/cache の側で足り、zip が太るだけ。
	@# natives と GL の層の jar は coursier を通らないので、zip に無いと new-game のたびに Maven Central へ取りに行く。
	@mkdir -p "$(BUNDLE_NATIVES)"; \
	 for j in $(RENDER_GL_DIR)/lib/external/lwjgl-*-natives-*.jar $(RENDER_GL_DIR)/lib/external/fge-gl-*.jar; do \
	   [ -f "$$j" ] && cp "$$j" "$(BUNDLE_NATIVES)/"; \
	 done; \
	 ls "$(BUNDLE_NATIVES)"/lwjgl-*-natives-*.jar >/dev/null 2>&1 \
	   || { echo "!! $(RENDER_GL_DIR)/lib/external に LWJGL の natives がありません (make sync を流してください)"; exit 1; }
	@# Maven の取り物は engine_full の lib/cache（ゲームと同じ依存を持つ。普通は共有の置き場への symlink）から写す。
	@# WhyNot: ゲームの依存だけに絞らず置き場をまるごと写す — 推移的に引く物を解くのは coursier の仕事で、ここで解き直すと解き方が 2 つになる。
	@# 揃っているかは stage-engine が engine_full/flix.toml と突き合わせる。
	@src=$$(cd $(ENGINE_FULL_DIR)/lib/cache 2>/dev/null && pwd -P || $(MVN_CACHE_SHARE) --print-dir); \
	 [ -d "$$src" ] || { echo "!! Maven の取り物の置き場がありません ($$src)。engine_full を一度ビルドしてください (make sync-engine-full)"; exit 1; }; \
	 mkdir -p "$(BUNDLE_MVN_CACHE)" && cp -R "$$src"/. "$(BUNDLE_MVN_CACHE)"/ \
	 && find "$(BUNDLE_MVN_CACHE)" \( -name '*.lock' -o -name '*.part' \) -exec rm -f {} +
	@# flixlint は手元の置き場に無ければ flixlint-prepare が取ってくる（release の CI でも組める）。
	@eval "$$(bin/fge flixlint-prepare)" && [ -n "$$FLIXLINT_DIR" ] || { echo "!! flixlint の本体と shim の jar をそろえられません"; exit 1; }; \
	 ver=$$(basename "$$(dirname "$$FLIXLINT_DIR")"); \
	 mkdir -p "$(BUNDLE_FLIXLINT)/$$ver" && cp "$$FLIXLINT_SHIM" "$(BUNDLE_FLIXLINT)/$$ver/" && cp -R "$$FLIXLINT_DIR" "$(BUNDLE_FLIXLINT)/$$ver/src"
	@# WhyNot: --all-platforms で 5 種を全部入れる — 1 つに絞ると zip を組んだ機械 (CI は linux) 向けしか入らず、
	@# mac と Windows の Studio の「engine を更新」が、取ってきた bin/fge-go を走らせる所で exec format error になる。
	bin/fge stage-engine --out "$(BUNDLE_STAGE)" --all-platforms \
	  --flix-jar "$(BUNDLE_FLIX_JAR)" \
	  --flix-wrapper "$(BUNDLE_FLIX_WRAPPER)" \
	  --natives "$(BUNDLE_NATIVES)" \
	  --mvn-cache "$(BUNDLE_MVN_CACHE)" \
	  --flixlint "$(BUNDLE_FLIXLINT)"
	cd build/bundle && zip -qry "../../$(BUNDLE_ZIP)" engine
	@# WhyNot: 照合の相手を release でなく bundle-zip で作るのは、zip と対で作れば
	@# ズレが原理的に起きないため。Studio の self-update はこれと突き合わせてから差し替える。
	shasum -a 256 "$(BUNDLE_ZIP)" > "$(BUNDLE_SUMS)"
	@echo "[bundle-zip] $(BUNDLE_ZIP) ($$(du -h $(BUNDLE_ZIP) | cut -f1))"

# ── バージョン更新 (lockstep) ─────────────────────────────
# 5パッケージの flix.toml の [package] version と、パッケージ間・templates/bench の
# 自パッケージ依存参照の version を一括で上げる。flix コンパイラのバージョン (flix = "...") と
# flix-random など他リポ依存は触らない。使い方: make bump FROM=0.1.0 TO=0.1.1
# sed でなく perl なのは BSD/GNU の -i の非互換を踏まないため (toml は ASCII なので byte 処理で安全)。
.PHONY: bump
bump: ## FROM=x TO=y | 全 flix.toml の version と VERSION を一括で上げる（api-digest と追随の材料も作り直す）
	@test -n "$(FROM)" && test -n "$(TO)" || { echo "usage: make bump FROM=0.1.0 TO=0.1.1"; exit 1; }
	@# WhyNot: 書き換える前にも見る — 後でだけ見ると、pin の忘れで止まった時に版の字だけ書き換わった途中の形が残る。
	@$(MAKE) --no-print-directory gl-jar-pin-check
	@for f in $(ENGINE_DIR) $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR) $(ENGINE_FULL_DIR); do \
		perl -pi -e 's/^(version\s*=\s*)"\Q$(FROM)\E"/$${1}"$(TO)"/' "$$f/flix.toml"; \
	done
	@for f in $(ENGINE_DIR)/flix.toml $(RENDER_GL_DIR)/flix.toml $(ENGINE_WORLD_DIR)/flix.toml $(ENGINE_TOOLS_DIR)/flix.toml $(ENGINE_FULL_DIR)/flix.toml templates/*/flix.toml bench/*/flix.toml; do \
		[ -f "$$f" ] && perl -pi -e 's|(ababup1192/flix_[a-z_]*"[^"]*version = )"[0-9]+\.[0-9]+\.[0-9]+"|$${1}"$(TO)"|g' "$$f" || true; \
	done
	@# GL の層の jar の行は版を持たない（置き場は render_gl/java のハッシュ）。上の置き換えが触っていないかだけ見る。
	@$(MAKE) --no-print-directory gl-jar-pin-check
	@perl -pi -e 's/^(VERSION := ).*/$${1}$(TO)/' Makefile
	@$(MAKE) --no-print-directory api-digest VERSION=$(TO)
	@# WhyNot: リリースの中でなく bump で作るのは、release の途中で作ると未コミットの
	@# 生成物が同梱 zip にだけ入り、タグの中身には入らないため（後からそのバージョンを
	@# 取り出しても追随の材料が無い、という形になる）。
	@bin/fge migration-notes
	@echo "[bump] $(FROM) -> $(TO) 完了 (依存行は旧バージョンどれでも TO へ・flix-random と flix コンパイラのバージョンは据え置き。api-digest も再生成済み)。"

##@ 作業場とゲームへ配る物
# ── コミュニティビルド用ルート src/ ──────────────────────
# Flix 公式の community build (flix/flix の community-build.yaml) は、このリポジトリを
# checkout してルートで `flix build` を実行するだけで、make sync の fpkg 配布は走らない。
# そこでルート src/ に全エンジンパッケージの .flix をファイル単位の symlink で並べ、
# 5 パッケージを 1 ソースツリーとしてビルドできるようにする (ルートの flix.toml が対応)。
# ディレクトリ symlink は Flix のソース走査に追従されないため、必ずファイル単位で張る。
# エンジンに .flix を追加/削除/改名したら再実行して symlink 集を更新し、コミットする。
ROOT_SRC_PKGS := $(ENGINE_DIR) $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR)

.PHONY: sync-root-src
sync-root-src: ### | コミュニティビルド用のルート src/ の symlink 集を作り直す
	@for pkg in $(ROOT_SRC_PKGS); do rm -rf "src/$$pkg"; done
	@$(MAKE) --no-print-directory sync-root-src-missing
	@find src -type l | awk 'END { print "[sync-root-src] " NR " symlink(s)" }'

# 足りない symlink だけを張り、先の無い symlink だけを消す (今ある物は触らない)。
# WhyNot: make check から sync-root-src を流さない。先に src/<pkg> を丸ごと消すので、並べて走る別の確かめが
# 読んでいる最中のソースが消え、偽の赤で正しい書き換えが戻される。
.PHONY: sync-root-src-missing
sync-root-src-missing: ### | ルート src/ の足りない symlink だけを張り、先の無い物だけを消す（make check が呼ぶ）
	@for pkg in $(ROOT_SRC_PKGS); do $(LINK_FLIX) --relative --only-missing "$$pkg/src" "src/$$pkg" || exit 1; done; \
	find src -type l ! -exec test -e {} \; -exec rm -f {} +

# engine の上に載る 3 層 (render_gl / engine_world / engine_tools) の検査用の作業場を張る。
# .layers/<層>/ に flix.toml (層のものへの symlink) と、src/engine/ (engine のソース)・
# src/<層>/ (層のソース)・test/ (層のテストと読み込む資料) をファイル単位の symlink で並べる。
# 層どうしは互いのソースを持たないので、render_gl が engine_world を呼ぶような層の破れは
# ここでのコンパイルが止める。symlink なので、ソースを直したら張り直さずにそのまま組める
# (.flix を足した・消した・改名したときだけ張り直す。make test は毎回張り直す)。
# .layers/templates は engine_tools のテストが ../templates/ のフォントを読むための道。
.PHONY: sync-layers
sync-layers: gl-jar ## | render_gl / engine_world / engine_tools の検査用の作業場（.layers/）を張り直す
	@for pkg in $(LAYER_PKGS); do \
		dir="$(LAYER_ROOT)/$$pkg"; \
		rm -rf "$$dir/src" "$$dir/test"; \
		mkdir -p "$$dir"; \
		ln -sfn "$(CURDIR)/$$pkg/flix.toml" "$$dir/flix.toml"; \
		for part in "$(ENGINE_DIR)/src:src/$(ENGINE_DIR)" "$$pkg/src:src/$$pkg" "$$pkg/test:test"; do \
			from="$${part%%:*}"; to="$${part#*:}"; \
			[ -d "$$from" ] || continue; \
			bin/link-tree.sh "$(CURDIR)/$$from" "$$dir/$$to" || exit 1; \
		done; \
	done; \
	ln -sfn ../templates "$(LAYER_ROOT)/templates"; \
	find $(LAYER_ROOT) -type l | awk 'END { print "[sync-layers] " NR " symlink(s)" }'

# agents-pack をゲームに配る。配布物一覧の source of truth は agents-pack/manifest.json で、
# Makefile はその解釈器 bin/fge sync-agents を呼ぶだけ (Studio の配布も同じ manifest を
# 読むので、リストの二重管理で片方だけ腐ることが無い)。冪等。
# バージョンはルート flix.toml でなく $(VERSION) (bump が進める実体) を刻む。ゲーム側の
# bin/fge status がこの刻印と engine Makefile の VERSION を照らし、陳腐化を知らせる。
.PHONY: sync-agents
sync-agents: ## GAME=<dir> | agents-pack をゲームに配る（manifest.json が一覧。bin/fge-go も配る）
	@if [ -z "$(GAME)" ]; then echo "error: GAME を指定してください (make sync-agents GAME=/path/to/game)"; exit 1; fi
	@bin/fge sync-agents --game "$(GAME)" --version "$(VERSION)"
	@$(MAKE) --no-print-directory sync-fge-go GAME="$(GAME)"

# 検査の中身は bin/fge-go (Go のバイナリ)。配る先の OS/CPU に合う 1 つだけを置く。
# WhyNot: manifest.json の copy に並べないのは、あそこが「どの OS でも同じ物を配る」表で、
# 配る先ごとに 1 つ選ぶ仕組みが無いため (全部配ると 4 つ × 4.2M が各リポに積まれる)。
.PHONY: sync-fge-go
# WhyNot: 配る前に go-build を通すのは、規約データ (lint-rules) を sync-agents が git の
# 作業ツリーから配るのに対し、検査の中身はここが bin/dist から配るため。組み直しを忘れると
# 「宣言はあるのに入口が無い」ゲームができる。Go のビルドキャッシュが効くので数秒。
#
# 置き方（別名に書いてから rename・Windows は今の物を .old に退けてから）の WhyNot は go/internal/exereplace。
#
# WhyNot: 配った版（go/ が無い）は組めないので、同梱の bin/fge-go（配った先の OS/CPU 向けの 1 本）をそのまま配る。
sync-fge-go: ### GAME=<dir> | 配る先の OS/CPU に合う bin/fge-go を 1 つだけゲームへ置く
	@if [ -z "$(GAME)" ]; then echo "error: GAME を指定してください"; exit 1; fi
	@[ -n "$(IS_BUNDLE)" ] || $(MAKE) --no-print-directory go-build GO_OSARCH="$(GO_HOST)"
	@bin/fge sync-fge-go --game "$(GAME)"

##@ 規約と文書
# 規約の本文は docs/ に 1 つだけ置く。CLAUDE.md は AGENTS.md を import するだけ、
# .claude/rules/ は bin/fge gen-rules の生成物。手で 2 か所に書かないので、ずれない。
.PHONY: rules
rules: api-digest ### | docs/ の規約から .claude/rules/ を作り直す（api-digest も）
	@bin/fge gen-rules

# engine/engine_world/engine_tools の pub API を 1 枚のダイジェストに畳む。
# AI エージェントが型・引数を調べる時、ソースを grep する前にまずここを読めば済む。
.PHONY: api-digest
api-digest: ### | engine の pub API を docs/api-digest.md に 1 つにまとめる
	@bin/fge api-digest

# 規約まわりの配線が崩れていないかの検査（生成はしない）。名前つきの小さな検査の集まりで、1 つ落ちても後ろを流し、最後に落ちた名前を並べる。
# 名前ごとの入力（どのファイルを触った時に効くか）は根の gates.json の docs-sync:<名前> の門が持つ（bin/fge gates --files で引く）。
# DOCS_SYNC_DESC_<名前> は流す時に出す 1 行、DOCS_SYNC_SH_<名前> はシェルの 1 文（落ちたら非 0）。
# WhyNot: 名前ごとのターゲットに分けない — make -j で並ぶと出力が混ざる（lint と同じ）。
DOCS_SYNC_NAMES := claude-import rules px-ops check-codes skill-table core-skills core-bridge skill-links skill-frontmatter \
	skill-sync old-prim-names manifest follow-latest check-refs api-index api-digest docs-links template-claude gates \
	jdk-major template-engine

DOCS_SYNC_DESC_claude-import = CLAUDE.md が AGENTS.md を import しているか
DOCS_SYNC_SH_claude-import = \
	if [ ! -f CLAUDE.md ] || [ ! -f AGENTS.md ]; then echo "[check-docs-sync] CLAUDE.md か AGENTS.md が見つかりません"; exit 1; fi; \
	grep -q '^@AGENTS.md' CLAUDE.md || { echo "[check-docs-sync] NG: CLAUDE.md は @AGENTS.md の 1 行にしてください（本文の二重管理を避ける）"; exit 1; }

DOCS_SYNC_DESC_rules = .claude/rules が docs/ と一致しているか
DOCS_SYNC_SH_rules = bin/fge gen-rules --check

DOCS_SYNC_DESC_px-ops = docs/px-ops.md と px のスキーマが op の登録と一致しているか
DOCS_SYNC_SH_px-ops = ok=1; bin/fge px ops --check || ok=0; bin/fge px schema --check || ok=0; [ $$ok = 1 ]

DOCS_SYNC_DESC_check-codes = docs/check-codes.md が検査の code の表と一致しているか
DOCS_SYNC_SH_check-codes = bin/fge check codes --check

DOCS_SYNC_DESC_skill-table = AGENTS.md のスキル表が実在する skill を指しているか
DOCS_SYNC_SH_skill-table = ok=1; \
	for s in $$(grep -o '`/[a-z][a-z-]*`' AGENTS.md | tr -d '`/' | sort -u); do \
	  if [ ! -f ".claude/skills/$$s/SKILL.md" ]; then \
	    echo "[check-docs-sync] NG: AGENTS.md が /$$s を指していますが .claude/skills/$$s/SKILL.md がありません"; ok=0; \
	  fi; \
	done; [ $$ok = 1 ]

DOCS_SYNC_DESC_core-skills = AGENTS.core.md のスキル参照が agents-pack/skills に実在するか
DOCS_SYNC_SH_core-skills = ok=1; \
	for s in $$(grep -o '`/[a-z][a-z-]*`' agents-pack/AGENTS.core.md | tr -d '`/' | sort -u) \
	         $$(grep -o '\.claude/skills/[a-z][a-z-]*' agents-pack/AGENTS.core.md | sed 's|.*/||' | sort -u); do \
	  if [ ! -f "agents-pack/skills/$$s/SKILL.md" ]; then \
	    echo "[check-docs-sync] NG: AGENTS.core.md が $$s を指していますが agents-pack/skills/$$s/SKILL.md がありません（ゲームに配られるのは agents-pack/skills だけ）"; ok=0; \
	  fi; \
	done; [ $$ok = 1 ]

DOCS_SYNC_DESC_core-bridge = AGENTS.core.md に skills への橋渡しがあるか
DOCS_SYNC_SH_core-bridge = grep -q 'SKILL.md' agents-pack/AGENTS.core.md || \
	{ echo "[check-docs-sync] NG: AGENTS.core.md に「.claude/skills/<名前>/SKILL.md を直接読む」案内がありません（スキル機構を持たないエージェントが skills に気づけなくなります）"; exit 1; }

DOCS_SYNC_DESC_skill-links = agents-pack/skills にコピー先のゲームで切れる相対リンクが無いか
DOCS_SYNC_SH_skill-links = if grep -rn '](\.\./' agents-pack/skills/; then \
	  echo "[check-docs-sync] NG: 上の相対リンクは skills フォルダの外を指していて、コピー先のゲームで切れます。「engine リポの docs/...」の文言参照にしてください"; exit 1; \
	fi

DOCS_SYNC_DESC_skill-frontmatter = skill の frontmatter に name と description があるか
DOCS_SYNC_SH_skill-frontmatter = ok=1; \
	for f in .claude/skills/*/SKILL.md agents-pack/skills/*/SKILL.md; do \
	  if ! grep -q '^name:' $$f; then echo "[check-docs-sync] NG: $$f に name がありません"; ok=0; fi; \
	  if ! grep -q '^description:' $$f; then echo "[check-docs-sync] NG: $$f に description がありません"; ok=0; fi; \
	done; [ $$ok = 1 ]

DOCS_SYNC_DESC_skill-sync = 同名スキルの sync 印が両側で一致するか
DOCS_SYNC_SH_skill-sync = ok=1; \
	for d in agents-pack/skills/*/; do \
	  s=$$(basename $$d); \
	  if [ -f ".claude/skills/$$s/SKILL.md" ]; then \
	    a=$$(grep '^sync:' "$$d/SKILL.md" | head -1); \
	    b=$$(grep '^sync:' ".claude/skills/$$s/SKILL.md" | head -1); \
	    if [ -z "$$a" ] || [ "$$a" != "$$b" ]; then \
	      echo "[check-docs-sync] NG: skill $$s の sync 印が不一致（agents-pack=$$a / .claude=$${b}）。片方を直したらもう片方へ内容を移植し、両方の sync: を同じ日付に上げる"; ok=0; \
	    fi; \
	  fi; \
	done; [ $$ok = 1 ]

DOCS_SYNC_DESC_old-prim-names = 図形プリミティブの旧名 Render.box 等が docs/ と AGENTS.md に残っていないか
DOCS_SYNC_SH_old-prim-names = \
	old_names='Render\.(box|boxAt|orBoxAt|circle|circleAt|polygon|ngon|ngonAt|ellipse|ellipseAt|ellipseSegs|ellipseSegsAt|ellipseSegsFor|sector|sectorAt|circleSegment|circleSegmentAt|star|starAt|lineQuad|lineSeg)\b'; \
	if grep -rlE "$$old_names" docs/*.md AGENTS.md 2>/dev/null | grep -v docs/api-digest; then \
	  echo "[check-docs-sync] NG: 上のファイルに図形プリミティブの旧名（Render.box 等）が残っています。RawDraw.* へ書き換えてください"; exit 1; \
	fi

DOCS_SYNC_DESC_manifest = agents-pack/manifest.json が正しい JSON で src が全実在するか
DOCS_SYNC_SH_manifest = bin/fge sync-agents --check-manifest

# WhyNot: 版によらないスキルのコマンドを Go 側の表と比べない — 古い版のゲームに無いコマンドかどうかは、
# 版ごとの make のターゲットを全部持っていないと決められない。人が決めた一覧（manifest）と比べるだけにする。
DOCS_SYNC_DESC_follow-latest = 版によらないスキル（manifest の followLatest）の中のコマンドが followLatest.commands にあるか
DOCS_SYNC_SH_follow-latest = bin/fge sync-agents --check-follow-latest

DOCS_SYNC_DESC_check-refs = Makefile / templates / agents-pack の参照先が実在するか
DOCS_SYNC_SH_check-refs = bin/fge check-refs

DOCS_SYNC_DESC_api-index = pub def を持つモジュールが API 索引に載っているか
DOCS_SYNC_SH_api-index = bin/fge check-api-index

DOCS_SYNC_DESC_api-digest = docs/api-digest.md が作り直しても差分ゼロか
DOCS_SYNC_SH_api-digest = bin/fge api-digest --check

DOCS_SYNC_DESC_docs-links = AGENTS.md から docs/ への導線があるか
DOCS_SYNC_SH_docs-links = ok=1; \
	for kw in docs/audio.md docs/module-index.md docs/drawing-floor.md docs/flix-conventions.md docs/z-bands.md docs/performance.md; do \
	  if ! grep -q "$$kw" AGENTS.md; then echo "[check-docs-sync] NG: AGENTS.md に $$kw への導線がありません"; ok=0; fi; \
	done; [ $$ok = 1 ]

DOCS_SYNC_DESC_template-claude = templates/ に CLAUDE.md を置いていないか
DOCS_SYNC_SH_template-claude = ok=1; \
	for f in templates/*/CLAUDE.md; do \
	  if [ -f "$$f" ]; then \
	    echo "[check-docs-sync] NG: $$f は make new-game の sync-agents が @AGENTS.md で上書きするので、書いても捨てられます。ゲーム固有の事は AGENTS.local.md に、共通の方針は agents-pack/AGENTS.core.md に書いてください"; ok=0; \
	  fi; \
	done; [ $$ok = 1 ]

DOCS_SYNC_DESC_gates = 根の gates.json が Makefile の口・テストのパッケージ・検査の名前・リリースの門とそろっているか
DOCS_SYNC_SH_gates = bin/fge gates --check

# WhyNot: 版の全部（25.0.3）をそろえない — devbox の JDK は OS ごとに違う（macOS は Zulu・Linux は nixpkgs の OpenJDK）。
# 主な版が違うと、配った engine と作者の手元で使える Java の機能が食い違う。
DOCS_SYNC_DESC_jdk-major = mk/jdk.mk の JDK の主な版が devbox.json・devbox.lock の jdk の主な版と同じか
DOCS_SYNC_SH_jdk-major = mk=$$(sed -n 's/^FGE_JDK_VERSION[[:space:]]*[:?]*=[[:space:]]*\([0-9]*\).*/\1/p' mk/jdk.mk); \
	got=$$( { grep -o '"jdk@[0-9]*"' devbox.json devbox.lock | sed 's/.*@//; s/"//'; grep -o -- 'jdk-[0-9][0-9]*\.' devbox.lock | sed 's/jdk-//; s/\.//'; } | sort -u | tr '\n' ' '); \
	if [ -n "$$mk" ] && [ "$$got" = "$$mk " ]; then exit 0; fi; \
	echo "[check-docs-sync] NG: mk/jdk.mk の主な版（$${mk:-読めない}）と devbox の jdk の主な版（$${got:-読めない}）が違います。版を上げる時は両方を一緒に替えてください"; exit 1

# WhyNot: 6 つを同じ形にそろえる — ENGINE の決まりは Go の ResolveEngineDir と同じでなければならず、1 つだけずれると
# そのテンプレートから作ったゲームだけが別の engine を読む。
DOCS_SYNC_DESC_template-engine = テンプレートの Makefile の ENGINE の既定の行（FGE_VERSION と ENGINE ?=）が 6 つとも同じ形か
DOCS_SYNC_SH_template-engine = ok=1; first=""; \
	for f in templates/*/Makefile; do \
	  lines=$$(grep -E '^(FGE_VERSION :=|ENGINE \?=)' "$$f"); \
	  if [ "$$(printf '%s\n' "$$lines" | grep -c .)" != 2 ]; then echo "[check-docs-sync] NG: $$f に FGE_VERSION := と ENGINE ?= の行が 1 つずつありません"; ok=0; continue; fi; \
	  if [ -z "$$first" ]; then first=$$f; want=$$lines; \
	  elif [ "$$lines" != "$$want" ]; then echo "[check-docs-sync] NG: $$f の ENGINE の既定の行が $$first と違います"; ok=0; fi; \
	done; [ $$ok = 1 ]

DOCS_SYNC_RUN := $(if $(ONLY),$(subst $(comma), ,$(ONLY)),$(DOCS_SYNC_NAMES))
.PHONY: check-docs-sync
check-docs-sync: ## [ONLY=<名前>,…] | 規約まわりの配線が崩れていないかの検査（生成はしない・無ければ全部）。知らない名前を渡すと名前の一覧が出る
	@$(if $(filter-out $(DOCS_SYNC_NAMES),$(DOCS_SYNC_RUN)),$(error [check-docs-sync] 知らない名前: $(filter-out $(DOCS_SYNC_NAMES),$(DOCS_SYNC_RUN))（名前: $(DOCS_SYNC_NAMES)）))failed=""; \
	$(foreach n,$(DOCS_SYNC_RUN),echo "[check-docs-sync] $(DOCS_SYNC_DESC_$n)"; ( $(DOCS_SYNC_SH_$n) ) || failed="$$failed $n"; ) \
	if [ -n "$$failed" ]; then echo "[check-docs-sync] 落ちた物:$$failed"; exit 1; fi; \
	echo "[check-docs-sync] OK"

##@ 門をまとめて流す
# 門の一覧（make の口・当たるファイル・いつ流すか）は根の gates.json。流し方（suite）の中身もそこに書き、ここには書かない。
# bin/fge gates（一覧）・bin/fge gates --files <パス…>（当たる門だけ。流さない）。
# WhyNot: make test-<名前> の形にしない — test-% はパッケージ 1 本のテストの口で、suite の名前がテンプレートの名前と取り合う。
# 下の ##> の行の名前は gates.json の suites と同じ並び（bin/fge gates --check が見る）。
##> make verify SUITE=quick|test|release|gui|affected | quick=作業中の型検査・素振り・lint・配線／test=全部のテスト／release=リリースの門／gui=画面を開く門／affected=差分から選んで（bin/fge test-select・SINCE=<ref>・GUI=1）
# affected は選ぶ前に、go/ の下に bin/fge-go より新しいファイル（.go・embed の素材・go.mod）があれば go-build を流す。
# WhyNot: 古い bin/fge-go のまま選ばない — 選ぶ表の読み方そのものが go にあり、直した回に古い決まりで選ぶ。
.PHONY: verify
verify: ## SUITE=<名前> [DRY=1] [ARGS="K=V …"] [SINCE=<ref>] [GUI=1] | 流し方を 1 つ選んで門を順に流す（SUITE が無ければ一覧・DRY=1 は何を流すかだけ）
	@if [ -z "$(SUITE)" ]; then bin/fge gates --suites; exit 0; fi; \
	if [ "$(SUITE)" = affected ] && [ -n "$$(find go -type f -newer bin/fge-go 2>/dev/null | head -1)" ]; then \
	  echo "[verify] go/ が bin/fge-go より新しいので、選ぶ前に go-build"; $(MAKE) --no-print-directory go-build || exit 1; fi; \
	bin/fge gates --suite "$(SUITE)" $(if $(DRY),--dry-run) $(if $(SINCE),--since "$(SINCE)") $(if $(GUI),--gui) -- $(ARGS)

# 答え合わせ（plans/test-selection.md の 6 節・12.8）。台の worktree（.claude/worktrees/replay-scratch）を立て、コミットごとに
# 選んだ門（sync-engine-full・check・test・check-pkgs）と全量（make test ALL=1・check-pkgs の全部）を流して比べる。結果は build/test-select/replay/。
# WhyNot: verify の suite にしない — 1 本 10 分を超え、作業中の確かめではなく夜に流す物。
.PHONY: test-select-replay
test-select-replay: ### RANGE=<a>..<b> | COMMITS=<sha,…> | 答え合わせ: 過去のコミットの src を戻した赤で、選んだ門と全量の答えを比べる（1 本 10 分前後）
	@if [ -n "$$(find go -type f -newer bin/fge-go 2>/dev/null | head -1)" ]; then $(MAKE) --no-print-directory go-build || exit 1; fi; \
	bin/fge test-select-replay $(if $(RANGE),--range "$(RANGE)") $(if $(COMMITS),--commits "$(COMMITS)")

# ステージした物と作業ツリーの差分（追跡していない新しいファイルを含む）でコミットの門を素振りする。 消したファイルは本物の precommit と同じく渡さない（--diff-filter=ACMR）。
# jargon はステージした行（git diff --cached）しか見ないので、ステージしていない行の独自語はここでは拾えない。
.PHONY: precommit-dry
# FILES_FROM=<ファイル> は差分を見ず、そのファイルの 1 行 1 つのパスで素振りする（bin/fge test-select が SINCE や --files の差を渡す）。
precommit-dry: ### [FILES_FROM=<ファイル>] | ステージした物と作業ツリーの差分で bin/fge precommit を素振りする（コミットはしない）
	@if [ -n "$(FILES_FROM)" ]; then files=$$(grep -v '^$$' "$(FILES_FROM)" | while IFS= read -r f; do [ -e "$$f" ] && printf '%s\n' "$$f"; done); \
	else files=$$( { git diff --name-only --diff-filter=ACMR HEAD; git ls-files --others --exclude-standard; } | sort -u); fi; \
	if [ -z "$$files" ]; then echo "[precommit-dry] 差分がありません"; exit 0; fi; \
	bin/fge precommit --files $$files

# テストを持たないパッケージ（bench）の型検査。bin/fge test-select が packages の check: true から DIRS を束ねる。
# make -C <フォルダ> check を持つ所はそれ（webgpu_v1/v2 は木を組んでから・crowd2d などは bench/common の写しの比べも）・無ければ bin/flix check。
.PHONY: check-pkgs
check-pkgs: ### DIRS="<フォルダ…>" | テストを持たないパッケージを 1 つずつ型検査する（赤があっても最後まで流して並べる）
	@[ -n "$(DIRS)" ] || { echo "[check-pkgs] DIRS=\"<フォルダ…>\" を渡す"; exit 2; }; \
	failed=""; for d in $(DIRS); do \
	  [ -d "$$d" ] || { echo "[check-pkgs] $$d がありません"; failed="$$failed $$d"; continue; }; \
	  echo "===== $$d ====="; \
	  if [ -f "$$d/Makefile" ] && grep -q '^check:' "$$d/Makefile"; then $(MAKE) --no-print-directory -C "$$d" check || failed="$$failed $$d"; \
	  else (cd "$$d" && "$(FLIX)" check) || failed="$$failed $$d"; fi; \
	done; \
	if [ -n "$$failed" ]; then echo "[check-pkgs] 赤:$$failed"; exit 1; fi; echo "[check-pkgs] OK"

# game-starter を build/new-game-check へ産み、make new-game の産声の確認（check → test → lint-flixlint → render-all）を通す。
# WhyNot: game-starter を素のフォルダで組まない — src に new-game が埋める字（__WW__ など）が残っていて読めない。
NEW_GAME_CHECK_DIR := $(CURDIR)/build/new-game-check
.PHONY: new-game-check
new-game-check: ### | game-starter を build/new-game-check へ産んで産声の確認を通す（engine 側か game-starter を直した時・bin/fge test-select が選ぶ）
	@case "$(NEW_GAME_CHECK_DIR)" in */build/new-game-check) rm -r -f "$(NEW_GAME_CHECK_DIR)";; *) exit 2;; esac
	@$(MAKE) --no-print-directory new-game GAME="$(NEW_GAME_CHECK_DIR)" NAME=newgamecheck TITLE=check

# bin/fge gates --check が Makefile の値を受け取る口（1 行 1 つ）。
.PHONY: gates-facts
gates-facts: ### | gates.json と比べる Makefile の値（テストのパッケージ・lint と check-docs-sync の名前・リリースの門）
	@echo "test-pkgs $(notdir $(TEST_DIRS) $(TEMPLATE_DIRS) $(BENCH_TEST_DIRS))"
	@echo "lint-names $(LINT_NAMES)"
	@echo "docs-sync-names $(DOCS_SYNC_NAMES)"
	@echo "release-gates $(RELEASE_GATES)"

# ── 新しいゲームを 1 コマンドで産む ──────────────────────
# 使い方: make new-game GAME=/abs/path/to/dir NAME=<パッケージ名> TITLE=<題名> W=240 H=320 TEMPLATE=sound-novel-starter
#   - GAME  … 生成先（存在しない絶対パス）。
#   - TEMPLATE … 複製元（templates/ 直下の名前。省略時は game-starter）。
#   - NAME  … Flix パッケージ名（小文字英字はじまり・[a-z0-9_]）。sprite の entityId にも使う。
#   - TITLE … ウィンドウの題名（省略時は NAME）。
#   - W/H   … design 解像度（省略時は 480×300。ウィンドウはその 2 倍）。
# 中身は bin/fge new-game（go/internal/scaffold）。テンプレートを写して __NAME__/__TITLE__/__W__/__H__/__WW__/__WH__ を置換し、
# lib/ を engine の手元の物から種付けし、git init（commit はしない）・sync-agents・sync-fge-go の後に check → test → render を通す。
# ここに残すのは engine の作業コピーだけで要る前処理（engine-full-fresh・fge-go を組む）。
# 題名は自由文（アポストロフィ・空白・記号を含みうる）。make の export で環境変数として渡し（execve が値をそのまま載せる）、
# recipe では "$$NG_TITLE" で読む（make の展開を '...' や "..." に埋めると ' や " で構文が壊れる）。
NG_TITLE = $(if $(TITLE),$(TITLE),$(NAME))
export NG_TITLE

##@ ゲームを産む・上げる
# engine_full.fpkg がソースより古いまま先へ進まない。作業コピーなら、その場で sync-engine-full を流して作り直してから進む。
# WhyNot: 「在るかどうか」だけでは足りない。fpkg のバージョン名は bump で進むので、中身が
# 古くても名前は新しいバージョンに見える。それがゲームの lib/ や Studio の .app へ写ると、
# Flix は「バージョン名が同じなら取り直さない」ので誰も気づけず、engine のソースにも Release
# にも在る def が「Undefined name」になる。
# 判定は mtime なので、git checkout 直後は中身が同じでも古く見えることがある。空振りは
# sync-engine-full を 1 回回せば済む側の失敗なので、見逃すよりそちらを選ぶ（その 1 回はここで流す）。
# WhyNot: 置き場の今のエントリが組んだ束・toml・版と同じかまで見る — 手で build-pkg した後や、版を上げて sync していない時は、
# ゲームへ写すのが置き場の古い束（中の version も古い）になる。
# WhyNot: 4 つの src に未コミットの差がある時・HEAD が main に入っていない時は作り直さずに止める — 作業中の engine が版の名前を付けてゲームへ運ばれる。
# WhyNot: 作り直す時はブラウザ版の束（sync-engine-full-web）も組む — 同じ版の名前のまま古い中身が残り、ゲームの export-web が新しい def を知らずに止まる。
# 古い理由を 1 行ずつ出すシェルの 1 文（古くなければ何も出さない）。
ENGINE_FULL_STALE = if [ ! -f "$(ENGINE_FULL_FPKG_SRC)" ]; then echo "$(ENGINE_FULL_FPKG_SRC) が無い"; else \
	  find $(ROOT_SRC_PKGS:%=%/src) -name '*.flix' -newer "$(ENGINE_FULL_FPKG_SRC)" 2>/dev/null | head -5 | sed 's/^/ソースの方が新しい: /'; \
	  entry=$$(bin/fpkg-store.sh path engine_full 2>/dev/null); base=$$(basename "$$entry" 2>/dev/null); \
	  if [ -z "$$entry" ]; then echo "置き場（build/fpkg-store）に engine_full が無い"; \
	  else case "$$base" in (engine_full-$(VERSION)-*) ;; (*) echo "置き場の今のエントリ（$${base}）が v$(VERSION) の物ではない";; esac; \
	    { cmp -s "$$entry/package.fpkg" "$(ENGINE_FULL_FPKG_SRC)" && cmp -s "$$entry/flix.toml" "$(ENGINE_FULL_TOML_SRC)"; } || \
	      echo "置き場の今の束（$${base}）が $(ENGINE_FULL_FPKG_SRC)・$(ENGINE_FULL_TOML_SRC) と違う"; fi; fi
.PHONY: engine-full-fresh
# 配った版はリリースが組んだ fpkg をそのまま使う（ソースの時刻は zip を開いた時刻なので、比べると空振りで止まる）。
engine-full-fresh: ### | engine_full.fpkg が古くないか（古ければ作業コピーでは sync-engine-full を流す・new-game・upgrade-game の前提）
	@if [ -n "$(IS_BUNDLE)" ]; then \
	  [ -f "$(ENGINE_FULL_FPKG_SEED)" ] || { echo "error: $(ENGINE_FULL_FPKG_SEED) がありません（配った engine が欠けています。入れ直してください）"; exit 1; }; \
	  exit 0; \
	fi; \
	why=$$($(ENGINE_FULL_STALE)); \
	[ -n "$$why" ] || exit 0; \
	echo "[engine-full-fresh] engine_full の束が古い:"; echo "$$why" | sed 's/^/  /'; \
	dirty=$$(git status --porcelain -- $(ROOT_SRC_PKGS:%=%/src) 2>/dev/null | head -10); \
	if [ -n "$$dirty" ]; then \
	  echo "error: engine のソースに未コミットの差があるので作り直しません（作業中の物を v$(VERSION) の名前でゲームへ運ばないため）:"; \
	  echo "$$dirty" | sed 's/^/  /'; \
	  echo "  次: コミットするか戻してから打ち直す（承知で運ぶなら make sync-engine-full を流してから）"; exit 1; \
	fi; \
	if [ "$(FGE_ANY_BRANCH)" != 1 ] && git rev-parse -q --verify refs/heads/main >/dev/null 2>&1 && ! git merge-base --is-ancestor HEAD main 2>/dev/null; then \
	  echo "error: HEAD（$$(git rev-parse --abbrev-ref HEAD)）が main に入っていないコミットを持つので、new-game・upgrade-game の前に engine_full の束を作り直しません（まだ出していない作業を v$(VERSION) の名前でゲームへ運ばないため）"; \
	  echo "  次: main で打ち直す（承知でこの枝の engine を使うなら FGE_ANY_BRANCH=1 を付けて打ち直す）"; exit 1; \
	fi; \
	if git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null 2>&1; then \
	  commits=$$(git log --oneline "v$(VERSION)..HEAD" -- $(ROOT_SRC_PKGS:%=%/src) 2>/dev/null); \
	  if [ -n "$$commits" ]; then echo "[engine-full-fresh] v$(VERSION) のタグの後のコミットも束に入ります:"; echo "$$commits" | sed 's/^/  /'; \
	  else echo "[engine-full-fresh] ソースは v$(VERSION) のタグと同じです"; fi; \
	fi; \
	echo "[engine-full-fresh] make sync-engine-full と sync-engine-full-web を流して作り直します"; \
	$(MAKE) --no-print-directory sync-engine-full || exit 1; \
	$(MAKE) --no-print-directory sync-engine-full-web || exit 1; \
	why=$$($(ENGINE_FULL_STALE)); \
	[ -z "$$why" ] || { echo "error: sync-engine-full の後も束が古いままです:"; echo "$$why" | sed 's/^/  /'; exit 1; }

.PHONY: new-game
new-game: engine-full-fresh ## GAME=/abs/path NAME=<名前> [TITLE=] [W=] [H=] [TEMPLATE=] [PACK_NOTE=0] | 新しいゲームを 1 コマンドで産む（check → test → render-all まで通す）
	@[ -n "$(IS_BUNDLE)" ] || $(MAKE) --no-print-directory go-build GO_OSARCH="$(GO_HOST)"
	@bin/fge new-game --game "$(GAME)" --name "$(NAME)" --title "$$NG_TITLE" --w "$(W)" --h "$(H)" --template "$(TEMPLATE)" \
	  $(if $(filter 0,$(PACK_NOTE)),--no-pack-note)

# ── ゲームの engine バージョン追随 ────────────────────────────────
# ゲームの flix.toml が指す flix_game_engine のバージョンをこの engine の $(VERSION) へ上げ、
# lib/ に対応する fpkg + toml を置き、agents-pack も配り直す。bin/fge status の
# 「engine バージョンズレ」を見た人が 1 手で追随する入口 (テンプレの make engine-upgrade が
# ここへ委譲する)。自動では走らせない — バージョン上げは挙動・リファレンス画像まで変わりうる
# 「人が選ぶ側」の変更。
# 中身は bin/fge upgrade-game (順番・巻き戻し・指示書の書き出し)。ここは engine 側にしか
# 無い置き場 (fpkg の在り処・lib/ の中の名前) を渡すだけにして、二重管理を作らない。
#
# 終了コードの意味 (0 上げ切った / 3 追随待ち / 1 想定外 / 2 引数と入出力)。
# 非互換のあるバージョン上げでは、エージェントが直すまで check は必ず赤なので、
# 3 はここで 0 に潰す — ただし「上げ切った」ではない。何をすべきかは道具が画面に書く
# (ゲームの直下の UPDATE_PLAN.md)。CI や Studio から区別したいときは bin/fge を直に呼ぶ。
#
# REFERENCE=1 で絵の比較 (reference-check) も回す。既定で回さないのは render-all を
# 連れてきて数分かかり、得られるのが指示書の 1 行だけのため。
.PHONY: upgrade-game
upgrade-game: engine-full-fresh ### GAME=/abs/path [REFERENCE=1] | ゲームの engine の版をこの engine へ上げる（ゲームの make engine-upgrade がここへ来る）
	@if [ -z "$(GAME)" ]; then echo "error: GAME を指定してください (make upgrade-game GAME=/abs/path)"; exit 1; fi
	@[ -n "$(IS_BUNDLE)" ] || $(MAKE) --no-print-directory go-build GO_OSARCH="$(GO_HOST)"
	@$(ENGINE_FULL_GAME_FILES); \
	bin/fge upgrade-game --game "$(GAME)" --version "$(VERSION)" \
	  --fpkg "$$fpkg" --toml "$$toml" \
	  --dest "$(ENGINE_FULL_SUBPATH)" --make "$(MAKE)" \
	  --fpkg-name "$(ENGINE_FULL_FPKG_NAME)" --toml-name "$(ENGINE_FULL_TOML_NAME)" \
	  $(if $(IS_BUNDLE),--no-content-swap,) $(if $(REFERENCE),--reference,) || [ $$? -eq 3 ]

# WhyNot: 頭で取り込まない — 先に読んだターゲットが既定のターゲットになり、素の make が status でなく help になる。
include mk/common.mk
