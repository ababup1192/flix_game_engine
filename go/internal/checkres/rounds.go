package checkres

// 周回の比べ（前の周と code ごとの got の差）と、止め時の判定（stop）。
// rounds snap の周（debug/history/<名前>/rN.report.json）に Round を積み、次の周で読む。

import (
	"fmt"
	"sort"
	"strings"
)

// Round は 1 周ぶんの検査の記録（rN.report.json の check）。
type Round struct {
	Summary Summary  `json:"summary"`
	Results []Result `json:"results"`
	Tokens  *Tokens  `json:"tokens,omitempty"` // 呼ぶ側が渡した時だけ
	Delta   []Delta  `json:"delta,omitempty"`  // 前の周との差（rounds snap が入れる）
	Stop    *Stop    `json:"stop,omitempty"`   // 止め時の判定（rounds snap が入れる）
}

// Brief は --json の標準出力に出す短い形（まとめだけ。1 件ずつの全部は report.json の results）。
func (r *Round) Brief() map[string]any {
	if r == nil {
		return nil
	}
	out := map[string]any{"summary": r.Summary, "results": len(r.Results)}
	if r.Delta != nil {
		out["delta"] = r.Delta
	}
	if r.Stop != nil {
		out["stop"] = r.Stop
	}
	return out
}

// Tokens は呼ぶ側（AI）が申告した使ったトークンと予算（--tokens 使った/予算）。
type Tokens struct {
	Used   int `json:"used"`
	Budget int `json:"budget"`
}

// Delta は code 1 つの前の周との差。Change は worse・new・better・gone・same。
type Delta struct {
	Code      string  `json:"code"`
	Change    string  `json:"change"`
	PrevGot   float64 `json:"prevGot,omitempty"`
	Got       float64 `json:"got,omitempty"`
	PrevCount int     `json:"prevCount"`
	Count     int     `json:"count"`
	Want      Want    `json:"want"`
	Unit      string  `json:"unit"`
}

type codeAgg struct {
	worst Result
	n     int
}

func aggregate(rs []Result) map[string]codeAgg {
	m := map[string]codeAgg{}
	for _, r := range rs {
		if r.Status == Pass {
			continue
		}
		a, ok := m[r.Code]
		if !ok || Worse(r, a.worst) {
			a.worst = r
		}
		a.n++
		m[r.Code] = a
	}
	return m
}

var changeOrder = map[string]int{"worse": 0, "new": 1, "better": 2, "gone": 3, "same": 4}

// Compare は前の周と今の周を code ごとに比べる（悪くなった物を先頭に。same は省く）。
// 1 つの code の比べは一番悪い 1 件の割合と、外れの件数で決める。
func Compare(prev, cur []Result) []Delta {
	pa, ca := aggregate(prev), aggregate(cur)
	var out []Delta
	for code, c := range ca {
		d := Delta{Code: code, Got: c.worst.Got, Count: c.n, Want: c.worst.Want, Unit: c.worst.Unit}
		p, ok := pa[code]
		switch {
		case !ok:
			d.Change = "new"
		default:
			d.PrevGot, d.PrevCount = p.worst.Got, p.n
			switch {
			case c.worst.Ratio < p.worst.Ratio || c.worst.Ratio == p.worst.Ratio && c.n > p.n:
				d.Change = "worse"
			case c.worst.Ratio > p.worst.Ratio || c.n < p.n:
				d.Change = "better"
			default:
				d.Change = "same"
			}
		}
		if d.Change != "same" {
			out = append(out, d)
		}
	}
	for code, p := range pa {
		if _, ok := ca[code]; !ok {
			out = append(out, Delta{Code: code, Change: "gone", PrevGot: p.worst.Got, PrevCount: p.n, Want: p.worst.Want, Unit: p.worst.Unit})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if changeOrder[out[i].Change] != changeOrder[out[j].Change] {
			return changeOrder[out[i].Change] < changeOrder[out[j].Change]
		}
		return out[i].Code < out[j].Code
	})
	return out
}

// Stop は止め時の判定。Stop が true なら次の周へ進まず報告へ。Rule は当たった決まり（clear・budget・no-gain・same-next・continue）。
type Stop struct {
	Stop   bool   `json:"stop"`
	Rule   string `json:"rule"`
	Reason string `json:"reason"`
}

// JudgeStop は前の周の並び（古い順）と今の周から止め時を決める。上限の周数（rounds.json）とは別に、
// 「検査を全部満たした・トークンの予算・score が N 周続けて上がらない・next が同じ物を繰り返す」で止める。
func JudgeStop(history []Round, cur Round, rules *Rules) Stop {
	st := rules.Stop
	if len(cur.Summary.Next) == 0 {
		return Stop{true, "clear", "検査を全部満たした（ここから先の質は検査では測れない。絵を push して目で見てもらう）"}
	}
	if t := cur.Tokens; t != nil && t.Budget > 0 && float64(t.Used) >= st.BudgetShare*float64(t.Budget) {
		return Stop{true, "budget", fmt.Sprintf("トークン %d / 予算 %d（%.0f%% を超えた）", t.Used, t.Budget, st.BudgetShare*100)}
	}
	all := append(append([]Round{}, history...), cur)
	if n := st.NoGainRounds; len(all) > n {
		base := all[len(all)-1-n].Summary.Score
		gain := false
		for _, r := range all[len(all)-n:] {
			if r.Summary.Score > base {
				gain = true
			}
		}
		if !gain {
			return Stop{true, "no-gain", fmt.Sprintf("score が %d 周続けて上がらない（%d 周前 %d → 今 %d）", n, n, base, cur.Summary.Score)}
		}
	}
	if n := st.SameNextRounds; len(all) >= n {
		key := cur.Summary.Next[0].Key()
		same := true
		for _, r := range all[len(all)-n:] {
			if len(r.Summary.Next) == 0 || r.Summary.Next[0].Key() != key {
				same = false
			}
		}
		if same {
			return Stop{true, "same-next", fmt.Sprintf("next が %d 周続けて同じ（%s）。手を変えるか、基準を見回り役に聞く", n, cur.Summary.Next[0].Code)}
		}
	}
	reason := "初めの周"
	if len(history) > 0 {
		reason = fmt.Sprintf("score %d → %d", history[len(history)-1].Summary.Score, cur.Summary.Score)
	}
	return Stop{false, "continue", reason}
}

// DeltaLines は人向けの差の行（悪くなった物から max 行）。
func DeltaLines(ds []Delta, max int) []string {
	mark := map[string]string{"worse": "▼ 悪くなった", "new": "＋ 新しく出た", "better": "▲ 良くなった", "gone": "－ 消えた"}
	var out []string
	for i, d := range ds {
		if i == max {
			out = append(out, fmt.Sprintf("ほか %d 件", len(ds)-max))
			break
		}
		s := fmt.Sprintf("%s %s", mark[d.Change], d.Code)
		switch d.Change {
		case "worse", "better":
			s += fmt.Sprintf(" got %s → %s（%d 件 → %d 件・want %s %s）", num(d.PrevGot), num(d.Got), d.PrevCount, d.Count, d.Want, d.Unit)
		case "new":
			s += fmt.Sprintf(" got %s（%d 件・want %s %s）", num(d.Got), d.Count, d.Want, d.Unit)
		case "gone":
			s += fmt.Sprintf("（前は got %s・%d 件）", num(d.PrevGot), d.PrevCount)
		}
		out = append(out, strings.TrimSpace(s))
	}
	return out
}
