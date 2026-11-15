package compare

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func solid(w, h int, c color.NRGBA) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetNRGBA(x, y, c)
		}
	}
	return img
}

// 半透明の画素は前乗せせずに比べる: alpha 0 の画素で色だけ違っても差になる（RGBA で比べると潰れる所）。
func TestDiffNRGBASeesColorUnderZeroAlpha(t *testing.T) {
	a := solid(2, 1, color.NRGBA{10, 20, 30, 0})
	b := solid(2, 1, color.NRGBA{10, 20, 30, 0})
	b.SetNRGBA(1, 0, color.NRGBA{12, 20, 30, 0})
	got := DiffNRGBA(a, b, true)
	if got.Pixels != 1 || got.MaxDelta != 2 || got.Total != 2 {
		t.Fatalf("got %+v", got)
	}
}

// alpha を見ない時は、alpha だけ違う画素を差にしない（opaque な canvas と alpha を持つ FBO の絵を比べる時）。
func TestDiffNRGBAIgnoresAlphaWhenAsked(t *testing.T) {
	got := DiffNRGBA(solid(2, 1, color.NRGBA{10, 20, 30, 255}), solid(2, 1, color.NRGBA{10, 20, 30, 128}), false)
	if got.Pixels != 0 {
		t.Fatalf("got %+v", got)
	}
}

// 大きさが違えば Pixels = -1。
func TestDiffNRGBASizeMismatch(t *testing.T) {
	if got := DiffNRGBA(solid(2, 2, color.NRGBA{}), solid(3, 2, color.NRGBA{}), true); got.Pixels != -1 {
		t.Fatalf("got %+v", got)
	}
}

// 表は # の行と空の行を読まず、場面ごとの許す差を返す。
func TestReadTolerancesSkipsComments(t *testing.T) {
	got, err := ReadTolerances(strings.NewReader("# 場面\t許す差\t理由\n\ntext\t2\t字の縁\nboxes\t0\t-\n"))
	if err != nil || len(got) != 2 || got["text"] != 2 || got["boxes"] != 0 {
		t.Fatalf("got %v err %v", got, err)
	}
}

func writePNGFile(t *testing.T, path string, img image.Image) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
}

// 許す差の内なら 0・超えたら 1 を返し、差があれば差の絵を書く。
func TestRunPixelDiffUsesToleranceByName(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "text.png")
	b := filepath.Join(dir, "other.png")
	writePNGFile(t, a, solid(2, 2, color.NRGBA{100, 100, 100, 255}))
	writePNGFile(t, b, solid(2, 2, color.NRGBA{102, 100, 100, 255}))
	tsv := filepath.Join(dir, "tolerance.tsv")
	if err := os.WriteFile(tsv, []byte("text\t2\t字の縁\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	diffPath := filepath.Join(dir, "diff.png")
	var out, errOut strings.Builder
	within := RunPixelDiff([]string{a, b, "--tolerance", tsv, "--out", diffPath}, &out, &errOut)
	over := RunPixelDiff([]string{a, b, "--out", diffPath}, &out, &errOut)
	if _, err := os.Stat(diffPath); within != 0 || over != 1 || err != nil {
		t.Fatalf("within=%d over=%d diff err=%v out=%s err=%s", within, over, err, out.String(), errOut.String())
	}
}
