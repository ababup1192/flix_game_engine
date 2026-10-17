package snd

// 音量の測り方: ITU-R BS.1770-4 の統合ラウドネス（LUFS。左右は重み 1 で足す）。K 特性（高域の棚 + 低域の切り）を
// どのサンプルレートでも同じ式で作り（libebur128 と同じ係数の式）、400ms の窓を 100ms ずつずらして
// -70 LUFS の絶対の門と -10 LU の相対の門を通した平均。400ms より短い音は全体を 1 つの窓にする（規格の外の扱い）。
// true peak は 4 倍に読み直した波のピーク（BS.1770-4 の付録 2 の考え方。48 タップの窓つき sinc）。
// 検査の報告に使う物は Go の math のまま。normalize は測った値を 0.01 dB に丸めてから倍率にする（機械の差で書き出しが変わらないように）。

import (
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
)

type biquad struct{ b0, b1, b2, a1, a2 float64 }

func (f biquad) run(x []float64) []float64 {
	out := make([]float64, len(x))
	var x1, x2, y1, y2 float64
	for i, v := range x {
		y := f.b0*v + f.b1*x1 + f.b2*x2 - f.a1*y1 - f.a2*y2
		x2, x1 = x1, v
		y2, y1 = y1, y
		out[i] = y
	}
	return out
}

func kWeighting(rate float64) (biquad, biquad) {
	f0, g, q := 1681.974450955533, 3.999843853973347, 0.7071752369554196
	k := math.Tan(math.Pi * f0 / rate)
	vh := math.Pow(10, g/20)
	vb := math.Pow(vh, 0.4996667741545416)
	a0 := 1 + k/q + k*k
	shelf := biquad{(vh + vb*k/q + k*k) / a0, 2 * (k*k - vh) / a0, (vh - vb*k/q + k*k) / a0, 2 * (k*k - 1) / a0, (1 - k/q + k*k) / a0}
	f0, q = 38.13547087602444, 0.5003270373238773
	k = math.Tan(math.Pi * f0 / rate)
	a0 = 1 + k/q + k*k
	high := biquad{1, -2, 1, 2 * (k*k - 1) / a0, (1 - k/q + k*k) / a0}
	return shelf, high
}

// LUFS は統合ラウドネス（chans はチャンネルごと）。無音は -inf。
func LUFS(rate int, chans [][]float64) float64 {
	if len(chans) == 0 || len(chans[0]) == 0 {
		return math.Inf(-1)
	}
	shelf, high := kWeighting(float64(rate))
	var ys [][]float64
	for _, x := range chans {
		ys = append(ys, high.run(shelf.run(x)))
	}
	n := len(ys[0])
	block := int(0.4 * float64(rate))
	hop := int(0.1 * float64(rate))
	power := func(a, b int) float64 {
		p := 0.0
		for _, y := range ys {
			p += meanSquare(y[a:b])
		}
		return p
	}
	var z []float64
	if n < block {
		z = append(z, power(0, n))
	} else {
		for s := 0; s+block <= n; s += hop {
			z = append(z, power(s, s+block))
		}
	}
	loud := func(ms float64) float64 { return -0.691 + 10*math.Log10(ms) }
	gated := func(th float64) (float64, int) {
		sum, n := 0.0, 0
		for _, m := range z {
			if m > 0 && loud(m) > th {
				sum += m
				n++
			}
		}
		return sum, n
	}
	sum, n := gated(-70)
	if n == 0 {
		return math.Inf(-1)
	}
	rel := loud(sum/float64(n)) - 10
	sum, n = gated(rel)
	if n == 0 {
		return math.Inf(-1)
	}
	return loud(sum / float64(n))
}

func meanSquare(x []float64) float64 {
	s := 0.0
	for _, v := range x {
		s += v * v
	}
	return s / float64(max(1, len(x)))
}

// dBFS は振幅を dB に（0 は -inf）。
func dBFS(a float64) float64 {
	if a <= 0 {
		return math.Inf(-1)
	}
	return 20 * math.Log10(a)
}

func peakOf(chans ...[]float64) float64 {
	p := 0.0
	for _, x := range chans {
		for _, v := range x {
			p = math.Max(p, math.Abs(v))
		}
	}
	return p
}

// tpTaps は 4 倍の読み直しの係数（位相 4 × 12 タップ。Hann の窓つき sinc。crmath で作るのでどの機械でも同じ）。
var tpTaps = func() [4][12]float64 {
	var t [4][12]float64
	for ph := 0; ph < 4; ph++ {
		for k := 0; k < 12; k++ {
			x := float64(k-6) + float64(ph)/4 // 読む点からの距離（サンプル）
			s := 1.0
			if x != 0 {
				s = crmath.Sin(math.Pi*x) / (math.Pi * x)
			}
			w := 0.5 + 0.5*crmath.Cos(math.Pi*x/7)
			t[ph][k] = s * w
		}
	}
	return t
}()

// truePeakOf は 4 倍に読み直した波の絶対値の最大（チャンネルの中で一番大きい物）。
func truePeakOf(chans ...[]float64) float64 {
	p := 0.0
	for _, x := range chans {
		n := len(x)
		for i := 0; i < n; i++ {
			for ph := 0; ph < 4; ph++ {
				if ph == 0 {
					p = math.Max(p, math.Abs(x[i]))
					continue
				}
				v := 0.0
				for k := 0; k < 12; k++ {
					j := i + 6 - k
					if j >= 0 && j < n {
						v = v + float64(tpTaps[ph][k]*x[j])
					}
				}
				p = math.Max(p, math.Abs(v))
			}
		}
	}
	return p
}

func rmsOf(x []float64) float64 { return math.Sqrt(meanSquare(x)) }
