package refactor

import (
	"fmt"
	"sort"
	"strings"
)

// change-signature --propagate: 葉の def に足す引数を `--args '@res, w'` の形で呼ぶ所の局所の名前にした時、呼ぶ所を囲む
// def が @res を束ねていなければ、その def にも同じ引数（`res: 型`）を足し、その def を呼ぶ所へも同じ見方で上へ広げる
// （Change Signature の Propagate。IntelliJ の「呼び手へ広げる」と同じ）。葉と広げた def を 1 つの計画にまとめ、
// make check は 1 回（落ちれば全部戻す）。
//
// 足す位置: 葉の --params で @res の引数が先頭なら広げる def でも先頭、でなければ末尾。呼ぶ所には res をそのまま渡す。
// 止める所（広げずに、その中の呼ぶ所を fix へ）: --stop-at で名指しした def・main と @Test の def・引数の無い def・
// 同じ型の別の名前の引数を持つ def（その名前で --args を書き直す）・--depth（既定 8）を超える段・宣言が索引に無い物。
// 関数として渡す所（App の口に渡す def など）は広げても型が合わないので、今までどおり fix。

const defaultPropagateDepth = 8

// liftedDef は --propagate で引数を足す def の 1 つ。
type liftedDef struct {
	Sym   string
	Depth int      // 葉から何段上か（1 が葉を呼ぶ def）
	Names []string // 足す引数の名前
	Calls int      // この def を呼ぶ所の数
}

// propagation は --propagate の計画の下ごしらえ。
type propagation struct {
	Queries []SignatureQuery // 葉の問いと、広げる def ごとの問い
	Lifted  []liftedDef
	Stops   map[string]string // 広げなかった def → 訳
	// 型の値をもう持つ def → 局所の名前 → 呼ぶ所に書く式（同じ型の引数 `r`・その record の欄 `env#res`）。広げない。
	Provided map[string]map[string]string
}

// planPropagation は葉の問い leaf（--args に @名前 を持つ）から、上へ引数を足す def を幅優先で集める。
func planPropagation(rows []Row, srcs *reshapeSources, leaf SignatureQuery, stopAt map[string]bool, maxDepth int) (propagation, error) {
	pr := propagation{Stops: map[string]string{}, Provided: map[string]map[string]string{}}
	part, err := prepSignature(rows, srcs, leaf, map[string]*useNeed{}, new([]string))
	if err != nil {
		return pr, err
	}
	if len(part.locals) == 0 {
		return pr, fmt.Errorf("--propagate は --args に呼ぶ所の局所の名前（@名前）がある時だけ（例 --args '@res, w'）")
	}
	// 局所の名前ごとの型の字と、足す位置（先頭か末尾）。
	types, front := map[string]string{}, map[string]bool{}
	first := part.defs[leaf.Defs[0]]
	for _, n := range part.locals {
		k := -1
		for i, t := range part.q.Templates {
			if strings.TrimSpace(t) == "@"+n {
				k = i
			}
		}
		if k < 0 || first.types[part.news[k]] == "" {
			return pr, fmt.Errorf("--propagate は @%s を 1 つの引数にそのまま書き（--args の 1 つが `@%s`）、--params でその引数に型を書く時だけ", n, n)
		}
		if part.news[k] != n {
			return pr, fmt.Errorf("--propagate は @%s を同じ名前の引数へ渡す時だけ（--params の %d 番目は %s。上の def に足す引数の名前が決まらない）", n, k+1, part.news[k])
		}
		types[n], front[n] = first.types[part.news[k]], k == 0
	}
	// `@名前=式` の式が使う元の引数の名前と型。広げる def が同じ名前・同じ型の引数を持てば、その段でも式を書ける。
	fallbacks := map[string]string{}
	fallbackNeeds := map[string]map[string]string{}
	oldSet := map[string]bool{}
	for _, o := range part.old {
		oldSet[o] = true
	}
	for k, e := range part.fallback {
		n := strings.TrimPrefix(part.q.Templates[k], "@")
		needs := map[string]string{}
		for _, at := range identUses(e, oldSet) {
			needs[e[at[0]:at[1]]] = first.types[e[at[0]:at[1]]]
		}
		fallbacks[n], fallbackNeeds[n] = e, needs
	}
	given := map[string][]string{}
	for _, d := range leaf.Defs {
		given[d] = part.locals
	}
	owners := ownerStarts(rows, srcs)
	args := argRowsAt(rows)
	callsTo := map[string][]Row{}
	for _, r := range rows {
		if r.Kind == KindDefUse && !strings.Contains(r.Extra, "sugar") {
			callsTo[r.Sym] = append(callsTo[r.Sym], r)
		}
	}
	depth := map[string]int{}
	type item struct {
		sym   string
		depth int
	}
	queue := []item{}
	for _, d := range leaf.Defs {
		queue = append(queue, item{d, 0})
	}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		names := given[cur.sym]
		for _, r := range callsTo[cur.sym] {
			s, err := srcs.get(r.File)
			if err != nil {
				return pr, err
			}
			ns, ne, err := ByteRange(s, r)
			if err != nil {
				return pr, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", r.Where())
			}
			if _, h, err := argsAfter(s, ne); err != nil || !h || args[argKey(KindDefUse, r)].Synth {
				continue // 関数として渡す所は計画の方で fix
			}
			o := r.Owner
			missing := withoutAll(unboundLocals(s, owners[o], ns, names), given[o])
			missing = withoutKeys(missing, pr.Provided[o])
			if len(missing) == 0 || pr.Stops[o] != "" {
				continue
			}
			if !stopAt[o] {
				if got := provideFor(rows, srcs, o, missing, types); len(got) == len(missing) {
					if pr.Provided[o] == nil {
						pr.Provided[o] = map[string]string{}
					}
					for k, v := range got {
						pr.Provided[o][k] = v
					}
					continue
				}
			}
			if why := stopReason(rows, srcs, o, missing, types, stopAt, cur.depth+1, maxDepth); why != "" {
				pr.Stops[o] = why
				continue
			}
			if _, seen := depth[o]; !seen {
				depth[o] = cur.depth + 1
			}
			given[o] = append(given[o], missing...)
			queue = append(queue, item{o, cur.depth + 1})
		}
	}
	for sym, d := range depth {
		pr.Lifted = append(pr.Lifted, liftedDef{Sym: sym, Depth: d, Names: given[sym], Calls: len(callsTo[sym])})
	}
	sort.Slice(pr.Lifted, func(i, j int) bool {
		if pr.Lifted[i].Depth != pr.Lifted[j].Depth {
			return pr.Lifted[i].Depth < pr.Lifted[j].Depth
		}
		return pr.Lifted[i].Sym < pr.Lifted[j].Sym
	})
	leaf.Given, leaf.Stops, leaf.Provided = given, pr.Stops, pr.Provided
	pr.Queries = append(pr.Queries, leaf)
	for _, l := range pr.Lifted {
		_, _, _, params, err := readDefParams(rows, srcs, l.Sym)
		if err != nil {
			return pr, err
		}
		olds, err := paramNames(params)
		if err != nil {
			return pr, err
		}
		ptypes := map[string]string{}
		for _, p := range params {
			if n, t, ok := strings.Cut(p, ":"); ok {
				ptypes[strings.TrimSpace(n)] = strings.TrimSpace(t)
			}
		}
		mark := func(n string) string {
			e, ok := fallbacks[n]
			if !ok {
				return "@" + n
			}
			for u, t := range fallbackNeeds[n] {
				if t == "" || !sameTypeText(ptypes[u], t) {
					return "@" + n
				}
			}
			return "@" + n + "=" + e
		}
		var head, tail, headT, tailT []string
		for _, n := range l.Names {
			if front[n] {
				head, headT = append(head, n+": "+types[n]), append(headT, mark(n))
			} else {
				tail, tailT = append(tail, n+": "+types[n]), append(tailT, mark(n))
			}
		}
		ps := append(append(head, olds...), tail...)
		ts := append(append(headT, olds...), tailT...)
		pr.Queries = append(pr.Queries, SignatureQuery{Defs: []string{l.Sym}, Params: strings.Join(ps, ", "), Templates: ts, Prefer: leaf.Prefer, Given: given, Stops: pr.Stops, Provided: pr.Provided})
	}
	return pr, nil
}

// stopReason は def o へ引数 missing を広げない訳（広げるなら ""）。
func stopReason(rows []Row, srcs *reshapeSources, o string, missing []string, types map[string]string, stopAt map[string]bool, depth, maxDepth int) string {
	if stopAt[o] {
		return "--stop-at で名指しした def"
	}
	if shortName(o) == "main" {
		return "main（App の入口）"
	}
	if depth > maxDepth {
		return fmt.Sprintf("--depth %d を超える段", maxDepth)
	}
	decl, _, _, params, err := readDefParams(rows, srcs, o)
	if err != nil {
		return "宣言が読めない（" + err.Error() + "）"
	}
	if strings.Contains(decl.Attr("ann"), "test") {
		return "@Test の def（テストは引数を取れない）"
	}
	if len(params) == 0 {
		return "引数の無い def（呼ぶ所が多い入口のことが多い。足すかは人）"
	}
	if ret := returnType(rows, srcs, o); strings.Contains(ret, "App[") {
		return "App の口（戻り値が App。描く元は App の w から渡す）"
	}
	return ""
}

// propagateNotes は --propagate の報告の行（広げた def を深さの順に・止めた def を訳の種類ごとに）。
func propagateNotes(pr propagation) []string {
	var out []string
	if len(pr.Lifted) == 0 {
		out = append(out, "上へ広げた def 0")
	} else {
		var names []string
		for _, l := range pr.Lifted {
			names = append(names, fmt.Sprintf("%s（深さ %d・呼ぶ所 %d）", l.Sym, l.Depth, l.Calls))
		}
		out = append(out, fmt.Sprintf("上へ広げた def %d・深さの最大 %d: %s", len(pr.Lifted), pr.Lifted[len(pr.Lifted)-1].Depth, strings.Join(names, "・")))
	}
	if len(pr.Provided) > 0 {
		var xs []string
		for _, o := range sortedKeys(pr.Provided) {
			for _, n := range sortedKeys(pr.Provided[o]) {
				xs = append(xs, o+" → "+pr.Provided[o][n])
			}
		}
		out = append(out, fmt.Sprintf("型の値をもう持つ def %d（広げずに呼ぶ所へその式を書く）: %s", len(pr.Provided), strings.Join(xs, "・")))
	}
	if len(pr.Stops) > 0 {
		kinds := map[string]int{}
		for _, why := range pr.Stops {
			k, _, _ := strings.Cut(why, "（")
			kinds[k]++
		}
		var parts []string
		for _, k := range sortedKeys(kinds) {
			parts = append(parts, fmt.Sprintf("%s %d", k, kinds[k]))
		}
		out = append(out, fmt.Sprintf("広げずに止めた def %d（中の呼ぶ所は fix。@名前=式 なら葉を直に呼ぶ所は式を書く）: %s", len(pr.Stops), strings.Join(parts, "・")))
	}
	return out
}

// propagateFlags は次の手の行に写す --propagate の旗。
func propagateFlags(a args) string {
	if !a.propagate {
		return ""
	}
	s := " --propagate"
	if a.stopAt != "" {
		s += " --stop-at " + a.stopAt
	}
	if a.depth > 0 {
		s += fmt.Sprintf(" --depth %d", a.depth)
	}
	return s
}

// provideFor は def o の引数から、局所の名前 missing の型の値を読む式（同じ型の引数ならその名前・引数の型が record の
// alias で、その欄の型が同じなら `引数#欄`）。読めた名前だけを返す。
func provideFor(rows []Row, srcs *reshapeSources, o string, missing []string, types map[string]string) map[string]string {
	_, _, _, params, err := readDefParams(rows, srcs, o)
	if err != nil {
		return nil
	}
	out := map[string]string{}
	for _, m := range missing {
		for _, p := range params {
			n, t, ok := strings.Cut(p, ":")
			if !ok {
				continue
			}
			n, t = strings.TrimSpace(n), strings.TrimSpace(t)
			if sameTypeText(t, types[m]) {
				out[m] = n
				break
			}
			if f := fieldOfType(rows, srcs, t, types[m]); f != "" {
				out[m] = n + "#" + f
				break
			}
		}
	}
	return out
}

// sameTypeText は 2 つの型の字が同じ型を指すと見てよいか（字が同じか、型引数の無い名前で最後の区切りが同じ）。
func sameTypeText(a, b string) bool {
	if a == b {
		return true
	}
	if strings.ContainsAny(a+b, "[{(") {
		return false
	}
	return shortName(a) == shortName(b)
}

// fieldOfType は型の字 typ が record の alias なら、型が want の欄の名前（1 つだけの時。無ければ ""）。
func fieldOfType(rows []Row, srcs *reshapeSources, typ, want string) string {
	if strings.ContainsAny(typ, "[{(") {
		return ""
	}
	for _, r := range rows {
		if r.Kind != KindAliasDecl || shortName(r.Sym) != shortName(typ) || !(r.Sym == typ || strings.HasSuffix(r.Sym, "."+typ) || !strings.Contains(typ, ".")) {
			continue
		}
		src, err := srcs.get(r.File)
		if err != nil {
			continue
		}
		m := map[string]string{r.File: src}
		shape, err := FindAliasShape(m, r.Sym)
		if err != nil {
			continue
		}
		var hits []string
		for _, f := range shape.Fields {
			if sameTypeText(fieldTypeOf(m, shape, f), want) {
				hits = append(hits, f)
			}
		}
		if len(hits) == 1 {
			return hits[0]
		}
	}
	return ""
}

// returnType は def sym の宣言の戻り値の型の字（引数の並びの後ろから本体の前まで）。
func returnType(rows []Row, srcs *reshapeSources, sym string) string {
	decl, src, list, _, err := readDefParams(rows, srcs, sym)
	if err != nil {
		return ""
	}
	span, err := spanOf(decl.File, decl.Attr("ext"))
	if err != nil {
		return ""
	}
	_, extEnd, err := ByteRange(src, span)
	if err != nil {
		return ""
	}
	if body, ok := DefBodyStart(src, list.Close+1); ok && body <= extEnd {
		return src[list.Close+1 : body]
	}
	return ""
}

// withoutKeys は xs から m の鍵を除いた列。
func withoutKeys(xs []string, m map[string]string) []string {
	var out []string
	for _, x := range xs {
		if _, ok := m[x]; !ok {
			out = append(out, x)
		}
	}
	return out
}
