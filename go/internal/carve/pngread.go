package carve

// PNG を読んで、色票つき (color type 3) や
// RGB (2) も RGBA として取り出せる形にする。
//
//	fge-go carve-pngread 絵.png     # 大きさ・形式・色数を出す

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// Image は展開した絵。全画素を組にせず、必要な所だけ取り出す。
type Image struct {
	im *pxlib.Image
}

// Width は幅。
func (im *Image) Width() int { return im.im.W }

// Height は高さ。
func (im *Image) Height() int { return im.im.H }

// At は (x, y) の RGBA。
func (im *Image) At(x, y int) [4]int {
	o := (y*im.im.W + x) * 4
	p := im.im.Pix
	return [4]int{int(p[o]), int(p[o+1]), int(p[o+2]), int(p[o+3])}
}

// OpenImage は PNG を読む。
//
// WhyNot: デコーダを書き起こさないのは pxlib.LoadPNG が同じ範囲
// (8bit・インターレース無し) を同じ理由で弾き、色票・グレー・RGB を
// 同じ RGBA に開くため。
func OpenImage(path string) (*Image, error) {
	im, err := pxlib.LoadPNG(path)
	if err != nil {
		return nil, err
	}
	return &Image{im: im}, nil
}

// RunPNGRead は carve-pngread の入口。
func RunPNGRead(out *strings.Builder, args []string) (int, error) {
	for _, path := range args {
		img, err := OpenImage(path)
		if err != nil {
			return 1, err
		}
		var xs, ys []int
		colors := NewCounter[RGB]()
		for y := 0; y < img.Height(); y++ {
			for x := 0; x < img.Width(); x++ {
				c := img.At(x, y)
				if c[3] > 8 {
					xs = append(xs, x)
					ys = append(ys, y)
					colors.Add(RGB{c[0], c[1], c[2]}, 1)
				}
			}
		}
		fmt.Fprintf(out, "%s: %dx%d  中身 %dx%d  %d 色\n",
			filepath.Base(path), img.Width(), img.Height(),
			maxOf(xs)-minOf(xs)+1, maxOf(ys)-minOf(ys)+1, colors.Len())
	}
	return 0, nil
}
