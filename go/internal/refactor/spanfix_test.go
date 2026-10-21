package refactor

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// record の式の範囲（flixlint の spans の形）と、書き替えで呼び手が 0 になる def の始末を確かめる。
//
// 手組みの AST の範囲は、internet_dungeon の generic-typed で見た実物の形に合わせた:
//   - `{ x = a, y = b }` の頭の RecordExtend は最初の欄 x から閉じかっこ } の次まで（開きかっこ { を含まない）。
//     欄ごとの内側の RecordExtend は `y = b }`（その欄から閉じかっこまで）。空の record の節（構文が作った物）は省く。
//   - `{ y = v | w }` の頭の RecordExtend と RecordRestrict は y から w まで（{ も } も含まない）。

const recSrc = `mod A {
    def f(rect: M.R): M.P =
        { x = rect#x, y = rect#y }

    def g(r: M.R): Int32 = B.use({ x = r#x, y = r#y })

    def k(r: M.R): M.Q = { z = r#z, x = r#x, y = r#y }

    def h(w: M.P): Int32 = B.use({ y = w#b | w })
}
`

var (
	recKinds = []string{"Def", "FormalParam", "Expr.ApplyDef", "Expr.Var", "Expr.RecordSelect", "Expr.RecordExtend", "Expr.RecordRestrict"}
	recSlots = []string{"fparams", "exp", "exp1", "exp2", "exps"}
	recAttrs = []string{"sym", "symUse", "tpe", "label"}
)

func recTypes() ([]rwTypeRow, map[string]int) {
	rows := []rwTypeRow{
		{"Cst", "Int32", nil, -1}, // 0
		{"Cst", "M.R", nil, -1},   // 1
		{"Cst", "M.P", nil, -1},   // 2
		{"Cst", "M.Q", nil, -1},   // 3
		{"Cst", "Pure", nil, -1},  // 4
		{"Cst", "List", nil, -1},  // 5（type.args の列を作るため）
		{"Apply", "", []int{5, 0}, -1},
	}
	return rows, map[string]int{"Int32": 0, "M.R": 1, "M.P": 2, "M.Q": 3, "Pure": 4}
}

func recSel(v string, id int, label, slot string) rwNode {
	return rwNode{kind: "Expr.RecordSelect", slot: slot, text: v + "#" + label, attrs: [][2]string{{"label", label}}, typ: "Int32", eff: "Pure", kids: []rwNode{
		{kind: "Expr.Var", slot: "exp", text: v, attrs: [][2]string{{"sym", fmt.Sprintf("%s#%d", v, id)}}, typ: "M.R", eff: "Pure"}}}
}

// recLit は `{ l1 = v#l1, l2 = v#l2, … }` の flixlint の形（頭は最初の欄から } まで・内側は欄ごと）。
func recLit(v string, id int, slot, typ string, labels ...string) rwNode {
	var build func(i int) rwNode
	build = func(i int) rwNode {
		var parts []string
		for _, l := range labels[i:] {
			parts = append(parts, l+" = "+v+"#"+l)
		}
		n := rwNode{kind: "Expr.RecordExtend", slot: "exp2", text: strings.Join(parts, ", ") + " }", attrs: [][2]string{{"label", labels[i]}}, typ: typ, eff: "Pure",
			kids: []rwNode{recSel(v, id, labels[i], "exp1")}}
		if i+1 < len(labels) {
			n.kids = append(n.kids, build(i+1))
		}
		return n
	}
	n := build(0)
	n.slot = slot
	return n
}

func recDecls() []rwNode {
	param := func(name string, id int, typ string) rwNode {
		return rwNode{kind: "FormalParam", slot: "fparams", text: name + ": " + typ, attrs: [][2]string{{"sym", fmt.Sprintf("%s#%d", name, id)}, {"tpe", "@" + typ}}}
	}
	use := func(text string, arg rwNode) rwNode {
		return rwNode{kind: "Expr.ApplyDef", slot: "exp", text: text, attrs: [][2]string{{"symUse", "B.use"}}, typ: "Int32", eff: "Pure", kids: []rwNode{arg}}
	}
	f := rwNode{kind: "Def", text: "def f(rect: M.R): M.P =\n        { x = rect#x, y = rect#y }", attrs: [][2]string{{"sym", "A.f"}}, kids: []rwNode{
		param("rect", 1, "M.R"), recLit("rect", 1, "exp", "M.P", "x", "y")}}
	g := rwNode{kind: "Def", text: "def g(r: M.R): Int32 = B.use({ x = r#x, y = r#y })", attrs: [][2]string{{"sym", "A.g"}}, kids: []rwNode{
		param("r", 2, "M.R"), use("B.use({ x = r#x, y = r#y })", recLit("r", 2, "exps", "M.P", "x", "y"))}}
	k := rwNode{kind: "Def", text: "def k(r: M.R): M.Q = { z = r#z, x = r#x, y = r#y }", attrs: [][2]string{{"sym", "A.k"}}, kids: []rwNode{
		param("r", 3, "M.R"), recLit("r", 3, "exp", "M.Q", "z", "x", "y")}}
	// 内側の { x = r#x, y = r#y } と同じ形（型も同じ）にして、欄ごとの内側の節を式と見ない事を確かめる。
	k.kids[1].kids[1].typ = "M.P"
	wv := rwNode{kind: "Expr.Var", slot: "exp", text: "w", nth: 1, attrs: [][2]string{{"sym", "w#4"}}, typ: "M.P", eff: "Pure"}
	upd := rwNode{kind: "Expr.RecordExtend", slot: "exps", text: "y = w#b | w", attrs: [][2]string{{"label", "y"}}, typ: "M.P", eff: "Pure", kids: []rwNode{
		{kind: "Expr.RecordSelect", slot: "exp1", text: "w#b", attrs: [][2]string{{"label", "b"}}, typ: "Int32", eff: "Pure", kids: []rwNode{
			{kind: "Expr.Var", slot: "exp", text: "w", attrs: [][2]string{{"sym", "w#4"}}, typ: "M.P", eff: "Pure"}}},
		{kind: "Expr.RecordRestrict", slot: "exp2", text: "y = w#b | w", attrs: [][2]string{{"label", "y"}}, typ: "M.P", eff: "Pure", kids: []rwNode{wv}},
	}}
	h := rwNode{kind: "Def", text: "def h(w: M.P): Int32 = B.use({ y = w#b | w })", attrs: [][2]string{{"sym", "A.h"}}, kids: []rwNode{
		param("w", 4, "M.P"), use("B.use({ y = w#b | w })", upd)}}
	return []rwNode{f, g, k, h}
}

func recRoot(t *testing.T) (*Ast, *reshapeSources) {
	t.Helper()
	types, ids := recTypes()
	a, srcs, _ := genRoot(t, genAst{src: recSrc, file: "src/A.flix", decls: recDecls(), types: types, typeID: ids, stage: "typed",
		kinds: recKinds, slots: recSlots, attrs: recAttrs})
	return a, srcs
}

// extract-function で record の式を選ぶ（位置は { から } まで）と、置く def の本体も呼ぶ所も波かっこごと書く。
// 3 つの欄の record の内側（`x = r#x, y = r#y }`）は同じ形でも字の上の式でないので替えない。
func TestExtractFunctionTakesTheWholeRecordWithItsBraces(t *testing.T) {
	a, srcs := recRoot(t)
	at := spanOfText("src/A.flix", recSrc, "{ x = rect#x, y = rect#y }", 0)
	plan, err := PlanExtract(a, srcs, ExtractQuery{Name: "A.mid", At: at, All: true})
	must(t, err)
	got, err := ApplyEdits(recSrc, plan.Edits)
	must(t, err)
	for _, w := range []string{
		"    def mid(rect: M.R): M.P =\n        { x = rect#x, y = rect#y }\n\n    def f(rect: M.R): M.P =\n        mid(rect)\n",
		"B.use(mid(r))",
		"{ z = r#z, x = r#x, y = r#y }",
	} {
		if !strings.Contains(got, w) {
			t.Errorf("%q が無い", w)
		}
	}
	if len(plan.Sites) != 2 {
		t.Fatalf("f と g の 2 か所（k の内側は替えない）: sites %d\n%s", len(plan.Sites), got)
	}
}

// rewrite の穴が record の式なら、波かっこごと写す（欄を替える形 { y = v | w } は { も } も範囲の外だった）。
func TestRewriteCopiesARecordHoleWithItsBraces(t *testing.T) {
	a, srcs := recRoot(t)
	plan, err := PlanRewrite(a, srcs, RewriteQuery{Rules: []RewriteRule{{From: "B.use($p)", To: "B.take($p)"}}})
	must(t, err)
	got, err := ApplyEdits(recSrc, plan.Edits)
	must(t, err)
	for _, w := range []string{"B.take({ x = r#x, y = r#y })", "B.take({ y = w#b | w })"} {
		if !strings.Contains(got, w) {
			t.Errorf("%q が無い:\n%s", w, got)
		}
	}
}

// 字の補間の切れ端（"a${・}b"）は式 1 つとして写せない。record の式の字は広げた後に閉じる。
func TestBracketBalance(t *testing.T) {
	for _, c := range []struct {
		s  string
		ok bool
	}{
		{`"\"${`, false}, {`}\""`, false}, {`"a${f("x")}b"`, true}, {`{ x = 1 }`, true}, {`x = 1 }`, false},
		{`f('}', "}") // }`, true}, {`(a, [b])`, true}, {`(a]`, false},
	} {
		if balancedExpr(c.s) != c.ok {
			t.Errorf("balancedExpr(%q) != %v", c.s, c.ok)
		}
	}
	src := "    f({\n        // 欄\n        x = 1 | w\n    })"
	s := strings.Index(src, "x = 1")
	ns, ne := widenBraces(src, s, s+len("x = 1 | w"))
	if got := src[ns:ne]; got != "{\n        // 欄\n        x = 1 | w\n    }" {
		t.Fatalf("コメントの行を飛ばして { 〜 } に広げる: %q", got)
	}
}

// ---- 呼び手が 0 になる def ----

const orphanSrc = `mod A {
    def f(r: Int32): Int32 = old(r) + pubOld(r)

    def g(r: Int32): Int32 = old(kept(r))

    def h(r: Int32): Int32 = kept(r) + mention(r)

    /// 古い入口。
    def old(r: Int32): Int32 = helper(r)

    def helper(r: Int32): Int32 = r

    def kept(r: Int32): Int32 = r

    def mention(r: Int32): Int32 = r

    pub def pubOld(r: Int32): Int32 = r
}
`

// orphanRows は orphanSrc の索引の行（def-decl と def-use）。
func orphanRows(t *testing.T) []Row {
	t.Helper()
	pos := func(text string, nth int) (int, int, int, int) {
		at := -1
		for i := 0; i <= nth; i++ {
			k := strings.Index(orphanSrc[at+1:], text)
			if k < 0 {
				t.Fatalf("%q が無い", text)
			}
			at += k + 1
		}
		li := newLineIndex(orphanSrc)
		l, c := li.posAt(at)
		el, ec := li.posAt(at + len(text))
		return l, c, el, ec
	}
	var rows []Row
	li := newLineIndex(orphanSrc)
	decl := func(name string, pub bool) {
		head := "def " + name + "("
		if pub {
			head = "pub " + head
		}
		at := strings.Index(orphanSrc, head)
		l, c := li.posAt(at)
		nl, nc := li.posAt(at + strings.Index(head, name))
		_, ec := li.posAt(at + strings.IndexByte(orphanSrc[at:], '\n'))
		extra := fmt.Sprintf("ext=%d:%d:%d:%d", l, c, l, ec)
		if pub {
			extra = "pub " + extra
		}
		rows = append(rows, Row{Kind: KindDefDecl, File: "src/A.flix", Line: nl, Col: nc, EndLine: nl, EndCol: nc + len(name), Sym: "A." + name, Owner: "A." + name, Extra: extra})
	}
	for _, d := range []string{"f", "g", "h", "old", "helper", "kept", "mention"} {
		decl(d, false)
	}
	decl("pubOld", true)
	use := func(name string, nth int, owner string) {
		l, c, el, ec := pos(name+"(", nth)
		rows = append(rows, Row{Kind: KindDefUse, File: "src/A.flix", Line: l, Col: c, EndLine: el, EndCol: ec - 1, Sym: "A." + name, Owner: "A." + owner})
	}
	use("old", 0, "f")
	use("pubOld", 0, "f")
	use("old", 1, "g")
	use("kept", 0, "g")
	use("kept", 1, "h")
	use("mention", 0, "h")
	use("helper", 0, "old")
	return rows
}

// 書き替えで呼ぶ所を失う def: pub でない old とその道連れ helper は doc ごと消す。g の中の kept は穴の字として
// 残り、h からも呼ばれるので残す。--to の字に名前が出る mention は残す。pub の pubOld は消さず数えるだけ。
func TestRewriteRemovesPrivateDefsThatLoseEveryCaller(t *testing.T) {
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, "src"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "src", "A.flix"), []byte(orphanSrc), 0o644))
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	site := func(before, after string) Edit {
		s := strings.Index(orphanSrc, before)
		return Edit{File: "src/A.flix", Start: s, End: s + len(before), Make: func(string) (string, error) { return after, nil }}
	}
	edits := []Edit{
		site("old(r) + pubOld(r)", "N.go(r)"),
		site("old(kept(r))", "N.go(kept(r))"),
		site("mention(r)", "N.go(mention(r))"),
	}
	plan, err := planOrphans(root, orphanRows(t), srcs, edits, []string{"N.go(r)", "N.go(kept(r))", "N.go(mention(r))"}, DeadQuery{})
	must(t, err)
	var removed []string
	for _, f := range plan.Removed {
		removed = append(removed, f.Sym)
	}
	if strings.Join(removed, ",") != "A.old,A.helper" || strings.Join(plan.Pub, ",") != "A.pubOld" {
		t.Fatalf("消す %v（want A.old・A.helper）・pub %v（want A.pubOld）", removed, plan.Pub)
	}
	got, err := ApplyEdits(orphanSrc, append(edits, plan.Edits...))
	must(t, err)
	for _, gone := range []string{"古い入口", "def old", "def helper"} {
		if strings.Contains(got, gone) {
			t.Errorf("%q が残る:\n%s", gone, got)
		}
	}
	for _, kept := range []string{"def kept", "def mention", "pub def pubOld", "N.go(kept(r))"} {
		if !strings.Contains(got, kept) {
			t.Errorf("%q が無い:\n%s", kept, got)
		}
	}
}
