package hooks

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNameSearchOnFlixCatchesNameGrepsOnly(t *testing.T) {
	grep := func(pat, glob, path string) Payload {
		return Payload{"tool_name": "Grep", "tool_input": map[string]any{"pattern": pat, "glob": glob, "path": path}}
	}
	bash := func(cmd string) Payload {
		return Payload{"tool_name": "Bash", "tool_input": map[string]any{"command": cmd}}
	}
	hit := map[string]Payload{
		"Grep の def":           grep(`def enterFight`, "*.flix", ""),
		"Grep の Mod.名前":        grep(`WorldFight.enterFight`, "", "src"),
		"grep -rn の camelCase": bash(`grep -rn "enterFight" src/`),
		"rg の def と --include": bash(`cd game && rg -n 'def armFight' --glob '*.flix'`),
		"grep -rn --include":   bash(`grep -rn --include=*.flix "pub def step" .`),
		"引用符の中の | を含む正規表現":     bash(`cd src && cat Main.flix; grep -n "^\\s*\\(pub \\)\\?\\(def\\|mod\\|enum\\)" View.flix World.flix`),
	}
	for name, p := range hit {
		if !NameSearchOnFlix(p, ".flix") {
			t.Errorf("%s: 名前の字の検索として拾うはず", name)
		}
	}
	miss := map[string]Payload{
		"文書の言葉":         grep(`決定の音`, "*.md", ""),
		"JSON の値":       bash(`grep -n "preRoll" assets/cue.json`),
		".flix の外の名前":   bash(`grep -rn "enterFight" docs/`),
		"grep をパイプの後ろで": bash(`git log --oneline | grep fix`),
		"Read":          Payload{"tool_name": "Read", "tool_input": map[string]any{"file_path": "src/World.flix"}},
	}
	for name, p := range miss {
		if NameSearchOnFlix(p, ".flix") {
			t.Errorf("%s: 拾わないはず", name)
		}
	}
}

func TestNameSearchOnFlixCatchesWholeProjectAndTypeNames(t *testing.T) {
	game := t.TempDir()
	for _, f := range []string{"flix.toml", "src/World.flix", "docs/notes.md"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(game, f)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(game, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	at := func(tool string, input map[string]any) Payload {
		return Payload{"tool_name": tool, "cwd": game, "tool_input": input}
	}
	hit := map[string]Payload{
		"プロジェクトの根を grep -rn":         at("Bash", map[string]any{"command": `grep -rn "enterFight" ` + game}),
		"cd してから grep -rn .":         at("Bash", map[string]any{"command": `cd ` + game + ` && grep -rn enterFight .`}),
		"探す先を書かない rg":                at("Bash", map[string]any{"command": `rg -n enterFight`}),
		"Grep で Mod.Type.Case":       at("Grep", map[string]any{"pattern": `Entry.Entry`, "path": game}),
		"Grep で大文字の 1 語と *.flix":     at("Grep", map[string]any{"pattern": `Entry`, "glob": "*.flix"}),
		"grep -rn で Mod.Type を src/": at("Bash", map[string]any{"command": `grep -rn "WorldFight.Entry" src/`}),
	}
	for name, p := range hit {
		if !NameSearchOnFlix(p, ".flix") {
			t.Errorf("%s: 名前の字の検索として拾うはず", name)
		}
	}
	miss := map[string]Payload{
		"プロジェクトの中の .flix の無いフォルダ":  at("Bash", map[string]any{"command": `grep -rn enterFight ` + filepath.Join(game, "docs")}),
		"根を探しても文字列":                at("Bash", map[string]any{"command": `grep -rn "着火" ` + game}),
		"根を探しても全部大文字の語":            at("Bash", map[string]any{"command": `grep -rn TODO .`}),
		"Grep で *.md に絞った大文字の 1 語": at("Grep", map[string]any{"pattern": `Entry`, "glob": "*.md", "path": game}),
		"-r の無い grep で 1 ファイル":     at("Bash", map[string]any{"command": `grep -n Entry README.md`}),
		"出力の絞り込み":                  at("Bash", map[string]any{"command": `make test 2>&1 | grep Passed`}),
	}
	for name, p := range miss {
		if NameSearchOnFlix(p, ".flix") {
			t.Errorf("%s: 拾わないはず", name)
		}
	}
}

func TestShellSegmentsKeepQuotedSeparators(t *testing.T) {
	got := shellSegments(`cd src && grep -n "a\\|b;c" X.flix | head -3; echo 'x|y'`)
	want := []string{"cd src ", ` grep -n "a\\|b;c" X.flix `, " head -3", ` echo 'x|y'`}
	if strings.Join(got, "¦") != strings.Join(want, "¦") {
		t.Errorf("引用符の中の | ; では区切らないはず: %q", got)
	}
}

func nudgeRoot(t *testing.T) string {
	t.Helper()
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "bin", "lint-rules"), 0o755); err != nil {
		t.Fatal(err)
	}
	shipped, err := os.ReadFile(filepath.Join("..", "..", "..", RulesPath))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, RulesPath), shipped, 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func nudgeOnce(root, payload string) string {
	var out strings.Builder
	RunSearchNudge(&out, root, "", strings.NewReader(payload))
	return out.String()
}

func TestSearchNudgeSpeaksFirstThenEveryFifth(t *testing.T) {
	root := nudgeRoot(t)
	in := `{"session_id": "s1", "tool_name": "Grep", "tool_input": {"pattern": "def step", "glob": "*.flix"}}`
	var spoke []int
	for n := 1; n <= 11; n++ {
		if nudgeOnce(root, in) != "" {
			spoke = append(spoke, n)
		}
	}
	if fmt.Sprint(spoke) != "[1 6 11]" {
		t.Errorf("1 回目と、その後 5 回ごとに案内するはず: %v", spoke)
	}
}

func TestSearchNudgeCountsEachSubagentApart(t *testing.T) {
	root := nudgeRoot(t)
	parent := `{"session_id": "s1", "tool_name": "Grep", "tool_input": {"pattern": "def step", "glob": "*.flix"}}`
	sub := `{"session_id": "s1", "agent_id": "a1", "tool_name": "Grep", "tool_input": {"pattern": "def step", "glob": "*.flix"}}`
	nudgeOnce(root, parent)
	if nudgeOnce(root, sub) == "" {
		t.Errorf("同じセッションでも、サブエージェントの 1 回目は案内するはず")
	}
}

func TestSearchNudgeSaysHowManyTimes(t *testing.T) {
	root := nudgeRoot(t)
	in := `{"session_id": "s1", "tool_name": "Grep", "tool_input": {"pattern": "def step", "glob": "*.flix"}}`
	var last string
	for n := 1; n <= 6; n++ {
		last = nudgeOnce(root, in)
	}
	if !strings.Contains(last, "6 回目") {
		t.Errorf("言い直しには何回目かを添えるはず: %s", last)
	}
}
