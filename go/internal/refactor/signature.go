package refactor

import (
	"fmt"
	"strings"
)

// change-signature: def の引数の並びを --params の並びに替え、呼ぶ所の引数を --args のテンプレートで作り直す。
// 足す・消す・並べ替える・型を替えるのどれも同じ 1 つの形で書く:
//
//	--params 'env: ViewEnv.Env, input: XScene.In'     新しい引数の並び（宣言にそのまま書く）
//	--args   'ViewEnv.of(ctx, w), XScene.inputOf(w)'  新しい引数ごとの式。元の引数の名前（ctx・w）が使え、呼ぶ所では
//	                                                  その所の引数の式に置き換わる（式が名前より大きければ括弧で包む）
//
// 本体（Introduce Parameter と Extract Variable）: 本体の中の --args の式は、let に置いた物もあちこちに書いた物も
// 新しい引数の名前に替え、`let env = env;` になった行は消す。同じ式は字（空白は問わない）か索引の def（mod の中の素の名前・
// use の別名）で当て、式の def の本体が record の式なら欄の式も引数から読む（`ctx#atlas` → `env#ctx#atlas`・
// `w#theme` → `env#res#theme`。sigprep.go）。替えた後も本体が消える引数（ctx・w）を使うなら書かずに止める。
// 宣言と呼ぶ所の並びは元の改行の形（1 行・1 つずつ改行・決まった桁で折る）を写し、新しい引数の型と呼ぶ所の式の名前が
// そのファイルで引けなければ use を足す（出どころは索引の use の行から）。
//
// 人へ回す所（fix）: 関数として渡す所（`List.map(f(ctx), xs)`・`f` だけ。lambda で包むかは人）・引数の数が違う・
// 2 回以上使う元の引数に、名前・字の値でない式が渡っている（2 回評価される。先に let で名前を付ける）・
// 効果のある def を呼ぶ --args の式（評価の回数と順が変わる）。
// fix が 1 つでもあれば書かない（書くと型が合わない）。--def a,b は同じ引数の名前を持つ def を 1 回で替える。

// SignatureQuery は change-signature の問い。
type SignatureQuery struct {
	Defs      []string // 索引の def の名前（解決済み）
	Params    string   // 新しい引数の並び（宣言の字）
	Templates []string // 新しい引数ごとの式
}

// SignaturePlan は change-signature の計画。
type SignaturePlan struct {
	Edits     []Edit
	Sites     []Fixed
	Fix       []Fixed
	Old, New  []string // 元の・新しい引数の名前
	Calls     int
	Lifted    int // 本体から引数へ移した式の数
	Dropped   int // 捨てた引数の式のうち、名前・字の値でない物
	CallFiles map[string]int
	UsesAdded []string // 足す use（`Clock（fge::） → src/X.flix`）
	Unused    []string // 本体が使わない新しい引数
}

// paramNames は `a: T, b: U` の名前の列。
func paramNames(params []string) ([]string, error) {
	var out []string
	for _, p := range params {
		name, _, _ := strings.Cut(p, ":")
		name = strings.TrimSpace(name)
		if !isIdent(name) {
			return nil, fmt.Errorf("引数 %q が `名前: 型`（か、元の引数をそのまま残す `名前`）でない", p)
		}
		out = append(out, name)
	}
	return out, nil
}

type sigDef struct {
	row               Row
	list              ArgList
	bodyStart, extEnd int
	params            string            // 宣言に書く新しい引数の並び（型の無い名前を元の引数で埋めた物）
	types             map[string]string // 新しい引数の名前 → 型の字
}

// useNeed は 1 つのファイルの 1 つの mod で、名前の解決に要る頭（use を足すかを決める）。
type useNeed struct {
	file, mod string
	before    int
	names     []string
	site      Row
}

func addNeed(needs map[string]*useNeed, order *[]string, file, mod string, at int, site Row, names []string) {
	k := file + "\x00" + mod
	n, ok := needs[k]
	if !ok {
		n = &useNeed{file: file, mod: mod, before: at, site: site}
		needs[k] = n
		*order = append(*order, k)
	}
	if at < n.before {
		n.before = at
	}
	for _, x := range names {
		if indexOf(n.names, x) < 0 {
			n.names = append(n.names, x)
		}
	}
}

// PlanSignature は q の def の引数の並びと、呼ぶ所を替える計画。
func PlanSignature(rows []Row, srcs *reshapeSources, q SignatureQuery) (SignaturePlan, error) {
	p := SignaturePlan{CallFiles: map[string]int{}}
	newParams, err := splitTop(q.Params)
	if err != nil {
		return p, fmt.Errorf("--params: %v", err)
	}
	if p.New, err = paramNames(newParams); err != nil {
		return p, fmt.Errorf("--params: %v", err)
	}
	if len(q.Templates) != len(p.New) {
		return p, fmt.Errorf("--args の式が %d 個・--params の引数が %d 個（同じ数に）", len(q.Templates), len(p.New))
	}
	// 型の無い名前（`card`）は、その def の元の引数をそのまま残す（宣言の字を写す）。
	expand := func(params []string) ([]string, error) {
		var out []string
		for _, e := range newParams {
			if strings.Contains(e, ":") {
				out = append(out, e)
				continue
			}
			found := ""
			for _, o := range params {
				if n, _, _ := strings.Cut(o, ":"); strings.TrimSpace(n) == e {
					found = o
				}
			}
			if found == "" {
				return nil, fmt.Errorf("--params の %s に型が無く、元の引数にも無い（`%s: 型` と書く）", e, e)
			}
			out = append(out, found)
		}
		return out, nil
	}
	ix := newSigIndex(rows)
	needs := map[string]*useNeed{}
	var needOrder []string
	defs := map[string]sigDef{}
	for _, sym := range q.Defs {
		var decl *Row
		for i := range rows {
			if rows[i].Kind == KindDefDecl && rows[i].Sym == sym {
				decl = &rows[i]
				break
			}
		}
		if decl == nil {
			return p, fmt.Errorf("def %s の宣言が索引に無い（パッケージの def は直せない）", sym)
		}
		src, err := srcs.get(decl.File)
		if err != nil {
			return p, err
		}
		_, nameEnd, err := ByteRange(src, *decl)
		if err != nil {
			return p, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", decl.Where())
		}
		open := nameEnd
		if open < len(src) && src[open] == '[' {
			if _, at, err := scanTop(src, open+1, "]"); err == nil {
				open = at + 1
			}
		}
		list, has, err := argsAfter(src, open)
		if err != nil || !has {
			return p, fmt.Errorf("%s: def %s の引数の並びが読めない", decl.Where(), sym)
		}
		var params []string
		for _, a := range list.Args {
			params = append(params, src[a[0]:a[1]])
		}
		old, err := paramNames(params)
		if err != nil {
			return p, fmt.Errorf("%s: %v", decl.Where(), err)
		}
		if len(old) == 0 {
			return p, fmt.Errorf("def %s に引数が無い（引数の無い def は扱わない）", sym)
		}
		if p.Old == nil {
			p.Old = old
		} else if strings.Join(old, ",") != strings.Join(p.Old, ",") {
			return p, fmt.Errorf("--def の def は同じ引数の名前が要る: %s は (%s)・前の def は (%s)", sym, strings.Join(old, ", "), strings.Join(p.Old, ", "))
		}
		span, err := spanOf(decl.File, decl.Attr("ext"))
		if err != nil {
			return p, err
		}
		_, extEnd, err := ByteRange(src, span)
		if err != nil {
			return p, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", decl.Where())
		}
		body, ok := DefBodyStart(src, list.Close+1)
		if !ok || body > extEnd {
			return p, fmt.Errorf("%s: def %s の本体の始まりが読めない", decl.Where(), sym)
		}
		items, err := expand(params)
		if err != nil {
			return p, err
		}
		types := map[string]string{}
		var roots []string
		for i, it := range items {
			n, typ, _ := strings.Cut(it, ":")
			types[strings.TrimSpace(n)] = strings.TrimSpace(typ)
			if strings.Contains(newParams[i], ":") {
				roots = append(roots, typeRoots(typ)...)
			}
		}
		addNeed(needs, &needOrder, decl.File, modOf(sym), nameEnd, *decl, roots)
		defs[sym] = sigDef{row: *decl, list: list, bodyStart: body, extEnd: extEnd, params: joinLayout(items, readLayout(src, list)), types: types}
	}
	uses := countUses(q.Templates, p.Old)
	args := argRowsAt(rows)
	var calls []Edit
	for _, r := range rows {
		if r.Kind != KindDefUse || strings.Contains(r.Extra, "sugar") {
			continue
		}
		if _, ok := defs[r.Sym]; !ok {
			continue
		}
		s, err := srcs.get(r.File)
		if err != nil {
			return p, err
		}
		ns, ne, err := ByteRange(s, r)
		if err != nil {
			return p, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", r.Where())
		}
		l, h, err := argsAfter(s, ne)
		info := args[argKey(KindDefUse, r)]
		switch {
		case err != nil:
			p.Fix = append(p.Fix, Fixed{r, err.Error()})
			continue
		case info.Synth || !h:
			p.Fix = append(p.Fix, Fixed{r, "関数として渡している（引数を変えると型が変わる。lambda で包むかは人）"})
			continue
		case len(l.Args) != len(p.Old) || info.N != len(l.Args):
			p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("引数の数 %d が宣言の %d と違う", len(l.Args), len(p.Old))})
			continue
		}
		var bad []string
		for i, name := range p.Old {
			v := s[l.Args[i][0]:l.Args[i][1]]
			switch {
			case uses[name] > 1 && !isSimple(v):
				bad = append(bad, name+" に `"+oneLine(v)+"`")
			case uses[name] == 0 && !isSimple(v):
				p.Dropped++
			}
		}
		if len(bad) > 0 {
			p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("--args が 2 回使う引数に式が渡っている: %s（2 回評価される。先に let で名前を付ける）", strings.Join(bad, "・"))})
			continue
		}
		old, tmpl, lay := p.Old, q.Templates, readLayout(s, l)
		if dm := modOf(r.Sym); modOf(r.Owner) != dm {
			tmpl = qualifyTemplates(q.Templates, dm, rows, p.Old)
			var roots []string
			for _, t := range tmpl {
				roots = append(roots, exprRoots(t)...)
			}
			addNeed(needs, &needOrder, r.File, modOf(r.Owner), ns, r, roots)
		}
		calls = append(calls, Edit{File: r.File, Start: l.Args[0][0], End: l.Args[len(l.Args)-1][1], Site: r,
			Check: []Want{{Span: r, Text: s[ns:ne]}},
			Make:  func(cur string) (string, error) { return rewriteCallArgs(cur, old, tmpl, lay) }})
		p.Sites = append(p.Sites, Fixed{r, "呼ぶ所"})
		p.Calls++
		p.CallFiles[r.File]++
	}
	// 宣言と本体。本体の中の呼ぶ所（再帰・--def の別の def）は内側の書き換えとして先に当たる。
	var removed []string
	keep := map[string]bool{}
	for _, n := range p.New {
		keep[n] = true
	}
	for _, n := range p.Old {
		if !keep[n] {
			removed = append(removed, n)
		}
	}
	edits := append([]Edit{}, calls...)
	for _, sym := range q.Defs {
		d := defs[sym]
		src, _ := srcs.get(d.row.File)
		params := d.params
		edits = append(edits, Edit{File: d.row.File, Start: d.list.Args[0][0], End: d.list.Args[len(d.list.Args)-1][1], Site: d.row,
			Make: func(string) (string, error) { return params, nil }})
		sim, err := ApplyEdits(src[d.bodyStart:d.extEnd], shiftEdits(calls, d.row.File, d.bodyStart, d.extEnd))
		if err != nil {
			return p, err
		}
		rules, why := ix.bodyRules(srcs, sigTarget{file: d.row.File, mod: modOf(sym), types: d.types}, p.New, q.Templates, removed)
		if why != "" {
			p.Fix = append(p.Fix, Fixed{d.row, why})
			continue
		}
		after, lifted, left := liftBody(sim, rules, p.New, removed)
		if len(left) > 0 {
			p.Fix = append(p.Fix, Fixed{d.row, fmt.Sprintf("替えた後も本体が消える引数 %s を使う（%d か所。最初: `%s`）。--args の式（とその record の欄）と同じでない形。そこを引数から読む形に直すか、消える引数を残す",
				strings.Join(dedupe(left), "・"), len(left), firstLineAround(after, left[0], removed))})
			continue
		}
		for _, n := range p.New {
			if indexOf(p.Old, n) < 0 && !strings.HasPrefix(n, "_") && len(identUses(after, map[string]bool{n: true})) == 0 && indexOf(p.Unused, n) < 0 {
				p.Unused = append(p.Unused, n)
			}
		}
		p.Lifted += lifted
		news, gone := p.New, removed
		edits = append(edits, Edit{File: d.row.File, Start: d.bodyStart, End: d.extEnd, Site: d.row,
			Make: func(cur string) (string, error) {
				out, _, left := liftBody(cur, rules, news, gone)
				if len(left) > 0 {
					return "", fmt.Errorf("本体が消える引数 %s を使う", strings.Join(left, "・"))
				}
				return out, nil
			}})
		p.Sites = append([]Fixed{{d.row, "宣言と本体"}}, p.Sites...)
	}
	// 新しい引数の型（宣言のファイル）と呼ぶ所の式（def の mod の外のファイル）の名前を引く use。
	for _, k := range needOrder {
		n := needs[k]
		ue, notes := ix.useEdits(srcs, n.file, n.mod, n.before, n.names, n.site)
		edits = append(edits, ue...)
		for _, x := range notes {
			p.UsesAdded = append(p.UsesAdded, x+" → "+n.file)
		}
	}
	p.Edits = edits
	p.Fix = sortedFixed(p.Fix)
	return p, nil
}

// qualifyTemplates は、テンプレートの中の素の名前の呼び出し（`envOf(…)`）のうち mod の def を指す物を `mod.envOf` にした写し
// （def の mod の外の呼ぶ所では素の名前が解けないため）。元の引数の名前・修飾の付いた名前はそのまま。
func qualifyTemplates(templates []string, mod string, rows []Row, old []string) []string {
	names := map[string]bool{}
	for _, r := range rows {
		if r.Kind == KindDefDecl && modOf(r.Sym) == mod {
			names[shortName(r.Sym)] = true
		}
	}
	for _, o := range old {
		delete(names, o)
	}
	out := make([]string, len(templates))
	for i, t := range templates {
		uses := identUses(t, names)
		for k := len(uses) - 1; k >= 0; k-- {
			u := uses[k]
			if j := skipSpace(t, u[1]); j < len(t) && t[j] == '(' {
				t = t[:u[0]] + mod + "." + t[u[0]:]
			}
		}
		out[i] = t
	}
	return out
}

// liftBody は本体 body に置き換え（--args の式とその record の欄の式 → 引数の名前・欄の選択。bodyRules）を当て、
// `let x = x;` を消す。返すのは替えた本体・替えた数・それでも残る消える引数の名前（使う所の数だけ並ぶ）。
func liftBody(body string, rules []liftRule, news, removed []string) (string, int, []string) {
	body, n := applyRules(body, rules, removed)
	body = dropSelfLets(body, news)
	names := map[string]bool{}
	for _, r := range removed {
		names[r] = true
	}
	var left []string
	for _, u := range identUses(body, names) {
		left = append(left, body[u[0]:u[1]])
	}
	return body, n, left
}

// firstLineAround は本体の中で name を最初に使う行（報告用）。
func firstLineAround(body, name string, removed []string) string {
	names := map[string]bool{}
	for _, r := range removed {
		names[r] = true
	}
	for _, u := range identUses(body, names) {
		ls := strings.LastIndexByte(body[:u[0]], '\n') + 1
		le := strings.IndexByte(body[u[0]:], '\n')
		if le < 0 {
			le = len(body) - u[0]
		}
		return oneLine(body[ls : u[0]+le])
	}
	return name
}

// rewriteCallArgs は呼ぶ所の引数の並びの字（最初の引数の頭〜最後の引数の終わり。内側の書き換えを当てた後）を、
// テンプレートで作り直す。並びの改行の形（1 行・1 つずつ改行・決まった桁で折る）は元の並びの物（lay）を写す。
func rewriteCallArgs(cur string, old, templates []string, lay argLayout) (string, error) {
	l, _, err := argsAfter("("+cur+")", 0)
	if err != nil {
		return "", err
	}
	text := "(" + cur + ")"
	if len(l.Args) != len(old) {
		return "", fmt.Errorf("引数の数 %d が宣言の %d と違う（索引が古い）", len(l.Args), len(old))
	}
	vals := make([]string, len(l.Args))
	for i, a := range l.Args {
		vals[i] = text[a[0]:a[1]]
	}
	items := make([]string, len(templates))
	for i, t := range templates {
		items[i] = Substitute(strings.TrimSpace(t), old, vals)
	}
	return joinLayout(items, lay), nil
}

func dedupe(xs []string) []string {
	var out []string
	for _, x := range xs {
		if indexOf(out, x) < 0 {
			out = append(out, x)
		}
	}
	return out
}

func indexOf(xs []string, x string) int {
	for i, v := range xs {
		if v == x {
			return i
		}
	}
	return -1
}

// signatureReport は change-signature の入口。
func signatureReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	if !idx.hasAdds(KindArg) {
		return report{}, fmt.Errorf("索引に arg の行が無い（flixlint %s 以上が要る。--flixlint か FGE_FLIXLINT で名指しして bin/fge refactor index --rebuild）", MinFlixlintArgs)
	}
	templates, err := splitTop(a.argsText)
	if err != nil {
		return report{}, fmt.Errorf("--args: %v", err)
	}
	q := SignatureQuery{Params: strings.TrimSpace(a.params), Templates: templates}
	for _, d := range strings.Split(a.def, ",") {
		sym, err := Resolve(idx.Rows, strings.TrimSpace(d), map[string]bool{KindDefDecl: true})
		if err != nil {
			return report{}, err
		}
		q.Defs = append(q.Defs, sym)
	}
	plan, err := PlanSignature(idx.Rows, &reshapeSources{root: root, m: map[string]string{}}, q)
	if err != nil {
		return report{}, err
	}
	how := a.applyWith(cfg.Verify, o)
	if len(plan.Fix) > 0 {
		how.On = false
	}
	out := Change(root, plan.Edits, how)
	if a.apply && len(plan.Fix) > 0 {
		out.State, out.Reason = StateRefused, fmt.Sprintf("人へ回す所 %d（書くと型が合わない。直してから --apply）", len(plan.Fix))
	}
	r := report{Op: "change-signature", Target: a.def + "（(" + strings.Join(plan.Old, ", ") + ") → (" + strings.Join(plan.New, ", ") + ")）", code: CodeSignature, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = plan.Calls + len(q.Defs)
	}
	r.Sites = plan.Sites
	r.gotText = fmt.Sprintf("宣言 %d・呼ぶ所 %d（%d ファイル）・本体から引数へ移す式 %d・人へ回す %d", len(q.Defs), plan.Calls, len(plan.CallFiles), plan.Lifted, len(plan.Fix))
	r.extra = append(r.extra, "呼ぶ所の引数: "+strings.Join(templates, ", ")+"（"+strings.Join(plan.Old, "・")+" はその所の式）")
	if plan.Dropped > 0 {
		r.extra = append(r.extra, fmt.Sprintf("捨てる引数の式のうち名前・字の値でない物 %d（副作用があれば手で）", plan.Dropped))
	}
	if len(plan.UsesAdded) > 0 {
		r.extra = append(r.extra, "use を足す: "+strings.Join(plan.UsesAdded, "・"))
	}
	if len(plan.Unused) > 0 {
		r.extra = append(r.extra, fmt.Sprintf("本体が使わない新しい引数 %s（Flix は使わない引数を誤りにする。_ で始めるか本体で使う）", strings.Join(plan.Unused, "・")))
	}
	r.wantText = "宣言と呼ぶ所の引数が --params の並び（決められない所は fix。fix があれば書かない）"
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", s.Where(), s.Why, s.Owner))
	}
	base := fmt.Sprintf("bin/fge refactor change-signature --def %s --params %s --args %s", a.def, shellQuote(q.Params), shellQuote(a.argsText))
	nextOf(&r, base, a, &out)
	switch {
	case len(plan.Fix) > 0:
		r.fixHint = "fix の所を手で直す（関数として渡す所は lambda で包む・本体に残る消える引数は引数から読む形に）か、索引に合う形にしてから"
		r.Next, r.NextWhy = base, "fix の所を直してから dry-run から（fix が 0 になれば --apply）"
	case out.State == StateApplied:
		r.Done = fmt.Sprintf("done: %d sites（宣言 %d・呼ぶ所 %d）→ 0 left · check ok", plan.Calls+len(q.Defs), len(q.Defs), plan.Calls)
		r.Next, r.NextWhy = "bin/fge refactor usages "+strings.Split(a.def, ",")[0]+" --callers", "替えた後の呼び手（索引は作り直しになる）"
		r.lines = nil
	}
	return r, nil
}
