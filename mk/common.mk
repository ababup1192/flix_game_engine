# common.mk — エンジンの Makefile と mk/game.mk の両方が取り込むターゲット（help・hooks・api・module・mvn-cache-share）。
#
# 違いはエンジンの置き場の前置きだけで、取り込む側が include より前に決める:
#   FGE_PREFIX      … エンジンの根への前置き（エンジンでは空・ゲームでは $(ENGINE)/）。レシピでは "" で括って使う
#   MVN_CACHE_SHARE … bin/mvn-cache-share.sh の場所
#   HELP_SRC        … help が説明を読むファイル（空白を含むパスは "" で括って並べる。書き方は mk/help.awk の頭）
#   HELP_HEAD / HELP_TAIL / HELP_ALL_TAIL … 一覧の前・後・help-all の最後に流すシェルの 1 文（任意）
#   API_AFTER       … make api の後に流すシェルの 1 文（任意）
#
# WhyNot: 前置きを ENGINE の名前で決めない — エンジンの Makefile で ENGINE を決めると、環境変数で来た
# ENGINE（Studio が渡す同梱の engine）を書き換えたまま子の make と道具へ渡してしまう。

.PHONY: help help-all hooks api module mvn-cache-share strays worktree-gc

# python3 を起こす前置き（レシピでは素の python3 でなく $(PYTHON3) と書く）。macOS で DEVELOPER_DIR が nix の apple-sdk を
# 指していても動くように、bin/py3 が起こす 1 回だけ CommandLineTools へ向け直す（理由は bin/py3 の頭）。
PYTHON3 ?= $(if $(filter Windows_NT,$(OS)),python3,"$(FGE_PREFIX)bin/py3")

##@ 一覧・引く・配線
help: ### | 日ごろ使うターゲットの一覧（全部は make help-all）
	@$(HELP_HEAD)
	@awk -v ALL=0 -f "$(FGE_PREFIX)mk/help.awk" $(HELP_SRC)
	@$(HELP_TAIL)

help-all: ## | 全部のターゲットの一覧
	@$(HELP_HEAD)
	@awk -v ALL=1 -f "$(FGE_PREFIX)mk/help.awk" $(HELP_SRC)
	@$(HELP_TAIL)
	@$(HELP_ALL_TAIL)

# コミット時のゲート (描き出した絵の混入・矩形だけの View・規約の配線ずれを止める)。
# .git/hooks は git 管理外なので clone ごとに 1 回この配線が要る (status が未配線を知らせる)。
hooks: ### | git の pre-commit ゲート（bin/githooks）をこの clone に配線する（clone ごとに 1 回）
	@git config core.hooksPath bin/githooks
	@echo "[hooks] 配線しました: pre-commit = bin/githooks/pre-commit (中身は bin/fge precommit)"

# エンジン API の型・引数を 1 行で引く（docs/api-digest の grep・中身は bin/fge api）。例: make api Q=gradPolygon 。ソースを読む前にまずこれ。
# WhyNot: ゲームの bin/fge を呼ばない — 配った時期が古いゲームの bin/fge-go は api・module を持たない。engine の bin/fge は engine と同じ版。
api: ## Q=<名前> | エンジン API の型・引数を 1 行で引く（ソースを読む前にまずこれ）
	@"$(FGE_PREFIX)bin/fge" api $(if $(FGE_PREFIX),--engine "$(patsubst %/,%,$(FGE_PREFIX))") "$(Q)"
	@$(API_AFTER)

# やりたいこと → エンジンのモジュールを 1 行ずつ引く（docs/modules/<分野>.md の grep・中身は bin/fge module）。
# 例: make module Q=スクロール 。当たった行に「分野のファイル:行番号」が付く。自前で書く前にまずこれ。
module: ## Q=<語> | やりたいこと → エンジンのモジュールを 1 行ずつ引く（自前で書く前にまずこれ）
	@"$(FGE_PREFIX)bin/fge" module $(if $(FGE_PREFIX),--engine "$(patsubst %/,%,$(FGE_PREFIX))") "$(Q)"

# lib/cache（Maven の取り物）を共有の置き場 1 か所へ移して symlink にする（中身は捨てない・使用中は飛ばす）。
# ROOT を省くとこの作業場。置き場・移し方・同時に使っても壊れない根拠は bin/mvn-cache-share.sh。
mvn-cache-share: ### [ROOT=<dir>] | lib/cache を共有の置き場への symlink にする（status が「向いていない」と言ったら）
	@"$(MVN_CACHE_SHARE)" "$(or $(ROOT),$(CURDIR))"

# このリポジトリ（engine なら main と全部の worktree）から起こして、親がいなくなったまま残っているプロセス
# （ヘッドレスの Chrome・http.server・ゲームのウィンドウ・消した worktree の常駐）を一覧にする。人の普段の Chrome やアプリは拾わない。
# 拾い方と止めない物の理由は bin/strays.sh の頭。
strays: ## [KILL=1] [AGE=<分>] | このリポから起こして取り残されたプロセス（Chrome・http.server・ウィンドウ・常駐）を一覧に（KILL=1 で AGE 分より古い物を止める）
	@KILL="$(KILL)" AGE="$(AGE)" ROOT="$(STRAYS_ROOT)" "$(FGE_PREFIX)bin/strays.sh" "$(CURDIR)"

# たまった git worktree のうち、main（INTO=<枝> で替える）に取り込み済み・未コミット 0・未追跡 0・使っているプロセス無し・
# GC_AGE 時間（既定 12）触っていない物を一覧にする。APPLY=1 で git worktree remove（枝は残す）。make status が結果を 1 行に出す。
worktree-gc: ## [APPLY=1] [INTO=<枝>] [GC_AGE=<時間>] | 取り込み済みで変更の無い git worktree を一覧に（APPLY=1 で消す・枝は残す）
	@"$(FGE_PREFIX)bin/fge" worktree-gc $(if $(INTO),--base "$(INTO)") $(if $(GC_AGE),--age "$(GC_AGE)") $(if $(filter 1,$(APPLY)),--apply)
