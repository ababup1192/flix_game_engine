package checkres

// 1 回の検査のまとめ: score・level と status ごとの数・悪い順の上位・next（次の周でまず直す 1〜3 件）・
// applied（当てた検査の組）・exempt（外した数）・終了コード。形の決まりは docs/check-results.md と
// checkset-design §7（next の順・applied は変わらない周は id だけ・exempt は単位ごと）。

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
)

// Scope は結果の範囲（next の順に使う: 広い範囲から）。
const (
	ScopeSpec     = "spec"     // spec 全体（ランプの並び・宣言）
	ScopeSequence = "sequence" // コマ列（動き・ちらつき）
	ScopeFrame    = "frame"    // コマ全体
	ScopePart     = "part"     // 部品の範囲
	ScopeFile     = "file"     // 書き出した物全体（音・sprite.json）
)

var scopeOrder = map[string]int{ScopeSpec: 0, ScopeFile: 0, ScopeSequence: 1, ScopeFrame: 2, ScopePart: 3, "": 4}

// Counts は level と status ごとの数（level → status → 数）。
type Counts map[string]map[string]int

// TopItem は上位の 1 件の短い形（全文は results・next）。
type TopItem struct {
	Code   string           `json:"code"`
	Level  checklevel.Level `json:"level"`
	Status Status           `json:"status"`
	Got    float64          `json:"got"`
	Want   Want             `json:"want"`
	Unit   string           `json:"unit"`
	Gap    float64          `json:"gap"`
	Where  string           `json:"where,omitempty"` // sprite/frame (x,y) か ms
}

// NearWaiting は fail が残る間の near（件数と code の名前だけ。fail が 0 になると next に入る）。
type NearWaiting struct {
	Count int      `json:"count"`
	Codes []string `json:"codes"`
}

// ExemptUnits は外した物の内訳（単位ごと）。
type ExemptUnits struct {
	Pixels  map[string]int      `json:"pixels,omitempty"`  // op の Exempt で外した画素（op → 数）
	Parts   map[string][]string `json:"parts,omitempty"`   // 部品ごとに外した物（emissive・poly → 部品 id）
	Rules   map[string][]string `json:"rules,omitempty"`   // 規則ごとに外した物（lint-sprite → 規則名）
	Demoted map[string]int      `json:"demoted,omitempty"` // 重さを下げた件（code → 数。corner・banding など）
}

// Exempt は外した数のまとめ（画素の数・描いた画素に対する割合・前の周との差）。内訳は増えた時か --explain だけ。
type Exempt struct {
	Px    int          `json:"px"`
	Pct   float64      `json:"pct"`
	D     *int         `json:"d,omitempty"`
	Units *ExemptUnits `json:"units,omitempty"`
}

// Summary は 1 回の検査のまとめ。
type Summary struct {
	Round   bool                          `json:"round"` // false は --only・--no-check（周の比べに入れない）
	Score   int                           `json:"score"` // 0〜100（gate の外れがあれば上限 gateCap）
	Counts  Counts                        `json:"counts"`
	Top     []TopItem                     `json:"top"`            // 悪い順の上位（rules の top 件）
	Next    []Result                      `json:"next,omitempty"` // 次の周でまず直す 1〜3 件（外れが無ければ省く）
	Near    *NearWaiting                  `json:"nearWaiting,omitempty"`
	Applied map[string]checklevel.Applied `json:"applied,omitempty"` // 絵（sprite）ごとの当てた検査の組
	Exempt  *Exempt                       `json:"exempt,omitempty"`
	Exit    int                           `json:"exit"` // 0 合格・1 gate の外れ・2 lint の fail だけ
}

// Worse は a が b より悪いか（gate → lint → advice・fail → near・割合の小さい順・code の名前の順）。
func Worse(a, b Result) bool {
	if a.Level != b.Level {
		return a.Level < b.Level
	}
	if a.Status != b.Status {
		return a.Status > b.Status
	}
	if a.Ratio != b.Ratio {
		return a.Ratio < b.Ratio
	}
	return a.Code < b.Code
}

// Sorted は悪い順に並べた写し（pass は除く）。
func Sorted(rs []Result) []Result {
	var out []Result
	for _, r := range rs {
		if r.Status != Pass {
			out = append(out, r)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return Worse(out[i], out[j]) })
	return out
}

// ExitCode は終了コード: gate の外れ（near も）があれば 1・lint の fail があれば 2・ほかは 0（near と advice は 0）。
func ExitCode(rs []Result) int {
	code := 0
	for _, r := range rs {
		switch {
		case r.Level == checklevel.Gate && r.Status != Pass:
			return 1
		case r.Level == checklevel.Lint && r.Status == Fail:
			code = 2
		}
	}
	return code
}

// WorseExit は 2 つの終了コードの重い方（1 gate > 2 lint > 0）。いくつもの spec をまとめて流す時に使う。
func WorseExit(a, b int) int {
	switch {
	case a == 1 || b == 1:
		return 1
	case a == 2 || b == 2:
		return 2
	}
	return max(a, b)
}

// Score は 0〜100 の点。fail は level の重み・near はその nearFactor 倍を引き、同じ code の 2 件目からは repeatDecay 倍ずつ軽くする。
func Score(rs []Result, rules *Rules) int {
	s := rules.Score
	seen := map[string]int{}
	lost := 0.0
	gate := false
	for _, r := range Sorted(rs) {
		w := map[checklevel.Level]float64{checklevel.Gate: s.Gate, checklevel.Lint: s.Lint, checklevel.Advice: s.Advice}[r.Level]
		if r.Status == Near {
			w *= s.NearFactor
		}
		w *= math.Pow(s.RepeatDecay, float64(seen[r.Code]))
		seen[r.Code]++
		lost += w
		if r.Level == checklevel.Gate {
			gate = true
		}
	}
	score := math.Max(0, 100-lost)
	if gate {
		score = math.Min(score, s.GateCap)
	}
	return int(math.Round(score))
}

// nextGroup は next の組（checkset-design §7）: 0 宣言（decl.*）→ 1 gate → 2 fail → 3 near。
func nextGroup(r Result) int {
	switch {
	case strings.Contains(r.Code, ".decl."):
		return 0
	case r.Level == checklevel.Gate:
		return 1
	case r.Status == Fail:
		return 2
	}
	return 3
}

// fixKey は同じ直し方で直る件を 1 つにまとめる鍵（最初の候補の op と引数か、原因の op）。
func fixKey(r Result) string {
	if len(r.Fix.Try) > 0 {
		return r.Fix.Try[0].Op + "|" + r.Fix.Try[0].Arg
	}
	if r.Cause.Op != "" {
		return r.Code + "|" + r.Cause.Op
	}
	return r.Key()
}

// NextOf は次の周でまず直す 1〜3 件と、fail が残る間の near のまとめ。
// 順は 宣言 → gate → fail（spec 全体 → コマ列 → コマ全体 → 部品・lint → advice）→ near（gap の大きい順。単位が code ごとに
// 違うので 1 − ratio で比べる）。同じ直し方で直る物は 1 件に。prevKeys は前の周に出た件の鍵（同じ順位なら新しく出た物を先に）。
func NextOf(rs []Result, prevKeys map[string]bool) ([]Result, *NearWaiting) {
	var cand []Result
	fails := false
	for _, r := range rs {
		if r.Status == Pass {
			continue
		}
		cand = append(cand, r)
		if nextGroup(r) < 3 {
			fails = true
		}
	}
	sort.SliceStable(cand, func(i, j int) bool {
		a, b := cand[i], cand[j]
		if ga, gb := nextGroup(a), nextGroup(b); ga != gb {
			return ga < gb
		}
		if nextGroup(a) == 3 {
			return 1-a.Ratio > 1-b.Ratio
		}
		if sa, sb := scopeOrder[a.Scope], scopeOrder[b.Scope]; sa != sb {
			return sa < sb
		}
		if a.Level != b.Level {
			return a.Level < b.Level
		}
		if prevKeys != nil {
			if na, nb := !prevKeys[a.Key()], !prevKeys[b.Key()]; na != nb {
				return na
			}
		}
		return a.Ratio < b.Ratio
	})
	var next []Result
	var near *NearWaiting
	seen := map[string]bool{}
	nearCodes := map[string]bool{}
	for _, r := range cand {
		if fails && nextGroup(r) == 3 {
			if near == nil {
				near = &NearWaiting{}
			}
			near.Count++
			nearCodes[r.Code] = true
			continue
		}
		if len(next) == 3 || seen[fixKey(r)] {
			continue
		}
		seen[fixKey(r)] = true
		next = append(next, r)
	}
	if near != nil {
		for c := range nearCodes {
			near.Codes = append(near.Codes, c)
		}
		sort.Strings(near.Codes)
	}
	return next, near
}

// Summarize は結果の並びをまとめる。prevKeys は前の周に出た件の鍵（nil で見ない）。
// round は周の比べに入れる検査か（--only・--no-check は false）。applied・exempt は呼ぶ側が入れる。
func Summarize(rs []Result, rules *Rules, prevKeys map[string]bool) Summary {
	sum := Summary{Round: true, Score: Score(rs, rules), Counts: Counts{}, Exit: ExitCode(rs)}
	for _, l := range []checklevel.Level{checklevel.Gate, checklevel.Lint, checklevel.Advice} {
		sum.Counts[l.String()] = map[string]int{"near": 0, "fail": 0}
	}
	for _, r := range rs {
		if r.Status != Pass {
			sum.Counts[r.Level.String()][r.Status.String()]++
		}
	}
	sorted := Sorted(rs)
	for _, r := range sorted[:min(len(sorted), rules.Top)] {
		sum.Top = append(sum.Top, TopItem{Code: r.Code, Level: r.Level, Status: r.Status, Got: r.Got, Want: r.Want, Unit: r.Unit, Gap: r.Gap, Where: r.Where.Short()})
	}
	if sum.Top == nil {
		sum.Top = []TopItem{}
	}
	sum.Next, sum.Near = NextOf(rs, prevKeys)
	return sum
}

// Short は場所の短い字面（sprite/frame (x,y)・ms）。
func (w Where) Short() string {
	var b strings.Builder
	b.WriteString(w.Sprite)
	if w.Frame != "" {
		b.WriteString("/" + w.Frame)
	}
	if w.X != nil {
		fmt.Fprintf(&b, " (%d,%d)", *w.X, *w.Y)
	}
	switch {
	case w.FromMs != nil && w.ToMs != nil:
		fmt.Fprintf(&b, " %s〜%s ms", num(*w.FromMs), num(*w.ToMs))
	case w.Ms != nil:
		fmt.Fprintf(&b, " %s ms", num(*w.Ms))
	}
	if w.Channel != "" {
		b.WriteString(" " + w.Channel)
	}
	return strings.TrimSpace(b.String())
}

// Key は前の周と同じ件かを見分ける鍵（code と場所）。
func (r Result) Key() string {
	x, y := -1, -1
	if r.Where.X != nil {
		x, y = *r.Where.X, *r.Where.Y
	}
	return fmt.Sprintf("%s|%s|%s|%d|%d|%s", r.Code, r.Where.Sprite, r.Where.Frame, x, y, r.Msg)
}

// AppliedOf は当てた検査の組を作る。prev は前の周の同じ絵の id（無ければ ""）。組が同じなら id だけ（explain なら全文も）。
func AppliedOf(full checklevel.AppliedFull, prev string, explain bool) checklevel.Applied {
	sort.Strings(full.Checks)
	sort.Strings(full.Materials)
	h := sha256.New()
	fid := ""
	if full.Fidelity != nil {
		fid = fmt.Sprint(*full.Fidelity)
	}
	fmt.Fprintf(h, "%s|%s|%s|%s|%s|%s|%s", full.Kind, full.KindBy, fid, full.Style, strings.Join(full.Materials, ","), strings.Join(full.Checks, ","), full.Look)
	for _, s := range full.Skipped {
		fmt.Fprintf(h, "|%s:%s:%s", s.Code, s.By, s.Why)
	}
	id := hex.EncodeToString(h.Sum(nil))[:8]
	a := checklevel.Applied{ID: id, Changed: prev != "" && prev != id}
	if prev != id || explain {
		a.Full = &full
	}
	return a
}

// Line は人向けの 1 行（例 "score 72・gate 0・lint 3（near 2）・advice 1 → next px.ground-contrast（…）"）。
func (s Summary) Line() string {
	c := s.Counts
	var parts []string
	if !s.Round {
		parts = append(parts, "周の外（--only か --no-check）")
	}
	parts = append(parts, fmt.Sprintf("score %d", s.Score))
	for _, l := range []string{"gate", "lint", "advice"} {
		f, n := c[l]["fail"], c[l]["near"]
		switch {
		case f == 0 && n == 0:
			parts = append(parts, l+" 0")
		case n == 0:
			parts = append(parts, fmt.Sprintf("%s %d", l, f))
		default:
			parts = append(parts, fmt.Sprintf("%s %d（near %d）", l, f+n, n))
		}
	}
	line := strings.Join(parts, "・")
	if len(s.Next) > 0 {
		n := s.Next[0]
		line += " → next " + n.Code + "（" + n.Short() + "）"
		if len(n.Fix.Try) > 0 {
			line += " 試す: " + n.Fix.Try[0].String()
		}
		if len(s.Next) > 1 {
			line += fmt.Sprintf("（ほか next %d 件）", len(s.Next)-1)
		}
	}
	if e := s.Exempt; e != nil && e.Px > 0 {
		line += fmt.Sprintf("・外した画素 %d（%.1f%%", e.Px, e.Pct)
		if e.D != nil {
			line += fmt.Sprintf("・前の周 %+d", *e.D)
		}
		line += "）"
	}
	return line
}
