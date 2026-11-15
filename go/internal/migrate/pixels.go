package migrate

import (
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
)

// Thresholds はコマの画素の線引き（10.3。差は 0〜255 の段で数える）。
type Thresholds struct {
	DoneDelta    int     // lineDone: 1 画素の差がこれ以内なら同じ
	DoneRatio    float64 // lineDone: 同じ画素がこの割合以上で通る
	MidMean      float64 // mid: 画素の差の平均がこれ以下で通る
	Still3DDelta int     // 3D の背景の休みの位置
	Still3DRatio float64
	ShiftPx      int     // 絵のずれをこの px まで許す（近くに同じ色の画素があれば同じと見る）
	RectPx       float64 // objects の矩形のずれ（px）
	BusDB        float64 // バスの音量の差
	BusStep      float64 // バスの音量を比べる間隔（秒）
	SilentDB     float64 // これ以下の音量は無音と見る
}

// DefaultThresholds は 10.3 の表の値。
func DefaultThresholds() Thresholds {
	return Thresholds{DoneDelta: 2, DoneRatio: 0.995, MidMean: 3, Still3DDelta: 3, Still3DRatio: 0.99,
		ShiftPx: 2, RectPx: 2, BusDB: 1, BusStep: 0.1, SilentDB: -60}
}

// PixelStats は 2 枚のコマの差。Mean は全画素・RGB の差の平均、Max は最大、Within は差が delta 以内の画素の割合。
type PixelStats struct {
	Mean   float64
	Max    int
	Within float64
}

func loadNRGBA(path string) (*image.NRGBA, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	img, err := png.Decode(f)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if n, ok := img.(*image.NRGBA); ok && n.Rect.Min == (image.Point{}) {
		return n, nil
	}
	b := img.Bounds()
	out := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(out, out.Rect, img, b.Min, draw.Src)
	return out, nil
}

// comparePixels は 2 枚を比べ、画素ごとの差（RGB のいちばん大きい差）も返す（差の色の図を作り直さずに書くため）。
// 1 画素の差は、相手の同じ所から shift px 以内の画素のうち、いちばん近い色との差（合格線「絵は数画素のずれまで許す」）。
// WhyNot: internal/compare の DiffNRGBA を使わない — あちらは同じ所の画素だけを比べ、ずれを許さない（reference の SHA の退行を見る物）。
func comparePixels(a, b *image.NRGBA, delta, shift int) (PixelStats, []uint8, error) {
	if a.Rect.Dx() != b.Rect.Dx() || a.Rect.Dy() != b.Rect.Dy() {
		return PixelStats{Mean: 255, Max: 255}, nil, fmt.Errorf("大きさが違う（%dx%d と %dx%d）", a.Rect.Dx(), a.Rect.Dy(), b.Rect.Dx(), b.Rect.Dy())
	}
	n := a.Rect.Dx() * a.Rect.Dy()
	gaps := make([]uint8, n)
	var sum, within int64
	maxD := 0
	for i := 0; i < n; i++ {
		o := i * 4
		px, chans := pixelGap(a, b, o, o)
		if px > delta && shift > 0 {
			// WhyNot: a から b の近くを探すだけにしない — b にだけ足された小さな点は、周りの a の色が近くにあるので見逃す。
			pa, ca := nearestGap(a, b, i, shift, px, chans)
			pb, cb := nearestGap(b, a, i, shift, px, chans)
			px, chans = max(pa, pb), max(ca, cb)
		}
		gaps[i] = uint8(px)
		sum += int64(chans)
		maxD = max(maxD, px)
		if px <= delta {
			within++
		}
	}
	return PixelStats{Mean: float64(sum) / float64(n*3), Max: maxD, Within: float64(within) / float64(n)}, gaps, nil
}

// writeHeat は差の色の図を書く（差の大きい所ほど赤い・同じ所は前の絵を暗く）。
func writeHeat(path string, a *image.NRGBA, gaps []uint8, delta int) error {
	out := image.NewNRGBA(a.Rect)
	for i, px := range gaps {
		o := i * 4
		out.Pix[o+3] = 255
		if int(px) <= delta {
			g := uint8((int(a.Pix[o]) + int(a.Pix[o+1]) + int(a.Pix[o+2])) / 12)
			out.Pix[o], out.Pix[o+1], out.Pix[o+2] = g, g, g
			continue
		}
		c := heatColor(int(px))
		out.Pix[o], out.Pix[o+1], out.Pix[o+2] = c.R, c.G, c.B
	}
	return writePNG(path, out)
}

// pixelGap は a の oa と b の ob の画素の差（RGB のいちばん大きい差と、3 つの差の和）。
func pixelGap(a, b *image.NRGBA, oa, ob int) (int, int) {
	px, sum := 0, 0
	for c := 0; c < 3; c++ {
		d := int(a.Pix[oa+c]) - int(b.Pix[ob+c])
		if d < 0 {
			d = -d
		}
		sum += d
		if d > px {
			px = d
		}
	}
	return px, sum
}

// nearestGap は b の shift px 以内でいちばん差の小さい画素との差。
func nearestGap(a, b *image.NRGBA, i, shift, px, sum int) (int, int) {
	w, h := a.Rect.Dx(), a.Rect.Dy()
	x, y := i%w, i/w
	for dy := -shift; dy <= shift; dy++ {
		for dx := -shift; dx <= shift; dx++ {
			nx, ny := x+dx, y+dy
			if nx < 0 || ny < 0 || nx >= w || ny >= h {
				continue
			}
			p, s := pixelGap(a, b, i*4, (ny*w+nx)*4)
			if p < px || p == px && s < sum {
				px, sum = p, s
			}
		}
	}
	return px, sum
}

// heatColor は差の大きさを黄（小）→ 赤（大）にする。
func heatColor(d int) color.NRGBA {
	if d > 64 {
		d = 64
	}
	return color.NRGBA{R: 255, G: uint8(220 - d*220/64), B: 0, A: 255}
}

func writePNG(path string, img image.Image) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := png.Encode(f, img); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
