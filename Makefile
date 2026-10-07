## Flix ゲームエンジン モノレポの workspace コマンド
##
## 構成:
##   engine/       ─ 契約層 flix_engine_core（Game/Audio effect・共有描画型・土台型・描画語彙）
##   render_gl/    ─ engine（契約層）を実装する GL バックエンド
##   engine_world/ ─ App/World/UI ランタイム。ゲームが利用する
##   engine_tools/ ─ ヘッドレス描き出し/reference 工具箱。ゲームが利用する
##   engine_full/  ─ 上4つのソースを1つに集めた自己完結の全部入り flix_game_engine（配布物）
##   templates/    ─ 新しいゲームの写し元。各テンプレは `cd templates/<name> && flix ...` で直接動く
##
## Makefile に集約するのは workspace 横断の配布作業だけ:
##   `make sync` … engine / render_gl / engine_world / engine_tools を build-pkg し、それぞれを
##                  依存しているディレクトリの lib/github/ababup1192/<pkg>/<version>/ に
##                  相対 symlink を張る (cp ではなく ln -sf)。
##                  symlink にすることで engine を rebuild すれば即座に反映され、
##                  例題側で stale な fpkg を持ち回らなくて済む。
##                  各ターゲットディレクトリの project root への相対パスは深さで決まる:
##                    render_gl/lib/github/.../0.1.0/         → 6 階層上 (../ x6)
##                    engine_world/lib/github/.../0.1.0/      → 6 階層上 (../ x6)
##                    templates/<name>/lib/github/.../0.1.0/ → 7 階層上 (../ x7)
##                  ループ内で $$dir のスラッシュ数 + 5 (ENGINE_SUBPATH 階層) として計算する。

# Flix コンパイラは bin/flix ラッパー経由で呼ぶ。ラッパーが devbox (flix.nix) の
# flix コマンドと手動配置 bin/flix.jar のどちらを使うかを解決し、JVM フラグ
# (-XstartOnFirstThread、`test` サブコマンド時の -Djava.awt.headless=true) も
# サブコマンドに応じて自動で付ける。フラグの理由は bin/flix 内のコメント参照。
FLIX      := $(CURDIR)/bin/flix
FLIX_TEST := $(CURDIR)/bin/flix

# 全パッケージ共通のバージョン (lockstep)。sync 先ディレクトリ名や release の
# asset 名に使う。make bump FROM=x TO=y で各 flix.toml と一緒に上げる。
VERSION := 0.33.5

RENDER_GL_DIR       := render_gl
RENDER_GL_FPKG_SRC  := $(RENDER_GL_DIR)/artifact/package.fpkg
RENDER_GL_TOML_SRC  := $(RENDER_GL_DIR)/flix.toml
RENDER_GL_SUBPATH   := lib/github/ababup1192/flix_render_gl/$(VERSION)
RENDER_GL_FPKG_NAME := flix_render_gl-$(VERSION).fpkg
RENDER_GL_TOML_NAME := flix_render_gl-$(VERSION).toml

ENGINE_DIR       := engine
ENGINE_FPKG_SRC  := $(ENGINE_DIR)/artifact/package.fpkg
ENGINE_TOML_SRC  := $(ENGINE_DIR)/flix.toml
ENGINE_SUBPATH   := lib/github/ababup1192/flix_engine_core/$(VERSION)
ENGINE_FPKG_NAME := flix_engine_core-$(VERSION).fpkg
ENGINE_TOML_NAME := flix_engine_core-$(VERSION).toml

# engine_world は engine に依存する再利用 ECS lib。ゲームが利用する。
ENGINE_WORLD_DIR       := engine_world
ENGINE_WORLD_FPKG_SRC  := $(ENGINE_WORLD_DIR)/artifact/package.fpkg
ENGINE_WORLD_TOML_SRC  := $(ENGINE_WORLD_DIR)/flix.toml
ENGINE_WORLD_SUBPATH   := lib/github/ababup1192/flix_engine_world/$(VERSION)
ENGINE_WORLD_FPKG_NAME := flix_engine_world-$(VERSION).fpkg
ENGINE_WORLD_TOML_NAME := flix_engine_world-$(VERSION).toml

# engine_tools は engine に依存するヘッドレス描画/スナップショット工具箱 lib。ゲームが利用する。
ENGINE_TOOLS_DIR       := engine_tools
ENGINE_TOOLS_FPKG_SRC  := $(ENGINE_TOOLS_DIR)/artifact/package.fpkg
ENGINE_TOOLS_TOML_SRC  := $(ENGINE_TOOLS_DIR)/flix.toml
ENGINE_TOOLS_SUBPATH   := lib/github/ababup1192/flix_engine_tools/$(VERSION)
ENGINE_TOOLS_FPKG_NAME := flix_engine_tools-$(VERSION).fpkg
ENGINE_TOOLS_TOML_NAME := flix_engine_tools-$(VERSION).toml

# engine_full は engine / render_gl / engine_world / engine_tools のソースを1つに集めた
# 自己完結の全部入りパッケージ (依存ゼロ・LWJGL ネイティブ自前)。ゲームはこれ1つだけを
# 依存にでき、公開も既存リポ flix_game_engine の Release 1つで完結する
# (推移先の別リポを見に行かない)。配布名は flix_game_engine でリポ名と一致させる。
ENGINE_FULL_DIR       := engine_full
ENGINE_FULL_FPKG_SRC  := $(ENGINE_FULL_DIR)/artifact/package.fpkg
ENGINE_FULL_TOML_SRC  := $(ENGINE_FULL_DIR)/flix.toml
ENGINE_FULL_SUBPATH   := lib/github/ababup1192/flix_game_engine/$(VERSION)
ENGINE_FULL_FPKG_NAME := flix_game_engine-$(VERSION).fpkg
ENGINE_FULL_TOML_NAME := flix_game_engine-$(VERSION).toml

# lib/github/ababup1192/<pkg>/<version> サブパスの階層数 (= 5)。
# `$$dir` のスラッシュ数 (render_gl/ や engine_full/ なら 1、templates/<name>/ なら 2) と足して
# 全体の up 階層数を求め、symlink の相対パスを動的に組み立てる。
SUBPATH_DEPTH := 5

.PHONY: help status sync sync-engine sync-render-gl sync-engine-world sync-engine-tools sync-engine-full sync-root-src clean-locks clean-game-builds test test-par render render-all render-par render-changed diff gl-parity release release-guard bump lint-palette lint-view lint-loop lint-audio rules check-docs-sync checkd-stop shader-cache-soak

# セッション立ち上げの固定費を数百トークンに抑える口。SessionStart フックが毎回呼ぶので
# 実行や変更は一切せず、残っている記録 (.test-logs/ スナップショット チケット git) を集めるだけ。
status:
	@bin/fge status

# コミット時のゲート (描き出した絵の混入・規約の配線ずれ・矩形だけの View を止める)。
# .git/hooks は git 管理外なので、clone ごとに 1 回この配線が要る (status が未配線を知らせる)。
.PHONY: hooks
hooks:
	@git config core.hooksPath bin/githooks
	@echo "[hooks] 配線しました: pre-commit = bin/githooks/pre-commit (中身は bin/fge precommit)"

help:
	@echo "Targets:"
	@echo "  make status               現状 1 画面 (テスト記録・スナップショット・チケット・git)。何も実行しない"
	@echo "  make test                 全パッケージ (engine系 + templates) のテストを headless で実行"
	@echo "  make test-par             同上を並列実行 (実時間 ≈ 最遅パッケージ 1本分。ログは .test-logs/)"
	@echo "  make test-<name>          1 つだけテスト (例: make test-rpg-starter / make test-engine)"
	@echo "  make lint-palette         ドット絵 legend の意味色キーが Studio から解けるか検査"
	@echo "  make lint-view            View が矩形と円だけになっていないか検査"
	@echo "  make lint-images          git に入れる絵が増えすぎていないか検査"
	@echo "  make lint-sprite          ドット絵の画素の並び (浮き・塊の分裂・階段・細長さ・色数) を検査"
	@echo "  make lint-anim            コマ間の飛び・体積・接地と 4 方向のそろいを検査"
	@echo "  make lint-loop            ループ GIF の継ぎ目 (最終コマ→0 コマ) が浮かないか検査"
	@echo "  make lint-ui              ui.json の text の折り返し宣言漏れ (はみ出す形) を検査"
	@echo "  make lint-audio           音名が SfxRender の名・project.json・コードの 3 か所でそろっているか検査"
	@echo "  make lint-jargon          コメント・文章に独自の比喩語が混ざっていないか検査 (語は bin/lint-rules/jargon.json の words)"
	@echo "  make lint-fallback        読み込みの途中で bug! していないか検査 (許すのは *OrBug の中だけ)"
	@echo "  make lint-f32             engine の pub 面に Float32 が出ていないか検査 (Float32 は GL / OpenAL / STB の内側だけ)"
	@echo "  bin/fge digest A B   絵の差を数値で要約 (2 枚 or フォルダ。目視の前にまずこれ)"
	@echo "  make go-build             go/ を bin/fge-go と、配る先ごとの 5 種にビルド"
	@echo "  make go-test              go/ のテスト (CIEDE2000 の参照 34 組・外部依存ゼロの検査を含む)"
	@echo "  make rules                docs/ の規約から .claude/rules/ を作り直す"
	@echo "  make render-all           render-all ターゲットを持つ全 template の生成物を描き出し直す"
	@echo "  make render-par           同上を並列実行"
	@echo "  make render-changed       git で変更のあった template だけ描き出す (engine 側に変更があれば全テンプレ)"
	@echo "  make diff DIR=<dir>       直す前(スナップショット)と後(gallery)を左右に並べて <dir>/debug/diff/ に描き出す"
	@echo "  make gl-parity            GL と SoftRaster が同じ絵を出すかを隠しウィンドウで突き合わせ (不一致で exit 1)"
	@echo "  make shader-cache-soak    シェーダープログラムのキャッシュが上限で頭打ちになるかを隠しウィンドウで確認 (増え続ければ exit 1)"
	@echo "  make sync                 engine / render_gl / engine_world / engine_tools を build-pkg し、各依存先に配布"
	@echo "  make sync-render-gl       render_gl だけ build-pkg & 配布 (依存する各パッケージへ)"
	@echo "  make sync-engine          engine だけ build-pkg & 配布 (render_gl / engine_world / engine_tools へ)"
	@echo "  make sync-engine-world      engine_world だけ build-pkg & 配布 (依存する各パッケージへ)"
	@echo "  make sync-engine-tools    engine_tools だけ build-pkg & 配布 (依存する各パッケージへ)"
	@echo "  make sync-root-src        コミュニティビルド用にルート src/ の symlink 集を再生成"
	@echo "  make clean-locks          flix check 中断で残った Maven cache の *.lock を削除"
	@echo "  make checkd-stop          flix check 常駐 (bin/fge checkd) を全部止める (詳細は docs/checkd.md)"
	@echo "  make clean-game-builds    templates/*/build/ と bench/*/build/ を全削除 (IDE の scene.json glob 高速化用)"
	@echo "  make sync-engine-full     engine_full だけ src 集約 & build-pkg & 配布 (templates / bench へ)"
	@echo "  make release              sync→test-par→gl-parity→build-pkg→gh release を一括実行 (未コミットなら中断・tagはHEAD固定)"
	@echo "  make bump FROM=x TO=y     全 flix.toml の version を一括更新 (lockstep)。release の前に実行する"
	@echo "  make hooks                git の pre-commit ゲート (bin/githooks) をこの clone に配線する"
	@echo "  make bundle-zip           Studio に同梱する engine 一式を zip に固める (Release に添える)"

# flix check を Ctrl-C で中断すると lib/cache/.../*.lock が残り、
# 次回 Maven リゾルバが「他プロセスが取得中」と誤認して無限待ちになる。
# ルートから `find .` すると worktree や巨大な build/ まで stat して数分固まるので、
# 走査先はパッケージ配下だけに絞り、build/ は枝ごと prune する (lock は lib/cache だけにある)。
# 消すのは -delete でなく -exec rm にする: BSD find の -delete は暗黙に -depth を立て、
# すると -prune が無効化されて GB 級の build/ を全部歩き数分固まる (元の 7 分ハングの正体)。
LOCK_DIRS := $(ENGINE_DIR) $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR) $(ENGINE_FULL_DIR) $(wildcard templates/*) $(wildcard bench/*)
clean-locks:
	@find $(LOCK_DIRS) -type d -name build -prune -o \( -path "*/lib/cache/*" -name "*.lock" -print -exec rm -f {} + \) 2>/dev/null | awk 'END { print NR " lock(s) removed" }'

# flix check の常駐 (bin/fge checkd) を全部止める。挙動が怪しい時・メモリを空けたい時の逃げ道。
checkd-stop:
	@bin/fge checkd --stop-all

# IDE でゲームのプロジェクトを開くと ProjectLoader.findSceneFiles の Fs.Glob が
# build/class 配下の数十万コンパイル成果物を stat してしまい、プロジェクト読み込みに
# 数十秒〜数分かかる。IDE 起動前に各プロジェクトの build/ を消して回避する。
# もう一度 flix run すれば build/ は再生成される (incremental compile は失われる)。
# engine 自身のパッケージも消す。build/ は呼ぶたび足されるだけで減らないので、
# 消さずにいると engine_world が 2.1GB / 49 万ファイルまで育つ (実測)。
# テストの速さへの効きは 2 割ほどで、主な理由はディスクと IDE の glob。
PKG_DIRS := $(ENGINE_DIR) $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR)
clean-game-builds:
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

# 全パッケージのテストを順に回す。1 つでも赤ならそこで止まり exit 1。
TEST_DIRS := $(ENGINE_DIR) $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR) $(TEMPLATE_DIRS)

test:
	@for dir in $(TEST_DIRS); do \
		if [ -f "$$dir/flix.toml" ]; then \
			echo "===== $$dir ====="; \
			(cd "$$dir" && "$(FLIX_TEST)" test) || exit 1; \
		fi \
	done

# 並列テスト。各パッケージは独立 (別ディレクトリ・別 JVM) なので同時に回せて、
# 実時間は最遅パッケージ 1本分まで縮む。ログは .test-logs/ にパッケージ別で残し、
# 赤があれば最後にそのログ末尾を表示して exit 1。並列数は TEST_PAR_JOBS で変えられる。
# xargs は -I でなく -n1 + $$0 渡し (BSD xargs の -I は置換後の引数が 255 バイト制限で、
# スクリプトに埋めると「command line cannot be assembled」で 1 本も走らない)。
# 「1 本も走っていないのに green」の偽陽性は実行数ガードで落とす。
TEST_PAR_JOBS ?= 6
test-par:
	@mkdir -p .test-logs; rm -f .test-logs/*.log .test-logs/*.fail; \
	printf '%s\n' $(TEST_DIRS) | xargs -P $(TEST_PAR_JOBS) -n 1 sh -c ' \
		dir="$$0"; [ -f "$$dir/flix.toml" ] || exit 0; \
		name=$$(printf "%s" "$$dir" | tr / _); \
		if (cd "$$dir" && "$(FLIX_TEST)" test) > ".test-logs/$$name.log" 2>&1; then \
			echo "[test-par] PASS $$dir"; \
		else \
			echo "[test-par] FAIL $$dir"; touch ".test-logs/$$name.fail"; \
		fi'; \
	ran=$$(ls .test-logs/*.log 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$ran" -eq 0 ]; then echo "[test-par] 1 本も実行されていない (xargs 失敗の疑い)"; exit 1; fi; \
	if ls .test-logs/*.fail > /dev/null 2>&1; then \
		echo "===== 失敗したパッケージのログ末尾 ====="; \
		for f in .test-logs/*.fail; do base=$${f%.fail}; echo "--- $$base"; tail -40 "$$base.log"; done; \
		exit 1; \
	fi; \
	echo "[test-par] all green ($$ran packages)"

# ── render ────────────────────────────────────────────────
# 各テンプレのギャラリー・効果音などの生成物を一括で描き出し直す。
# 対象は「Makefile に render-all ターゲットを持つ template」だけ。
# テンプレ側の素の `render` は場面名 (SHOT) を要求して失敗するので、ここからは必ず render-all を打つ。
render-all:
	@for dir in $(TEMPLATE_DIRS:%=%/); do \
		if [ -f "$$dir/Makefile" ] && grep -qE "^render-all:|mk/game.mk" "$$dir/Makefile"; then \
			echo "===== $$dir ====="; \
			(cd "$$dir" && make render-all) || exit 1; \
		fi \
	done

# 素の render は打ち間違いなので、どのターゲットを打てばいいかを出して止める（テンプレ側と同じ形）。
render:
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
render-changed:
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
		if [ -f "$$dir/Makefile" ] && grep -qE "^render-all:|mk/game.mk" "$$dir/Makefile"; then \
			echo "===== $$dir ====="; \
			(cd "$$dir" && make render-all) || exit 1; \
			ran=$$((ran + 1)); \
		fi \
	done; \
	if [ "$$ran" -eq 0 ]; then echo "[render-changed] 変更のあったテンプレはありません (全量は make render-all)"; \
	else echo "[render-changed] done ($$ran templates)"; fi

# 並列の描き出し。テンプレ同士は生成物が交わらないので同時に走れる。ログ・失敗の扱いは test-par と同じ。
RENDER_PAR_JOBS ?= 4
render-par:
	@mkdir -p .test-logs; rm -f .test-logs/render-*.log .test-logs/render-*.fail; \
	for dir in $(TEMPLATE_DIRS:%=%/); do \
		if [ -f "$$dir/Makefile" ] && grep -qE "^render-all:|mk/game.mk" "$$dir/Makefile"; then echo "$$dir"; fi; \
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
diff:
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
		cd $(ENGINE_TOOLS_DIR) && DIFF_DIR="$(abspath $(DIR))" DIFF_NAMES="$$names" \
			JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" "$(FLIX)" run --entrypoint ReferenceDiff.pairs; \
	fi

# GL と SoftRaster の突き合わせ (bench/gl_parity)。隠しウィンドウで GL を 1 コマずつ描き出し、
# 同じ scene 宣言を SoftRaster でも描き出して画素比較する。A 段階 (バイト一致層) に不一致が
# あれば exit 1。描画経路 (render_gl / SoftRaster / Frame / ShaderEval) を触ったら回す。
gl-parity:
	@$(MAKE) -C bench/gl_parity run

# シェーダープログラムのキャッシュの上限 (bench/shader_cache_soak)。隠しウィンドウで
# 数値だけが違う Spec を 200 本投げ、LRU の追い出しでキャッシュが上限に留まるかを見る。
# 頭打ちにならなければ exit 1。ShaderCache / buildProgram / ShaderGen を触ったら回す。
shader-cache-soak:
	@$(MAKE) -C bench/shader_cache_soak run

# 個別テスト: make test-rpg-starter (templates/ を先に探し、無ければルート直下のパッケージ名)
# 出力は .test-logs/ に落とし (test-par と同じ命名)、緑なら末尾 5 行だけ見せる。
# make status が「最後にいつ・どれが緑/赤だったか」をこの記録から読む。
test-%:
	@mkdir -p .test-logs; \
	if [ -d "templates/$*" ]; then dir="templates/$*"; else dir="$*"; fi; \
	name=$$(printf "%s" "$$dir" | tr / _); \
	rm -f ".test-logs/$$name.fail"; \
	if (cd "$$dir" && "$(FLIX_TEST)" test) > ".test-logs/$$name.log" 2>&1; then \
		tail -5 ".test-logs/$$name.log"; \
	else \
		touch ".test-logs/$$name.fail"; tail -40 ".test-logs/$$name.log"; exit 1; \
	fi

# ── ゲート: ドット絵の意味色キー ────────────────────────────
# legend の名前が Studio から実色に解けるかを検査する (解けないと編集画面が仮色で塗り、
# 実機と配色が食い違う)。テンプレを足す・sprite Doc を触ったら通す。
lint-palette:
	@bin/fge palette

# ── ゲート: 音の名前 ────────────────────────────────────────
# SfxRender の名・project.json の sounds・コード内リテラルの 3 か所で音名がそろっているか検査する
# (ずれてもエラーは出ず、音だけ鳴らない・別の音が鳴る)。音を足した・改名したら通す。
lint-audio:
	@bin/fge audio

.PHONY: lint-jargon
lint-jargon:
	@bin/fge jargon --all

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

.PHONY: go-build
go-build:
	@cd go && CGO_ENABLED=0 go build -ldflags="$(GO_LDFLAGS)" -o ../bin/fge-go .
	@for pair in $(GO_OSARCH); do \
		os=$${pair%%/*}; arch=$${pair##*/}; \
		ext=""; [ "$$os" = "windows" ] && ext=".exe"; \
		(cd go && CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch \
			go build -ldflags="$(GO_LDFLAGS)" -o ../$(GO_DIST)/fge-go-$$os-$$arch$$ext .) || exit 1; \
		echo "  $(GO_DIST)/fge-go-$$os-$$arch$$ext"; \
	done

.PHONY: go-test
go-test:
	@cd go && CGO_ENABLED=0 go test ./...

# ── ゲート: bug! を置く場所 ──────────────────────────────────
# 読み込みの途中で bug! すると、既定値で続けてよいかを呼ぶ側が選べない
# (docs/error-handling.md の決まり 2)。*OrBug という名前の関数の中だけを許す。
# 残すと決めた bug! は bin/lint-rules/fallback.json の exempt に理由付きで載っている。
.PHONY: lint-fallback
lint-fallback:
	@bin/fge fallback --self-test >/dev/null
	@bin/fge fallback --all

# ── ゲート: pub 面に Float32 を出さない ───────────────────────
# ゲームを書く側は Float64 と Int32 だけで済むのが決まり。Float32 は
# GL / OpenAL / STB の境界の内側だけ (plans/f32-boundary.md)。
# 残すと決めた Float32 は bin/lint-rules/f32.json の exempt に理由付きで載っている。
.PHONY: lint-f32
lint-f32:
	@bin/fge f32 --self-test >/dev/null
	@bin/fge f32

# ── 起動画面の素材 ────────────────────────────────────────
# 組み込みフォント (ASCII の 1bit ビットマップ) とロゴを engine/src/render/BootFontData.flix へ
# 作り直す。fpkg は .flix しか運べないので、生成物はコミットする。
# 起動画面の文言に新しい字を足したとき・ロゴを差し替えたときだけ回す。
# PREVIEW=<dir> を付けると、作った結果を目視用の PNG でも書き出す。
boot-font:
	@java bin/BootFontGen.java $(if $(PREVIEW),--preview $(PREVIEW))

# フォントの生成結果のキャッシュを捨てる (次の起動は作り直しになる)。
# 作り方を変えた・容量が気になる・作り直しを確かめたいときに。
clean-font-cache:
	@rm -rf "$${FLIX_GE_CACHE_DIR:-$$HOME/.cache/flix_game_engine/font}"
	@echo "[clean-font-cache] キャッシュを捨てました"

# WhyNot: 配り先の packages.lock は配るたびに消す。fpkg は手元の作り直しで毎回中身が変わるので、
# 残すと Flix 0.77 以降は「packages.lock の記録と違う」で check ごと止まる。
sync: clean-locks sync-engine sync-render-gl sync-engine-world sync-engine-tools sync-engine-full sync-root-src

# engine_full は engine / render_gl / engine_world / engine_tools のソースを1つに集めた
# 自己完結パッケージ (依存ゼロ)。ルート src/ と同じくファイル単位の symlink で4パッケージの
# .flix を engine_full/src/ に集約してから build-pkg し、最後に full を使う templates / bench へ配る。
# ディレクトリ symlink は Flix のソース走査に追従されないため、必ずファイル単位で張る。
# エンジンに .flix を追加/削除/改名したら再実行して集約を更新する (sync-root-src と同じ運用)。
sync-engine-full:
	@for pkg in $(ROOT_SRC_PKGS); do rm -rf "$(ENGINE_FULL_DIR)/src/$$pkg"; done; \
	for pkg in $(ROOT_SRC_PKGS); do \
		(cd "$$pkg/src" && find . -name '*.flix') | sed 's|^\./||' | while read -r f; do \
			d=$$(dirname "$$f"); \
			if [ "$$d" = "." ]; then dir="$(ENGINE_FULL_DIR)/src/$$pkg"; else dir="$(ENGINE_FULL_DIR)/src/$$pkg/$$d"; fi; \
			mkdir -p "$$dir"; \
			depth=$$(printf '%s' "$$dir" | tr -cd '/' | wc -c | tr -d ' '); \
			up=$$(printf '../%.0s' $$(seq 0 "$$depth")); \
			ln -sfn "$$up$$pkg/src/$$f" "$$dir/$$(basename "$$f")"; \
		done; \
	done; \
	find $(ENGINE_FULL_DIR)/src -type l | awk 'END { print "[sync-engine-full] " NR " source symlink(s)" }'
	# 固める前に型検査する。build-pkg はソースを zip にするだけで、コンパイルが通るかを
	# 見ない。ここで検査しないと、壊れたエンジンが fpkg → Studio 同梱 → /Applications まで
	# 全部 exit 0 で運ばれ、誰かが新しいゲームを産んだ時に初めて落ちる。
	# WhyNot: 常駐 (bin/fge checkd) は使わない。symlink で束ねたこのパッケージでは常駐が
	# 偽の緑を返す (checkd 自身がこの形を見つけたら素の CLI へ落ちるようにしてある)。
	@echo "[sync-engine-full] 固める前に型検査"
	cd $(ENGINE_FULL_DIR) && "$(FLIX)" check
	cd $(ENGINE_FULL_DIR) && "$(FLIX)" build-pkg
	@for dir in templates/*/ bench/*/; do \
		toml="$$dir/flix.toml"; \
		if [ -f "$$toml" ] && grep -q 'ababup1192/flix_game_engine"' "$$toml"; then \
			target="$${dir}$(ENGINE_FULL_SUBPATH)"; \
			mkdir -p "$$target"; \
			depth=$$(printf '%s' "$$dir" | tr -cd '/' | wc -c | tr -d ' '); \
			upcnt=$$((depth + $(SUBPATH_DEPTH))); \
			rel=$$(printf '../%.0s' $$(seq 1 $$upcnt)); \
			ln -sfn "$${rel}$(ENGINE_FULL_FPKG_SRC)" "$$target/$(ENGINE_FULL_FPKG_NAME)"; \
			ln -sfn "$${rel}$(ENGINE_FULL_TOML_SRC)" "$$target/$(ENGINE_FULL_TOML_NAME)"; \
			rm -f "$${dir}packages.lock"; \
			echo "[sync-engine-full] $$target"; \
		fi \
	done

# ── リリース ──────────────────────────────────────────────
# 自己完結の全部入り engine_full を build-pkg し、既存リポ flix_game_engine の GitHub Release に
# fpkg と flix.toml を添付する。利用側は github:ababup1192/flix_game_engine の1行でこのバージョンを引く。
# 依存ゼロなので公開はこの1リポで完結する (推移先の別リポは不要)。
#
# 推奨フロー (この3手だけ):
#   1) make bump FROM=<旧> TO=<新>   … 全 flix.toml と VERSION を一括更新
#   2) git で変更を commit → main へ push  … リリースするバージョンを GitHub に載せる
#   3) make release                        … sync → test-par(全量ゲート) → gl-parity(A 段階の全一致) → build-pkg → gh release
#   終了後の案内どおり、lib/ を消したコピーで外部 fetch を検証する。
#
# release は sync (clean-locks はパッケージ配下だけ walk するのでもう固まらない) と
# test-par (並列全量ゲート) を前提に組み、以下の安全策を持つ:
#   - engine ソースが未コミットだと配布 fpkg がどのコミットにも対応しなくなるため中断する。
#   - tag は現在の HEAD に固定する。push し忘れていれば gh が「commit が無い」と明示エラーにする。
# test-par に不審な挙動があれば TEST := test で逐次にフォールバックする (make release TEST=test)。
RELEASE_SHA := $(shell git rev-parse HEAD)
TEST := test-par
release-guard:
	@# WhyNot: 追随の材料も未コミット検査に入れるのは、bump が生成した物をコミットし
	@# 忘れるとタグの中身に材料が入らず、後からそのバージョンを取り出しても空になるため。
	@dirty=$$(git status --porcelain -- $(ROOT_SRC_PKGS) docs/migrations); \
	 if [ -n "$$dirty" ]; then \
	   echo "[release] engine ソースが未コミットです。commit してから実行してください:"; echo "$$dirty"; exit 1; \
	 fi
	@# ゲーム側 lib の flix.toml はここへの symlink なので、別プロセスの依存解決が
	@# symlink 越しに中身を空にしてしまうことがある。壊れたまま build-pkg へ進まない。
	@for f in $(ROOT_SRC_PKGS:%=%/flix.toml) $(ENGINE_FULL_DIR)/flix.toml; do \
	   grep -q '^name' "$$f" || { echo "[release] $$f が壊れています (package.name が無い)。git checkout -- $$f で復元してください"; exit 1; }; \
	 done
	@# WhyNot: 全量ゲートの前に flix.jar の在処を見るのは、同梱 zip がこれを要るため。
	@# 後ろで気づくと、10 分以上かけたテストの後に落ちて全部やり直しになる。
	@test -n "$(BUNDLE_FLIX_JAR)" -a -f "$(BUNDLE_FLIX_JAR)" \
	  || { echo "[release] flix.jar が見つかりません (同梱 zip が作れません)。BUNDLE_FLIX_JAR= で場所を指定してください"; exit 1; }
	@# 追随の材料が bump のときのままか。API を触るコミットが bump の後に入ると古くなる。
	@bin/fge migration-notes --check
	@echo "[release] v$(VERSION) を $(RELEASE_SHA) で公開します"
# gl-parity も全量ゲートの一員 — GL と SoftRaster の絵の退行はテストに出ないため。
release: release-guard sync $(TEST) gl-parity
	cd $(ENGINE_FULL_DIR) && "$(FLIX)" build-pkg
	@# WhyNot: build-pkg の後に置くのは、zip の中身に engine_full.fpkg が入るため。
	@# 先に組むと 1 つ前のバージョンの fpkg を配ってしまう。
	$(MAKE) bundle-zip
	gh release create v$(VERSION) --repo ababup1192/flix_game_engine --target $(RELEASE_SHA) \
	  --title "v$(VERSION)" --generate-notes \
	  "$(ENGINE_FULL_FPKG_SRC)#$(ENGINE_FULL_FPKG_NAME)" \
	  "$(ENGINE_FULL_TOML_SRC)#$(ENGINE_FULL_TOML_NAME)" \
	  "$(BUNDLE_ZIP)" "$(BUNDLE_SUMS)"
	@echo "[release] 完了。外部 fetch 検証: lib/ を消したサンプルで github:ababup1192/flix_game_engine v$(VERSION) を引けるか確認してください"

# ── 同梱用 zip ────────────────────────────────────────────
# Studio に同梱する engine 一式を、そのまま Release に添えられる zip にする。
# 中身の一覧は bin/lint-rules/stage-engine.json が source of truth で、組み立ても最後の照合も
# bin/fge stage-engine が持つ (Studio の make stage-engine・ci/package-windows.ps1 と同じ口)。
#
# lwjgl (Maven) の種は入れない。あれは engine のバージョンで変わらないので、
# Studio 側が自分の server/lib から渡せば足りる (入れると zip が 9M ほど太る)。
#
# flix.jar は devbox profile が指す nix store の実体から借りる (Studio の FLIX_JAR と同じ
# 見つけ方)。手で置いた bin/flix.jar が古いことがあるので既定にしない。
BUNDLE_ZIP   := flix_game_engine-engine-v$(VERSION).zip
BUNDLE_STAGE := build/bundle/engine
BUNDLE_SUMS  := SHA256SUMS.txt
BUNDLE_FLIX_JAR ?= $(shell real=$$(readlink -f .devbox/nix/profile/default/bin/flix 2>/dev/null); \
                     [ -n "$$real" ] && echo "$$(dirname $$(dirname $$real))/share/java/flix/flix.jar")
BUNDLE_FLIX_WRAPPER ?= bin/flix
.PHONY: bundle-zip
# WhyNot: 組む前に必ず go-build を通すのは、検査データ (bin/lint-rules/*.json) が git の
# 作業ツリーから、検査の中身 (bin/dist の fge-go) が前に組んだ物から来るため。
# 別々の経路なので、バイナリだけ古いまま配ると「宣言はあるのに入口が無い」バンドルになり、
# 配った先の precommit が毎回 exit 2 で止まる (0.32.0 の flix-reserved がこれ)。
bundle-zip: go-build
	@test -n "$(BUNDLE_FLIX_JAR)" -a -f "$(BUNDLE_FLIX_JAR)" \
	  || (echo "!! flix.jar が見つかりません (BUNDLE_FLIX_JAR= で場所を指定してください)" && exit 1)
	rm -rf build/bundle "$(BUNDLE_ZIP)" "$(BUNDLE_SUMS)"
	bin/fge stage-engine --out "$(BUNDLE_STAGE)" \
	  --flix-jar "$(BUNDLE_FLIX_JAR)" \
	  --flix-wrapper "$(BUNDLE_FLIX_WRAPPER)"
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
bump:
	@test -n "$(FROM)" && test -n "$(TO)" || { echo "usage: make bump FROM=0.1.0 TO=0.1.1"; exit 1; }
	@for f in $(ENGINE_DIR) $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR) $(ENGINE_FULL_DIR); do \
		perl -pi -e 's/^(version\s*=\s*)"\Q$(FROM)\E"/$${1}"$(TO)"/' "$$f/flix.toml"; \
	done
	@for f in $(ENGINE_DIR)/flix.toml $(RENDER_GL_DIR)/flix.toml $(ENGINE_WORLD_DIR)/flix.toml $(ENGINE_TOOLS_DIR)/flix.toml $(ENGINE_FULL_DIR)/flix.toml templates/*/flix.toml bench/*/flix.toml flix_ge_shapes/flix.toml; do \
		[ -f "$$f" ] && perl -pi -e 's|(ababup1192/flix_[a-z_]*"[^"]*version = )"[0-9]+\.[0-9]+\.[0-9]+"|$${1}"$(TO)"|g' "$$f" || true; \
	done
	@perl -pi -e 's/^(VERSION := ).*/$${1}$(TO)/' Makefile
	@$(MAKE) --no-print-directory api-digest VERSION=$(TO)
	@# WhyNot: リリースの中でなく bump で作るのは、release の途中で作ると未コミットの
	@# 生成物が同梱 zip にだけ入り、タグの中身には入らないため（後からそのバージョンを
	@# 取り出しても追随の材料が無い、という形になる）。
	@$(MAKE) --no-print-directory migration-notes
	@echo "[bump] $(FROM) -> $(TO) 完了 (依存行は旧バージョンどれでも TO へ・flix-random と flix コンパイラのバージョンは据え置き。api-digest も再生成済み)。"

# 1 つ前のリリースからの非互換と、engine 自身の追随例を 1 枚にまとめて書き出す。
# make bump が呼ぶので普段は直に打たない（作り直したいときだけ）。
.PHONY: migration-notes
migration-notes:
	@bin/fge migration-notes

# ── コミュニティビルド用ルート src/ ──────────────────────
# Flix 公式の community build (flix/flix の community-build.yaml) は、このリポジトリを
# checkout してルートで `flix build` を実行するだけで、make sync の fpkg 配布は走らない。
# そこでルート src/ に全エンジンパッケージの .flix をファイル単位の symlink で並べ、
# 5 パッケージを 1 ソースツリーとしてビルドできるようにする (ルートの flix.toml が対応)。
# ディレクトリ symlink は Flix のソース走査に追従されないため、必ずファイル単位で張る。
# エンジンに .flix を追加/削除/改名したら再実行して symlink 集を更新し、コミットする。
ROOT_SRC_PKGS := $(ENGINE_DIR) $(RENDER_GL_DIR) $(ENGINE_WORLD_DIR) $(ENGINE_TOOLS_DIR)

sync-root-src:
	@for pkg in $(ROOT_SRC_PKGS); do rm -rf "src/$$pkg"; done; \
	for pkg in $(ROOT_SRC_PKGS); do \
		(cd "$$pkg/src" && find . -name '*.flix') | sed 's|^\./||' | while read -r f; do \
			d=$$(dirname "$$f"); \
			if [ "$$d" = "." ]; then dir="src/$$pkg"; else dir="src/$$pkg/$$d"; fi; \
			mkdir -p "$$dir"; \
			depth=$$(printf '%s' "$$dir" | tr -cd '/' | wc -c | tr -d ' '); \
			up=$$(printf '../%.0s' $$(seq 0 "$$depth")); \
			ln -sfn "$$up$$pkg/src/$$f" "$$dir/$$(basename "$$f")"; \
		done; \
	done; \
	find src -type l | awk 'END { print "[sync-root-src] " NR " symlink(s)" }'

# render_gl は engine（フロント契約）を実装する GL バックエンド。
# engine に依存するので sync チェーンでは sync-engine の後に置く（lib に engine fpkg が要る）。
sync-render-gl:
	cd $(RENDER_GL_DIR) && "$(FLIX)" build-pkg
	@for dir in templates/*/ bench/*/; do \
		toml="$$dir/flix.toml"; \
		if [ -f "$$toml" ] && grep -q 'ababup1192/flix_render_gl"' "$$toml"; then \
			target="$${dir}$(RENDER_GL_SUBPATH)"; \
			mkdir -p "$$target"; \
			depth=$$(printf '%s' "$$dir" | tr -cd '/' | wc -c | tr -d ' '); \
			upcnt=$$((depth + $(SUBPATH_DEPTH))); \
			rel=$$(printf '../%.0s' $$(seq 1 $$upcnt)); \
			ln -sfn "$${rel}$(RENDER_GL_FPKG_SRC)" "$$target/$(RENDER_GL_FPKG_NAME)"; \
			ln -sfn "$${rel}$(RENDER_GL_TOML_SRC)" "$$target/$(RENDER_GL_TOML_NAME)"; \
			rm -f "$${dir}packages.lock"; \
			echo "[sync-render-gl] $$target"; \
		fi \
	done

# engine は render_gl / engine_world / engine_tools が依存している。
# 特に render_gl は engine を実装するバックエンドなので、engine fpkg を render_gl にも配る。
# fpkg / toml は cp ではなく相対 symlink で配布する (engine 再ビルドが即反映される)
sync-engine:
	cd $(ENGINE_DIR) && "$(FLIX)" build-pkg
	@for dir in $(RENDER_GL_DIR)/ $(ENGINE_WORLD_DIR)/ $(ENGINE_TOOLS_DIR)/ templates/*/ bench/*/; do \
		toml="$$dir/flix.toml"; \
		if [ -f "$$toml" ] && grep -q 'ababup1192/flix_engine_core"' "$$toml"; then \
			target="$${dir}$(ENGINE_SUBPATH)"; \
			mkdir -p "$$target"; \
			depth=$$(printf '%s' "$$dir" | tr -cd '/' | wc -c | tr -d ' '); \
			upcnt=$$((depth + $(SUBPATH_DEPTH))); \
			rel=$$(printf '../%.0s' $$(seq 1 $$upcnt)); \
			ln -sfn "$${rel}$(ENGINE_FPKG_SRC)" "$$target/$(ENGINE_FPKG_NAME)"; \
			ln -sfn "$${rel}$(ENGINE_TOML_SRC)" "$$target/$(ENGINE_TOML_NAME)"; \
			rm -f "$${dir}packages.lock"; \
			echo "[sync-engine] $$target"; \
		fi \
	done

# engine_world は engine を依存にする再利用 ECS lib。依存する各パッケージに配布する。
# engine に依存するので sync チェーンでは sync-engine の後に置く（lib に engine fpkg が要る）。
sync-engine-world:
	cd $(ENGINE_WORLD_DIR) && "$(FLIX)" build-pkg
	@for dir in templates/*/ bench/*/; do \
		toml="$$dir/flix.toml"; \
		if [ -f "$$toml" ] && grep -q 'ababup1192/flix_engine_world"' "$$toml"; then \
			target="$${dir}$(ENGINE_WORLD_SUBPATH)"; \
			mkdir -p "$$target"; \
			depth=$$(printf '%s' "$$dir" | tr -cd '/' | wc -c | tr -d ' '); \
			upcnt=$$((depth + $(SUBPATH_DEPTH))); \
			rel=$$(printf '../%.0s' $$(seq 1 $$upcnt)); \
			ln -sfn "$${rel}$(ENGINE_WORLD_FPKG_SRC)" "$$target/$(ENGINE_WORLD_FPKG_NAME)"; \
			ln -sfn "$${rel}$(ENGINE_WORLD_TOML_SRC)" "$$target/$(ENGINE_WORLD_TOML_NAME)"; \
			rm -f "$${dir}packages.lock"; \
			echo "[sync-engine-world] $$target"; \
		fi \
	done

# engine_tools は engine を依存にするヘッドレス描画/スナップショット工具箱 lib。依存する各パッケージに配布する。
# engine に依存するので sync チェーンでは sync-engine の後に置く（lib に engine fpkg が要る）。
sync-engine-tools:
	cd $(ENGINE_TOOLS_DIR) && "$(FLIX)" build-pkg
	@for dir in templates/*/ bench/*/; do \
		toml="$$dir/flix.toml"; \
		if [ -f "$$toml" ] && grep -q 'ababup1192/flix_engine_tools"' "$$toml"; then \
			target="$${dir}$(ENGINE_TOOLS_SUBPATH)"; \
			mkdir -p "$$target"; \
			depth=$$(printf '%s' "$$dir" | tr -cd '/' | wc -c | tr -d ' '); \
			upcnt=$$((depth + $(SUBPATH_DEPTH))); \
			rel=$$(printf '../%.0s' $$(seq 1 $$upcnt)); \
			ln -sfn "$${rel}$(ENGINE_TOOLS_FPKG_SRC)" "$$target/$(ENGINE_TOOLS_FPKG_NAME)"; \
			ln -sfn "$${rel}$(ENGINE_TOOLS_TOML_SRC)" "$$target/$(ENGINE_TOOLS_TOML_NAME)"; \
			rm -f "$${dir}packages.lock"; \
			echo "[sync-engine-tools] $$target"; \
		fi \
	done

# agents-pack をゲームに配る。配布物一覧の source of truth は agents-pack/manifest.json で、
# Makefile はその解釈器 bin/fge sync-agents を呼ぶだけ (Studio の配布も同じ manifest を
# 読むので、リストの二重管理で片方だけ腐ることが無い)。冪等。
# バージョンはルート flix.toml でなく $(VERSION) (bump が進める実体) を刻む。ゲーム側の
# bin/fge status がこの刻印と engine Makefile の VERSION を照らし、陳腐化を知らせる。
.PHONY: sync-agents
sync-agents:
	@if [ -z "$(GAME)" ]; then echo "error: GAME を指定してください (make sync-agents GAME=/path/to/game)"; exit 1; fi
	@bin/fge sync-agents --game "$(GAME)" --version "$(VERSION)"
	@$(MAKE) --no-print-directory sync-fge-go GAME="$(GAME)"

# Go 移行で役目を終えた Python の道具を、配った先のゲームから消す (一度きりの後始末)。
# copyDirs (skills・rules・lint-rules) と違って bin/ はゲームが自分の道具も置く場所なので、
# ミラーにはせず名指しの一覧だけを消す。engine 側にまだある道具は消さない。
# 素振りは DRY_RUN=1。一覧は go/internal/prunetools の StaleTools。
# WhyNot: manifest.json に載せないのは、これが恒久の配布規約ではなく一度きりの後始末で、
# 載せると Studio の Flix にも同じ実装と parity 検査が要るため。
.PHONY: prune-stale-tools
prune-stale-tools:
	@if [ -z "$(GAME)" ]; then echo "error: GAME を指定してください (make prune-stale-tools GAME=/path/to/game)"; exit 1; fi
	@bin/fge prune-stale-tools --game "$(GAME)" $(if $(DRY_RUN),--dry-run,)

# 検査の中身は bin/fge-go (Go のバイナリ)。配る先の OS/CPU に合う 1 つだけを置く。
# WhyNot: manifest.json の copy に並べないのは、あそこが「どの OS でも同じ物を配る」表で、
# 配る先ごとに 1 つ選ぶ仕組みが無いため (全部配ると 4 つ × 4.2M が各リポに積まれる)。
.PHONY: sync-fge-go
# WhyNot: 配る前に go-build を通すのは、規約データ (lint-rules) を sync-agents が git の
# 作業ツリーから配るのに対し、検査の中身はここが bin/dist から配るため。組み直しを忘れると
# 「宣言はあるのに入口が無い」ゲームができる。Go のビルドキャッシュが効くので数秒。
#
# WhyNot: 置き換えを cp の上書きでなく別名 + mv にするのは、macOS が実行ファイルの中身を
# 同じ inode のまま書き換えられると、その inode について覚えていた署名の検証結果を捨て、
# 次の実行を即 SIGKILL するため。中身も署名も正しいのに配った先だけが死に、
# pre-commit がこれを呼ぶ git まで道連れになる (index.lock だけが残る)。
# mv なら inode が新しくなるので踏まない。
sync-fge-go: go-build
	@if [ -z "$(GAME)" ]; then echo "error: GAME を指定してください"; exit 1; fi
	@os=$$(uname -s | tr 'A-Z' 'a-z'); arch=$$(uname -m); ext=""; \
	case "$$os" in darwin) ;; linux) ;; mingw*|msys*|cygwin*) os=windows; ext=".exe" ;; \
	  *) echo "[sync-fge-go] 知らない OS ($$os)。bin/dist/ から手で選んで $(GAME)/bin/ へ置いてください"; exit 0 ;; esac; \
	case "$$arch" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; \
	  *) echo "[sync-fge-go] 知らない CPU ($$arch)。bin/dist/ から手で選んでください"; exit 0 ;; esac; \
	src=$(GO_DIST)/fge-go-$$os-$$arch$$ext; \
	if [ ! -f "$$src" ]; then echo "[sync-fge-go] $$src がありません (make go-build)"; exit 1; fi; \
	tmp="$(GAME)/bin/.fge-go$$ext.new"; \
	cp "$$src" "$$tmp"; \
	chmod +x "$$tmp"; \
	mv -f "$$tmp" "$(GAME)/bin/fge-go$$ext"; \
	echo "[sync-fge-go] $$src → $(GAME)/bin/fge-go$$ext"

# 規約の本文は docs/ に 1 つだけ置く。CLAUDE.md は AGENTS.md を import するだけ、
# .claude/rules/ は bin/fge gen-rules の生成物。手で 2 か所に書かないので、ずれない。
.PHONY: rules
rules: api-digest
	@bin/fge gen-rules

# engine/engine_world/engine_tools の pub API を 1 枚のダイジェストに畳む。
# AI エージェントが型・引数を調べる時、ソースを grep する前にまずここを読めば済む。
.PHONY: api-digest
api-digest:
	@bin/fge api-digest

# ダイジェストの引き方の近道。例: make api Q=gradPolygon
# ソースを開かずに pub 宣言 (型・引数・エフェクト・doc 1 行) だけ拾う。
#
# digest は作業ツリーの src/ から作るので、まだリリースしていない宣言も載る。
# ゲームは flix.toml で版を固定して fpkg を引くため、digest を信じて書くと
# コンパイルで落ちる (2026-08-14: Depth.bands / PxSpriteDoc.Loop で 2 本が落ちた)。
# だから引くたびに「その名前は未リリースか」を後ろに出す (bin/fge check-api-released)。
.PHONY: api
api:
	@test -n "$(Q)" || { echo "usage: make api Q=<関数名やモジュール名>"; exit 1; }
	@out=$$(grep -h -i -- "$(Q)" docs/api-digest/*.md 2>/dev/null | head -40); \
	 if [ -n "$$out" ]; then printf '%s\n' "$$out"; \
	 else echo "[api] '$(Q)' はダイジェストに無い。docs/module-index.md で別名を探す"; fi
	@# 2>/dev/null を付けない。この検査の存在理由は「digest の嘘を見えるようにする」ことなので、
	@# 検査自体が黙って死ぬ形は自己矛盾になる (|| true は助言だから止めない、の意味で残す)。
	@bin/fge check-api-released "$(Q)" || true

# 絵の下限（矩形と円だけになっていないか）。どの OS・どのエージェントからも同じ検査。
.PHONY: lint-view
lint-view:
	@bin/fge view

# git に入れる絵が増えすぎていないか（描き出した絵が紛れ込んでいないか）の検査。
.PHONY: lint-images
lint-images:
	@bin/fge images

# ドット絵の画素の並びの検査。自己テストが壊れた lint には門番をさせない。
.PHONY: lint-sprite
lint-sprite:
	@bin/fge sprite --self-test >/dev/null
	@bin/fge sprite

.PHONY: lint-anim
lint-anim:
	@bin/fge anim --self-test >/dev/null
	@bin/fge anim

# ui.json の text の折り返し宣言漏れ (固定幅の枠 + wrap/fit なし) の検査。
# 実寸は測らない構造検査。コード直組みの Text と instance 参照ノードは見えない。
.PHONY: lint-ui
lint-ui:
	@bin/fge ui-overflow --self-test >/dev/null
	@bin/fge ui-overflow

# ループ GIF の継ぎ目（最終コマ→0 コマ）が浮かないかの検査。描き出し済みのコマが前提なので
# 保存時フックや pre-commit には乗せない（手動で回す）。
.PHONY: lint-loop
lint-loop:
	@bin/fge loop --self-test >/dev/null
	@bin/fge loop

# 規約まわりの配線が崩れていないかの検査（生成はしない）。
.PHONY: check-docs-sync
check-docs-sync:
	@ok=1; \
	if [ ! -f CLAUDE.md ] || [ ! -f AGENTS.md ]; then \
	  echo "[check-docs-sync] CLAUDE.md か AGENTS.md が見つかりません"; exit 1; \
	fi; \
	echo "[check-docs-sync] CLAUDE.md が AGENTS.md を import しているか"; \
	if ! grep -q '^@AGENTS.md' CLAUDE.md; then \
	  echo "[check-docs-sync] NG: CLAUDE.md は @AGENTS.md の 1 行にしてください（本文の二重管理を避ける）"; ok=0; \
	fi; \
	echo "[check-docs-sync] .claude/rules が docs/ と一致しているか"; \
	bin/fge gen-rules --check || ok=0; \
	echo "[check-docs-sync] AGENTS.md のスキル表が実在する skill を指しているか"; \
	for s in $$(grep -o '`/[a-z][a-z-]*`' AGENTS.md | tr -d '`/' | sort -u); do \
	  if [ ! -f ".claude/skills/$$s/SKILL.md" ]; then \
	    echo "[check-docs-sync] NG: AGENTS.md が /$$s を指していますが .claude/skills/$$s/SKILL.md がありません"; ok=0; \
	  fi; \
	done; \
	echo "[check-docs-sync] AGENTS.core.md のスキル参照が agents-pack/skills に実在するか"; \
	for s in $$(grep -o '`/[a-z][a-z-]*`' agents-pack/AGENTS.core.md | tr -d '`/' | sort -u) \
	         $$(grep -o '\.claude/skills/[a-z][a-z-]*' agents-pack/AGENTS.core.md | sed 's|.*/||' | sort -u); do \
	  if [ ! -f "agents-pack/skills/$$s/SKILL.md" ]; then \
	    echo "[check-docs-sync] NG: AGENTS.core.md が $$s を指していますが agents-pack/skills/$$s/SKILL.md がありません（ゲームに配られるのは agents-pack/skills だけ）"; ok=0; \
	  fi; \
	done; \
	echo "[check-docs-sync] AGENTS.core.md に skills への橋渡しがあるか"; \
	if ! grep -q 'SKILL.md' agents-pack/AGENTS.core.md; then \
	  echo "[check-docs-sync] NG: AGENTS.core.md に「.claude/skills/<名前>/SKILL.md を直接読む」案内がありません（スキル機構を持たないエージェントが skills に気づけなくなります）"; ok=0; \
	fi; \
	echo "[check-docs-sync] agents-pack/skills にコピー先のゲームで切れる相対リンクが無いか"; \
	if grep -rn '](\.\./' agents-pack/skills/; then \
	  echo "[check-docs-sync] NG: 上の相対リンクは skills フォルダの外を指していて、コピー先のゲームで切れます。「engine リポの docs/...」の文言参照にしてください"; ok=0; \
	fi; \
	echo "[check-docs-sync] skill の frontmatter に name と description があるか"; \
	for f in .claude/skills/*/SKILL.md agents-pack/skills/*/SKILL.md; do \
	  if ! grep -q '^name:' $$f; then echo "[check-docs-sync] NG: $$f に name がありません"; ok=0; fi; \
	  if ! grep -q '^description:' $$f; then echo "[check-docs-sync] NG: $$f に description がありません"; ok=0; fi; \
	done; \
	echo "[check-docs-sync] 同名スキルの sync 印が両側で一致するか"; \
	for d in agents-pack/skills/*/; do \
	  s=$$(basename $$d); \
	  if [ -f ".claude/skills/$$s/SKILL.md" ]; then \
	    a=$$(grep '^sync:' "$$d/SKILL.md" | head -1); \
	    b=$$(grep '^sync:' ".claude/skills/$$s/SKILL.md" | head -1); \
	    if [ -z "$$a" ] || [ "$$a" != "$$b" ]; then \
	      echo "[check-docs-sync] NG: skill $$s の sync 印が不一致（agents-pack=$$a / .claude=$$b）。片方を直したらもう片方へ内容を移植し、両方の sync: を同じ日付に上げる"; ok=0; \
	    fi; \
	  fi; \
	done; \
	echo "[check-docs-sync] 図形プリミティブの旧名 Render.box 等が docs/ と AGENTS.md に残っていないか"; \
	old_names='Render\.(box|boxAt|orBoxAt|circle|circleAt|polygon|ngon|ngonAt|ellipse|ellipseAt|ellipseSegs|ellipseSegsAt|ellipseSegsFor|sector|sectorAt|circleSegment|circleSegmentAt|star|starAt|lineQuad|lineSeg)\b'; \
	if grep -rlE "$$old_names" docs/*.md AGENTS.md 2>/dev/null | grep -v docs/api-digest; then \
	  echo "[check-docs-sync] NG: 上のファイルに図形プリミティブの旧名（Render.box 等）が残っています。RawDraw.* へ書き換えてください"; ok=0; \
	fi; \
	echo "[check-docs-sync] agents-pack/manifest.json が正しい JSON で src が全実在するか"; \
	bin/fge sync-agents --check-manifest || ok=0; \
	echo "[check-docs-sync] Makefile / templates / agents-pack の参照先が実在するか"; \
	bin/fge check-refs || ok=0; \
	echo "[check-docs-sync] pub def を持つモジュールが API 索引に載っているか"; \
	bin/fge check-api-index || ok=0; \
	echo "[check-docs-sync] docs/api-digest.md が作り直しても差分ゼロか"; \
	bin/fge api-digest --check || ok=0; \
	echo "[check-docs-sync] AGENTS.md から docs/ への導線があるか"; \
	for kw in \
	  "docs/audio.md" \
	  "docs/engine-module-index.md" \
	  "docs/module-index.md" \
	  "docs/drawing-floor.md" \
	  "docs/flix-conventions.md" \
	  "docs/z-bands.md" \
	  "docs/performance.md" \
	; do \
	  if ! grep -q "$$kw" AGENTS.md; then \
	    echo "[check-docs-sync] NG: AGENTS.md に $$kw への導線がありません"; ok=0; \
	  fi; \
	done; \
	echo "[check-docs-sync] templates/ に CLAUDE.md を置いていないか"; \
	for f in templates/*/CLAUDE.md; do \
	  if [ -f "$$f" ]; then \
	    echo "[check-docs-sync] NG: $$f は make new-game の sync-agents が @AGENTS.md で上書きするので、書いても捨てられます。ゲーム固有の事は AGENTS.local.md に、共通の方針は agents-pack/AGENTS.core.md に書いてください"; ok=0; \
	  fi; \
	done; \
	if [ -d .agents/skills ]; then \
	  for d in .agents/skills/*/; do \
	    n=$$(basename $$d); \
	    if [ ! -f ".claude/skills/$$n/SKILL.md" ] || ! diff -q "$$d/SKILL.md" ".claude/skills/$$n/SKILL.md" >/dev/null 2>&1; then \
	      echo "[check-docs-sync] WARN: .agents/skills/$$n が .claude/skills/ と違います（どこからも参照されていない古い写しです。消すか揃えるか決めてください）"; \
	    fi; \
	  done; \
	fi; \
	if [ "$$ok" = "1" ]; then \
	  echo "[check-docs-sync] OK"; \
	else \
	  exit 1; \
	fi

# ── 新しいゲームを 1 コマンドで産む ──────────────────────
# 使い方: make new-game GAME=/abs/path/to/dir NAME=<パッケージ名> TITLE=<題名> W=240 H=320 TEMPLATE=novel-starter
#   - GAME  … 生成先（存在しない絶対パス）。
#   - TEMPLATE … 複製元（templates/ 直下の名前。省略時は game-starter）。
#   - NAME  … Flix パッケージ名（小文字英字はじまり・[a-z0-9_]）。sprite の entityId にも使う。
#   - TITLE … ウィンドウの題名（省略時は NAME）。
#   - W/H   … design 解像度（省略時は 480×300。ウィンドウはその 2 倍）。
# templates/game-starter を写して __NAME__/__TITLE__/__W__/__H__/__WW__/__WH__ を置換する。
# エンジンの現在地は Makefile には書かず、git に入れない local.mk へ書く（Makefile は
# マシンをまたいで共有できる形のまま。別のマシンでは local.mk を 1 度だけ書き直す）。
# lib/ をエンジン手元の成果物から
# 種付け（初回ダウンロード不要）、git init（commit はしない）、
# sync-agents を配ってから check → test → render を通して「生きて産まれた」ことを証明する。
NG_TEMPLATE := $(if $(TEMPLATE),$(TEMPLATE),game-starter)
NG_W := $(if $(W),$(W),480)
NG_H := $(if $(H),$(H),300)
NG_TITLE = $(if $(TITLE),$(TITLE),$(NAME))
# 題名は自由文（アポストロフィ・空白・記号を含みうる）。シェルの '...' 囲みだと
# "Tetris's" のような ' で構文が壊れる。make の export で環境変数として直接渡し
# （execve が値をそのまま載せる・シェル再クォート無し）、recipe 側の perl は
# $ENV{NG_TITLE} で安全に読む。
export NG_TITLE

# engine_full.fpkg がソースより古いまま先へ進むのを止める。
# WhyNot: 「在るかどうか」だけでは足りない。fpkg のバージョン名は bump で進むので、中身が
# 古くても名前は新しいバージョンに見える。それがゲームの lib/ や Studio の .app へ写ると、
# Flix は「バージョン名が同じなら取り直さない」ので誰も気づけず、engine のソースにも Release
# にも在る def が「Undefined name」になる。
# 判定は mtime なので、git checkout 直後は中身が同じでも古く見えることがある。空振りは
# sync-engine-full を 1 回回せば済む側の失敗なので、見逃すよりそちらを選ぶ。
.PHONY: engine-full-fresh
engine-full-fresh:
	@if [ ! -f "$(ENGINE_FULL_FPKG_SRC)" ]; then \
	  echo "error: $(ENGINE_FULL_FPKG_SRC) がありません。先に make sync-engine-full を実行してください"; exit 1; \
	fi
	@newer=$$(find $(ROOT_SRC_PKGS:%=%/src) -name '*.flix' -newer "$(ENGINE_FULL_FPKG_SRC)" 2>/dev/null | head -5); \
	 if [ -n "$$newer" ]; then \
	   echo "error: $(ENGINE_FULL_FPKG_SRC) がソースより古いです。make sync-engine-full で作り直してください"; \
	   echo "$$newer" | sed 's/^/  新しい: /'; exit 1; \
	 fi

.PHONY: new-game
new-game: engine-full-fresh
	@if [ -z "$(GAME)" ]; then echo "error: GAME を指定してください (make new-game GAME=/abs/path NAME=mygame TITLE=題名 W=240 H=320)"; exit 1; fi
	@case "$(GAME)" in /*) : ;; *) echo "error: GAME は絶対パスで指定してください: $(GAME)"; exit 1;; esac
	@if [ -e "$(GAME)" ]; then echo "error: 生成先が既に存在します: $(GAME)"; exit 1; fi
	@if [ -z "$(NAME)" ]; then echo "error: NAME を指定してください（Flix パッケージ名）"; exit 1; fi
	@echo "$(NAME)" | grep -Eq '^[a-z][a-z0-9_]*$$' || { echo "error: NAME が不正です: $(NAME)（小文字英字はじまり・英小文字/数字/_ のみ）"; exit 1; }
	@echo "$(NG_W)" | grep -Eq '^[0-9]+$$' || { echo "error: W が数値ではありません: $(NG_W)"; exit 1; }
	@echo "$(NG_H)" | grep -Eq '^[0-9]+$$' || { echo "error: H が数値ではありません: $(NG_H)"; exit 1; }
	@echo "$(NG_TEMPLATE)" | grep -Eq '^[a-z][a-z0-9-]*$$' || { echo "error: TEMPLATE が不正です: $(NG_TEMPLATE)"; exit 1; }
	@if [ ! -d "templates/$(NG_TEMPLATE)" ]; then echo "error: templates/$(NG_TEMPLATE) がありません"; exit 1; fi
	@if [ -z "$(W)$(H)" ] && grep -q "__W__" "templates/$(NG_TEMPLATE)/project.json" 2>/dev/null; then echo "[new-game] W/H 未指定 — トークン式テンプレの既定 480×300 で作ります"; fi
	@set -e; \
	echo "[new-game] $(GAME) を作成します (NAME=$(NAME) TITLE=$(NG_TITLE) design=$(NG_W)x$(NG_H) TEMPLATE=$(NG_TEMPLATE))"; \
	mkdir -p "$(GAME)"; \
	cp -R "templates/$(NG_TEMPLATE)/." "$(GAME)/"; \
	: 生成物は運ばない。lib は engine_full から置き直す。build はテンプレ 1 本で 500MB 級に育つ; \
	: ので、運ぶと産まれたゲームがその分太る（パッケージ名が変わるのでどのみち使えない）; \
	rm -rf "$(GAME)/lib" "$(GAME)/build" "$(GAME)/debug" "$(GAME)/gallery" "$(GAME)/.devbox" "$(GAME)/.test-logs"; \
	mkdir -p "$(GAME)/gallery" "$(GAME)/reference" "$(GAME)/debug" "$(GAME)/atelier"; \
	for f in "$(GAME)"/assets/__NAME__.*; do \
	  [ -e "$$f" ] || continue; \
	  mv "$$f" "$(GAME)/assets/$(NAME).$${f##*/__NAME__.}"; \
	done; \
	NG_NAME='$(NAME)' NG_W='$(NG_W)' NG_H='$(NG_H)' \
	NG_WW=$$(( $(NG_W) * 2 )) NG_WH=$$(( $(NG_H) * 2 )) \
	find "$(GAME)" -type f \( -name '*.flix' -o -name '*.json' -o -name '*.toml' -o -name '*.md' -o -name 'Makefile' \) \
	  -exec perl -pi -e 's/__NAME__/$$ENV{NG_NAME}/g; s/__TITLE__/$$ENV{NG_TITLE}/g; s/__WW__/$$ENV{NG_WW}/g; s/__WH__/$$ENV{NG_WH}/g; s/__W__/$$ENV{NG_W}/g; s/__H__/$$ENV{NG_H}/g;' {} +; \
	if [ -f "$(GAME)/AGENTS.local.md" ]; then \
	  NG_TPL='$(NG_TEMPLATE)' perl -pi -e 's/^(## この(?:画面|ゲーム)の画風)\s*$$/$$1\n\n（テンプレ $$ENV{NG_TPL} の画風の仮置き。**最初に決めて、ここに** 自分の画風を書き直す — 決め方は画風の聞き取りスキル）/' "$(GAME)/AGENTS.local.md"; \
	fi; \
	printf '%s\n' '# このマシンの実行環境 (git には入れない — .gitignore 済み)。make new-game が生成。' '# ?= なのは Studio が環境変数 ENGINE で渡してくる同梱 engine を勝たせるため。' 'ENGINE ?= $(CURDIR)' > "$(GAME)/local.mk"; \
	mkdir -p "$(GAME)/$(ENGINE_FULL_SUBPATH)"; \
	cp "$(ENGINE_FULL_FPKG_SRC)" "$(GAME)/$(ENGINE_FULL_SUBPATH)/$(ENGINE_FULL_FPKG_NAME)"; \
	cp "$(ENGINE_FULL_TOML_SRC)" "$(GAME)/$(ENGINE_FULL_SUBPATH)/$(ENGINE_FULL_TOML_NAME)"; \
	for d in cache external; do \
	  if [ -d "lib/$$d" ]; then mkdir -p "$(GAME)/lib"; cp -R "lib/$$d" "$(GAME)/lib/$$d"; fi; \
	done; \
	echo "[new-game] lib/ を種付けしました（engine 手元に無い Maven 依存 (LWJGL natives 等) は初回ビルドで自動ダウンロードされます）"; \
	git -C "$(GAME)" init -q; \
	git -C "$(GAME)" config core.hooksPath bin/githooks; \
	$(MAKE) --no-print-directory sync-agents GAME="$(GAME)"; \
	echo "[new-game] 産声の確認: check → test → render-all"; \
	$(MAKE) --no-print-directory -C "$(GAME)" check ENGINE="$(CURDIR)"; \
	$(MAKE) --no-print-directory -C "$(GAME)" test ENGINE="$(CURDIR)"; \
	$(MAKE) --no-print-directory -C "$(GAME)" render-all ENGINE="$(CURDIR)"; \
	echo ""; \
	echo "🎉 新しいゲームが産まれました: $(GAME)"; \
	echo "  次にやること:"; \
	echo "    cd $(GAME) && make run              … ウィンドウを開いて遊ぶ（矢印キーで移動）"; \
	echo "    make reference-update                 … いまの絵をリファレンス画像(基準)にする"; \
	echo "    Studio で $(GAME) を開く            … 色や数値をフォームから調整する"; \
	echo "  git init 済み・未コミットです。最初のコミットは自分の手で。"

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
upgrade-game: engine-full-fresh
	@if [ -z "$(GAME)" ]; then echo "error: GAME を指定してください (make upgrade-game GAME=/abs/path)"; exit 1; fi
	@bin/fge upgrade-game --game "$(GAME)" --version "$(VERSION)" \
	  --fpkg "$(ENGINE_FULL_FPKG_SRC)" --toml "$(ENGINE_FULL_TOML_SRC)" \
	  --dest "$(ENGINE_FULL_SUBPATH)" --make "$(MAKE)" \
	  --fpkg-name "$(ENGINE_FULL_FPKG_NAME)" --toml-name "$(ENGINE_FULL_TOML_NAME)" \
	  $(if $(REFERENCE),--reference,) || [ $$? -eq 3 ]
