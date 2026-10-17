package carve

// コマの PNG を並べて動く GIF にする。
//
//	fge-go carve-gifs [縮小率] [工程名...]

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// GifCycle は動きごとのコマの並び。
type GifCycle struct {
	Name   string
	Frames []string
}

// bits は LZW の符号をビット列に詰める。辞書を伸ばさず、幅が上がる前に clear を打つ。
func bits(codes []int, widthStart, clear, end int) []byte {
	out := []byte{}
	acc, accBits := uint32(0), 0
	width := widthStart
	push := func(code int) {
		acc |= uint32(code) << accBits
		accBits += width
		for accBits >= 8 {
			out = append(out, byte(acc&0xFF))
			acc >>= 8
			accBits -= 8
		}
	}
	push(clear)
	since := 0
	for _, code := range codes {
		push(code)
		since++
		if since >= 250 {
			push(clear)
			since = 0
		}
	}
	push(end)
	if accBits != 0 {
		out = append(out, byte(acc&0xFF))
	}
	return out
}

// GifOf は画素の番号の並びから GIF を組む。
func GifOf(width, height int, frames [][]int, palette []RGB, delay, transparent int) []byte {
	table := make([]byte, 0, 768)
	for i := 0; i < 256; i++ {
		c := RGB{0, 0, 0}
		if i < len(palette) {
			c = palette[i]
		}
		table = append(table, byte(c[0]), byte(c[1]), byte(c[2]))
	}
	out := []byte("GIF89a")
	out = append(out, byte(width&255), byte(width>>8), byte(height&255), byte(height>>8), 0xF7, 0, 0)
	out = append(out, table...)
	out = append(out, []byte("\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00")...)
	for _, pixels := range frames {
		out = append(out, 0x21, 0xF9, 4, 0b00001001, byte(delay&255), byte(delay>>8),
			byte(transparent), 0)
		out = append(out, 0x2C, 0, 0, 0, 0, byte(width&255), byte(width>>8),
			byte(height&255), byte(height>>8), 0)
		out = append(out, 8)
		data := bits(pixels, 9, 256, 257)
		for i := 0; i < len(data); i += 255 {
			end := i + 255
			if end > len(data) {
				end = len(data)
			}
			chunk := data[i:end]
			out = append(out, byte(len(chunk)))
			out = append(out, chunk...)
		}
		out = append(out, 0x00)
	}
	out = append(out, 0x3B)
	return out
}

// FromPNGs は PNG を読んで、色を番号に振り直した GIF を作る。番号 0 は透明。
func FromPNGs(paths []string, shrink int, delay int) ([]byte, error) {
	type sheetImage struct {
		w, h int
		rows [][]RGBA
	}
	var read []sheetImage
	for _, path := range paths {
		img, err := pxlib.LoadPNG(path)
		if err != nil {
			return nil, err
		}
		w, h, rows := img.W, img.H, img.Rows()
		if shrink > 1 {
			var small [][]RGBA
			for y := 0; y < h; y += shrink {
				var line []RGBA
				for x := 0; x < w; x += shrink {
					line = append(line, rows[y][x])
				}
				small = append(small, line)
			}
			rows = small
			w, h = len(rows[0]), len(rows)
		}
		read = append(read, sheetImage{w, h, rows})
	}
	w, h := 0, 0
	for _, r := range read {
		if r.w > w {
			w = r.w
		}
		if r.h > h {
			h = r.h
		}
	}
	palette := []RGB{{0, 0, 0}}
	index := map[RGB]int{}
	var frames [][]int
	for _, im := range read {
		ox, oy := (w-im.w)/2, h-im.h
		flat := make([]int, 0, w*h)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				px := RGBA{0, 0, 0, 0}
				sy, sx := y-oy, x-ox
				if 0 <= sy && sy < im.h && 0 <= sx && sx < im.w {
					px = im.rows[sy][sx]
				}
				if px[3] == 0 {
					flat = append(flat, 0)
					continue
				}
				key := RGB{int(px[0]), int(px[1]), int(px[2])}
				if _, ok := index[key]; !ok {
					index[key] = len(palette)
					palette = append(palette, key)
				}
				flat = append(flat, index[key])
			}
		}
		frames = append(frames, flat)
	}
	return GifOf(w, h, frames, palette, delay, 0), nil
}

// RunGifs は carve-gifs の入口。root は assets / gallery を置く根。
func RunGifs(out *strings.Builder, root string, args []string, rules *Rules) (int, error) {
	shrink := 6
	if len(args) > 0 {
		n, err := strconv.Atoi(args[0])
		if err != nil {
			return 1, err
		}
		shrink = n
	}
	var only []string
	if len(args) > 1 {
		only = args[1:]
	}
	var made []string
	bodies, err := sortedDir(filepath.Join(root, "gallery"))
	if err != nil {
		return 1, err
	}
	for _, body := range bodies {
		home := filepath.Join(root, "gallery", body)
		if !isDir(home) {
			continue
		}
		stages, err := sortedDir(home)
		if err != nil {
			return 1, err
		}
		for _, stage := range stages {
			if len(only) > 0 && !contains(only, stage) {
				continue
			}
			for _, view := range SheetViews {
				for _, cycle := range rules.GifCycles {
					var paths []string
					ok := true
					for _, f := range cycle.Frames {
						p := filepath.Join(home, stage, fmt.Sprintf("%s_%s.png", view, f))
						if _, err := os.Stat(p); err != nil {
							ok = false
						}
						paths = append(paths, p)
					}
					if !ok {
						continue
					}
					outPath := filepath.Join(root, "gallery",
						fmt.Sprintf("%s_%s_%s_%s.gif", cycle.Name, body, stage, view))
					data, err := FromPNGs(paths, shrink, rules.GifDelay)
					if err != nil {
						return 1, err
					}
					if err := os.WriteFile(outPath, data, 0o644); err != nil {
						return 1, err
					}
					rel, _ := filepath.Rel(root, outPath)
					made = append(made, rel)
				}
			}
		}
	}
	fmt.Fprintln(out, strings.Join(made, "\n"))
	return 0, nil
}

func contains(list []string, v string) bool {
	for _, s := range list {
		if s == v {
			return true
		}
	}
	return false
}
