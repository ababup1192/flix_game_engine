package prunetools

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func repoRoot() string { return filepath.Join("..", "..", "..") }

// 一覧は manifest の copy に載っている .py の写し。写し漏れを機械で見張る。
// WhyNot: 逆向き (StaleTools ⊆ manifest) を見ないのは、.py を engine から消した後は
// manifest から消えて、それでも一覧には残っていてほしいため。
func TestStaleToolsCoverManifest(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(repoRoot(), "agents-pack", "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m struct {
		Copy []struct{ Src, Dst string } `json:"copy"`
	}
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, rel := range StaleTools {
		have[rel] = true
	}
	for _, e := range m.Copy {
		if strings.HasSuffix(e.Dst, ".py") && !have[e.Dst] {
			t.Errorf("manifest の %s が StaleTools に無い", e.Dst)
		}
	}
}

// engine にまだある道具は消さない (消す順番を間違えたゲームを作らないため)。
func TestKeepsToolsStillInEngine(t *testing.T) {
	// WhyNot: 本物の engine を根に使わないのは、一覧の道具が engine から全部
	// 消えた時点で「まだある」場合を作れなくなり、この見張りが空回りするため。
	root := t.TempDir()
	writeFile(t, filepath.Join(root, ".claude", "hooks", "after-flix-edit.py"), "x")
	game := t.TempDir()
	writeFile(t, filepath.Join(game, ".claude", "hooks", "after-flix-edit.py"), "x")
	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, []string{"--game", game}); err != nil || code != 0 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	if !isFile(filepath.Join(game, ".claude", "hooks", "after-flix-edit.py")) {
		t.Error("engine にまだある道具を消してしまった")
	}
	if !strings.Contains(out.String(), "消す物はありません") {
		t.Errorf("出力が想定と違う: %s", out.String())
	}
}

// engine に無い道具だけを消す。素振りでは消さない。
func TestPrunesOnlyToolsGoneFromEngine(t *testing.T) {
	root := t.TempDir()
	game := t.TempDir()
	writeFile(t, filepath.Join(game, "bin", "status.py"), "x")
	writeFile(t, filepath.Join(game, "bin", "my-tool.sh"), "x")

	var dry, dryErr strings.Builder
	if code, err := Run(&dry, &dryErr, root, []string{"--game", game, "--dry-run"}); err != nil || code != 0 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	if !isFile(filepath.Join(game, "bin", "status.py")) {
		t.Error("素振りなのに消した")
	}
	if !strings.Contains(dry.String(), "消す: bin/status.py") {
		t.Errorf("素振りが消す物を出していない: %s", dry.String())
	}

	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, []string{"--game", game}); err != nil || code != 0 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	if isFile(filepath.Join(game, "bin", "status.py")) {
		t.Error("engine に無い道具が残っている")
	}
	if !isFile(filepath.Join(game, "bin", "my-tool.sh")) {
		t.Error("一覧に無いゲームの道具を消してしまった")
	}
}

// What: 古い呼び口を持つ settings.json が、道具を消す前に今の口へ直ること。
func TestRewritesStaleHookCalls(t *testing.T) {
	root := t.TempDir()
	game := t.TempDir()
	writeFile(t, filepath.Join(game, ".claude", "settings.json"),
		`{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/after-flix-work.py\""}]}],`+
			`"SessionEnd":[{"hooks":[{"type":"command","command":"python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/session-diet.py\""}]}],`+
			`"Custom":[{"hooks":[{"type":"command","command":"make -s status"}]}]}}`)
	writeFile(t, filepath.Join(game, ".claude", "hooks", "after-flix-work.py"), "x")

	var dry, dryErr strings.Builder
	if code, err := Run(&dry, &dryErr, root, []string{"--game", game, "--dry-run"}); err != nil || code != 0 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	if strings.Contains(read(t, filepath.Join(game, ".claude", "settings.json")), "bin/fge") {
		t.Error("素振りなのに書き換えた")
	}

	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, []string{"--game", game}); err != nil || code != 0 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	got := read(t, filepath.Join(game, ".claude", "settings.json"))
	if strings.Contains(got, "python3") {
		t.Errorf("古い呼び口が残っている: %s", got)
	}
	if !strings.Contains(got, `\"$CLAUDE_PROJECT_DIR/bin/fge\" hook-flix-work`) {
		t.Errorf("hook-flix-work へ直っていない: %s", got)
	}
	if strings.Contains(got, "session-diet") || strings.Contains(got, "SessionEnd") {
		t.Errorf("廃止した session-diet の呼び出しが残っている: %s", got)
	}
	if !strings.Contains(got, `"make -s status"`) {
		t.Errorf("関係のない呼び口まで触った: %s", got)
	}
	if !strings.Contains(out.String(), "呼び口 2 件") {
		t.Errorf("直した数を出していない: %s", out.String())
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func TestMissingGameAborts(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, repoRoot(), []string{"--game", filepath.Join(t.TempDir(), "nope")})
	if err != nil || code != 1 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	if !strings.Contains(errOut.String(), "見つかりません") {
		t.Errorf("理由が出ていない: %s", errOut.String())
	}
}

func TestNoGameAborts(t *testing.T) {
	var out, errOut strings.Builder
	if code, _ := Run(&out, &errOut, repoRoot(), nil); code != 1 {
		t.Fatalf("code=%d", code)
	}
}

func TestUnknownArgAborts(t *testing.T) {
	var out, errOut strings.Builder
	if code, _ := Run(&out, &errOut, repoRoot(), []string{"--bogus"}); code != 2 {
		t.Fatalf("code=%d", code)
	}
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// & や > を含むコマンドは、手で書いた settings.json の形のまま見つけて二重に足さない。
func TestAddMissingHooksKeepsAmpersandCommandOnce(t *testing.T) {
	dir := t.TempDir()
	cmd := `cd "$CLAUDE_PROJECT_DIR" && make -s status > /dev/null`
	hook := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":` + quote(cmd) + `}]}]}}`
	game := filepath.Join(dir, "game.json")
	pack := filepath.Join(dir, "pack.json")
	writeFile(t, game, hook)
	writeFile(t, pack, hook)
	if n, err := AddMissingHooks(game, pack); err != nil || n != 0 {
		t.Errorf("n=%d err=%v（すでにあるのに足した）: %s", n, err, read(t, game))
	}
}

// ゲームが最上位の RemovedHooksKey に書いたフックは、配るたびに足し直さない。
func TestAddMissingHooksSkipsMarkedRemoved(t *testing.T) {
	dir := t.TempDir()
	game := filepath.Join(dir, "game.json")
	pack := filepath.Join(dir, "pack.json")
	writeFile(t, game, `{"`+RemovedHooksKey+`":["hook-art-edit"],"hooks":{}}`)
	writeFile(t, pack, `{"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[`+
		`{"type":"command","command":"bin/fge hook-art-edit"}]}]}}`)
	if n, err := AddMissingHooks(game, pack); err != nil || n != 0 {
		t.Errorf("n=%d err=%v（外した印のあるフックを足した）: %s", n, err, read(t, game))
	}
}

// quote は手で書いた JSON と同じく、& や > を逃がさずに引用する。
func quote(s string) string { return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"` }

// engine が道具名を足した matcher（Codex の apply_patch）は、既にあるゲームの同じフックのグループにも広げる。
// ゲームが足したフックの混ざるグループと、配る側に無い道具名を持つ matcher は触らない。
func TestAddMissingHooksWidensMatcher(t *testing.T) {
	dir := t.TempDir()
	pack := filepath.Join(dir, "pack.json")
	game := filepath.Join(dir, "game.json")
	os.WriteFile(pack, []byte(`{"hooks":{"PostToolUse":[{"matcher":"Edit|Write|apply_patch","hooks":[{"type":"command","command":"bin/fge hook-a"},{"type":"command","command":"bin/fge hook-b"}]}],
	  "PreToolUse":[{"matcher":"Edit|Write|apply_patch","hooks":[{"type":"command","command":"bin/fge hook-c"}]}]}}`), 0o644)
	os.WriteFile(game, []byte(`{"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"bin/fge hook-a"},{"type":"command","command":"bin/fge hook-b"}]}],
	  "PreToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"bin/fge hook-c"},{"type":"command","command":"make mine"}]}]}}`), 0o644)
	n, err := AddMissingHooks(game, pack)
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	body, _ := os.ReadFile(game)
	if !strings.Contains(string(body), `"matcher": "Edit|Write|apply_patch"`) || !strings.Contains(string(body), `"matcher": "Edit|Write"`) {
		t.Errorf("PostToolUse だけ広がるはず: %s", body)
	}
}
