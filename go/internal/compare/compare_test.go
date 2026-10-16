package compare

// 何を守るか: 差のある絵だけが diff になり前後の 1 枚が書かれること、基準の一時の worktree が
// 終わった後に残らないこと、片方にしか無い物を取りこぼさないこと。

import (
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
)

func writePNG(t *testing.T, path string, c color.RGBA) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	for i := 0; i < 16; i++ {
		img.SetRGBA(i%4, i/4, color.RGBA{0, 0, 0, 255})
	}
	img.SetRGBA(1, 1, c)
	os.MkdirAll(filepath.Dir(path), 0o755)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	png.Encode(f, img)
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %s", args, out)
	}
}

// 描き出しの代わりに src/ の PNG を gallery/ へ写すだけのゲーム。
const makefile = `render-all:
	mkdir -p gallery && cp src/*.png gallery/
gallery-sounds:
	@true
`

func fakeEngine(t *testing.T) string {
	dir := t.TempDir()
	for path, body := range map[string]string{
		"mk/game.mk": "", "Makefile": "VERSION := 0.1.0\n",
		"engine_full/artifact/package.fpkg": "x", "engine_full/flix.toml": "",
	} {
		os.MkdirAll(filepath.Join(dir, filepath.Dir(path)), 0o755)
		os.WriteFile(filepath.Join(dir, path), []byte(body), 0o644)
	}
	return dir
}

func TestCompareFindsChangedImageAndCleansUp(t *testing.T) {
	game := t.TempDir()
	git(t, game, "init", "-q")
	os.WriteFile(filepath.Join(game, "Makefile"), []byte(makefile), 0o644)
	os.WriteFile(filepath.Join(game, "flix.toml"),
		[]byte(`"github:ababup1192/flix_game_engine" = { version = "0.1.0" }`+"\n"), 0o644)
	writePNG(t, filepath.Join(game, "src", "same.png"), color.RGBA{255, 255, 255, 255})
	writePNG(t, filepath.Join(game, "src", "moved.png"), color.RGBA{255, 0, 0, 255})
	writePNG(t, filepath.Join(game, "src", "gone.png"), color.RGBA{0, 255, 0, 255})
	git(t, game, "add", ".")
	git(t, game, "commit", "-qm", "base")
	writePNG(t, filepath.Join(game, "src", "moved.png"), color.RGBA{0, 0, 255, 255})
	os.Remove(filepath.Join(game, "src", "gone.png"))
	// 基準側は何も渡さなければ今の作業場と同じエンジンを使う。
	os.WriteFile(filepath.Join(game, "local.mk"), []byte("ENGINE := "+fakeEngine(t)+"\n"), 0o644)

	code := Run([]string{"--base", "HEAD"}, Options{
		Game: game, Out: io.Discard, Err: io.Discard,
		HeavyOpts: heavy.Options{Lock: filepath.Join(t.TempDir(), "lock"), Err: io.Discard},
	})
	if code != 0 {
		t.Fatalf("compare が %d で終わった", code)
	}
	report, err := os.ReadFile(filepath.Join(game, "debug", "compare", "report.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"image\tsame.png\tsame", "image\tmoved.png\tdiff", "image\tgone.png\tonly-base"} {
		if !strings.Contains(string(report), want) {
			t.Fatalf("report.tsv に %q がない:\n%s", want, report)
		}
	}
	if _, err := os.Stat(filepath.Join(game, "debug", "compare", "pairs", "moved.png")); err != nil {
		t.Fatalf("差のある絵の前後の 1 枚が無い")
	}
	out, _ := exec.Command("git", "-C", game, "worktree", "list").Output()
	if strings.Count(string(out), "\n") != 1 {
		t.Fatalf("基準の worktree が残った:\n%s", out)
	}
}

func TestFrameRangesFoldsRuns(t *testing.T) {
	if got := frameRanges([]int{3, 4, 5, 9}); got != "コマ 3〜5, 9" {
		t.Fatalf("got %q", got)
	}
}

func TestVideoDiffListsFramesAndWritesSideBySide(t *testing.T) {
	ff := findFFmpeg()
	if ff == "" {
		t.Skip("ffmpeg が無い")
	}
	dir := t.TempDir()
	mk := func(name, color2 string) string {
		p := filepath.Join(dir, name)
		// 3 コマ目からだけ色が違う、幅が奇数の 6 コマ。
		filter := "color=c=black:s=33x20:r=10:d=0.2[a];color=c=" + color2 + ":s=33x20:r=10:d=0.4[b];[a][b]concat=n=2:v=1"
		if out, err := exec.Command(ff, "-y", "-v", "error", "-filter_complex", filter,
			"-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv444p", p).CombinedOutput(); err != nil {
			t.Fatalf("%s: %s", err, out)
		}
		return p
	}
	a, b := mk("a.mp4", "white"), mk("b.mp4", "red")
	o := Options{OutDir: filepath.Join(dir, "out")}
	detail, pair, video := diffVideo(o, "x.mp4", a, b)
	if !strings.Contains(detail, "4 / 6 コマ") {
		t.Fatalf("差のあるコマの数がずれた: %q", detail)
	}
	if pair == "" || video == "" {
		t.Fatalf("最初のコマの前後か左右の mp4 が無い: %q %q (%s)", pair, video, detail)
	}
}
