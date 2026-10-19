package talk

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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

// $名前=値 の引数は始まりの行の後ろに並び、命令口へは同じ名前の問いとして送る。形の違う物は止める。
func TestVariablesGoToTheStartLineAndTheQuery(t *testing.T) {
	vars, err := varsOf([]string{"--port", "9", "$tickets=0", "$met=true"})
	if err != nil {
		t.Fatal(err)
	}
	target := Target{Node: "gate", Line: 5, Vars: vars}
	if got := target.StartLine(); got != "talk node=gate line=5 $tickets=0 $met=true" {
		t.Errorf("got %q", got)
	}
	var query string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query = r.URL.Query().Get("$tickets")
		w.Write([]byte("ok"))
	}))
	defer server.Close()
	port, _ := strconv.Atoi(server.URL[strings.LastIndex(server.URL, ":")+1:])
	if _, err := Goto(port, target); err != nil || query != "0" {
		t.Errorf("問いの $tickets = %q（%v）", query, err)
	}
	if _, err := varsOf([]string{"$tickets"}); err == nil {
		t.Error("= の無い $tickets は止めるはず")
	}
}
