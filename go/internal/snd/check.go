package snd

// 検査。重さは 3 段（checklevel）: gate（外れたら WAV を書かず終了コード 1）・lint（報告だけ）・advice（報告だけ）。
// gate には原因の op（spec の中の場所）を付ける: 「その op を 1 つ外すと直る」op を書き出しの順の後ろから引く（renderer.cause）。
//
// どの検査も左右のチャンネルを 1 本ずつ見て、悪い方を出す（音量は左右を足した LUFS）。
//
//	gate   clip   ±1 を超えたサンプル（16bit に収める前・song の仕上げで切った数も）
//	gate   seam   ループの継ぎ目（終わり → 頭）の段差・前後 20ms の音量の差
//	gate   bars   輪の長さが tempo の整数小節か
//	gate   style  機種の外の op・引数・同時に鳴らす数・破ってよい所（breaks）の外の手・左右の振り方
//	gate   drone  song の 1 本のチャンネルが打ち直さず高さも変えずに droneSeconds 秒より長く鳴る（離し忘れ。song_drone.go）
//	lint   loudness  統合ラウドネス（LUFS。ループする音は輪の 1 周で測る）が kind の目安から外れる
//	lint   peak / truepeak / head / tail / dc  ピーク・4 倍に読み直したピーク（dBTP）・鳴り出しの遅れ・終わりのクリック・直流
//	advice alias  パルスの 3 倍音がナイキスト周波数を超える（折り返す）
//	advice breaks 使った機種の外の手（style が許している物。報告に「破った所」として残す）

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

// finding は検査の結果 1 つ。組み立ては newFinding の 1 か所（got と want を必ず持たせる）。
// 外へ出す形は checkres.Result（result で写す。code は snd.<check>[.<sub>]）。
type finding struct {
	Check   string           `json:"check"`
	Sub     string           `json:"sub,omitempty"` // 同じ検査の中の測り方の別（code の末尾）
	Level   checklevel.Level `json:"level"`
	Msg     string           `json:"msg"`
	Cause   string           `json:"cause,omitempty"`
	Got     float64          `json:"got"`
	Want    checkres.Want    `json:"want"`
	Ms      *float64         `json:"ms,omitempty"` // 場所の時刻（無ければ全体）
	ToMs    *float64         `json:"toMs,omitempty"`
	Channel string           `json:"channel,omitempty"`
	Tries   []checkres.Try   `json:"try,omitempty"`
}

// newFinding は結果 1 つを組み立てる唯一の口: 検査・重さ・測った値・基準・人向けの文。
func newFinding(check string, lv checklevel.Level, got float64, want checkres.Want, msg string) finding {
	return finding{Check: check, Level: lv, Got: got, Want: want, Msg: msg}
}

func (f finding) code() string {
	c := "snd." + f.Check
	if f.Sub != "" {
		c += "." + f.Sub
	}
	return c
}

// result は外へ出す形にする。検査は外れた時だけ出すので、境目ちょうどで pass に見える時は fail のまま。
func (f finding) result(rules *checkres.Rules) checkres.Result {
	r := checkres.New(f.code(), f.Level, checkres.Measure{Got: f.Got, Want: f.Want}, rules, f.Msg)
	if r.Status == checkres.Pass {
		r.Status = checkres.Fail
	}
	r.Where.Ms, r.Where.ToMs, r.Where.Channel = f.Ms, f.ToMs, f.Channel
	if f.ToMs != nil {
		r.Where.FromMs, r.Where.Ms = f.Ms, nil
	}
	r.Cause.Op = f.Cause
	r.Fix = checkres.Fix{Hint: fixHints[f.code()], Try: f.Tries}
	return r
}

// fixHints は code ごとの直し方の文。
var fixHints = map[string]string{
	"snd.style.op":         "機種の書ける op に替えるか、style の breaks に入れる",
	"snd.style.duty":       "duty を機種の 4 種のどれかに",
	"snd.style.noise-kind": "noise の kind を機種の作り方に",
	"snd.style.break":      "その手を外すか、style の breaks に足す（破った所として残る）",
	"snd.style.voices":     "同時に鳴らす声を減らす（休みを入れて重なりを外す・部品を替える）",
	"snd.drone":            "その音を mus.rest か OFF で離す",
	"snd.breaks":           "そのままでよい（破った所として報告に残る）",
	"snd.clip":             "post に normalize を書く（倍率だけで ±1 に収める）か、声の gain を下げる",
	"snd.seam.step":        "ループの頭と終わりの値をそろえる（ゼロ交差で切る・終わりに短い fade）",
	"snd.seam.level":       "ループの終わりと頭の音量をそろえる（終わりの減衰を短く・頭の立ち上がりを遅く）",
	"snd.bars":             "曲の長さを tempo の整数小節にする（loop の頭か曲の終わりを小節の頭へ）",
	"snd.loudness":         "post に normalize（lufs を省くと kind の目安）",
	"snd.peak":             "post に normalize（peak_dbtp の上限で倍率を下げる）",
	"snd.truepeak":         "post に normalize（peak_dbtp を省くと snd.json の truePeakDbtp）",
	"snd.head":             "頭の無音を削る（最初の音の at を 0 に）",
	"snd.tail":             "終わりに短い fade を足して 0 へ戻す",
	"snd.dc":               "post に highpass を足すか、片寄った波形（duty・offset）を直す",
	"snd.alias":            "パルスを低くするか、post に lowpass",
}

func (f finding) String() string {
	s := fmt.Sprintf("%-6s %-8s %s", f.Level, f.Check, f.Msg)
	if f.Cause != "" {
		s += "\n         ← 原因: " + f.Cause
	}
	return s
}

func overCount(chans [][]float64) (int, int, float64) {
	n, first, peak := 0, -1, 0.0
	for _, x := range chans {
		for i, v := range x {
			if a := math.Abs(v); a > 1 {
				if first < 0 || i < first {
					first = i
				}
				n++
				peak = math.Max(peak, a)
			}
		}
	}
	return n, first, peak
}

// loopBody はループする音の輪の 1 周（無ければ全体）。音量はここで測る（頭の 1 回より、くり返し聞く所）。
func loopBody(chans [][]float64, loopStart int) [][]float64 {
	if loopStart <= 0 || len(chans) == 0 || loopStart >= len(chans[0]) {
		return chans
	}
	var out [][]float64
	for _, x := range chans {
		out = append(out, x[loopStart:])
	}
	return out
}

// seamProblems はループの継ぎ目の困り事（無ければ空）。
// WhyNot: 前後 5ms の平均（直流）の差は見ない。110Hz の矩形波では 5ms が 1 周期に満たず、継ぎ目が正しくても差が出る。
func seamProblems(res *rendered, rate int, rules *sndRules) []finding {
	for k, x := range res.out {
		if ps := seamOf(x, res.loopStart, rate, rules); len(ps) > 0 {
			if len(res.out) == 2 {
				for i := range ps {
					ps[i].Channel = []string{"左", "右"}[k]
					ps[i].Msg = ps[i].Channel + ": " + ps[i].Msg
				}
			}
			return ps
		}
	}
	return nil
}

func seamOf(x []float64, ls, rate int, rules *sndRules) []finding {
	n := len(x)
	if ls < 0 || ls >= n-1 {
		return nil
	}
	w := min(rate/50, (n-ls)/4) // 20ms
	if w < 2 {
		return nil
	}
	step := math.Abs(x[ls] - x[n-1])
	local := 0.0
	for i := n - w; i < n-1; i++ {
		local = math.Max(local, math.Abs(x[i+1]-x[i]))
	}
	for i := ls; i < ls+w-1; i++ {
		local = math.Max(local, math.Abs(x[i+1]-x[i]))
	}
	var out []finding
	at := checkres.Ptr(float64(ls) * 1000 / float64(rate))
	if lim := float64(rules.SeamStepRatio*local) + 0.02; step > lim {
		f := newFinding("seam", checklevel.Gate, step, checkres.WantAtMost(lim),
			fmt.Sprintf("終わり → 頭の段差 %.3f（まわり 20ms の隣り合う差の最大 %.3f）", step, local))
		f.Sub, f.Ms = "step", at
		out = append(out, f)
	}
	before, after := dBFS(rmsOf(x[n-w:])), dBFS(rmsOf(x[ls:ls+w]))
	if d := math.Abs(clampDB(before) - clampDB(after)); math.Max(before, after) > -50 && d > rules.SeamLevelDB {
		f := newFinding("seam", checklevel.Gate, d, checkres.WantAtMost(rules.SeamLevelDB),
			fmt.Sprintf("継ぎ目の前後 20ms の音量 %.1f → %.1f dBFS", clampDB(before), clampDB(after)))
		f.Sub, f.Ms = "level", at
		out = append(out, f)
	}
	return out
}

func clampDB(d float64) float64 { return math.Max(-90, d) }

func mean(x []float64) float64 {
	s := 0.0
	for _, v := range x {
		s += v
	}
	return s / float64(max(1, len(x)))
}

// barsProblem は輪の長さが整数小節でない時の文と、整数小節からのずれ（サンプル。合えば ""）。
func barsProblem(res *rendered, rate int, rules *sndRules) (string, float64) {
	if res.loopStart < 0 || res.tempo == nil {
		return "", 0
	}
	loopLen := res.frames() - res.loopStart
	perBar := float64(rate) * 60 * float64(res.tempo.BeatsPerBar) / res.tempo.BPM
	bars := math.Round(float64(loopLen) / perBar)
	off := float64(loopLen) - bars*perBar
	if bars >= 1 && math.Abs(off) <= float64(rules.BarTolerance) {
		return "", 0
	}
	beats := float64(loopLen) / (perBar / float64(res.tempo.BeatsPerBar))
	msg := fmt.Sprintf("輪の長さ %d サンプル = %.3f 拍（%v BPM・%d 拍子で整数小節から %+.0f サンプル）", loopLen, beats, res.tempo.BPM, res.tempo.BeatsPerBar, off)
	if bars < 1 {
		off = float64(loopLen) - perBar // 1 小節に満たない輪は 1 小節からのずれ
	}
	return msg, math.Abs(off)
}

// seenProbe はテストが組み立てた結果を全部見る口（TestMain が code・got・want を確かめる。ふだんは nil）。
var seenProbe func(finding)

// runChecks は書き出した音を検査する。gate は原因の op を引く（その分だけ鳴らし直す）。
func runChecks(r *renderer, res *rendered, st *sndStyle, rules *sndRules) []finding {
	out := runChecksRaw(r, res, st, rules)
	if seenProbe != nil {
		for _, f := range out {
			seenProbe(f)
		}
	}
	return out
}

func runChecksRaw(r *renderer, res *rendered, st *sndStyle, rules *sndRules) []finding {
	var out []finding
	rate := r.s.Rate
	msOf := func(i int) *float64 { return checkres.Ptr(math.Round(float64(i)*1000/float64(rate)*10) / 10) }
	gate := func(f finding, bad func(*rendered) bool) {
		f.Cause = r.cause(bad)
		out = append(out, f)
	}
	for _, p := range st.checkStyle(r.s, res) {
		f := newFinding("style", checklevel.Gate, p.got, checkres.WantAtMost(p.limit), p.msg)
		f.Sub, f.Cause, f.Tries = p.sub, p.where, p.tries
		out = append(out, f)
	}
	for _, d := range res.drones {
		if rules.DroneSeconds > 0 && d.seconds >= rules.DroneSeconds {
			f := newFinding("drone", checklevel.Gate, d.seconds, checkres.WantAtMost(rules.DroneSeconds), d.String())
			f.Cause, f.Channel = d.where, d.channel
			out = append(out, f)
		}
	}
	for _, b := range res.breaks {
		out = append(out, newFinding("breaks", checklevel.Advice, 1, checkres.WantAtMost(0), fmt.Sprintf("機種の外の手 %s を使った（%s が許す）", b, st.label())))
	}
	if n, first, peak := overCount(res.out); n+res.clamped > 0 {
		msg := fmt.Sprintf("±1 を超えたサンプルが %d（最大 %+.1f dBFS・最初は %.3f 秒）", n, dBFS(peak), float64(first)/float64(rate))
		if res.clamped > 0 {
			msg = fmt.Sprintf("song の仕上げで ±1 に切ったサンプルが %d", res.clamped)
			if n > 0 {
				msg += fmt.Sprintf("・その後も ±1 を超えたサンプルが %d", n)
			}
		}
		f := newFinding("clip", checklevel.Gate, float64(n+res.clamped), checkres.WantAtMost(0), msg)
		if first >= 0 {
			f.Ms = msOf(first)
		}
		f.Tries = normalizeTries(r.s, rules)
		gate(f, func(x *rendered) bool { n, _, _ := overCount(x.out); return n+x.clamped > 0 })
	}
	for _, f := range seamProblems(res, rate, rules) {
		gate(f, func(x *rendered) bool { return len(seamProblems(x, rate, rules)) > 0 })
	}
	if p, off := barsProblem(res, rate, rules); p != "" {
		gate(newFinding("bars", checklevel.Gate, off, checkres.WantAtMost(float64(rules.BarTolerance)), p),
			func(x *rendered) bool { p, _ := barsProblem(x, rate, rules); return p != "" })
	}
	if lu, ok := rules.Loudness[r.s.Kind]; ok {
		want := checkres.WantRange(lu.Target-lu.Tolerance, lu.Target+lu.Tolerance)
		if l := LUFS(rate, loopBody(res.out, res.loopStart)); math.IsInf(l, -1) {
			out = append(out, newFinding("loudness", checklevel.Lint, silentLUFS, want, "無音"))
		} else if math.Abs(l-lu.Target) > lu.Tolerance {
			f := newFinding("loudness", checklevel.Lint, l, want, fmt.Sprintf("%.1f LUFS（%s の目安 %.0f ± %.0f）", l, r.s.Kind, lu.Target, lu.Tolerance))
			if !hasPost(r.s, "normalize") {
				f.Tries = []checkres.Try{{Op: "post", Arg: "normalize.lufs", Try: lu.Target}}
			}
			out = append(out, f)
		}
	}
	if p := dBFS(peakOf(res.out...)); p > rules.PeakDBFS && p <= 0 {
		f := newFinding("peak", checklevel.Lint, p, checkres.WantAtMost(rules.PeakDBFS), fmt.Sprintf("ピーク %.2f dBFS（%.1f まで）", p, rules.PeakDBFS))
		f.Tries = normalizeTries(r.s, rules)
		out = append(out, f)
	}
	if tp := dBFS(truePeakOf(res.out...)); tp > rules.TruePeakDBTP && dBFS(peakOf(res.out...)) <= 0 {
		f := newFinding("truepeak", checklevel.Lint, tp, checkres.WantAtMost(rules.TruePeakDBTP), fmt.Sprintf("true peak %.2f dBTP（%.1f まで。post に normalize）", tp, rules.TruePeakDBTP))
		f.Tries = normalizeTries(r.s, rules)
		out = append(out, f)
	}
	if res.loopStart < 0 && res.frames() > 0 {
		onset := res.frames()
		for _, x := range res.out {
			for i, v := range x {
				if math.Abs(v) > 0.001 {
					onset = min(onset, i)
					break
				}
			}
		}
		if ms := float64(onset) * 1000 / float64(rate); ms > rules.HeadSilenceMs {
			f := newFinding("head", checklevel.Lint, ms, checkres.WantAtMost(rules.HeadSilenceMs), fmt.Sprintf("鳴り出しが %.1f ms 遅れる（%.0f ms まで。演出の拍に合わない）", ms, rules.HeadSilenceMs))
			f.Ms, f.ToMs = checkres.Ptr(0), msOf(onset)
			out = append(out, f)
		}
		last := 0.0
		for _, x := range res.out {
			last = math.Max(last, math.Abs(x[len(x)-1]))
		}
		if last > rules.TailClick {
			f := newFinding("tail", checklevel.Lint, last, checkres.WantAtMost(rules.TailClick), fmt.Sprintf("終わりのサンプルが %.3f（0 へ戻らずプツと鳴る。%.2f まで）", last, rules.TailClick))
			f.Ms = msOf(res.frames() - 1)
			out = append(out, f)
		}
	}
	for k, x := range res.out {
		if d := mean(x); math.Abs(d) > rules.DC {
			f := newFinding("dc", checklevel.Lint, math.Abs(d), checkres.WantAtMost(rules.DC), fmt.Sprintf("平均 %.4f（直流が %.2f を超える）", d, rules.DC))
			if len(res.out) == 2 {
				f.Channel = []string{"左", "右"}[k]
			}
			out = append(out, f)
			break
		}
	}
	nyq := float64(rate) / 2
	for _, vo := range r.s.Voices {
		for _, c := range vo.Ops {
			if hz := math.Max(c.Args.Num("hz"), c.Args.Num("to_hz")); c.Name == "pulse" && 3*hz > nyq {
				f := newFinding("alias", checklevel.Advice, 3*hz, checkres.WantAtMost(nyq),
					fmt.Sprintf("パルスの 3 倍音がナイキスト周波数（%d Hz）を超えて折り返す（低くするか post に lowpass）", rate/2))
				f.Cause = c.Where
				arg := "hz"
				if c.Args.Num("to_hz") > c.Args.Num("hz") {
					arg = "to_hz"
				}
				try := math.Floor(nyq / 3)
				f.Tries = []checkres.Try{{Op: c.Where, Arg: arg, Now: hz, Try: try, Expect: checkres.Ptr(3 * try)}}
				out = append(out, f)
			}
		}
	}
	return out
}

// silentLUFS は無音の時の got（-inf の代わり）。
const silentLUFS = -99

func hasPost(s *spec, name string) bool {
	for _, c := range s.Post {
		if c.Name == name {
			return true
		}
	}
	return false
}

// normalizeTries は「post に normalize」の候補。normalize は true peak を peak_dbtp まで下げるので、その値を見込みにする。
// 書いてある normalize の peak_dbtp が上限より高ければ、それを上限へ下げる候補。
func normalizeTries(s *spec, rules *sndRules) []checkres.Try {
	for _, c := range s.Post {
		if c.Name == "normalize" {
			if c.Args.Has("peak_dbtp") && c.Args.Num("peak_dbtp") > rules.TruePeakDBTP {
				return []checkres.Try{{Op: c.Where, Arg: "peak_dbtp", Now: c.Args.Num("peak_dbtp"), Try: rules.TruePeakDBTP, Expect: checkres.Ptr(rules.TruePeakDBTP)}}
			}
			return nil // normalize の後に音量を上げる op がある（post の順を見る）
		}
	}
	return []checkres.Try{{Op: "post", Arg: "normalize.peak_dbtp", Try: rules.TruePeakDBTP, Expect: checkres.Ptr(rules.TruePeakDBTP)}}
}

func gateFailed(fs []finding) bool {
	for _, f := range fs {
		if f.Level == checklevel.Gate {
			return true
		}
	}
	return false
}
