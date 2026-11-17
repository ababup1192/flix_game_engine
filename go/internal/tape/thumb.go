package tape

import (
	"encoding/json"
	"image"
	"image/jpeg"
	"os"
)

// thumbLookahead はシーンの頭から何コマ先までを見出しの絵の候補にするか（0.5 秒ごとなので 8 秒）。
const thumbLookahead = 16

// pickSceneThumbs は各シーンの見出しの絵に、頭から thumbLookahead コマのうち一番明るいコマの番号を scenes の thumb に書く。
// WhyNot: シーンの頭のコマをそのまま使わない — 場面の頭は暗転から明けるところが多く、夜の場面では見出しが真っ黒に見えた。
// 絵が読めない時は何も書かない（頁は頭のコマに戻る）。
func pickSceneThumbs(t *Tape, stripPath string, strip Strip) {
	var scenes []scene
	if err := json.Unmarshal(t.raw["scenes"], &scenes); err != nil || len(scenes) == 0 {
		return
	}
	f, err := os.Open(stripPath)
	if err != nil {
		return
	}
	defer f.Close()
	img, err := jpeg.Decode(f)
	if err != nil {
		return
	}
	for i, s := range scenes {
		if s.T == nil {
			continue
		}
		end := strip.Count
		if i+1 < len(scenes) && scenes[i+1].T != nil {
			end = int(*scenes[i+1].T * StripPerSec)
		}
		first := int(*s.T*StripPerSec) + 1
		if first >= strip.Count {
			first = strip.Count - 1
		}
		last := first + thumbLookahead
		if last > end {
			last = end
		}
		best, bestLuma := first, -1.0
		for c := first; c < last && c < strip.Count; c++ {
			x, y := strip.cellOrigin(c)
			if l := cellLuma(img, x, y, strip.W, strip.H); l > bestLuma {
				best, bestLuma = c, l
			}
		}
		n := best
		scenes[i].Thumb = &n
	}
	if b, err := json.Marshal(scenes); err == nil {
		t.raw["scenes"] = b
	}
}

// cellLuma は strip の 1 コマ（左上 x0・y0 から幅 w・高さ h）の明るさの平均（4 画素おきに間引いて読む）。
func cellLuma(img image.Image, x0, y0, w, h int) float64 {
	sum, n := 0.0, 0
	for y := y0; y < y0+h; y += 4 {
		for x := x0; x < x0+w; x += 4 {
			r, g, b, _ := img.At(x, y).RGBA()
			sum += 0.299*float64(r) + 0.587*float64(g) + 0.114*float64(b)
			n++
		}
	}
	if n == 0 {
		return 0
	}
	return sum / float64(n)
}
