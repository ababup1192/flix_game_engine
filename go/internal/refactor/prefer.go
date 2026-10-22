package refactor

import (
	"fmt"
	"regexp"
	"strings"
)

// 呼ぶ所・作る所に式を書く操作（change-signature の --args・change-case-shape と fix-construction・add-field の --value）が
// 共有する所: 書こうとした式と同じ値の局所の名前が、書く所にすでにあればそれを書く（設計 §9）。
//
// 「同じ」と決める形は 2 つ（どちらも式が効果のある def・索引で引けない def を呼べば外す。評価の回数が変わるため）:
//  1. let: 書く所を囲む def の本体で、書く所より前の `let x = E;`（E は書こうとした式と字が同じ。空白・use の別名・
//     同じ mod の素の名前は respell で同じに見る）。let の後から書く所まで括弧の外へ出ず・match の腕を越えず、
//     x と E の名前を束ね直していない。
//  2. 引数: 書く所を囲む def D の引数 p。E の名前が全部 D の引数で、D を呼ぶ所が 1 つ以上・全部が引数の並びで呼び、
//     p の位置に「E の D の引数をその所の式にした物」を渡している（D の中の再帰は p と E の名前をそのまま渡す物だけ）。
//
// 同じと決められない時は式のまま書き、型が同じ局所の名前（D の引数・型を注記した let）を候補として数える。
// 型は索引の type-use の行（引数の型の名前の sym）から取り、無ければ型の字を use・alias-decl・enum-decl で解決して比べる。
// prefer（--prefer-local）なら候補が 1 つの所だけそれを書く。
//
// WhyNot: let・引数の束ねは索引に無いので字で読む（unboundLocals と同じ）。読み違いは確かめの口（make check）で止まって戻る。

// localWant は書く値の型の字と、その字を書いた所（型の名前を解決する）。typ が空なら候補を探さない。
type localWant struct {
	typ, file, mod string
}

// localPicker は 1 回の操作の中で、書く所ごとに局所の名前を選ぶ（数も持つ）。
type localPicker struct {
	ix       *sigIndex
	srcs     *reshapeSources
	prefer   bool
	skip     map[string]bool  // 見ない def（change-signature で引数の並びが変わる def）
	calls    map[string][]Row // def → 呼ぶ所（def-use）
	types    map[string][]Row // ファイル → type-use の行
	declared map[string]bool  // alias-decl・enum-decl の sym
	args     map[string]argInfo
	scopes   map[string]*ownerScope
	passes   map[string]int // owner + 式 → 呼ぶ所が全部その式を渡す引数の番号（-1 は無し）

	Same      int // 同じ値と決まって局所の名前を書いた所
	Preferred int // --prefer-local で候補を書いた所（同じ値かは確かめていない）
	Cands     int // 候補があるが式のまま書いた所（--prefer-local で使える）
	Ambiguous int // --prefer-local でも候補が 2 つ以上で式のまま書いた所
}

type ownerParam struct{ name, typ string }

// ownerScope は書く所を囲む def（引数の名前と型・本体の始まり）。
type ownerScope struct {
	file, mod, src string
	params         []ownerParam
	body           int
	ok             bool
}

func newLocalPicker(rows []Row, srcs *reshapeSources, prefer bool, skip map[string]bool) *localPicker {
	lp := &localPicker{ix: newSigIndex(rows), srcs: srcs, prefer: prefer, skip: skip, calls: map[string][]Row{}, types: map[string][]Row{},
		declared: map[string]bool{}, args: argRowsAt(rows), scopes: map[string]*ownerScope{}, passes: map[string]int{}}
	for _, r := range rows {
		switch r.Kind {
		case KindDefUse:
			if !strings.Contains(r.Extra, "sugar") {
				lp.calls[r.Sym] = append(lp.calls[r.Sym], r)
			}
		case KindTypeUse:
			lp.types[r.File] = append(lp.types[r.File], r)
		case KindAliasDecl, KindEnumDecl:
			lp.declared[r.Sym] = true
		}
	}
	return lp
}

var simpleTypeName = regexp.MustCompile(`^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$`)

// resolveType は (file, mod) で書いた型の字を比べられる形にする: 名前だけの型は sym へ（use の別名・同じ mod・
// 宣言の sym）、型引数などのある型は空白を除いた字。
func (lp *localPicker) resolveType(file, mod, text string) string {
	t := strings.Join(strings.Fields(text), "")
	if !simpleTypeName.MatchString(t) {
		return t
	}
	if lp.declared[t] {
		return t
	}
	if lp.declared[mod+"."+t] {
		return mod + "." + t
	}
	first, rest, _ := strings.Cut(t, ".")
	for _, u := range lp.ix.uses[file] {
		if u.Owner != mod {
			continue
		}
		switch {
		case u.alias == t:
			return u.Sym
		case u.alias == first && rest != "":
			return u.Sym + "." + rest
		}
	}
	return t
}

// typeAt は src[s:e] に書いた型の比べられる形。名前だけの型で索引の type-use の行が 1 つ当たれば、その sym。
func (lp *localPicker) typeAt(file, mod, src string, s, e int) string {
	text := strings.TrimSpace(src[s:e])
	if simpleTypeName.MatchString(text) {
		var hit []string
		for _, r := range lp.types[file] {
			if b, _, err := ByteRange(src, r); err == nil && b >= s && b < e {
				hit = append(hit, r.Sym)
			}
		}
		if len(hit) == 1 {
			return hit[0]
		}
	}
	return lp.resolveType(file, mod, text)
}

// scopeOf は def sym の引数（名前と型）と本体の始まり。読めなければ ok=false。
func (lp *localPicker) scopeOf(sym string) *ownerScope {
	if sc, ok := lp.scopes[sym]; ok {
		return sc
	}
	sc := &ownerScope{}
	lp.scopes[sym] = sc
	r, ok := lp.ix.defs[sym]
	if !ok {
		return sc
	}
	src, err := lp.srcs.get(r.File)
	if err != nil {
		return sc
	}
	_, nameEnd, err := ByteRange(src, r)
	if err != nil {
		return sc
	}
	open := nameEnd
	if open < len(src) && src[open] == '[' {
		if _, at, err := scanTop(src, open+1, "]"); err == nil {
			open = at + 1
		}
	}
	list, has, err := argsAfter(src, open)
	if err != nil || !has {
		return sc
	}
	body, ok := DefBodyStart(src, list.Close+1)
	if !ok {
		return sc
	}
	sc.file, sc.mod, sc.src, sc.body = r.File, modOf(sym), src, body
	for _, a := range list.Args {
		name, _, found := strings.Cut(src[a[0]:a[1]], ":")
		name = strings.TrimSpace(name)
		if !isIdent(name) {
			return sc
		}
		p := ownerParam{name: name}
		if found {
			colon := a[0] + strings.IndexByte(src[a[0]:a[1]], ':')
			p.typ = lp.typeAt(r.File, sc.mod, src, colon+1, a[1])
		}
		sc.params = append(sc.params, p)
	}
	sc.ok = true
	return sc
}

// pick は owner の中の at（file のバイト）に式 expr を書く時、代わりに書く局所の名前（無ければ ""）。
func (lp *localPicker) pick(owner, file string, at int, expr string, want localWant) string {
	expr = strings.TrimSpace(expr)
	if lp == nil || expr == "" || isIdent(expr) || lp.skip[owner] {
		return ""
	}
	sc := lp.scopeOf(owner)
	if !sc.ok || sc.file != file || at < sc.body || at > len(sc.src) {
		return ""
	}
	before := sc.src[sc.body:at]
	free := freeNames(expr)
	if lp.pure(expr, file, sc.mod) {
		// _ で始まる名前は選ばない（Flix は _ の名前を使うと誤りにする: Hidden variable symbol）。
		if name := lp.sameLet(sc, at, expr, free); name != "" && !strings.HasPrefix(name, "_") {
			lp.Same++
			return name
		}
		if name := lp.sameParam(owner, sc, before, expr, free); name != "" && !strings.HasPrefix(name, "_") {
			lp.Same++
			return name
		}
	}
	if want.typ == "" {
		return ""
	}
	wt := lp.resolveType(want.file, want.mod, want.typ)
	var cands []string
	for _, p := range sc.params {
		if p.typ == wt && !strings.HasPrefix(p.name, "_") && !rebinds(before, p.name) {
			cands = append(cands, p.name)
		}
	}
	for _, l := range lets(sc, at) {
		if l.typ == wt && !strings.HasPrefix(l.name, "_") && indexOf(cands, l.name) < 0 && inScope(sc.src, l.end, at) && !bindsAny(sc.src[l.end:at], []string{l.name}) {
			cands = append(cands, l.name)
		}
	}
	switch {
	case len(cands) == 0:
		return ""
	case lp.prefer && len(cands) == 1:
		lp.Preferred++
		return cands[0]
	case lp.prefer:
		lp.Ambiguous++
	default:
		lp.Cands++
	}
	return ""
}

// letBind は本体の `let x = v;`・`let x: T = v;` 1 つ（v の範囲と `;` の次・型の比べられる形）。
type letBind struct {
	name, typ    string
	vStart, vEnd int
	end          int
}

var letHead = regexp.MustCompile(`\blet\s+([a-z_][A-Za-z0-9_]*)\s*(:)?`)

// lets は sc の本体の at より前で終わる let（書いた順）。
func lets(sc *ownerScope, at int) []letBind {
	var out []letBind
	for _, m := range letHead.FindAllStringSubmatchIndex(sc.src[sc.body:at], -1) {
		b := letBind{name: sc.src[sc.body+m[2] : sc.body+m[3]]}
		eq := sc.body + m[1]
		if m[4] >= 0 {
			stop, e, err := scanTop(sc.src, eq, "=;")
			if err != nil || stop != '=' {
				continue
			}
			b.typ = strings.TrimSpace(sc.src[eq:e])
			eq = e
		} else if eq >= len(sc.src) || sc.src[eq] != '=' {
			continue
		}
		if eq+1 < len(sc.src) && (sc.src[eq+1] == '=' || sc.src[eq+1] == '>') {
			continue
		}
		stop, semi, err := scanTop(sc.src, eq+1, ";")
		if err != nil || stop != ';' || semi >= at {
			continue
		}
		b.vStart, b.vEnd, b.end = eq+1, semi, semi+1
		out = append(out, b)
	}
	return out
}

// sameLet は at より前の let のうち、値が expr と同じで at まで届く物の名前（近い物を選ぶ）。
func (lp *localPicker) sameLet(sc *ownerScope, at int, expr string, free []string) string {
	spells := lp.ix.respell(expr, sc.file, sc.mod, sc.file, sc.mod)
	if len(spells) == 0 {
		spells = []string{expr}
	}
	found := ""
	for _, l := range lets(sc, at) {
		v := squash(sc.src[l.vStart:l.vEnd])
		same := false
		for _, s := range spells {
			if squash(s) == v {
				same = true
			}
		}
		if same && inScope(sc.src, l.end, at) && !bindsAny(sc.src[l.end:at], append([]string{l.name}, free...)) {
			found = l.name
		}
	}
	return found
}

// sameParam は owner の引数のうち、owner を呼ぶ所が全部 expr を渡している物の名前。
func (lp *localPicker) sameParam(owner string, sc *ownerScope, before, expr string, free []string) string {
	var names []string
	for _, p := range sc.params {
		names = append(names, p.name)
	}
	for _, f := range free {
		if indexOf(names, f) < 0 {
			return ""
		}
	}
	if bindsAny(before, free) {
		return ""
	}
	key := owner + "\x00" + expr
	i, ok := lp.passes[key]
	if !ok {
		i = lp.passedEverywhere(owner, sc, names, expr, free)
		lp.passes[key] = i
	}
	if i < 0 || bindsAny(before, []string{names[i]}) {
		return ""
	}
	return names[i]
}

// passedEverywhere は owner を呼ぶ所が全部、同じ番号の引数に expr（owner の引数をその所の式にした物）を渡すなら
// その番号。呼ぶ所が無い・関数として渡す所がある・引数の数が違えば -1。
func (lp *localPicker) passedEverywhere(owner string, sc *ownerScope, names []string, expr string, free []string) int {
	calls := lp.calls[owner]
	if len(calls) == 0 {
		return -1
	}
	cand := make([]bool, len(names))
	for i := range cand {
		cand[i] = indexOf(free, names[i]) < 0
	}
	for _, c := range calls {
		s, err := lp.srcs.get(c.File)
		if err != nil {
			return -1
		}
		_, ne, err := ByteRange(s, c)
		if err != nil {
			return -1
		}
		l, has, err := argsAfter(s, ne)
		if err != nil || !has || lp.args[argKey(KindDefUse, c)].Synth || len(l.Args) != len(names) {
			return -1
		}
		vals := make([]string, len(l.Args))
		for i, a := range l.Args {
			vals[i] = s[a[0]:a[1]]
		}
		if c.Owner == owner {
			// 再帰: p と E の名前をそのまま渡す物だけ（p の値は呼ばれた時と同じ）。
			for _, f := range free {
				if strings.TrimSpace(vals[indexOf(names, f)]) != f {
					return -1
				}
			}
			for i := range cand {
				cand[i] = cand[i] && strings.TrimSpace(vals[i]) == names[i]
			}
			continue
		}
		spells := lp.ix.respell(expr, sc.file, sc.mod, c.File, modOf(c.Owner))
		if len(spells) == 0 {
			return -1
		}
		for i := range cand {
			if !cand[i] {
				continue
			}
			got, same := squash(vals[i]), false
			for _, sp := range spells {
				if squash(Substitute(sp, names, vals)) == got {
					same = true
				}
			}
			cand[i] = same
		}
	}
	for i, ok := range cand {
		if ok {
			return i
		}
	}
	return -1
}

// pure は式が呼ぶ物が全部、索引で引けて効果の注記の無い def か、case を作る物（頭の最後が大文字）か。
func (lp *localPicker) pure(expr, file, mod string) bool {
	for _, h := range heads(expr) {
		head := expr[h[0]:h[1]]
		if last := shortName(head); last != "" && last[0] >= 'A' && last[0] <= 'Z' {
			continue
		}
		sym := lp.ix.headSym(head, file, mod)
		if sym == "" {
			return false
		}
		if d, ok := lp.ix.shapeOf(lp.srcs, sym); !ok || d.effect {
			return false
		}
	}
	return true
}

var lowerWord = regexp.MustCompile(`[a-z_][A-Za-z0-9_]*`)

// freeNames は式が名前として使う小文字の名前（修飾・選択の後ろ・欄の名前・語は除く）。
func freeNames(expr string) []string {
	names := map[string]bool{}
	for _, w := range lowerWord.FindAllString(expr, -1) {
		if !keywords[w] && w != "true" && w != "false" {
			names[w] = true
		}
	}
	var out []string
	for _, u := range identUses(expr, names) {
		if w := expr[u[0]:u[1]]; indexOf(out, w) < 0 {
			out = append(out, w)
		}
	}
	return out
}

// squash は式を比べる形（空白を除く）。
func squash(s string) string { return strings.Join(strings.Fields(s), "") }

// bindsAny は text が names のどれかを束ねるか（let・case のパターン・lambda・`<-`。unboundLocals と同じ形）。
func bindsAny(text string, names []string) bool {
	for _, n := range names {
		if bindingRe(n).MatchString(text) {
			return true
		}
	}
	return false
}

// inScope は src[from:to] が括弧の外へ出ず、深さ 0 で match の腕（`case`）を越えないか（from の束ねが to まで届く）。
func inScope(src string, from, to int) bool {
	depth := 0
	for i := from; i < to && i < len(src); i++ {
		c := src[i]
		switch {
		case c == '"':
			j := i + 1
			for j < to && src[j] != '"' {
				if src[j] == '\\' {
					j++
				}
				j++
			}
			i = j
		case c == '/' && i+1 < to && src[i+1] == '/':
			for i < to && src[i] != '\n' {
				i++
			}
		case c == '(' || c == '[' || c == '{':
			depth++
		case c == ')' || c == ']' || c == '}':
			depth--
			if depth < 0 {
				return false
			}
		case depth == 0 && identByte(c) && (i == 0 || !identByte(src[i-1])):
			j := i
			for j < len(src) && identByte(src[j]) {
				j++
			}
			if src[i:j] == "case" {
				return false
			}
			i = j - 1
		}
	}
	return true
}

// localNotes は局所の名前を書いた数・候補の数を報告の注の頭に足す（注の数の上限で切られないよう）。
// 候補の 1 行は、done の行があればその後に出す。
func localNotes(r *report, lp *localPicker) {
	if lp == nil {
		return
	}
	var notes []string
	if lp.Cands > 0 {
		line := fmt.Sprintf("局所の候補あり %d か所（--prefer-local で使う）", lp.Cands)
		if r.Done != "" {
			r.Done += "\n" + line
		} else {
			notes = append(notes, line)
		}
	}
	if lp.Same > 0 {
		notes = append(notes, fmt.Sprintf("局所の名前を書く %d か所（書こうとした式と同じ値と決まった let・引数）", lp.Same))
	}
	if lp.Preferred > 0 {
		notes = append(notes, fmt.Sprintf("--prefer-local で局所の候補を書く %d か所（型が同じ物 1 つ・同じ値かは確かめていない）", lp.Preferred))
	}
	if lp.Ambiguous > 0 {
		notes = append(notes, fmt.Sprintf("局所の候補が 2 つ以上で式のまま %d か所", lp.Ambiguous))
	}
	r.extra = append(notes, r.extra...)
}

// preferFlag は next の行に写す --prefer-local。
func preferFlag(a args) string {
	if a.preferLocal {
		return " --prefer-local"
	}
	return ""
}
