package snd

// 効果の op: 声の音源の後と post（混ぜた後）に順に掛ける。

import (
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
)

const tau = 6.283185307179586

func init() {
	register(&opDef{
		Name:    "fade",
		Summary: "頭を 1 倍・終わりを 0 倍へ直線で先細らせる（times 回重ねると急になる）",
		Machine: "無し（ゲームボーイなら steps で書く）",
		Example: `{"fade": {}}`,
		Params:  []opreg.Param{timesP},
		Fx: func(c *rctx, x []float64, a opreg.Args) ([]float64, error) {
			for t := 0; t < a.Int("times"); t++ {
				x = fadeOnce(x)
			}
			return x, nil
		},
	})
	register(&opDef{
		Name:    "rasp",
		Summary: "隣のサンプルとの差 × 0.7（低い成分を落とした擦れ。times 回重ねる）",
		Machine: "無し",
		Example: `{"rasp": {"times": 2}}`,
		Params:  []opreg.Param{timesP},
		Fx: func(c *rctx, x []float64, a opreg.Args) ([]float64, error) {
			for t := 0; t < a.Int("times"); t++ {
				x = raspOnce(x)
			}
			return x, nil
		},
	})
	register(&opDef{
		Name:    "svf",
		Summary: "2 極のステートバリアブルフィルタ。中心を hz から to_hz へ指数で動かす（mode = band・low）",
		Machine: "無し（フィルタは機種の外）",
		Example: `{"svf": {"hz": 5500, "to_hz": 450, "q": 0.6, "gain": 0.42}}`,
		Params: []opreg.Param{
			{Name: "mode", Type: opreg.Choice, Default: "band", Choices: []string{"band", "low"}, Summary: "出口（band = 中心のまわり・low = 中心より下）"},
			{Name: "hz", Type: opreg.Number, Required: true, Summary: "頭の中心（Hz）", Lo: bound(1), Hi: bound(20000)},
			{Name: "to_hz", Type: opreg.Number, Summary: "終わりの中心（Hz。省くと動かない）", Lo: bound(1), Hi: bound(20000)},
			{Name: "q", Type: opreg.Number, Default: 0.6, Summary: "減衰（小さいほど鋭く鳴る）", Lo: bound(0.01), Hi: bound(2)},
			{Name: "gain", Type: opreg.Number, Default: 1.0, Summary: "出口の倍率", Lo: bound(0), Hi: bound(8)},
		},
		Fx: fxSVF,
	})
	register(&opDef{
		Name:    "env",
		Summary: "立ち上がり attack_ms・hold_ms 保ってから decay_ms の速さで指数に減衰（decay_ms 0 は減衰なし）",
		Machine: "無し（ゲームボーイの音量は 16 段の steps）",
		Example: `{"env": {"attack_ms": 0.5, "decay_ms": 40}}`,
		Params: []opreg.Param{
			{Name: "attack_ms", Type: opreg.Number, Default: 0.5, Summary: "立ち上がり（ミリ秒）", Lo: bound(0), Hi: bound(10000)},
			{Name: "decay_ms", Type: opreg.Number, Default: 0.0, Summary: "1/e まで落ちる時間（ミリ秒）", Lo: bound(0), Hi: bound(60000)},
			{Name: "hold_ms", Type: opreg.Number, Default: 0.0, Summary: "保つ時間（ミリ秒）", Lo: bound(0), Hi: bound(60000)},
		},
		Fx: fxEnv,
	})
	register(&opDef{
		Name:    "steps",
		Summary: "音量を level/15 から every_ms ごとに 1 段ずつ下げる（0 で止まる。16 段の音量包絡）",
		Machine: "ゲームボーイの音量包絡（NRx2: 初めの音量 4 bit・1/64 秒 × n ごとに 1 段）",
		Example: `{"steps": {"level": 15, "every_ms": 15.625}}`,
		Params: []opreg.Param{
			{Name: "level", Type: opreg.Int, Default: 15.0, Summary: "初めの段（0〜15）", Lo: bound(0), Hi: bound(15)},
			{Name: "every_ms", Type: opreg.Number, Default: 15.625, Summary: "1 段下げる間（ミリ秒。0 は下げない）", Lo: bound(0), Hi: bound(10000)},
		},
		Fx: fxSteps,
	})
	register(&opDef{
		Name:    "gain",
		Summary: "音量を by 倍にする",
		Machine: "混ぜる段の音量（どの機種でも書ける）",
		Example: `{"gain": {"by": 0.5}}`,
		Params:  []opreg.Param{{Name: "by", Type: opreg.Number, Required: true, Summary: "倍率", Lo: bound(0), Hi: bound(64)}},
		Fx: func(c *rctx, x []float64, a opreg.Args) ([]float64, error) {
			return gainOf(a.Num("by"), x), nil
		},
	})
	register(&opDef{
		Name:    "lowpass",
		Summary: "1 極のローパスを stages 段（hz より上をなだらかに落とす）",
		Machine: "無し（フィルタは機種の外）",
		Example: `{"lowpass": {"hz": 4500, "stages": 2}}`,
		Params: []opreg.Param{
			{Name: "hz", Type: opreg.Number, Required: true, Summary: "切る所（Hz）", Lo: bound(1), Hi: bound(20000)},
			{Name: "stages", Type: opreg.Int, Default: 1.0, Summary: "段の数", Lo: bound(1), Hi: bound(4)},
		},
		Fx: func(c *rctx, x []float64, a opreg.Args) ([]float64, error) {
			for s := 0; s < a.Int("stages"); s++ {
				var err error
				if x, err = lowpass1(c, a.Num("hz"), x); err != nil {
					return nil, err
				}
			}
			return x, nil
		},
	})
	register(&opDef{
		Name:    "finish",
		Summary: "仕上げ: 尾の無音を切り、25Hz の低域切り・8kHz の 2 段ローパス・頭 in_ms と尾 out_ms の直線の絞りを掛け、ピークを 1 にそろえる",
		Machine: "無し（仕上げのフィルタは機種の外）",
		Example: `{"finish": {"in_ms": 2, "out_ms": 12}}`,
		Params: []opreg.Param{
			{Name: "in_ms", Type: opreg.Number, Default: 2.0, Summary: "頭の絞り（ミリ秒）", Lo: bound(0), Hi: bound(1000)},
			{Name: "out_ms", Type: opreg.Number, Default: 12.0, Summary: "尾の絞り（ミリ秒）", Lo: bound(0), Hi: bound(1000)},
		},
		Mix: fxFinish,
	})
	register(&opDef{
		Name:    "resample",
		Summary: "ratio 倍の速さで読み直す（高さが ratio 倍・長さが 1/ratio。線形の補間）",
		Machine: "無し（読み直しは機種の外。ゲームボーイなら高さを書き直す）",
		Example: `{"resample": {"ratio": 1.125}}`,
		Params:  []opreg.Param{{Name: "ratio", Type: opreg.Number, Required: true, Summary: "速さの倍率", Lo: bound(0.0625), Hi: bound(16)}},
		Fx: func(c *rctx, x []float64, a opreg.Args) ([]float64, error) {
			return resample(a.Num("ratio"), x), nil
		},
	})
}

var timesP = opreg.Param{Name: "times", Type: opreg.Int, Default: 1.0, Summary: "重ねる回数", Lo: bound(1), Hi: bound(8)}

func fadeOnce(x []float64) []float64 {
	out := make([]float64, len(x))
	n := float64(len(x))
	for i, s := range x {
		out[i] = s * (1 - float64(i)/n)
	}
	return out
}

func raspOnce(x []float64) []float64 {
	out := make([]float64, len(x))
	prev := 0.0
	for i, s := range x {
		out[i] = (s - prev) * 0.7
		prev = s
	}
	return out
}

func gainOf(g float64, x []float64) []float64 {
	out := make([]float64, len(x))
	for i, s := range x {
		out[i] = s * g
	}
	return out
}

// fxSVF は SfxRender.slashSweep・Dsp.resonantLowpass と同じ式（中心はサンプルごとに比 ratio を掛けて動く）。
func fxSVF(c *rctx, x []float64, a opreg.Args) ([]float64, error) {
	n := max(1, len(x))
	fc := a.Num("hz")
	ratio := 1.0
	if a.Has("to_hz") {
		var err error
		if ratio, err = crmath.Pow(a.Num("to_hz")/fc, 1/float64(n)); err != nil {
			return nil, err
		}
	}
	q, g := a.Num("q"), a.Num("gain")
	limit, low := 1.2, a.Str("mode") == "low"
	if low {
		limit = 1.0
	}
	out := make([]float64, len(x))
	lo, band := 0.0, 0.0
	for i, s := range x {
		f := math.Min(limit, float64(tau*fc)/c.rate)
		lo1 := lo + float64(f*band)
		high := s - lo1 - float64(q*band)
		band1 := band + float64(f*high)
		if low {
			out[i] = g * lo1
		} else {
			out[i] = g * band1
		}
		lo, band = lo1, band1
		fc = fc * ratio
	}
	return out, nil
}

// fxEnv は Dsp.envelope と同じ式。
func fxEnv(c *rctx, x []float64, a opreg.Args) ([]float64, error) {
	na := c.frames(a.Num("attack_ms"))
	nh := 0
	if a.Num("hold_ms") > 0 {
		nh = c.frames(a.Num("hold_ms"))
	}
	decay := a.Num("decay_ms")
	tauN := float64(decay*c.rate) / 1000
	out := make([]float64, len(x))
	for i, s := range x {
		g := 1.0
		switch {
		case i < na:
			g = float64(i) / float64(na)
		case decay <= 0 || i < na+nh:
		default:
			var err error
			if g, err = crmath.Exp(-float64(i-na-nh) / tauN); err != nil {
				return nil, err
			}
		}
		out[i] = s * g
	}
	return out, nil
}

func fxSteps(c *rctx, x []float64, a opreg.Args) ([]float64, error) {
	from, every := a.Int("level"), a.Num("every_ms")
	per := 0
	if every > 0 {
		per = c.frames(every)
	}
	out := make([]float64, len(x))
	for i, s := range x {
		level := from
		if per > 0 {
			level = max(0, from-i/per)
		}
		out[i] = s * float64(level) / 15
	}
	return out, nil
}

// lowpass1 は 1 極のローパス（Dsp.lowpass と同じ式。係数は 1 度だけ作る）。
func lowpass1(c *rctx, hz float64, x []float64) ([]float64, error) {
	e, err := crmath.Exp(float64(-tau*hz) / c.rate)
	if err != nil {
		return nil, err
	}
	k := 1 - e
	out := make([]float64, len(x))
	y := 0.0
	for i, s := range x {
		y = y + float64(k*(s-y))
		out[i] = y
	}
	return out, nil
}

// fxFinish は Dsp.finish と同じ手順（左右は尾の切り方とピークをそろえる）。
func fxFinish(c *rctx, x sig, a opreg.Args) (sig, error) {
	end := x.frames()
	quiet := func(i int) bool {
		for _, ch := range x.ch {
			if math.Abs(ch[i]) >= 0.0005 {
				return false
			}
		}
		return true
	}
	for end > 0 && quiet(end-1) {
		end--
	}
	peak := 0.0
	var ys [][]float64
	for _, ch := range x.ch {
		ch = ch[:end]
		lp, err := lowpass1(c, 25, ch)
		if err != nil {
			return sig{}, err
		}
		hp := make([]float64, len(ch))
		for i := range ch {
			hp[i] = ch[i] - lp[i]
		}
		y, err := lowpass1(c, 8000, hp)
		if err == nil {
			y, err = lowpass1(c, 8000, y)
		}
		if err != nil {
			return sig{}, err
		}
		n := len(y)
		na, nb := c.frames(a.Num("in_ms")), c.frames(a.Num("out_ms"))
		for i, s := range y {
			gIn, gOut := 1.0, 1.0
			if i < na {
				gIn = float64(i) / float64(na)
			}
			if n-1-i < nb {
				gOut = float64(n-1-i) / float64(nb)
			}
			y[i] = s * gIn * gOut
			peak = math.Max(peak, math.Abs(y[i]))
		}
		ys = append(ys, y)
	}
	ls := x.loopStart
	if ls >= end {
		ls = -1
	}
	if peak <= 0 {
		return sig{ch: ys, loopStart: ls}, nil
	}
	return sig{ch: gainAll(1/peak, ys), loopStart: ls}, nil
}

// resample は Dsp.resample と同じ（線形の補間。ratio 1 はそのまま）。
func resample(ratio float64, x []float64) []float64 {
	if ratio == 1 {
		return x
	}
	n := int(float64(len(x)) / ratio)
	at := func(k int) float64 {
		if k < len(x) {
			return x[k]
		}
		return 0
	}
	out := make([]float64, n)
	for i := range out {
		pos := float64(i) * ratio
		k := int(math.Floor(pos))
		f := pos - math.Floor(pos)
		out[i] = at(k) + float64((at(k+1)-at(k))*f)
	}
	return out
}
