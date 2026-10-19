package talk

import (
	"os"
	"path/filepath"
	"testing"
)

const scenario = "title: a\n---\none\n===\ntitle: b\n---\ntwo\nthree\n===\n"

func TestResolveFindsTheNodeHoldingTheLine(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "assets", "talk"), 0o755)
	os.WriteFile(filepath.Join(root, "assets", "talk", "x.yarn"), []byte(scenario), 0o644)
	got, err := Resolve(root, "assets/talk/x.yarn:8")
	if err != nil || got.Node != "b" || got.File != "assets/talk/x.yarn" || got.StartLine() != "talk node=b line=8" {
		t.Fatalf("got %+v %v", got, err)
	}
}

func TestResolveRejectsALineBeforeAnyNode(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "x.yarn"), []byte("// c\n"+scenario), 0o644)
	if _, err := Resolve(root, "x.yarn:1"); err == nil {
		t.Fatal("ノードより前の行は断るはず")
	}
}

func TestPortFromRegistryMatchesThisGameAndLivePid(t *testing.T) {
	root := t.TempDir()
	reg := filepath.Join(t.TempDir(), "games.json")
	os.WriteFile(reg, []byte(`{"games":[{"dir":"`+root+`","pid":"1","port":"100"},{"dir":"/else","pid":"2","port":"200"},{"dir":"`+root+`","pid":"3","port":"300"}]}`), 0o644)
	port, ok := PortFromRegistry(reg, root, func(pid int) bool { return pid != 3 })
	if !ok || port != 100 {
		t.Fatalf("got %d %v", port, ok)
	}
}

func TestPngOfReadsTheShotLine(t *testing.T) {
	if got := PngOf("rendered: x\nok png=debug/shot/a.png\n"); got != "debug/shot/a.png" {
		t.Fatalf("got %q", got)
	}
}
