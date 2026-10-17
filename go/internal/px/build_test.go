package px

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// engineRoot はテストから見たリポジトリのルート（bin/lint-rules/ がある所）。
const engineRoot = "../../.."

// copyTree は testdata の 1 つを一時フォルダへ写す。
func copyTree(t *testing.T, src string) string {
	t.Helper()
	dst := t.TempDir()
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(dst, rel), data, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	return dst
}

// 指定が描くコマを base から消してから描いても、ゲームの assets と 1 バイトも違わない
// （puzzle はタブ字下げを base から、relic は 2 字下げを spec の indent から取る）。
func TestBytesMatchAssets(t *testing.T) {
	for _, tc := range []struct {
		dir, spec, sprite string
		frames            int
	}{
		{"puzzle", "puzzle.pxsrc.json", "internet_dungeon.puzzle.sprite.json", 22},
		{"relic", "relic.pxsrc.json", "internet_dungeon.relic.sprite.json", 3},
	} {
		t.Run(tc.dir, func(t *testing.T) { checkBytesMatch(t, tc.dir, tc.spec, tc.sprite, tc.frames) })
	}
}

func checkBytesMatch(t *testing.T, dir, specFile, spriteFile string, wantFrames int) {
	root := copyTree(t, filepath.Join("testdata", dir))
	basePath := filepath.Join(root, "assets", spriteFile)
	want, err := os.ReadFile(basePath)
	if err != nil {
		t.Fatal(err)
	}
	spec, err := loadSpec(filepath.Join(root, "art", specFile))
	if err != nil {
		t.Fatal(err)
	}
	doc, err := pxlib.ReadOrdered(basePath)
	if err != nil {
		t.Fatal(err)
	}
	sprites, _ := doc.Get("sprites")
	blanked := 0
	for _, sp := range spec.Sprites {
		entry, _ := sprites.(*pxlib.Obj).Get(sp.Name)
		frames, _ := entry.(*pxlib.Obj).Get("frames")
		for _, f := range sp.Frames {
			frames.(*pxlib.Obj).Set(f.Name, []any{})
			blanked++
		}
	}
	// 消した base はタブで書く（relic は spec の indent で 2 字に戻ること）
	if err := os.WriteFile(basePath, []byte(pxlib.DumpPy(doc, "\t")), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := build(root, filepath.Join("art", specFile), buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Frames) != blanked || blanked != wantFrames {
		t.Fatalf("描いたコマ %d・消したコマ %d（%d のはず）", len(res.Frames), blanked, wantFrames)
	}
	got, err := os.ReadFile(filepath.Join(root, "atelier", spriteFile))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		gl, wl := strings.Split(string(got), "\n"), strings.Split(string(want), "\n")
		for i := range min(len(gl), len(wl)) {
			if gl[i] != wl[i] {
				t.Fatalf("%d 行目が違う:\n got  %q\n want %q", i+1, gl[i], wl[i])
			}
		}
		t.Fatalf("行数が違う: got %d want %d", len(gl), len(wl))
	}
	name := strings.TrimSuffix(specFile, ".pxsrc.json")
	for _, f := range []string{"sheet.png", "report.json", spec.Sprites[0].Name + ".png"} {
		if _, err := os.Stat(filepath.Join(root, "debug", "px", name, "last", f)); err != nil {
			t.Errorf("%s が無い: %v", f, err)
		}
	}
}
