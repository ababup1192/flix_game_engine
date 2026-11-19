package compare

import (
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// captureFixture は基準の SHA の一覧・基準の絵のフォルダ・今のフォルダを作り、Run の入力を返す。
// base と cur は名前（scene/frame-N.png）→ 絵。baseImages が false なら基準の絵を置かない。
func captureFixture(t *testing.T, base, cur map[string]image.Image, baseImages bool) CaptureBaselineCheck {
	t.Helper()
	dir := t.TempDir()
	c := CaptureBaselineCheck{
		Sums:      filepath.Join(dir, "base.sha256"),
		Images:    filepath.Join(dir, "images"),
		Current:   filepath.Join(dir, "cur"),
		Tolerance: DefaultCaptureTolerance,
	}
	write := func(root string, imgs map[string]image.Image) string {
		var sums strings.Builder
		for n, img := range imgs {
			p := filepath.Join(root, n)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			writePNGFile(t, p, img)
			sha, err := fileSHA256(p)
			if err != nil {
				t.Fatal(err)
			}
			fmt.Fprintf(&sums, "%s  %s\n", sha, n)
		}
		return sums.String()
	}
	baseRoot := filepath.Join(dir, "base-shot")
	if baseImages {
		baseRoot = c.Images
	}
	if err := os.WriteFile(c.Sums, []byte("# adapter\n"+write(baseRoot, base)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(c.Current, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(c.Current, "SHA256SUMS"), []byte(write(c.Current, cur)), 0o644); err != nil {
		t.Fatal(err)
	}
	return c
}

func runCapture(c CaptureBaselineCheck) (int, string) {
	var out, errOut strings.Builder
	code := c.Run(&out, &errOut)
	return code, out.String() + errOut.String()
}

// withPixels は img の写しの (x, 0) から n 画素の R を delta だけ上げた物。
func withPixels(img *image.NRGBA, n, delta int) *image.NRGBA {
	cp := image.NewNRGBA(img.Bounds())
	copy(cp.Pix, img.Pix)
	for x := 0; x < n; x++ {
		c := cp.NRGBAAt(x, 0)
		c.R = uint8(int(c.R) + delta)
		cp.SetNRGBA(x, 0, c)
	}
	return cp
}

var gray = color.NRGBA{100, 100, 100, 255}

func TestCaptureBaselineSameHashPasses(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img}, map[string]image.Image{"s/frame-1.png": img}, true)
	if code, log := runCapture(c); code != 0 {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestCaptureBaselineSmallDiffPasses(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img}, map[string]image.Image{"s/frame-1.png": withPixels(img, 18, 16)}, true)
	code, log := runCapture(c)
	if code != 0 || !strings.Contains(log, "小さい差で通した s/frame-1.png") {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestCaptureBaselineTooManyPixelsFails(t *testing.T) {
	img := solid(128, 4, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img}, map[string]image.Image{"s/frame-1.png": withPixels(img, DefaultCaptureTolerance.MaxPixels+1, DefaultCaptureTolerance.Threshold+1)}, true)
	if code, log := runCapture(c); code != 1 {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestCaptureBaselineLargeDeltaFails(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img}, map[string]image.Image{"s/frame-1.png": withPixels(img, 1, DefaultCaptureTolerance.MaxDelta+1)}, true)
	if code, log := runCapture(c); code != 1 {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestCaptureBaselineWithoutBaseImageFails(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img}, map[string]image.Image{"s/frame-1.png": withPixels(img, 1, 1)}, false)
	code, log := runCapture(c)
	if code != 1 || !strings.Contains(log, "基準の絵が") {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestCaptureBaselineStaleBaseImageFails(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img}, map[string]image.Image{"s/frame-1.png": withPixels(img, 1, 1)}, true)
	writePNGFile(t, filepath.Join(c.Images, "s/frame-1.png"), withPixels(img, 1, 1))
	if code, log := runCapture(c); code != 1 {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestCaptureBaselineSeedsImageOnSameHash(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img}, map[string]image.Image{"s/frame-1.png": img}, false)
	runCapture(c)
	want, _ := fileSHA256(filepath.Join(c.Current, "s/frame-1.png"))
	if got, _ := fileSHA256(filepath.Join(c.Images, "s/frame-1.png")); got != want {
		t.Fatalf("基準の絵 %q・今の絵 %q", got, want)
	}
}

func TestCaptureBaselineMissingFrameFails(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img, "s/frame-2.png": img}, map[string]image.Image{"s/frame-1.png": img}, true)
	if code, log := runCapture(c); code != 1 {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestCaptureBaselineSkipDropsScene(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img, "t__x/frame-1.png": img}, map[string]image.Image{"s/frame-1.png": img}, true)
	c.Skip = []string{"t__x"}
	if code, log := runCapture(c); code != 0 {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestCaptureBaselineOnlyMatchesHead(t *testing.T) {
	img := solid(32, 32, gray)
	c := captureFixture(t, map[string]image.Image{"s/frame-1.png": img, "t__x/frame-1.png": img}, map[string]image.Image{"t__x/frame-1.png": img}, true)
	c.Only = []string{"t"}
	if code, log := runCapture(c); code != 0 {
		t.Fatalf("code %d\n%s", code, log)
	}
}

func TestLessCaptureNameSortsFrameNumbers(t *testing.T) {
	if !lessCaptureName("a/frame-2.png", "a/frame-10.png") {
		t.Fatal("frame-2 が frame-10 の前に来ない")
	}
}

// 実機で撮った絵での確かめ。0.103.0 の前に tidepool の 12 枚が字のふちで数画素ずれた時の撮り物（基準どおりの絵と今の絵）を
// GL_CAPTURE_OLD・GL_CAPTURE_NEW（フォルダ）で渡す。無ければ飛ばす（撮り物は git の外）。
func realCaptureDirs(t *testing.T) (string, string) {
	t.Helper()
	old, cur := os.Getenv("GL_CAPTURE_OLD"), os.Getenv("GL_CAPTURE_NEW")
	if old == "" || cur == "" {
		t.Skip("GL_CAPTURE_OLD・GL_CAPTURE_NEW が無い")
	}
	return old, cur
}

func realPairs(t *testing.T, old string) []string {
	t.Helper()
	names, _ := filepath.Glob(filepath.Join(old, "tidepool-starter__*", "frame-*.png"))
	if len(names) == 0 {
		t.Skipf("%s に tidepool の撮り物が無い", old)
	}
	rel := make([]string, len(names))
	for i, n := range names {
		rel[i], _ = filepath.Rel(old, n)
	}
	return rel
}

func mustReadPNG(t *testing.T, p string) image.Image {
	t.Helper()
	img, err := readPNG(p)
	if err != nil {
		t.Fatal(err)
	}
	return img
}

func TestRealCaptureFontEdgeDriftIsWithin(t *testing.T) {
	old, cur := realCaptureDirs(t)
	for _, n := range realPairs(t, old) {
		d := DiffNRGBAOver(mustReadPNG(t, filepath.Join(old, n)), mustReadPNG(t, filepath.Join(cur, n)), true, DefaultCaptureTolerance.Threshold)
		if d.Pixels == 0 || !DefaultCaptureTolerance.Within(d) {
			t.Errorf("%s: %+v", n, d)
		}
	}
}

func TestRealCaptureOneFrameShiftIsOutside(t *testing.T) {
	old, cur := realCaptureDirs(t)
	for _, n := range realPairs(t, old) {
		var k int
		if _, err := fmt.Sscanf(filepath.Base(n), "frame-%d.png", &k); err != nil || k >= 6 {
			continue
		}
		next := filepath.Join(filepath.Dir(n), fmt.Sprintf("frame-%d.png", k+1))
		d := DiffNRGBAOver(mustReadPNG(t, filepath.Join(old, n)), mustReadPNG(t, filepath.Join(cur, next)), true, DefaultCaptureTolerance.Threshold)
		if DefaultCaptureTolerance.Within(d) {
			t.Errorf("%s と次のコマ: %+v", n, d)
		}
	}
}

func TestRealCapturePaintedPatchIsOutside(t *testing.T) {
	old, cur := realCaptureDirs(t)
	for _, n := range realPairs(t, old) {
		src := mustReadPNG(t, filepath.Join(cur, n))
		painted := image.NewNRGBA(src.Bounds())
		draw.Draw(painted, painted.Bounds(), src, src.Bounds().Min, draw.Src)
		draw.Draw(painted, image.Rect(100, 100, 116, 116), &image.Uniform{color.NRGBA{255, 0, 255, 255}}, image.Point{}, draw.Src)
		d := DiffNRGBAOver(mustReadPNG(t, filepath.Join(old, n)), painted, true, DefaultCaptureTolerance.Threshold)
		if DefaultCaptureTolerance.Within(d) {
			t.Errorf("%s に 16x16 を塗った物: %+v", n, d)
		}
	}
}
