package refactor

import (
	"io"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/propagate は change-signature --propagate のお手本。testdata/propagate-spans-resolved.tsv はそれに
// flixlint 0.8.4 の --spans --stage resolved src test を掛けた物。Calc は上で止まらずに書ける鎖
// （leaf ← mid ← top。top は res をもう引数に持つ）、Rule と Board は止める所の揃った鎖。

func runPropagate(t *testing.T, root string, args ...string) (int, string, []string) {
	t.Helper()
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")),
		Options{Run: spansRunner("propagate"), Verify: verifyWith(0, "", &cmds), Log: io.Discard})
	return code, out.String() + errOut.String(), cmds
}

// 葉の leaf に res を足し（本体の Kit.defaults() は res に）、res を束ねていない mid にも同じ引数を先頭へ足し、res を引数に持つ top で止まる。
func TestPropagateAddsTheParameterUpToTheDefThatHasIt(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	code, out, cmds := runPropagate(t, root, "change-signature", "--def", "Calc.leaf",
		"--params", "res: Res, w", "--args", "@res=Kit.defaults(), w", "--propagate", "--apply")
	if code != 0 || len(cmds) != 1 {
		t.Fatalf("終了コード %d・確かめ %d 回:\n%s", code, len(cmds), out)
	}
	mustContain(t, read(t, root, "src/Calc.flix"),
		"pub def leaf(res: Res, w: Int32): Int32 = w + res#scale",
		"pub def mid(res: Res, w: Int32, k: Int32): Int32 = leaf(res, w) * k",
		"pub def top(res: Res, w: Int32): Int32 = mid(res, w, res#scale)")
	mustContain(t, out, "上へ広げた def 1・深さの最大 1: Calc.mid（深さ 1・呼ぶ所 1）")
	if strings.Contains(out, "警告") {
		t.Fatalf("Res は use で引ける（警告は要らない）:\n%s", out)
	}
}

// 止める所: --stop-at・引数の無い def・@Test。止めた def の中の呼ぶ所は fix で、fix があるので書かない。
// 型の値をもう持つ def（同じ型の引数 r・欄に Res を持つ Env の引数 env・使っていない印の同じ型の引数 _r）は広げずに
// r・env#res・res（_r は res に名前を替える）を書く。Board.show（3 段上・別の mod）には型の use を足す計画になる。
func TestPropagateStopsAtNamedEntriesAndTypedParameters(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	before := read(t, root, "src/Rule.flix")
	code, out, cmds := runPropagate(t, root, "change-signature", "--def", "Rule.score",
		"--params", "res: Res, w", "--args", "@res, w", "--propagate", "--stop-at", "Rule.stopped", "--apply", "-v", "--all")
	if code != 2 || len(cmds) != 0 || read(t, root, "src/Rule.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out,
		"上へ広げた def 3・深さの最大 3: Rule.total（深さ 1・呼ぶ所 3）・Rule.twice（深さ 2・呼ぶ所 2）・Board.show（深さ 3・呼ぶ所 1）",
		"関数として渡す所（先頭の引数 res を部分適用で書く）（Extra.scores）",
		"パイプ・部分適用の呼ぶ所（先頭に res を書く）（Extra.bonusOf）",
		"広げずに止めた def 3（中の呼ぶ所は fix。@名前=式 なら葉を直に呼ぶ所は式を書く）: --stop-at で名指しした def 1・@Test の def 1・引数の無い def 1",
		"型の値をもう持つ def 3（広げずに呼ぶ所へその式を書く）: Extra.quiet → res・Rule.shown → env#res・Rule.withRes → r",
		"使っていない印の _ の引数を使う def 1（引数を足さずに名前を替える）: Extra.quiet（_r → res）",
		"呼ぶ所（@res の代わりに env#res）（Rule.shown）",
		"葉の本体が res を使わない",
		"use を足す: Res（Kit.） → src/Board.flix")
}

// `@res=式` なら、止めた所には fix の代わりに式を書く。葉を直に呼ぶ所（stopped）も、上の段（entry・@Test）も、
// 式の使う元の引数（ここでは無し）が広げた def に同じ名前・同じ型であればその段の引数で書ける。fix が無いので書く。
func TestPropagateWritesTheExpressionWhereItStops(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	code, out, _ := runPropagate(t, root, "change-signature", "--def", "Rule.score",
		"--params", "res: Res, w", "--args", "@res=Kit.defaults(), w", "--propagate", "--stop-at", "Rule.stopped", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Rule.flix"),
		"pub def score(res: Res, w: Int32): Int32 = w * res#scale",
		"pub def stopped(w: Int32): Int32 = score(Kit.defaults(), w)",
		"pub def entry(): Int32 = twice(Kit.defaults(), 3)",
		"pub def withRes(r: Res, w: Int32): Int32 = score(r, w) + r#scale",
		"pub def shown(env: Kit.Env, w: Int32): Int32 = score(env#res, w) + env#n")
	mustContain(t, read(t, root, "test/TestRule.flix"), "Board.show(Kit.defaults(), 1)")
}

// 呼ぶ所を囲む def が同じ型の引数を使っていない印の名前（quiet の _r: Res）で持っていれば、res を足さずに（二重の
// `(res: Res, _r: Res, w)`・`quiet(res, res)` にしない）_r を res に名前を替えて呼ぶ所に書く。quiet を呼ぶ所は替えない。
func TestPropagateRenamesAnUnderscoreParameterOfTheSameType(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	code, out, _ := runPropagate(t, root, "change-signature", "--def", "Rule.score",
		"--params", "res: Res, w", "--args", "@res=Kit.defaults(), w", "--propagate", "--stop-at", "Rule.stopped", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	if extra := read(t, root, "src/Extra.flix"); !strings.Contains(extra, "pub def quiet(res: Res, w: Int32): Int32 = Rule.score(res, w)") || strings.Contains(extra, "_r") {
		t.Errorf("_r を res に替えていない・引数を足した:\n%s", extra)
	}
	mustContain(t, out, "使っていない印の _ の引数を使う def 1（引数を足さずに名前を替える）: Extra.quiet（_r → res）")
}

// --params の型の名前が引けなければ（綴りの誤り・use の無い型）dry-run で警告する。修飾した名前は宣言の mod まで見る。
func TestSignatureWarnsAboutTypeNamesItCannotResolve(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	_, out, _ := runPropagate(t, root, "change-signature", "--def", "Calc.leaf",
		"--params", "res: Ress, k: Kit.Res, z: Kit.Nope, w", "--args", "@res, @k, @z, w")
	mustContain(t, out, "警告: --params の型の名前 Ress（src/Calc.flix）・Kit.Nope（src/Calc.flix） が引けない")
}

// 型の別名が Unit（Blank = Unit）の def を --args に書いても、本体の値の () は引数へ替えない（名前の無い式は同じ値と限らない）。
func TestSignatureDoesNotLiftTheUnitValue(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	code, out, _ := runPropagate(t, root, "change-signature", "--def", "Extra.screen",
		"--params", "b: Blank, w", "--args", "Extra.blankOf(w), w", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Extra.flix"), "pub def screen(b: Blank, w: Int32): (Int32, Unit) = if (w > 0) (w, b) else (0, ())")
}

// _ で始まる引数（_r）は型が同じでも選ばない（Flix は使うと誤りにする）。パイプ・関数として渡す所は先頭に res を書く。
func TestSignatureSkipsUnderscoreNamesAndWritesIntoPipes(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	code, out, _ := runPropagate(t, root, "change-signature", "--def", "Rule.score",
		"--params", "res: Res, w", "--args", "@res=Kit.defaults(), w", "--prefer-local", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Extra.flix"),
		"pub def quiet(_r: Res, w: Int32): Int32 = Rule.score(Kit.defaults(), w)",
		"List.map(Rule.score(res), ws)",
		"(w |> Rule.score(res)) + res#scale")
	mustContain(t, read(t, root, "src/Rule.flix"), "pub def withRes(r: Res, w: Int32): Int32 = score(r, w) + r#scale")
}

// 呼ぶ所が `(_, x) -> tip(x)` の中なら、前にある別の lambda `(res, x) -> …` の res は使えない（その外では束ねていない）。
// どの _ に res が来るかは決めずに人へ回し、res を束ねる lambda の中の呼ぶ所だけ res を書く。
func TestSignatureDoesNotUseANameBoundByAnotherLambda(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	before := read(t, root, "src/Extra.flix")
	code, out, _ := runPropagate(t, root, "change-signature", "--def", "Extra.tip",
		"--params", "res: Res, w", "--args", "@res=Kit.defaults(), w", "--propagate", "--apply", "--all")
	if code != 2 || read(t, root, "src/Extra.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out,
		"fix  呼ぶ所に局所の名前 @res が無く、囲む lambda (_, x) -> の引数に _ がある（@res の値が入る所なら _ を res に替えてから流し直す。",
		"呼ぶ所（Extra.viaLambda）")
}
