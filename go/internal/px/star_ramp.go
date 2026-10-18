package px

// px.ramp: 基準の色から段の列（暗 → 明）を作る。既定は検査（ramp-order・ramp-hue・ramp-chroma）をはじめから満たす:
// 明るくなるたびに色相を黄の向きへ同じ向きに hue_step 度ずつ回し・明るさは単調で明るい側ほど刻みが小さく・
// 彩度は真ん中が高い山で明るい段ほど下げる。色そのものは台本が選ぶ（基準の色・段の数・回し方は引数）。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"go.starlark.net/starlark"
)

// rampOklch は基準の色（Oklch の色相 h0 度・彩度 c0）から n 段の色を作る（検査と同じ Oklch の上で作る）。
// 明るさ L は dark〜light を上に凸に・彩度は真ん中が山で両端を下げ、明るい段（L ≥ 0.88）はさらに下げる・
// 色相は明るくなるたびに黄（Oklch の 100°）の向きへ hue_step 度ずつ回す。sRGB の外は彩度を下げて収める。
func rampOklch(h0, c0 float64, n int, hueStep, dark, light float64) []string {
	toYellow := math.Mod(100-h0+540, 360) - 180
	dir := 1.0
	if toYellow < 0 {
		dir = -1
	}
	if hueStep > 0 && math.Abs(toYellow) < hueStep*float64(n-1)/2 {
		dir = 0.5 * dir // 黄に近い色は回し過ぎない
	}
	mid := float64(n-1) / 2
	c0 = math.Max(c0, 0.06)
	out := make([]string, n)
	for i := 0; i < n; i++ {
		t := float64(i) / float64(n-1)
		l := dark + (light-dark)*(1-math.Pow(1-t, 1.25))
		c := c0 * (0.5 + 0.5*math.Sin(math.Pi*(0.15+0.7*t)))
		if l >= 0.88 {
			c = math.Min(c, 0.05)
		}
		h := (h0 + dir*hueStep*(float64(i)-mid)) * math.Pi / 180
		for k := 0; k < 40; k++ { // sRGB に収まるまで彩度を下げる
			want := pxlib.Oklab{l, c * math.Cos(h), c * math.Sin(h)}
			hex := pxlib.HexOfOklab(want)
			if back, ok := pxlib.OklabOfHex(hex); ok && math.Abs(back[0]-want[0]) < 0.01 && math.Hypot(back[1]-want[1], back[2]-want[2]) < 0.006 {
				out[i] = hex
				break
			}
			c *= 0.9
		}
		if out[i] == "" {
			out[i] = pxlib.HexOfOklab(pxlib.Oklab{l, 0, 0})
		}
	}
	return out
}

// starRamp は px.ramp(base, n=5, hue_step=12, dark=0.25, light=0.95): "#rrggbb" の列（暗 → 明）を返す。px.palette の色に渡す。
func starRamp(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var base string
	n := 5
	var hueStep, dark, light starlark.Value = starlark.Float(12), starlark.Float(0.25), starlark.Float(0.95)
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "base", &base, "n?", &n, "hue_step?", &hueStep, "dark?", &dark, "light?", &light); err != nil {
		return nil, err
	}
	hs, _ := starlark.AsFloat(hueStep)
	dk, _ := starlark.AsFloat(dark)
	lt, _ := starlark.AsFloat(light)
	if n < 3 || n > 16 || hs < 0 || hs > 30 || dk < 0 || lt > 1 || dk >= lt {
		return nil, fmt.Errorf("%s: n は 3〜16・hue_step は 0〜30 度・0 ≤ dark < light ≤ 1", b.Name())
	}
	c, ok := pxlib.RGBAOfValue(base)
	if !ok {
		return nil, fmt.Errorf("%s: base は \"#rrggbb\"", b.Name())
	}
	lab := pxlib.OklabOfRGBA(c)
	h := math.Atan2(lab[2], lab[1]) * 180 / math.Pi
	ch := math.Hypot(lab[1], lab[2])
	var out []starlark.Value
	for _, hex := range rampOklch(h, ch, n, hs, dk, lt) {
		out = append(out, starlark.String(hex))
	}
	return starlark.NewList(out), nil
}
