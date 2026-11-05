package quadratic

// 何を守るか: 蓄積を List.append の第 1 引数に置く形 (欄・タプルで分解した別名も) と、
// 文字列の蓄積に足していく形を拾うこと。正しい書き方 (:: で積む・数の合計・名前付き関数を渡す) は
// 鳴らさないこと。コミット時は足した行だけを見ること・除外と --warn の扱い。

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func kinds(src string) string {
	var out []string
	for _, h := range Scan("a.flix", src) {
		out = append(out, h.Kind+":"+h.Acc)
	}
	return strings.Join(out, " ")
}

func TestAppendToAccumulatorFires(t *testing.T) {
	for _, tc := range []struct{ src, want string }{
		{"def f(xs: List[Int32]): List[Int32] =\n    List.foldLeft((acc, x) -> List.append(acc, x :: Nil), Nil, xs)", "append:acc"},
		{"def f(): Unit =\n    List.foldLeft((s, row) -> { drawables = List.append(s#drawables, row), n = 1 }, init, rows)", "append:s"},
		{"def f(): Unit =\n    xs |> List.foldLeft((acc2, ch) -> {\n        let (done, x) = acc2;\n        (List.append(done, ch :: Nil), x)\n    }, (Nil, 0))", "append:done"},
		{"def f(): Unit =\n    List.foldRight((x, acc) -> List.append(acc, x :: Nil), Nil, xs)", "append:acc"},
	} {
		if got := kinds(tc.src); got != tc.want {
			t.Fatalf("%q: got %q want %q", tc.src, got, tc.want)
		}
	}
}

func TestStringGrowthFires(t *testing.T) {
	for _, tc := range []struct{ src, want string }{
		{"def f(): String = cs |> List.map(Char.toString) |> List.foldLeft(String.concat, \"\")", "string:String.concat"},
		{"def f(): String = List.foldLeft((acc, c) -> \"${acc}${c}\", \"\", cs)", "string:acc"},
		{"def f(): String = List.foldLeft((acc, c) -> String.concat(acc, c), \"\", cs)", "string:acc"},
		{"def f(): String =\n    let (text, _) = List.foldLeft((acc, nf) -> {\n        let (out, env) = acc;\n        (out + line(nf), env)\n    }, (\"\", Map.empty()), bs);\n    text", "string:out"},
	} {
		if got := kinds(tc.src); got != tc.want {
			t.Fatalf("%q: got %q want %q", tc.src, got, tc.want)
		}
	}
}

func TestQuietOnTheRightShapes(t *testing.T) {
	for _, src := range []string{
		"def f(): List[Int32] = List.reverse(List.foldLeft((acc, x) -> x :: acc, Nil, xs))",
		"def f(): Int32 = List.foldLeft((acc, x) -> acc + x, 0, xs)",
		"def f(): List[Int32] = List.foldLeft((acc, x) -> List.append(x :: Nil, acc), Nil, xs)",
		"def f(): List[Int32] = List.foldLeft(merge, Nil, xs)",
		"def f(): Unit = // List.foldLeft((acc, x) -> List.append(acc, x), Nil, xs)\n    ()",
		"def f(): String = \"List.foldLeft((acc, x) -> List.append(acc, x), Nil, xs)\"",
	} {
		if got := kinds(src); got != "" {
			t.Fatalf("%q で鳴った: %s", src, got)
		}
	}
}

func TestHitNamesTheEnclosingDef(t *testing.T) {
	hits := Scan("a.flix", "mod A {\n    def build(xs: List[Int32]): List[Int32] =\n        List.foldLeft((acc, x) -> List.append(acc, x :: Nil), Nil, xs)\n}")
	if len(hits) != 1 || hits[0].Def != "build" || hits[0].Line != 3 {
		t.Fatalf("%+v", hits)
	}
}

func writeRepo(t *testing.T, exempt string) string {
	t.Helper()
	root := t.TempDir()
	put := func(rel, body string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	put("bin/lint-rules/quadratic.json", `{"scopeSuffixes":[".flix"],"skipPrefixes":["testdata/"],"skipDirNames":["lib","test"],"exempt":`+exempt+`}`)
	put("src/Old.flix", "mod Old {\n    def old(xs: List[Int32]): List[Int32] =\n        List.foldLeft((acc, x) -> List.append(acc, x :: Nil), Nil, xs)\n}\n")
	put("test/TestOld.flix", "def t(): List[Int32] = List.foldLeft((acc, x) -> List.append(acc, x :: Nil), Nil, xs)\n")
	return root
}

func run(t *testing.T, root string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
}

func TestStagedLooksOnlyAtAddedLines(t *testing.T) {
	root := writeRepo(t, `{}`)
	run(t, root, "init", "-q")
	run(t, root, "add", ".")
	run(t, root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
	body := "mod Old {\n    def old(xs: List[Int32]): List[Int32] =\n        List.foldLeft((acc, x) -> List.append(acc, x :: Nil), Nil, xs)\n" +
		"    def added(cs: List[String]): String =\n        List.foldLeft((s, c) -> \"${s}${c}\", \"\", cs)\n}\n"
	if err := os.WriteFile(filepath.Join(root, "src/Old.flix"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, root, "add", ".")
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, nil)
	if err != nil || code != 1 || !strings.Contains(errOut.String(), "src/Old.flix:5 (added)") || strings.Contains(errOut.String(), "(old)") {
		t.Fatalf("code=%d err=%v\n%s", code, err, errOut.String())
	}
}

func TestAllSkipsTestDirsAndExemptAndStale(t *testing.T) {
	root := writeRepo(t, `{"src/Old.flix::old":"N は 3 で決まっている","src/Old.flix::gone":"消えた"}`)
	var out, errOut strings.Builder
	code, _ := Run(&out, &errOut, root, []string{"--all"})
	if code != 1 || strings.Contains(errOut.String(), "TestOld") || strings.Contains(errOut.String(), "(old)") ||
		!strings.Contains(errOut.String(), "src/Old.flix::gone は exempt") {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}

func TestWarnExitsZero(t *testing.T) {
	root := writeRepo(t, `{}`)
	var out, errOut strings.Builder
	if code, _ := Run(&out, &errOut, root, []string{"--warn", "--all"}); code != 0 || !strings.Contains(errOut.String(), "(old)") {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}

// ゲームの除外 (quadratic.local.json) はエンジンの規約に足される。両方にある鍵は止める。
func TestLocalExemptIsMerged(t *testing.T) {
	root := writeRepo(t, `{}`)
	local := filepath.Join(root, "bin/lint-rules/quadratic.local.json")
	if err := os.WriteFile(local, []byte(`{"exempt":{"src/Old.flix::old":"描き出しの道具で N は 3"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, []string{"--all"}); err != nil || code != 0 {
		t.Fatalf("code=%d err=%v\n%s", code, err, errOut.String())
	}
	root2 := writeRepo(t, `{"src/Old.flix::old":"エンジン側"}`)
	if err := os.WriteFile(filepath.Join(root2, "bin/lint-rules/quadratic.local.json"), []byte(`{"exempt":{"src/Old.flix::old":"ゲーム側"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadRules(root2); err == nil || !strings.Contains(err.Error(), "両方") {
		t.Fatalf("重なった鍵が通った: %v", err)
	}
}

// 配られたエンジンの除外 (このリポに無いファイル) は古いと言わない。
func TestExemptForAbsentFileIsNotStale(t *testing.T) {
	root := writeRepo(t, `{"render_gl/src/FontCache.flix::fontHash":"N は 8 で決まっている","src/Old.flix::old":"N は 3"}`)
	var out, errOut strings.Builder
	if code, _ := Run(&out, &errOut, root, []string{"--all"}); code != 0 {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}

func nearLines(src string) string {
	var out []string
	for _, h := range ScanNear("a.flix", src) {
		out = append(out, h.Loop+">"+h.Scan+"@"+h.Def)
	}
	return strings.Join(out, " ")
}

func TestNearScanFiresInsideLoopLambda(t *testing.T) {
	for _, tc := range []struct{ src, want string }{
		{"def f(xs: List[Int32]): List[Int32] =\n    xs |> List.map(x -> xs |> List.filter(y -> y != x) |> List.length)", "List.map>List.filter@f"},
		{"def f(): Bool = List.forAll(a -> List.exists(b -> a == b, bs), as)", "List.forAll>List.exists@f"},
		{"def f(): Int32 = List.foldLeft((acc, e) -> acc + List.length(List.filter(o -> o == e, es)), 0, es)", "List.foldLeft>List.filter@f"},
		{"def f(): Unit = Vector.map(v -> List.find(o -> o == v, os), vs)", "Vector.map>List.find@f"},
	} {
		if got := nearLines(tc.src); got != tc.want {
			t.Fatalf("%q: got %q want %q", tc.src, got, tc.want)
		}
	}
}

// 回すラムダが呼ぶ同じファイルの def の中も 1 段だけ見る (押し合いの近所を毎回作る形がこれ)。
func TestNearScanFollowsOneCallInTheSameFile(t *testing.T) {
	src := "def separate(ds: List[Disc]): List[Disc] =\n    ds |> List.map(d -> apart(ds, d))\n" +
		"def apart(ds: List[Disc], d: Disc): Disc =\n    let others = ds |> List.filter(o -> o#id != d#id);\n    push(others, d)\n"
	hits := ScanNear("a.flix", src)
	if len(hits) != 1 || hits[0].Def != "apart" || hits[0].Line != 4 || hits[0].LoopLine != 2 {
		t.Fatalf("%+v", hits)
	}
}

func TestNearScanQuietOnTheRightShapes(t *testing.T) {
	for _, src := range []string{
		"def f(): List[Int32] = xs |> List.filter(x -> x > 0) |> List.map(x -> x + 1)",
		"def f(): List[Int32] = List.map(lookup, xs)",
		"def f(): Unit =\n    let far = xs |> List.filter(x -> x > 0);\n    ys |> List.map(y -> y + 1)",
		"def f(): Unit = xs |> List.map(x -> x + 1) // List.map(x -> List.filter(p, xs))",
		"def f(): Unit = xs |> List.map(x -> Other.apart(x))\ndef apart(x: Int32): Bool = List.exists(p, xs)",
	} {
		if got := nearLines(src); got != "" {
			t.Fatalf("%q で鳴った: %s", src, got)
		}
	}
}

// 知らせるだけで、終了コードは変えない。除外に載せれば黙り、古い除外とも言わない。
func TestNearScanOnlyNotifies(t *testing.T) {
	root := writeRepo(t, `{"src/Old.flix::old":"N は 3"}`)
	body := "mod Near {\n    def near(xs: List[Int32]): List[Int32] =\n        xs |> List.map(x -> List.length(List.filter(y -> y == x, xs)))\n}\n"
	if err := os.WriteFile(filepath.Join(root, "src/Near.flix"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, []string{"--all"})
	if err != nil || code != 0 || !strings.Contains(out.String(), "src/Near.flix:3 (near)") || !strings.Contains(out.String(), "SpatialGrid") {
		t.Fatalf("code=%d err=%v\n%s\n%s", code, err, out.String(), errOut.String())
	}
	root2 := writeRepo(t, `{"src/Old.flix::old":"N は 3","src/Near.flix::near":"N は 4 で決まっている"}`)
	if err := os.WriteFile(filepath.Join(root2, "src/Near.flix"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var out2, errOut2 strings.Builder
	if code, _ := Run(&out2, &errOut2, root2, []string{"--all"}); code != 0 || strings.Contains(out2.String(), "(near)") {
		t.Fatalf("code=%d\n%s\n%s", code, out2.String(), errOut2.String())
	}
}
