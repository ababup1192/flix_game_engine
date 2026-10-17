package pxlib

// 見本のシート: 1 コマを「実寸・拡大・地の色の上の拡大・前の周との差」の 4 列で並べる。
// 地の色の上で見ないと、輪郭が地に溶けるかを判断できない。差の列は変わった画素だけを赤で示す。
// コマ列（アニメ）なら 5 列目に玉ねぎの皮（前のコマを赤・次のコマを青で薄く重ねた上に今のコマ）を足す。

import (
	"image"
	"image/color"
)

// SheetFrame は 1 コマの実色。Px[y][x] の A が 0 なら透明。Prev は前の周の同じコマ（無ければ nil）。
type SheetFrame struct {
	Px    [][]color.RGBA
	Prev  [][]color.RGBA
	Onion [][]color.RGBA // 玉ねぎの皮（前後のコマを薄く重ねた物。地の色の上に描く。無ければ nil）
}

var (
	sheetNeutral = color.RGBA{0x2a, 0x2a, 0x33, 0xff}
	sheetChanged = color.RGBA{0xff, 0x30, 0x30, 0xff}
	sheetDim     = color.RGBA{0x55, 0x55, 0x60, 0xff}
)

// Sheet はコマを並べた 1 枚を作る。ground は地の色、scale は拡大の倍率。
func Sheet(frames []SheetFrame, ground color.RGBA, scale int) *image.RGBA {
	const gap = 6
	cw, ch := 0, 0
	cols4 := 3
	for _, f := range frames {
		if f.Onion != nil {
			cols4 = 4
		}
	}
	for _, f := range frames {
		fh := len(f.Px)
		fw := 0
		if fh > 0 {
			fw = len(f.Px[0])
		}
		cw = max(cw, fw+gap+cols4*(fw*scale+gap))
		ch = max(ch, fh*scale)
	}
	cols := max(1, min(len(frames), 1600/max(1, cw+gap)))
	rows := max(1, (len(frames)+cols-1)/cols)
	w, h := gap+cols*(cw+gap), gap+rows*(ch+gap)
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	fill(img, image.Rect(0, 0, w, h), sheetNeutral)
	for i, f := range frames {
		if len(f.Px) == 0 {
			continue
		}
		fw := len(f.Px[0])
		ox, oy := gap+(i%cols)*(cw+gap), gap+(i/cols)*(ch+gap)
		x1 := ox + fw + gap
		x2 := x1 + fw*scale + gap
		x3 := x2 + fw*scale + gap
		x4 := x3 + fw*scale + gap
		fill(img, image.Rect(x2, oy, x2+fw*scale, oy+len(f.Px)*scale), ground)
		if f.Onion != nil {
			fill(img, image.Rect(x4, oy, x4+fw*scale, oy+len(f.Px)*scale), ground)
			for y, row := range f.Onion {
				for x, c := range row {
					if c.A != 0 {
						fill(img, image.Rect(x4+x*scale, oy+y*scale, x4+(x+1)*scale, oy+(y+1)*scale), c)
					}
				}
			}
		}
		for y, row := range f.Px {
			for x, c := range row {
				changed := f.Prev != nil && (y >= len(f.Prev) || x >= len(f.Prev[y]) || f.Prev[y][x] != c)
				diff := sheetDim
				if changed {
					diff = sheetChanged
				} else if c.A == 0 {
					diff = sheetNeutral
				}
				fill(img, image.Rect(x3+x*scale, oy+y*scale, x3+(x+1)*scale, oy+(y+1)*scale), diff)
				if c.A == 0 {
					continue
				}
				img.SetRGBA(ox+x, oy+y, c)
				fill(img, image.Rect(x1+x*scale, oy+y*scale, x1+(x+1)*scale, oy+(y+1)*scale), c)
				fill(img, image.Rect(x2+x*scale, oy+y*scale, x2+(x+1)*scale, oy+(y+1)*scale), c)
			}
		}
	}
	return img
}

// Strip はコマを実寸で横に並べる（隙間 1px）。
func Strip(frames [][][]color.RGBA) *image.RGBA {
	w, h := 0, 0
	for _, f := range frames {
		if len(f) > 0 {
			w += len(f[0]) + 1
			h = max(h, len(f))
		}
	}
	img := image.NewRGBA(image.Rect(0, 0, max(1, w-1), max(1, h)))
	ox := 0
	for _, f := range frames {
		if len(f) == 0 {
			continue
		}
		for y, row := range f {
			for x, c := range row {
				if c.A != 0 {
					img.SetRGBA(ox+x, y, c)
				}
			}
		}
		ox += len(f[0]) + 1
	}
	return img
}

func fill(img *image.RGBA, r image.Rectangle, c color.RGBA) {
	r = r.Intersect(img.Bounds())
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			img.SetRGBA(x, y, c)
		}
	}
}

// Onion は前のコマ（赤）と次のコマ（青）を地の色の上に薄く重ね、今のコマを上に置いた 1 枚の色を返す。
func Onion(cur, prev, next [][]color.RGBA, ground color.RGBA) [][]color.RGBA {
	tint := func(base, c color.RGBA, t color.RGBA) color.RGBA {
		mix := func(a, b uint8, w float64) uint8 { return uint8(float64(float64(a)*(1-w)) + float64(float64(b)*w)) }
		m := color.RGBA{mix(c.R, t.R, 0.5), mix(c.G, t.G, 0.5), mix(c.B, t.B, 0.5), 0xff}
		return color.RGBA{mix(base.R, m.R, 0.35), mix(base.G, m.G, 0.35), mix(base.B, m.B, 0.35), 0xff}
	}
	out := make([][]color.RGBA, len(cur))
	for y := range cur {
		out[y] = make([]color.RGBA, len(cur[y]))
		for x := range cur[y] {
			c := ground
			for _, layer := range []struct {
				px [][]color.RGBA
				t  color.RGBA
			}{{prev, color.RGBA{0xff, 0x40, 0x40, 0xff}}, {next, color.RGBA{0x40, 0x80, 0xff, 0xff}}} {
				if y < len(layer.px) && x < len(layer.px[y]) && layer.px[y][x].A != 0 {
					c = tint(c, layer.px[y][x], layer.t)
				}
			}
			if cur[y][x].A != 0 {
				c = cur[y][x]
			}
			out[y][x] = c
		}
	}
	return out
}

// Tile3x3 は 1 コマを 3×3 に並べて scale 倍にした 1 枚（タイルの継ぎ目を見る）。
func Tile3x3(px [][]color.RGBA, ground color.RGBA, scale int) *image.RGBA {
	h := len(px)
	w := 0
	if h > 0 {
		w = len(px[0])
	}
	img := image.NewRGBA(image.Rect(0, 0, max(1, 3*w*scale), max(1, 3*h*scale)))
	fill(img, img.Bounds(), ground)
	for ty := 0; ty < 3; ty++ {
		for tx := 0; tx < 3; tx++ {
			for y, row := range px {
				for x, c := range row {
					if c.A == 0 {
						continue
					}
					X, Y := (tx*w+x)*scale, (ty*h+y)*scale
					fill(img, image.Rect(X, Y, X+scale, Y+scale), c)
				}
			}
		}
	}
	return img
}
