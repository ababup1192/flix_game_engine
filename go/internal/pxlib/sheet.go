package pxlib

// 見本のシート: 1 コマを「実寸・拡大・地の色の上の拡大・前の周との差」の 4 列で並べる。
// 地の色の上で見ないと、輪郭が地に溶けるかを判断できない。差の列は変わった画素だけを赤で示す。

import (
	"image"
	"image/color"
)

// SheetFrame は 1 コマの実色。Px[y][x] の A が 0 なら透明。Prev は前の周の同じコマ（無ければ nil）。
type SheetFrame struct {
	Px   [][]color.RGBA
	Prev [][]color.RGBA
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
	for _, f := range frames {
		fh := len(f.Px)
		fw := 0
		if fh > 0 {
			fw = len(f.Px[0])
		}
		cw = max(cw, fw+gap+3*(fw*scale+gap))
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
		fill(img, image.Rect(x2, oy, x2+fw*scale, oy+len(f.Px)*scale), ground)
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
