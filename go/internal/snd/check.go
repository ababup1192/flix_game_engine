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
)

// finding は検査の結果 1 つ。
type finding struct {
	Check string           `json:"check"`
	Level checklevel.Level `json:"level"`
	Msg   string           `json:"msg"`
	Cause string           `json:"cause,omitempty"`
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
func seamProblems(res *rendered, rate int, rules *sndRules) []string {
	for k, x := range res.out {
		if ps := seamOf(x, res.loopStart, rate, rules); len(ps) > 0 {
			if len(res.out) == 2 {
				for i := range ps {
					ps[i] = []string{"左", "右"}[k] + ": " + ps[i]
				}
			}
			return ps
		}
	}
	return nil
}

func seamOf(x []float64, ls, rate int, rules *sndRules) []string {
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
	var out []string
	if step > float64(rules.SeamStepRatio*local)+0.02 {
		out = append(out, fmt.Sprintf("終わり → 頭の段差 %.3f（まわり 20ms の隣り合う差の最大 %.3f）", step, local))
	}
	before, after := dBFS(rmsOf(x[n-w:])), dBFS(rmsOf(x[ls:ls+w]))
	if math.Max(before, after) > -50 && math.Abs(clampDB(before)-clampDB(after)) > rules.SeamLevelDB {
		out = append(out, fmt.Sprintf("継ぎ目の前後 20ms の音量 %.1f → %.1f dBFS", clampDB(before), clampDB(after)))
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

// barsProblem は輪の長さが整数小節でない時の文（合えば ""）。
func barsProblem(res *rendered, rate int, rules *sndRules) string {
	if res.loopStart < 0 || res.tempo == nil {
		return ""
	}
	loopLen := res.frames() - res.loopStart
	perBar := float64(rate) * 60 * float64(res.tempo.BeatsPerBar) / res.tempo.BPM
	bars := math.Round(float64(loopLen) / perBar)
	off := float64(loopLen) - bars*perBar
	if bars >= 1 && math.Abs(off) <= float64(rules.BarTolerance) {
		return ""
	}
	beats := float64(loopLen) / (perBar / float64(res.tempo.BeatsPerBar))
	return fmt.Sprintf("輪の長さ %d サンプル = %.3f 拍（%v BPM・%d 拍子で整数小節から %+.0f サンプル）", loopLen, beats, res.tempo.BPM, res.tempo.BeatsPerBar, off)
}

// runChecks は書き出した音を検査する。gate は原因の op を引く（その分だけ鳴らし直す）。
func runChecks(r *renderer, res *rendered, st *sndStyle, rules *sndRules) []finding {
	var out []finding
	rate := r.s.Rate
	gate := func(check, msg string, bad func(*rendered) bool) {
		out = append(out, finding{Check: check, Level: checklevel.Gate, Msg: msg, Cause: r.cause(bad)})
	}
	for _, p := range st.checkStyle(r.s, res) {
		out = append(out, finding{Check: "style", Level: checklevel.Gate, Msg: p[0], Cause: p[1]})
	}
	for _, d := range res.drones {
		if rules.DroneSeconds > 0 && d.seconds >= rules.DroneSeconds {
			out = append(out, finding{Check: "drone", Level: checklevel.Gate, Msg: d.String(), Cause: d.where})
		}
	}
	for _, b := range res.breaks {
		out = append(out, finding{Check: "breaks", Level: checklevel.Advice, Msg: fmt.Sprintf("機種の外の手 %s を使った（%s が許す）", b, st.label())})
	}
	if n, first, peak := overCount(res.out); n+res.clamped > 0 {
		msg := fmt.Sprintf("±1 を超えたサンプルが %d（最大 %+.1f dBFS・最初は %.3f 秒）", n, dBFS(peak), float64(first)/float64(rate))
		if res.clamped > 0 {
			msg = fmt.Sprintf("song の仕上げで ±1 に切ったサンプルが %d", res.clamped)
			if n > 0 {
				msg += fmt.Sprintf("・その後も ±1 を超えたサンプルが %d", n)
			}
		}
		gate("clip", msg, func(x *rendered) bool { n, _, _ := overCount(x.out); return n+x.clamped > 0 })
	}
	if ps := seamProblems(res, rate, rules); len(ps) > 0 {
		for _, p := range ps {
			gate("seam", p, func(x *rendered) bool { return len(seamProblems(x, rate, rules)) > 0 })
		}
	}
	if p := barsProblem(res, rate, rules); p != "" {
		gate("bars", p, func(x *rendered) bool { return barsProblem(x, rate, rules) != "" })
	}
	if lu, ok := rules.Loudness[r.s.Kind]; ok {
		if l := LUFS(rate, loopBody(res.out, res.loopStart)); math.IsInf(l, -1) {
			out = append(out, finding{Check: "loudness", Level: checklevel.Lint, Msg: "無音"})
		} else if math.Abs(l-lu.Target) > lu.Tolerance {
			out = append(out, finding{Check: "loudness", Level: checklevel.Lint,
				Msg: fmt.Sprintf("%.1f LUFS（%s の目安 %.0f ± %.0f）", l, r.s.Kind, lu.Target, lu.Tolerance)})
		}
	}
	if p := dBFS(peakOf(res.out...)); p > rules.PeakDBFS && p <= 0 {
		out = append(out, finding{Check: "peak", Level: checklevel.Lint, Msg: fmt.Sprintf("ピーク %.2f dBFS（%.1f まで）", p, rules.PeakDBFS)})
	}
	if tp := dBFS(truePeakOf(res.out...)); tp > rules.TruePeakDBTP && dBFS(peakOf(res.out...)) <= 0 {
		out = append(out, finding{Check: "truepeak", Level: checklevel.Lint, Msg: fmt.Sprintf("true peak %.2f dBTP（%.1f まで。post に normalize）", tp, rules.TruePeakDBTP)})
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
			out = append(out, finding{Check: "head", Level: checklevel.Lint, Msg: fmt.Sprintf("鳴り出しが %.1f ms 遅れる（%.0f ms まで。演出の拍に合わない）", ms, rules.HeadSilenceMs)})
		}
		last := 0.0
		for _, x := range res.out {
			last = math.Max(last, math.Abs(x[len(x)-1]))
		}
		if last > rules.TailClick {
			out = append(out, finding{Check: "tail", Level: checklevel.Lint, Msg: fmt.Sprintf("終わりのサンプルが %.3f（0 へ戻らずプツと鳴る。%.2f まで）", last, rules.TailClick)})
		}
	}
	for _, x := range res.out {
		if d := mean(x); math.Abs(d) > rules.DC {
			out = append(out, finding{Check: "dc", Level: checklevel.Lint, Msg: fmt.Sprintf("平均 %.4f（直流が %.2f を超える）", d, rules.DC)})
			break
		}
	}
	for _, vo := range r.s.Voices {
		for _, c := range vo.Ops {
			if c.Name == "pulse" && 3*math.Max(c.Args.Num("hz"), c.Args.Num("to_hz")) > float64(rate)/2 {
				out = append(out, finding{Check: "alias", Level: checklevel.Advice, Cause: c.Where,
					Msg: fmt.Sprintf("パルスの 3 倍音がナイキスト周波数（%d Hz）を超えて折り返す（低くするか post に lowpass）", rate/2)})
			}
		}
	}
	return out
}

func gateFailed(fs []finding) bool {
	for _, f := range fs {
		if f.Level == checklevel.Gate {
			return true
		}
	}
	return false
}
