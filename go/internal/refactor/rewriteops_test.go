package refactor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// rewrite の型紙の演算子と中置の形を、flixlint の Generic が書く形で手で組んだ汎用の AST で確かめる。
// 木の形はコンパイラ（Flix 0.78 の Weeder2・Desugar・Resolver）が作る形: `::` は List.Cons の case、`:::` は
// List.append・`|>` `++` はその名前の頭の def・算術と比べは trait の sig の呼び出し・`and` は Expr.Binary・
// `{ a = e | r }` は RecordExtend(a, e, RecordRestrict(a, r))・List#{…} は Vector.toList(Vector#{…})・
// 引数の足りない呼び出し `List.map(f)` は構文が作ったラムダ（x -> List.map(f, x)）。ラムダの引数は FormalParam の下の Binder。

const opsSrc = `mod B {
    def a(x: Int32, xs: List[Int32]): List[Int32] = x + 1 :: xs
    def b(xs: List[Int32], ys: List[Int32]): List[Int32] = xs ::: ys
    def c(xs: List[Int32], f: Int32 -> Int32): List[Int32] = xs |> List.map(f)
    def d(x: Int32, y: Int32): Int32 = x + y * 2
    def e(r: { a = Int32 }): { a = Int32 } = { a = r#a + 1 | r }
    def g(xs: List[Int32]): List[Int32] = List.map(v -> v + 1, xs)
    def q(xs: List[Int32], y: Int32): List[Int32] = List.map(v -> y + 1, xs)
    def h(x: Int32, y: Int32): List[Int32] = List#{x, y}
    def k(x: Int32): Set[Int32] = Set#{x}
    def m(s: String, t: String): String = s ++ t
    def n(x: Int32, y: Int32): Bool = x < y and y >= 0
}
`

func opVar(slot, name, sym string) rwNode {
	return rwNode{kind: "Expr.Var", slot: slot, text: name, attrs: [][2]string{{"sym", sym}}}
}

func opInt(slot, lit string) rwNode {
	return rwNode{kind: "Expr.Cst", slot: slot, text: lit, attrs: [][2]string{{"cst", "Int32"}, {"cst.lit", lit}}}
}

// opCall は呼び出しの節（kind は Expr.ApplyDef・Expr.ApplySig・Expr.Tag。引数は exps）。
func opCall(kind, slot, sym, text string, kids ...rwNode) rwNode {
	for i := range kids {
		if kids[i].slot == "" {
			kids[i].slot = "exps"
		}
	}
	return rwNode{kind: kind, slot: slot, text: text, attrs: [][2]string{{"symUse", sym}}, kids: kids}
}

// opLambda はラムダ（引数 param を束ねる Binder の sym・本体 body）。synth は構文が作ったラムダ（引数の足りない呼び出し）。
func opLambda(slot, text, param, sym string, synth bool, body rwNode) rwNode {
	body.slot = "exp"
	return rwNode{kind: "Expr.Lambda", slot: slot, text: text, synth: synth, kids: []rwNode{
		{kind: "FormalParam", slot: "fparam", text: param, synth: synth, kids: []rwNode{
			{kind: "Binder", slot: "bnd", text: param, synth: synth, attrs: [][2]string{{"sym", sym}}},
		}},
		body,
	}}
}

func opDef(name, text string, body rwNode) rwNode {
	body.slot = "exp"
	return rwNode{kind: "Def", text: text, attrs: [][2]string{{"sym", "B." + name}}, kids: []rwNode{body}}
}

func opsDecls() []rwNode {
	line := func(name string) string {
		i := strings.Index(opsSrc, "def "+name+"(")
		return opsSrc[i : i+strings.IndexByte(opsSrc[i:], '\n')]
	}
	app, sig, tag := "Expr.ApplyDef", "Expr.ApplySig", "Expr.Tag"
	partial := opVar("exps", "List.map(f)", "x#9")
	partial.synth = true
	return []rwNode{
		opDef("a", line("a"), opCall(tag, "", "List.Cons", "x + 1 :: xs",
			opCall(sig, "", "Add.add", "x + 1", opVar("", "x", "x#0"), opInt("", "1")), opVar("", "xs", "xs#1"))),
		opDef("b", line("b"), opCall(app, "", "List.append", "xs ::: ys", opVar("", "xs", "xs#2"), opVar("", "ys", "ys#3"))),
		opDef("c", line("c"), opCall(app, "", "|>", "xs |> List.map(f)", opVar("", "xs", "xs#4"),
			opLambda("exps", "List.map(f)", "List.map(f)", "x#9", true,
				opCall(app, "", "List.map", "List.map(f)", opVar("", "f", "f#5"), partial)))),
		opDef("d", line("d"), opCall(sig, "", "Add.add", "x + y * 2", opVar("", "x", "x#6"),
			opCall(sig, "", "Mul.mul", "y * 2", opVar("", "y", "y#7"), opInt("", "2")))),
		// flixlint の範囲は { を含まない（alignSpans が { 〜 } に広げる）。書き替えの欄の外しは構文が作った内側の節。
		opDef("e", line("e"), rwNode{kind: "Expr.RecordExtend", text: "a = r#a + 1 | r", attrs: [][2]string{{"label", "a"}}, kids: []rwNode{
			opCall(sig, "exp1", "Add.add", "r#a + 1",
				rwNode{kind: "Expr.RecordSelect", slot: "exps", text: "r#a", attrs: [][2]string{{"label", "a"}}, kids: []rwNode{opVar("exp", "r", "r#8")}},
				opInt("", "1")),
			{kind: "Expr.RecordRestrict", slot: "exp2", text: "| r", attrs: [][2]string{{"label", "a"}}, kids: []rwNode{opVar("exp", "r", "r#8")}},
		}}),
		opDef("g", line("g"), opCall(app, "", "List.map", "List.map(v -> v + 1, xs)",
			opLambda("exps", "v -> v + 1", "v", "v#10", false, opCall(sig, "", "Add.add", "v + 1", opVar("", "v", "v#10"), opInt("", "1"))),
			opVar("", "xs", "xs#11"))),
		opDef("q", line("q"), opCall(app, "", "List.map", "List.map(v -> y + 1, xs)",
			opLambda("exps", "v -> y + 1", "v", "v#12", false, opCall(sig, "", "Add.add", "y + 1", opVar("", "y", "y#13"), opInt("", "1"))),
			opVar("", "xs", "xs#14"))),
		opDef("h", line("h"), opCall(app, "", "Vector.toList", "List#{x, y}",
			rwNode{kind: "Expr.VectorLit", slot: "exps", text: "List#{x, y}", kids: []rwNode{opVar("exps", "x", "x#15"), opVar("exps", "y", "y#16")}})),
		opDef("k", line("k"), opCall(app, "", "Vector.toSet", "Set#{x}",
			rwNode{kind: "Expr.VectorLit", slot: "exps", text: "Set#{x}", kids: []rwNode{opVar("exps", "x", "x#17")}})),
		opDef("m", line("m"), opCall(app, "", "++", "s ++ t", opVar("", "s", "s#18"), opVar("", "t", "t#19"))),
		opDef("n", line("n"), rwNode{kind: "Expr.Binary", text: "x < y and y >= 0", attrs: [][2]string{{"sop", "And"}}, kids: []rwNode{
			opCall(sig, "exp1", "Order.less", "x < y", opVar("", "x", "x#20"), opVar("", "y", "y#21")),
			opCall(sig, "exp2", "Order.greaterEqual", "y >= 0", opVar("", "y", "y#21"), opInt("", "0")),
		}}),
	}
}

// opsPlan は opsSrc に型紙の組を当てた計画と、当てた後の中身。
func opsPlan(t *testing.T, rules ...RewriteRule) (*RewritePlan, string) {
	t.Helper()
	tmp := t.TempDir()
	writeGenAst(t, filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint"), genAst{src: opsSrc, file: "src/B.flix", decls: opsDecls(), stage: "typed", types: []rwTypeRow{{"Cst", "Int32", nil, -1}, {"Cst", "List", nil, -1}, {"Apply", "", []int{1, 0}, -1}}, typeID: map[string]int{"Int32": 0},
		kinds: []string{"Def", "Binder", "FormalParam", "Expr.Ascribe", "Expr.ApplyClo", "Expr.ApplyDef", "Expr.ApplySig", "Expr.Binary", "Expr.Cst", "Expr.Lambda",
			"Expr.RecordExtend", "Expr.RecordRestrict", "Expr.RecordSelect", "Expr.Tag", "Expr.Var", "Expr.VectorLit"},
		slots: []string{"bnd", "exp", "exp1", "exp2", "exps", "fparam"},
		attrs: []string{"cst", "cst.lit", "label", "sop", "sym", "symUse"}})
	a, err := LoadAst(filepath.Join(tmp, "generic"), filepath.Join(tmp, "flixlint", "bin", "flixlint"))
	must(t, err)
	root := filepath.Join(tmp, "root")
	must(t, os.MkdirAll(filepath.Join(root, "src"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "src", "B.flix"), []byte(opsSrc), 0o644))
	plan, err := PlanRewrite(a, &reshapeSources{root: root, m: map[string]string{}}, RewriteQuery{Rules: rules})
	must(t, err)
	got, err := ApplyEdits(opsSrc, plan.Edits)
	must(t, err)
	return plan, got
}

// opsLine は書いた後の中身の def name の行。
func opsLine(got, name string) string {
	i := strings.Index(got, "def "+name+"(")
	if i < 0 {
		return ""
	}
	return got[i : i+strings.IndexByte(got[i:], '\n')]
}

func wantLine(t *testing.T, got, name, want string) {
	t.Helper()
	if l := opsLine(got, name); !strings.HasSuffix(l, want) {
		t.Errorf("def %s の行:\n  got  %s\n  want …%s", name, l, want)
	}
}

// ゲームの担当が書けなかった形。:: の左の穴の式（x + 1）は、--to で演算子の間に置くので包む。
func TestRewriteConsTemplate(t *testing.T) {
	plan, got := opsPlan(t, RewriteRule{From: "$x :: $xs", To: "$x :: List.reverse($xs)"})
	if len(plan.Sites) != 1 {
		t.Fatalf("sites %d（1 のはず）", len(plan.Sites))
	}
	wantLine(t, got, "a", "= (x + 1) :: List.reverse(xs)")
}

// 当たりの親が :: なら、原子でない --to の式を包む（包まないと x :: xs の左の結びつきが変わる）。
func TestRewriteInsideConsWrapsTheReplacement(t *testing.T) {
	_, got := opsPlan(t, RewriteRule{From: "$a + 1", To: "1 + $a"})
	wantLine(t, got, "a", "= (1 + x) :: xs")
	wantLine(t, got, "g", "List.map(v -> 1 + v, xs)") // ラムダの本体は包まない
	wantLine(t, got, "e", "= { a = 1 + r#a | r }")    // 欄の値も包まない
	wantLine(t, got, "q", "List.map(v -> 1 + y, xs)")
}

func TestRewriteAppendTemplate(t *testing.T) {
	_, got := opsPlan(t, RewriteRule{From: "$a ::: $b", To: "List.append($a, $b)"})
	wantLine(t, got, "b", "= List.append(xs, ys)")
}

// |> の右の List.map($f) は、コンパイラが作ったラムダ（x -> List.map(f, x)）に当てる。
func TestRewritePipeWithPartialCall(t *testing.T) {
	plan, got := opsPlan(t, RewriteRule{From: "$xs |> List.map($f)", To: "List.map($f, $xs)"})
	if len(plan.Sites) != 1 {
		t.Fatalf("sites %d（1 のはず）", len(plan.Sites))
	}
	wantLine(t, got, "c", "= List.map(f, xs)")
}

// 算術はコンパイラと同じ強さで読む: $a + $b * 2 は Add.add(a, Mul.mul(b, 2))。($a + $b) * 2 は別の木。
func TestRewriteArithmeticFollowsPrecedence(t *testing.T) {
	_, got := opsPlan(t, RewriteRule{From: "$a + $b * 2", To: "$a + 2 * $b"})
	wantLine(t, got, "d", "= x + 2 * y")
	if plan, _ := opsPlan(t, RewriteRule{From: "($a + $b) * 2", To: "B.z($a, $b)"}); len(plan.Sites) != 0 {
		t.Fatalf("(a + b) * 2 が a + b * 2 に当たった: %d", len(plan.Sites))
	}
}

func TestRewriteComparisonsUnderAnd(t *testing.T) {
	_, got := opsPlan(t, RewriteRule{From: "$x < $y and $y >= 0", To: "B.between($x, $y)"})
	wantLine(t, got, "n", "= B.between(x, y)")
}

// { a = e | r }（欄の書き替え）は RecordExtend(a, e, RecordRestrict(a, r))。{ +a = e | r }（足す）とは別の木。
func TestRewriteRecordUpdate(t *testing.T) {
	_, got := opsPlan(t, RewriteRule{From: "{ a = $v | $r }", To: "B.withA($v, $r)"})
	wantLine(t, got, "e", "= B.withA(r#a + 1, r)")
	if plan, _ := opsPlan(t, RewriteRule{From: "{ +a = $v | $r }", To: "B.withA($v, $r)"}); len(plan.Sites) != 0 {
		t.Fatalf("欄を足す型紙が欄の書き替えに当たった: %d", len(plan.Sites))
	}
}

// ラムダの引数は穴 $p でも名前でもよく、本体の中の名前はその引数だけを指す（q の y + 1 は外の y なので外れる）。
func TestRewriteLambdaParamsReferToTheParam(t *testing.T) {
	plan, got := opsPlan(t, RewriteRule{From: "List.map($p -> $p + 1, $xs)", To: "List.map($p -> $p + 2, $xs)"})
	if len(plan.Sites) != 1 {
		t.Fatalf("sites %d（g だけのはず）", len(plan.Sites))
	}
	wantLine(t, got, "g", "= List.map(v -> v + 2, xs)")
	plan, got = opsPlan(t, RewriteRule{From: "List.map(x -> x + 1, $xs)", To: "List.map(Int32.succ, $xs)"})
	if len(plan.Sites) != 1 {
		t.Fatalf("名前で書いた引数: sites %d（g だけのはず）", len(plan.Sites))
	}
	wantLine(t, got, "g", "= List.map(Int32.succ, xs)")
}

func TestRewriteCollectionLiterals(t *testing.T) {
	_, got := opsPlan(t, RewriteRule{From: "List#{$a, $b}", To: "$a :: $b :: Nil"}, RewriteRule{From: "Set#{$a}", To: "Set.singleton($a)"})
	wantLine(t, got, "h", "= x :: y :: Nil")
	wantLine(t, got, "k", "= Set.singleton(x)")
}

// ++ や |> のような記号だけの演算子は、その名前の頭の def の呼び出し。
func TestRewriteUserDefinedOperator(t *testing.T) {
	_, got := opsPlan(t, RewriteRule{From: "$s ++ $t", To: "String.concat($s, $t)"})
	wantLine(t, got, "m", "= String.concat(s, t)")
}

// tmplShape は型紙の木を ( 名前 子… ) の字にする（読んだ木の形を比べる）。
func tmplShape(t *Tmpl) string {
	var parts []string
	switch t.Kind {
	case tHole:
		return "$" + t.Name
	case tAny:
		return "_"
	case tLit:
		return t.Lit
	case tLocal:
		return t.Name
	case tLambda:
		p := t.Params[0]
		name := p.Name
		if p.Hole != "" {
			name = "$" + p.Hole
		} else if name == "" {
			name = "_"
		}
		parts = append(parts, "->", name)
	case tRecExtend:
		parts = append(parts, "ext", t.Name)
	case tRecRestrict:
		parts = append(parts, "res", t.Name)
	case tVector:
		parts = append(parts, "vec")
	default:
		parts = append(parts, t.Name)
	}
	for _, a := range t.Args {
		parts = append(parts, tmplShape(a))
	}
	return "(" + strings.Join(parts, " ") + ")"
}

func TestParseTmplOperatorShapes(t *testing.T) {
	for from, want := range map[string]string{
		"$a :: $b :: $c":              "(List.Cons $a (List.Cons $b $c))",
		"$a ::: $b :: $c":             "(List.append $a (List.Cons $b $c))",
		"$a + $b * $c":                "(Add.add $a (Mul.mul $b $c))",
		"$a - $b - $c":                "(Sub.sub (Sub.sub $a $b) $c)",
		"$a + $b |> $f":               "(Add.add $a (|> $b $f))", // 記号の演算子は + より強い（Flix の Parser2 と同じ）
		"$a |> $f |> $g":              "(|> (|> $a $f) $g)",
		"$a == $b and $c or $d":       "(Or (And (Eq.eq $a $b) $c) $d)",
		"not $a == $b":                "(Eq.eq (Not $a) $b)",
		"$a <=> $b":                   "(Order.compare $a $b)",
		"-$x * 2":                     "(Mul.mul (Neg.neg $x) 2)",
		"$a - -1":                     "(Sub.sub $a -1)",
		"$a :: $b == $c":              "(Eq.eq (List.Cons $a $b) $c)",
		"$a `B.max` $b":               "(B.max $a $b)",
		"$xs |> List.map(x -> x + 1)": "(|> $xs (List.map (-> x (Add.add x 1))))",
		"(x, _) -> f(x)":              "(-> x (-> _ (f x)))",
		"{ a = $v, -b | $r }":         "(ext a $v (res a (res b $r)))",
		"{ +a = $v | $r }#a":          "(a (ext a $v $r))",
		"List#{}":                     "(Vector.toList (vec))",
		"Set#{}":                      "(Set.empty )",
		"Vector#{$a}":                 "(vec $a)",
		"$r#a :: Nil":                 "(List.Cons (a $r) (Nil))",
	} {
		got, err := ParseTmpl(from)
		if err != nil {
			t.Errorf("%s: %v", from, err)
			continue
		}
		if s := tmplShape(got); s != want {
			t.Errorf("%s:\n  got  %s\n  want %s", from, s, want)
		}
	}
}

// 読めない形は「型紙の何文字目のどの形が読めない」を 1 行で返す。
func TestParseTmplNamesTheUnreadableForm(t *testing.T) {
	for from, want := range map[string]string{
		"$a <+> $b":         "4 字目の <+> が読めない",
		"$x instanceof Foo": "4 字目の instanceof が読めない",
		"$x[0]":             `3 字目の "[" が読めない`,
		"Map#{$k => $v}":    "1 字目の Map#{…} が読めない",
		"($x: Int32) -> $x": "4 字目の 型の注釈 : が読めない",
		"{ a = 1 }":         "1 字目の record の字の値 { … } が読めない",
		"($a, $b)":          "4 字目の タプル (a, b) が読めない",
		"let y = $x":        "1 字目の let が読めない",
	} {
		_, err := ParseTmpl(from)
		if err == nil || !strings.Contains(err.Error(), want) || strings.Contains(err.Error(), "\n") {
			t.Errorf("%s: 誤りに %q が 1 行で無い: %v", from, want, err)
		}
	}
}
