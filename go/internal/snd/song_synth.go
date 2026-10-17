package snd

// 機種の外の音色（neo の style の breaks でだけ許す。gb には部品も手も無いので gate で止まる）。
//   - part の saw（ノコギリ。polyBLEP で折り返しを抑える）・sine（サイン。808 のキックやサブの本体）。
//   - unison: 同じ音を voices 本、cents の幅でずらして重ね、左右へ width だけ広げる（ノコギリなら supersaw・パッド）。
//   - filter: 2 極のフィルタ（TPT の SVF。low・band・high）。切る所は hz か sweep（小節 → Hz）で、鳴らした頭に env オクターブ
//     上がって env_ms で戻る（音ごとの開閉）。sweep は小節で開け閉めする（ビルドアップ・落とす所）。
//   - pitchenv: 鳴らした頭に semis 半音上から ms で指数に落ちる（808 のキック・タム・ザップ）。
//   - fm: サインの高さを ratio 倍のサインで揺らす 2 オペレータの FM。揺らす深さ index は鳴らした頭から decay_ms で floor の割合まで減る
//     （エレピ・ベル・オルゴール。part は sine だけ）。
// 係数は 16 サンプルごとに作り直す（tan・exp・pow は crmath。2 台で同じ値になる）。

import (
	"fmt"
	"math"
	"sort"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
)

// unisonDef は同じ音を voices 本、cents の幅でずらして重ね、左右へ width だけ広げる。
type unisonDef struct {
	voices       int
	cents, width float64
}

// filterDef は 2 極のフィルタ。切る所は hz（sweep があれば小節で動かす）から、鳴らした頭に env オクターブ上がり env_ms で戻る。
type filterDef struct {
	mode       string // low・band・high
	hz, q      float64
	env, envMs float64
	sweep      [][2]float64 // [小節, Hz]（頭からの小節。間は高さの比で滑らかに・外は端の値）
}

// pitchEnvDef は鳴らした頭に semis 半音上から ms の速さで指数に落ちる音程。
type pitchEnvDef struct{ semis, ms float64 }

// fmDef は 2 オペレータの FM（揺らす側の高さの比・頭の深さ・深さが減る速さ・残る深さの割合）。
type fmDef struct{ ratio, index, decayMs, floor float64 }

// synthBlock は係数を作り直すサンプルの間。
const synthBlock = 16

func parseSynth(m map[string]any, d *chanDef) error {
	if u := objectOf(m, "unison"); u != nil {
		d.unison = &unisonDef{voices: intOr(u, "voices", 3), cents: floatOr(u, "cents", 12), width: floatOr(u, "width", 0.6)}
		switch {
		case d.part == partNoise:
			return fmt.Errorf("unison は雑音に掛けられない（高さの無い音）")
		case d.unison.voices < 2 || d.unison.voices > 7:
			return fmt.Errorf("unison.voices は 2〜7（got %d）", d.unison.voices)
		case d.unison.cents < 0 || d.unison.cents > 100 || d.unison.width < 0 || d.unison.width > 1:
			return fmt.Errorf("unison.cents は 0〜100・width は 0〜1")
		}
	}
	if f := objectOf(m, "filter"); f != nil {
		mode, _ := f["mode"].(string)
		if mode == "" {
			mode = "low"
		}
		d.filter = &filterDef{mode: mode, hz: floatOr(f, "hz", 2000), q: floatOr(f, "q", 0.707),
			env: floatOr(f, "env", 0), envMs: floatOr(f, "env_ms", 120)}
		switch {
		case mode != "low" && mode != "band" && mode != "high":
			return fmt.Errorf("filter.mode は low・band・high（got %q）", mode)
		case d.filter.hz < 20 || d.filter.hz > 20000 || d.filter.q < 0.3 || d.filter.q > 12:
			return fmt.Errorf("filter.hz は 20〜20000・q は 0.3〜12")
		case d.filter.env < -8 || d.filter.env > 8 || d.filter.envMs <= 0:
			return fmt.Errorf("filter.env は -8〜8 オクターブ・env_ms は 0 より大きく")
		}
		if raw, ok := f["sweep"].([]any); ok {
			for i, p := range raw {
				pt, ok := p.([]any)
				if !ok || len(pt) != 2 {
					return fmt.Errorf("filter.sweep[%d] は [小節, Hz]", i)
				}
				bar, ok1 := pt[0].(float64)
				hz, ok2 := pt[1].(float64)
				if !ok1 || !ok2 || bar < 0 || hz < 20 || hz > 20000 {
					return fmt.Errorf("filter.sweep[%d] は [0 以上の小節, 20〜20000 Hz]", i)
				}
				d.filter.sweep = append(d.filter.sweep, [2]float64{bar, hz})
			}
			sort.SliceStable(d.filter.sweep, func(a, b int) bool { return d.filter.sweep[a][0] < d.filter.sweep[b][0] })
		}
	}
	if p := objectOf(m, "pitchenv"); p != nil {
		d.pitchEnv = &pitchEnvDef{semis: floatOr(p, "semis", 24), ms: floatOr(p, "ms", 30)}
		if math.Abs(d.pitchEnv.semis) > 60 || d.pitchEnv.ms <= 0 {
			return fmt.Errorf("pitchenv.semis は -60〜60・ms は 0 より大きく")
		}
	}
	if f := objectOf(m, "fm"); f != nil {
		d.fm = &fmDef{ratio: floatOr(f, "ratio", 1), index: floatOr(f, "index", 2), decayMs: floatOr(f, "decay_ms", 400), floor: floatOr(f, "floor", 0.2)}
		switch {
		case d.part != partSine:
			return fmt.Errorf("fm は part が sine のチャンネルにだけ書ける（got %s）", d.part)
		case d.fm.ratio < 0.25 || d.fm.ratio > 16 || d.fm.index < 0 || d.fm.index > 20:
			return fmt.Errorf("fm.ratio は 0.25〜16・index は 0〜20")
		case d.fm.decayMs <= 0 || d.fm.floor < 0 || d.fm.floor > 1:
			return fmt.Errorf("fm.decay_ms は 0 より大きく・floor は 0〜1")
		}
	}
	return nil
}

// synthBreaks はチャンネルが使う機種の外の音色（style の breaks の名前）。
func synthBreaks(cd chanDef) []string {
	var out []string
	if cd.part == partSaw || cd.part == partSine {
		out = append(out, string(cd.part))
	}
	if cd.unison != nil {
		out = append(out, "unison")
	}
	if cd.filter != nil {
		out = append(out, "filter")
	}
	if cd.pitchEnv != nil {
		out = append(out, "pitchenv")
	}
	if cd.fm != nil {
		out = append(out, "fm")
	}
	return out
}

// voiceVar は重ねの 1 本（ずらす高さ・頭の位相・左右・音量・サブを鳴らすか）。重ねの無いチャンネルは 1 本。
type voiceVar struct {
	cents, phase0, pan, scale float64
	sub                       bool
}

func unisonVoices(cd chanDef) []voiceVar {
	u := cd.unison
	if u == nil {
		return []voiceVar{{pan: cd.pan, scale: 1, sub: true}}
	}
	out := make([]voiceVar, u.voices)
	scale := 1 / math.Sqrt(float64(u.voices))
	for k := range out {
		spread := float64(2*k)/float64(u.voices-1) - 1 // -1〜1
		ph := float64(k) * 0.6180339887498949
		out[k] = voiceVar{cents: float64(u.cents * spread), phase0: ph - math.Floor(ph),
			pan: math.Max(-1, math.Min(1, cd.pan+float64(u.width*spread))), scale: scale, sub: k == 0}
	}
	return out
}

// polyBLEP はノコギリの段差のまわりを滑らかにする補正（位相 p・1 サンプルの進み dt）。
func polyBLEP(p, dt float64) float64 {
	switch {
	case p < dt:
		t := p / dt
		return float64(t+t) - float64(t*t) - 1
	case p > 1-dt:
		t := (p - 1) / dt
		return float64(t*t) + float64(t+t) + 1
	}
	return 0
}

// sawAt は帯域を抑えたノコギリ（-1〜1）。
func sawAt(p, dt float64) float64 { return float64(2*p) - 1 - polyBLEP(p, dt) }

// svf は 2 極のステートバリアブルフィルタ（Zavalishin の TPT 形。切る所を動かしても崩れない）。
type svf struct {
	mode           string
	k, a1, a2, a3  float64
	ic1eq, ic2eq   float64
	rate, lastFreq float64
}

func newSVF(mode string, q, rate float64) *svf {
	return &svf{mode: mode, k: 1 / q, rate: rate, lastFreq: -1}
}

func (f *svf) set(hz float64) {
	hz = math.Max(20, math.Min(float64(0.45*f.rate), hz))
	if hz == f.lastFreq {
		return
	}
	f.lastFreq = hz
	g := crmath.Tan(float64(math.Pi*hz) / f.rate)
	f.a1 = 1 / (1 + float64(g*(g+f.k)))
	f.a2 = float64(g * f.a1)
	f.a3 = float64(g * f.a2)
}

func (f *svf) run(x float64) float64 {
	v3 := x - f.ic2eq
	v1 := float64(f.a1*f.ic1eq) + float64(f.a2*v3)
	v2 := f.ic2eq + float64(f.a2*f.ic1eq) + float64(f.a3*v3)
	f.ic1eq = float64(2*v1) - f.ic1eq
	f.ic2eq = float64(2*v2) - f.ic2eq
	switch f.mode {
	case "band":
		return v1
	case "high":
		return x - float64(f.k*v1) - v2
	}
	return v2
}

// sweepAt は sweep の bar 小節目の切る所（点の間は高さの比で滑らかに・外は端の値）。
func sweepAt(pts [][2]float64, bar float64) float64 {
	if bar <= pts[0][0] {
		return pts[0][1]
	}
	for i := 1; i < len(pts); i++ {
		if bar <= pts[i][0] {
			a, b := pts[i-1], pts[i]
			if b[0] == a[0] {
				return b[1]
			}
			r, err := crmath.Pow(b[1]/a[1], (bar-a[0])/(b[0]-a[0]))
			if err != nil {
				return a[1]
			}
			return float64(a[1] * r)
		}
	}
	return pts[len(pts)-1][1]
}

// barTimeline は tick ごとの小節の位置（頭からの小節。ループの 2 周目は 1 周目と同じ位置に折る）。sweep の時刻に使う。
func barTimeline(s *song, totalTicks, introSteps, bodySteps int) []float64 {
	out := make([]float64, totalTicks)
	step := 0
	for t := range out {
		for s.tickOfStep(step+1) <= t {
			step++
		}
		folded := step
		if bodySteps > 0 && folded >= introSteps+bodySteps {
			folded -= bodySteps
		}
		frac := float64(t-s.tickOfStep(step)) / float64(s.stepTicks(step))
		out[t] = (float64(folded) + frac) / phraseSteps
	}
	return out
}

// synthState は 1 本の声の機種の外の音色の今（鳴らしてからのサンプル・フィルタ・音程の包絡）。
type synthState struct {
	cd     chanDef
	rate   float64
	age    int
	filter *svf
	penv   float64 // 今の block の音程の上乗せ（半音）
	fmIdx  float64 // 今の block の FM の深さ（ラジアン）
}

func newSynthState(cd chanDef, rate float64) *synthState {
	st := &synthState{cd: cd, rate: rate}
	if cd.filter != nil {
		st.filter = newSVF(cd.filter.mode, cd.filter.q, rate)
	}
	return st
}

// onset は音の頭（打ち直しを含む）で包絡を頭に戻す。
func (st *synthState) onset() { st.age = 0 }

// block は synthBlock サンプルごとに音程の包絡とフィルタの係数を作り直す（bar は今の小節の位置）。
func (st *synthState) block(bar float64) {
	ms := float64(st.age) * 1000 / st.rate
	if pe := st.cd.pitchEnv; pe != nil {
		e, _ := crmath.Exp(-ms / pe.ms)
		st.penv = float64(pe.semis * e)
	}
	if fm := st.cd.fm; fm != nil {
		e, _ := crmath.Exp(-ms / fm.decayMs)
		st.fmIdx = float64(fm.index * (fm.floor + float64((1-fm.floor)*e)))
	}
	if f := st.cd.filter; f != nil {
		hz := f.hz
		if len(f.sweep) > 0 {
			hz = sweepAt(f.sweep, bar)
		}
		if f.env != 0 {
			e, _ := crmath.Exp(-ms / f.envMs)
			r, _ := crmath.Pow(2, float64(f.env*e))
			hz = float64(hz * r)
		}
		st.filter.set(hz)
	}
}
