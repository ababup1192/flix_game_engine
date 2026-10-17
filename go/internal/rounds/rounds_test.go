package rounds

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// repoRoot はテストから見たリポジトリのルート (go/internal/rounds の 3 つ上)。
func repoRoot() string { return filepath.Join("..", "..", "..") }

func loadRules(t *testing.T) *Rules {
	t.Helper()
	rules, err := LoadRules(repoRoot())
	if err != nil {
		t.Fatal(err)
	}
	return rules
}

// newGame は PNG 1 枚と台本 1 本を持つ一時のゲームのルートを作る。
func newGame(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for name, body := range map[string]string{
		"pic.png":         string(pxlib.PNGMagic) + "png-body",
		"art/hero.src.py": "v1",
	} {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func run(t *testing.T, root string, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, repoRoot(), root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String(), errOut.String()
}

func TestSnapStacksRoundsInOrder(t *testing.T) {
	root := newGame(t)
	run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	hist := filepath.Join(root, loadRules(t).HistoryDir, "hero")
	if got := NextRound(hist); got != 3 {
		t.Fatalf("2 回積んだ後の次の番号 = %d, want 3", got)
	}
}

func TestSnapStopsAfterMaxRounds(t *testing.T) {
	root := newGame(t)
	rules := loadRules(t)
	for i := 0; i < rules.MaxRounds; i++ {
		run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	}
	code, _, _ := run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	if code != 1 {
		t.Fatalf("上限を超えた snap の終了コード = %d, want 1", code)
	}
}

func TestSnapNewMovesOldRoundsAside(t *testing.T) {
	root := newGame(t)
	run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	run(t, root, "snap", "hero", "pic.png", "art/hero.src.py", "--new")
	hist := filepath.Join(root, loadRules(t).HistoryDir, "hero")
	if got := NextRound(hist); got != 2 {
		t.Fatalf("--new の後の次の番号 = %d, want 2", got)
	}
}

func TestRestoreBringsBackSavedScript(t *testing.T) {
	root := newGame(t)
	script := filepath.Join(root, "art", "hero.src.py")
	run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	if err := os.WriteFile(script, []byte("v2"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, root, "restore", "hero", "r1", "art/hero.src.py")
	got, _ := os.ReadFile(script)
	if string(got) != "v1" {
		t.Fatalf("restore 後の台本 = %q, want %q", got, "v1")
	}
}

// restore は上書きする前の台本（積んでいない書きかけ）を history に残す。
func TestRestoreKeepsCurrentScript(t *testing.T) {
	root := newGame(t)
	script := filepath.Join(root, "art", "hero.src.py")
	run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	if err := os.WriteFile(script, []byte("v2"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, root, "restore", "hero", "r1", "art/hero.src.py")
	kept, _ := filepath.Glob(filepath.Join(root, "debug", "history", "hero", "before-restore-*.hero.src.py"))
	if len(kept) != 1 {
		t.Fatalf("戻す前の台本が残っていない: %v", kept)
	}
	if got, _ := os.ReadFile(kept[0]); string(got) != "v2" {
		t.Fatalf("残した台本 = %q, want v2", got)
	}
}

func TestSnapDrawsSpriteSheet(t *testing.T) {
	root := newGame(t)
	sprite := `{"version":1,"legend":{"a":"#ff0000"},"sprites":{"hero":{"frames":{"0":["a.","aa"],"1":[".a","aa"]}}}}`
	if err := os.WriteFile(filepath.Join(root, "hero.sprite.json"), []byte(sprite), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, root, "snap", "hero", "hero.sprite.json", "art/hero.src.py")
	img, err := pxlib.LoadPNG(filepath.Join(root, loadRules(t).HistoryDir, "hero", "r1.png"))
	if err != nil {
		t.Fatal(err)
	}
	// 左上のコマの等倍の (0,0) は sheetGap だけずれた所に赤で置かれる。
	if got := img.RGBAt(sheetGap, sheetGap); got != 0xff0000 {
		t.Fatalf("見本の最初の画素 = %06x, want ff0000", got)
	}
}

// r2（askAt）を積んだら、そこで止めて依頼主に 3 つ聞く案内を出す。
func TestSnapAtAskRoundSaysStop(t *testing.T) {
	root := newGame(t)
	run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	_, out, _ := run(t, root, "snap", "hero", "pic.png", "art/hero.src.py")
	if !strings.Contains(out, "ここで止める") || !strings.Contains(out, "③") {
		t.Errorf("r2 の案内に止める・3 つ聞くが無い:\n%s", out)
	}
}
