// Package rendercache は、エンジンの RenderCache（engine_tools/src/RenderCache.flix）が塗った PNG を
// キャッシュに入れる場所の見張り役。キャッシュの読み書きは Flix 側だけがする。ここは大きさを見て、古い物から消すだけ。
//
//	fge render-cache status           置き場・枚数・大きさ
//	fge render-cache prune [--max-mb N] [--quiet]   N MB（既定 4096）を超えた分を、使った時刻の古い順に消す
//
// 置き場は FGE_RENDER_CACHE（既定 ~/.cache/flix-render-cache・"off" / "0" で使わない）。Flix 側と同じ決め方。
// キャッシュの 1 枚は <置き場>/<鍵の頭 2 字>/<鍵>.png。写すたびに時刻を今にするので、時刻は「最後に使った時」。
package rendercache

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// DefaultMaxMB は prune が残す大きさの既定。動画 1 本（コマ 1000 枚前後）が数百 MB になる。
const DefaultMaxMB = 4096

// Dir は置き場。使わない設定・相対パスなら空（Flix 側と同じ決め方）。
func Dir() string {
	env := os.Getenv("FGE_RENDER_CACHE")
	switch env {
	case "off", "0":
		return ""
	case "", "verify":
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		return filepath.Join(home, ".cache", "flix-render-cache")
	}
	env = strings.TrimPrefix(env, "verify:")
	if !filepath.IsAbs(env) {
		return ""
	}
	return env
}

// キャッシュの 1 枚（<鍵の頭 2 字>/<鍵>.png）と、書きかけの残り（<鍵>.png.<時刻>-<糸>.part とその一時ファイル）。
var (
	storedRe = regexp.MustCompile(`^[0-9a-f]{2}/[0-9a-f]{64}\.png$`)
	partRe   = regexp.MustCompile(`^[0-9a-f]{2}/\.?[0-9a-f]{64}\.png\.[0-9-]+\.part`)
)

// partMaxAge より古い書きかけは、描き出しが途中で止まった残り。
const partMaxAge = time.Hour

type entry struct {
	path string
	size int64
	used time.Time
}

func scan(dir string) []entry {
	var es []entry
	filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		rel = filepath.ToSlash(rel)
		switch {
		case storedRe.MatchString(rel):
			es = append(es, entry{p, info.Size(), info.ModTime()})
		case partRe.MatchString(rel) && time.Since(info.ModTime()) > partMaxAge:
			os.Remove(p)
		}
		return nil
	})
	return es
}

// Status は置き場の様子を 1 行で書く。
func Status(out io.Writer, dir string) {
	if dir == "" {
		fmt.Fprintln(out, "render-cache: 使わない設定です（FGE_RENDER_CACHE=off）")
		return
	}
	es := scan(dir)
	var total int64
	for _, e := range es {
		total += e.size
	}
	fmt.Fprintf(out, "render-cache: %s に %d 枚・%d MB\n", dir, len(es), total>>20)
}

// Prune は maxBytes を超えた分を、使った時刻の古い順に消す。消した枚数と残りの大きさを返す。
func Prune(dir string, maxBytes int64) (removed int, kept int64) {
	if dir == "" {
		return 0, 0
	}
	es := scan(dir)
	for _, e := range es {
		kept += e.size
	}
	sort.Slice(es, func(i, j int) bool { return es[i].used.Before(es[j].used) })
	for _, e := range es {
		if kept <= maxBytes {
			break
		}
		if os.Remove(e.path) == nil {
			kept -= e.size
			removed++
		}
	}
	return removed, kept
}
