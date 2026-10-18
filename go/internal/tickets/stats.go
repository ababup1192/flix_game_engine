package tickets

// stats: ledger を作った日で期間に分け、件数・regressedBy の埋まった割合・前の直しが生んだ割合・
// 多く生んだ直しを数える。全体の割合と多く生んだ直しは checkres の形（code/got/want/ratio/status/fix）。

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

// Period は 1 つの期間の数。
type Period struct {
	From      string  `json:"from"` // 期間の頭の日（YYYY-MM-DD）
	Closed    int     `json:"closed"`
	Filled    int     `json:"filled"`    // regressedBy が unknown でない
	Regressed int     `json:"regressed"` // 前の直しが生んだ
	FilledR   float64 `json:"filledRatio"`
	RegressR  float64 `json:"regressedRatio"` // Regressed / Filled
}

// Cause は多く生んだ直し 1 件。
type Cause struct {
	Ref     string   `json:"ref"`
	Kind    Kind     `json:"kind"`
	Subject string   `json:"subject,omitempty"`
	Tickets []string `json:"tickets"`
}

// Report は stats の --json の形。
type Report struct {
	Ledger  string            `json:"ledger"`
	Since   string            `json:"since,omitempty"`
	Until   string            `json:"until,omitempty"`
	By      string            `json:"by"`
	Open    int               `json:"open"` // まだ閉じていないチケット（このマシンの debug/ にある物）
	Total   Period            `json:"total"`
	Periods []Period          `json:"periods"`
	Causes  []Cause           `json:"causes"`
	Results []checkres.Result `json:"results"`
	Next    []checkres.Result `json:"next"`
}

// periodStart は t を含む期間の頭（week は月曜から）。
func periodStart(t time.Time, by string) time.Time {
	d := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, t.Location())
	switch by {
	case "day":
		return d
	case "month":
		return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, t.Location())
	default:
		return d.AddDate(0, 0, -((int(d.Weekday()) + 6) % 7))
	}
}

func ratio(a, b int) float64 {
	if b == 0 {
		return 0
	}
	return float64(a) / float64(b)
}

func (p *Period) add(rec Record) {
	p.Closed++
	if rec.RegressedBy.Kind != KindUnknown && rec.RegressedBy.Kind != "" {
		p.Filled++
	}
	if rec.IsRegression() {
		p.Regressed++
	}
	p.FilledR = round3(ratio(p.Filled, p.Closed))
	p.RegressR = round3(ratio(p.Regressed, p.Filled))
}

func round3(v float64) float64 { return float64(int(v*1000+0.5)) / 1000 }

// BuildReport は ledger から数を組む。since・until は作った日（YYYY-MM-DD・until はその日を含む）。
func (r *Rules) BuildReport(recs []Record, since, until, by string, open int) (Report, error) {
	rep := Report{Ledger: r.Ledger, Since: since, Until: until, By: by, Open: open,
		Periods: []Period{}, Causes: []Cause{}, Results: []checkres.Result{}, Next: []checkres.Result{}}
	byFrom := map[string]*Period{}
	causes := map[string]*Cause{}
	for _, rec := range recs {
		at, err := time.Parse(time.RFC3339, rec.Created)
		if err != nil {
			return rep, fmt.Errorf("ledger の %s の created %q が RFC 3339 ではありません", rec.Ticket, rec.Created)
		}
		at = at.In(time.Local)
		day := at.Format("2006-01-02")
		if (since != "" && day < since) || (until != "" && day > until) {
			continue
		}
		from := periodStart(at, by).Format("2006-01-02")
		if byFrom[from] == nil {
			byFrom[from] = &Period{From: from}
		}
		byFrom[from].add(rec)
		rep.Total.add(rec)
		if rec.IsRegression() {
			c := causes[rec.RegressedBy.Ref]
			if c == nil {
				c = &Cause{Ref: rec.RegressedBy.Ref, Kind: rec.RegressedBy.Kind, Subject: rec.RegressedBy.Subject}
				causes[rec.RegressedBy.Ref] = c
			}
			c.Tickets = append(c.Tickets, rec.Ticket)
		}
	}
	for _, p := range byFrom {
		rep.Periods = append(rep.Periods, *p)
	}
	sort.Slice(rep.Periods, func(i, j int) bool { return rep.Periods[i].From < rep.Periods[j].From })
	for _, c := range causes {
		rep.Causes = append(rep.Causes, *c)
	}
	sort.Slice(rep.Causes, func(i, j int) bool {
		if len(rep.Causes[i].Tickets) != len(rep.Causes[j].Tickets) {
			return len(rep.Causes[i].Tickets) > len(rep.Causes[j].Tickets)
		}
		return rep.Causes[i].Ref < rep.Causes[j].Ref
	})
	if rep.Total.Closed == 0 {
		return rep, nil
	}
	filled := checkres.New(CodeFilled, 0, checkres.Measure{Got: rep.Total.FilledR, Want: checkres.WantAtLeast(r.FilledMin)}, nil,
		fmt.Sprintf("閉じた %d 件のうち regressedBy が埋まったのは %d 件", rep.Total.Closed, rep.Total.Filled))
	filled.Fix = checkres.Fix{Hint: r.Hints[CodeFilled]}
	rep.Results = append(rep.Results, filled)
	if rep.Total.Filled > 0 {
		reg := checkres.New(CodeRegressed, 0, checkres.Measure{Got: rep.Total.RegressR, Want: checkres.WantAtMost(r.RegressedMax)}, nil,
			fmt.Sprintf("埋まった %d 件のうち前の直しが生んだのは %d 件", rep.Total.Filled, rep.Total.Regressed))
		reg.Fix = checkres.Fix{Hint: r.Hints[CodeRegressed]}
		rep.Results = append(rep.Results, reg)
	}
	for _, c := range rep.Causes {
		if float64(len(c.Tickets)) <= r.CauseMax {
			continue
		}
		res := checkres.New(CodeCause, 0, checkres.Measure{Got: float64(len(c.Tickets)), Want: checkres.WantAtMost(r.CauseMax)}, nil,
			fmt.Sprintf("%s %s が %d 件を生んだ", short(c.Ref), clip(c.Subject, 48), len(c.Tickets)))
		res.Cause = checkres.Cause{Op: c.Ref}
		res.Fix = checkres.Fix{Hint: r.Hints[CodeCause]}
		rep.Results = append(rep.Results, res)
	}
	var bad []checkres.Result
	for _, res := range rep.Results {
		if res.Status != checkres.Pass {
			bad = append(bad, res)
		}
	}
	sort.SliceStable(bad, func(i, j int) bool { return checkres.Worse(bad[i], bad[j]) })
	if len(bad) > 3 {
		bad = bad[:3]
	}
	rep.Next = append(rep.Next, bad...)
	return rep, nil
}

// PrintReport は人向けの表。
func PrintReport(b *strings.Builder, rep Report) {
	span := "全期間"
	if rep.Since != "" || rep.Until != "" {
		span = rep.Since + "〜" + rep.Until
	}
	fmt.Fprintf(b, "[tickets stats] %s・%s ごと（作った日）・ledger %s・閉じていない %d 件\n", span, rep.By, rep.Ledger, rep.Open)
	if rep.Total.Closed == 0 {
		fmt.Fprintln(b, "  閉じたチケットがまだありません（閉じる口: bin/fge tickets close）")
		return
	}
	fmt.Fprintln(b, "  期間の頭    閉じた  埋まった（割合）  前の直しが生んだ（埋まった中の割合）")
	row := func(name string, p Period) {
		fmt.Fprintf(b, "  %-10s  %4d    %4d（%3.0f%%）     %4d/%d（%3.0f%%）\n", name, p.Closed, p.Filled, p.FilledR*100, p.Regressed, p.Filled, p.RegressR*100)
	}
	for _, p := range rep.Periods {
		row(p.From, p)
	}
	row("total", rep.Total)
	if len(rep.Causes) > 0 {
		fmt.Fprintln(b, "  多く生んだ直し:")
		for i, c := range rep.Causes {
			if i >= 5 {
				break
			}
			fmt.Fprintf(b, "    %d 件 %s %s\n", len(c.Tickets), short(c.Ref), clip(c.Subject, 48))
		}
	}
	for _, res := range rep.Results {
		mark := "ok"
		if res.Status != checkres.Pass {
			mark = "!!"
		}
		fmt.Fprintf(b, "%s %s %s（ratio %g・%s）%s\n", mark, res.Code, res.Short(), res.Ratio, res.Status, res.Msg)
	}
	for i, res := range rep.Next {
		fmt.Fprintf(b, "next %d: %s → %s\n", i+1, res.Code, res.Fix.Hint)
	}
}
