package refactor

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/reshape は change-case-shape・change-signature のお手本（src/Mode.flix・src/Sig.flix・test/TestReshape.flix）。
// testdata/reshape-spans-resolved.tsv はそれに flixlint 0.6.6（adds=arg）の --spans --stage resolved src test を掛けた物。
// 期待の字は「宣言・作る所・当てる所（呼ぶ所）の欄（引数）の数が揃う」規則から手で書いた物。

func reshapeRoot(t *testing.T, edit map[string][2]string) string {
	t.Helper()
	root := t.TempDir()
	for _, f := range []string{"flix.toml", "src/Mode.flix", "src/Sig.flix", "test/TestReshape.flix"} {
		data, err := os.ReadFile(filepath.Join("testdata", "reshape", f))
		must(t, err)
		text := string(data)
		if e, ok := edit[f]; ok {
			if !strings.Contains(text, e[0]) || len(e[0]) != len(e[1]) {
				t.Fatalf("%s に %q が無いか、置き換えの長さが違う（索引の位置がずれる）", f, e[0])
			}
			text = strings.Replace(text, e[0], e[1], 1)
		}
		must(t, os.MkdirAll(filepath.Dir(filepath.Join(root, f)), 0o755))
		must(t, os.WriteFile(filepath.Join(root, f), []byte(text), 0o644))
	}
	must(t, os.WriteFile(filepath.Join(root, ".gitignore"), []byte("build/\nflixlint\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "flixlint"), []byte("stand-in\n"), 0o644))
	git(t, root, "init", "-q")
	git(t, root, "add", ".")
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-m", "fixture")
	return root
}

func reshapeRunner(stage Stage, _, _ string, cmd []string, _ string) int {
	for i := 0; i+1 < len(cmd); i++ {
		if cmd[i] == "--spans" {
			data, err := os.ReadFile(filepath.Join("testdata", "reshape-spans-"+string(stage)+".tsv"))
			if err != nil || os.WriteFile(cmd[i+1], data, 0o644) != nil {
				return 4
			}
		}
	}
	return 0
}

func runReshape(t *testing.T, root string, v VerifyRunner, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")), Options{Run: reshapeRunner, Verify: v, Log: io.Discard})
	return code, out.String() + errOut.String()
}

func mustContain(t *testing.T, text string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(text, w) {
			t.Errorf("%q が無い:\n%s", w, text)
		}
	}
}

func TestCaseShapeGivesANullaryCaseAField(t *testing.T) {
	root := reshapeRoot(t, nil)
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-case-shape", "--case", "Scene.Fight", "--add", "Int32", "--value", "0", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Mode.flix"), "case Fight(Int32)\n", "= Scene.Fight(0)\n", "case Scene.Fight(_)    =>", "case Scene.Fight(_) => true")
	mustContain(t, read(t, root, "test/TestReshape.flix"), "Mode.isFight(Scene.Fight(0))")
	mustContain(t, out, "done: 5 sites（宣言 1・作る所 2・当てる所 2）→ 0 left · check ok")
}

func TestCaseShapeAddsAtThePositionAndKeepsTheLayout(t *testing.T) {
	root := reshapeRoot(t, nil)
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-case-shape", "--case", "Mode.Scene.Cards", "--add", "String", "--at", "1", "--value", `"x"`, "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Mode.flix"), "case Cards(Int32, String, Bool)", "Scene.Cards(1,\n                                         \"x\", true)", "case Scene.Cards(_, _, p)")
}

func TestCaseShapeRemoveStopsWhereTheFieldIsUsedOrTheCaseIsPassed(t *testing.T) {
	root := reshapeRoot(t, nil)
	before := read(t, root, "src/Mode.flix")
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-case-shape", "--case", "Scene.Deck", "--remove", "0", "--apply")
	if code != 2 || len(cmds) != 0 || read(t, root, "src/Mode.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d・確かめ %d 回）:\n%s", code, len(cmds), out)
	}
	mustContain(t, out, "refused（人へ回す所 2", "src/Mode.flix:21:60  fix  case を関数として渡している", "src/Mode.flix:26:14  fix  消す欄の変数 n を腕の本体が使う")
}

func TestCaseShapeRemovingTheLastFieldLeavesANullaryCase(t *testing.T) {
	root := reshapeRoot(t, map[string][2]string{"src/Mode.flix": {`"menu ${m#cursor}"`, `"menu"            `}})
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-case-shape", "--case", "Scene.Menu", "--remove", "0", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Mode.flix"), "case Menu\n", "pub def menu(): Scene = Scene.Menu\n", "case Scene.Menu        =>")
	mustContain(t, out, "捨てる作る所の式のうち名前・字の値でない物 1")
}

func TestCaseShapeAddsALabelToTheRecordPayload(t *testing.T) {
	root := reshapeRoot(t, nil)
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-case-shape", "--case", "Scene.Menu", "--label", "top", "--type", "Int32", "--value", "0", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Mode.flix"), "case Menu({ at = Int32, cursor = Int32, top = Int32 })", "Scene.Menu({ at = 0, cursor = 1, top = 0 })", "case Scene.Menu(m)")
	mustContain(t, out, "record を丸ごと束ねて当てる所 1 はそのまま")
}

func TestCaseShapeTakesSeveralCasesAtOnce(t *testing.T) {
	root := reshapeRoot(t, nil)
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-case-shape", "--case", "Scene.Title,Scene.Fight", "--add", "Bool", "--value", "false", "--apply")
	if code != 0 || len(cmds) != 1 {
		t.Fatalf("終了コード %d・確かめ %d 回:\n%s", code, len(cmds), out)
	}
	mustContain(t, read(t, root, "src/Mode.flix"), "case Title(Bool)\n", "case Fight(Bool)\n", "case Scene.Title(_)    =>")
}

func TestSignatureMovesTheBodysExpressionsIntoTheParameters(t *testing.T) {
	root := reshapeRoot(t, nil)
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-signature", "--def", "Sig.draw,Sig.drawBoth",
		"--params", "env: Env, speed: Int32", "--args", "envOf(ctx, w), speedOf(w)", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	sig := read(t, root, "src/Sig.flix")
	mustContain(t, sig,
		"pub def draw(env: Env, speed: Int32): Int32 =\n        env#scale * env#clock + speed\n",
		"pub def drawBoth(env: Env, speed: Int32): Int32 =\n        draw(env, speed) + env#scale + speed\n",
		`"${name}: ${draw(envOf(ctx, w), speedOf(w))}"`,
		"draw(envOf(ctx, w), speedOf(w)) + draw(envOf({ scale = 2 }, w),\n                            speedOf(w))",
		"List.map(x -> draw(envOf(ctx, x), speedOf(x)), ws)")
	// mod の外の呼ぶ所では、テンプレートの素の名前の呼び出し（envOf）を def の mod で修飾する。
	mustContain(t, read(t, root, "test/TestReshape.flix"), "Sig.draw(Sig.envOf({ scale = 2 }, w), Sig.speedOf(w))")
	mustContain(t, out, "done: 8 sites（宣言 2・呼ぶ所 6）→ 0 left · check ok")
}

func TestSignatureStopsAtValuesDoubleEvaluationAndBodiesThatStillUseTheOldName(t *testing.T) {
	root := reshapeRoot(t, nil)
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-signature", "--def", "Sig.tick",
		"--params", "env: Env, speed: Int32", "--args", "envOf(ctx, w), speedOf(w)", "--apply")
	if code != 2 || len(cmds) != 0 {
		t.Fatalf("書かずに断るはず（終了コード %d）:\n%s", code, out)
	}
	// tick の本体（ctx#scale + w#speed）は envOf の欄 scale と speedOf の本体なので、下ごしらえ無しで替えられる（fix にしない）。
	mustContain(t, out, "refused（人へ回す所 2",
		"src/Sig.flix:34:9   fix  --args が 2 回使う引数に式が渡っている: w に `{ speed = 1 | w }`",
		"src/Sig.flix:34:50  fix  関数として渡している")
	if strings.Contains(out, "src/Sig.flix:31:13  fix") {
		t.Errorf("tick の本体は替えられるはず:\n%s", out)
	}
}

func TestSignatureReordersAndAddsWithIdentityTemplates(t *testing.T) {
	root := reshapeRoot(t, nil)
	var cmds []string
	code, out := runReshape(t, root, verifyWith(0, "", &cmds), "change-signature", "--def", "Sig.label",
		"--params", "name, ctx, w, n: Int32", "--args", "name, ctx, w, 0", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Sig.flix"), "pub def label(name: String, ctx: Ctx, w: World, n: Int32): String =")
}

func TestSubstituteParenthesizesOnlyWhereNeeded(t *testing.T) {
	old := []string{"ctx", "w"}
	for _, c := range []struct{ tmpl, ctx, w, want string }{
		{"envOf(ctx, w)", "c", "a + b", "envOf(c, a + b)"},
		{"w#speed + 1", "c", "f(x)", "(f(x))#speed + 1"},
		{"w", "c", "a + b", "a + b"},
		{"M.w(ctx#w)", "c", "z", "M.w(c#w)"},
		{"{ w = w }", "c", "z", "{ w = z }"},
	} {
		if got := Substitute(c.tmpl, old, []string{c.ctx, c.w}); got != c.want {
			t.Errorf("Substitute(%q) = %q（want %q）", c.tmpl, got, c.want)
		}
	}
}

func TestIdentUsesSkipsStringsButReadsInterpolation(t *testing.T) {
	text := `"w ${w#x}" + x.w + y#w + { w = 1 } + w // w`
	got := identUses(text, map[string]bool{"w": true})
	if len(got) != 2 {
		t.Fatalf("2 か所のはず: %v", got)
	}
}

// 並びの改行の形（1 行・1 つずつ改行・決まった桁で折る）は、元の並びから読んで新しい並びへ写す。
func TestJoinLayoutCopiesTheShapeOfTheOriginalList(t *testing.T) {
	for _, c := range []struct{ src, want string }{
		{"    f(a, b)", "env: ViewEnv.Env, dialog: Int32, lines: Int32"},
		{"    f(a,\n      b)", "env: ViewEnv.Env,\n      dialog: Int32,\n      lines: Int32"},
		// 1 行目は 56 桁まで（lines が入らずに折った）: 新しい並びも 56 桁で折る。
		{"    pub def box(ctx: Lib.Ctx, w: Lib.World,\n                lines: Int32)", "env: ViewEnv.Env, dialog: Int32,\n                lines: Int32"},
	} {
		l, _, err := argsAfter(c.src, strings.IndexByte(c.src, '('))
		must(t, err)
		if got := joinLayout([]string{"env: ViewEnv.Env", "dialog: Int32", "lines: Int32"}, readLayout(c.src, l)); got != c.want {
			t.Errorf("%q:\n got %q\nwant %q", c.src, got, c.want)
		}
	}
}

func TestRewriteCallArgsWrapsAtTheOriginalColumn(t *testing.T) {
	// 1 行目は 92 桁まで（z が入らずに折った）。ViewEnv.of(ctx, w) で伸びた分、最後の引数が次の行へ移る。
	src := "        View.cardAt(ctx, w, card, at, full, someLongArgumentName, anotherLongArgumentName,\n                    z)"
	l, _, err := argsAfter(src, strings.IndexByte(src, '('))
	must(t, err)
	old := []string{"ctx", "w", "card", "at", "full", "someLongArgumentName", "anotherLongArgumentName", "z"}
	got, err := rewriteCallArgs(src[l.Args[0][0]:l.Args[len(l.Args)-1][1]], old,
		append([]string{"ViewEnv.of(ctx, w)"}, old[2:]...), nil, readLayout(src, l))
	must(t, err)
	if want := "ViewEnv.of(ctx, w), card, at, full, someLongArgumentName,\n                    anotherLongArgumentName, z"; got != want {
		t.Fatalf("got %q（want %q）", got, want)
	}
}

// 本体の同じ式を引数の名前に替える時、数の字（0.0・10・1.0e-0）・字の値・コメントの途中には当てない。
// 字の値はまるごと同じ時だけ、字の補間の ${ } の中はコードとして当てる。
func TestLiftRulesDoNotSplitNumbersStringsOrComments(t *testing.T) {
	body := `List.foldLeft((a, x) -> a + x, 0.0, xs) + 0 + 10 + 1.0e-0 + f("0", "a 0 b", "${0}") // 0 を足す`
	got, n := applyRules(body, []liftRule{{pats: []string{"0"}, name: "probe"}}, nil)
	want := `List.foldLeft((a, x) -> a + x, 0.0, xs) + probe + 10 + 1.0e-0 + f("0", "a 0 b", "${probe}") // 0 を足す`
	if got != want || n != 2 {
		t.Fatalf("替えた数 %d\ngot:  %s\nwant: %s", n, got, want)
	}
	got, n = applyRules(`g("0", "00")`, []liftRule{{pats: []string{`"0"`}, name: "zero"}}, nil)
	if got != `g(zero, "00")` || n != 1 {
		t.Fatalf("字の値はまるごと同じ時だけ: %d %s", n, got)
	}
}
