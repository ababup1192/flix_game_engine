package refactor

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testdata/proj は書き換えの操作のお手本（src/Zoo.flix・src/Main.flix・test/TestZoo.flix）。
// testdata/proj-spans-resolved.tsv はそれに flixlint --spans --stage resolved src test を掛けた物。

func zooRows(t *testing.T) []Row {
	t.Helper()
	rows, err := ReadIndex(filepath.Join("testdata", "proj-spans-resolved.tsv"), Resolved)
	must(t, err)
	return rows
}

// zoo は proj を写した git の作業場（コミット済み）を作る。
func zoo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, f := range []string{"flix.toml", "src/Zoo.flix", "src/Main.flix", "test/TestZoo.flix"} {
		data, err := os.ReadFile(filepath.Join("testdata", "proj", f))
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

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Skipf("git が使えない: %v %s", err, out)
	}
	return string(out)
}

func read(t *testing.T, root, f string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, f))
	must(t, err)
	return string(data)
}

func zooRunner(_ Stage, _, _ string, cmd []string, _ string) int {
	for i := 0; i+1 < len(cmd); i++ {
		if cmd[i] == "--spans" {
			data, err := os.ReadFile(filepath.Join("testdata", "proj-spans-resolved.tsv"))
			if err != nil || os.WriteFile(cmd[i+1], data, 0o644) != nil {
				return 4
			}
		}
	}
	return 0
}

// verifyWith は確かめの代わり: 終了コード code を返し、log に msg を書く。呼ばれた口を cmds に積む。
func verifyWith(code int, msg string, cmds *[]string) VerifyRunner {
	return func(cmd, dir, log string) int {
		*cmds = append(*cmds, cmd)
		os.WriteFile(log, []byte(msg), 0o644)
		return code
	}
}

func runZoo(t *testing.T, root string, v VerifyRunner, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")), Options{Run: zooRunner, Verify: v, Log: io.Discard})
	return code, out.String() + errOut.String()
}

func edit(s, e int, f func(string) string) Edit {
	return Edit{Start: s, End: e, Make: func(c string) (string, error) { return f(c), nil }}
}

func TestApplyEditsAppliesTheInnerEditFirst(t *testing.T) {
	got, err := ApplyEdits("abcdef", []Edit{
		edit(1, 5, func(c string) string { return "[" + c + "]" }),
		edit(2, 4, strings.ToUpper),
	})
	if err != nil || got != "a[bCDe]f" {
		t.Errorf("got %q %v", got, err)
	}
}

func TestApplyEditsShiftsTheEditsBehind(t *testing.T) {
	got, err := ApplyEdits("ab cd", []Edit{
		edit(0, 2, func(string) string { return "xyz" }),
		edit(3, 5, func(string) string { return "w" }),
	})
	if err != nil || got != "xyz w" {
		t.Errorf("got %q %v", got, err)
	}
}

func TestApplyEditsRefusesAPartialOverlap(t *testing.T) {
	_, err := ApplyEdits("abcdef", []Edit{edit(1, 4, strings.ToUpper), edit(3, 6, strings.ToUpper)})
	if err == nil || !strings.Contains(err.Error(), "解けない重なり") {
		t.Errorf("交わるだけの 2 つを通した: %v", err)
	}
}

func TestPlanExpandSendsUndecidableArmsToFix(t *testing.T) {
	plan, err := PlanExpand(filepath.Join("testdata", "proj"), zooRows(t), "Zoo.Animal", nil)
	must(t, err)
	// sound・pair の外と内は書き出す。legs（変数を使う）・describe（見張りつき）は fix。
	if plan.Sites != 5 || len(plan.Edits) != 3 || len(plan.Fix) != 2 {
		t.Errorf("sites %d・書き出す %d・fix %+v（5・3・2 のはず）", plan.Sites, len(plan.Edits), plan.Fix)
	}
}

func TestExpandWritesTheRemainingCasesWithTheirArity(t *testing.T) {
	root := zoo(t)
	code, text := runZoo(t, root, nil, "expand-wildcard", "--enum", "Animal")
	diff := read(t, root, "build/refactor/last.diff")
	want := "+        case Animal.Bird(_, _) => \"...\""
	if code != 0 || !strings.Contains(diff, want) || !strings.Contains(text, "dry-run") {
		t.Errorf("exit %d\n%s\n%s", code, text, diff)
	}
}

func TestExpandDryRunLeavesTheFilesAlone(t *testing.T) {
	root := zoo(t)
	before := read(t, root, "src/Zoo.flix")
	runZoo(t, root, nil, "expand-wildcard", "--enum", "Animal")
	if read(t, root, "src/Zoo.flix") != before {
		t.Error("dry-run がファイルを書き換えた")
	}
}

// pair の外の `case _` の本体には内の match の `case _` がある。外の 3 つの写しは、内を書き出した後の本体を写す。
func TestExpandCopiesTheRewrittenInnerMatch(t *testing.T) {
	root := zoo(t)
	var cmds []string
	code, text := runZoo(t, root, verifyWith(0, "", &cmds), "expand-wildcard", "--enum", "Animal", "--apply")
	got := strings.Count(read(t, root, "src/Zoo.flix"), `case Animal.Fish => "x-other"`)
	if code != 0 || got != 3 {
		t.Errorf("exit %d・内の Fish の腕 %d（外の写し 3 つに 1 つずつのはず）\n%s", code, got, text)
	}
}

func TestApplyRunsTheConfiguredVerify(t *testing.T) {
	root := zoo(t)
	var cmds []string
	runZoo(t, root, verifyWith(0, "", &cmds), "expand-wildcard", "--enum", "Animal", "--apply")
	if len(cmds) != 1 || cmds[0] != "make check" {
		t.Errorf("流した確かめ %v（make check のはず）", cmds)
	}
}

func TestApplyRevertsOnlyItsPatchWhenVerifyFails(t *testing.T) {
	root := zoo(t)
	before := read(t, root, "src/Zoo.flix")
	var cmds []string
	code, text := runZoo(t, root, verifyWith(1, "ok line\n-- Type Error -- src/Zoo.flix:13\n>> Unable to unify\n", &cmds), "expand-wildcard", "--enum", "Animal", "--apply")
	if code != 1 || read(t, root, "src/Zoo.flix") != before || !strings.Contains(text, "reverted") || !strings.Contains(text, "src/Zoo.flix:13") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// 書き換えるファイルにコミットしていない変更があっても --apply は通り、確かめが通れば手の変更も残る。
func TestApplyKeepsTheUncommittedChangesOfTheFile(t *testing.T) {
	root := zoo(t)
	mine := read(t, root, "src/Zoo.flix") + "// hand edit in progress\n"
	must(t, os.WriteFile(filepath.Join(root, "src/Zoo.flix"), []byte(mine), 0o644))
	var cmds []string
	code, text := runZoo(t, root, verifyWith(0, "", &cmds), "expand-wildcard", "--enum", "Animal", "--apply")
	if code != 0 || len(cmds) != 1 || !strings.Contains(read(t, root, "src/Zoo.flix"), "// hand edit in progress") {
		t.Errorf("exit %d・確かめ %v\n%s", code, cmds, text)
	}
}

// 確かめが落ちたら、書く前の中身（コミットしていない手の変更を含む）へバイト単位で戻す。
func TestRevertRestoresTheUncommittedContentExactly(t *testing.T) {
	root := zoo(t)
	mine := read(t, root, "src/Zoo.flix") + "// hand edit in progress\n"
	must(t, os.WriteFile(filepath.Join(root, "src/Zoo.flix"), []byte(mine), 0o644))
	var cmds []string
	code, text := runZoo(t, root, verifyWith(1, "error\n", &cmds), "expand-wildcard", "--enum", "Animal", "--apply")
	runs := backupRuns(filepath.Join(root, "build", "refactor", "before"))
	if code != 1 || read(t, root, "src/Zoo.flix") != mine || len(runs) != 1 || read(t, root, "build/refactor/before/"+runs[0]+"/src/Zoo.flix") != mine {
		t.Errorf("exit %d・控えの回 %v\n%s", code, runs, text)
	}
}

// revert-failed の後のもう 1 回の --apply は、唯一の控えを残すため断り、控えの場所を言う。控えの中身へ戻せば通る。
func TestApplyAfterRevertFailedRefusesUntilRestored(t *testing.T) {
	root := zoo(t)
	orig := read(t, root, "src/Zoo.flix")
	spoil := func(cmd, dir, log string) int {
		os.WriteFile(filepath.Join(dir, "src", "Zoo.flix"), []byte("changed by the verify step\n"), 0o644)
		os.WriteFile(log, []byte("error\n"), 0o644)
		return 1
	}
	if code, text := runZoo(t, root, spoil, "expand-wildcard", "--enum", "Animal", "--apply"); code != 3 {
		t.Fatalf("1 回目 exit %d\n%s", code, text)
	}
	runs := backupRuns(filepath.Join(root, "build", "refactor", "before"))
	if len(runs) != 1 {
		t.Fatalf("控えの回 %v", runs)
	}
	must(t, os.WriteFile(filepath.Join(root, "src", "Zoo.flix"), []byte(orig), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "src", "Zoo.flix"), []byte(orig+"// other hand\n"), 0o644))
	var cmds []string
	code, text := runZoo(t, root, verifyWith(0, "", &cmds), "expand-wildcard", "--enum", "Animal", "--apply")
	if code != 2 || len(cmds) != 0 || !strings.Contains(text, "build/refactor/before/"+runs[0]) || !strings.Contains(text, revertFailedMark) {
		t.Errorf("2 回目は断る: exit %d・確かめ %v\n%s", code, cmds, text)
	}
	must(t, os.WriteFile(filepath.Join(root, "src", "Zoo.flix"), []byte(orig), 0o644))
	code, text = runZoo(t, root, verifyWith(0, "", &cmds), "expand-wildcard", "--enum", "Animal", "--apply")
	if code != 0 || len(backupRuns(filepath.Join(root, "build", "refactor", "before"))) != 2 {
		t.Errorf("控えの中身へ戻した後は通り、前の回の控えも残る: exit %d\n%s", code, text)
	}
}

// 控えは新しい KeepBackups 回だけ残し、revert-failed の印のある回は数えず残す。
func TestBackupsKeepTheNewestRunsAndRevertFailed(t *testing.T) {
	dir := t.TempDir()
	start := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	var first string
	for i := 0; i < KeepBackups+3; i++ {
		run, err := saveBackup(dir, []string{"src/A.flix"}, map[string]string{"src/A.flix": "a"}, start.Add(time.Duration(i)*time.Second))
		must(t, err)
		if i == 0 {
			first = run
			markRevertFailed(run, []string{"src/A.flix"}, "test")
		}
	}
	runs := backupRuns(dir)
	if len(runs) != KeepBackups+1 || runs[0] != filepath.Base(first) {
		t.Errorf("残った回 %d（%d のはず）・一番古い %s（印の回 %s のはず）", len(runs), KeepBackups+1, runs[0], filepath.Base(first))
	}
}

// git の作業場の外でも --apply して戻せる（戻しは git に頼らない）。
func TestApplyRevertsOutsideGit(t *testing.T) {
	root := zoo(t)
	must(t, os.RemoveAll(filepath.Join(root, ".git")))
	before := read(t, root, "src/Zoo.flix")
	var cmds []string
	code, text := runZoo(t, root, verifyWith(1, "error\n", &cmds), "expand-wildcard", "--enum", "Animal", "--apply")
	if code != 1 || read(t, root, "src/Zoo.flix") != before {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// --require-clean は今までの歯止め: コミットしていない変更があれば断り、パスを頭の字まで正しく言う。
func TestRequireCleanRefusesAndNamesTheWholePath(t *testing.T) {
	root := zoo(t)
	must(t, os.WriteFile(filepath.Join(root, "src/Zoo.flix"), []byte(read(t, root, "src/Zoo.flix")+"\n"), 0o644))
	var cmds []string
	code, text := runZoo(t, root, verifyWith(0, "", &cmds), "expand-wildcard", "--enum", "Animal", "--apply", "--require-clean")
	if code != 2 || len(cmds) != 0 || !strings.Contains(text, "コミットしていない変更がある: src/Zoo.flix") {
		t.Errorf("exit %d・確かめ %v\n%s", code, cmds, text)
	}
}

// git status --porcelain の最初の行が " M"（作業ツリーだけの変更）でも、パスの頭の字を食わない。
func TestPorcelainPathsKeepTheFirstLetter(t *testing.T) {
	got := porcelainPaths(" M src/scene/PuzzleScene.flix\nM  src/A.flix\nR  old.flix -> src/New.flix\n?? test/T.flix\n")
	want := []string{"src/scene/PuzzleScene.flix", "src/A.flix", "src/New.flix", "test/T.flix"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("got %v", got)
	}
}

func TestApplyRefusesAStaleIndex(t *testing.T) {
	root := zoo(t)
	// 索引の範囲の字（`_`）を別の字に替えて、索引が古い作業場を作る（鍵は使い回しを止めないよう同じ索引を写す）。
	src := strings.Replace(read(t, root, "src/Zoo.flix"), `case _          => "..."`, `case x          => "..."`, 1)
	must(t, os.WriteFile(filepath.Join(root, "src/Zoo.flix"), []byte(src), 0o644))
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-qam", "stale")
	code, text := runZoo(t, root, nil, "expand-wildcard", "--enum", "Animal")
	if code != 2 || !strings.Contains(text, "索引が古い") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestSkipLeavesASiteToFix(t *testing.T) {
	plan, err := PlanExpand(filepath.Join("testdata", "proj"), zooRows(t), "Zoo.Animal", map[string]bool{"src/Zoo.flix:13": true})
	must(t, err)
	if len(plan.Edits) != 2 || len(plan.Fix) != 3 {
		t.Errorf("書き出す %d・fix %d（2・3 のはず）", len(plan.Edits), len(plan.Fix))
	}
}

func deadSyms(fs []Fixed) map[string]string {
	m := map[string]string{}
	for _, f := range fs {
		m[f.Sym] = f.Why
	}
	return m
}

func TestPlanDeadWithTests(t *testing.T) {
	plan, err := PlanDead(filepath.Join("testdata", "proj"), zooRows(t), DeadQuery{WithTests: true, TestDirs: []string{"test"}})
	must(t, err)
	got := deadSyms(plan.Targets)
	// onlyTested（テストからだけ）・unused（参照 0）・helper（onlyTested だけが使う private）。
	if len(got) != 3 || got["Zoo.onlyTested"] != "test-only" || got["Zoo.unused"] != "unreferenced" || got["Zoo.helper"] == "" {
		t.Errorf("消す def %v", got)
	}
}

func TestPlanDeadRemovesTheTestOfTheRemovedDefOnly(t *testing.T) {
	plan, err := PlanDead(filepath.Join("testdata", "proj"), zooRows(t), DeadQuery{WithTests: true, TestDirs: []string{"test"}})
	must(t, err)
	tests, fix := deadSyms(plan.Tests), deadSyms(plan.Fix)
	// onlyTestedTooWithUsed は src の used も使うので、onlyTestedToo ごと fix。
	if len(tests) != 1 || tests["TestZoo.onlyTestedAddsOne"] == "" || fix["Zoo.onlyTestedToo"] == "" {
		t.Errorf("テスト %v・fix %v", tests, fix)
	}
}

func TestPlanDeadWithoutTestsKeepsTestedDefs(t *testing.T) {
	plan, err := PlanDead(filepath.Join("testdata", "proj"), zooRows(t), DeadQuery{TestDirs: []string{"test"}})
	must(t, err)
	got := deadSyms(plan.Targets)
	if len(got) != 1 || got["Zoo.unused"] == "" || len(plan.Fix) != 2 {
		t.Errorf("消す def %v・fix %d（unused だけ・2 のはず）", got, len(plan.Fix))
	}
}

func TestRemoveDeadDeletesTheDocAndAnnotationLines(t *testing.T) {
	root := zoo(t)
	var cmds []string
	code, text := runZoo(t, root, verifyWith(0, "", &cmds), "remove-dead", "--with-tests", "--apply")
	src := read(t, root, "src/Zoo.flix")
	if code != 0 || strings.Contains(src, "Only the tests call this") || strings.Contains(src, "@Deprecated") || strings.Contains(src, "def helper") || strings.Contains(src, "\n\n\n") {
		t.Errorf("exit %d\n%s\n%s", code, text, src)
	}
	if len(cmds) != 1 || cmds[0] != "make test" {
		t.Errorf("流した確かめ %v（remove-dead は make test のはず）", cmds)
	}
}

func TestRemoveDeadJSONHasTheCheckresShape(t *testing.T) {
	_, text := runZoo(t, zoo(t), nil, "remove-dead", "--with-tests", "--json")
	var rep struct {
		Results []struct {
			Code string  `json:"code"`
			Got  float64 `json:"got"`
		} `json:"results"`
		Outcome Outcome `json:"outcome"`
		Fix     []Fixed `json:"fix"`
	}
	if err := json.Unmarshal([]byte(text), &rep); err != nil {
		t.Fatalf("%v\n%s", err, text)
	}
	if len(rep.Results) != 1 || rep.Results[0].Code != CodeRemoveDead || rep.Results[0].Got != 1 || rep.Outcome.State != StateDryRun {
		t.Errorf("%s", text)
	}
}

// 本物の flixlint と flix で、お手本を書き換えてコンパイルとテストが通るか（FGE_REFACTOR_E2E=1 の時だけ。
// FGE_FLIXLINT に bin/flixlint、FLIX_JAR に flix.jar（0.78）が要る）。
func TestEndToEndOnTheFixture(t *testing.T) {
	if os.Getenv("FGE_REFACTOR_E2E") == "" {
		t.Skip("FGE_REFACTOR_E2E=1 の時だけ（本物の flixlint と flix を流す）")
	}
	jar, fl := os.Getenv("FLIX_JAR"), os.Getenv("FGE_FLIXLINT")
	root := zoo(t)
	must(t, os.MkdirAll(filepath.Join(root, "bin", "lint-rules"), 0o755))
	conf := `{"verify": "java -jar ` + jar + ` check", "verifyTests": "java -jar ` + jar + ` test"}`
	must(t, os.WriteFile(filepath.Join(root, "bin", "lint-rules", "refactor.local.json"), []byte(conf), 0o644))
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
	step := func(args ...string) string {
		var out, errOut strings.Builder
		code := Run(&out, &errOut, root, append(args, "--flixlint", fl), Options{Run: direct, Verify: verify, Log: io.Discard})
		if code != 0 {
			t.Fatalf("%v: exit %d\n%s%s", args, code, out.String(), errOut.String())
		}
		return out.String()
	}
	if text := step("expand-wildcard", "--enum", "Animal", "--apply"); !strings.Contains(text, "applied") {
		t.Fatalf("%s", text)
	}
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-qam", "expanded")
	if text := step("remove-dead", "--with-tests", "--apply"); !strings.Contains(text, "applied") {
		t.Fatalf("%s", text)
	}
	t.Logf("%s", read(t, root, "src/Zoo.flix"))
}

// fpkg で配るライブラリ（engine）の pub は使う側がこの索引の外にいるので、消さずに fix へ回す。
func TestPlanDeadKeepsThePublicAPIOfALibrary(t *testing.T) {
	plan, err := PlanDead(filepath.Join("testdata", "proj"), zooRows(t), DeadQuery{WithTests: true, TestDirs: []string{"test"}, Library: true})
	must(t, err)
	if len(plan.Targets) != 0 || len(plan.Tests) != 0 || deadSyms(plan.Fix)["Zoo.unused"] == "" {
		t.Errorf("消す %v・テスト %v・fix %v", deadSyms(plan.Targets), deadSyms(plan.Tests), deadSyms(plan.Fix))
	}
}

func TestIsLibraryLooksForTheRepositoryOfThePackage(t *testing.T) {
	root := t.TempDir()
	must(t, os.WriteFile(filepath.Join(root, "flix.toml"), []byte("[package]\nversion = \"0.1.0\"\nrepository = \"github:o/n\"\n"), 0o644))
	game := t.TempDir()
	must(t, os.WriteFile(filepath.Join(game, "flix.toml"), []byte("[package]\nversion = \"0.1.0\"\n"), 0o644))
	if !IsLibrary(root, defaults()) || IsLibrary(game, defaults()) || !IsLibrary(game, Config{Library: "true"}) {
		t.Error("repository のある package だけがライブラリ（library: true で強める）のはず")
	}
}

func TestRemoveDeadOnALibraryRemovesNothing(t *testing.T) {
	root := zoo(t)
	must(t, os.WriteFile(filepath.Join(root, "flix.toml"), []byte(read(t, root, "flix.toml")+"repository = \"github:o/zoo\"\n"), 0o644))
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-qam", "library")
	var cmds []string
	code, text := runZoo(t, root, verifyWith(0, "", &cmds), "remove-dead", "--with-tests", "--apply")
	if code != 0 || len(cmds) != 0 || !strings.Contains(text, "nothing") || !strings.Contains(read(t, root, "src/Zoo.flix"), "def unused") {
		t.Errorf("exit %d・確かめ %v\n%s", code, cmds, text)
	}
}

// 書いた後に別の手（ここでは確かめ）が同じファイルを変えたら、その変更を消さないよう戻さない: revert-failed・終了コード 3。
func TestRevertFailedNamesTheFilesLeft(t *testing.T) {
	root := zoo(t)
	spoil := func(cmd, dir, log string) int {
		os.WriteFile(filepath.Join(dir, "src", "Zoo.flix"), []byte("changed by the verify step\n"), 0o644)
		os.WriteFile(log, []byte("error\n"), 0o644)
		return 1
	}
	code, text := runZoo(t, root, spoil, "expand-wildcard", "--enum", "Animal", "--apply")
	if code != 3 || !strings.Contains(text, "revert-failed") || !strings.Contains(text, "src/Zoo.flix") || read(t, root, "src/Zoo.flix") != "changed by the verify step\n" {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestRevertListsWhatTheVerifyLeftBehind(t *testing.T) {
	root := zoo(t)
	gen := func(cmd, dir, log string) int {
		os.MkdirAll(filepath.Join(dir, "test", "gen"), 0o755)
		os.WriteFile(filepath.Join(dir, "test", "gen", "Gen.flix"), []byte("mod Gen {}\n"), 0o644)
		os.WriteFile(log, []byte("error\n"), 0o644)
		return 1
	}
	code, text := runZoo(t, root, gen, "expand-wildcard", "--enum", "Animal", "--apply")
	if code != 1 || !strings.Contains(text, "確かめが残した変更") || !strings.Contains(text, "test/gen/Gen.flix") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// def の上の /// が def より深く字下げされていても落ちない（行ごと消す範囲は ext の始まりの行で決める）。
func TestDeleteEditToleratesADeeperDocComment(t *testing.T) {
	root := t.TempDir()
	src := "mod M {\n            /// deep doc\n  pub def f(): Int32 = 1\n}\n"
	must(t, os.WriteFile(filepath.Join(root, "M.flix"), []byte(src), 0o644))
	for _, ext := range []Row{{File: "M.flix", Line: 3, Col: 3, EndLine: 3, EndCol: 25}, {File: "M.flix", Line: 2, Col: 13, EndLine: 3, EndCol: 25}} {
		d := defInfo{Row: Row{Kind: KindDefDecl, File: "M.flix", Line: 3, Col: 11, EndLine: 3, EndCol: 12, Sym: "M.f"}, Pub: true, Ext: ext}
		e, err := deleteEdit(root, d)
		if err != nil {
			t.Fatal(err)
		}
		if got := src[:e.Start] + src[e.End:]; got != "mod M {\n}\n" {
			t.Errorf("ext %v: got %q", ext, got)
		}
	}
}
