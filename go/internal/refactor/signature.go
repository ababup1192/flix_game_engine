package refactor

import (
	"fmt"
	"regexp"
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
	Prefer    bool     // --prefer-local: 同じ値と決められない時も、型が同じ局所の名前が 1 つならそれを書く
	// --propagate: 同じ回に引数を足す def → そこで束ねた扱いにする @名前（呼ぶ所の確かめで束ねていなくても通す）。
	Given    map[string][]string
	Stops    map[string]string            // --propagate で広げなかった def → 訳（その中の呼ぶ所の fix に書く）
	Provided map[string]map[string]string // --propagate: 型の値をもう持つ def → @名前 → 代わりに書く式（`env#res`）
	Renamed  map[string]map[string]string // --propagate: Provided のうち値が `_` の引数の def → 元の名前（`_res`）→ 替える名前
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
	UsesAdded []string     // 足す use（`Clock（fge::） → src/X.flix`）
	Unused    []string     // 本体が使わない新しい引数
	Unknown   []string     // --params の型の名前で、宣言のファイルで引けない物（`Res（src/Board.flix）`）
	Local     *localPicker // 呼ぶ所に書いた局所の名前の数（設計 §9）
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
	newTypes          []string          // --params で型を書いた引数の型の字（名前が引けるかの確かめ）
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
	return PlanSignatures(rows, srcs, []SignatureQuery{q})
}

// sigPart は PlanSignatures の 1 つの問いの下ごしらえ（引数の並びの違う def ごとに 1 つ）。
type sigPart struct {
	q                            SignatureQuery
	old, news                    []string
	locals                       []string
	callTemplates, bodyTemplates []string
	defs                         map[string]sigDef
	uses                         map[string]int
	fallback                     map[int]string // `@名前=式` の式（引数の番号 → 式。呼ぶ所に名前が無ければこれを書く）
	prefix                       int            // 先頭に足すだけの局所の名前（@名前）の数（後ろは元の引数がそのままの順。0 は違う形）
}

// PlanSignatures は幾つかの問いを 1 つの計画にまとめる（--propagate: 葉の def と、上へ引数を足す def）。
// 呼ぶ所を全部集めてから本体を見るので、ある def の本体の中の別の問いの呼ぶ所も、本体の確かめに入る。
// use を足す所はファイルと mod ごとに 1 つ（同じ型を 2 つの問いが足しても 1 回）。Old・New は最初の問いの物。
func PlanSignatures(rows []Row, srcs *reshapeSources, qs []SignatureQuery) (SignaturePlan, error) {
	p := SignaturePlan{CallFiles: map[string]int{}}
	ix := newSigIndex(rows)
	needs := map[string]*useNeed{}
	var needOrder []string
	var parts []*sigPart
	skip := map[string]bool{}
	for _, q := range qs {
		part, err := prepSignature(rows, srcs, q, needs, &needOrder)
		if err != nil {
			return p, err
		}
		parts = append(parts, part)
		for _, d := range q.Defs {
			skip[d] = true
		}
	}
	p.Old, p.New = parts[0].old, parts[0].news
	for _, part := range parts {
		for _, sym := range part.q.Defs {
			d := part.defs[sym]
			for _, typ := range d.newTypes {
				for _, x := range ix.unknownTypes(srcs, typ, d.row.File, modOf(sym)) {
					if w := x + "（" + d.row.File + "）"; indexOf(p.Unknown, w) < 0 {
						p.Unknown = append(p.Unknown, w)
					}
				}
			}
		}
	}
	p.Local = newLocalPicker(rows, srcs, qs[0].Prefer, skip)
	args := argRowsAt(rows)
	owners := ownerStarts(rows, srcs)
	var calls []Edit
	for _, part := range parts {
		c, err := planCalls(rows, srcs, part, &p, args, owners, needs, &needOrder)
		if err != nil {
			return p, err
		}
		calls = append(calls, c...)
	}
	// 宣言と本体。本体の中の呼ぶ所（再帰・--def の別の def・別の問いの def）は内側の書き換えとして先に当たる。
	edits := append([]Edit{}, calls...)
	for _, part := range parts {
		var removed []string
		keep := map[string]bool{}
		for _, n := range part.news {
			keep[n] = true
		}
		for _, n := range part.old {
			if !keep[n] {
				removed = append(removed, n)
			}
		}
		for _, sym := range part.q.Defs {
			d := part.defs[sym]
			src, _ := srcs.get(d.row.File)
			params := d.params
			edits = append(edits, Edit{File: d.row.File, Start: d.list.Args[0][0], End: d.list.Args[len(d.list.Args)-1][1], Site: d.row,
				Make: func(string) (string, error) { return params, nil }})
			sim, err := ApplyEdits(src[d.bodyStart:d.extEnd], shiftEdits(calls, d.row.File, d.bodyStart, d.extEnd))
			if err != nil {
				return p, err
			}
			rules, why := ix.bodyRules(srcs, sigTarget{file: d.row.File, mod: modOf(sym), types: d.types}, part.news, part.bodyTemplates, removed)
			if why != "" {
				p.Fix = append(p.Fix, Fixed{d.row, why})
				continue
			}
			after, lifted, left := liftBody(sim, rules, part.news, removed)
			if len(left) > 0 {
				p.Fix = append(p.Fix, Fixed{d.row, fmt.Sprintf("替えた後も本体が消える引数 %s を使う（%d か所。最初: `%s`）。--args の式（とその record の欄）と同じでない形。そこを引数から読む形に直すか、消える引数を残す",
					strings.Join(dedupe(left), "・"), len(left), firstLineAround(after, left[0], removed))})
				continue
			}
			for _, n := range part.news {
				if indexOf(part.old, n) < 0 && !strings.HasPrefix(n, "_") && len(identUses(after, map[string]bool{n: true})) == 0 && indexOf(p.Unused, n) < 0 {
					p.Unused = append(p.Unused, n)
				}
			}
			p.Lifted += lifted
			news, gone := part.news, removed
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
	}
	// --propagate で値を `_` の引数に持つ def は、その引数の名前を替える（引数は足さない）。問いは同じ表を分け合う。
	re, rs, err := renameParamEdits(rows, srcs, qs[0].Renamed)
	if err != nil {
		return p, err
	}
	edits = append(edits, re...)
	p.Sites = append(p.Sites, rs...)
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

// prepSignature は問い q の def の宣言を読み、新しい引数の並びと呼ぶ所・本体のテンプレートを作る。
func prepSignature(rows []Row, srcs *reshapeSources, q SignatureQuery, needs map[string]*useNeed, needOrder *[]string) (*sigPart, error) {
	part := &sigPart{q: q, defs: map[string]sigDef{}}
	newParams, err := splitTop(q.Params)
	if err != nil {
		return nil, fmt.Errorf("--params: %v", err)
	}
	if part.news, err = paramNames(newParams); err != nil {
		return nil, fmt.Errorf("--params: %v", err)
	}
	if len(q.Templates) != len(part.news) {
		return nil, fmt.Errorf("--args の式が %d 個・--params の引数が %d 個（同じ数に）", len(q.Templates), len(part.news))
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
	// `@名前` は呼ぶ所の局所の名前（let・case のパターン・lambda・def の引数で束ねた物）。呼ぶ所ではそのまま書き、
	// 呼ぶ所を囲む def の中で束ねていなければ fix。本体の中に同じ式は無いので、本体から引数へ移す式にはしない。
	// `@名前=式` は、呼ぶ所に名前が無ければ fix の代わりに式を書き（元の引数の名前が使える）、本体の中の同じ式を引数の名前に替える。
	part.fallback = map[int]string{}
	q.Templates = append([]string{}, q.Templates...)
	for i, t := range q.Templates {
		if m := localDefault.FindStringSubmatch(t); m != nil {
			part.fallback[i], q.Templates[i] = strings.TrimSpace(m[2]), "@"+m[1]
		}
	}
	part.q = q
	part.locals, part.callTemplates, part.bodyTemplates = localNames(q.Templates), make([]string, len(q.Templates)), make([]string, len(q.Templates))
	for i, t := range q.Templates {
		part.callTemplates[i] = localMark.ReplaceAllString(t, "$1")
		part.bodyTemplates[i] = t
		if localMark.MatchString(t) {
			part.bodyTemplates[i] = part.news[i]
		}
		if e, ok := part.fallback[i]; ok {
			part.bodyTemplates[i] = e
		}
	}
	for _, sym := range q.Defs {
		decl, src, list, params, err := readDefParams(rows, srcs, sym)
		if err != nil {
			return nil, err
		}
		_, nameEnd, _ := ByteRange(src, decl)
		old, err := paramNames(params)
		if err != nil {
			return nil, fmt.Errorf("%s: %v", decl.Where(), err)
		}
		if len(old) == 0 {
			return nil, fmt.Errorf("def %s に引数が無い（引数の無い def は扱わない）", sym)
		}
		if part.old == nil {
			part.old = old
		} else if strings.Join(old, ",") != strings.Join(part.old, ",") {
			return nil, fmt.Errorf("--def の def は同じ引数の名前が要る: %s は (%s)・前の def は (%s)", sym, strings.Join(old, ", "), strings.Join(part.old, ", "))
		}
		span, err := spanOf(decl.File, decl.Attr("ext"))
		if err != nil {
			return nil, err
		}
		_, extEnd, err := ByteRange(src, span)
		if err != nil {
			return nil, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", decl.Where())
		}
		body, ok := DefBodyStart(src, list.Close+1)
		if !ok || body > extEnd {
			return nil, fmt.Errorf("%s: def %s の本体の始まりが読めない", decl.Where(), sym)
		}
		items, err := expand(params)
		if err != nil {
			return nil, err
		}
		types := map[string]string{}
		var roots, newTypes []string
		for i, it := range items {
			n, typ, _ := strings.Cut(it, ":")
			types[strings.TrimSpace(n)] = strings.TrimSpace(typ)
			if strings.Contains(newParams[i], ":") {
				roots = append(roots, typeRoots(typ)...)
				newTypes = append(newTypes, strings.TrimSpace(typ))
			}
		}
		addNeed(needs, needOrder, decl.File, modOf(sym), nameEnd, decl, roots)
		part.defs[sym] = sigDef{row: decl, list: list, bodyStart: body, extEnd: extEnd, params: joinLayout(items, readLayout(src, list)), types: types, newTypes: newTypes}
	}
	for _, n := range part.locals {
		if indexOf(part.old, n) >= 0 {
			return nil, fmt.Errorf("--args の @%s は元の引数の名前と同じ（元の引数なら @ を外す）", n)
		}
	}
	part.uses = countUses(part.withFallback(part.callTemplates, nil), part.old)
	k := 0
	for k < len(part.news) && localMark.MatchString(q.Templates[k]) && strings.TrimSpace(localMark.ReplaceAllString(q.Templates[k], "")) == "" && indexOf(part.old, part.news[k]) < 0 {
		k++
	}
	if k > 0 && strings.Join(part.news[k:], ",") == strings.Join(part.old, ",") {
		part.prefix = k
	}
	return part, nil
}

// readDefParams は def sym の宣言の行・ファイルの中身・引数の並び・引数ごとの字（`w: World`）。
func readDefParams(rows []Row, srcs *reshapeSources, sym string) (Row, string, ArgList, []string, error) {
	var decl *Row
	for i := range rows {
		if rows[i].Kind == KindDefDecl && rows[i].Sym == sym {
			decl = &rows[i]
			break
		}
	}
	if decl == nil {
		return Row{}, "", ArgList{}, nil, fmt.Errorf("def %s の宣言が索引に無い（パッケージの def は直せない）", sym)
	}
	src, err := srcs.get(decl.File)
	if err != nil {
		return Row{}, "", ArgList{}, nil, err
	}
	_, nameEnd, err := ByteRange(src, *decl)
	if err != nil {
		return Row{}, "", ArgList{}, nil, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", decl.Where())
	}
	open := nameEnd
	if open < len(src) && src[open] == '[' {
		if _, at, err := scanTop(src, open+1, "]"); err == nil {
			open = at + 1
		}
	}
	list, has, err := argsAfter(src, open)
	if err != nil || !has {
		return Row{}, "", ArgList{}, nil, fmt.Errorf("%s: def %s の引数の並びが読めない", decl.Where(), sym)
	}
	var params []string
	for _, a := range list.Args {
		params = append(params, src[a[0]:a[1]])
	}
	return *decl, src, list, params, nil
}

// planCalls は問い part の def を呼ぶ所の書き換え（決められない所は p.Fix）。
func planCalls(rows []Row, srcs *reshapeSources, part *sigPart, p *SignaturePlan, args map[string]argInfo, owners map[string]int, needs map[string]*useNeed, needOrder *[]string) ([]Edit, error) {
	var calls []Edit
	for _, r := range rows {
		if r.Kind != KindDefUse || strings.Contains(r.Extra, "sugar") {
			continue
		}
		d, ok := part.defs[r.Sym]
		if !ok {
			continue
		}
		s, err := srcs.get(r.File)
		if err != nil {
			return nil, err
		}
		ns, ne, err := ByteRange(s, r)
		if err != nil {
			return nil, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", r.Where())
		}
		l, h, err := argsAfter(s, ne)
		info := args[argKey(KindDefUse, r)]
		// パイプ・部分適用・関数として渡す所: 先頭に局所の名前を足すだけなら、その名前を先頭へ書く（`x |> f(a)` → `x |> f(res, a)`・
		// `List.map(f, xs)` → `List.map(f(res), xs)`）。Flix の関数は前から部分適用できるので、後ろの引数の渡り方は変わらない。
		if err == nil && (info.Synth || !h || len(l.Args) < len(part.old)) && part.prefix > 0 {
			if e, why, ok := part.curriedEdit(rows, s, r, ns, ne, l, h, owners); ok {
				calls = append(calls, e)
				p.Sites = append(p.Sites, Fixed{r, why})
				p.Calls++
				p.CallFiles[r.File]++
				continue
			}
		}
		switch {
		case err != nil:
			p.Fix = append(p.Fix, Fixed{r, err.Error()})
			continue
		case info.Synth || !h:
			p.Fix = append(p.Fix, Fixed{r, "関数として渡している（引数を変えると型が変わる。lambda で包むかは人）"})
			continue
		case len(l.Args) != len(part.old) || info.N != len(l.Args):
			p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("引数の数 %d が宣言の %d と違う", len(l.Args), len(part.old))})
			continue
		}
		var bad []string
		for i, name := range part.old {
			v := s[l.Args[i][0]:l.Args[i][1]]
			switch {
			case part.uses[name] > 1 && !isSimple(v):
				bad = append(bad, name+" に `"+oneLine(v)+"`")
			case part.uses[name] == 0 && !isSimple(v):
				p.Dropped++
			}
		}
		if len(bad) > 0 {
			p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("--args が 2 回使う引数に式が渡っている: %s（2 回評価される。先に let で名前を付ける）", strings.Join(bad, "・"))})
			continue
		}
		callTemplates, filled := part.callTemplates, ""
		missing := withoutAll(unboundLocals(s, owners[r.Owner], ns, part.locals), part.q.Given[r.Owner])
		if hl := holeLambda(s, owners[r.Owner], ns); len(missing) > 0 && hl != "" {
			p.Fix = append(p.Fix, Fixed{r, holeWhy(missing, hl)})
			continue
		}
		var provided []string
		if pv := part.q.Provided[r.Owner]; len(missing) > 0 && len(pv) > 0 {
			var rest []string
			tm := append([]string{}, callTemplates...)
			for _, n := range missing {
				e, ok := pv[n]
				if !ok {
					rest = append(rest, n)
					continue
				}
				for i, t := range part.q.Templates {
					if t == "@"+n {
						tm[i] = e
					}
				}
				provided = append(provided, "@"+n+" の代わりに "+e)
			}
			callTemplates, missing = tm, rest
		}
		if len(missing) > 0 && part.hasFallback(missing) {
			callTemplates, filled, missing = part.withFallback(callTemplates, missing), "@"+strings.Join(missing, "・@"), nil
		}
		if len(missing) > 0 {
			why := fmt.Sprintf("呼ぶ所に局所の名前 %s が無い（呼ぶ所を囲む def の中で let・case のパターン・lambda・引数で束ねていない）", "@"+strings.Join(missing, "・@"))
			if stop := part.q.Stops[r.Owner]; stop != "" {
				why = fmt.Sprintf("呼ぶ所に局所の名前 %s が無く、囲む def へは広げない: %s", "@"+strings.Join(missing, "・@"), stop)
			}
			p.Fix = append(p.Fix, Fixed{r, why})
			continue
		}
		old, tmpl, lay := part.old, callTemplates, readLayout(s, l)
		if dm := modOf(r.Sym); modOf(r.Owner) != dm {
			tmpl = qualifyTemplates(callTemplates, dm, rows, append(append([]string{}, part.old...), part.locals...))
		}
		// 同じ値の局所の名前（設計 §9）。元の引数そのもの・@名前 の式は見ない。
		vals := make([]string, len(l.Args))
		for i, a := range l.Args {
			vals[i] = s[a[0]:a[1]]
		}
		picked := make([]string, len(tmpl))
		var pickedNames []string
		for i, t := range tmpl {
			if isIdent(strings.TrimSpace(callTemplates[i])) || (localMark.MatchString(part.q.Templates[i]) && (filled == "" || callTemplates[i] != part.fallback[i])) {
				continue
			}
			want := localWant{typ: d.types[part.news[i]], file: d.row.File, mod: modOf(r.Sym)}
			if n := p.Local.pick(r.Owner, r.File, ns, Substitute(strings.TrimSpace(t), old, vals), want); n != "" {
				picked[i] = n
				pickedNames = append(pickedNames, n)
			}
		}
		if modOf(r.Owner) != modOf(r.Sym) {
			var roots []string
			for i, t := range tmpl {
				if picked[i] == "" {
					roots = append(roots, exprRoots(t)...)
				}
			}
			addNeed(needs, needOrder, r.File, modOf(r.Owner), ns, r, roots)
		}
		calls = append(calls, Edit{File: r.File, Start: l.Args[0][0], End: l.Args[len(l.Args)-1][1], Site: r,
			Check: []Want{{Span: r, Text: s[ns:ne]}},
			Make:  func(cur string) (string, error) { return rewriteCallArgs(cur, old, tmpl, picked, lay) }})
		why := "呼ぶ所"
		if filled != "" {
			why += "（" + filled + " が無いので式を書く）"
		}
		if len(provided) > 0 {
			why += "（" + strings.Join(provided, "・") + "）"
		}
		if len(pickedNames) > 0 {
			why += "（局所の " + strings.Join(pickedNames, "・") + " を書く）"
		}
		p.Sites = append(p.Sites, Fixed{r, why})
		p.Calls++
		p.CallFiles[r.File]++
	}
	return calls, nil
}

// withoutAll は xs から drop の物を除いた列。
func withoutAll(xs, drop []string) []string {
	var out []string
	for _, x := range xs {
		if indexOf(drop, x) < 0 {
			out = append(out, x)
		}
	}
	return out
}

// localDefault は `@名前=式`（呼ぶ所に名前が無ければ式を書く）。`==` は比べる式なので当てない。
var localDefault = regexp.MustCompile(`^\s*@([A-Za-z_][A-Za-z0-9_]*)\s*=([^=>][\s\S]*)$`)

// hasFallback は names の局所の名前が全部 `@名前=式` の式を持つか。
func (part *sigPart) hasFallback(names []string) bool {
	for _, n := range names {
		found := false
		for i := range part.fallback {
			if part.q.Templates[i] == "@"+n {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// withFallback は呼ぶ所のテンプレート base のうち、名前 names（nil は全部）の `@名前=式` を式にした写し。
func (part *sigPart) withFallback(base, names []string) []string {
	out := append([]string{}, base...)
	for i, e := range part.fallback {
		if names == nil || indexOf(names, strings.TrimPrefix(part.q.Templates[i], "@")) >= 0 {
			out[i] = e
		}
	}
	return out
}

// localMark は --args の中の呼ぶ所の局所の名前（`@名前`）。
var localMark = regexp.MustCompile(`@([A-Za-z_][A-Za-z0-9_]*)`)

// localNames は templates に出る `@名前` の名前（出た順・重ねない）。
func localNames(templates []string) []string {
	var out []string
	for _, t := range templates {
		for _, m := range localMark.FindAllStringSubmatch(t, -1) {
			if indexOf(out, m[1]) < 0 {
				out = append(out, m[1])
			}
		}
	}
	return out
}

// ownerStarts は def の名前 → その def の書き出し（/// と注記の後ろの宣言の頭）のバイトの位置（呼ぶ所の束ねを探す頭）。
func ownerStarts(rows []Row, srcs *reshapeSources) map[string]int {
	out := map[string]int{}
	for _, r := range rows {
		if r.Kind != KindDefDecl {
			continue
		}
		src, err := srcs.get(r.File)
		if err != nil {
			continue
		}
		span, err := spanOf(r.File, r.Attr("ext"))
		if err != nil {
			continue
		}
		if start, _, err := ByteRange(src, span); err == nil {
			if _, ok := out[r.Sym]; !ok {
				out[r.Sym] = start
			}
		}
	}
	return out
}

// unboundLocals は names のうち、src の from〜to（呼ぶ所を囲む def の頭から呼ぶ所まで）で束ねていない物。
// 束ねの形: `let … name … =`・`case … name … =>`・`name ->`・`(…, name, …) ->`・`name: 型`（def の引数・注記）・`name <-`。
// WhyNot: 索引は局所の名前を持たないので字で探す。束ねていない所に名前を書けば確かめ（make check）が落ちて戻す。
func unboundLocals(src string, from, to int, names []string) []string {
	if from < 0 || from > to || to > len(src) {
		from = 0
	}
	text := src[from:to]
	var missing []string
	for _, n := range names {
		bound := false
		for _, loc := range bindingRe(n).FindAllStringIndex(text, -1) {
			// lambda の引数（`n ->`・`(…, n, …) ->`）は、呼ぶ所がその lambda の本体の中にある時だけ束ねている。
			// 前にある別の lambda（`(res, w) -> …` の後の `(_, w) -> f(w)`）の名前は、その外では使えない。
			if strings.HasSuffix(strings.TrimSpace(text[loc[0]:loc[1]]), "->") && !bodyReaches(text, loc[1], len(text)) {
				continue
			}
			bound = true
			break
		}
		if !bound {
			missing = append(missing, n)
		}
	}
	return missing
}

// bindingRe は name を束ねる形（unboundLocals の訳の形）に当たる正規表現。
func bindingRe(name string) *regexp.Regexp {
	q := regexp.QuoteMeta(name)
	return regexp.MustCompile(`\blet\s+[^=;]*\b` + q + `\b[^=;]*=|\bcase\b[^=\n]*\b` + q + `\b[^=\n]*=>|(?:^|[^\w.#])` + q +
		`\s*->|\([^()]*\b` + q + `\b[^()]*\)\s*->|\b` + q + `\s*:\s*[A-Za-z{(]|\b` + q + `\s*<-`)
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
// テンプレートで作り直す。picked[i] が空でなければ i 番目はその局所の名前（設計 §9）。
// 並びの改行の形（1 行・1 つずつ改行・決まった桁で折る）は元の並びの物（lay）を写す。
func rewriteCallArgs(cur string, old, templates, picked []string, lay argLayout) (string, error) {
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
		if i < len(picked) && picked[i] != "" {
			items[i] = picked[i]
		}
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
	templates, err := splitTop(a.argsText)
	if err != nil {
		return report{}, fmt.Errorf("--args: %v", err)
	}
	q := SignatureQuery{Params: strings.TrimSpace(a.params), Templates: templates, Prefer: a.preferLocal}
	for _, d := range strings.Split(a.def, ",") {
		sym, err := Resolve(idx.Rows, strings.TrimSpace(d), map[string]bool{KindDefDecl: true})
		if err != nil {
			return report{}, err
		}
		q.Defs = append(q.Defs, sym)
	}
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	var pr propagation
	var plan SignaturePlan
	if a.propagate {
		stop := map[string]bool{}
		for _, d := range strings.Split(a.stopAt, ",") {
			if d = strings.TrimSpace(d); d == "" {
				continue
			}
			sym, err := Resolve(idx.Rows, d, map[string]bool{KindDefDecl: true})
			if err != nil {
				return report{}, fmt.Errorf("--stop-at: %v", err)
			}
			stop[sym] = true
		}
		depth := a.depth
		if depth == 0 {
			depth = defaultPropagateDepth
		}
		if pr, err = planPropagation(idx.Rows, srcs, q, stop, depth); err != nil {
			return report{}, err
		}
		plan, err = PlanSignatures(idx.Rows, srcs, pr.Queries)
	} else {
		plan, err = PlanSignature(idx.Rows, srcs, q)
	}
	if err != nil {
		return report{}, err
	}
	// --propagate で葉の本体が足す引数を使わなければ、上の段は通っても葉が Flix の「使わない引数」で落ちる（_ で始める
	// 名前は上の段で使えない）。check を流す前に止める。
	if a.propagate {
		for _, n := range localNames(templates) {
			if indexOf(plan.Unused, n) < 0 {
				continue
			}
			for _, sym := range q.Defs {
				if decl, _, _, _, err := readDefParams(idx.Rows, srcs, sym); err == nil {
					plan.Fix = append(plan.Fix, Fixed{decl, fmt.Sprintf("葉の本体が %s を使わない（Flix は使わない引数を誤りにし、_%s は上の段で使えない）。--args を @%s=<本体の中の式> にして本体の式を %s に替えるか、先に本体を %s の元の式で書く", n, n, n, n, n)})
				}
			}
		}
	}
	how := a.applyWith(cfg.Verify, o)
	if len(plan.Fix) > 0 {
		how.On = false
	}
	out := Change(root, plan.Edits, how)
	if a.apply && len(plan.Fix) > 0 {
		out.State, out.Reason = StateRefused, fmt.Sprintf("人へ回す所 %d（書くと型が合わない。直してから --apply）", len(plan.Fix))
	}
	decls := len(q.Defs) + len(pr.Lifted)
	r := report{Op: "change-signature", Target: a.def + "（(" + strings.Join(plan.Old, ", ") + ") → (" + strings.Join(plan.New, ", ") + ")）", code: CodeSignature, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = plan.Calls + decls
	}
	r.Sites = plan.Sites
	r.gotText = fmt.Sprintf("宣言 %d・呼ぶ所 %d（%d ファイル）・本体から引数へ移す式 %d・人へ回す %d", decls, plan.Calls, len(plan.CallFiles), plan.Lifted, len(plan.Fix))
	note := "（" + strings.Join(plan.Old, "・") + " はその所の式"
	if ls := localNames(templates); len(ls) > 0 {
		note += "・@" + strings.Join(ls, "・@") + " は呼ぶ所の局所の名前"
	}
	r.extra = append(r.extra, "呼ぶ所の引数: "+strings.Join(templates, ", ")+note+"）")
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
	// 型の名前の警告と --propagate の行は注の頭へ（注は数行で切れて残りは -v）。
	var head []string
	if len(plan.Unknown) > 0 {
		head = append(head, fmt.Sprintf("警告: --params の型の名前 %s が引けない（標準の型・同じ mod の宣言・use・プロジェクトの型のどれでもない。--apply の check で落ちる。修飾を足すか、use の出どころを確かめる）", strings.Join(plan.Unknown, "・")))
	}
	if a.propagate {
		head = append(head, propagateNotes(pr)...)
	}
	r.extra = append(head, r.extra...)
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", s.Where(), s.Why, s.Owner))
	}
	base := fmt.Sprintf("bin/fge refactor change-signature --def %s --params %s --args %s", a.def, shellQuote(q.Params), shellQuote(a.argsText)) + preferFlag(a) + propagateFlags(a)
	nextOf(&r, base, a, &out)
	switch {
	case len(plan.Fix) > 0:
		r.fixHint = "fix の所を手で直す（関数として渡す所は lambda で包む・本体に残る消える引数は引数から読む形に）か、索引に合う形にしてから"
		r.Next, r.NextWhy = base, "fix の所を直してから dry-run から（fix が 0 になれば --apply）"
	case out.State == StateApplied:
		r.Done = fmt.Sprintf("done: %d sites（宣言 %d・呼ぶ所 %d）→ 0 left · check ok", plan.Calls+decls, decls, plan.Calls)
		r.Next, r.NextWhy = "bin/fge refactor usages "+strings.Split(a.def, ",")[0]+" --callers", "替えた後の呼び手（索引は作り直しになる）"
		r.lines = nil
	}
	localNotes(&r, plan.Local)
	return r, nil
}

// curriedEdit は、パイプ（書いていない引数がある）・部分適用（引数が宣言より少ない）・関数として渡す所（括弧が無い）の呼ぶ所に、
// 先頭の新しい引数（局所の名前・型の値を持つ def の式・元の引数を使わない `@名前=式` の式）を書く書き換え。書けなければ ok=false。
func (part *sigPart) curriedEdit(rows []Row, s string, r Row, ns, ne int, l ArgList, h bool, owners map[string]int) (Edit, string, bool) {
	missing := withoutAll(unboundLocals(s, owners[r.Owner], ns, part.locals), part.q.Given[r.Owner])
	oldSet := map[string]bool{}
	if len(missing) > 0 && holeLambda(s, owners[r.Owner], ns) != "" {
		return Edit{}, "", false
	}
	for _, o := range part.old {
		oldSet[o] = true
	}
	var texts []string
	for i := 0; i < part.prefix; i++ {
		n := strings.TrimPrefix(strings.TrimSpace(part.q.Templates[i]), "@")
		switch {
		case indexOf(missing, n) < 0:
			texts = append(texts, n)
		case part.q.Provided[r.Owner][n] != "":
			texts = append(texts, part.q.Provided[r.Owner][n])
		case part.fallback[i] != "" && len(identUses(part.fallback[i], oldSet)) == 0:
			e := part.fallback[i]
			if dm := modOf(r.Sym); modOf(r.Owner) != dm {
				e = qualifyTemplates([]string{e}, dm, rows, nil)[0]
			}
			texts = append(texts, e)
		default:
			return Edit{}, "", false
		}
	}
	add := strings.Join(texts, ", ")
	check := []Want{{Span: r, Text: s[ns:ne]}}
	if !h {
		return Edit{File: r.File, Start: ne, End: ne, Site: r, Check: check,
			Make: func(string) (string, error) { return "(" + add + ")", nil }}, "関数として渡す所（先頭の引数 " + add + " を部分適用で書く）", true
	}
	at, text := l.Open+1, add
	if len(l.Args) > 0 {
		at, text = l.Args[0][0], add+", "
	}
	return Edit{File: r.File, Start: at, End: at, Site: r, Check: check,
		Make: func(string) (string, error) { return text, nil }}, "パイプ・部分適用の呼ぶ所（先頭に " + add + " を書く）", true
}

// bodyReaches は text の body（lambda の `->` の後ろ）から始まる本体が at まで続くか。本体は、閉じていない `)`・`]`・`}` か、
// 括弧の外の `,`（lambda を引数に渡した時の次の引数）で終わる。
func bodyReaches(text string, body, at int) bool {
	depth := 0
	for i := body; i < at && i < len(text); i++ {
		switch text[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
			if depth < 0 {
				return false
			}
		case ',':
			if depth == 0 {
				return false
			}
		case '"':
			for i++; i < at && text[i] != '"'; i++ {
				if text[i] == '\\' {
					i++
				}
			}
		}
	}
	return true
}

// lambdaHead は lambda の引数の並び（`(_, w) ->`・`_ ->`）。
var lambdaHead = regexp.MustCompile(`\(([^()]*)\)\s*->|(?:^|[^\w.#])(_)\s*->`)

// holeLambda は src の from〜at（呼ぶ所を囲む def の頭から呼ぶ所まで）で、呼ぶ所を囲む lambda のうち引数に `_` を持つ物の
// 引数の並び（無ければ ""）。`Resources.read((_, w) -> …)` の `_` に足す引数の値が来ることが多いが、どの `_` かは型を見ないと
// 決まらないので、道具は替えずに人へ回す。
func holeLambda(src string, from, at int) string {
	if from < 0 || from > at || at > len(src) {
		from = 0
	}
	text := src[from:at]
	for _, m := range lambdaHead.FindAllStringSubmatchIndex(text, -1) {
		params := ""
		switch {
		case m[2] >= 0:
			params = text[m[2]:m[3]]
		case m[4] >= 0:
			params = "_"
		}
		hole := false
		for _, p := range strings.Split(params, ",") {
			if n, _, _ := strings.Cut(p, ":"); strings.TrimSpace(n) == "_" {
				hole = true
			}
		}
		if hole && bodyReaches(text, m[1], len(text)) {
			return "(" + strings.TrimSpace(params) + ") ->"
		}
	}
	return ""
}

// holeWhy は呼ぶ所を囲む lambda の引数に `_` がある時の fix の訳。
func holeWhy(missing []string, head string) string {
	n := "@" + strings.Join(missing, "・@")
	return fmt.Sprintf("呼ぶ所に局所の名前 %s が無く、囲む lambda %s の引数に _ がある（%s の値が入る所なら _ を %s に替えてから流し直す。"+
		"道具はどの _ かを決めない・囲む def へも広げない）", n, head, n, strings.Join(missing, "・"))
}
