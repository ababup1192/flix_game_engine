package precommit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeFge は受け取った引数と STAGED_FILE の中身を出し、引数に fail があれば 1 で終わる bin/fge の代わりを置く。
func fakeFge(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "fge")
	script := "#!/bin/sh\necho \"args: $*\"\ncat \"$STAGED_FILE\"\ncase \" $* \" in *\" fail \"*) exit 1;; esac\n"
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func projectGateRun(t *testing.T, root string, files ...string) (string, string, int) {
	t.Helper()
	var parent, child, childErr strings.Builder
	code, err := Run(&parent, Options{
		Root: root, Args: append([]string{"--files"}, files...), Stdout: &child, Stderr: &childErr,
		Lints: okLints(t), Fge: fakeFge(t),
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return parent.String(), child.String(), code
}

func writeFile(t *testing.T, root, rel, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, rel), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// withoutMake は make の無い機械として走らせる。
func withoutMake(t *testing.T) {
	t.Helper()
	old := lookMake
	lookMake = func() bool { return false }
	t.Cleanup(func() { lookMake = old })
}

func TestProjectPrecommitRunsFgeWithStagedFile(t *testing.T) {
	root := fakeRepo(t)
	writeFile(t, root, "project.json", `{"precommit": ["lint-flixlint --quick"]}`)
	_, child, code := projectGateRun(t, root, "art/a.sprite.json")
	if code != 0 || !strings.Contains(child, "args: lint-flixlint --quick") || !strings.Contains(child, "art/a.sprite.json") {
		t.Errorf("project.json の precommit が引数とステージを受け取っていない: code=%d out=%q", code, child)
	}
}

func TestProjectPrecommitTaskNameRunsThroughTask(t *testing.T) {
	root := fakeRepo(t)
	writeFile(t, root, "project.json", `{"tasks": {"palette-gate": {"entry": "Gate.main"}}, "precommit": ["palette-gate"]}`)
	_, child, _ := projectGateRun(t, root, "notes.txt")
	if !strings.Contains(child, "args: task palette-gate") {
		t.Errorf("tasks の名前が bin/fge task で流れていない: %q", child)
	}
}

func TestProjectPrecommitFailureStops(t *testing.T) {
	root := fakeRepo(t)
	writeFile(t, root, "project.json", `{"precommit": ["ok", "fail"]}`)
	parent, _, code := projectGateRun(t, root, "notes.txt")
	if code != 1 || !strings.Contains(parent, "止めました") {
		t.Errorf("落ちた precommit で止まっていない: code=%d %q", code, parent)
	}
}

func TestProjectPrecommitReplacesMakefileGate(t *testing.T) {
	root := fakeRepo(t)
	writeFile(t, root, "project.json", `{"precommit": []}`)
	writeFile(t, root, "Makefile", "precommit-local:\n\t@echo 古いターゲット; exit 1\n")
	_, child, code := projectGateRun(t, root, "notes.txt")
	if code != 0 || strings.Contains(child, "古いターゲット") {
		t.Errorf("precommit の欄があるのに Makefile のターゲットを流した: code=%d out=%q", code, child)
	}
}

func TestBrokenProjectPrecommitIsAnError(t *testing.T) {
	root := fakeRepo(t)
	writeFile(t, root, "project.json", `{"precommit": "lint"}`)
	var parent, child strings.Builder
	_, err := Run(&parent, Options{Root: root, Args: []string{"--files", "notes.txt"}, Stdout: &child, Stderr: &child, Lints: okLints(t)})
	if err == nil {
		t.Error("読めない precommit の欄を飛ばした")
	}
}

func TestMakeMissingWithLocalGateStops(t *testing.T) {
	withoutMake(t)
	root := fakeRepo(t)
	writeFile(t, root, "Makefile", "include x.mk\n\nprecommit-local: lint\n\t@true\n")
	parent, _, _, code := gateRun(t, root, []string{"--files", "notes.txt"}, okLints(t), nil)
	if code != 1 || !strings.Contains(parent, "make が見つからないので Makefile の precommit-local を流せません") {
		t.Errorf("make が無いのに知らせずに通した: code=%d %q", code, parent)
	}
}

func TestMakeMissingWithoutLocalGateIsSilent(t *testing.T) {
	withoutMake(t)
	root := fakeRepo(t)
	writeFile(t, root, "Makefile", "PRECOMMIT := precommit-local\nrun:\n\t@true\n")
	parent, _, _, code := gateRun(t, root, []string{"--files", "notes.txt"}, okLints(t), nil)
	if code != 0 || parent != "" {
		t.Errorf("ターゲットの無いゲームで何か言った: code=%d %q", code, parent)
	}
}

func TestMakeMissingWithDocsSyncTargetStops(t *testing.T) {
	withoutMake(t)
	root := fakeRepo(t)
	writeFile(t, root, "Makefile", "check-docs-sync:\n\t@true\n")
	parent, _, _, code := gateRun(t, root, []string{"--files", "docs/a.md"}, okLints(t), nil)
	if code != 1 || !strings.Contains(parent, "check-docs-sync を流せません") {
		t.Errorf("make が無いのに配線検査を知らせずに通した: code=%d %q", code, parent)
	}
}
