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
// 型の値をもう持つ def（同じ型の引数 r・欄に Res を持つ Env の引数 env）は広げずに r・env#res を書く。Board.show（3 段上・別の mod）には型の use を足す計画になる。
func TestPropagateStopsAtNamedEntriesAndTypedParameters(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	before := read(t, root, "src/Rule.flix")
	code, out, cmds := runPropagate(t, root, "change-signature", "--def", "Rule.score",
		"--params", "res: Res, w", "--args", "@res, w", "--propagate", "--stop-at", "Rule.stopped", "--apply", "-v", "--all")
	if code != 2 || len(cmds) != 0 || read(t, root, "src/Rule.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out,
		"上へ広げた def 3・深さの最大 3: Rule.total（深さ 1・呼ぶ所 2）・Rule.twice（深さ 2・呼ぶ所 2）・Board.show（深さ 3・呼ぶ所 1）",
		"広げずに止めた def 3（中の呼ぶ所は fix。@名前=式 なら葉を直に呼ぶ所は式を書く）: --stop-at で名指しした def 1・@Test の def 1・引数の無い def 1",
		"型の値をもう持つ def 2（広げずに呼ぶ所へその式を書く）: Rule.shown → env#res・Rule.withRes → r",
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

// --params の型の名前が引けなければ（綴りの誤り・use の無い型）dry-run で警告する。修飾した名前は宣言の mod まで見る。
func TestSignatureWarnsAboutTypeNamesItCannotResolve(t *testing.T) {
	root := fixtureRoot(t, "propagate")
	_, out, _ := runPropagate(t, root, "change-signature", "--def", "Calc.leaf",
		"--params", "res: Ress, k: Kit.Res, z: Kit.Nope, w", "--args", "@res, @k, @z, w")
	mustContain(t, out, "警告: --params の型の名前 Ress（src/Calc.flix）・Kit.Nope（src/Calc.flix） が引けない")
}
