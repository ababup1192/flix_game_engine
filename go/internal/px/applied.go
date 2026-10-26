package px

// まとめの applied（絵ごとの当てた検査の組）と exempt（外した物を単位ごとに数える）。checkset-design §4・§7。
// 組が前の build と同じ絵は id だけ・外した物の内訳は前より増えた時か --explain だけ出す（まとめを毎周短く）。
// kind・look の欄は宣言の仕組み（段 2）で足す。

import (
	"math"
	"sort"

	"github.com/ababup1192/flixlint/go/checklevel"
	"github.com/ababup1192/flixlint/go/checkres"
)

type appliedSet struct {
	kinds    map[string]resolvedKind
	look     string
	fidelity map[string]fidelityOf
	style    string
	noCheck  bool
	checks   map[string]map[string]bool
	skipped  map[string][]checklevel.Skip
	mats     map[string]map[string]bool
	order    []string
	emissive map[string]bool // 部品 id（sprite/part）
	poly     map[string]bool
	rules    map[string]bool // lint-sprite で外した規則
	drawn    int             // 描いた画素の数（全コマ。exempt の割合の分母）
}

func newAppliedSet(style string, noCheck bool) *appliedSet {
	return &appliedSet{kinds: map[string]resolvedKind{}, fidelity: map[string]fidelityOf{}, style: style, noCheck: noCheck, checks: map[string]map[string]bool{}, skipped: map[string][]checklevel.Skip{},
		mats: map[string]map[string]bool{}, emissive: map[string]bool{}, poly: map[string]bool{}, rules: map[string]bool{}}
}

func (a *appliedSet) touch(sp string) {
	if _, ok := a.checks[sp]; !ok {
		a.checks[sp] = map[string]bool{}
		a.mats[sp] = map[string]bool{}
		a.order = append(a.order, sp)
	}
}

func (a *appliedSet) check(sp, name string) { a.touch(sp); a.checks[sp][name] = true }

func (a *appliedSet) kind(sp string, rk resolvedKind) { a.touch(sp); a.kinds[sp] = rk }

func (a *appliedSet) skip(sp, code, why, by string) {
	a.touch(sp)
	for _, s := range a.skipped[sp] {
		if s.Code == code {
			return
		}
	}
	a.skipped[sp] = append(a.skipped[sp], checklevel.Skip{Code: code, Why: why, By: by})
}

func (a *appliedSet) rule(sp, rule string) { a.touch(sp); a.rules[sp+":"+rule] = true }

func (a *appliedSet) part(sp string, p *part, c *checkCtx) {
	a.touch(sp)
	if p.Material != "" {
		a.mats[sp][p.Material] = true
	}
	if p.Emissive {
		a.emissive[sp+"/"+p.ID] = true
	}
	if c.Poly[p.ID] {
		a.poly[sp+"/"+p.ID] = true
	}
}

func keysOfSet(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// summary は applied と exempt。prev は前の build のまとめ（id と外した画素の数を比べる）。
func (a *appliedSet) summary(counts map[[2]string]int, prev *checkres.Summary, explain bool) (map[string]checklevel.Applied, *checkres.Exempt) {
	applied := map[string]checklevel.Applied{}
	for _, sp := range a.order {
		full := checklevel.AppliedFull{Style: a.style, Look: a.look, Materials: keysOfSet(a.mats[sp]), Checks: keysOfSet(a.checks[sp]), Skipped: a.skipped[sp]}
		if rk, ok := a.kinds[sp]; ok {
			full.Kind, full.KindBy = string(rk.Kind), rk.By
		}
		if f, ok := a.fidelity[sp]; ok && f.Known {
			v := f.Value
			full.Fidelity, full.FidelityBy = &v, f.By
		} else if ok {
			full.FidelityBy = f.By
		}
		if a.noCheck {
			full.Skipped = append(full.Skipped, checklevel.Skip{Code: "lint・advice の全部", Why: "--no-check（周の外の下見）", By: "--no-check"})
		}
		prevID := ""
		if prev != nil {
			prevID = prev.Applied[sp].ID
		}
		applied[sp] = checkres.AppliedOf(full, prevID, explain)
	}
	units := &checkres.ExemptUnits{Pixels: map[string]int{}, Parts: map[string][]string{}, Rules: map[string][]string{}, Demoted: map[string]int{}}
	px := 0
	for k, n := range counts {
		if k[0] == "demoted" {
			units.Demoted[k[1]] += n
			continue
		}
		units.Pixels[k[1]] += n
		px += n
	}
	if len(a.emissive) > 0 {
		units.Parts["emissive"] = keysOfSet(a.emissive)
	}
	if len(a.poly) > 0 {
		units.Parts["poly"] = keysOfSet(a.poly)
	}
	if len(a.rules) > 0 {
		units.Rules["lint-sprite"] = keysOfSet(a.rules)
	}
	ex := &checkres.Exempt{Px: px}
	if a.drawn > 0 {
		ex.Pct = math.Round(float64(px)*1000/float64(a.drawn)) / 10
	}
	increased := prev == nil || prev.Exempt == nil
	if prev != nil && prev.Exempt != nil {
		d := px - prev.Exempt.Px
		ex.D = &d
		increased = d > 0
	}
	if increased || explain {
		ex.Units = units
	}
	return applied, ex
}
