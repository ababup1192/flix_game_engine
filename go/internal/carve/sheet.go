package carve

// 工程の絵を 4 方向 × コマの一覧に並べる。
//
//	fge-go carve-sheet 2_陰影

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// SheetViews は一覧に並べる向き。
var SheetViews = []string{"front", "east", "back", "west"}

// SheetFrames は一覧に並べるコマ。
var SheetFrames = []string{"idle", "walk_0", "walk_1", "walk_2", "walk_3",
	"swing_0", "swing_1", "swing_2",
	"jump_0", "jump_1", "jump_2"}

// RunSheet は carve-sheet の入口。root は assets / gallery を置く根。
func RunSheet(out *strings.Builder, root string, args []string, rules *Rules) (int, error) {
	stage := "2_陰影"
	if len(args) > 0 {
		stage = args[0]
	}
	var made []string
	bodies, err := sortedDir(filepath.Join(root, "gallery"))
	if err != nil {
		return 1, err
	}
	for _, body := range bodies {
		home := filepath.Join(root, "gallery", body, stage)
		if !isDir(home) {
			continue
		}
		type tile struct {
			w, h int
			px   [][]RGBA
		}
		var tiles []tile
		for _, v := range SheetViews {
			for _, f := range SheetFrames {
				img, err := pxlib.LoadPNG(filepath.Join(home, fmt.Sprintf("%s_%s.png", v, f)))
				if err != nil {
					return 1, err
				}
				tiles = append(tiles, tile{img.W, img.H, img.Rows()})
			}
		}
		tw, th := 0, 0
		for _, t := range tiles {
			if t.w > tw {
				tw = t.w
			}
			if t.h > th {
				th = t.h
			}
		}
		cols := len(SheetFrames) * len(SheetViews)
		canvas := make([][]RGBA, th)
		for y := range canvas {
			row := make([]RGBA, tw*cols)
			for x := range row {
				row[x] = rules.SheetBack
			}
			canvas[y] = row
		}
		for i, t := range tiles {
			ox := i*tw + (tw-t.w)/2
			oy := th - t.h
			for y := 0; y < t.h; y++ {
				for x := 0; x < t.w; x++ {
					if t.px[y][x][3] != 0 {
						canvas[oy+y][ox+x] = t.px[y][x]
					}
				}
			}
		}
		path := filepath.Join(root, "gallery", fmt.Sprintf("_一覧_%s_%s.png", body, stage))
		if err := pxlib.WritePNG(path, pxlib.ImageOfRows(canvas)); err != nil {
			return 1, err
		}
		rel, _ := filepath.Rel(root, path)
		made = append(made, rel)
	}
	fmt.Fprintln(out, strings.Join(made, "\n"))
	return 0, nil
}

func sortedDir(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names, nil
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
