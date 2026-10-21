package refactor

import (
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// rewrite: 式を型紙（--from）で探し、別の式（--to）に書き替える（refactor-tool-design §11）。
//
//	bin/fge refactor rewrite --from '$x != None' --to 'Option.nonEmpty($x)' [--where '$x: Option'] [--in src] [--apply]
//	bin/fge refactor rewrite --rule option-none-compare [--apply]      設定の rewrites に書いた型紙の組
//
// 当たりは字でなく汎用の AST（typed の段の式の木・名前・型）で決め、穴（$x）の式の字は元のまま写す。
// 書けない所（穴の式が書かれた所に無い・型紙の外の字にコメントがある・入れ子）は書かずに人へ回す。
// ゲーム・ファイルの名前は持たない（型紙と --where は引数か設定の rewrites）。

// RewriteRule は型紙の組 1 つ（設定の rewrites の 1 件）。
type RewriteRule struct {
	From  string `json:"from"`
	To    string `json:"to"`
	Where string `json:"where,omitempty"`
	Note  string `json:"note,omitempty"`
}

// RewriteQuery は rewrite の問い。
type RewriteQuery struct {
	Rules []RewriteRule
	In    []string        // 根からの相対の file か dir（空なら全部）
	Skip  map[string]bool // file:line
}

// RewriteSite は書き替える所 1 つ。
type RewriteSite struct {
	Row
	Before string `json:"before"`
	After  string `json:"after"`
	Rule   int    `json:"rule"` // Rules の何番目で当たったか
}

// RewritePlan は rewrite の計画。
type RewritePlan struct {
	Edits    []Edit
	Sites    []RewriteSite
	Fix      []Fixed
	PerRule  []int // 型紙ごとの当たり（書く所）
	Excluded int   // --where で外した数
	Nested   int   // 別の当たりの中にある当たり（書いた後にもう一度流すと当たる）
	Notes    []string
}

var pkgPrefix = regexp.MustCompile(`^\$pkg\$[^.]*\.`)

// displaySym は索引の名前から fpkg の頭（$pkg$github$…$name.）を外した物（書く名前と比べる形）。
func displaySym(s string) string { return pkgPrefix.ReplaceAllString(s, "") }

// preludeMods は短い名前が 2 つ以上に当たった時に選ぶ標準の mod（None・Some・Ok・Err・Nil）。
var preludeMods = []string{"Option.", "Result.", "List."}

type rewriteMatcher struct {
	ast   *Ast
	srcs  *reshapeSources
	syms  map[string]map[string]bool // "tag"・"call" → 索引に出る名前（そのままの綴り）
	cache map[string]map[string]bool
	notes map[string]bool
	err   error
}

func newRewriteMatcher(a *Ast, srcs *reshapeSources) *rewriteMatcher {
	m := &rewriteMatcher{ast: a, srcs: srcs, syms: map[string]map[string]bool{"tag": {}, "call": {}}, cache: map[string]map[string]bool{}, notes: map[string]bool{}}
	for _, k := range []struct{ kind, cat string }{{"Expr.Tag", "tag"}, {"Pattern.Tag", "tag"}, {"Expr.ApplyDef", "call"}, {"Expr.ApplySig", "call"}} {
		for _, n := range a.OfKind(k.kind) {
			if s, ok := a.Attr(n, "symUse"); ok {
				m.syms[k.cat][s] = true
			}
		}
	}
	return m
}

// resolve は型紙の名前を索引の名前の集まりにする（同じ名前の綴りが fpkg の頭の有る無しで 2 つになる物は両方）。
func (m *rewriteMatcher) resolve(cat, name string) map[string]bool {
	key := cat + " " + name
	if s, ok := m.cache[key]; ok {
		return s
	}
	exact, suffix := map[string]bool{}, map[string]bool{}
	for s := range m.syms[cat] {
		d := displaySym(s)
		switch {
		case d == name:
			exact[s] = true
		case strings.HasSuffix(d, "."+name):
			suffix[s] = true
		}
	}
	out := exact
	if len(out) == 0 {
		out = suffix
		if names := displayNames(suffix); len(names) > 1 {
			var prelude []string
			for _, n := range names {
				for _, p := range preludeMods {
					if strings.HasPrefix(n, p) && strings.Count(n, ".") == 1 {
						prelude = append(prelude, n)
					}
				}
			}
			if len(prelude) == 1 {
				out = map[string]bool{}
				for s := range suffix {
					if displaySym(s) == prelude[0] {
						out[s] = true
					}
				}
			} else if m.err == nil {
				m.err = fmt.Errorf("型紙の名前 %s が 2 つ以上に当たる（%s）。修飾つきで書いてください", name, strings.Join(names, "・"))
			}
		}
	}
	if len(out) == 0 {
		m.notes[fmt.Sprintf("型紙の名前 %s は索引に無い（どこからも使われていない）", name)] = true
	}
	m.cache[key] = out
	return out
}

func displayNames(set map[string]bool) []string {
	seen := map[string]bool{}
	var out []string
	for s := range set {
		if d := displaySym(s); !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	sort.Strings(out)
	return out
}

// text は節の字（読めなければ ""）。
func (m *rewriteMatcher) text(n int32) string {
	r := m.ast.SpanOf(n)
	src, err := m.srcs.get(r.File)
	if err != nil {
		return ""
	}
	s, e, err := ByteRange(src, r)
	if err != nil || s > e {
		return ""
	}
	return src[s:e]
}

type bindings map[string]int32

func (b bindings) clone() bindings {
	c := make(bindings, len(b))
	for k, v := range b {
		c[k] = v
	}
	return c
}

func (m *rewriteMatcher) isExpr(n int32) bool { return strings.HasPrefix(m.ast.KindOf(n), "Expr.") }

// match は型紙 t が節 n に当たるか（当たれば b に穴を束ねる。外れた時の b は使わない）。
func (m *rewriteMatcher) match(t *Tmpl, n int32, b bindings) bool {
	a := m.ast
	if n < 0 {
		return false
	}
	kind := a.KindOf(n)
	switch t.Kind {
	case tAny:
		return m.isExpr(n)
	case tHole:
		if !m.isExpr(n) {
			return false
		}
		if old, ok := b[t.Name]; ok {
			return normSpace(m.text(old)) == normSpace(m.text(n))
		}
		b[t.Name] = n
		return true
	case tLit:
		if kind != "Expr.Cst" {
			return false
		}
		cst, _ := a.Attr(n, "cst")
		lit, _ := a.Attr(n, "cst.lit")
		switch t.Name {
		case "Unit":
			return cst == "Unit"
		case "Bool", "Str":
			return cst == t.Name && lit == t.Lit
		}
		return lit == t.Lit && cst != "Str"
	case tCall:
		if kind != "Expr.ApplyDef" && kind != "Expr.ApplySig" {
			return false
		}
		sym, _ := a.Attr(n, "symUse")
		if !m.resolve("call", t.Name)[sym] {
			return false
		}
		return m.matchArgs(t.Args, a.ChildrenIn(n, "exps"), b, t.Comm)
	case tTag:
		if kind != "Expr.Tag" {
			return false
		}
		sym, _ := a.Attr(n, "symUse")
		if !m.resolve("tag", t.Name)[sym] {
			return false
		}
		return m.matchArgs(t.Args, a.ChildrenIn(n, "exps"), b, false)
	case tSelect:
		if kind != "Expr.RecordSelect" {
			return false
		}
		if l, _ := a.Attr(n, "label"); l != t.Name {
			return false
		}
		return m.match(t.Args[0], a.Child(n, "exp"), b)
	case tBinary:
		if kind != "Expr.Binary" {
			return false
		}
		if op, _ := a.Attr(n, "sop"); op != t.Name {
			return false
		}
		return m.matchArgs(t.Args, []int32{a.Child(n, "exp1"), a.Child(n, "exp2")}, b, false)
	case tUnary:
		if kind != "Expr.Unary" {
			return false
		}
		if op, _ := a.Attr(n, "sop"); op != t.Name {
			return false
		}
		return m.match(t.Args[0], a.Child(n, "exp"), b)
	case tIf:
		if kind != "Expr.IfThenElse" {
			return false
		}
		return m.matchArgs(t.Args, []int32{a.Child(n, "exp1"), a.Child(n, "exp2"), a.Child(n, "exp3")}, b, false)
	case tMatch:
		if kind != "Expr.Match" {
			return false
		}
		rules := a.ChildrenIn(n, "rules")
		if len(rules) != len(t.Rules) {
			return false
		}
		for _, r := range rules {
			if len(a.ChildrenIn(r, "guard")) > 0 {
				return false
			}
		}
		if !m.match(t.Args[0], a.Child(n, "exp"), b) {
			return false
		}
		// 腕の順: 型紙に _ の腕が無ければ順を問わない（どの腕も互いに重ならない）。_ があれば同じ順だけ。
		ordered := false
		for _, r := range t.Rules {
			ordered = ordered || r.Pat.Wild
		}
		used := make([]bool, len(rules))
		var try func(i int, cur bindings) bool
		try = func(i int, cur bindings) bool {
			if i == len(t.Rules) {
				for k, v := range cur {
					b[k] = v
				}
				return true
			}
			for j, r := range rules {
				if used[j] || (ordered && j != i) {
					continue
				}
				next := cur.clone()
				if m.matchPat(t.Rules[i].Pat, a.Child(r, "pat")) && m.match(t.Rules[i].Body, a.Child(r, "exp"), next) {
					used[j] = true
					if try(i+1, next) {
						return true
					}
					used[j] = false
				}
			}
			return false
		}
		return try(0, b.clone())
	}
	return false
}

// matchArgs は引数の並びを当てる（comm なら 2 つの左右を入れ替えても）。
func (m *rewriteMatcher) matchArgs(ts []*Tmpl, ns []int32, b bindings, comm bool) bool {
	if len(ts) != len(ns) {
		return false
	}
	try := func(order []int) bool {
		next := b.clone()
		for i, t := range ts {
			if !m.match(t, ns[order[i]], next) {
				return false
			}
		}
		for k, v := range next {
			b[k] = v
		}
		return true
	}
	order := make([]int, len(ns))
	for i := range order {
		order[i] = i
	}
	if try(order) {
		return true
	}
	return comm && len(ns) == 2 && try([]int{1, 0})
}

func (m *rewriteMatcher) matchPat(p *TmplPat, n int32) bool {
	a := m.ast
	if n < 0 {
		return false
	}
	kind := a.KindOf(n)
	if p.Wild {
		return kind == "Pattern.Wild"
	}
	if kind != "Pattern.Tag" {
		return false
	}
	sym, _ := a.Attr(n, "symUse")
	if !m.resolve("tag", p.Name)[sym] {
		return false
	}
	pats := a.ChildrenIn(n, "pats")
	if len(p.Args) == 0 {
		// `None` は中身の無い case。中身のある case を名前だけで書いた時は当てない（Some と書いて Some(x) に当てない）。
		return len(pats) == 0
	}
	if len(pats) != len(p.Args) {
		return false
	}
	for i, q := range p.Args {
		if !m.matchPat(q, pats[i]) {
			return false
		}
	}
	return true
}

// rootKinds は型紙の根が当たりうる節の種類。
func rootKinds(t *Tmpl) []string {
	switch t.Kind {
	case tCall:
		return []string{"Expr.ApplyDef", "Expr.ApplySig"}
	case tTag:
		return []string{"Expr.Tag"}
	case tSelect:
		return []string{"Expr.RecordSelect"}
	case tBinary:
		return []string{"Expr.Binary"}
	case tUnary:
		return []string{"Expr.Unary"}
	case tLit:
		return []string{"Expr.Cst"}
	case tMatch:
		return []string{"Expr.Match"}
	case tIf:
		return []string{"Expr.IfThenElse"}
	}
	return nil
}

// whereOK は --where の型の絞りに b が合うか。
func (m *rewriteMatcher) whereOK(ws []Where, b bindings) bool {
	for _, w := range ws {
		t := m.ast.Type[b[w.Hole]]
		ok := m.ast.TypeText(t) == w.Type || m.ast.AliasOf(t, w.Type)
		for _, h := range m.ast.TypeHeads(t) {
			if d := displaySym(h); d == w.Type || strings.HasSuffix(d, "."+w.Type) {
				ok = true
			}
		}
		if !ok {
			return false
		}
	}
	return true
}

func normSpace(s string) string { return strings.Join(strings.Fields(s), " ") }

func inPaths(file string, in []string) bool {
	if len(in) == 0 {
		return true
	}
	for _, p := range in {
		p = strings.TrimSuffix(filepath.ToSlash(filepath.Clean(p)), "/")
		if file == p || strings.HasPrefix(file, p+"/") || p == "." {
			return true
		}
	}
	return false
}

type rewriteHit struct {
	rule  int
	root  int32
	b     bindings
	row   Row
	start int
	end   int
}

// PlanRewrite は型紙の組を汎用の AST に当て、書き替えの計画を作る。
func PlanRewrite(a *Ast, srcs *reshapeSources, q RewriteQuery) (*RewritePlan, error) {
	if a.Stage != string(Typed) {
		return nil, fmt.Errorf("汎用の AST の段が %s（rewrite は typed の段が要る）", a.Stage)
	}
	type compiled struct {
		from  *Tmpl
		to    string
		where []Where
	}
	var cs []compiled
	for i, r := range q.Rules {
		t, err := ParseTmpl(r.From)
		if err != nil {
			return nil, fmt.Errorf("型紙 %d（%s）: %v", i+1, r.From, err)
		}
		ws, err := ParseWhere(r.Where)
		if err != nil {
			return nil, err
		}
		holes := map[string]bool{}
		for _, h := range t.Holes() {
			holes[h] = true
		}
		for _, h := range toHoles(r.To) {
			if !holes[h] {
				return nil, fmt.Errorf("--to の $%s が --from（%s）に無い", h, r.From)
			}
		}
		for _, w := range ws {
			if !holes[w.Hole] {
				return nil, fmt.Errorf("--where の $%s が --from（%s）に無い", w.Hole, r.From)
			}
		}
		if strings.TrimSpace(r.To) == "" {
			return nil, fmt.Errorf("型紙 %d（%s）に --to が無い", i+1, r.From)
		}
		cs = append(cs, compiled{t, r.To, ws})
	}
	m := newRewriteMatcher(a, srcs)
	plan := &RewritePlan{PerRule: make([]int, len(cs))}
	var hits []rewriteHit
	taken := map[int32]bool{}
	for i, c := range cs {
		for _, k := range rootKinds(c.from) {
			for _, n := range a.OfKind(k) {
				if taken[n] {
					continue
				}
				row := a.SpanOf(n)
				if row.File == "" || !inPaths(row.File, q.In) {
					continue
				}
				b := bindings{}
				if !m.match(c.from, n, b) {
					continue
				}
				if m.err != nil {
					return nil, m.err
				}
				if !m.whereOK(c.where, b) {
					plan.Excluded++
					continue
				}
				taken[n] = true
				hits = append(hits, rewriteHit{rule: i, root: n, b: b, row: row})
			}
		}
	}
	if m.err != nil {
		return nil, m.err
	}
	for note := range m.notes {
		plan.Notes = append(plan.Notes, note)
	}
	sort.Strings(plan.Notes)
	sort.Slice(hits, func(i, j int) bool { return less(hits[i].row, hits[j].row) })
	// 当たりの中の当たり（match の腕の中の x != None など）は外側だけ書く。内側は書いた後にもう一度流すと当たる。
	var outer []rewriteHit
	for _, h := range hits {
		inside := false
		for _, o := range outer {
			if o.row.File == h.row.File && o.row.contains(h.row) {
				inside = true
				break
			}
		}
		if inside {
			plan.Nested++
			continue
		}
		outer = append(outer, h)
	}
	for _, h := range outer {
		h.row.Owner = a.RootName(h.root)
		if q.Skip[fmt.Sprintf("%s:%d", h.row.File, h.row.Line)] {
			continue
		}
		site, edit, why := m.plan(h, cs[h.rule].to)
		if why != "" {
			plan.Fix = append(plan.Fix, Fixed{h.row, why})
			continue
		}
		site.Rule = h.rule
		plan.Sites = append(plan.Sites, site)
		plan.Edits = append(plan.Edits, edit)
		plan.PerRule[h.rule]++
	}
	return plan, nil
}

var callForm = regexp.MustCompile(`^[A-Za-z_][\w.]*\s*\(`)

// plan は当たり 1 つの書き替え（書けなければ理由）。
func (m *rewriteMatcher) plan(h rewriteHit, to string) (RewriteSite, Edit, string) {
	a := m.ast
	src, err := m.srcs.get(h.row.File)
	if err != nil {
		return RewriteSite{}, Edit{}, err.Error()
	}
	s, e, err := ByteRange(src, h.row)
	if err != nil || s >= e {
		return RewriteSite{}, Edit{}, "索引が古い（範囲が中身の外。bin/fge refactor index --stage typed --rebuild）"
	}
	before := src[s:e]
	type hole struct {
		name       string
		start, end int
		text       string
	}
	var holes []hole
	for name, n := range h.b {
		r := a.SpanOf(n)
		hs, he, err := ByteRange(src, r)
		if err != nil || hs < s || he > e || hs >= he {
			return RewriteSite{}, Edit{}, fmt.Sprintf("穴 $%s の式が書かれた所に無い（構文が作った式。手で）", name)
		}
		text := src[hs:he]
		// match の腕の本体が { … } で囲まれていれば、その括弧ごと写す（let を並べた本体）。
		if a.SlotOf(n) == "exp" && a.Parent[n] >= 0 && a.KindOf(a.Parent[n]) == "MatchRule" {
			if bs, be, ok := bracedAround(src, hs, he); ok && bs >= s && be <= e {
				hs, he, text = bs, be, src[bs:be]
			} else if k := a.KindOf(n); k == "Expr.Let" || k == "Expr.Stm" || k == "Expr.LocalDef" || k == "Expr.Discard" {
				text = braceBlock(src, hs, text, lineIndent(src, s))
			}
		}
		holes = append(holes, hole{name, hs, he, text})
	}
	// 型紙の外の字（穴の外）にコメントがあれば、書き替えで消えるので書かない。
	rest := []byte(before)
	for _, x := range holes {
		for i := x.start - s; i < x.end-s; i++ {
			rest[i] = ' '
		}
	}
	if hasComment(string(rest)) {
		return RewriteSite{}, Edit{}, "型紙の外の字にコメントがある（書き替えると消える。手で）"
	}
	texts := map[string]string{}
	for _, x := range holes {
		texts[x.name] = x.text
	}
	after := substituteHoles(to, texts)
	if p := a.Parent[h.root]; p >= 0 && !isAtomicText(after) && needsParensIn(a, p, m.text(p)) {
		after = "(" + after + ")"
	}
	site := RewriteSite{Row: h.row, Before: before, After: after}
	edit := Edit{File: h.row.File, Start: s, End: e, Site: h.row,
		Make:  func(string) (string, error) { return after, nil },
		Check: []Want{{Span: h.row, Text: before}}}
	return site, edit, ""
}

// needsParensIn は親の節 p（字は text）の中で、原子でない式を括弧で包むか（演算子・欄の読みの受け手）。
func needsParensIn(a *Ast, p int32, text string) bool {
	switch a.KindOf(p) {
	case "Expr.Binary", "Expr.Unary", "Expr.RecordSelect":
		return true
	case "Expr.ApplySig", "Expr.ApplyDef":
		// 演算子の形（a + b・x != y）なら包む。f(…) の形の引数なら包まない。
		return !callForm.MatchString(strings.TrimSpace(text))
	}
	return false
}

// substituteHoles は --to の $x を穴の字にする。演算子の間に置く原子でない式は括弧で包む。
func substituteHoles(to string, texts map[string]string) string {
	var b strings.Builder
	rs := []rune(to)
	inStr := false
	for i := 0; i < len(rs); i++ {
		c := rs[i]
		if c == '"' && (i == 0 || rs[i-1] != '\\') {
			inStr = !inStr
		}
		if c != '$' || inStr {
			b.WriteRune(c)
			continue
		}
		j := i + 1
		for j < len(rs) && (isIdentRune(rs[j])) {
			j++
		}
		name := string(rs[i+1 : j])
		text, ok := texts[name]
		if !ok {
			b.WriteRune(c)
			continue
		}
		// then の本体に if を置くと、続く else がどちらの if の物か読みにくい（ぶら下がり else）ので包む。
		danglingElse := strings.HasPrefix(strings.TrimSpace(string(rs[j:])), "else") && startsWithWord(text, "if")
		if !isAtomicText(text) && (!delimited(rs, i, j) || danglingElse) {
			text = "(" + text + ")"
		}
		b.WriteString(text)
		i = j - 1
	}
	return b.String()
}

func isIdentRune(r rune) bool {
	return r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r > 127
}

// delimited は --to の rs[i:j]（$x）が括弧・, の間だけにあるか（`f($x, …)`・`($x)`・if の本体・else の後・全体）。
func delimited(rs []rune, i, j int) bool {
	prev := strings.TrimRight(string(rs[:i]), " \t\n")
	next := strings.TrimLeft(string(rs[j:]), " \t\n")
	okPrev := prev == "" || strings.HasSuffix(prev, "(") || strings.HasSuffix(prev, ",") || strings.HasSuffix(prev, "{") ||
		strings.HasSuffix(prev, "=>") || strings.HasSuffix(prev, " else") || prev == "else" || strings.HasSuffix(prev, ")") && isIfHead(prev)
	okNext := next == "" || strings.HasPrefix(next, ")") || strings.HasPrefix(next, ",") || strings.HasPrefix(next, "}") ||
		strings.HasPrefix(next, "else") || strings.HasPrefix(next, "case ")
	return okPrev && okNext
}

// isIfHead は prev が `if (…)` で終わるか（then の本体の前）。
func isIfHead(prev string) bool {
	depth := 0
	for i := len(prev) - 1; i >= 0; i-- {
		switch prev[i] {
		case ')':
			depth++
		case '(':
			depth--
			if depth == 0 {
				return strings.HasSuffix(strings.TrimRight(prev[:i], " "), "if")
			}
		}
	}
	return false
}

// isAtomicText は式の字が演算子なしの 1 つの形（名前・字の値・呼び出し・欄の読み・括弧で包んだ物）か。
func isAtomicText(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" {
		return true
	}
	depth := 0
	inStr := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if inStr {
			if c == '\\' {
				i++
			} else if c == '"' {
				inStr = false
			}
			continue
		}
		switch c {
		case '"':
			inStr = true
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		default:
			if depth == 0 && (c == ' ' || c == '\t' || c == '\n' || strings.IndexByte("+-*/<>=!&|:?", c) >= 0) {
				return false
			}
		}
	}
	return true
}

// bracedAround は src[hs:he] の前後（空白を飛ばして）が { と } なら、その範囲を返す。
func bracedAround(src string, hs, he int) (int, int, bool) {
	i := hs - 1
	for i >= 0 && strings.IndexByte(" \t\r\n", src[i]) >= 0 {
		i--
	}
	j := he
	for j < len(src) && strings.IndexByte(" \t\r\n", src[j]) >= 0 {
		j++
	}
	if i >= 0 && j < len(src) && src[i] == '{' && src[j] == '}' {
		return i, j + 1, true
	}
	return 0, 0, false
}

// braceBlock は let を並べた本体を { … } で包む（複数行なら、本体の行の字下げのまま閉じ括弧を root の字下げに）。
func braceBlock(src string, hs int, text, rootIndent string) string {
	if !strings.Contains(text, "\n") {
		return "{ " + text + " }"
	}
	return "{\n" + lineIndent(src, hs) + text + "\n" + rootIndent + "}"
}

// hasComment は字（字の値の中を除く）に // か /* があるか。
func hasComment(s string) bool {
	inStr := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if inStr {
			if c == '\\' {
				i++
			} else if c == '"' {
				inStr = false
			}
			continue
		}
		if c == '"' {
			inStr = true
			continue
		}
		if c == '/' && i+1 < len(s) && (s[i+1] == '/' || s[i+1] == '*') {
			return true
		}
	}
	return false
}

// rewriteRules は呼び方（--rule か --from/--to/--where）から型紙の組を作る。
func rewriteRules(a args, cfg Config) ([]RewriteRule, error) {
	if a.rule != "" {
		if a.from != "" || a.to != "" || a.where != "" {
			return nil, fmt.Errorf("--rule と --from・--to・--where は一緒に使えない")
		}
		// --rule a,b は組を並べて 1 回で当てる（1 つの patch・確かめ 1 回）。
		var rules []RewriteRule
		for _, name := range strings.Split(a.rule, ",") {
			name = strings.TrimSpace(name)
			got, ok := cfg.Rewrites[name]
			if !ok || len(got) == 0 {
				var names []string
				for k := range cfg.Rewrites {
					names = append(names, k)
				}
				sort.Strings(names)
				return nil, fmt.Errorf("設定の rewrites に %s が無い（あるのは %s。bin/lint-rules/refactor.local.json の rewrites に足す）", name, strings.Join(names, "・"))
			}
			rules = append(rules, got...)
		}
		return rules, nil
	}
	if a.from == "" || a.to == "" {
		return nil, fmt.Errorf("--from '<型紙>' と --to '<式>'（か --rule <名前>）が要ります")
	}
	return []RewriteRule{{From: a.from, To: a.to, Where: a.where}}, nil
}

// loadRewriteAst は索引と同じ走行の汎用の AST を読む（写しが無いか索引と鍵が違えば、typed の索引を作り直す）。
func loadRewriteAst(b Builder, idx *Index) (*Ast, *Index, error) {
	if b.genericKey(Typed) != idx.Key {
		fmt.Fprintf(b.Log, "[refactor] 汎用の AST（式の木）が索引と揃っていないので、typed の索引を作り直します\n")
		b.Rebuild = true
		fresh, err := b.Load(Typed)
		if err != nil {
			return nil, nil, err
		}
		idx = fresh
		if b.genericKey(Typed) != idx.Key {
			return nil, nil, fmt.Errorf("flixlint が汎用の AST（%s）を書かなかった（flixlint 0.8.0 以上が要る）", rel(b.factsGenericDir()))
		}
	}
	ast, err := LoadAst(b.GenericDir(Typed), b.Flixlint)
	return ast, idx, err
}

// rewriteReport は rewrite の入口。
func rewriteReport(root string, idx *Index, a args, cfg Config, o Options, b Builder) (report, *Index, error) {
	rules, err := rewriteRules(a, cfg)
	if err != nil {
		return report{}, idx, err
	}
	ast, idx, err := loadRewriteAst(b, idx)
	if err != nil {
		return report{}, idx, err
	}
	var in []string
	if a.in != "" {
		in = strings.Split(a.in, ",")
	}
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	plan, err := PlanRewrite(ast, srcs, RewriteQuery{Rules: rules, In: in, Skip: a.skip})
	if err != nil {
		return report{}, idx, err
	}
	out := Change(root, plan.Edits, a.applyWith(cfg.Verify, o))
	target := a.rule
	if target == "" {
		target = a.from + " → " + a.to
	}
	r := report{Op: "rewrite", Target: target, code: CodeRewrite, Outcome: &out, Fix: sortedFixed(plan.Fix)}
	if plan.Sites == nil {
		plan.Sites = []RewriteSite{}
	}
	r.Sites = plan.Sites
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.Sites) + len(plan.Fix)
	}
	rows := make([]Row, len(plan.Sites))
	for i, s := range plan.Sites {
		rows[i] = s.Row
	}
	r.gotText = fmt.Sprintf("書き替える所 %d（%s）・人へ回す %d", len(plan.Sites), split(rows), len(plan.Fix))
	if len(rules) > 1 {
		var parts []string
		for i, n := range plan.PerRule {
			parts = append(parts, fmt.Sprintf("%s %d", rules[i].From, n))
		}
		r.extra = append(r.extra, "型紙ごと: "+strings.Join(parts, "・"))
	}
	if plan.Excluded > 0 {
		r.extra = append(r.extra, fmt.Sprintf("形は当たったが --where の型で外した所 %d", plan.Excluded))
	}
	if plan.Nested > 0 {
		r.extra = append(r.extra, fmt.Sprintf("別の当たりの中にある当たり %d（外側だけ書く。書いた後にもう一度流すと当たる）", plan.Nested))
	}
	r.extra = append(r.extra, plan.Notes...)
	r.wantText = "型紙に当たる式が全部 --to の形になる（書けない所は fix）"
	for _, f := range r.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s → %s\t%s", s.Where(), clip(normSpace(s.Before), 60), clip(normSpace(s.After), 60), s.Owner))
	}
	nextOf(&r, rewriteCommand(a), a, &out)
	switch {
	case out.State == StateNothing && len(plan.Fix) == 0:
		r.extra = append(r.extra, "型紙に当たる式が無い")
	case len(plan.Fix) > 0 && out.State == StateDryRun:
		r.fixHint = "fix の所は手で（ほかの所は --apply で書く）"
	case len(plan.Fix) > 0 && out.State == StateNothing:
		r.fixHint = "fix の所は手で（型紙で書ける所は残っていない）"
	case out.State == StateApplied:
		r.Done = fmt.Sprintf("done: %d sites rewritten · %d left to a person · check ok", len(plan.Sites), len(plan.Fix))
		r.Next, r.NextWhy = rewriteCommand(a), "書いた後の残り（索引は作り直しになる。0 なら lint の上限を下げる）"
		r.lines = nil
	}
	return r, idx, nil
}

// rewriteCommand は同じ問いのコマンド（写して流せる形。型紙は ' で包む）。
func rewriteCommand(a args) string {
	cmd := "bin/fge refactor rewrite"
	if a.rule != "" {
		cmd += " --rule " + a.rule
	} else {
		cmd += " --from " + shellQuote(a.from) + " --to " + shellQuote(a.to)
		if a.where != "" {
			cmd += " --where " + shellQuote(a.where)
		}
	}
	if a.in != "" {
		cmd += " --in " + a.in
	}
	return cmd
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// startsWithWord は s が語 w で始まるか（`if (` の if・`iffy` は違う）。
func startsWithWord(s, w string) bool {
	s = strings.TrimSpace(s)
	return strings.HasPrefix(s, w) && (len(s) == len(w) || !isIdentRune(rune(s[len(w)])))
}
