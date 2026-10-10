package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func repoRoot() string { return filepath.Join("..", "..", "..") }

func load(t *testing.T) *Rules {
	t.Helper()
	r, err := LoadRules(repoRoot())
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func payloadOf(t *testing.T, v any) *strings.Reader {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return strings.NewReader(string(data))
}

func TestLoadRulesAbortsWhenMissing(t *testing.T) {
	if _, err := LoadRules(t.TempDir()); err == nil {
		t.Error("規約ファイルが無いのに緑で通った")
	}
}

// Edit・Write の形は file_path から 1 つ拾う。
func TestEditedPathsFromFilePath(t *testing.T) {
	p := Payload{"tool_input": map[string]any{"file_path": "src/A.flix"}}
	got := p.EditedPaths(load(t))
	if len(got) != 1 || got[0] != "src/A.flix" {
		t.Errorf("got %v", got)
	}
}

// apply_patch の形は 1 パッチの中の全ファイルを拾う。
func TestEditedPathsFromPatch(t *testing.T) {
	cmd := "*** Update File: src/A.flix\n@@\n-x\n*** Add File: test/B.flix\n*** Move to: src/C.flix\n"
	p := Payload{"tool_input": map[string]any{"command": cmd}}
	got := p.EditedPaths(load(t))
	want := []string{"src/A.flix", "test/B.flix", "src/C.flix"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("got %v want %v", got, want)
	}
}

// 編集ファイルは tool_response・直下のキーからも拾う (エージェントごとに形が違う)。
func TestEditedPathTriesEveryShape(t *testing.T) {
	if got := (Payload{"tool_response": map[string]any{"path": "a.flix"}}).EditedPath(); got != "a.flix" {
		t.Errorf("got %q", got)
	}
	if got := (Payload{"file_path": "b.flix"}).EditedPath(); got != "b.flix" {
		t.Errorf("got %q", got)
	}
	if got := (Payload{}).EditedPath(); got != "" {
		t.Errorf("got %q", got)
	}
}

// パッケージの根は flix.toml のある所。
func TestFindPkg(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "flix.toml"), "")
	writeFile(t, filepath.Join(root, "src", "A.flix"), "")
	got := FindPkg(load(t), filepath.Join(root, "src", "A.flix"))
	want, _ := filepath.EvalSymlinks(root)
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

// flix.toml が無ければパッケージ無し (フックは黙って降りる)。
func TestFindPkgReturnsEmpty(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "src", "A.flix"), "")
	if got := FindPkg(load(t), filepath.Join(root, "src", "A.flix")); got != "" {
		t.Errorf("got %q", got)
	}
}

// 状態の置き場はパッケージのパスから決まる (同じパスなら同じ置き場)。
func TestStateDirIsStable(t *testing.T) {
	r := load(t)
	if StateDir(r, "/a/b") != StateDir(r, "/a/b") {
		t.Error("同じパッケージで置き場が変わった")
	}
	if StateDir(r, "/a/b") == StateDir(r, "/a/c") {
		t.Error("別のパッケージで置き場が同じ")
	}
}

// 常駐の数の上限は 1 を下回らない。
func TestMaxDaemonCountIsAtLeastOne(t *testing.T) {
	r := load(t)
	t.Setenv(*r.Checkd.MaxDaemons.EnvVar, "0")
	if got := MaxDaemonCount(r); got < 1 {
		t.Errorf("got %d", got)
	}
}

// 環境変数で上限を差し替えられる (機械ごとに固定したいとき)。
func TestMaxDaemonCountHonorsEnv(t *testing.T) {
	r := load(t)
	t.Setenv(*r.Checkd.MaxDaemons.EnvVar, "7")
	if got := MaxDaemonCount(r); got != 7 {
		t.Errorf("got %d", got)
	}
}

// 印は「このセッションが触った」ことだけを表す。
func TestFlixTouchLeavesMarker(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	pkg := t.TempDir()
	writeFile(t, filepath.Join(pkg, "flix.toml"), "")
	writeFile(t, filepath.Join(pkg, "src", "A.flix"), "")

	var errOut strings.Builder
	code := RunFlixTouch(&errOut, repoRoot(), payloadOf(t, map[string]any{
		"session_id": "S1",
		"tool_input": map[string]any{"file_path": filepath.Join(pkg, "src", "A.flix")},
	}))
	if code != 0 || errOut.String() != "" {
		t.Fatalf("code=%d err=%q", code, errOut.String())
	}
	r := load(t)
	real, _ := filepath.EvalSymlinks(pkg)
	marker := filepath.Join(StateDir(r, real), "touched-"+SessionHash(r, "S1"))
	if !isFile(marker) {
		t.Errorf("印が無い: %s", marker)
	}
}

// .flix 以外の保存では何もしない。
func TestFlixTouchIgnoresOtherFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	var errOut strings.Builder
	code := RunFlixTouch(&errOut, repoRoot(), payloadOf(t, map[string]any{
		"session_id": "S1",
		"tool_input": map[string]any{"file_path": "/tmp/notes.md"},
	}))
	if code != 0 {
		t.Fatalf("code=%d", code)
	}
	if entries, err := os.ReadDir(filepath.Join(home, ".cache")); err == nil && len(entries) > 0 {
		t.Error("何も触っていないのに置き場を作った")
	}
}

// 形の読めないペイロードは無音で降りる (フックの都合で作業を壊さない)。
func TestBrokenPayloadIsSilent(t *testing.T) {
	var errOut strings.Builder
	if code := RunFlixTouch(&errOut, repoRoot(), strings.NewReader("not json")); code != 0 {
		t.Errorf("code=%d", code)
	}
	if code := RunSessionDiet(&errOut, repoRoot(), strings.NewReader("not json")); code != 0 {
		t.Errorf("廃止した口が 0 以外を返した: code=%d", code)
	}
	if errOut.String() != "" {
		t.Errorf("黙っていない: %q", errOut.String())
	}
}

// 直前のブロックで継続ターンに入っているなら、何もせず降りる (止まれなくならない)。
func TestFlixWorkYieldsWhenStopHookActive(t *testing.T) {
	var errOut strings.Builder
	code := RunFlixWork(&errOut, repoRoot(), payloadOf(t, map[string]any{
		"session_id": "S1", "stop_hook_active": true,
	}))
	if code != 0 || errOut.String() != "" {
		t.Fatalf("code=%d err=%q", code, errOut.String())
	}
}

// git リポジトリでない所では検査そのものをしない。
func TestFlixWorkSkipsOutsideGit(t *testing.T) {
	var errOut strings.Builder
	code := RunFlixWork(&errOut, tempRootWithRules(t), payloadOf(t, map[string]any{"session_id": "S1"}))
	if code != 0 {
		t.Fatalf("code=%d err=%q", code, errOut.String())
	}
}

// 規約ファイルが読めなければ、黙って緑にせず理由を出して止まる。
func TestFlixWorkAbortsWithoutRules(t *testing.T) {
	var errOut strings.Builder
	code := RunFlixWork(&errOut, t.TempDir(), payloadOf(t, map[string]any{"session_id": "S1"}))
	if code != 2 || !strings.Contains(errOut.String(), "規約ファイルを読めません") {
		t.Fatalf("code=%d err=%q", code, errOut.String())
	}
}

// tempRootWithRules は規約データだけを持つ使い捨ての根を組む。
func tempRootWithRules(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, name := range []string{"hooks.json", "explain-error.json"} {
		body, err := os.ReadFile(filepath.Join(repoRoot(), "bin", "lint-rules", name))
		if err != nil {
			t.Fatal(err)
		}
		writeFile(t, filepath.Join(root, "bin", "lint-rules", name), string(body))
	}
	return root
}

// 書いたファイルの拡張子に当たる検査だけを走らせる。
func TestArtEditRunsMatchingLintOnly(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "panel.ui.json")
	writeFile(t, target, "{}")
	ran := map[string]bool{}
	lints := map[string]Lint{
		"palette":     func(o, e *strings.Builder, a []string) int { ran["palette"] = true; return 0 },
		"ui-overflow": func(o, e *strings.Builder, a []string) int { ran["ui-overflow"] = true; return 0 },
		"view":        func(o, e *strings.Builder, a []string) int { ran["view"] = true; return 0 },
	}
	var errOut strings.Builder
	code := RunArtEdit(&errOut, repoRoot(), payloadOf(t, map[string]any{
		"tool_input": map[string]any{"file_path": target},
	}), lints)
	if code != 0 || errOut.String() != "" {
		t.Fatalf("code=%d err=%q", code, errOut.String())
	}
	if !ran["ui-overflow"] || ran["palette"] || ran["view"] {
		t.Errorf("走った検査が想定と違う: %v", ran)
	}
}

// 失敗した検査は、決まりの前置きを付けて Claude へ返す。
func TestArtEditReportsFailure(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "panel.ui.json")
	writeFile(t, target, "{}")
	lints := map[string]Lint{
		"ui-overflow": func(o, e *strings.Builder, a []string) int {
			o.WriteString("はみ出しています\n")
			return 1
		},
	}
	var errOut strings.Builder
	code := RunArtEdit(&errOut, repoRoot(), payloadOf(t, map[string]any{
		"tool_input": map[string]any{"file_path": target},
	}), lints)
	if code != 2 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(errOut.String(), "lint-ui-overflow が失敗しました") ||
		!strings.Contains(errOut.String(), "はみ出しています") {
		t.Errorf("出力が想定と違う: %q", errOut.String())
	}
}

// 引数の {file} は書かれたファイルのパスに置き換わる。
func TestArtEditSubstitutesFile(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "panel.ui.json")
	writeFile(t, target, "{}")
	var got []string
	lints := map[string]Lint{
		"ui-overflow": func(o, e *strings.Builder, a []string) int { got = a; return 0 },
	}
	var errOut strings.Builder
	RunArtEdit(&errOut, repoRoot(), payloadOf(t, map[string]any{
		"tool_input": map[string]any{"file_path": target},
	}), lints)
	if len(got) != 2 || got[0] != "--strict" || got[1] != target {
		t.Errorf("got %v", got)
	}
}

// 実在しないファイルは見ない。
func TestArtEditIgnoresMissingFile(t *testing.T) {
	var errOut strings.Builder
	code := RunArtEdit(&errOut, repoRoot(), payloadOf(t, map[string]any{
		"tool_input": map[string]any{"file_path": "/nope/x.ui.json"},
	}), map[string]Lint{})
	if code != 0 || errOut.String() != "" {
		t.Fatalf("code=%d err=%q", code, errOut.String())
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
