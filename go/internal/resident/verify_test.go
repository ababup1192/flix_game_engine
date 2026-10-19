package resident

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestShouldCopySkipsGeneratedAndGit(t *testing.T) {
	for _, rel := range []string{".git", "debug", "gallery", "build/headless/resident.json", "build/headless/proj/artifact"} {
		if ShouldCopy(rel, !strings.Contains(rel, ".json")) {
			t.Errorf("%s を写した", rel)
		}
	}
}

func TestShouldCopyKeepsJarAndSources(t *testing.T) {
	cases := map[string]bool{
		"src/Main.flix": false, "lib": true, "assets/novel.kind.json": false, "build": true, "build/headless": true,
		"build/headless/headless.jar": false, "build/headless/jar.manifest": false,
		"build/headless/proj/src/FgeHeadlessMain.flix": false,
	}
	for rel, isDir := range cases {
		if !ShouldCopy(rel, isDir) {
			t.Errorf("%s を写さなかった", rel)
		}
	}
}

func TestWrittenHasNewAndChangedOnly(t *testing.T) {
	before := FileTable{"debug/a.png": "1", "debug/b.png": "2"}
	after := FileTable{"debug/a.png": "1", "debug/b.png": "3", "gallery/c.png": "4"}
	want := FileTable{"debug/b.png": "3", "gallery/c.png": "4"}
	if got := Written(before, after); !reflect.DeepEqual(got, want) {
		t.Fatalf("%v", got)
	}
}

func TestDiffTablesNamesChangedAndOneSided(t *testing.T) {
	a := FileTable{"x": "1", "y": "2", "z": "3"}
	b := FileTable{"x": "1", "y": "9", "w": "4"}
	if got := DiffTables(a, b); !reflect.DeepEqual(got, []string{"w", "y", "z"}) {
		t.Fatalf("%v", got)
	}
}

func TestNormalizeStdoutHidesVolatileText(t *testing.T) {
	in := "wrote /private/var/folders/x/T/fge-verify-1/novel/debug/a.png in 1.25s (pid 4242, port 50123) 2026-10-19 20:31:05\n"
	want := "wrote <root>/debug/a.png in <dur> (pid <n>, port <n>) <datetime>"
	if got := NormalizeStdout(in, "/private/var/folders/x/T/fge-verify-1/novel", "/var/folders/x/T/fge-verify-1/novel"); got != want {
		t.Fatalf("%q", got)
	}
}

func TestNormalizeStdoutKeepsCounts(t *testing.T) {
	if got := NormalizeStdout("scenes 4 items 120", ""); got != "scenes 4 items 120" {
		t.Fatalf("%q", got)
	}
}

func TestNormalizeStdoutHidesUnresolvedRoot(t *testing.T) {
	if got := NormalizeStdout("/var/folders/q/novel/x", "/private/var/folders/q/novel", "/var/folders/q/novel"); got != "<root>/x" {
		t.Fatalf("%q", got)
	}
}

func TestFirstLineDiffFindsLine(t *testing.T) {
	if n, _, _ := FirstLineDiff("a\nb\nc", "a\nB\nc"); n != 2 {
		t.Fatalf("%d", n)
	}
}

func TestFirstLineDiffSameIsZero(t *testing.T) {
	if n, _, _ := FirstLineDiff("a\nb", "a\nb"); n != 0 {
		t.Fatalf("%d", n)
	}
}

func TestTouchJSONFlipsEveryColor(t *testing.T) {
	out, _ := TouchJSON([]byte(`{"bg": "#10203F", "fg": "#ffffff", "n": "#12"}`))
	if string(out) != `{"bg": "#10203e", "fg": "#fffffe", "n": "#12"}` {
		t.Fatalf("%s", out)
	}
}

func TestTouchJSONWithoutColorAppendsSpace(t *testing.T) {
	out, _ := TouchJSON([]byte(`{"n": 1}`))
	if string(out) != `{"n": 1} ` {
		t.Fatalf("%q", out)
	}
}

func TestTouchPNGChangesOnlyTopLeft(t *testing.T) {
	src := image.NewNRGBA(image.Rect(0, 0, 2, 1))
	src.SetNRGBA(0, 0, color.NRGBA{10, 20, 30, 255})
	src.SetNRGBA(1, 0, color.NRGBA{40, 50, 60, 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, src); err != nil {
		t.Fatal(err)
	}
	out, _, err := TouchPNG(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(bytes.NewReader(out))
	if err != nil {
		t.Fatal(err)
	}
	got := []color.NRGBA{color.NRGBAModel.Convert(img.At(0, 0)).(color.NRGBA), color.NRGBAModel.Convert(img.At(1, 0)).(color.NRGBA)}
	want := []color.NRGBA{{11, 20, 30, 255}, {40, 50, 60, 255}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%v", got)
	}
}

func TestBetweenArgsPicksOtherShot(t *testing.T) {
	got, _ := BetweenArgs("", []string{"render", "SHOT=title"}, []string{"title", "choice"})
	if !reflect.DeepEqual(got, []string{"render", "SHOT=choice"}) {
		t.Fatalf("%v", got)
	}
}

func TestBetweenArgsWithoutShotPicksFirst(t *testing.T) {
	got, _ := BetweenArgs("", []string{"render-all"}, []string{"title", "choice"})
	if !reflect.DeepEqual(got, []string{"render", "SHOT=title"}) {
		t.Fatalf("%v", got)
	}
}

func TestBetweenArgsGivenWins(t *testing.T) {
	got, _ := BetweenArgs("transition-video FLOW=a", []string{"render"}, []string{"title"})
	if !reflect.DeepEqual(got, []string{"transition-video", "FLOW=a"}) {
		t.Fatalf("%v", got)
	}
}

func TestBetweenArgsNoOtherShotFails(t *testing.T) {
	if _, err := BetweenArgs("", []string{"render", "SHOT=title"}, []string{"title"}); err == nil {
		t.Fatal("誤りにならない")
	}
}

func TestComparePairSameIsEmpty(t *testing.T) {
	a := RunResult{Label: "1 素の道", Code: 0, Stdout: "x", Files: FileTable{"debug/a.png": "abcdefabcdefabcdef"}}
	b := a
	b.Label = "2 常駐"
	if got := ComparePair(a, b); len(got) != 0 {
		t.Fatalf("%v", got)
	}
}

func TestComparePairNamesFileAndPair(t *testing.T) {
	a := RunResult{Label: "4 a", Files: FileTable{"debug/a.png": "abcdefabcdefabcdef"}}
	b := RunResult{Label: "5 b", Files: FileTable{"debug/a.png": "123456123456123456"}}
	got := ComparePair(a, b)
	if len(got) != 1 || !strings.Contains(got[0], "4↔5") || !strings.Contains(got[0], "debug/a.png") {
		t.Fatalf("%v", got)
	}
}

func TestCopyTreeRewritesRelativeSymlink(t *testing.T) {
	base := t.TempDir()
	src := filepath.Join(base, "game")
	writeFile(t, filepath.Join(base, "shared", "pkg.fpkg"), "pkg")
	writeFile(t, filepath.Join(src, "src", "Main.flix"), "mod Main {}")
	if err := os.MkdirAll(filepath.Join(src, "lib"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../shared/pkg.fpkg", filepath.Join(src, "lib", "pkg.fpkg")); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(t.TempDir(), "copy", "game")
	if err := CopyTree(src, dst); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dst, "lib", "pkg.fpkg"))
	if err != nil || string(raw) != "pkg" {
		t.Fatalf("%q %v", raw, err)
	}
}

func TestCopyTreeLeavesOutGenerated(t *testing.T) {
	src := t.TempDir()
	writeFile(t, filepath.Join(src, "debug", "a.png"), "x")
	writeFile(t, filepath.Join(src, "build", "headless", "resident.json"), "{}")
	writeFile(t, filepath.Join(src, "build", "headless", "jar.manifest"), "m")
	dst := filepath.Join(t.TempDir(), "g")
	if err := CopyTree(src, dst); err != nil {
		t.Fatal(err)
	}
	got, _ := SnapshotAll(dst)
	if !reflect.DeepEqual(got, []string{"build/headless/jar.manifest"}) {
		t.Fatalf("%v", got)
	}
}

func TestSnapshotOutputsSkipsDebugHeadless(t *testing.T) {
	d := t.TempDir()
	writeFile(t, filepath.Join(d, "debug", "headless", "x.log"), "x")
	writeFile(t, filepath.Join(d, "gallery", "t.png"), "t")
	got, err := SnapshotOutputs(d)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got.SortedPaths(), []string{"gallery/t.png"}) {
		t.Fatalf("%v", got)
	}
}

// SnapshotAll はテスト用に、根の下の全ファイルの相対パスを字の順で返す。
func SnapshotAll(root string) ([]string, error) {
	var out []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			rel, _ := filepath.Rel(root, path)
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	return out, err
}

func TestWithoutPrefixesDropsMatching(t *testing.T) {
	got := WithoutPrefixes(FileTable{"debug/shot/shot-1.png": "a", "debug/choice.png": "b"}, []string{"debug/shot/"})
	if !reflect.DeepEqual(got, FileTable{"debug/choice.png": "b"}) {
		t.Fatalf("%v", got)
	}
}
