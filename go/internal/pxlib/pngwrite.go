package pxlib

import (
	"image"
	"image/png"
	"os"
	"path/filepath"
)

// WritePNG は画像を PNG で書く（置き場のフォルダが無ければ作る）。
func WritePNG(path string, img image.Image) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	fh, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := png.Encode(fh, img); err != nil {
		fh.Close()
		return err
	}
	return fh.Close()
}

// ImageOfRows は画素の行（非乗算の RGBA。行の長さは 1 行目に揃える）を絵にする。
//
// WhyNot: 書いたバイト列そのものを絵の同一性の物差しに使わない。圧縮の仕方が
// 変われば同じ画素でもバイト列は変わる。比べるなら LoadPNG で開いた画素で見る。
func ImageOfRows(rows [][]RGBA) *image.NRGBA {
	w := 0
	if len(rows) > 0 {
		w = len(rows[0])
	}
	img := image.NewNRGBA(image.Rect(0, 0, w, len(rows)))
	for y, row := range rows {
		for x, px := range row[:min(len(row), w)] {
			copy(img.Pix[y*img.Stride+x*4:], px[:])
		}
	}
	return img
}
