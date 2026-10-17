package snd

// 音量の測り方: ITU-R BS.1770-4 の統合ラウドネス（LUFS、モノラル）。K 特性（高域の棚 + 低域の切り）を
// どのサンプルレートでも同じ式で作り（libebur128 と同じ係数の式）、400ms の窓を 100ms ずつずらして
// -70 LUFS の絶対の門と -10 LU の相対の門を通した平均。400ms より短い音は全体を 1 つの窓にする（規格の外の扱い）。
// 検査の報告に使うだけなので、ここは Go の math のまま（書き出す音には触れない）。

import "math"

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

// LUFS は統合ラウドネス。無音は -inf。
func LUFS(rate int, x []float64) float64 {
	if len(x) == 0 {
		return math.Inf(-1)
	}
	shelf, high := kWeighting(float64(rate))
	y := high.run(shelf.run(x))
	block := int(0.4 * float64(rate))
	hop := int(0.1 * float64(rate))
	var z []float64
	if len(y) < block {
		z = append(z, meanSquare(y))
	} else {
		for s := 0; s+block <= len(y); s += hop {
			z = append(z, meanSquare(y[s:s+block]))
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

func peakOf(x []float64) float64 {
	p := 0.0
	for _, v := range x {
		p = math.Max(p, math.Abs(v))
	}
	return p
}

func rmsOf(x []float64) float64 { return math.Sqrt(meanSquare(x)) }
