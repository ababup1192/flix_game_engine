package status

import (
	"fmt"

	"github.com/ababup1192/flix_game_engine/go/internal/cmdhint"
	"github.com/ababup1192/flix_game_engine/go/internal/rendercache"
	"github.com/ababup1192/flix_game_engine/go/internal/worktreegc"
)

// worktreeWarnCount はこの本数を超えたら worktree の行を出す（消せる物が分かっていればいつでも出す）。
const worktreeWarnCount = 20

// renderCacheWarnBytes は塗った PNG のキャッシュがこれを超えたら行を出す。
const renderCacheWarnBytes = 8 << 30

// sectionDisk はディスクを食う物を知らせる: たまった worktree と、塗った PNG のキャッシュ。
// WhyNot: ここで worktree ごとに git status を流したりフォルダを歩いたりしない — status は毎回の立ち上げで流れ、
// 100 本の worktree を見ると数秒かかる。本数は git worktree list の 1 回、消せる数と大きさは
// make worktree-gc の控え、キャッシュの大きさは render-cache が数えた控えを読むだけ。
func sectionDisk(c *ctx, out *[]string) {
	if listing := c.git("worktree", "list", "--porcelain"); listing != "" {
		n := len(worktreegc.ParsePorcelain(listing)) - 1
		common := c.git("rev-parse", "--path-format=absolute", "--git-common-dir")
		cache, ok := worktreegc.ReadCache(common)
		switch {
		case ok && cache.Removable > 0:
			*out = append(*out, fmt.Sprintf("worktree %d 本。%s の worktree-gc で消せた物 %d 本・約 %s → %s（一覧）・APPLY=1（消す）",
				n, cache.Time.Format("01-02"), cache.Removable, worktreegc.HumanBytes(cache.Bytes), cmdhint.Command("worktree-gc")))
		case n > worktreeWarnCount:
			*out = append(*out, fmt.Sprintf("worktree %d 本 → %s（取り込み済みで変更の無い物を一覧に）", n, cmdhint.Command("worktree-gc")))
		}
	}
	dir := rendercache.Dir()
	if s, ok := rendercache.ReadSummary(dir); ok && s.Bytes >= renderCacheWarnBytes {
		*out = append(*out, fmt.Sprintf("render-cache %s（%s・%s 時点）→ 減らすなら bin/fge render-cache prune --max-mb 4096",
			worktreegc.HumanBytes(s.Bytes), dir, s.Time.Format("01-02")))
	}
}
