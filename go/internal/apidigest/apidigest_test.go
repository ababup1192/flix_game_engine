package apidigest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func repoRoot() string { return filepath.Join("..", "..", "..") }

var day = time.Date(2026, 8, 18, 0, 0, 0, 0, time.UTC)

// fixture は engine/src だけを持つ小さなリポジトリを作る。
func fixture(t *testing.T, body string) string {
	t.Helper()
	root := t.TempDir()
	src := filepath.Join(root, "engine", "src")
	if err := os.MkdirAll(src, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "Sample.flix"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Makefile"), []byte("VERSION := 9.9.9\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestStampCarriesVersionAndDate(t *testing.T) {
	root := fixture(t, "mod M {\n    pub def f(): Unit = ()\n}\n")
	targets := Build(root, filepath.Join(root, "docs"), day)
	want := "<!-- engine v9.9.9 / 生成: 2026-08-18 -->\n"
	if !strings.HasPrefix(targets[0].Content, want) {
		t.Fatalf("先頭行が %q", strings.SplitN(targets[0].Content, "\n", 2)[0])
	}
}

func TestVersionFallsBackWhenMakefileIsMissing(t *testing.T) {
	root := t.TempDir()
	if got := engineVersion(root); got != "?" {
		t.Fatalf("Makefile が無いときのバージョンが %q", got)
	}
}

func TestDatelessMasksOnlyTheDate(t *testing.T) {
	got := Dateless("<!-- engine v1.0 / 生成: 2026-08-18 -->\n2026-08-18\n")
	if got != "<!-- engine v1.0 / 生成: 0000-00-00 -->\n2026-08-18\n" {
		t.Fatalf("均し方が %q", got)
	}
}

func TestDigestListsDeclarations(t *testing.T) {
	root := fixture(t, "mod M {\n    /// たす\n    pub def add(a: Int32): Int32 = a\n    pub enum Shape { case Box }\n}\n")
	targets := Build(root, filepath.Join(root, "docs"), day)
	body := targets[0].Content
	for _, want := range []string{
		"## M — `engine/src/Sample.flix`",
		"- たす",
		"  `pub def add(a: Int32): Int32`",
		"- `pub enum Shape { case Box }`",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("%q が出ていない\n---\n%s", want, body)
		}
	}
}

func TestIndexCountsModulesAndDecls(t *testing.T) {
	root := fixture(t, "mod M {\n    pub def a(): Unit = ()\n    pub def b(): Unit = ()\n}\n")
	targets := Build(root, filepath.Join(root, "docs"), day)
	index := targets[len(targets)-1].Content
	if !strings.Contains(index, "| engine | 1 | 2 | [api-digest/engine.md](api-digest/engine.md) |") {
		t.Fatalf("索引の表が\n%s", index)
	}
	if !strings.Contains(index, "| engine_world | 0 | 0 |") {
		t.Fatalf("空のパッケージが 0 件で出ていない\n%s", index)
	}
}

func TestWriteThenCheckIsQuiet(t *testing.T) {
	root := fixture(t, "mod M {\n    pub def f(): Unit = ()\n}\n")
	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, nil); err != nil || code != 0 {
		t.Fatalf("書き出しが %d %v", code, err)
	}
	if !strings.Contains(out.String(), "wrote docs/api-digest.md") {
		t.Fatalf("書き出しの報告が %q", out.String())
	}
	out.Reset()
	if code, err := Run(&out, &errOut, root, []string{"--check"}); err != nil || code != 0 {
		t.Fatalf("--check が %d %v (%s)", code, err, errOut.String())
	}
	if !strings.HasPrefix(out.String(), "OK: docs/api-digest.md") {
		t.Fatalf("--check の出力が %q", out.String())
	}
}

func TestCheckFailsWhenSourceMovedOn(t *testing.T) {
	root := fixture(t, "mod M {\n    pub def f(): Unit = ()\n}\n")
	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, nil); err != nil || code != 0 {
		t.Fatalf("書き出しが %d %v", code, err)
	}
	src := filepath.Join(root, "engine", "src", "Sample.flix")
	if err := os.WriteFile(src, []byte("mod M {\n    pub def g(): Unit = ()\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	errOut.Reset()
	code, err := Run(&out, &errOut, root, []string{"--check"})
	if err != nil {
		t.Fatal(err)
	}
	if code != 1 {
		t.Fatalf("ずれているのに終了コードが %d", code)
	}
	if !strings.Contains(errOut.String(), "docs/api-digest/engine.md がソースとずれています") {
		t.Fatalf("NG の行が stderr に出ていない: %q / %q", out.String(), errOut.String())
	}
}

// TestWriteSkipsWhenOnlyTheDateWouldChange は日付だけの空騒ぎを作らないことを見る。
func TestWriteSkipsWhenOnlyTheDateWouldChange(t *testing.T) {
	root := fixture(t, "mod M {\n    pub def f(): Unit = ()\n}\n")
	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, nil); err != nil || code != 0 {
		t.Fatalf("書き出しが %d %v", code, err)
	}
	path := filepath.Join(root, "docs", "api-digest.md")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	stale := strings.Replace(string(before), "生成: ", "生成: ", 1)
	stale = Dateless(stale)
	if err := os.WriteFile(path, []byte(stale), 0o644); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if code, err := Run(&out, &errOut, root, nil); err != nil || code != 0 {
		t.Fatalf("2 回目が %d %v", code, err)
	}
	if strings.Contains(out.String(), "api-digest.md") {
		t.Fatalf("日付しか違わないのに書き直した: %q", out.String())
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != stale {
		t.Fatal("日付だけのために上書きした")
	}
}

func TestOutDirIsHonored(t *testing.T) {
	root := fixture(t, "mod M {\n    pub def f(): Unit = ()\n}\n")
	outDir := filepath.Join(t.TempDir(), "elsewhere")
	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, []string{"--out", outDir}); err != nil || code != 0 {
		t.Fatalf("--out が %d %v", code, err)
	}
	for _, rel := range []string{"api-digest.md", filepath.Join("api-digest", "engine.md")} {
		if _, err := os.Stat(filepath.Join(outDir, rel)); err != nil {
			t.Errorf("%s が書かれていない", rel)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "docs")); err == nil {
		t.Error("--out を渡したのに docs/ を作った")
	}
}

// TestRepoDigestIsUpToDate はリポの docs/ が今のソースと合っているかを見る。
func TestRepoDigestIsUpToDate(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, repoRoot(), []string{"--check"})
	if err != nil {
		t.Fatal(err)
	}
	if code != 0 {
		t.Fatalf("docs/api-digest がソースとずれている: %s", errOut.String())
	}
}

// 名前の段に Internal を持つモジュールだけを中身の部品と見なす（Internals のような語の一部は見なさない）。
func TestIsInternalModuleMatchesWholeSegmentOnly(t *testing.T) {
	got := []bool{IsInternalModule("App.Internal.Runner"), IsInternalModule("App.Internal"), IsInternalModule("App"), IsInternalModule("App.Internals")}
	want := []bool{true, true, false, false}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
}
