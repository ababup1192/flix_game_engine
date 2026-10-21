package refactor

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// extract-function: 選んだ式を新しい def に出し、元の所を呼び出しに替える（設計 §12）。
//
// 式は位置（索引と同じ形の範囲）か rewrite の型紙で選ぶ。引数は式の自由変数（式の外で束ねた局所の名前）で、型は束ねた所の
// 書いた型（引数なら alias のまま）か推論の型、戻りと効果は推論の型（typed の段）。--all は汎用の AST で同じ形の式を
// 全部呼び出しへ替える: 局所の名前の付け替えは同じと見て、自由変数の所だけはほかの所で別の式でもよい（その所の引数になる）。
// ゲーム・ファイルの名前は持たない。

// ExtractQuery は extract-function の問い。
type ExtractQuery struct {
	Name string // Mod.name
	At   string // file:L:C-L:C（無ければ Expr）
	Expr string // 型紙
	To   string // 置くファイル（無ければ既定）
	All  bool
	Doc  string
	Skip map[string]bool
}

// ExtractSite は呼び出しへ替える所 1 つ。
type ExtractSite struct {
	Row
	Before string `json:"before"`
	Call   string `json:"call"`
}

// ExtractPlan は extract-function の計画。
type ExtractPlan struct {
	Decl     string // 置く def の字
	DeclRow  Row
	Params   []string // 引数（名前: 型）
	Ret      string
	Effect   string // 効果（Pure は ""）
	Pub      bool
	Edits    []Edit
	Sites    []ExtractSite
	Fix      []Fixed
	Excluded int // 形は同じで、自由変数の所の型が違う・効果のある式（呼び出しにしない）
	Shapes   int // 型紙に当たったが、選んだ式と形が違う所（--expr の時）
}

var extractAtRe = regexp.MustCompile(`^(.+):(\d+):(\d+)-(\d+):(\d+)$`)

// nodeText は節の字（読めなければ ""）。
func nodeText(a *Ast, srcs *reshapeSources, n int32) string {
	r := a.SpanOf(n)
	src, err := srcs.get(r.File)
	if err != nil {
		return ""
	}
	s, e, err := ByteRange(src, r)
	if err != nil || s > e {
		return ""
	}
	return src[s:e]
}

func isExprKind(a *Ast, n int32) bool { return strings.HasPrefix(a.KindOf(n), "Expr.") }

// sameSpan は 2 つの節が同じ範囲か。
func sameSpan(a *Ast, x, y int32) bool {
	return a.Line[x] == a.Line[y] && a.Col[x] == a.Col[y] && a.EndLine[x] == a.EndLine[y] && a.EndCol[x] == a.EndCol[y]
}

// findExprAt は位置 file:L:C-L:C とちょうど同じ範囲の式（構文の作った節でない一番外の物）。
func findExprAt(a *Ast, at string) (int32, error) {
	m := extractAtRe.FindStringSubmatch(at)
	if m == nil {
		return -1, fmt.Errorf("位置は <file>:<行>:<桁>-<行>:<桁>（桁は 1 から・終わりは最後の字の次）: %q", at)
	}
	num := func(s string) int32 { n, _ := strconv.Atoi(s); return int32(n) }
	file, l1, c1, l2, c2 := m[1], num(m[2]), num(m[3]), num(m[4]), num(m[5])
	best, near := int32(-1), int32(-1)
	for i := range a.Kind {
		n := int32(i)
		if !isExprKind(a, n) || a.File(n) != file {
			continue
		}
		if a.Line[n] == l1 && a.Col[n] == c1 && a.EndLine[n] == l2 && a.EndCol[n] == c2 {
			if a.Synth[n] != 0 {
				continue
			}
			if best < 0 || depthOf(a, n) < depthOf(a, best) {
				best = n
			}
			continue
		}
		// 範囲を含む一番小さい式（止める時に出す）
		startsBefore := a.Line[n] < l1 || (a.Line[n] == l1 && a.Col[n] <= c1)
		endsAfter := a.EndLine[n] > l2 || (a.EndLine[n] == l2 && a.EndCol[n] >= c2)
		if startsBefore && endsAfter && a.Synth[n] == 0 && (near < 0 || depthOf(a, n) > depthOf(a, near)) {
			near = n
		}
	}
	if best >= 0 {
		return best, nil
	}
	if near >= 0 {
		r := a.SpanOf(near)
		return -1, fmt.Errorf("%s とちょうど同じ範囲の式が無い（含む一番小さい式は %s:%d:%d-%d:%d）", at, r.File, r.Line, r.Col, r.EndLine, r.EndCol)
	}
	return -1, fmt.Errorf("%s に式が無い", at)
}

func depthOf(a *Ast, n int32) int {
	d := 0
	for p := a.Parent[n]; p >= 0; p = a.Parent[p] {
		d++
	}
	return d
}

// subtree は n とその下の節（歩く順）。
func subtree(a *Ast, n int32) []int32 {
	out := []int32{n}
	for i := 0; i < len(out); i++ {
		out = append(out, a.children[out[i]]...)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// isLocalSym は局所の名前の sym（x#12 の形）か。
func isLocalSym(s string) bool {
	i := strings.LastIndexByte(s, '#')
	if i <= 0 || i == len(s)-1 {
		return false
	}
	_, err := strconv.Atoi(s[i+1:])
	return err == nil
}

func localName(s string) string { return s[:strings.LastIndexByte(s, '#')] }

// freeVar は式の自由変数 1 つ。
type freeVar struct {
	sym  string
	name string
	at   int32 // 最初に出た Expr.Var
}

// boundIn は n の下で束ねた局所の名前。
func boundIn(a *Ast, nodes []int32) map[string]bool {
	out := map[string]bool{}
	for _, x := range nodes {
		if a.KindOf(x) == "Expr.Var" {
			continue
		}
		if s, ok := a.Attr(x, "sym"); ok && isLocalSym(s) {
			out[s] = true
		}
	}
	return out
}

// freeVarsOf は式 n の自由変数（出た順）と、選べない訳（無ければ ""）。
func freeVarsOf(a *Ast, n int32) ([]freeVar, string) {
	nodes := subtree(a, n)
	bound := boundIn(a, nodes)
	var out []freeVar
	seen := map[string]bool{}
	names := map[string]string{}
	for _, x := range nodes {
		switch a.KindOf(x) {
		case "Expr.Var":
			s, _ := a.Attr(x, "sym")
			if !isLocalSym(s) || bound[s] || seen[s] {
				continue
			}
			seen[s] = true
			name := localName(s)
			if other, ok := names[name]; ok && other != s {
				return nil, fmt.Sprintf("同じ名前 %s の別の局所の名前を 2 つ使う（引数の名前がぶつかる）", name)
			}
			names[name] = s
			out = append(out, freeVar{sym: s, name: name, at: x})
		case "Expr.ApplyLocalDef":
			if s, _ := a.Attr(x, "symUse"); !bound[s] {
				return nil, fmt.Sprintf("式の外の局所の def %s を呼ぶ（引数に渡せない）", localName(s))
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		x, y := out[i].at, out[j].at
		if a.Line[x] != a.Line[y] {
			return a.Line[x] < a.Line[y]
		}
		return a.Col[x] < a.Col[y]
	})
	return out, ""
}

// binderOf は宣言 root の中で局所の名前 sym を束ねた節（無ければ -1）。
func binderOf(a *Ast, root int32, sym string) int32 {
	for _, x := range subtree(a, root) {
		if a.KindOf(x) == "Expr.Var" {
			continue
		}
		if s, ok := a.Attr(x, "sym"); ok && s == sym {
			return x
		}
	}
	return -1
}

// paramType は自由変数の型の字（束ねた所が書いた型の引数ならそれ・ほかは推論の型）。
func paramType(a *Ast, v freeVar) (string, string) {
	b := binderOf(a, a.Root[v.at], v.sym)
	if b >= 0 && a.Synth[b] != 0 {
		return "", "構文（|> など）の作った名前 " + v.name + " を使う（選んだ範囲が構文の一部）"
	}
	if b >= 0 && a.KindOf(b) == "FormalParam" {
		if src, _ := a.Attr(b, "src"); src != "Inferred" {
			for _, t := range a.AttrTypes(b, "tpe") {
				if s, ok := a.FlixType(t); ok {
					return s, ""
				}
			}
		}
	}
	if s, ok := a.FlixType(a.Type[v.at]); ok {
		return s, ""
	}
	return "", fmt.Sprintf("引数 %s の型 %s を書けない（型の変数・書けない形）", v.name, a.TypeText(a.Type[v.at]))
}

// shapeEq は 2 つの式が汎用の AST で同じ形かを比べる（局所の名前は束ねた所の対応で・自由変数の所は穴）。
type shapeEq struct {
	a      *Ast
	srcs   *reshapeSources
	free   map[string]bool
	bound  map[string]string
	back   map[string]string
	args   map[string]int32
	ignore map[int32]bool // 比べない葉（pos）
	why    string         // 形は同じだが外した訳（型・効果）
}

func (e *shapeEq) eq(x, y int32) bool {
	a := e.a
	if a.KindOf(x) == "Expr.Var" {
		if s, _ := a.Attr(x, "sym"); e.free[s] {
			if !isExprKind(a, y) {
				return false
			}
			if prev, ok := e.args[s]; ok {
				return normSpace(nodeText(a, e.srcs, prev)) == normSpace(nodeText(a, e.srcs, y))
			}
			if a.Type[x] != a.Type[y] {
				e.why = "型"
				return false
			}
			if eff := a.EffectOf(y); eff >= 0 {
				if _, pure, ok := a.FlixEffect(eff); !ok || !pure {
					e.why = "効果"
					return false
				}
			}
			e.args[s] = y
			return true
		}
	}
	if a.Kind[x] != a.Kind[y] || a.Synth[x] != a.Synth[y] || a.Slot[x] != a.Slot[y] || a.Index[x] != a.Index[y] {
		return false
	}
	nx, ny := a.aStart[x+1]-a.aStart[x], a.aStart[y+1]-a.aStart[y]
	if nx != ny {
		return false
	}
	for k := int32(0); k < nx; k++ {
		i, j := a.aStart[x]+k, a.aStart[y]+k
		if a.aName[i] != a.aName[j] {
			return false
		}
		if e.ignore[a.aName[i]] {
			continue // 末尾の呼び出しか（pos）は置き場で変わるので比べない
		}
		if a.aType[i] != a.aType[j] {
			return false
		}
		vi, vj := a.aValue[i], a.aValue[j]
		if vi == vj {
			if vi >= 0 && isLocalSym(a.strs[vi]) && !e.same(a.strs[vi], a.strs[vj]) {
				return false
			}
			continue
		}
		if vi < 0 || vj < 0 {
			return false
		}
		si, sj := a.strs[vi], a.strs[vj]
		if !isLocalSym(si) || !isLocalSym(sj) || !e.same(si, sj) {
			return false
		}
	}
	cx, cy := a.children[x], a.children[y]
	if len(cx) != len(cy) {
		return false
	}
	for k := range cx {
		if !e.eq(cx[k], cy[k]) {
			return false
		}
	}
	return true
}

// same は局所の名前 s（選んだ式の側）と t（比べる側）が対応するか（初めてなら対応を覚える）。
func (e *shapeEq) same(s, t string) bool {
	if e.free[s] {
		return s == t
	}
	if m, ok := e.bound[s]; ok {
		return m == t
	}
	if m, ok := e.back[t]; ok {
		return m == s
	}
	e.bound[s], e.back[t] = t, s
	return true
}

// PlanExtract は extract-function の計画を作る。
func PlanExtract(a *Ast, srcs *reshapeSources, q ExtractQuery) (*ExtractPlan, error) {
	mod, short := modOf(q.Name), shortName(q.Name)
	if mod == "" || short == "" || unicodeUpper(short) {
		return nil, fmt.Errorf("--name は Mod.name の形（名前は小文字で始める）: %q", q.Name)
	}
	for _, kind := range []string{"Def", "Enum", "TypeAlias"} {
		for _, n := range a.OfKind(kind) {
			if a.Parent[n] < 0 && displaySym(a.RootName(n)) == q.Name {
				return nil, fmt.Errorf("%s はもうある（別の名前を --name に）", q.Name)
			}
		}
	}
	plan := &ExtractPlan{}
	var rep int32 = -1
	var tmplHits []int32
	if q.At != "" {
		n, err := findExprAt(a, q.At)
		if err != nil {
			return nil, err
		}
		rep = n
	} else {
		t, err := ParseTmpl(q.Expr)
		if err != nil {
			return nil, fmt.Errorf("--expr: %v", err)
		}
		m := newRewriteMatcher(a, srcs)
		for _, k := range rootKinds(t) {
			for _, n := range a.OfKind(k) {
				if a.Synth[n] == 0 && a.File(n) != "" && m.match(t, n, bindings{}) {
					tmplHits = append(tmplHits, n)
				}
			}
		}
		if m.err != nil {
			return nil, m.err
		}
		sortNodes(a, tmplHits)
		switch {
		case len(tmplHits) == 0:
			return nil, fmt.Errorf("--expr %s に当たる式が無い", q.Expr)
		case len(tmplHits) > 1 && !q.All:
			var ws []string
			for i, n := range tmplHits {
				if i == 5 {
					ws = append(ws, "…")
					break
				}
				ws = append(ws, a.SpanOf(n).Where())
			}
			return nil, fmt.Errorf("--expr に当たる式が %d（%s）。全部を呼び出しへ替えるなら --all、1 つなら <file>:<行>:<桁>-<行>:<桁> で", len(tmplHits), strings.Join(ws, "・"))
		}
		rep = tmplHits[0]
	}
	frees, why := freeVarsOf(a, rep)
	if why != "" {
		return nil, fmt.Errorf("%s: %s", a.SpanOf(rep).Where(), why)
	}
	free := map[string]bool{}
	for _, v := range frees {
		free[v.sym] = true
		t, why := paramType(a, v)
		if why != "" {
			return nil, fmt.Errorf("%s: %s", a.SpanOf(rep).Where(), why)
		}
		plan.Params = append(plan.Params, v.name+": "+shortenIn(t, mod))
	}
	ret, ok := a.FlixType(a.Type[rep])
	if !ok {
		return nil, fmt.Errorf("%s: 式の型 %s を書けない（型の変数・書けない形）", a.SpanOf(rep).Where(), a.TypeText(a.Type[rep]))
	}
	plan.Ret = shortenIn(ret, mod)
	if eff := a.EffectOf(rep); eff >= 0 {
		text, pure, ok := a.FlixEffect(eff)
		if !ok {
			return nil, fmt.Errorf("%s: 式の効果に型の変数がある（効果の多相の式は手で出す）", a.SpanOf(rep).Where())
		}
		if !pure {
			plan.Effect = text
		}
	}
	// 呼び出しへ替える所: 選んだ式と、--all なら同じ形の式。
	type site struct {
		n    int32
		args []string
	}
	repArgs := make([]string, len(frees))
	for i, v := range frees {
		repArgs[i] = v.name
	}
	sites := []site{{rep, repArgs}}
	ignore := map[int32]bool{}
	if no, ok := a.attrNo["pos"]; ok {
		ignore[no] = true
	}
	if q.All {
		for _, n := range a.OfKind(a.KindOf(rep)) {
			if n == rep || a.Synth[n] != 0 || a.File(n) == "" {
				continue
			}
			e := &shapeEq{a: a, srcs: srcs, free: free, bound: map[string]string{}, back: map[string]string{}, args: map[string]int32{}, ignore: ignore}
			// 根の欄・位置は比べない（どこにあってもよい）。
			if !e.eqRoot(rep, n) {
				if e.why != "" {
					plan.Excluded++
				}
				continue
			}
			args := make([]string, len(frees))
			for i, v := range frees {
				args[i] = nodeText(a, srcs, e.args[v.sym])
			}
			sites = append(sites, site{n, args})
		}
		for _, n := range tmplHits {
			found := false
			for _, s := range sites {
				if s.n == n {
					found = true
				}
			}
			if !found {
				plan.Shapes++
			}
		}
	}
	sort.Slice(sites, func(i, j int) bool { return less(a.SpanOf(sites[i].n), a.SpanOf(sites[j].n)) })
	// 入れ子・重なりは外側だけ。
	var kept []site
	for _, s := range sites {
		r := a.SpanOf(s.n)
		inside := false
		for _, k := range kept {
			if kr := a.SpanOf(k.n); kr.File == r.File && kr.contains(r) {
				inside = true
			}
		}
		if !inside {
			kept = append(kept, s)
		}
	}
	for _, s := range kept {
		r := a.SpanOf(s.n)
		r.Owner = displaySym(a.RootName(s.n))
		if q.Skip[fmt.Sprintf("%s:%d", r.File, r.Line)] {
			continue
		}
		callee := q.Name
		if modOf(r.Owner) == mod {
			callee = short
		} else {
			plan.Pub = true
		}
		call := callee + "(" + strings.Join(s.args, ", ") + ")"
		src, err := srcs.get(r.File)
		if err != nil {
			return nil, err
		}
		bs, be, err := ByteRange(src, r)
		if err != nil || bs >= be {
			return nil, fmt.Errorf("索引が古い（%s の範囲が中身の外。bin/fge refactor index --stage typed --rebuild）", r.Where())
		}
		before := src[bs:be]
		c := call
		plan.Edits = append(plan.Edits, Edit{File: r.File, Start: bs, End: be, Site: r,
			Make: func(string) (string, error) { return c, nil }, Check: []Want{{Span: r, Text: before}}})
		plan.Sites = append(plan.Sites, ExtractSite{Row: r, Before: before, Call: call})
	}
	if len(plan.Sites) == 0 {
		return plan, nil
	}
	// 置く所と def の字。
	repRow := a.SpanOf(rep)
	src, err := srcs.get(repRow.File)
	if err != nil {
		return nil, err
	}
	rs, re, _ := ByteRange(src, repRow)
	body := src[rs:re]
	ownerMod := modOf(displaySym(a.RootName(rep)))
	var file string
	var pos int
	var indent string
	trailer := "\n\n"
	lead := ""
	if q.To == "" && mod == ownerMod {
		root := a.Root[rep]
		ds, _, err := ByteRange(src, a.SpanOf(root))
		if err != nil {
			return nil, err
		}
		file, pos, indent = repRow.File, lineStart(src, ds), lineIndent(src, ds)
	} else {
		file = q.To
		if file == "" {
			f, _, err := firstDeclOf(a, srcs, mod)
			if err != nil {
				return nil, fmt.Errorf("mod %s の置き場が分からない（--to <file> で置くファイルを渡す）", mod)
			}
			file = f
		}
		tsrc, err := srcs.get(file)
		if err != nil {
			return nil, fmt.Errorf("--to %s が読めない: %v", file, err)
		}
		span, ok := modBlock(tsrc, mod)
		if !ok {
			return nil, fmt.Errorf("%s に mod %s の括弧が無い", file, mod)
		}
		pos, indent = span.closeLine, span.indent+"    "
		lead, trailer = "\n", "\n"
	}
	bodyIndent := indent + "    "
	lines := strings.SplitN(body, "\n", 2)
	text := lines[0]
	if len(lines) == 2 {
		text += "\n" + reindent(lines[1], lineIndent(src, rs), bodyIndent)
	}
	sig := "def " + short + "(" + strings.Join(plan.Params, ", ") + "): " + plan.Ret
	if plan.Effect != "" {
		sig += " \\ " + plan.Effect
	}
	var b strings.Builder
	b.WriteString(lead)
	if q.Doc != "" {
		b.WriteString(indent + "/// " + q.Doc + "\n")
	}
	b.WriteString(indent)
	if plan.Pub {
		b.WriteString("pub ")
	}
	b.WriteString(sig + " =\n" + bodyIndent + text + trailer)
	decl := b.String()
	plan.Decl = strings.TrimSpace(decl)
	fsrc, _ := srcs.get(file)
	plan.DeclRow = rowAt(file, fsrc, pos, q.Name)
	plan.DeclRow.Kind = "def-decl"
	plan.Edits = append(plan.Edits, Edit{File: file, Start: pos, End: pos, Site: plan.DeclRow,
		Make: func(string) (string, error) { return decl, nil }})
	return plan, nil
}

// eqRoot は根の節の欄と位置を問わずに比べる。
func (e *shapeEq) eqRoot(x, y int32) bool {
	a := e.a
	sx, ix := a.Slot[x], a.Index[x]
	sy, iy := a.Slot[y], a.Index[y]
	a.Slot[y], a.Index[y] = sx, ix
	ok := e.eq(x, y)
	a.Slot[y], a.Index[y] = sy, iy
	return ok
}

func sortNodes(a *Ast, ns []int32) {
	sort.Slice(ns, func(i, j int) bool { return less(a.SpanOf(ns[i]), a.SpanOf(ns[j])) })
}

// extractFunctionReport は extract-function の入口。
func extractFunctionReport(root string, idx *Index, a args, cfg Config, o Options, b Builder) (report, *Index, error) {
	ast, idx, err := loadGenericAst(b, idx, Typed)
	if err != nil {
		return report{}, idx, err
	}
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	q := ExtractQuery{Name: a.name, At: a.target, Expr: a.expr, To: a.to, All: a.all, Doc: a.doc, Skip: a.skip}
	plan, err := PlanExtract(ast, srcs, q)
	if err != nil {
		return report{}, idx, err
	}
	out := Change(root, plan.Edits, a.applyWith(cfg.Verify, o))
	r := report{Op: "extract-function", Target: a.name, code: CodeExtractFunction, Outcome: &out, Fix: sortedFixed(plan.Fix)}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.Sites) + len(plan.Fix)
	}
	if plan.Sites == nil {
		plan.Sites = []ExtractSite{}
	}
	r.Sites = plan.Sites
	rows := make([]Row, len(plan.Sites))
	for i, s := range plan.Sites {
		rows[i] = s.Row
	}
	r.gotText = fmt.Sprintf("呼び出しへ替える所 %d（%s）・def を置く 1（%s）・人へ回す %d", len(plan.Sites), split(rows), plan.DeclRow.Where(), len(plan.Fix))
	sig := "(" + strings.Join(plan.Params, ", ") + "): " + plan.Ret
	if plan.Effect != "" {
		sig += " \\ " + plan.Effect
	}
	r.extra = append(r.extra, "型: "+a.name+sig)
	if plan.Excluded > 0 {
		r.extra = append(r.extra, fmt.Sprintf("形は同じだが自由変数の所の型が違う・効果のある式を渡す所 %d（替えない）", plan.Excluded))
	}
	if plan.Shapes > 0 {
		r.extra = append(r.extra, fmt.Sprintf("型紙に当たったが選んだ式（最初の当たり）と形が違う所 %d（替えない。その所を位置で選んで別の名前で）", plan.Shapes))
	}
	r.wantText = "選んだ式（--all なら同じ形の式）が " + a.name + " の呼び出しになる"
	r.lines = append(r.lines, fmt.Sprintf("%s\t%s", plan.DeclRow.Where(), clip(normSpace(plan.Decl), 90)))
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s → %s\t%s", s.Where(), clip(normSpace(s.Before), 50), clip(s.Call, 50), s.Owner))
	}
	nextOf(&r, extractFunctionCommand(a), a, &out)
	if out.State == StateApplied {
		r.Done = fmt.Sprintf("done: %d sites → %s · check ok", len(plan.Sites), a.name)
		r.Next, r.NextWhy = "bin/fge refactor usages "+a.name, "出した def の呼ぶ所（索引は作り直しになる）"
		r.lines = nil
	}
	return r, idx, nil
}

func extractFunctionCommand(a args) string {
	cmd := "bin/fge refactor extract-function"
	if a.target != "" {
		cmd += " " + a.target
	} else {
		cmd += " --expr " + shellQuote(a.expr)
	}
	cmd += " --name " + a.name
	if a.to != "" {
		cmd += " --to " + a.to
	}
	if a.all {
		cmd += " --all"
	}
	if a.doc != "" {
		cmd += " --doc " + shellQuote(a.doc)
	}
	return cmd
}
