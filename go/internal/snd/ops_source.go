package snd

// 音源の op: pulse（矩形波）・noise（雑音）・rest（無音）。譜面の曲は song.go。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
)

func init() {
	register(&opDef{
		Name:    "pulse",
		Summary: "矩形波を ms ミリ秒。to_hz を書くと hz から to_hz へ比が一定の速さで滑る",
		Machine: "パルスのチャンネル（ゲームボーイの ch1・ch2。滑りは ch1 の sweep に当たる）",
		Example: `{"pulse": {"hz": 784, "ms": 40, "amp": 0.16}}`,
		Part:    partPulse,
		Params: []opreg.Param{
			{Name: "hz", Type: opreg.Number, Required: true, Summary: "高さ（Hz）", Lo: bound(1), Hi: bound(20000)},
			msP("長さ（ミリ秒）"),
			ampP,
			{Name: "duty", Type: opreg.Number, Default: 0.5, Summary: "山の割合（0.125・0.25・0.5・0.75 が機種の 4 種）", Lo: bound(0.01), Hi: bound(0.99)},
			{Name: "to_hz", Type: opreg.Number, Summary: "滑って着く高さ（Hz。省くと滑らない）", Lo: bound(1), Hi: bound(20000)},
			{Name: "accumulate", Type: opreg.Bool, Default: false, Summary: "位相を 1 サンプルずつ足して進める（滑る時は常にこれ。省くとサンプルの番号から位相を出す）"},
		},
		Gen: genPulse,
	})
	register(&opDef{
		Name:    "noise",
		Summary: "雑音を ms ミリ秒。kind = hash（番号のハッシュの白色雑音）・lfsr15 / lfsr7（ゲームボーイの雑音。hz 回/秒で回す）",
		Machine: "雑音のチャンネル（ゲームボーイの ch4 は lfsr15・lfsr7）",
		Example: `{"noise": {"ms": 30, "amp": 0.16}}`,
		Part:    partNoise,
		Params: []opreg.Param{
			msP("長さ（ミリ秒）"),
			ampP,
			{Name: "kind", Type: opreg.Choice, Default: "hash", Choices: []string{"hash", "lfsr15", "lfsr7"}, Summary: "雑音の作り方"},
			{Name: "hz", Type: opreg.Number, Default: 8000.0, Summary: "LFSR を回す速さ（回/秒。hash は読まない）", Lo: bound(1), Hi: bound(1048576)},
			{Name: "to_hz", Type: opreg.Number, Summary: "回す速さの着く先（比が一定の速さで滑る。省くと滑らない）", Lo: bound(1), Hi: bound(1048576)},
		},
		Gen: genNoise,
	})
	register(&opDef{
		Name:    "rest",
		Summary: "無音を ms ミリ秒（声の長さをそろえる・曲の休符）",
		Machine: "無し（どの機種でも書ける）",
		Example: `{"rest": {"ms": 180}}`,
		Params:  []opreg.Param{msP("長さ（ミリ秒）")},
		Gen: func(c *rctx, a opreg.Args) (sourceOut, error) {
			return sourceOut{s: make([]float64, c.frames(a.Num("ms"))), loopStart: -1}, nil
		},
	})
}

// glideAt は a から b へ n サンプルで比が一定の速さで滑る高さ（Dsp.glide と同じ式）。
func glideAt(a, b float64, i, n int) (float64, error) {
	t := math.Min(1, float64(i)/float64(max(1, n)))
	p, err := crmath.Pow(b/a, t)
	return float64(a * p), err
}

func genPulse(c *rctx, a opreg.Args) (sourceOut, error) {
	n := c.frames(a.Num("ms"))
	hz, amp, duty := a.Num("hz"), a.Num("amp"), a.Num("duty")
	out := make([]float64, n)
	if !a.Has("to_hz") && !a.Bool("accumulate") {
		// 位相 = 番号 / レート × 高さ の小数部（SfxSynth.tone と同じ。長く鳴らしても位相がずれ込まない）
		for i := range out {
			ph := float64(float64(i)/c.rate) * hz
			if ph-math.Floor(ph) < duty {
				out[i] = amp
			} else {
				out[i] = -amp
			}
		}
		return sourceOut{s: out, loopStart: -1, parts: []part{partPulse}}, nil
	}
	to := hz
	if a.Has("to_hz") {
		to = a.Num("to_hz")
	}
	ph := 0.0
	dur := c.frames(a.Num("ms"))
	for i := range out {
		p := ph - math.Floor(ph)
		if p < duty {
			out[i] = amp
		} else {
			out[i] = -amp
		}
		f := hz
		if to != hz {
			var err error
			if f, err = glideAt(hz, to, i, dur); err != nil {
				return sourceOut{}, err
			}
		}
		ph = ph + f/c.rate
	}
	return sourceOut{s: out, loopStart: -1, parts: []part{partPulse}}, nil
}

// hashNoise は SfxSynth.noise と同じ: 番号を 32 bit で回るハッシュに通した -1〜1。
func hashNoise(n int) float64 {
	h := int32(n)*374761393 + 668265263
	m := (h * (h + 30011)) % 20001
	if m < 0 {
		m += 20001
	}
	return float64(m-10000) / 10000
}

func genNoise(c *rctx, a opreg.Args) (sourceOut, error) {
	n := c.frames(a.Num("ms"))
	amp := a.Num("amp")
	out := make([]float64, n)
	switch a.Str("kind") {
	case "hash":
		for i := range out {
			out[i] = amp * hashNoise(i)
		}
	case "lfsr15", "lfsr7":
		hz := a.Num("hz")
		to := hz
		if a.Has("to_hz") {
			to = a.Num("to_hz")
		}
		short := a.Str("kind") == "lfsr7"
		ph, lfsr := 0.0, 32767
		for i := range out {
			f := hz
			if to != hz {
				var err error
				if f, err = glideAt(hz, to, i, n); err != nil {
					return sourceOut{}, err
				}
			}
			v := lfsrStep(f/c.rate, short, &ph, &lfsr)
			out[i] = amp * v
		}
	default:
		return sourceOut{}, fmt.Errorf("知らない kind %q", a.Str("kind"))
	}
	return sourceOut{s: out, loopStart: -1, parts: []part{partNoise}}, nil
}

// lfsrStep は 15 bit の LFSR を 1 サンプルに clocks 回ぶん回す（短周期は 6 bit 目へ戻すので 93 段で一巡する。
// ChipSynth.noiseSample と同じ）。
func lfsrStep(clocks float64, short bool, phase *float64, lfsr *int) float64 {
	total := *phase + clocks
	whole := min(64, int(math.Floor(total)))
	*phase = total - math.Floor(total)
	tap := 2
	if short {
		tap = 64
	}
	l := *lfsr
	for k := 0; k < whole; k++ {
		bit := (l ^ (l / tap)) & 1
		l = l/2 + bit*16384
	}
	*lfsr = l
	if l&1 == 0 {
		return 1
	}
	return -1
}
