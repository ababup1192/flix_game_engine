package snd

// 左右を一緒に見る効果の op: normalize（音量をそろえる）・reverb・delay（機種の外の厚み。style の breaks で許す物だけ）。
// reverb と delay は song の送り（chip.json の fx）と同じ式。ループのある音は「頭 + 輪 + 輪」に掛けて 2 周目の輪を切り出すので、
// 尾が継ぎ目の頭へ回り込む（song と同じ手）。

import (
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
)

func init() {
	register(&opDef{
		Name:    "normalize",
		Summary: "統合ラウドネスを lufs にそろえ、true peak が peak_dbtp を超えるなら倍率を下げる（倍率だけ。ループする音は輪の 1 周で測る）",
		Machine: "混ぜる段の音量（どの機種でも書ける）",
		Example: `{"normalize": {"lufs": -16}}`,
		Params: []opreg.Param{
			{Name: "lufs", Type: opreg.Number, Summary: "目標の統合ラウドネス（LUFS。省くと kind の目安）", Lo: bound(-60), Hi: bound(0)},
			{Name: "peak_dbtp", Type: opreg.Number, Summary: "true peak の上限（dBTP。省くと snd.json の truePeakDbtp）", Lo: bound(-20), Hi: bound(0)},
		},
		Mix: mixNormalize,
	})
	register(&opDef{
		Name:    "reverb",
		Summary: "部屋の響き（櫛形 8 本 + 全域通過 4 本の Freeverb 型。左右で長さをずらして広げる）を wet だけ足す",
		Machine: "無し（機種の外。スーファミのエコーより長い響き）",
		Break:   "reverb",
		Example: `{"reverb": {"room": 0.6, "wet": 0.2}}`,
		Params:  reverbParams,
		Mix: func(c *rctx, x sig, a opreg.Args) (sig, error) {
			p := reverbOf(a)
			return loopWrapped(x, func(chans [][]float64) [][]float64 {
				l, r := reverbRun(c.rate, monoOf(chans), p)
				return addWet(chans, l, r, p.wet)
			}), nil
		},
	})
	register(&opDef{
		Name:    "delay",
		Summary: "帰還つきのディレイ（ms ごとに feedback 倍で返る。pingpong で左右に交互に返す・帰還の道で lowpass）を wet だけ足す",
		Machine: "無し（機種の外。機種の中なら song のチャンネルに遅らせた写しを置く）",
		Break:   "delay",
		Example: `{"delay": {"ms": 300, "feedback": 0.35, "wet": 0.25}}`,
		Params: append([]opreg.Param{
			{Name: "ms", Type: opreg.Number, Required: true, Summary: "遅れ（ミリ秒）", Lo: bound(1), Hi: bound(4000)},
		}, delayParams...),
		Mix: func(c *rctx, x sig, a opreg.Args) (sig, error) {
			p := delayOf(a)
			p.frames = c.frames(a.Num("ms"))
			return loopWrapped(x, func(chans [][]float64) [][]float64 {
				l, r := delayRun(c.rate, monoOf(chans), p)
				return addWet(chans, l, r, p.wet)
			}), nil
		},
	})
}

var reverbParams = []opreg.Param{
	{Name: "room", Type: opreg.Number, Default: 0.5, Summary: "部屋の大きさ（0〜1。響きの長さ）", Lo: bound(0), Hi: bound(1)},
	{Name: "damp", Type: opreg.Number, Default: 0.5, Summary: "響きの高域の減り（0〜1）", Lo: bound(0), Hi: bound(1)},
	{Name: "wet", Type: opreg.Number, Default: 0.2, Summary: "響きの量", Lo: bound(0), Hi: bound(2)},
	{Name: "predelay_ms", Type: opreg.Number, Default: 0.0, Summary: "響きの始まりの遅れ（ミリ秒）", Lo: bound(0), Hi: bound(200)},
}

var delayParams = []opreg.Param{
	{Name: "feedback", Type: opreg.Number, Default: 0.35, Summary: "返る量（0〜0.95）", Lo: bound(0), Hi: bound(0.95)},
	{Name: "wet", Type: opreg.Number, Default: 0.25, Summary: "返りの量", Lo: bound(0), Hi: bound(2)},
	{Name: "pingpong", Type: opreg.Bool, Default: true, Summary: "左右に交互に返す（モノラルの書き出しでは真ん中）"},
	{Name: "lowpass", Type: opreg.Number, Default: 6000.0, Summary: "帰還の道のローパス（Hz。返るたびに暗くなる）", Lo: bound(100), Hi: bound(20000)},
}

type reverbParam struct{ room, damp, wet, predelay float64 }

func reverbOf(a opreg.Args) reverbParam {
	return reverbParam{a.Num("room"), a.Num("damp"), a.Num("wet"), a.Num("predelay_ms")}
}

type delayParam struct {
	frames            int
	feedback, wet, lp float64
	pingpong          bool
}

func delayOf(a opreg.Args) delayParam {
	return delayParam{feedback: a.Num("feedback"), wet: a.Num("wet"), lp: a.Num("lowpass"), pingpong: a.Bool("pingpong")}
}

// monoOf は左右を半分ずつ足した 1 本（モノラルはそのまま）。
func monoOf(chans [][]float64) []float64 {
	if len(chans) == 1 {
		return chans[0]
	}
	out := make([]float64, len(chans[0]))
	for i := range out {
		out[i] = float64(chans[0][i]+chans[1][i]) * 0.5
	}
	return out
}

// addWet は元の音に響き（左・右）を wet 倍で足す（モノラルは左右の平均）。
func addWet(chans [][]float64, l, r []float64, wet float64) [][]float64 {
	out := make([][]float64, len(chans))
	for k, x := range chans {
		y := make([]float64, len(x))
		for i, v := range x {
			w := l[i]
			switch {
			case len(chans) == 1:
				w = float64(l[i]+r[i]) * 0.5
			case k == 1:
				w = r[i]
			}
			y[i] = v + float64(w*wet)
		}
		out[k] = y
	}
	return out
}

// loopWrapped は尾の残る効果を掛ける。ループがあれば「頭 + 輪 + 輪」に掛けて 2 周目の輪を切り出す（尾が継ぎ目に回る）。
func loopWrapped(x sig, fn func([][]float64) [][]float64) sig {
	ls, n := x.loopStart, x.frames()
	if ls < 0 || ls >= n {
		return sig{ch: fn(x.ch), loopStart: ls}
	}
	long := make([][]float64, len(x.ch))
	for k, c := range x.ch {
		long[k] = append(append([]float64{}, c...), c[ls:]...)
	}
	y := fn(long)
	out := make([][]float64, len(y))
	for k, c := range y {
		out[k] = append(append([]float64{}, c[:ls]...), c[n:]...)
	}
	return sig{ch: out, loopStart: ls}
}

// ── normalize ──

func mixNormalize(c *rctx, x sig, a opreg.Args) (sig, error) {
	target := c.kindLUFS
	if a.Has("lufs") {
		target = a.Num("lufs")
	}
	ceil := c.truePeak
	if a.Has("peak_dbtp") {
		ceil = a.Num("peak_dbtp")
	}
	l := LUFS(int(c.rate), loopBody(x.ch, x.loopStart))
	if math.IsInf(l, -1) {
		return x, nil
	}
	// 測った値は 0.01 dB に丸めてから倍率にする（測る式は Go の math。機械の差で倍率が変わらないように）
	db := math.Round((target-l)*100) / 100
	tp := math.Round(dBFS(truePeakOf(x.ch...))*100) / 100
	if tp+db > ceil {
		db = ceil - tp
	}
	g, err := crmath.Pow(10, db/20)
	if err != nil {
		return sig{}, err
	}
	return sig{ch: gainAll(g, x.ch), loopStart: x.loopStart}, nil
}

// ── reverb（Freeverb 型。数は 44.1kHz の時の長さを rate に合わせて伸び縮みさせる） ──

var (
	combTune    = []int{1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617}
	allpassTune = []int{556, 441, 341, 225}
)

const stereoSpread = 23

// reverbRun は 1 本の入りから響きの左・右を作る。
func reverbRun(rate float64, in []float64, p reverbParam) ([]float64, []float64) {
	scale := func(n int) int { return max(1, int(float64(n)*rate/44100)) }
	pre := int(p.predelay * rate / 1000)
	fb := float64(p.room*0.28) + 0.7
	damp := p.damp * 0.4
	side := func(spread int) []float64 {
		out := make([]float64, len(in))
		combs := make([][]float64, len(combTune))
		for i, t := range combTune {
			combs[i] = make([]float64, scale(t+spread))
		}
		filt := make([]float64, len(combTune))
		idx := make([]int, len(combTune))
		aps := make([][]float64, len(allpassTune))
		for i, t := range allpassTune {
			aps[i] = make([]float64, scale(t+spread))
		}
		aidx := make([]int, len(allpassTune))
		for i := range in {
			x := 0.0
			if i-pre >= 0 {
				x = in[i-pre] * 0.015
			}
			sum := 0.0
			for k, buf := range combs {
				y := buf[idx[k]]
				filt[k] = float64(y*(1-damp)) + float64(filt[k]*damp)
				buf[idx[k]] = x + float64(filt[k]*fb)
				idx[k] = (idx[k] + 1) % len(buf)
				sum += y
			}
			for k, buf := range aps {
				b := buf[aidx[k]]
				o := b - sum
				buf[aidx[k]] = sum + float64(b*0.5)
				aidx[k] = (aidx[k] + 1) % len(buf)
				sum = o
			}
			out[i] = sum * 3 // 入りの 0.015 と櫛 8 本で小さくなる分を戻す（wet 1 でおよそ元と同じ大きさ）
		}
		return out
	}
	return side(0), side(stereoSpread)
}

// ── delay ──

// delayRun は 1 本の入りから返りの左・右を作る（pingpong は左 → 右 → 左…と交互に返す）。
func delayRun(rate float64, in []float64, p delayParam) ([]float64, []float64) {
	n := max(1, p.frames)
	e, err := crmath.Exp(float64(-tau*p.lp) / rate)
	if err != nil {
		e = 0
	}
	k := 1 - e
	bl, br := make([]float64, n), make([]float64, n)
	l, r := make([]float64, len(in)), make([]float64, len(in))
	lpL, lpR := 0.0, 0.0
	at := 0
	for i, x := range in {
		yl, yr := bl[at], br[at]
		lpL = lpL + float64(k*(yl-lpL))
		lpR = lpR + float64(k*(yr-lpR))
		if p.pingpong {
			bl[at] = x + float64(lpR*p.feedback)
			br[at] = float64(lpL * p.feedback)
		} else {
			bl[at] = x + float64(lpL*p.feedback)
			br[at] = bl[at]
		}
		l[i], r[i] = yl, yr
		at = (at + 1) % n
	}
	return l, r
}
