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
