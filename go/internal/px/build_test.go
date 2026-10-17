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

// 指定が描くコマを base から消してから描いても、ゲームの assets と 1 バイトも違わない。
func TestPuzzleBytesMatch(t *testing.T) {
	root := copyTree(t, "testdata/puzzle")
	basePath := filepath.Join(root, "assets", "internet_dungeon.puzzle.sprite.json")
	want, err := os.ReadFile(basePath)
	if err != nil {
		t.Fatal(err)
	}
	spec, err := loadSpec(filepath.Join(root, "art", "puzzle.pxsrc.json"))
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
	if err := os.WriteFile(basePath, []byte(pxlib.DumpPy(doc, "\t")), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := build(root, "art/puzzle.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Frames) != blanked || blanked != 22 {
		t.Fatalf("描いたコマ %d・消したコマ %d（22 のはず）", len(res.Frames), blanked)
	}
	got, err := os.ReadFile(filepath.Join(root, "atelier", "internet_dungeon.puzzle.sprite.json"))
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
	for _, name := range []string{"sheet.png", "report.json", "pieceGuard.png"} {
		if _, err := os.Stat(filepath.Join(root, "debug", "px", "puzzle", "last", name)); err != nil {
			t.Errorf("%s が無い: %v", name, err)
		}
	}
}
