package hooks

import (
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

func TestSearchNudgeSpeaksOncePerSession(t *testing.T) {
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
	in := `{"session_id": "s1", "tool_name": "Grep", "tool_input": {"pattern": "def step", "glob": "*.flix"}}`
	var first, second strings.Builder
	if code := RunSearchNudge(&first, root, "", strings.NewReader(in)); code != 0 || !strings.Contains(first.String(), `"additionalContext":"Flix の名前は`) {
		t.Fatalf("1 回目は案内を返すはず（code %d）: %s", code, first.String())
	}
	if RunSearchNudge(&second, root, "", strings.NewReader(in)); second.String() != "" {
		t.Errorf("同じセッションの 2 回目は黙るはず: %s", second.String())
	}
}
