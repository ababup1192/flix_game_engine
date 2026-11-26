package launcher

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// fakeEngine は、呼ばれた引数と環境変数の一部を calls.log に 1 行ずつ書く偽の bin/headless-run と bin/flix を持つ engine。
func fakeEngine(t *testing.T) (engine, calls string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("偽のスクリプトは sh で書く")
	}
	engine = t.TempDir()
	calls = filepath.Join(engine, "calls.log")
	script := `#!/bin/sh
echo "$(basename "$0") $* JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS:-} SHOT=${SHOT:-} START=${START:-} DEBUG=${DEBUG:-} FALLBACK=${FGE_HEADLESS_FALLBACK:-} BOT_RUNS=${BOT_RUNS:-} FLOW=${FLOW:-} VARIANTS=${FLIX_GE_SHADER_VARIANTS:-}" >> "` + calls + `"
case "$*" in *fail*) exit 7 ;; esac
case "$*" in Palette.write) echo palette > assets/x.palette.json ;; esac
exit 0
`
	for _, n := range []string{"headless-run", "flix"} {
		p := filepath.Join(engine, "bin", n)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return engine, calls
}

func newTestLauncher(t *testing.T, project string) (*Launcher, string, *bytes.Buffer) {
	t.Helper()
	engine, calls := fakeEngine(t)
	t.Setenv("JAVA_TOOL_OPTIONS", "")
	root := t.TempDir()
	if project != "" {
		if err := os.WriteFile(filepath.Join(root, "project.json"), []byte(project), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	p, err := LoadProject(root)
	if err != nil {
		t.Fatal(err)
	}
	self, err := exec.LookPath("true")
	if err != nil {
		t.Skip("true が無い")
	}
	var out bytes.Buffer
	return &Launcher{Root: root, Engine: engine, Self: self, Project: p, Stdout: &out, Stderr: &out}, calls, &out
}

func readCalls(t *testing.T, calls string) []string {
	t.Helper()
	b, err := os.ReadFile(calls)
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func TestRenderAllRunsSceneRenderAllHeadless(t *testing.T) {
	l, calls, _ := newTestLauncher(t, "")
	if code := l.RenderAll(nil); code != 0 {
		t.Fatalf("code %d", code)
	}
	got := readCalls(t, calls)
	if len(got) != 1 || !strings.HasPrefix(got[0], "headless-run SceneRender.all JAVA_TOOL_OPTIONS=-Djava.awt.headless=true ") {
		t.Fatalf("calls %q", got)
	}
}

func TestRenderPassesShotsJoinedBySpace(t *testing.T) {
	l, calls, _ := newTestLauncher(t, "")
	l.Render([]string{"title", "boss"}, nil)
	if got := readCalls(t, calls); len(got) != 1 || !strings.Contains(got[0], "SceneRender.one ") || !strings.Contains(got[0], "SHOT=title boss START=") {
		t.Fatalf("calls %q", got)
	}
}

func TestPlayWithShotOpensWindowFromTheShotPaused(t *testing.T) {
	l, calls, _ := newTestLauncher(t, "")
	l.Play("boss", false, nil)
	got := readCalls(t, calls)
	if len(got) != 1 || !strings.HasPrefix(got[0], "headless-run --window main JAVA_TOOL_OPTIONS= ") ||
		!strings.Contains(got[0], "START=shot:boss DEBUG=1 FALLBACK=1") {
		t.Fatalf("calls %q", got)
	}
}

func TestPlayRecordsShaderVariantsOnlyForWebGames(t *testing.T) {
	l, calls, _ := newTestLauncher(t, "")
	l.Play("", false, nil)
	if err := os.MkdirAll(filepath.Join(l.Root, "web"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(l.Root, "web", "WebMain.flix"), []byte("def main(): Unit = ()\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l.Play("", true, nil)
	got := readCalls(t, calls)
	want := filepath.Join(l.Root, "web", "shader-variants.json")
	if len(got) != 2 || !strings.HasSuffix(got[0], "VARIANTS=") || !strings.HasSuffix(got[1], "VARIANTS="+want) {
		t.Fatalf("calls %q", got)
	}
}

func TestDebugSetsDebugTrue(t *testing.T) {

	l, calls, _ := newTestLauncher(t, "")
	l.Play("", true, nil)
	if got := readCalls(t, calls); len(got) != 1 || !strings.Contains(got[0], "DEBUG=true") {
		t.Fatalf("calls %q", got)
	}
}

func TestHeadlessReturnsTheEntryExitCode(t *testing.T) {
	l, _, _ := newTestLauncher(t, "")
	if code := l.Headless("Mod.fail", nil); code != 7 {
		t.Fatalf("code %d", code)
	}
}

func TestTaskUsesEnvDefaultUnlessOverridden(t *testing.T) {
	l, calls, _ := newTestLauncher(t, `{"tasks": {"bot": {"entry": "BotRun.play", "env": {"BOT_RUNS": "5"}}}}`)
	l.Task("bot", nil)
	l.Task("bot", map[string]string{"BOT_RUNS": "1"})
	got := readCalls(t, calls)
	if len(got) != 2 || !strings.Contains(got[0], "BOT_RUNS=5") || !strings.Contains(got[1], "BOT_RUNS=1") {
		t.Fatalf("calls %q", got)
	}
}

func TestTaskOutsideEnvironmentBeatsTheDefault(t *testing.T) {
	l, calls, _ := newTestLauncher(t, `{"tasks": {"bot": {"entry": "BotRun.play", "env": {"BOT_RUNS": "5"}}}}`)
	t.Setenv("BOT_RUNS", "3")
	l.Task("bot", nil)
	if got := readCalls(t, calls); len(got) != 1 || !strings.Contains(got[0], "BOT_RUNS=3") {
		t.Fatalf("calls %q", got)
	}
}

func TestUnknownTaskFailsWithTheList(t *testing.T) {
	l, _, out := newTestLauncher(t, `{"tasks": {"bot": {"entry": "BotRun.play", "about": "自動で遊ぶ"}}}`)
	if code := l.Task("nope", nil); code != 2 || !strings.Contains(out.String(), "自動で遊ぶ") {
		t.Fatalf("code %d out %q", code, out.String())
	}
}

func TestPrebuildRunsWhenADepIsNewerAndTouchesTheOutput(t *testing.T) {
	l, calls, _ := newTestLauncher(t, `{"prebuild": [{"out": "assets/x.palette.json", "deps": ["assets/x.theme.json"], "entry": "Palette.write"}]}`)
	assets := filepath.Join(l.Root, "assets")
	os.MkdirAll(assets, 0o755)
	os.WriteFile(filepath.Join(assets, "x.palette.json"), []byte("palette\n"), 0o644)
	old := time.Now().Add(-time.Hour)
	os.Chtimes(filepath.Join(assets, "x.palette.json"), old, old)
	os.WriteFile(filepath.Join(assets, "x.theme.json"), []byte("{}"), 0o644)
	l.RenderAll(nil)
	got := readCalls(t, calls)
	if len(got) != 2 || !strings.HasPrefix(got[0], "headless-run Palette.write ") {
		t.Fatalf("calls %q", got)
	}
	info, _ := os.Stat(filepath.Join(assets, "x.palette.json"))
	if !info.ModTime().After(old.Add(time.Minute)) {
		t.Fatal("出力の時刻が新しくなっていない")
	}
}

func TestPrebuildSkipsWhenTheOutputIsNewer(t *testing.T) {
	l, calls, _ := newTestLauncher(t, `{"prebuild": [{"out": "assets/x.palette.json", "deps": ["assets/x.theme.json"], "entry": "Palette.write"}]}`)
	assets := filepath.Join(l.Root, "assets")
	os.MkdirAll(assets, 0o755)
	os.WriteFile(filepath.Join(assets, "x.theme.json"), []byte("{}"), 0o644)
	old := time.Now().Add(-time.Hour)
	os.Chtimes(filepath.Join(assets, "x.theme.json"), old, old)
	os.WriteFile(filepath.Join(assets, "x.palette.json"), []byte("palette\n"), 0o644)
	l.RenderAll(nil)
	if got := readCalls(t, calls); len(got) != 1 {
		t.Fatalf("calls %q", got)
	}
}

func TestPrebuildStopsOnAMissingDep(t *testing.T) {
	l, calls, _ := newTestLauncher(t, `{"prebuild": [{"out": "a.json", "deps": ["missing.json"], "entry": "Palette.write"}]}`)
	os.WriteFile(filepath.Join(l.Root, "a.json"), nil, 0o644)
	if code := l.RenderAll(nil); code != 2 || len(readCalls(t, calls)) != 0 {
		t.Fatalf("code %d", code)
	}
}

func TestTestWritesFailMarkAndReturnsOneOnRed(t *testing.T) {
	l, _, _ := newTestLauncher(t, "")
	os.WriteFile(filepath.Join(l.Engine, "bin", "flix"), []byte("#!/bin/sh\necho red\nexit 3\n"), 0o755)
	if code := l.Test(nil); code != 1 {
		t.Fatalf("code %d", code)
	}
	if _, err := os.Stat(filepath.Join(l.Root, ".test-logs", "test.fail")); err != nil {
		t.Fatal("test.fail が無い")
	}
}

func TestCheckWithCheckdOffRunsFlixCheckIntoTheLog(t *testing.T) {
	l, calls, _ := newTestLauncher(t, "")
	l.Check(map[string]string{"CHECKD": "0", "QUIET": "0"})
	if got := readCalls(t, calls); len(got) != 1 || !strings.HasPrefix(got[0], "flix check ") {
		t.Fatalf("calls %q", got)
	}
	if _, err := os.Stat(filepath.Join(l.Root, ".test-logs", "check.log")); err != nil {
		t.Fatal("check.log が無い")
	}
}

func TestLoadProjectRejectsTaskWithBothEntryAndCmd(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "project.json"), []byte(`{"tasks": {"x": {"entry": "A.b", "cmd": ["python3"]}}}`), 0o644)
	if _, err := LoadProject(root); err == nil {
		t.Fatal("want error")
	}
}

func TestLoadProjectWithoutProjectJsonIsEmpty(t *testing.T) {
	p, err := LoadProject(t.TempDir())
	if err != nil || len(p.Tasks) != 0 || len(p.Shots) != 0 {
		t.Fatalf("%+v %v", p, err)
	}
}

func TestSplitVarsSeparatesAssignmentsFromWords(t *testing.T) {
	vars, rest := SplitVars([]string{"title", "SHOT=a b", "--all", "x=y=z", "9X=1"})
	if vars["SHOT"] != "a b" || vars["x"] != "y=z" || len(rest) != 3 || rest[2] != "9X=1" {
		t.Fatalf("%v %v", vars, rest)
	}
}

func TestTailLinesCountsLikeTail(t *testing.T) {
	if got := string(tailLines([]byte("a\nb\nc\n"), 2)); got != "b\nc\n" {
		t.Fatalf("got %q", got)
	}
	if got := string(tailLines([]byte("a\nb"), 5)); got != "a\nb" {
		t.Fatalf("got %q", got)
	}
}
