package refactor

// usages: IDE の「使っている所を探す（Find Usages）」と「呼び出しの階層（Call Hierarchy）」に当たる、読むだけの問い。
//
//	usages <Mod.f | Enum | Enum.Case | Alias>        def・enum・case・型 alias の使われ所（resolved の段）
//	usages <Alias>#<欄> | --label x [--receiver T]   record の欄の読み・書き・組み立て（typed の段）
//	usages … --callers [--depth N]                   使っている def を畳んで、呼び手の呼び手まで
//	usages --unused                                   外から使われない pub の def と、使っていない use
//
// 名前はコンパイラが解決した symbol で当てる（同じ名前の別物を拾わない）。2 つ以上に当たれば候補を並べて止まる。
// 型の注記・use の行は flixlint 0.6.6 の resolved の段から（頭の行の adds=）。古い索引ではその 2 つを数えず、そう書く。
//
// WhyNot: refs を太らせずに別の操作にした。refs は書き換えの下ごしらえ（宣言と参照の span）で、出力の形も
// 呼んでいる道具がある。usages は人と AI が読む一覧で、種類（呼び出し・読み・書き…）と短さが主。

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// 索引の種類（resolved の段の adds=）。
const (
	KindUse       = "use"
	KindTypeUse   = "type-use"
	KindAliasDecl = "alias-decl"
)

// UsageWhat は使い方の種類（--json の what）。
type UsageWhat string

const (
	WhatCall      UsageWhat = "call"      // 呼び出し（f(…)・構文が指す物）
	WhatRef       UsageWhat = "ref"       // 関数を値で渡す（List.map(f)・x |> f）
	WhatRead      UsageWhat = "read"      // e#x
	WhatWrite     UsageWhat = "write"     // { x = v | e }
	WhatConstruct UsageWhat = "construct" // case を作る・record を組み立てる
	WhatPattern   UsageWhat = "pattern"   // match の型で当てる
	WhatType      UsageWhat = "type"      // 型の注記（シグネチャ・型を書いた let・case の欄・alias の本体）
	WhatUse       UsageWhat = "use"       // use の宣言
)

var whatLabel = map[UsageWhat]string{
	WhatCall: "呼び出し", WhatRef: "参照", WhatRead: "読み", WhatWrite: "書き", WhatConstruct: "組み立て",
	WhatPattern: "パターン", WhatType: "型の注記", WhatUse: "use",
}

var whatOrder = []UsageWhat{WhatCall, WhatRef, WhatRead, WhatWrite, WhatConstruct, WhatPattern, WhatType, WhatUse}

// UsageSite は使われ所 1 つ。
type UsageSite struct {
	File   string    `json:"file"`
	Line   int       `json:"line"`
	Col    int       `json:"col"`
	Owner  string    `json:"owner"` // 囲む def（use は mod・型の宣言の中は enum・alias）
	What   UsageWhat `json:"what"`
	Detail string    `json:"detail,omitempty"` // enum の時の case・欄の受け手が決まらない時の理由
}

func (u UsageSite) Where() string { return fmt.Sprintf("%s:%d:%d", u.File, u.Line, u.Col) }

// Target は usages が当てた物。
type Target struct {
	Sym  string `json:"sym"`
	Kind string `json:"kind"` // def・enum・case・alias・field
	Decl string `json:"decl,omitempty"`
}

var declKindName = map[string]string{KindDefDecl: "def", KindEnumDecl: "enum", KindCaseDecl: "case", KindAliasDecl: "alias"}

// useKinds は名前で当てる時に見る行（宣言と、宣言の無いパッケージの物を指す行）。
var useKinds = map[string]string{KindDefUse: "def", KindCaseConstruct: "case", KindCasePattern: "case", KindTypeUse: ""}

// ResolveTarget は q（Mod.f・Enum・Enum.Case・Alias）を 1 つの物に決める。当たる物が 2 つ以上なら、
// 種類と宣言の場所つきで候補を並べた誤りを返す（書いた通りの名前が在ればそれ）。
func ResolveTarget(rows []Row, q string) (Target, error) {
	found := map[string]*Target{}
	var order []string
	add := func(sym, kind, decl string) {
		t, ok := found[sym]
		if !ok {
			t = &Target{Sym: sym, Kind: kind}
			found[sym] = t
			order = append(order, sym)
		}
		if t.Kind == "" {
			t.Kind = kind
		}
		if decl != "" && t.Decl == "" {
			t.Decl = decl
		}
	}
	for _, r := range rows {
		if !nameMatches(r.Sym, q) {
			continue
		}
		if k, ok := declKindName[r.Kind]; ok {
			add(r.Sym, k, r.Where())
		} else if k, ok := useKinds[r.Kind]; ok {
			if k == "" {
				k = r.Attr("what")
			}
			add(r.Sym, k, "")
		}
	}
	switch len(order) {
	case 0:
		return Target{}, fmt.Errorf("%s という名前は索引にありません（def・enum・case・型 alias を Mod.name で。record の欄は <Alias>#<欄> か --label）", q)
	case 1:
		return *found[order[0]], nil
	}
	if t, ok := found[q]; ok {
		return *t, nil
	}
	sort.Strings(order)
	var lines []string
	for _, s := range order {
		t := found[s]
		at := t.Decl
		if at == "" {
			at = "宣言は索引の外"
		}
		lines = append(lines, fmt.Sprintf("  %s（%s・%s）", s, t.Kind, at))
	}
	return Target{}, fmt.Errorf("%s が %d 個に当たります。もっと長く書いてください:\n%s", q, len(order), strings.Join(lines, "\n"))
}

// hasAdds は索引の頭の行の adds= に kind があるか（無ければ古い shim の索引で、その種類の行はソースに無いのでなく書かれていない）。
func (idx *Index) hasAdds(kind string) bool {
	for _, k := range strings.Split(idx.Adds, ",") {
		if k == kind {
			return true
		}
	}
	return false
}

// srcCache はファイルの中身を 1 度だけ読む（読めなければ ""）。
type srcCache struct {
	root  string
	files map[string]string
}

func (c *srcCache) get(file string) string {
	if c.files == nil {
		c.files = map[string]string{}
	}
	s, ok := c.files[file]
	if !ok {
		b, _ := os.ReadFile(filepath.Join(c.root, file))
		s = string(b)
		c.files[file] = s
	}
	return s
}

// text は r の範囲の字（読めなければ ""）。
func (c *srcCache) text(r Row) string {
	t, err := SpanText(c.get(r.File), r)
	if err != nil {
		return ""
	}
	return t
}

// callOrRef は def の参照が呼び出しか（名前のすぐ後が `(`・構文が指す物）、関数を値で渡しているか。
func (c *srcCache) callOrRef(r Row) UsageWhat {
	if r.Extra == "sugar" {
		return WhatCall
	}
	src := c.get(r.File)
	if src == "" {
		return WhatCall
	}
	lines := strings.SplitAfter(src, "\n")
	if r.EndLine < 1 || r.EndLine > len(lines) {
		return WhatCall
	}
	rest := lineAfter(lines[r.EndLine-1], r.EndCol)
	if strings.HasPrefix(rest, "(") {
		return WhatCall
	}
	return WhatRef
}

func usageOf(r Row, what UsageWhat, detail string) UsageSite {
	return UsageSite{File: r.File, Line: r.Line, Col: r.Col, Owner: r.Owner, What: what, Detail: detail}
}

// SymbolUsages は def・enum・case・alias の使われ所（宣言は入れない）。enum はその case を作る・当てる所も入れる。
func SymbolUsages(rows []Row, t Target, src *srcCache) []UsageSite {
	var out []UsageSite
	child := func(sym string) (string, bool) {
		if !strings.HasPrefix(sym, t.Sym+".") {
			return "", false
		}
		rest := sym[len(t.Sym)+1:]
		return rest, !strings.Contains(rest, ".")
	}
	for _, r := range rows {
		switch {
		case r.Kind == KindUse && (r.Sym == t.Sym || (t.Kind == "enum" && isChild(r.Sym, t.Sym))):
			out = append(out, usageOf(r, WhatUse, ""))
		case r.Kind == KindDefUse && r.Sym == t.Sym:
			out = append(out, usageOf(r, src.callOrRef(r), ""))
		case (r.Kind == KindCaseConstruct || r.Kind == KindCasePattern) && r.Sym == t.Sym:
			out = append(out, usageOf(r, caseWhat(r), ""))
		case (r.Kind == KindCaseConstruct || r.Kind == KindCasePattern) && t.Kind == "enum":
			if c, ok := child(r.Sym); ok {
				out = append(out, usageOf(r, caseWhat(r), c))
			}
		case r.Kind == KindTypeUse && r.Sym == t.Sym:
			out = append(out, usageOf(r, WhatType, ""))
		}
	}
	return out
}

func isChild(sym, parent string) bool {
	return strings.HasPrefix(sym, parent+".") && !strings.Contains(sym[len(parent)+1:], ".")
}

func caseWhat(r Row) UsageWhat {
	if r.Kind == KindCasePattern {
		return WhatPattern
	}
	return WhatConstruct
}

// FieldUsages は欄の読み書き（受け手の型が決まらない物は unsure）。
func FieldUsages(rows []Row, label, receiver string) (sure, unsure []UsageSite) {
	ans := FieldSites(rows, FieldQuery{Label: label, Receiver: receiver})
	for _, s := range ans.Sites {
		w := WhatRead
		if s.Write {
			w = WhatWrite
		}
		sure = append(sure, usageOf(s.Row, w, ""))
	}
	for _, s := range ans.Unsure {
		w := WhatRead
		if s.Write {
			w = WhatWrite
		}
		unsure = append(unsure, usageOf(s.Row, w, "受け手 "+s.Recv+"（"+s.Via+"）"))
	}
	return sure, unsure
}

// receiversOf は欄 label の受け手の型の数（? は数えない）。--receiver が無い時に、別の型の同じ名前の欄を見分ける。
func receiversOf(rows []Row, label string) map[string]int {
	n := map[string]int{}
	for _, r := range rows {
		if (r.Kind == KindLabelSelect || r.Kind == KindLabelUpdate) && r.Sym == label {
			for _, a := range strings.Split(r.Attr("recv"), "|") {
				if a != "?" && a != "" {
					n[a]++
				}
			}
		}
	}
	return n
}

// Caller は使っている def 1 つ（と、--depth の時はその呼び手）。
type Caller struct {
	Owner   string   `json:"owner"`
	Count   int      `json:"count"`
	First   string   `json:"first"`             // 最初の使われ所の file:line:col
	Seen    bool     `json:"seen,omitempty"`    // 上の段で出た（再帰か、別の道で同じ def に着いた）。下は辿らない
	Callers []Caller `json:"callers,omitempty"` // --depth 2 以上: この def を呼ぶ def
}

// groupCallers は使われ所を囲む def ごとに畳む（名前の順）。
func groupCallers(us []UsageSite) []Caller {
	by := map[string]*Caller{}
	var order []string
	for _, u := range us {
		c, ok := by[u.Owner]
		if !ok {
			c = &Caller{Owner: u.Owner, First: u.Where()}
			by[u.Owner] = c
			order = append(order, u.Owner)
		}
		c.Count++
	}
	sort.Strings(order)
	out := make([]Caller, 0, len(order))
	for _, o := range order {
		out = append(out, *by[o])
	}
	return out
}

// CallerTree は first（1 段目の呼び手）から depth 段まで、def の呼び手を辿る。同じ def は 1 度だけ辿る。
func CallerTree(rows []Row, first []Caller, depth int, start string) []Caller {
	uses := map[string][]UsageSite{}
	for _, r := range rows {
		if r.Kind == KindDefUse && r.Owner != r.Sym {
			uses[r.Sym] = append(uses[r.Sym], usageOf(r, WhatCall, ""))
		}
	}
	seen := map[string]bool{start: true}
	var grow func(cs []Caller, level int) []Caller
	grow = func(cs []Caller, level int) []Caller {
		for i := range cs {
			if seen[cs[i].Owner] {
				cs[i].Seen = true
				continue
			}
			seen[cs[i].Owner] = true
		}
		if level >= depth {
			return cs
		}
		for i := range cs {
			if !cs[i].Seen {
				cs[i].Callers = grow(groupCallers(uses[cs[i].Owner]), level+1)
			}
		}
		return cs
	}
	return grow(first, 1)
}

func countCallers(cs []Caller) int {
	n := 0
	for _, c := range cs {
		if !c.Seen {
			n++
		}
		n += countCallers(c.Callers)
	}
	return n
}

// countWhat は「呼び出し 4・use 1」の形。
func countWhat(us []UsageSite) string {
	n := map[UsageWhat]int{}
	for _, u := range us {
		n[u.What]++
	}
	var parts []string
	for _, w := range whatOrder {
		if n[w] > 0 {
			parts = append(parts, fmt.Sprintf("%s %d", whatLabel[w], n[w]))
		}
	}
	return strings.Join(parts, "・")
}

// splitUsages は場所を src・test・ほかに数える（ファイルの数も）。
func splitUsages(us []UsageSite) string {
	rows := make([]Row, len(us))
	for i, u := range us {
		rows[i] = Row{File: u.File}
	}
	return split(rows)
}

func sortUsages(us []UsageSite) {
	sort.SliceStable(us, func(i, j int) bool {
		a, b := us[i], us[j]
		if a.File != b.File {
			return a.File < b.File
		}
		if a.Line != b.Line {
			return a.Line < b.Line
		}
		return a.Col < b.Col
	})
}

// fieldTarget は usages の引数を欄として読むか（<Alias>#<欄>・--label・--receiver）。
func (a args) fieldTarget() (label, receiver string, ok bool) {
	label, receiver = a.label, a.receiver
	if l, r, has := strings.Cut(a.target, "#"); has {
		receiver, label = l, r
		if a.receiver != "" {
			receiver = a.receiver
		}
	} else if label == "" && a.receiver != "" {
		label = a.target
	}
	return label, receiver, label != ""
}

func usagesReport(root string, idx *Index, a args, cfg Config) (report, error) {
	if a.unused {
		return unusedReport(root, idx, a, cfg)
	}
	src := &srcCache{root: root}
	r := report{Op: "usages", Target: a.target, code: CodeUsages}
	var us, unsure []UsageSite
	var t Target
	if label, receiver, ok := a.fieldTarget(); ok {
		if receiver == "" {
			recv := receiversOf(idx.Rows, label)
			if len(recv) > 1 {
				var names []string
				for k, n := range recv {
					names = append(names, fmt.Sprintf("  %s#%s（%d か所）", k, label, n))
				}
				sort.Strings(names)
				return report{}, fmt.Errorf("欄 %s は %d 個の型にあります。--receiver <型> か <型>#%s で 1 つに:\n%s", label, len(recv), label, strings.Join(names, "\n"))
			}
			for k := range recv {
				receiver = k
			}
		}
		t = Target{Sym: receiver + "#" + label, Kind: "field"}
		if receiver == "" {
			t.Sym = "#" + label
		}
		us, unsure = FieldUsages(idx.Rows, label, receiver)
		if receiver != "" {
			cons, note, err := fieldConstructions(root, idx, cfg, receiver, label)
			if err == nil {
				us = append(us, cons...)
			}
			if note != "" {
				r.extra = append(r.extra, note)
			}
		}
	} else {
		var err error
		t, err = ResolveTarget(idx.Rows, a.target)
		if err != nil {
			return report{}, err
		}
		us = SymbolUsages(idx.Rows, t, src)
		if !idx.hasAdds(KindTypeUse) {
			r.extra = append(r.extra, "型の注記・use は数えていない（索引にその行が無い。flixlint "+MinFlixlintUsages+" 以上で出る）")
		}
	}
	sortUsages(us)
	sortUsages(unsure)
	r.Sym, r.Usage = t.Sym, &t
	r.got = len(us)
	r.Sites = us
	if us == nil {
		r.Sites = []UsageSite{}
	}
	head := fmt.Sprintf("%d か所", len(us))
	if len(us) > 0 {
		head += "（" + countWhat(us) + "）"
	}
	first := groupCallers(us)
	head += fmt.Sprintf("・使う側 %d（def・型の宣言・use の mod）・%s", len(first), splitUsages(us))
	r.gotText = head
	if len(unsure) > 0 {
		r.extra = append(r.extra, fmt.Sprintf("受け手の型が決まらない %d（数えていない・末尾に ? で並べた）", len(unsure)))
		r.Maybe = unsure
	}
	if a.callers || a.depth > 1 {
		depth := max(a.depth, 1)
		tree := CallerTree(idx.Rows, first, depth, t.Sym)
		r.Callers = tree
		if depth > 1 {
			r.extra = append(r.extra, fmt.Sprintf("呼び手 %d 段まで %d def（↑ は上に出た def）", depth, countCallers(tree)))
		}
		r.lines = callerLines(tree, 0)
		return r, nil
	}
	for _, u := range us {
		r.lines = append(r.lines, usageLine(u))
	}
	for _, u := range unsure {
		r.lines = append(r.lines, usageLine(u)+" ?\t"+u.Detail)
	}
	return r, nil
}

func usageLine(u UsageSite) string {
	what := whatLabel[u.What]
	if u.Detail != "" && u.What != WhatRead && u.What != WhatWrite {
		what += " " + u.Detail
	}
	return u.Where() + "\t" + u.Owner + "\t" + what
}

func callerLines(cs []Caller, level int) []string {
	var out []string
	for _, c := range cs {
		mark := ""
		if c.Seen {
			mark = " ↑"
		}
		indent := strings.Repeat("  ", level)
		arrow := ""
		if level > 0 {
			arrow = "← "
		}
		out = append(out, fmt.Sprintf("%s%s%s\t%d\t%s%s", indent, arrow, c.Owner, c.Count, c.First, mark))
		out = append(out, callerLines(c.Callers, level+1)...)
	}
	return out
}

// fieldConstructions は型 alias receiver を組み立てる record の式（欄の組が型と同じ物）。欄の組が同じ別の型があれば
// 決めずに数えない（note に書く）。
func fieldConstructions(root string, idx *Index, cfg Config, receiver, label string) ([]UsageSite, string, error) {
	srcs, err := loadSources(root, cfg)
	if err != nil {
		return nil, "", err
	}
	shape, err := FindAliasShape(srcs, receiver)
	if err != nil {
		return nil, "組み立ては数えていない（" + err.Error() + "）", err
	}
	if !shape.Has(label) {
		return nil, "", nil
	}
	key := fieldKey(shape.Fields)
	var others []string
	for _, at := range AllShapeKeys(srcs)[key] {
		if at != fmt.Sprintf("%s:%d", shape.File, shape.Brace) {
			others = append(others, at[:strings.LastIndex(at, ":")])
		}
	}
	if len(others) > 0 {
		return nil, "組み立ては数えていない（欄の組が同じ別の型 " + strings.Join(others, "・") + " があり、どちらか決められない）", nil
	}
	var out []UsageSite
	eachLiteral(idx.Rows, srcs, func(d Row, src string, l Literal) {
		if fieldKey(l.Fields) == key {
			out = append(out, usageOf(rowAt(d.File, src, l.Brace, d.Sym), WhatConstruct, ""))
		}
	})
	return out, "", nil
}

// --unused ---------------------------------------------------------------

// Unused は外から使われない pub の def か、使っていない use の 1 つ。
type Unused struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Col     int    `json:"col"`
	Sym     string `json:"sym"`
	What    string `json:"what"`              // def・use
	Why     string `json:"why"`               // unreferenced・test-only・own-mod・unused-use
	Refs    int    `json:"refs"`              // 自分の外からの参照の数
	Outside string `json:"outside,omitempty"` // 名前が字で出る .flix の外のファイル（入口・文書かもしれない）
}

func (u Unused) Where() string { return fmt.Sprintf("%s:%d:%d", u.File, u.Line, u.Col) }

var whyLabel = map[string]string{
	"unreferenced": "参照 0",
	"test-only":    "テストからだけ",
	"own-mod":      "同じ mod の中だけ（pub を外せる）",

	"unused-use": "使っていない use",
}

// UnusedDefs は src の pub な def のうち、外から使われない物: 参照 0・テストからだけ・同じ mod の中だけ。
// instance の def・@Test・main・テストのフォルダの def は入れない。自分の中の参照（再帰）は数えない。
func UnusedDefs(rows []Row, testDirs []string) []Unused {
	defs, order := defTable(rows)
	refs := refsBySym(rows)
	var out []Unused
	for _, s := range order {
		d := defs[s]
		if !d.Pub || d.Inst || d.Test || inDirs(d.File, testDirs) || strings.HasSuffix(s, ".main") || s == "main" {
			continue
		}
		fromTest, fromOwnMod, fromOtherSrc := 0, 0, 0
		for _, r := range refs[s] {
			switch {
			case inDirs(r.File, testDirs):
				fromTest++
			case modOf(r.Owner) == modOf(s):
				fromOwnMod++
			default:
				fromOtherSrc++
			}
		}
		why := ""
		switch {
		case fromOtherSrc > 0:
			continue
		case len(refs[s]) == 0:
			why = "unreferenced"
		case fromTest > 0:
			why = "test-only"
		default:
			why = "own-mod"
		}
		out = append(out, Unused{File: d.File, Line: d.Line, Col: d.Col, Sym: s, What: "def", Why: why, Refs: len(refs[s])})
	}
	return out
}

// judgedUse は使っているかを索引で決められる use の中身（effect・trait・mod などの使われ所は索引に無い）。
var judgedUse = map[string]bool{"def": true, "enum": true, "case": true, "alias": true}

// UnusedUses は使っていない use: 同じファイルに、その名前を use で入れた名前（alias=）のまま書いた所が無い物。
// 決められない物（effect・trait・mod などを入れる use）の数も返す。
//
// WhyNot: mod の範囲でなくファイルで見る。索引は mod の範囲を持たず、1 ファイルに mod が 2 つ在って別々に同じ名前を
// use する事は少ない。見落とす向き（使っていないのに使っていると見る）にしか外れない。
func UnusedUses(rows []Row, src *srcCache) (out []Unused, unjudged int) {
	byFile := map[string][]Row{}
	for _, r := range rows {
		switch r.Kind {
		case KindDefUse, KindCaseConstruct, KindCasePattern, KindTypeUse:
			if r.Extra != "sugar" {
				byFile[r.File] = append(byFile[r.File], r)
			}
		}
	}
	for _, u := range rows {
		if u.Kind != KindUse {
			continue
		}
		if !judgedUse[u.Attr("what")] {
			unjudged++
			continue
		}
		alias := u.Attr("alias")
		used := false
		for _, r := range byFile[u.File] {
			if r.Sym != u.Sym && !strings.HasPrefix(r.Sym, u.Sym+".") {
				continue
			}
			if t := src.text(r); t == alias || strings.HasPrefix(t, alias+".") {
				used = true
				break
			}
		}
		if !used {
			out = append(out, Unused{File: u.File, Line: u.Line, Col: u.Col, Sym: u.Sym, What: "use", Why: "unused-use"})
		}
	}
	return out, unjudged
}

func unusedReport(root string, idx *Index, a args, cfg Config) (report, error) {
	src := &srcCache{root: root}
	defs := UnusedDefs(idx.Rows, cfg.TestDirs)
	mentioned, err := mentionedOutsideFlix(root, engineDir(root))
	if err != nil {
		return report{}, err
	}
	n := map[string]int{}
	for i := range defs {
		defs[i].Outside = mentioned[defs[i].Sym]
		n[defs[i].Why]++
	}
	var uses []Unused
	unjudged := 0
	if idx.hasAdds(KindUse) {
		uses, unjudged = UnusedUses(idx.Rows, src)
	}
	all := append(append([]Unused{}, defs...), uses...)
	sort.SliceStable(all, func(i, j int) bool {
		if all[i].File != all[j].File {
			return all[i].File < all[j].File
		}
		return all[i].Line < all[j].Line
	})
	r := report{Op: "usages", Target: "--unused", code: CodeUnused, got: len(all), Sites: all}
	outside := 0
	for _, d := range defs {
		if d.Outside != "" {
			outside++
		}
	}
	r.gotText = fmt.Sprintf("pub の def %d（参照 0: %d・テストからだけ: %d・同じ mod の中だけ: %d）・使っていない use %d",
		len(defs), n["unreferenced"], n["test-only"], n["own-mod"], len(uses))
	if outside > 0 {
		r.extra = append(r.extra, fmt.Sprintf("うち名前が .flix の外に字で出る def %d（入口・文書かもしれない。行の末尾に出る所）", outside))
	}
	if IsLibrary(root, cfg) {
		r.extra = append(r.extra, "ライブラリ（fpkg で配る）: pub の def の使い手は索引の外にもいる")
	}
	if !idx.hasAdds(KindUse) {
		r.extra = append(r.extra, "use は見ていない（索引に use の行が無い。flixlint "+MinFlixlintUsages+" 以上で出る）")
	} else if unjudged > 0 {
		r.extra = append(r.extra, fmt.Sprintf("effect・trait・mod などを入れる use %d は決められないので数えていない", unjudged))
	}
	r.extra = append(r.extra, "消すのは bin/fge refactor remove-dead（参照 0・テストからだけ）か手で。use の行は手で消す")
	for _, u := range all {
		name := u.Sym
		if u.What == "use" {
			name = "use " + u.Sym
		}
		line := u.Where() + "\t" + name + "\t" + whyLabel[u.Why]
		if u.Why == "test-only" || u.Why == "own-mod" {
			line += fmt.Sprintf(" %d か所", u.Refs)
		}
		if u.Outside != "" {
			line += "\t字: " + u.Outside
		}
		r.lines = append(r.lines, line)
	}
	return r, nil
}
