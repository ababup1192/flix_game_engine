package refactor

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/acc は field-to-accessor のお手本（src/Rec.flix）。testdata/acc-spans-typed.tsv はそれに
// flixlint --spans --stage typed src を掛けた物。期待の字は書き換えの規則（読み e#x → R(e)、1 欄の書き →
// 口の呼び出し）から手で書いた物。

func accRows(t *testing.T) []Row {
	t.Helper()
	rows, err := ReadIndex(filepath.Join("testdata", "acc-spans-typed.tsv"), Typed)
	must(t, err)
	return rows
}

func accSrcs(t *testing.T) map[string]string {
	t.Helper()
	return map[string]string{"src/Rec.flix": read(t, filepath.Join("testdata", "acc"), "src/Rec.flix")}
}

// acc は testdata/acc を写した git の作業場（コミット済み）。
func acc(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, f := range []string{"flix.toml", "src/Rec.flix"} {
		data, err := os.ReadFile(filepath.Join("testdata", "acc", f))
		must(t, err)
		must(t, os.MkdirAll(filepath.Dir(filepath.Join(root, f)), 0o755))
		must(t, os.WriteFile(filepath.Join(root, f), data, 0o644))
	}
	must(t, os.WriteFile(filepath.Join(root, ".gitignore"), []byte("build/\nflixlint\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "flixlint"), []byte("stand-in\n"), 0o644))
	git(t, root, "init", "-q")
	git(t, root, "add", ".")
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-m", "fixture")
	return root
}

func accRunner(_ Stage, _, _ string, cmd []string, _ string) int {
	for i := 0; i+1 < len(cmd); i++ {
		if cmd[i] == "--spans" {
			data, err := os.ReadFile(filepath.Join("testdata", "acc-spans-typed.tsv"))
			if err != nil || os.WriteFile(cmd[i+1], data, 0o644) != nil {
				return 4
			}
		}
	}
	return 0
}

func runAcc(t *testing.T, root string, v VerifyRunner, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")), Options{Run: accRunner, Verify: v, Log: io.Discard})
	return code, out.String() + errOut.String()
}

var accArgs = []string{"field-to-accessor", "--label", "clock", "--receiver", "World", "--reader", "Rec.clockOf"}

func TestParseUpdateSplitsValueAndReceiver(t *testing.T) {
	for text, want := range map[string][2]string{
		"{ x = a |> f | w }":           {"a |> f", "w"},
		`{ x = "a|b" | w }`:            {`"a|b"`, "w"},
		"{ x = { y = 1 | r } | g(w) }": {"{ y = 1 | r }", "g(w)"},
		"{x=if (a or b) 1 else 2|w}":   {"if (a or b) 1 else 2", "w"},
	} {
		u, err := ParseUpdate(text)
		if err != nil || len(u.Fields) != 1 {
			t.Errorf("%q: %v %+v", text, err, u)
			continue
		}
		f := u.Fields[0]
		v, e := strings.TrimSpace(text[f.VStart:f.VEnd]), strings.TrimSpace(text[u.EStart:u.EEnd])
		if f.Name != "x" || v != want[0] || e != want[1] || u.End != len(text) {
			t.Errorf("%q: v %q・e %q・end %d", text, v, e, u.End)
		}
	}
}

func TestParseUpdateRefusesARecordWithoutReceiver(t *testing.T) {
	if _, err := ParseUpdate("{ x = 1, y = 2 }"); err == nil || !strings.Contains(err.Error(), "受け手の無い") {
		t.Errorf("record の式を更新として読んだ: %v", err)
	}
}

// 2 欄の更新は、替える欄を外し、受け手を口で包む（ほかの欄の値は元の受け手を読むまま）。
func TestRewriteUpdateTakesOneFieldOut(t *testing.T) {
	wrap := func(v, e string) string { return "S(" + v + ", " + e + ")" }
	for text, want := range map[string]string{
		"{ x = 1 | w }":                  "S(1, w)",
		"{ x = 1, y = 2 | w }":           "{ y = 2 | S(1, w) }",
		"{ y = 2, x = f(a, b) | g(w) }":  "{ y = 2 | S(f(a, b), g(w)) }",
		"{ y = 2, x = 1,\n  z = 3 | w }": "{ y = 2,\n  z = 3 | S(1, w) }",
	} {
		got, err := RewriteUpdate(text, "x", wrap)
		if err != nil || got != want {
			t.Errorf("%q: got %q %v（%q のはず）", text, got, err, want)
		}
	}
}

func TestPlanAccessorCounts(t *testing.T) {
	p, err := PlanAccessor(accSrcs(t), accRows(t), AccessorQuery{Label: "clock", Receiver: "World", Reader: AccessorName{"Rec", "clockOf"}, Mapper: AccessorName{"Rec", "mapClock"},
		OwnerSyms: []string{"Rec.clockOf", "Rec.mapClock", "Rec.withClock"}})
	must(t, err)
	// 読み: tick・sum 2・made・piped・total 2・spread・note = 9。書き: tick・reset・both・late・piped・total = 6。
	// 口の中: clockOf・mapClock 2・withClock = 4。fix: open（開いた row）= 1。畳む読み: tick・piped = 2。
	if p.Reads != 9 || p.Writes != 6 || p.Inside != 4 || len(p.Fix) != 1 || p.Folded != 2 {
		t.Errorf("読み %d・書き %d・口の中 %d・fix %v・畳む %d", p.Reads, p.Writes, p.Inside, p.Fix, p.Folded)
	}
}

func TestFieldToAccessorRewritesWithTheMapper(t *testing.T) {
	root := acc(t)
	var cmds []string
	code, text := runAcc(t, root, verifyWith(0, "", &cmds), append(accArgs, "--mapper", "Rec.mapClock", "--apply")...)
	src := read(t, root, "src/Rec.flix")
	for _, want := range []string{
		"pub def tick(dt: Float64, w: World): World = mapClock(clock -> clock + dt, w)",
		"pub def reset(w: World): World = mapClock(_ -> 0.0, w)",
		"pub def sum(a: World, b: World): Float64 = clockOf(a) + clockOf(b)",
		"pub def made(): Float64 = clockOf(make())",
		"pub def piped(w: World): World = mapClock(clock -> clock |> half, w)",
		"        mapClock(_ -> List.foldLeft((acc, v) -> acc + clockOf(v), 0.0, ws) + clockOf(w), w)",
		`"clock: ${clockOf(w)}"`,
		"pub def both(w: World): World = { speed = 2 | mapClock(_ -> 1.0, w) }",
		"pub def late(w: World): World = { speed = 3 | mapClock(_ -> 2.0, w) }",
		// 替えない物: 口そのもの・同じ名前の別の record の欄・開いた row。
		"pub def clockOf(w: World): Float64 = w#clock",
		"pub def otherClock(): Float64 = other()#clock",
		"r#clock",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い", want)
		}
	}
	if code != 0 || len(cmds) != 1 || cmds[0] != "make check" {
		t.Errorf("exit %d・確かめ %v\n%s\n%s", code, cmds, text, src)
	}
}

func TestFieldToAccessorWritesWithTheSetter(t *testing.T) {
	root := acc(t)
	var cmds []string
	runAcc(t, root, verifyWith(0, "", &cmds), append(accArgs, "--setter", "Rec.withClock", "--apply")...)
	src := read(t, root, "src/Rec.flix")
	for _, want := range []string{
		"pub def tick(dt: Float64, w: World): World = withClock(clockOf(w) + dt, w)",
		"pub def reset(w: World): World = withClock(0.0, w)",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い\n%s", want, src)
		}
	}
}

func TestFieldToAccessorWithoutAWriterLeavesTheWritesToFix(t *testing.T) {
	p, err := PlanAccessor(accSrcs(t), accRows(t), AccessorQuery{Label: "clock", Receiver: "World", Reader: AccessorName{"Rec", "clockOf"}, OwnerSyms: []string{"Rec.clockOf"}})
	must(t, err)
	// 書きの口の def（mapClock・withClock）も口として渡していないので、その中の書きも fix に並ぶ: 書き 8＋開いた row 1。
	if p.Writes != 0 || len(p.Fix) != 9 {
		t.Errorf("書き %d・fix %d %v", p.Writes, len(p.Fix), p.Fix)
	}
}

func TestFieldToAccessorDryRunWritesOnlyTheDiff(t *testing.T) {
	root := acc(t)
	before := read(t, root, "src/Rec.flix")
	code, text := runAcc(t, root, nil, append(accArgs, "--mapper", "Rec.mapClock")...)
	diff := read(t, root, "build/refactor/last.diff")
	if code != 0 || read(t, root, "src/Rec.flix") != before || !strings.Contains(diff, "+    pub def made(): Float64 = clockOf(make())") || !strings.Contains(text, "--apply") {
		t.Errorf("exit %d\n%s\n%s", code, text, diff)
	}
}

// 名指しした口が索引に無ければ、World を宣言したファイルの既存の …Of の後ろに作り、読みをそれへ替える。
func TestFieldToAccessorMakesAMissingAccessor(t *testing.T) {
	root := acc(t)
	code, text := runAcc(t, root, nil, "field-to-accessor", "--label", "clock", "--receiver", "World", "--getter", "Rec.nope", "--mapper", "Rec.mapClock")
	diff := read(t, root, "build/refactor/last.diff")
	if code != 0 || !strings.Contains(diff, "+    pub def nope(w: World): Float64 = w#clock") || !strings.Contains(text, "口を作る: Rec.nope") {
		t.Errorf("exit %d\n%s\n%s", code, text, diff)
	}
}

func TestFieldToAccessorRevertsWhenTheCheckFails(t *testing.T) {
	root := acc(t)
	before := read(t, root, "src/Rec.flix")
	var cmds []string
	code, text := runAcc(t, root, verifyWith(1, "-- Type Error -- src/Rec.flix:24\n", &cmds), append(accArgs, "--mapper", "Rec.mapClock", "--apply")...)
	if code != 1 || read(t, root, "src/Rec.flix") != before || !strings.Contains(text, "reverted") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestTypesOfTheReaderAndTheField(t *testing.T) {
	src := read(t, filepath.Join("testdata", "acc"), "src/Rec.flix")
	field, ok := AliasFieldType(src, "World", "clock")
	if !ok || field != "Float64" {
		t.Errorf("欄の型 %q %v（コメントを挟んでも Float64 のはず）", field, ok)
	}
	if got, ok := DefReturnType("/// doc\npub def f(a: Int32, g: Int32 -> Int32): Option[Map[String, Int32]] \\ IO = None"); !ok || got != "Option[Map[String, Int32]]" {
		t.Errorf("戻りの型 %q %v", got, ok)
	}
	if !SameType("World.Phase", "Phase") || SameType("Option[Phase]", "Phase") {
		t.Error("mod の修飾だけ違う型は同じ・Option で包んだ型は違うはず")
	}
}

// 口の戻りの型が欄の型と違えば、読みは替えずに fix（読む側の組み替えは人）。
func TestFieldToAccessorLeavesReadsWhenTheTypesDiffer(t *testing.T) {
	p, err := PlanAccessor(accSrcs(t), accRows(t), AccessorQuery{Label: "clock", Receiver: "World", Reader: AccessorName{"Rec", "clockOf"}, OwnerSyms: []string{"Rec.clockOf"},
		TypeWhy: "口 Rec.clockOf の戻り Option[Float64] と欄の型 Float64 が違う"})
	must(t, err)
	if p.Reads != 0 || len(p.Edits) != 0 {
		t.Errorf("型の違う口へ読みを替えた: 読み %d", p.Reads)
	}
}

// 本物の flixlint（typed）と flix で、お手本を口へ替えて flix check が通るか（FGE_REFACTOR_E2E=1 の時だけ）。
func TestEndToEndFieldToAccessor(t *testing.T) {
	if os.Getenv("FGE_REFACTOR_E2E") == "" {
		t.Skip("FGE_REFACTOR_E2E=1 の時だけ（本物の flixlint と flix を流す）")
	}
	jar, fl := os.Getenv("FLIX_JAR"), os.Getenv("FGE_FLIXLINT")
	root := acc(t)
	must(t, os.MkdirAll(filepath.Join(root, "bin", "lint-rules"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "bin", "lint-rules", "refactor.local.json"), []byte(`{"verify": "java -jar `+jar+` check"}`), 0o644))
	git(t, root, "add", ".")
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-qm", "conf")
	direct := func(_ Stage, _, dir string, cmd []string, _ string) int {
		c := exec.Command(cmd[0], cmd[1:]...)
		c.Dir, c.Stderr = dir, os.Stderr
		if c.Run() != nil {
			return 1
		}
		return 0
	}
	verify := func(cmd, dir, log string) int {
		c := exec.Command("sh", "-c", cmd+" > '"+log+"' 2>&1")
		c.Dir = dir
		if c.Run() != nil {
			return 1
		}
		return 0
	}
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, append(accArgs, "--mapper", "Rec.mapClock", "--apply", "--flixlint", fl), Options{Run: direct, Verify: verify, Log: io.Discard})
	if code != 0 || !strings.Contains(out.String(), "applied") {
		t.Fatalf("exit %d\n%s%s", code, out.String(), errOut.String())
	}
	t.Logf("%s", read(t, root, "src/Rec.flix"))
}
