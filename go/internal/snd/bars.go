package snd

// fge snd bars: 曲の WAV を小節ごとに測る（音量・低中高の帯・左右の広がり）。山場が一番大きいか、継ぎ目の前後がそろうかを
// 数で見るための口（聞き比べの前の下見）。測るだけで、書き出しにも検査にも効かない。

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// barStat は 1 小節の測った値（dB。無音は -99）。
type barStat struct {
	Bar            int
	Loudness       float64 // K 特性の平均の大きさ（LUFS の目盛り・ゲートなし）
	Low, Mid, High float64 // 200Hz 未満・200Hz〜4kHz・4kHz 以上の RMS（dBFS・左右の平均）
	Width          float64 // 左右の差 ÷ 和（dB。-99 はモノラル・0 に近いほど広い）
	LoopHead       bool    // ループの頭がこの小節から
}

func dbOr(x float64) float64 {
	if x <= 0 {
		return -99
	}
	return 20 * math.Log10(x)
}

// onePoleLow は 1 極のローパス（帯を分けるだけ。測る用）。
func onePoleLow(x []float64, hz, rate float64) []float64 {
	a := math.Exp(-2 * math.Pi * hz / rate)
	out := make([]float64, len(x))
	y := 0.0
	for i, v := range x {
		y = (1-a)*v + a*y
		out[i] = y
	}
	return out
}

func measureBars(c Clip, bpm, beats float64) []barStat {
	rate := float64(c.Rate)
	barLen := rate * 60 / bpm * beats
	n := c.Frames()
	shelf, high := kWeighting(rate)
	var kw, lows, mids, highs [][]float64
	for _, x := range c.Chans {
		kw = append(kw, high.run(shelf.run(x)))
		lo := onePoleLow(onePoleLow(x, 200, rate), 200, rate)
		below4k := onePoleLow(onePoleLow(x, 4000, rate), 4000, rate)
		mid, hi := make([]float64, n), make([]float64, n)
		for i := range x {
			mid[i] = below4k[i] - lo[i]
			hi[i] = x[i] - below4k[i]
		}
		lows, mids, highs = append(lows, lo), append(mids, mid), append(highs, hi)
	}
	avgRMS := func(chs [][]float64, a, b int) float64 {
		s := 0.0
		for _, x := range chs {
			s += meanSquare(x[a:b])
		}
		return math.Sqrt(s / float64(len(chs)))
	}
	var out []barStat
	for k := 0; ; k++ {
		a, b := int(math.Round(float64(k)*barLen)), int(math.Round(float64(k+1)*barLen))
		if a >= n {
			break
		}
		b = min(b, n)
		if b-a < int(barLen/4) {
			break
		}
		st := barStat{Bar: k + 1, Width: -99}
		p := 0.0
		for _, y := range kw {
			p += meanSquare(y[a:b])
		}
		st.Loudness = -99
		if p > 0 {
			st.Loudness = -0.691 + 10*math.Log10(p)
		}
		st.Low, st.Mid, st.High = dbOr(avgRMS(lows, a, b)), dbOr(avgRMS(mids, a, b)), dbOr(avgRMS(highs, a, b))
		if len(c.Chans) == 2 {
			var ms, ss float64
			for i := a; i < b; i++ {
				m, s := c.Chans[0][i]+c.Chans[1][i], c.Chans[0][i]-c.Chans[1][i]
				ms += m * m
				ss += s * s
			}
			if ms > 0 && ss > 0 {
				st.Width = 10 * math.Log10(ss/ms)
			}
		}
		st.LoopHead = c.LoopStart >= 0 && c.LoopStart >= a && c.LoopStart < b
		out = append(out, st)
	}
	return out
}

func cmdBars(out, errOut *strings.Builder, workRoot string, args []string) int {
	var path string
	bpm, beats := 0.0, 4.0
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--bpm", "--beats":
			if i+1 >= len(args) {
				break
			}
			v, err := strconv.ParseFloat(args[i+1], 64)
			if err != nil || v <= 0 {
				fmt.Fprintf(errOut, "snd bars: %s は正の数（got %q）\n", args[i], args[i+1])
				return 2
			}
			if args[i] == "--bpm" {
				bpm = v
			} else {
				beats = v
			}
			i++
		default:
			path = args[i]
		}
	}
	if path == "" || bpm == 0 {
		errOut.WriteString("snd bars: <x.wav> --bpm <速さ> [--beats 4]\n")
		return 2
	}
	p := path
	if !filepath.IsAbs(p) {
		p = filepath.Join(workRoot, p)
	}
	data, err := os.ReadFile(p)
	if err != nil {
		fmt.Fprintf(errOut, "snd: %v\n", err)
		return 1
	}
	c, err := DecodeWAV(data)
	if err != nil {
		fmt.Fprintf(errOut, "snd: %s: %v\n", path, err)
		return 1
	}
	bars := measureBars(c, bpm, beats)
	fmt.Fprintf(out, "%s: %d 小節（%.0f BPM・%g 拍）。音量は K 特性の平均（ゲートなし）・帯は RMS dBFS・幅は左右の差 ÷ 和（dB）\n", path, len(bars), bpm, beats)
	out.WriteString("小節  音量    低     中     高     幅    \n")
	loud := -99.0
	for _, b := range bars {
		loud = math.Max(loud, b.Loudness)
	}
	for _, b := range bars {
		mark := ""
		if b.LoopHead {
			mark += " ← ループの頭"
		}
		if b.Loudness == loud {
			mark += " ← 一番大きい"
		}
		bar := strings.Repeat("#", max(0, int((b.Loudness+40)/1.5)))
		fmt.Fprintf(out, "%4d %6.1f %6.1f %6.1f %6.1f %6.1f  %-20s%s\n", b.Bar, b.Loudness, b.Low, b.Mid, b.High, b.Width, bar, mark)
	}
	return 0
}
