package refactor

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

// change-signature の下ごしらえ（Extract Variable）・引数の並びの改行の形・新しい引数の型の use。
//
// 下ごしらえ: 本体の中で --args の式と同じ物を新しい引数の名前に替える。「同じ」は 2 つの意味で見る。
//   - 字が同じ（空白は問わない）か、呼ぶ def が索引で同じ物（`ViewEnv.of`・mod の中の素の `of`・use の別名 `V.of`）。
//   - 式の def の本体が record の式（`{ ctx = ctx, res = resOf(w), … }`）なら、その欄の式も引数から読める物になる:
//     `ctx` → `env#ctx`・`ViewEnv.resOf(w)` → `env#res`・さらに resOf の欄 `w#theme` → `env#res#theme`（3 段まで）。
//     効果のある def（宣言に `\`）の本体は読まない（2 回書くのと 1 回で同じ値と言えない）。
// 置き換えられない形（式の一部だけが同じ・本体が消える引数を束ね直す）は替えず、消える引数が残れば人へ回す。
// 効果のある def を呼ぶ --args の式は人へ回す（本体の中から呼ぶ所へ移すと、評価の回数と順が変わる）。
//
// ここの関数は純粋（ファイルの中身は呼ぶ側が渡す）。

// sigIndex は change-signature が引く索引の表（def の宣言・ファイルごとの use・プロジェクトの根の mod）。
type sigIndex struct {
	defs  map[string]Row      // def-decl の sym → 行
	decls map[string][]string // 型の短い名前 → alias-decl・enum-decl の sym
	uses  map[string][]useRow // ファイル → use の行
	roots map[string]bool     // プロジェクトの根の mod の名前（どこからでも修飾で引ける）
}

type useRow struct {
	Row
	alias string
}

func newSigIndex(rows []Row) *sigIndex {
	ix := &sigIndex{defs: map[string]Row{}, decls: map[string][]string{}, uses: map[string][]useRow{}, roots: map[string]bool{}}
	for _, r := range rows {
		switch r.Kind {
		case KindDefDecl:
			if _, ok := ix.defs[r.Sym]; !ok {
				ix.defs[r.Sym] = r
			}
		case KindAliasDecl, KindEnumDecl:
			ix.decls[shortName(r.Sym)] = append(ix.decls[shortName(r.Sym)], r.Sym)
		case "use":
			if a := r.Attr("alias"); a != "" {
				ix.uses[r.File] = append(ix.uses[r.File], useRow{r, a})
			}
			continue
		default:
			continue
		}
		if i := strings.IndexByte(r.Sym, '.'); i > 0 {
			ix.roots[r.Sym[:i]] = true
		}
	}
	return ix
}

// headSym は (file, mod) で書いた呼ぶ所の頭 head（`ViewEnv.of`・`of`・`V.of`）の sym。決まらなければ ""。
func (ix *sigIndex) headSym(head, file, mod string) string {
	if _, ok := ix.defs[head]; ok {
		return head
	}
	if _, ok := ix.defs[mod+"."+head]; ok {
		return mod + "." + head
	}
	first, rest, _ := strings.Cut(head, ".")
	for _, u := range ix.uses[file] {
		if u.Owner != mod {
			continue
		}
		switch {
		case u.alias == head:
			return u.Sym
		case u.alias == first && rest != "":
			return u.Sym + "." + rest
		}
	}
	return ""
}

// spellings は sym を (file, mod) で書く書き方（修飾した名前・同じ mod の素の名前・use の別名から）。
func (ix *sigIndex) spellings(sym, file, mod string) []string {
	var out []string
	add := func(s string) {
		for _, o := range out {
			if o == s {
				return
			}
		}
		out = append(out, s)
	}
	if i := strings.IndexByte(sym, '.'); i > 0 && ix.roots[sym[:i]] {
		add(sym)
	}
	if modOf(sym) == mod {
		add(shortName(sym))
	}
	for _, u := range ix.uses[file] {
		if u.Owner != mod {
			continue
		}
		switch {
		case sym == u.Sym:
			add(u.alias)
		case strings.HasPrefix(sym, u.Sym+"."):
			add(u.alias + sym[len(u.Sym):])
		}
	}
	return out
}

var callHead = regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*`)

// heads は式の中の呼ぶ所の頭（名前の後が `(`。修飾・選択の後ろは除く）の [始まり, 終わり)。
func heads(e string) [][2]int {
	var out [][2]int
	for _, m := range callHead.FindAllStringIndex(e, -1) {
		if m[0] > 0 && (e[m[0]-1] == '#' || identByte(e[m[0]-1])) {
			continue
		}
		if j := skipSpace(e, m[1]); j < len(e) && e[j] == '(' {
			out = append(out, [2]int{m[0], m[1]})
		}
	}
	return out
}

// respell は (fromFile, fromMod) で書いた式 e を (file, mod) で書いた形の候補（呼ぶ所の頭の書き方の組み合わせ・16 まで）。
// 頭の sym が決まらない物はそのまま。書けない頭があれば空。
func (ix *sigIndex) respell(e, fromFile, fromMod, file, mod string) []string {
	out := []string{""}
	last := 0
	for _, h := range heads(e) {
		lit := e[last:h[0]]
		head := e[h[0]:h[1]]
		alts := []string{head}
		if sym := ix.headSym(head, fromFile, fromMod); sym != "" {
			alts = ix.spellings(sym, file, mod)
			if len(alts) == 0 {
				return nil
			}
		}
		var next []string
		for _, o := range out {
			for _, a := range alts {
				if len(next) < 16 {
					next = append(next, o+lit+a)
				}
			}
		}
		out = next
		last = h[1]
	}
	for i := range out {
		out[i] += e[last:]
	}
	return out
}

// defShape は def の引数の名前・本体の字・効果の注記があるか。
type defShape struct {
	params []string
	body   string
	effect bool
	file   string
	mod    string
}

func (ix *sigIndex) shapeOf(srcs *reshapeSources, sym string) (defShape, bool) {
	r, ok := ix.defs[sym]
	if !ok {
		return defShape{}, false
	}
	src, err := srcs.get(r.File)
	if err != nil {
		return defShape{}, false
	}
	_, nameEnd, err := ByteRange(src, r)
	if err != nil {
		return defShape{}, false
	}
	open := nameEnd
	if open < len(src) && src[open] == '[' {
		if _, at, err := scanTop(src, open+1, "]"); err == nil {
			open = at + 1
		}
	}
	list, has, err := argsAfter(src, open)
	if err != nil || !has {
		return defShape{}, false
	}
	span, err := spanOf(r.File, r.Attr("ext"))
	if err != nil {
		return defShape{}, false
	}
	_, extEnd, err := ByteRange(src, span)
	if err != nil {
		return defShape{}, false
	}
	body, ok := DefBodyStart(src, list.Close+1)
	if !ok || body > extEnd {
		return defShape{}, false
	}
	var params []string
	for _, a := range list.Args {
		params = append(params, src[a[0]:a[1]])
	}
	names, err := paramNames(params)
	if err != nil {
		return defShape{}, false
	}
	return defShape{params: names, body: strings.TrimSpace(src[body:extEnd]), effect: strings.Contains(src[list.Close+1:body], `\`),
		file: r.File, mod: modOf(sym)}, true
}

// recordFields は `{ a = e, b = f }`（拡張の `|` の無い record の式）の欄の名前と式。record の式でなければ nil。
func recordFields(body string) ([][2]string, bool) {
	if len(body) < 2 || body[0] != '{' || body[len(body)-1] != '}' {
		return nil, false
	}
	if _, at, err := scanTop(body, 1, "}"); err != nil || at != len(body)-1 {
		return nil, false
	}
	inner := body[1 : len(body)-1]
	if _, at, err := scanTop(inner+"}", 0, "|}"); err != nil || at != len(inner) {
		return nil, false
	}
	items, err := splitTop(inner)
	if err != nil {
		return nil, false
	}
	var out [][2]string
	for _, it := range items {
		label, e, ok := strings.Cut(it, "=")
		label = strings.TrimSpace(label)
		if !ok || !isIdent(label) || strings.HasPrefix(e, "=") || strings.HasPrefix(e, ">") {
			return nil, false
		}
		out = append(out, [2]string{label, strings.TrimSpace(e)})
	}
	return out, true
}

// liftRule は本体の 1 つの置き換え: pats（同じ式の書き方）のどれかを name に。bare は消える引数の名前そのもの
// （名前として使う所だけを替える）。
type liftRule struct {
	pats []string
	name string
	bare bool
}

// sigTarget は替える def の所（本体を書いたファイルと mod・新しい引数の型の字）。
type sigTarget struct {
	file, mod string
	types     map[string]string // 新しい引数の名前 → 型の字
}

// bodyRules は def の本体に当てる置き換えの列（--args の式・その record の欄の式・欄の欄…）と、人へ回す理由。
func (ix *sigIndex) bodyRules(srcs *reshapeSources, t sigTarget, news, templates, removed []string) ([]liftRule, string) {
	var direct, derived, bare []liftRule
	gone := map[string]bool{}
	for _, r := range removed {
		gone[r] = true
	}
	var derive func(e, sym, name string, labels map[string]bool, depth int)
	derive = func(e, sym, name string, labels map[string]bool, depth int) {
		d, ok := ix.shapeOf(srcs, sym)
		if !ok || d.effect || depth > 3 {
			return
		}
		fields, record := recordFields(d.body)
		h := heads(e)
		if len(h) == 0 || h[0][0] != 0 {
			return
		}
		l, has, err := argsAfter(e, skipSpace(e, h[0][1]))
		if err != nil || !has || l.Close != len(e)-1 || len(l.Args) != len(d.params) {
			return
		}
		var vals []string
		for _, a := range l.Args {
			vals = append(vals, e[a[0]:a[1]])
		}
		if !record {
			// 1 行の本体（`w#speed`・`ThemeDoc.rec(w#theme)`）は、その字（引数を呼ぶ所の式にした物）も同じ式。
			if strings.Contains(d.body, "\n") || regexp.MustCompile(`\blet\b|->`).MatchString(d.body) {
				return
			}
			var pats []string
			for _, v := range ix.respell(d.body, d.file, d.mod, t.file, t.mod) {
				pats = append(pats, Substitute(v, d.params, vals))
			}
			if len(pats) > 0 && !gone[pats[0]] && strings.ContainsAny(pats[0], "#(") && hasName(pats[0]) {
				derived = append(derived, liftRule{pats: pats, name: name})
			}
			return
		}
		for _, f := range fields {
			if labels != nil && !labels[f[0]] {
				continue
			}
			to := name + "#" + f[0]
			sub := Substitute(f[1], d.params, vals)
			if gone[sub] {
				bare = append(bare, liftRule{pats: []string{sub}, name: to, bare: true})
				continue
			}
			var pats []string
			for _, v := range ix.respell(f[1], d.file, d.mod, t.file, t.mod) {
				pats = append(pats, Substitute(v, d.params, vals))
			}
			if len(pats) == 0 || !strings.ContainsAny(pats[0], "#(") || !hasName(pats[0]) {
				continue
			}
			derived = append(derived, liftRule{pats: pats, name: to})
			if fh := heads(f[1]); len(fh) > 0 && fh[0][0] == 0 {
				if s := ix.headSym(f[1][:fh[0][1]], d.file, d.mod); s != "" {
					derive(pats[0], s, to, nil, depth+1)
				}
			}
		}
	}
	for i, tm := range templates {
		tm = strings.TrimSpace(tm)
		if tm == news[i] || !hasName(tm) {
			continue
		}
		pats := ix.respell(tm, t.file, t.mod, t.file, t.mod)
		if len(pats) == 0 {
			pats = []string{tm}
		}
		direct = append(direct, liftRule{pats: pats, name: news[i]})
		h := heads(tm)
		if len(h) == 0 || h[0][0] != 0 {
			continue
		}
		sym := ix.headSym(tm[:h[0][1]], t.file, t.mod)
		if sym == "" {
			continue
		}
		if d, ok := ix.shapeOf(srcs, sym); ok && d.effect {
			return nil, fmt.Sprintf("--args の `%s` は効果のある def %s を呼ぶ（本体から呼ぶ所へ移すと評価の回数と順が変わる）。そのまま残すか、効果の無い式にしてから", tm, sym)
		}
		derive(tm, sym, news[i], recordLabels(t.types[news[i]]), 0)
	}
	sort.SliceStable(derived, func(a, b int) bool { return len(derived[a].pats[0]) > len(derived[b].pats[0]) })
	return append(append(direct, derived...), bare...), ""
}

// recordLabels は型の字が record の型（`{ a = T, b = U | r }`）ならその欄の名前、でなければ nil（どの欄も通す）。
func recordLabels(typ string) map[string]bool {
	typ = strings.TrimSpace(typ)
	if !strings.HasPrefix(typ, "{") || !strings.HasSuffix(typ, "}") {
		return nil
	}
	inner := typ[1 : len(typ)-1]
	if _, at, err := scanTop(inner+"}", 0, "|}"); err == nil {
		inner = inner[:at]
	}
	items, err := splitTop(inner)
	if err != nil {
		return nil
	}
	out := map[string]bool{}
	for _, it := range items {
		if l, _, ok := strings.Cut(it, "="); ok {
			out[strings.TrimSpace(l)] = true
		}
	}
	return out
}

// rebinds は body が name を束ね直すか（`let name`・`name ->`）。束ね直す所の後ろは別の物なので、字では替えない。
func rebinds(body, name string) bool {
	q := regexp.QuoteMeta(name)
	return regexp.MustCompile(`\blet\s+` + q + `\b|(?:^|[^\w.#])` + q + `\s*->`).MatchString(body)
}

// usesAny は式 e が names のどれかを名前として使うか。
func usesAny(e string, names map[string]bool) []string {
	var out []string
	for _, u := range identUses(e, names) {
		out = append(out, e[u[0]:u[1]])
	}
	return out
}

// applyRules は本体に置き換えを順に当てる（替えた数）。消える引数を束ね直す本体には、その引数を使う式を当てない。
func applyRules(body string, rules []liftRule, removed []string) (string, int) {
	body, counts := applyRulesCounted(body, rules, removed)
	n := 0
	for _, k := range counts {
		n += k
	}
	return body, n
}

// applyRulesCounted は applyRules の、規則ごとの替えた数（rules と同じ順）。
func applyRulesCounted(body string, rules []liftRule, removed []string) (string, []int) {
	counts := make([]int, len(rules))
	gone := map[string]bool{}
	for _, r := range removed {
		gone[r] = true
	}
	for ri, r := range rules {
		skip := false
		for _, p := range r.pats {
			for _, u := range usesAny(p, gone) {
				if rebinds(body, u) {
					skip = true
				}
			}
		}
		if skip {
			continue
		}
		if r.bare {
			uses := identUses(body, map[string]bool{r.pats[0]: true})
			for k := len(uses) - 1; k >= 0; k-- {
				body = body[:uses[k][0]] + r.name + body[uses[k][1]:]
			}
			counts[ri] += len(uses)
			continue
		}
		for _, p := range r.pats {
			var k int
			body, k = replaceExpr(body, p, r.name)
			counts[ri] += k
		}
	}
	return body, counts
}

// ── 引数の並びの改行の形 ──

// layoutKind は元の引数の並びの形。
type layoutKind int

const (
	layoutOneLine layoutKind = iota // 1 行
	layoutPerLine                   // 1 つずつ改行
	layoutWrapped                   // 決まった桁で折る
)

// argLayout は元の並びの改行の形（折る時の字下げと、折る桁）。
type argLayout struct {
	kind   layoutKind
	indent string // 折った行の頭
	limit  int    // layoutWrapped の折る桁（行の終わりの字の数がこれを超えない）
	col    int    // 最初の引数の桁
}

// readLayout は src の並び l の形を読む。col は最初の引数の行の頭からの字の数。
func readLayout(src string, l ArgList) argLayout {
	lay := argLayout{col: colOf(src, firstArgStart(l))}
	if len(l.Args) < 2 {
		return lay
	}
	broken := 0
	for i := 1; i < len(l.Args); i++ {
		sep := src[l.Args[i-1][1]:l.Args[i][0]]
		if k := strings.LastIndexByte(sep, '\n'); k >= 0 {
			if broken == 0 {
				lay.indent = sep[k+1:]
			}
			broken++
		}
	}
	switch {
	case broken == 0:
		return lay
	case broken == len(l.Args)-1:
		lay.kind = layoutPerLine
		return lay
	}
	// 折る桁: どの行も収まり（行の終わりの最大）、折った所はその次の引数が入らなかった（はみ出しの最小 - 1）。
	lay.kind = layoutWrapped
	maxEnd, minOver := 0, -1
	end := lay.col
	for i, a := range l.Args {
		item := src[a[0]:a[1]]
		if i > 0 {
			sep := src[l.Args[i-1][1]:a[0]]
			if strings.Contains(sep, "\n") {
				if over := end + 1 + firstLineWidth(item) + 1; minOver < 0 || over < minOver {
					minOver = over
				}
				end = width(lay.indent)
			} else {
				end += width(sep) - 1
			}
		}
		end = advance(end, item) + 1 // 後ろの `,` か `)`
		if end > maxEnd {
			maxEnd = end
		}
	}
	lay.limit = maxEnd
	if minOver-1 > maxEnd {
		lay.limit = minOver - 1
	}
	return lay
}

// joinLayout は items を lay の形で並べた字（最初の引数の頭から最後の引数の終わりまで）。
func joinLayout(items []string, lay argLayout) string {
	var b strings.Builder
	end := lay.col
	for i, it := range items {
		if i > 0 {
			switch {
			case lay.kind == layoutPerLine,
				lay.kind == layoutWrapped && end+1+firstLineWidth(it)+1 > lay.limit:
				b.WriteString(",\n" + lay.indent)
				end = width(lay.indent)
			default:
				b.WriteString(", ")
				end += 1
			}
		}
		b.WriteString(it)
		end = advance(end, it) + 1
	}
	return b.String()
}

func firstArgStart(l ArgList) int {
	if len(l.Args) == 0 {
		return l.Open + 1
	}
	return l.Args[0][0]
}

// colOf は src の i の、行の頭からの字の数。
func colOf(src string, i int) int {
	return width(src[strings.LastIndexByte(src[:i], '\n')+1 : i])
}

func width(s string) int { return utf8.RuneCountInString(s) }

func firstLineWidth(s string) int {
	if k := strings.IndexByte(s, '\n'); k >= 0 {
		return width(s[:k])
	}
	return width(s)
}

// advance は桁 col から s を書いた後の桁（s が改行を含めば最後の行の長さ）。
func advance(col int, s string) int {
	if k := strings.LastIndexByte(s, '\n'); k >= 0 {
		return width(s[k+1:])
	}
	return col + width(s)
}

// ── 新しい引数の型の use ──

var typeQualifier = regexp.MustCompile(`[A-Z][A-Za-z0-9_]*`)

// typeRoots は型の字の中の、名前の解決に要る頭（`Clock.Time[World.Music]` → Clock・World、素の型 `Ctx` → Ctx）。
func typeRoots(typ string) []string {
	var out []string
	seen := map[string]bool{}
	for _, m := range typeQualifier.FindAllStringIndex(typ, -1) {
		if m[0] > 0 && (typ[m[0]-1] == '.' || typ[m[0]-1] == '#' || identByte(typ[m[0]-1])) {
			continue
		}
		if n := typ[m[0]:m[1]]; !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	return out
}

// exprRoots は式の中の修飾の頭（`Clock.secondsOf(x)` → Clock）。文字列の中は見ない。
func exprRoots(e string) []string {
	var out []string
	seen := map[string]bool{}
	for _, h := range heads(e) {
		head := e[h[0]:h[1]]
		first, _, ok := strings.Cut(head, ".")
		if ok && first != "" && first[0] >= 'A' && first[0] <= 'Z' && !seen[first] {
			seen[first] = true
			out = append(out, first)
		}
	}
	return out
}

// useSource は名前 x をどこから use するか（親の書き方 `fge::`・`Lib.`）。プロジェクトの根の mod・mod の中の型・
// 既に use してある名前・索引に無い名前（標準の型と mod）は ""（足さない）。
func (ix *sigIndex) useSource(srcs *reshapeSources, x, file, mod string) string {
	if ix.roots[x] {
		return ""
	}
	for _, s := range ix.decls[x] {
		if modOf(s) == mod {
			return ""
		}
	}
	for _, u := range ix.uses[file] {
		if u.Owner == mod && u.alias == x {
			return ""
		}
	}
	// 索引の use の行（同じ名前を use しているほかの所）の、いちばん多い出どころ。
	count := map[string]int{}
	first := map[string]useRow{}
	for _, f := range sortedKeys(ix.uses) {
		for _, u := range ix.uses[f] {
			if u.alias == x {
				count[u.Sym]++
				if _, ok := first[u.Sym]; !ok {
					first[u.Sym] = u
				}
			}
		}
	}
	best := ""
	for s, n := range count {
		if best == "" || n > count[best] || (n == count[best] && s < best) {
			best = s
		}
	}
	if best != "" {
		return useParent(srcs, first[best])
	}
	// use の例が無い型: 宣言が 1 つだけなら、その mod から。
	if ds := ix.decls[x]; len(ds) == 1 && modOf(ds[0]) != "" {
		return modOf(ds[0]) + "."
	}
	return ""
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// useParent は use の行の、名前の前の親の書き方（`use fge::{App, Clock}` → `fge::`・`use Lib.Clock` → `Lib.`）。
func useParent(srcs *reshapeSources, u useRow) string {
	src, err := srcs.get(u.File)
	if err != nil {
		return ""
	}
	s, e, err := ByteRange(src, u.Row)
	if err != nil {
		return ""
	}
	kw := strings.LastIndex(src[:s], "use ")
	if kw < 0 {
		return ""
	}
	stmt := src[kw+4 : s]
	if b := strings.IndexByte(stmt, '{'); b >= 0 {
		return strings.TrimSpace(stmt[:b])
	}
	full := strings.TrimSpace(stmt + src[s:e])
	if strings.HasSuffix(full, u.alias) {
		return full[:len(full)-len(u.alias)]
	}
	return ""
}

// useStmt はファイルの中の use の 1 文（位置はバイト）。
type useStmt struct {
	start, end   int    // 行の頭 〜 文の終わり
	indent       string // 字下げ
	parent       string // `fge::`・`Lib.`
	braces       bool
	items        [][2]int // 波括弧の中の名前ごとの範囲
	itemsText    []string
	lineEnd      int // 文の終わりの行の次の行の頭
	packageStyle bool
}

// moduleUses は src の mod の中（mod の行 〜 before）の use の文と、mod の行の終わり（use が無い時に足す所）・字下げ。
func moduleUses(src, mod string, before int) ([]useStmt, int, string, bool) {
	name := regexp.QuoteMeta(mod)
	short := regexp.QuoteMeta(shortName(mod))
	re := regexp.MustCompile(`(?m)^([ \t]*)(?:pub\s+)?mod\s+(?:` + name + `|` + short + `)\s*\{[ \t]*\r?\n`)
	var open []int
	for _, m := range re.FindAllStringSubmatchIndex(src, -1) {
		if m[0] < before {
			open = m
		}
	}
	if open == nil {
		return nil, 0, "", false
	}
	modIndent := src[open[2]:open[3]]
	var out []useStmt
	i := open[1]
	for i < before {
		le := strings.IndexByte(src[i:], '\n')
		if le < 0 {
			le = len(src) - i
		}
		line := src[i : i+le]
		trim := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(trim, "use ") {
			st := useStmt{start: i, indent: line[:len(line)-len(trim)]}
			body := i + (len(line) - len(trim)) + 4
			end := body
			if b := strings.IndexByte(line, '{'); b >= 0 {
				_, at, err := scanTop(src, i+b+1, "}")
				if err != nil {
					break
				}
				st.braces = true
				st.parent = strings.TrimSpace(src[body : i+b])
				inner := src[i+b+1 : at]
				off := i + b + 1
				for _, part := range splitKeep(inner) {
					st.items = append(st.items, [2]int{off + part[0], off + part[1]})
					st.itemsText = append(st.itemsText, inner[part[0]:part[1]])
				}
				end = at + 1
			} else {
				end = i + le
				path := strings.TrimSpace(src[body:end])
				if k := strings.LastIndexAny(path, ".:"); k >= 0 {
					st.parent = path[:k+1]
					st.itemsText = []string{path[k+1:]} // 波括弧の無い 1 つだけの use も、同じ物を重ねて足さないために名前を持つ
				}
			}
			st.end = end
			nl := strings.IndexByte(src[end:], '\n')
			if nl < 0 {
				st.lineEnd = len(src)
			} else {
				st.lineEnd = end + nl + 1
			}
			st.packageStyle = strings.Contains(st.parent, "::")
			out = append(out, st)
			i = st.lineEnd
			continue
		}
		i += le + 1
	}
	return out, open[1], modIndent + "    ", true
}

// splitKeep は "A, B,\n C" を深さ 0 の , で切った範囲（前後の空白を除く）。
func splitKeep(s string) [][2]int {
	var out [][2]int
	i := 0
	t := s + ")"
	for {
		stop, at, err := scanTop(t, i, ",)")
		if err != nil {
			return out
		}
		a, b := trimSpan(t, i, at)
		if b > a {
			out = append(out, [2]int{a, b})
		}
		if stop == ')' {
			return out
		}
		i = at + 1
	}
}

// useEdits は file の mod の中で names を引けるようにする use の書き換えと、足した物の説明（`Clock（fge::）`）。
// 同じ親の波括弧の並びがあればそこへ（並びが字の順なら順の位置・でなければ終わり）、無ければ use の並びの決まった位置
// （パッケージの use（::）は先・プロジェクトの use は後）へ 1 行足す。use が 1 つも無い mod は mod の行の次に足す。
func (ix *sigIndex) useEdits(srcs *reshapeSources, file, mod string, before int, names []string, site Row) ([]Edit, []string) {
	var wants []useWant
	for _, x := range names {
		if p := ix.useSource(srcs, x, file, mod); p != "" {
			wants = append(wants, useWant{x, p})
		}
	}
	return insertUses(srcs, file, mod, before, wants, site, nil)
}

// useWant は足す use の 1 つ: 波括弧の中に書く字（`Clock`・`area => size`）と親の書き方（`fge::`・`Lib.`）。
type useWant struct{ name, parent string }

// insertUses は file の mod の中へ wants の use を足す書き換えと、足した物の説明（`Clock（fge::）`）。並べ方は useEdits の doc。
// 既に同じ物を use していれば足さない（字で見る。索引の後に同じ回の別の書き換えが足す物も、ここで重ねない）。
// gone は同じ回に消す use の文の頭（その文の波括弧へは足さない。消す文に足すと一緒に消える）。
func insertUses(srcs *reshapeSources, file, mod string, before int, wants []useWant, site Row, gone map[int]bool) ([]Edit, []string) {
	if len(wants) == 0 {
		return nil, nil
	}
	src, err := srcs.get(file)
	if err != nil {
		return nil, nil
	}
	stmts, modLineEnd, indent, ok := moduleUses(src, mod, before)
	if !ok {
		return nil, nil
	}
	for _, st := range stmts {
		for _, it := range st.itemsText {
			for k := len(wants) - 1; k >= 0; k-- {
				if it == wants[k].name && st.parent == wants[k].parent {
					wants = append(wants[:k], wants[k+1:]...)
				}
			}
		}
	}
	inserts := map[int]string{}
	var order []int
	put := func(at int, text string) {
		if _, ok := inserts[at]; !ok {
			order = append(order, at)
		}
		inserts[at] += text
	}
	var notes []string
	newLines := map[string][]string{}
	var newParents []string
	for _, w := range wants {
		notes = append(notes, w.name+"（"+w.parent+"）")
		var target *useStmt
		for i := range stmts {
			if stmts[i].braces && stmts[i].parent == w.parent && !gone[stmts[i].start] {
				target = &stmts[i]
				break
			}
		}
		if target == nil {
			if _, ok := newLines[w.parent]; !ok {
				newParents = append(newParents, w.parent)
			}
			newLines[w.parent] = append(newLines[w.parent], w.name)
			continue
		}
		sorted := sort.StringsAreSorted(target.itemsText)
		pos := len(target.itemsText)
		if sorted {
			pos = sort.SearchStrings(target.itemsText, w.name)
		}
		if pos < len(target.items) {
			put(target.items[pos][0], w.name+", ")
		} else if len(target.items) > 0 {
			put(target.items[len(target.items)-1][1], ", "+w.name)
		} else {
			put(target.end-1, w.name)
		}
	}
	for _, p := range newParents {
		ns := newLines[p]
		sort.Strings(ns)
		line := "use " + p + "{" + strings.Join(ns, ", ") + "}\n"
		switch {
		case len(stmts) == 0:
			put(modLineEnd, indent+line+"\n")
		default:
			at := stmts[len(stmts)-1]
			if strings.Contains(p, "::") {
				for _, st := range stmts {
					if !st.packageStyle {
						put(st.start, st.indent+line)
						at = useStmt{start: -1}
						break
					}
				}
			}
			if at.start >= 0 {
				put(at.lineEnd, at.indent+line)
			}
		}
	}
	var edits []Edit
	for _, at := range order {
		text := inserts[at]
		edits = append(edits, Edit{File: file, Start: at, End: at, Site: site, Make: func(string) (string, error) { return text, nil }})
	}
	return edits, notes
}

// flixTypes は Flix の標準の型の名前（use 無しで引ける物）。
var flixTypes = map[string]bool{
	"Unit": true, "Bool": true, "Char": true, "Float32": true, "Float64": true, "BigDecimal": true, "Int8": true, "Int16": true,
	"Int32": true, "Int64": true, "BigInt": true, "String": true, "Regex": true, "Array": true, "Vector": true, "List": true,
	"Option": true, "Result": true, "Map": true, "Set": true, "Chain": true, "Nec": true, "Nel": true, "MutList": true,
	"MutMap": true, "MutSet": true, "MutDeque": true, "Lazy": true, "Region": true, "Ref": true, "IO": true, "Sender": true,
	"Receiver": true, "Void": true, "Pure": true, "Univ": true, "Validation": true, "Identity": true,
}

// typePath は型の字の中の名前の並び（`ViewEnv.Res`・`List`）。
var typePath = regexp.MustCompile(`[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*`)

// unknownTypes は型の字 typ の名前のうち、file の mod で引けない物（標準の型・同じ mod の宣言・use・同じ回に足す use・
// プロジェクトの型の宣言のどれでもない物）。パッケージ（fge:: など）の use から始まる名前は索引に宣言が無いので見ない。
func (ix *sigIndex) unknownTypes(srcs *reshapeSources, typ, file, mod string) []string {
	var out []string
	for _, m := range typePath.FindAllStringIndex(typ, -1) {
		if m[0] > 0 && (typ[m[0]-1] == '.' || typ[m[0]-1] == '#' || identByte(typ[m[0]-1])) {
			continue
		}
		path := typ[m[0]:m[1]]
		segs := strings.Split(path, ".")
		head, last := segs[0], segs[len(segs)-1]
		if len(segs) == 1 {
			if flixTypes[head] || ix.useSource(srcs, head, file, mod) != "" || ix.hasUse(file, head) {
				continue
			}
			found := false
			for _, s := range ix.decls[head] {
				if m := modOf(s); m == mod || m == "" {
					found = true
				}
			}
			if !found {
				out = append(out, path)
			}
			continue
		}
		if u, ok := ix.useOf(file, head); ok && !ix.roots[strings.Split(u, ".")[0]] {
			continue // パッケージの use（索引に宣言が無い）
		}
		rest := strings.Join(segs[1:], ".")
		found := false
		for _, s := range ix.decls[last] {
			if s == path || strings.HasSuffix(s, "."+path) || (ix.hasUse(file, head) && strings.HasSuffix(s, "."+rest)) {
				found = true
			}
		}
		if !found {
			out = append(out, path)
		}
	}
	return out
}

// hasUse は file に名前 x を入れる use があるか。
func (ix *sigIndex) hasUse(file, x string) bool {
	_, ok := ix.useOf(file, x)
	return ok
}

// useOf は file で名前 x を入れる use の出どころの sym。
func (ix *sigIndex) useOf(file, x string) (string, bool) {
	for _, u := range ix.uses[file] {
		if u.alias == x {
			return u.Sym, true
		}
	}
	return "", false
}

// namePart は式の中の名前（字・数の値だけの式には無い）。
var namePart = regexp.MustCompile(`[A-Za-z_]`)

// hasName は式 e が名前を含むか。`()`（Unit の値）・`0` のような値だけの式は、本体のほかの所の同じ字が同じ値とは限らず、
// 引数の名前へ替える対象にしない（型の別名が Unit の時、`()` を返す def を --args に書くと本体の `()` が全部替わった）。
func hasName(e string) bool {
	e = strings.TrimSpace(e)
	return namePart.MatchString(e) && e != "true" && e != "false"
}
