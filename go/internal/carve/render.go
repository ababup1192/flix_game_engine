package carve

// sprite.json の文字格子を PNG に描く（描くのは pxlib.RenderDoc）。
//
//	fge-go carve-render                 # bin/assets 配下を全部 bin/gallery へ
//	fge-go carve-render a.sprite.json   # 指定ファイルだけ

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// RGBA は 1 画素（pxlib の型）。
type RGBA = pxlib.RGBA

// RGB は不透明な色。
type RGB [3]int

// opaque は不透明な色を画素にする。
func opaque(c RGB) RGBA { return RGBA{byte(c[0]), byte(c[1]), byte(c[2]), 255} }

// RunRender は carve-render の入口。root は assets / gallery を置く根。
func RunRender(out *strings.Builder, root string, args []string) (int, error) {
	outDir := filepath.Join(root, "gallery")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return 1, err
	}
	targets := args
	if len(targets) == 0 {
		var found []string
		_ = filepath.Walk(filepath.Join(root, "assets"), func(p string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() {
				return nil //nolint:nilerr // 読めない枝で全体を止めないため、黙って飛ばす
			}
			if strings.HasSuffix(p, ".sprite.json") {
				found = append(found, p)
			}
			return nil
		})
		sort.Strings(found)
		targets = found
	}
	count := 0
	for _, path := range targets {
		written, err := pxlib.RenderDoc(path, outDir)
		if err != nil {
			return 1, err
		}
		for _, w := range written {
			rel, _ := filepath.Rel(root, w)
			fmt.Fprintln(out, rel)
			count++
		}
	}
	fmt.Fprintf(out, "%d 枚を書き出した\n", count)
	return 0, nil
}
