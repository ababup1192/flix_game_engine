package refactor

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// rewrite の当て方を、手で組んだ小さな汎用の AST（flixlint の Generic が書く列と同じ形のファイル）で確かめる。
// 位置は src の字を探して決める（同じ字の何番目か）ので、ソースを直せば位置も揃う。

const rwSrc = `mod A {
    def f(x: Option[Int32], r: M.Rec): Bool =
        x != None and None == r#o

    def g(x: Option[Int32]): Int32 = match x {
        case None    => 0
        case Some(_) =>
            let y = 1;
            y
    }

    def h(x: Option[Int32]): Int32 = match x {
        case Some(_) => 1 // 中身は使わない
        case None    => 0
    }

    def k(x: Option[Int32]): Bool = f(x, x) != None
}
`

var (
	rwKinds = []string{"Def", "Expr.ApplyDef", "Expr.ApplySig", "Expr.Binary", "Expr.Cst", "Expr.Let", "Expr.Match", "Expr.RecordSelect", "Expr.Tag", "Expr.Var", "MatchRule", "Pattern.Tag", "Pattern.Wild", "Binder"}
	rwSlots = []string{"bnd", "exp", "exp1", "exp2", "exps", "pat", "pats", "rules"}
	rwAttrs = []string{"cst", "cst.lit", "label", "sop", "sym", "symUse"}
)

// rwNode は組む節（text は親の範囲の中で探す字・nth はその何番目か）。
type rwNode struct {
	kind, slot, text string
	nth              int
	attrs            [][2]string
	typ              string
	kids             []rwNode
	eff              string // 効果の型（rwTypes の名前。無ければ -1）
	index            int    // 欄の中の位置
	synth            bool   // 構文が作った節
}

// rwTypes は型の表（名前 → 行）。Option[Int32]・M.Rec（{ o, p } の alias）・欄の並びの違う同じ record。
type rwTypeRow struct {
	form, name string
	args       []int
	expands    int
}

func rwTypeTable() ([]rwTypeRow, map[string]int) {
	rows := []rwTypeRow{
		{"Cst", "Option", nil, -1},         // 0
		{"Cst", "Int32", nil, -1},          // 1
		{"Apply", "", []int{0, 1}, -1},     // 2 Option[Int32]
		{"Cst", "Bool", nil, -1},           // 3
		{"Record", "", nil, -1},            // 4
		{"Cst", "RecordRowEmpty", nil, -1}, // 5
		{"RecordRow", "p", nil, -1},        // 6
		{"Apply", "", []int{6, 1}, -1},     // 7 RecordRow p [Int32]
		{"Apply", "", []int{7, 5}, -1},     // 8 ( p: Int32 | {} )
		{"RecordRow", "o", nil, -1},        // 9
		{"Apply", "", []int{9, 2}, -1},     // 10
		{"Apply", "", []int{10, 8}, -1},    // 11 ( o, p )
		{"Apply", "", []int{4, 11}, -1},    // 12 Record{ o, p }
		{"Alias", "M.Rec", nil, 12},        // 13 M.Rec = { o, p }
		{"Apply", "", []int{10, 5}, -1},    // 14 ( o | {} )
		{"Apply", "", []int{7, 14}, -1},    // 15 ( p, o )
		{"Apply", "", []int{4, 15}, -1},    // 16 Record{ p, o }（推論で開かれて欄の並びが違う物）
	}
	return rows, map[string]int{"Option[Int32]": 2, "Int32": 1, "Bool": 3, "M.Rec": 13, "{p,o}": 16}
}

func none(nth int) rwNode {
	return rwNode{kind: "Expr.Tag", slot: "exps", text: "None", nth: nth, attrs: [][2]string{{"symUse", "Option.None"}}, typ: "Option[Int32]"}
}

func xVar(slot string, nth int) rwNode {
	return rwNode{kind: "Expr.Var", slot: slot, text: "x", nth: nth, attrs: [][2]string{{"sym", "x#0"}}, typ: "Option[Int32]"}
}

func rwDecls() []rwNode {
	f := rwNode{kind: "Def", text: "def f(x: Option[Int32], r: M.Rec): Bool =\n        x != None and None == r#o", attrs: [][2]string{{"sym", "A.f"}}, kids: []rwNode{
		{kind: "Expr.Binary", slot: "exp", text: "x != None and None == r#o", attrs: [][2]string{{"sop", "And"}}, typ: "Bool", kids: []rwNode{
			{kind: "Expr.ApplySig", slot: "exp1", text: "x != None", attrs: [][2]string{{"symUse", "Eq.neq"}}, typ: "Bool", kids: []rwNode{xVar("exps", 0), none(0)}},
			{kind: "Expr.ApplySig", slot: "exp2", text: "None == r#o", attrs: [][2]string{{"symUse", "Eq.eq"}}, typ: "Bool", kids: []rwNode{
				none(0),
				{kind: "Expr.RecordSelect", slot: "exps", text: "r#o", attrs: [][2]string{{"label", "o"}}, typ: "Option[Int32]", kids: []rwNode{
					{kind: "Expr.Var", slot: "exp", text: "r", attrs: [][2]string{{"sym", "r#1"}}, typ: "{p,o}"},
				}},
			}},
		}},
	}}
	g := rwNode{kind: "Def", text: "def g(x: Option[Int32]): Int32 = match x {\n        case None    => 0\n        case Some(_) =>\n            let y = 1;\n            y\n    }", attrs: [][2]string{{"sym", "A.g"}}, kids: []rwNode{
		{kind: "Expr.Match", slot: "exp", text: "match x {\n        case None    => 0\n        case Some(_) =>\n            let y = 1;\n            y\n    }", typ: "Int32", kids: []rwNode{
			xVar("exp", 0),
			{kind: "MatchRule", slot: "rules", text: "case None    => 0", kids: []rwNode{
				{kind: "Pattern.Tag", slot: "pat", text: "None", attrs: [][2]string{{"symUse", "Option.None"}}},
				{kind: "Expr.Cst", slot: "exp", text: "0", attrs: [][2]string{{"cst", "Int32"}, {"cst.lit", "0"}}, typ: "Int32"},
			}},
			{kind: "MatchRule", slot: "rules", text: "case Some(_) =>\n            let y = 1;\n            y", kids: []rwNode{
				{kind: "Pattern.Tag", slot: "pat", text: "Some(_)", attrs: [][2]string{{"symUse", "Option.Some"}}, kids: []rwNode{
					{kind: "Pattern.Wild", slot: "pats", text: "_"},
				}},
				{kind: "Expr.Let", slot: "exp", text: "let y = 1;\n            y", typ: "Int32"},
			}},
		}},
	}}
	h := rwNode{kind: "Def", text: "def h(x: Option[Int32]): Int32 = match x {\n        case Some(_) => 1 // 中身は使わない\n        case None    => 0\n    }", attrs: [][2]string{{"sym", "A.h"}}, kids: []rwNode{
		{kind: "Expr.Match", slot: "exp", text: "match x {\n        case Some(_) => 1 // 中身は使わない\n        case None    => 0\n    }", typ: "Int32", kids: []rwNode{
			xVar("exp", 0),
			{kind: "MatchRule", slot: "rules", text: "case Some(_) => 1", kids: []rwNode{
				{kind: "Pattern.Tag", slot: "pat", text: "Some(_)", attrs: [][2]string{{"symUse", "Option.Some"}}, kids: []rwNode{
					{kind: "Pattern.Wild", slot: "pats", text: "_"},
				}},
				{kind: "Expr.Cst", slot: "exp", text: "1", attrs: [][2]string{{"cst", "Int32"}, {"cst.lit", "1"}}, typ: "Int32"},
			}},
			{kind: "MatchRule", slot: "rules", text: "case None    => 0", kids: []rwNode{
				{kind: "Pattern.Tag", slot: "pat", text: "None", attrs: [][2]string{{"symUse", "Option.None"}}},
				{kind: "Expr.Cst", slot: "exp", text: "0", attrs: [][2]string{{"cst", "Int32"}, {"cst.lit", "0"}}, typ: "Int32"},
			}},
		}},
	}}
	k := rwNode{kind: "Def", text: "def k(x: Option[Int32]): Bool = f(x, x) != None", attrs: [][2]string{{"sym", "A.k"}}, kids: []rwNode{
		{kind: "Expr.ApplySig", slot: "exp", text: "f(x, x) != None", attrs: [][2]string{{"symUse", "Eq.neq"}}, typ: "Bool", kids: []rwNode{
			{kind: "Expr.ApplyDef", slot: "exps", text: "f(x, x)", attrs: [][2]string{{"symUse", "A.f"}}, typ: "Option[Int32]", kids: []rwNode{xVar("exps", 0), xVar("exps", 1)}},
			none(0),
		}},
	}}
	return []rwNode{f, g, h, k}
}

// writeRwAst は rwSrc の汎用の AST を dir に書き、flixlint の前面の代わり（bin/flixlint と shim/AstNames.scala）を home に置く。
func writeRwAst(t *testing.T, dir, home string) {
	t.Helper()
	types, typeID := rwTypeTable()
	writeGenAst(t, dir, home, genAst{src: rwSrc, file: "src/A.flix", decls: rwDecls(), types: types, typeID: typeID, stage: "typed",
		kinds: rwKinds, slots: rwSlots, attrs: rwAttrs})
}

// genAst は手で組む汎用の AST 1 つ（ソース 1 ファイル）。
type genAst struct {
	src, file, stage    string
	decls               []rwNode
	types               []rwTypeRow
	typeID              map[string]int
	kinds, slots, attrs []string
}

// writeGenAst は g の汎用の AST を dir に書き、flixlint の前面の代わりを home に置く。節の葉は "@型" で型の葉（attr.type）、
// rwNode の eff は効果の型（node.effect）。
func writeGenAst(t *testing.T, dir, home string, g genAst) {
	t.Helper()
	rwSrc, rwKinds, rwSlots, rwAttrs, types, typeID := g.src, g.kinds, g.slots, g.attrs, g.types, g.typeID
	no := func(xs []string) map[string]int {
		m := map[string]int{}
		for i, x := range xs {
			m[x] = i
		}
		return m
	}
	kindNo, slotNo, attrNo := no(rwKinds), no(rwSlots), no(rwAttrs)
	var strs []string
	strID := map[string]int{}
	sid := func(s string) int {
		if i, ok := strID[s]; ok {
			return i
		}
		strs = append(strs, s)
		strID[s] = len(strs) - 1
		return len(strs) - 1
	}
	cols := map[string][]int32{}
	add := func(name string, v int) { cols[name] = append(cols[name], int32(v)) }
	lineCol := func(off int) (int, int) {
		before := rwSrc[:off]
		return strings.Count(before, "\n") + 1, off - strings.LastIndex(before, "\n")
	}
	var walk func(n rwNode, parent, root, from, to int) int
	walk = func(n rwNode, parent, root, from, to int) int {
		at := from
		for i := 0; ; i++ {
			j := strings.Index(rwSrc[at:to], n.text)
			if j < 0 {
				t.Fatalf("%s の字 %q が親の範囲に無い", n.kind, n.text)
			}
			if i == n.nth {
				at += j
				break
			}
			at += j + 1
		}
		end := at + len(n.text)
		id := len(cols["node.kind"])
		if root < 0 {
			root = id
		}
		l, c := lineCol(at)
		el, ec := lineCol(end)
		slot := -1
		if n.slot != "" {
			slot = slotNo[n.slot]
		}
		typ := -1
		if n.typ != "" {
			typ = typeID[n.typ]
		}
		eff := -1
		if n.eff != "" {
			eff = typeID[n.eff]
		}
		syn := 0
		if n.synth {
			syn = 1
		}
		for name, v := range map[string]int{"node.kind": kindNo[n.kind], "node.parent": parent, "node.slot": slot, "node.index": n.index, "node.root": root,
			"node.line": l, "node.col": c, "node.endLine": el, "node.endCol": ec, "node.synthetic": syn, "node.type": typ, "node.effect": eff} {
			add(name, v)
		}
		for _, kv := range n.attrs {
			add("attr.node", id)
			add("attr.name", attrNo[kv[0]])
			if strings.HasPrefix(kv[1], "@") {
				add("attr.value", -1)
				add("attr.type", typeID[kv[1][1:]])
			} else {
				add("attr.value", sid(kv[1]))
				add("attr.type", -1)
			}
			add("attr.line", -1)
		}
		for _, k := range n.kids {
			walk(k, id, root, at, end)
		}
		return id
	}
	var decls []int
	for _, d := range g.decls {
		decls = append(decls, walk(d, -1, -1, 0, len(rwSrc)))
	}
	for _, d := range decls {
		add("decl.node", d)
		add("decl.file", 0)
	}
	add("type.argStart", 0)
	for _, r := range types {
		add("type.form", indexOf(Forms, r.form))
		name := -1
		if r.name != "" {
			name = sid(r.name)
		}
		add("type.name", name)
		add("type.expands", r.expands)
		for _, x := range r.args {
			add("type.args", x)
		}
		add("type.argStart", len(cols["type.args"]))
	}
	must(t, os.MkdirAll(dir, 0o755))
	for name, xs := range cols {
		b := make([]byte, 4*len(xs))
		for i, x := range xs {
			binary.BigEndian.PutUint32(b[4*i:], uint32(x))
		}
		must(t, os.WriteFile(filepath.Join(dir, name+".i32"), b, 0o644))
	}
	for _, name := range []string{"attr.type", "attr.line"} {
		if _, ok := cols[name]; !ok {
			must(t, os.WriteFile(filepath.Join(dir, name+".i32"), nil, 0o644))
		}
	}
	lines := func(xs []string) []byte { return []byte(strings.Join(xs, "\n") + "\n") }
	must(t, os.WriteFile(filepath.Join(dir, "strings.txt"), lines(strs), 0o644))
	must(t, os.WriteFile(filepath.Join(dir, "files.txt"), lines([]string{g.file}), 0o644))
	must(t, os.WriteFile(filepath.Join(dir, "kinds.txt"), lines(rwKinds), 0o644))
	must(t, os.WriteFile(filepath.Join(dir, "meta.txt"), lines([]string{"format=1", "stage=" + g.stage, "flixVersion=0.78.0", "schemaHash=00aa"}), 0o644))
	quote := func(xs []string) string { return `"` + strings.Join(xs, `", "`) + `"` }
	scala := fmt.Sprintf("object AstNames {\n  val schemaHash: String = \"00aa\"\n  val kinds: Vector[String] = Vector(\n    %s)\n  val slots: Vector[String] = Vector(\n    %s)\n  val attrs: Vector[String] = Vector(\n    %s)\n}\n",
		quote(rwKinds), quote(rwSlots), quote(rwAttrs))
	must(t, os.MkdirAll(filepath.Join(home, "shim"), 0o755))
	must(t, os.MkdirAll(filepath.Join(home, "bin"), 0o755))
	must(t, os.WriteFile(filepath.Join(home, "shim", "AstNames.scala"), []byte(scala), 0o644))
	must(t, os.WriteFile(filepath.Join(home, "bin", "flixlint"), []byte("#!/bin/sh\n"), 0o755))
}

// rwPlan は rwSrc に型紙の組を当てた計画と、当てた後の中身。
func rwPlan(t *testing.T, rules ...RewriteRule) (*RewritePlan, string) {
	t.Helper()
	tmp := t.TempDir()
	writeRwAst(t, filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint"))
	a, err := LoadAst(filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint", "bin", "flixlint"))
	must(t, err)
	root := filepath.Join(tmp, "root")
	must(t, os.MkdirAll(filepath.Join(root, "src"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "src", "A.flix"), []byte(rwSrc), 0o644))
	plan, err := PlanRewrite(a, &reshapeSources{root: root, m: map[string]string{}}, RewriteQuery{Rules: rules})
	must(t, err)
	got, err := ApplyEdits(rwSrc, plan.Edits)
	must(t, err)
	return plan, got
}

func TestRewriteNoneCompareEitherSide(t *testing.T) {
	_, got := rwPlan(t, RewriteRule{From: "$x != None", To: "Option.nonEmpty($x)"}, RewriteRule{From: "$x == None", To: "Option.isEmpty($x)"})
	want := strings.Replace(strings.Replace(rwSrc, "x != None and None == r#o", "Option.nonEmpty(x) and Option.isEmpty(r#o)", 1),
		"f(x, x) != None", "Option.nonEmpty(f(x, x))", 1)
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestRewriteWrapsInOperator(t *testing.T) {
	_, got := rwPlan(t, RewriteRule{From: "$x != None", To: "not Option.isEmpty($x)"})
	if !strings.Contains(got, "(not Option.isEmpty(x)) and None == r#o") {
		t.Fatalf("and の左に置く not の式を括弧で包んでいない:\n%s", got)
	}
	if !strings.Contains(got, "def k(x: Option[Int32]): Bool = not Option.isEmpty(f(x, x))") {
		t.Fatalf("def の本体の全体は包まない:\n%s", got)
	}
}

func TestRewriteWhereByAliasLabels(t *testing.T) {
	plan, got := rwPlan(t, RewriteRule{From: "$r#o == None", To: "M.isOpen($r)", Where: "$r: M.Rec"})
	if !strings.Contains(got, "x != None and M.isOpen(r)") || len(plan.Sites) != 1 {
		t.Fatalf("推論で開かれた record（欄の並びが違う）を alias の欄の組で当てていない: sites %d\n%s", len(plan.Sites), got)
	}
}

func TestRewriteWhereExcludes(t *testing.T) {
	plan, _ := rwPlan(t, RewriteRule{From: "$x != None", To: "Option.nonEmpty($x)", Where: "$x: Bool"})
	if len(plan.Sites) != 0 || plan.Excluded != 2 {
		t.Fatalf("型の違う穴を外していない: sites %d excluded %d", len(plan.Sites), plan.Excluded)
	}
}

func TestRewriteMatchSomeWild(t *testing.T) {
	plan, got := rwPlan(t, RewriteRule{From: "match $x { case Some(_) => $a case None => $b }", To: "if (Option.nonEmpty($x)) $a else $b"})
	want := "def g(x: Option[Int32]): Int32 = if (Option.nonEmpty(x)) {\n            let y = 1;\n            y\n    } else 0\n"
	if !strings.Contains(got, want) {
		t.Fatalf("腕の順の違う match と let の本体を書いていない:\n%s", got)
	}
	if len(plan.Fix) != 1 || plan.Fix[0].Line != 12 || !strings.Contains(plan.Fix[0].Why, "コメント") {
		t.Fatalf("コメントの消える match（h）を人へ回していない: %+v", plan.Fix)
	}
}

func TestRewriteNestedTakesOuter(t *testing.T) {
	plan, _ := rwPlan(t, RewriteRule{From: "$a and $b", To: "Bool.and($a, $b)"}, RewriteRule{From: "$x != None", To: "Option.nonEmpty($x)"})
	if len(plan.Sites) != 2 || plan.Nested != 1 {
		t.Fatalf("入れ子は外側だけ書く: sites %d nested %d", len(plan.Sites), plan.Nested)
	}
}

func TestRewriteSameHoleTwice(t *testing.T) {
	plan, _ := rwPlan(t, RewriteRule{From: "A.f($x, $x) != None", To: "A.g($x)"})
	if len(plan.Sites) != 1 {
		t.Fatalf("同じ穴の 2 度目は字が同じ時だけ当たる: %d", len(plan.Sites))
	}
}

func TestRewriteTemplateErrors(t *testing.T) {
	for _, c := range []struct{ from, want string }{
		{"$x", "穴か _ だけ"},
		{"x != None", "局所の名前"},
		{"match $x { case Some(v) => $a }", "パターンは _ か case"},
		{"match $x { case Some(_) if $c => $a }", "ガード"},
		{"$x != None)", "残る"},
		{"$x + 1", "書けない字"},
	} {
		if _, err := ParseTmpl(c.from); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: 誤りに %q が無い: %v", c.from, c.want, err)
		}
	}
}

func TestRewriteToHoleMustBeInFrom(t *testing.T) {
	tmp := t.TempDir()
	writeRwAst(t, filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint"))
	a, err := LoadAst(filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint", "bin", "flixlint"))
	must(t, err)
	_, err = PlanRewrite(a, &reshapeSources{root: tmp, m: map[string]string{}}, RewriteQuery{Rules: []RewriteRule{{From: "$x != None", To: "f($y)"}}})
	if err == nil || !strings.Contains(err.Error(), "$y") {
		t.Fatalf("--to の知らない穴を止めていない: %v", err)
	}
}

func TestLoadAstRefusesOtherSchema(t *testing.T) {
	tmp := t.TempDir()
	writeRwAst(t, filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint"))
	meta := filepath.Join(tmp, "generic", "meta.txt")
	must(t, os.WriteFile(meta, []byte("format=1\nstage=typed\nschemaHash=ffff\n"), 0o644))
	if _, err := LoadAst(filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint", "bin", "flixlint")); err == nil || !strings.Contains(err.Error(), "schemaHash") {
		t.Fatalf("別の版の shim の列を読んだ: %v", err)
	}
}

func TestRewriteRulesFromConfig(t *testing.T) {
	cfg := defaults().with(Config{Rewrites: map[string][]RewriteRule{"a": {{From: "$x != None", To: "Option.nonEmpty($x)"}}}})
	cfg = cfg.with(Config{Rewrites: map[string][]RewriteRule{"b": {{From: "$x == None", To: "Option.isEmpty($x)"}}}})
	rules, err := rewriteRules(args{rule: "a,b"}, cfg)
	if err != nil || len(rules) != 2 {
		t.Fatalf("--rule a,b は 2 つの組を並べる（重ねた設定の両方）: %v %v", rules, err)
	}
	if _, err := rewriteRules(args{rule: "c"}, cfg); err == nil || !strings.Contains(err.Error(), "a・b") {
		t.Fatalf("無い名前は、ある名前を並べて止める: %v", err)
	}
}

func TestShippedRewritesParse(t *testing.T) {
	cfg, err := LoadConfig(filepath.Join("..", "..", ".."))
	must(t, err)
	for name, rules := range cfg.Rewrites {
		for _, r := range rules {
			if _, err := ParseTmpl(r.From); err != nil {
				t.Errorf("refactor.json の rewrites.%s の型紙 %q が読めない: %v", name, r.From, err)
			}
		}
	}
	if len(cfg.Rewrites["option-none-compare"]) == 0 || len(cfg.Rewrites["match-some-wild"]) == 0 {
		t.Fatalf("配る refactor.json に option-none-compare・match-some-wild の組が無い")
	}
}

func TestIsAtomicText(t *testing.T) {
	for s, want := range map[string]bool{"x": true, "f(a, b)": true, "r#o": true, `"a b"`: true, "(a or b)": true,
		"a or b": false, "not x": false, "x != None": false, "1.0 - y": false} {
		if got := isAtomicText(s); got != want {
			t.Errorf("isAtomicText(%q) = %v", s, got)
		}
	}
}

func TestKeepGenericCopiesSameStageWithKey(t *testing.T) {
	root := t.TempDir()
	b := Builder{Root: root}
	facts := b.factsGenericDir()
	must(t, os.MkdirAll(facts, 0o755))
	must(t, os.WriteFile(filepath.Join(facts, "meta.txt"), []byte("format=1\nstage=resolved\n"), 0o644))
	b.keepGeneric(Typed, "k1")
	if b.genericKey(Typed) != "" {
		t.Fatalf("別の段の走行の列を typed の写しにした")
	}
	must(t, os.WriteFile(filepath.Join(facts, "meta.txt"), []byte("format=1\nstage=typed\n"), 0o644))
	b.keepGeneric(Typed, "k1")
	if b.genericKey(Typed) != "k1" {
		t.Fatalf("写しに索引の鍵が無い: %q", b.genericKey(Typed))
	}
	if _, err := os.Stat(filepath.Join(b.GenericDir(Typed), "meta.txt")); err != nil {
		t.Fatalf("列を写していない: %v", err)
	}
}

func TestRunRewriteNeedsTemplate(t *testing.T) {
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, t.TempDir(), []string{"rewrite", "--from", "$x != None"}, Options{}); code != 2 || !strings.Contains(errOut.String(), "--to") {
		t.Fatalf("--to の無い rewrite を止めていない: %d %s", code, errOut.String())
	}
}
