package refactor

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// extract-function・extract-type-alias の当て方を、手で組んだ小さな汎用の AST（writeGenAst）で確かめる。
// 期待の字は「自由変数を出た順に引数へ・局所の名前の付け替えは同じ形・効果のある式を渡す所は外す」
// 「欄の順を問わず同じ組の record の型を名前へ・mod の外で使えば pub・本体がちょうどその組の別の alias は fix」の規則から書いた物。

// ---- extract-function ----

const exSrc = `mod A {
    pub def f(n: Int32, k: Int32): Int32 = B.add(B.dbl(n), k)

    def g(m: Int32): Int32 = B.add(B.dbl(B.inc(m)), 7)

    def h(m: Int32): Int32 = B.add(B.dbl(m), m)

    def j(): Int32 = B.add(B.dbl(B.readIO()), 1)

    def s(xs: List[Int32]): Int32 = B.sum(List.map(x -> B.dbl(x), xs))

    def t(ys: List[Int32]): Int32 = B.sum(List.map(y -> B.dbl(y), ys))
}
`

var (
	exKinds = []string{"Def", "FormalParam", "Expr.ApplyDef", "Expr.Var", "Expr.Cst", "Expr.Lambda"}
	exSlots = []string{"fparams", "fparam", "exp", "exps"}
	exAttrs = []string{"sym", "symUse", "tpe", "cst", "cst.lit"}
)

func exTypes() ([]rwTypeRow, map[string]int) {
	rows := []rwTypeRow{
		{"Cst", "Int32", nil, -1},      // 0
		{"Cst", "Pure", nil, -1},       // 1
		{"Effect", "IO", nil, -1},      // 2
		{"Cst", "List", nil, -1},       // 3
		{"Apply", "", []int{3, 0}, -1}, // 4 List[Int32]
	}
	return rows, map[string]int{"Int32": 0, "Pure": 1, "IO": 2, "List[Int32]": 4}
}

func exVar(name string, id, nth int) rwNode {
	return rwNode{kind: "Expr.Var", slot: "exps", text: name, nth: nth, attrs: [][2]string{{"sym", fmt.Sprintf("%s#%d", name, id)}}, typ: "Int32", eff: "Pure"}
}

func exCall(sym, text string, nth int, typ, eff string, kids ...rwNode) rwNode {
	return rwNode{kind: "Expr.ApplyDef", slot: "exps", text: text, nth: nth, attrs: [][2]string{{"symUse", sym}}, typ: typ, eff: eff, kids: kids}
}

func exParam(name string, id int, typ string) rwNode {
	return rwNode{kind: "FormalParam", slot: "fparams", text: name + ": " + typ, attrs: [][2]string{{"sym", fmt.Sprintf("%s#%d", name, id)}, {"tpe", "@" + typ}}}
}

func exDef(sym, text string, params []rwNode, body rwNode) rwNode {
	body.slot = "exp"
	return rwNode{kind: "Def", text: text, attrs: [][2]string{{"sym", sym}}, kids: append(params, body)}
}

func exDecls() []rwNode {
	lit := func(v string) rwNode {
		return rwNode{kind: "Expr.Cst", slot: "exps", text: v, attrs: [][2]string{{"cst", "Int32"}, {"cst.lit", v}}, typ: "Int32", eff: "Pure"}
	}
	addDbl := func(text string, arg, second rwNode, eff string) rwNode {
		return exCall("B.add", text, 0, "Int32", eff, exCall("B.dbl", "B.dbl(", 0, "Int32", eff, arg), second)
	}
	// B.dbl( の後ろの字は範囲の外まで伸ばす（手組みの位置は字を探して決めるので、呼び出しの範囲は書いた字の通りにする）。
	fixDbl := func(n rwNode, text string) rwNode { n.kids[0].text = text; return n }
	f := exDef("A.f", "pub def f(n: Int32, k: Int32): Int32 = B.add(B.dbl(n), k)",
		[]rwNode{exParam("n", 1, "Int32"), exParam("k", 2, "Int32")},
		fixDbl(addDbl("B.add(B.dbl(n), k)", exVar("n", 1, 0), exVar("k", 2, 0), "Pure"), "B.dbl(n)"))
	g := exDef("A.g", "def g(m: Int32): Int32 = B.add(B.dbl(B.inc(m)), 7)", []rwNode{exParam("m", 3, "Int32")},
		fixDbl(addDbl("B.add(B.dbl(B.inc(m)), 7)", exCall("B.inc", "B.inc(m)", 0, "Int32", "Pure", exVar("m", 3, 0)), lit("7"), "Pure"), "B.dbl(B.inc(m))"))
	h := exDef("A.h", "def h(m: Int32): Int32 = B.add(B.dbl(m), m)", []rwNode{exParam("m", 4, "Int32")},
		fixDbl(addDbl("B.add(B.dbl(m), m)", exVar("m", 4, 0), exVar("m", 4, 1), "Pure"), "B.dbl(m)"))
	j := exDef("A.j", "def j(): Int32 = B.add(B.dbl(B.readIO()), 1)", nil,
		fixDbl(addDbl("B.add(B.dbl(B.readIO()), 1)", exCall("B.readIO", "B.readIO()", 0, "Int32", "IO"), lit("1"), "IO"), "B.dbl(B.readIO())"))
	lam := func(v string, id int, list string, listID int) rwNode {
		return exCall("B.sum", "B.sum(List.map("+v+" -> B.dbl("+v+"), "+list+"))", 0, "Int32", "Pure",
			exCall("List.map", "List.map("+v+" -> B.dbl("+v+"), "+list+")", 0, "List[Int32]", "Pure",
				rwNode{kind: "Expr.Lambda", slot: "exps", text: v + " -> B.dbl(" + v + ")", typ: "Int32", eff: "Pure", kids: []rwNode{
					{kind: "FormalParam", slot: "fparam", text: v, attrs: [][2]string{{"sym", fmt.Sprintf("%s#%d", v, id)}}},
					{kind: "Expr.ApplyDef", slot: "exp", text: "B.dbl(" + v + ")", attrs: [][2]string{{"symUse", "B.dbl"}}, typ: "Int32", eff: "Pure", kids: []rwNode{exVar(v, id, 0)}},
				}},
				rwNode{kind: "Expr.Var", slot: "exps", text: list, attrs: [][2]string{{"sym", fmt.Sprintf("%s#%d", list, listID)}}, typ: "List[Int32]", eff: "Pure"}))
	}
	s := exDef("A.s", "def s(xs: List[Int32]): Int32 = B.sum(List.map(x -> B.dbl(x), xs))", []rwNode{exParam("xs", 5, "List[Int32]")}, lam("x", 6, "xs", 5))
	t := exDef("A.t", "def t(ys: List[Int32]): Int32 = B.sum(List.map(y -> B.dbl(y), ys))", []rwNode{exParam("ys", 7, "List[Int32]")}, lam("y", 8, "ys", 7))
	return []rwNode{f, g, h, j, s, t}
}

// genRoot は src を根の file に置き、手組みの AST を読む。
func genRoot(t *testing.T, g genAst) (*Ast, *reshapeSources, string) {
	t.Helper()
	tmp := t.TempDir()
	writeGenAst(t, filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint"), g)
	a, err := LoadAst(filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint", "bin", "flixlint"))
	must(t, err)
	root := filepath.Join(tmp, "root")
	must(t, os.MkdirAll(filepath.Dir(filepath.Join(root, g.file)), 0o755))
	must(t, os.WriteFile(filepath.Join(root, g.file), []byte(g.src), 0o644))
	return a, &reshapeSources{root: root, m: map[string]string{}}, root
}

// spanOfText は src の中の字 text（nth 番目）の範囲を file:L:C-L:C にする。
func spanOfText(file, src, text string, nth int) string {
	at := -1
	for i := 0; i <= nth; i++ {
		at = strings.Index(src[at+1:], text) + at + 1
	}
	pos := func(off int) (int, int) {
		before := src[:off]
		return strings.Count(before, "\n") + 1, off - strings.LastIndex(before, "\n")
	}
	l1, c1 := pos(at)
	l2, c2 := pos(at + len(text))
	return fmt.Sprintf("%s:%d:%d-%d:%d", file, l1, c1, l2, c2)
}

func exPlan(t *testing.T, q ExtractQuery) (*ExtractPlan, string) {
	t.Helper()
	types, ids := exTypes()
	a, srcs, _ := genRoot(t, genAst{src: exSrc, file: "src/A.flix", decls: exDecls(), types: types, typeID: ids, stage: "typed",
		kinds: exKinds, slots: exSlots, attrs: exAttrs})
	plan, err := PlanExtract(a, srcs, q)
	must(t, err)
	got, err := ApplyEdits(exSrc, plan.Edits)
	must(t, err)
	return plan, got
}

func TestExtractFunctionMakesTheDefAndCallsWithFreeVariables(t *testing.T) {
	at := spanOfText("src/A.flix", exSrc, "B.add(B.dbl(n), k)", 0)
	plan, got := exPlan(t, ExtractQuery{Name: "A.ext", At: at})
	want := strings.Replace(exSrc, "    pub def f(n: Int32, k: Int32): Int32 = B.add(B.dbl(n), k)",
		"    def ext(n: Int32, k: Int32): Int32 =\n        B.add(B.dbl(n), k)\n\n    pub def f(n: Int32, k: Int32): Int32 = ext(n, k)", 1)
	if got != want || len(plan.Sites) != 1 {
		t.Fatalf("sites %d\ngot:\n%s\nwant:\n%s", len(plan.Sites), got, want)
	}
}

func TestExtractFunctionAllReplacesSameShapeAndSkipsEffects(t *testing.T) {
	at := spanOfText("src/A.flix", exSrc, "B.add(B.dbl(n), k)", 0)
	plan, got := exPlan(t, ExtractQuery{Name: "A.ext", At: at, All: true})
	for _, w := range []string{"= ext(n, k)", "= ext(B.inc(m), 7)", "= ext(m, m)", "B.add(B.dbl(B.readIO()), 1)"} {
		if !strings.Contains(got, w) {
			t.Errorf("%q が無い", w)
		}
	}
	if len(plan.Sites) != 3 || plan.Excluded != 1 {
		t.Fatalf("同じ形の 3 か所を呼び出しへ・効果のある式を渡す 1 か所は外す: sites %d excluded %d\n%s", len(plan.Sites), plan.Excluded, got)
	}
}

func TestExtractFunctionTreatsRenamedLambdaParamsAsSameShape(t *testing.T) {
	at := spanOfText("src/A.flix", exSrc, "B.sum(List.map(x -> B.dbl(x), xs))", 0)
	plan, got := exPlan(t, ExtractQuery{Name: "A.sumDbl", At: at, All: true})
	if len(plan.Sites) != 2 || !strings.Contains(got, "= sumDbl(ys)") || !strings.Contains(got, "= sumDbl(xs)") {
		t.Fatalf("x と y の付け替えを同じ形と見ていない: sites %d\n%s", len(plan.Sites), got)
	}
	if !strings.HasPrefix(plan.Decl, "def sumDbl(xs: List[Int32]): Int32 =") {
		t.Fatalf("同じ mod の中だけで呼ぶ def は pub にしない・引数の型は書いた型: %s", plan.Decl)
	}
}

func TestExtractFunctionRefusesInexactRangeAndExistingName(t *testing.T) {
	types, ids := exTypes()
	a, srcs, _ := genRoot(t, genAst{src: exSrc, file: "src/A.flix", decls: exDecls(), types: types, typeID: ids, stage: "typed",
		kinds: exKinds, slots: exSlots, attrs: exAttrs})
	at := spanOfText("src/A.flix", exSrc, "B.add(B.dbl(n), ", 0)
	if _, err := PlanExtract(a, srcs, ExtractQuery{Name: "A.ext", At: at}); err == nil || !strings.Contains(err.Error(), "含む一番小さい式") {
		t.Fatalf("式の途中の範囲は、含む式を出して止める: %v", err)
	}
	full := spanOfText("src/A.flix", exSrc, "B.add(B.dbl(n), k)", 0)
	if _, err := PlanExtract(a, srcs, ExtractQuery{Name: "A.g", At: full}); err == nil || !strings.Contains(err.Error(), "もうある") {
		t.Fatalf("ある名前は止める: %v", err)
	}
}

// ---- extract-type-alias ----

const taSrc = `mod M {
    pub def f(a: { x = Int32, y = Int32 }): Int32 = a#x

    def g(b: { y = Int32, x = Int32 }, c: { x = Int32, y = Bool }): Int32 = b#y
}

mod N {
    /// 点。
    pub type alias P = { x = Int32, y = Int32 }

    def h(p: { x = Int32,
               y = Int32 }): Int32 = p#x
}
`

func taTypes() ([]rwTypeRow, map[string]int) {
	rows := []rwTypeRow{
		{"Cst", "Int32", nil, -1},          // 0
		{"Cst", "Bool", nil, -1},           // 1
		{"Cst", "RecordRowEmpty", nil, -1}, // 2
		{"RecordRow", "y", nil, -1},        // 3
		{"Apply", "", []int{3, 0}, -1},     // 4
		{"Apply", "", []int{4, 2}, -1},     // 5 ( y: Int32 | {} )
		{"RecordRow", "x", nil, -1},        // 6
		{"Apply", "", []int{6, 0}, -1},     // 7
		{"Apply", "", []int{7, 5}, -1},     // 8 ( x, y )
		{"Record", "", nil, -1},            // 9
		{"Apply", "", []int{9, 8}, -1},     // 10 { x, y }
		{"Apply", "", []int{7, 2}, -1},     // 11 ( x | {} )
		{"Apply", "", []int{4, 11}, -1},    // 12 ( y, x )
		{"Apply", "", []int{9, 12}, -1},    // 13 { y, x }
		{"Apply", "", []int{3, 1}, -1},     // 14
		{"Apply", "", []int{14, 2}, -1},    // 15 ( y: Bool | {} )
		{"Apply", "", []int{7, 15}, -1},    // 16
		{"Apply", "", []int{9, 16}, -1},    // 17 { x, y: Bool }
	}
	return rows, map[string]int{"Int32": 0, "{x,y}": 10, "{y,x}": 13, "{x,yBool}": 17}
}

func taDecls() []rwNode {
	param := func(text, sym, typ string) rwNode {
		return rwNode{kind: "FormalParam", slot: "fparams", text: text, attrs: [][2]string{{"sym", sym}, {"tpe", "@" + typ}}}
	}
	body := func(text string) rwNode {
		return rwNode{kind: "Expr.RecordSelect", slot: "exp", text: text, typ: "Int32"}
	}
	f := rwNode{kind: "Def", text: "pub def f(a: { x = Int32, y = Int32 }): Int32 = a#x", attrs: [][2]string{{"sym", "M.f"}}, kids: []rwNode{
		param("a: { x = Int32, y = Int32 }", "a#1", "{x,y}"), body("a#x")}}
	g := rwNode{kind: "Def", text: "def g(b: { y = Int32, x = Int32 }, c: { x = Int32, y = Bool }): Int32 = b#y", attrs: [][2]string{{"sym", "M.g"}}, kids: []rwNode{
		param("b: { y = Int32, x = Int32 }", "b#2", "{y,x}"), param("c: { x = Int32, y = Bool }", "c#3", "{x,yBool}"), body("b#y")}}
	p := rwNode{kind: "TypeAlias", text: "/// 点。\n    pub type alias P = { x = Int32, y = Int32 }", attrs: [][2]string{{"sym", "N.P"}, {"tpe", "@{x,y}"}}}
	h := rwNode{kind: "Def", text: "def h(p: { x = Int32,\n               y = Int32 }): Int32 = p#x", attrs: [][2]string{{"sym", "N.h"}}, kids: []rwNode{
		param("p: { x = Int32,\n               y = Int32 }", "p#4", "{x,y}"), body("p#x")}}
	return []rwNode{f, g, p, h}
}

func taPlan(t *testing.T, q TypeAliasQuery) (*TypeAliasPlan, string, error) {
	t.Helper()
	types, ids := taTypes()
	a, srcs, _ := genRoot(t, genAst{src: taSrc, file: "src/A.flix", decls: taDecls(), types: types, typeID: ids, stage: "resolved",
		kinds: []string{"Def", "FormalParam", "Expr.RecordSelect", "TypeAlias"}, slots: []string{"fparams", "exp"}, attrs: []string{"sym", "tpe"}})
	plan, err := PlanTypeAlias(a, srcs, q)
	if err != nil {
		return nil, "", err
	}
	got, err := ApplyEdits(taSrc, plan.Edits)
	must(t, err)
	return plan, got, nil
}

func TestExtractTypeAliasNamesEveryRecordWithTheSameFields(t *testing.T) {
	plan, got, err := taPlan(t, TypeAliasQuery{Name: "M.Point", From: "{ y = Int32, x = Int32 }", Doc: "点の座標。"})
	must(t, err)
	for _, w := range []string{
		"    /// 点の座標。\n    pub type alias Point = { x = Int32, y = Int32 }\n\n    pub def f(a: Point)",
		"def g(b: Point, c: { x = Int32, y = Bool })",
		"def h(p: M.Point): Int32",
	} {
		if !strings.Contains(got, w) {
			t.Errorf("%q が無い:\n%s", w, got)
		}
	}
	if len(plan.Sites) != 3 || plan.Excluded != 1 || len(plan.Fix) != 1 || !strings.Contains(plan.Fix[0].Why, "--name N.P") {
		t.Fatalf("欄の順の違う物も含め 3 か所・型の違う 1 つは数えるだけ・同じ組の alias N.P は fix: sites %d excluded %d fix %+v", len(plan.Sites), plan.Excluded, plan.Fix)
	}
}

func TestExtractTypeAliasReusesTheExistingAlias(t *testing.T) {
	plan, got, err := taPlan(t, TypeAliasQuery{Name: "N.P", At: "src/A.flix:2"})
	must(t, err)
	if !plan.Reused || plan.Decl != "" || len(plan.Sites) != 3 || !strings.Contains(got, "def f(a: N.P)") || !strings.Contains(got, "def h(p: P)") {
		t.Fatalf("もうある同じ組の alias を使い、宣言は足さない: reused %v sites %d\n%s", plan.Reused, len(plan.Sites), got)
	}
}

func TestExtractTypeAliasRefusesAnotherShapeUnderTheName(t *testing.T) {
	if _, _, err := taPlan(t, TypeAliasQuery{Name: "N.P", From: "{ x = Int32, y = Bool }"}); err == nil || !strings.Contains(err.Error(), "欄の組が違う") {
		t.Fatalf("違う組の alias の名前は止める: %v", err)
	}
	if _, _, err := taPlan(t, TypeAliasQuery{Name: "M.Q", From: "{ x = Int32, z = Int32 }"}); err == nil || !strings.Contains(err.Error(), "書いた所が無い") {
		t.Fatalf("型に書いていない組は止める: %v", err)
	}
}

func TestTypeTextMatchesBySuffix(t *testing.T) {
	for _, c := range []struct {
		w, f string
		ok   bool
	}{{"Vec2", "Vec2.Vec2", true}, {"List[Rect]", "List[Geometry.Rect]", true}, {"(Int32, Int32) -> Int32", "(Int32, Int32) -> Int32", true},
		{"Int32", "Int64", false}, {"ect", "Geometry.Rect", false}} {
		if typeTextMatches(c.w, c.f) != c.ok {
			t.Errorf("typeTextMatches(%q, %q) != %v", c.w, c.f, c.ok)
		}
	}
}

// ---- extract-type-alias の位置の指定と置き場 ----

// taSrc2 は doc つきの def の引数が次の行にある形と、見出しのコメント・型の宣言の並び。
const taSrc2 = `mod M {
    // ---- 型 ----

    /// 色。
    type alias C = Int32

    // ---- 描く ----

    /// 点を描く。
    def f(
        a: { x = Int32, y = Int32 }
    ): Int32 = a#x
}
`

// taSrc3 は型の宣言の無い mod（見出しの下に名前を使わない def、使う def には説明のコメント）。
const taSrc3 = `mod M {
    // ---- 読む ----

    def z(): Int32 = 1

    // 点を読む。
    def f(a: { x = Int32, y = Int32 }): Int32 = a#x

    def g(b: { y = Int32, x = Int32 }): Int32 = b#y
}
`

func taPlanOn(t *testing.T, src string, decls []rwNode, q TypeAliasQuery) (*TypeAliasPlan, string, error) {
	t.Helper()
	types, ids := taTypes()
	a, srcs, _ := genRoot(t, genAst{src: src, file: "src/A.flix", decls: decls, types: types, typeID: ids, stage: "resolved",
		kinds: []string{"Def", "FormalParam", "Expr.RecordSelect", "TypeAlias"}, slots: []string{"fparams", "exp"}, attrs: []string{"sym", "tpe"}})
	plan, err := PlanTypeAlias(a, srcs, q)
	if err != nil {
		return nil, "", err
	}
	got, err := ApplyEdits(src, plan.Edits)
	must(t, err)
	return plan, got, nil
}

func taDecls2() []rwNode {
	c := rwNode{kind: "TypeAlias", text: "/// 色。\n    type alias C = Int32", attrs: [][2]string{{"sym", "M.C"}, {"tpe", "@Int32"}}}
	f := rwNode{kind: "Def", text: "/// 点を描く。\n    def f(\n        a: { x = Int32, y = Int32 }\n    ): Int32 = a#x", attrs: [][2]string{{"sym", "M.f"}}, kids: []rwNode{
		{kind: "FormalParam", slot: "fparams", text: "a: { x = Int32, y = Int32 }", attrs: [][2]string{{"sym", "a#1"}, {"tpe", "@{x,y}"}}},
		{kind: "Expr.RecordSelect", slot: "exp", text: "a#x", typ: "Int32"}}}
	return []rwNode{c, f}
}

func taDecls3() []rwNode {
	param := func(text, sym, typ string) rwNode {
		return rwNode{kind: "FormalParam", slot: "fparams", text: text, attrs: [][2]string{{"sym", sym}, {"tpe", "@" + typ}}}
	}
	z := rwNode{kind: "Def", text: "def z(): Int32 = 1", attrs: [][2]string{{"sym", "M.z"}}}
	f := rwNode{kind: "Def", text: "def f(a: { x = Int32, y = Int32 }): Int32 = a#x", attrs: [][2]string{{"sym", "M.f"}}, kids: []rwNode{
		param("a: { x = Int32, y = Int32 }", "a#1", "{x,y}"), {kind: "Expr.RecordSelect", slot: "exp", text: "a#x", typ: "Int32"}}}
	g := rwNode{kind: "Def", text: "def g(b: { y = Int32, x = Int32 }): Int32 = b#y", attrs: [][2]string{{"sym", "M.g"}}, kids: []rwNode{
		param("b: { y = Int32, x = Int32 }", "b#2", "{y,x}"), {kind: "Expr.RecordSelect", slot: "exp", text: "b#y", typ: "Int32"}}}
	return []rwNode{z, f, g}
}

// lint の行（def の行）を渡すと、汎用の AST の宣言の始まり（/// の行）と 1 行ずれて当たらなかった。
func TestExtractTypeAliasAtTheDefLineOfADocumentedDecl(t *testing.T) {
	for _, q := range []TypeAliasQuery{
		{Name: "M.Point", At: "src/A.flix:10"},   // def の行（record は次の行）
		{Name: "M.Point", At: "src/A.flix:9"},    // /// の行
		{Name: "M.Point", At: "src/A.flix:11"},   // record の行
		{Name: "M.Point", From: "src/A.flix:10"}, // --from にも <file>:<行>
	} {
		plan, got, err := taPlanOn(t, taSrc2, taDecls2(), q)
		if err != nil {
			t.Fatalf("%+v: %v", q, err)
		}
		if len(plan.Sites) != 1 || !strings.Contains(got, "        a: Point\n") {
			t.Fatalf("%+v: sites %d\n%s", q, len(plan.Sites), got)
		}
	}
	if _, _, err := taPlanOn(t, taSrc2, taDecls2(), TypeAliasQuery{Name: "M.Point", At: "src/A.flix:5"}); err == nil {
		t.Fatalf("record の無い宣言の行は止める")
	}
}

func TestExtractTypeAliasPlacesAfterTheTypeDeclsWithDoc(t *testing.T) {
	_, got, err := taPlanOn(t, taSrc2, taDecls2(), TypeAliasQuery{Name: "M.Point", At: "src/A.flix:11", Doc: "点の座標。"})
	must(t, err)
	want := "    type alias C = Int32\n\n    /// 点の座標。\n    type alias Point = { x = Int32, y = Int32 }\n\n    // ---- 描く ----\n"
	if !strings.Contains(got, want) || !strings.HasPrefix(got, "mod M {\n    // ---- 型 ----\n\n    /// 色。\n") {
		t.Fatalf("型の宣言の並びの末尾に doc つきで置く:\n%s", got)
	}
}

func TestExtractTypeAliasPlacesBeforeTheFirstUserAndItsComment(t *testing.T) {
	plan, got, err := taPlanOn(t, taSrc3, taDecls3(), TypeAliasQuery{Name: "M.Point", From: "{ x = Int32, y = Int32 }"})
	must(t, err)
	want := "    def z(): Int32 = 1\n\n    type alias Point = { x = Int32, y = Int32 }\n\n    // 点を読む。\n    def f(a: Point)"
	if !strings.Contains(got, want) || strings.Contains(got, "///") || plan.DeclRow.Line != 6 {
		t.Fatalf("使う一番前の def の直前（付いたコメントごと前）に、--doc が無ければ doc なしで置く: decl row %d\n%s", plan.DeclRow.Line, got)
	}
}
