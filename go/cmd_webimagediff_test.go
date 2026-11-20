package main

import (
	"errors"
	"image"
	"image/color"
	"os"
	"path/filepath"
	"testing"
)

func TestWebImageDiffArgsDefaultLimit(t *testing.T) {
	o, err := parseWebImageDiffArgs([]string{"game"})
	if err != nil || o.Limit != 12 {
		t.Fatalf("got %+v, %v", o, err)
	}
}

func TestWebImageDiffArgsRejectZeroLimit(t *testing.T) {
	if _, err := parseWebImageDiffArgs([]string{"game", "--limit", "0"}); err == nil {
		t.Fatal("--limit 0 を通した")
	}
}

func TestWebImageDiffArgsRejectJSON(t *testing.T) {
	if _, err := parseWebImageDiffArgs([]string{"game", "--json"}); err == nil {
		t.Fatal("出せない --json を通した")
	}
}

func TestWebImageDiffArgsReadHelp(t *testing.T) {
	if _, err := parseWebImageDiffArgs([]string{"--help"}); !errors.Is(err, errCommandHelp) {
		t.Fatalf("err = %v", err)
	}
}

func TestWebImageDiffArgsNeedGame(t *testing.T) {
	if _, err := parseWebImageDiffArgs(nil); err == nil {
		t.Fatal("ゲーム無しを通した")
	}
}

func TestVisibleDiffIgnoresColorUnderZeroAlpha(t *testing.T) {
	if d := visibleDiff(color.NRGBA{255, 0, 0, 0}, color.NRGBA{0, 255, 0, 0}); d != [3]int{} {
		t.Fatalf("d = %v", d)
	}
}

func TestVisibleDiffScalesByAlpha(t *testing.T) {
	if d := visibleDiff(color.NRGBA{200, 0, 0, 255}, color.NRGBA{100, 0, 0, 255}); d[0] != 100 {
		t.Fatalf("d = %v", d)
	}
}

func TestCenterCropTakesMiddle(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 10, 10))
	img.SetNRGBA(5, 5, color.NRGBA{9, 9, 9, 255})
	if got := centerCrop(img, 4).NRGBAAt(2, 2); got.R != 9 {
		t.Fatalf("got %v", got)
	}
}

func TestCenterCropKeepsSmallImage(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 3, 2))
	if b := centerCrop(img, 4).Bounds(); b.Dx() != 3 || b.Dy() != 2 {
		t.Fatalf("bounds %v", b)
	}
}

// diffJob は src と dst（WebP の代わり）を大きさだけで置いた変換。
func diffJob(t *testing.T, dir, rel string, srcSize, dstSize int, v webImageVerdict) webJob {
	t.Helper()
	src, dst := filepath.Join(dir, rel+".png"), filepath.Join(dir, rel+".webp")
	if err := os.WriteFile(src, make([]byte, srcSize), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, make([]byte, dstSize), 0o644); err != nil {
		t.Fatal(err)
	}
	v.Rel = rel
	return webJob{rel: rel, src: src, dst: dst, verdict: &v}
}

func diffRowNames(rows []webImageDiffRow) []string {
	var names []string
	for _, r := range rows {
		names = append(names, r.v.Rel)
	}
	return names
}

func TestSelectWebImageDiffRowsSortsByColors(t *testing.T) {
	dir := t.TempDir()
	jobs := []webJob{
		diffJob(t, dir, "b", 100, 10, webImageVerdict{Kind: webImageAutoLossy, Colors: 5000}),
		diffJob(t, dir, "a", 100, 10, webImageVerdict{Kind: webImageAutoLossy, Colors: 2000}),
	}
	if got := diffRowNames(selectWebImageDiffRows(jobs, webImageDiffOptions{Limit: 12}, nil)); len(got) != 2 || got[0] != "a" {
		t.Fatalf("got %v", got)
	}
}

func TestSelectWebImageDiffRowsSkipsLossless(t *testing.T) {
	dir := t.TempDir()
	jobs := []webJob{diffJob(t, dir, "a", 100, 10, webImageVerdict{Kind: webImageLossless})}
	if got := selectWebImageDiffRows(jobs, webImageDiffOptions{Limit: 12}, nil); len(got) != 0 {
		t.Fatalf("got %v", diffRowNames(got))
	}
}

func TestSelectWebImageDiffRowsSkipsWebpLargerThanSource(t *testing.T) {
	dir := t.TempDir()
	jobs := []webJob{diffJob(t, dir, "a", 10, 100, webImageVerdict{Kind: webImageAutoLossy, Colors: 2000})}
	if got := selectWebImageDiffRows(jobs, webImageDiffOptions{Limit: 12}, nil); len(got) != 0 {
		t.Fatalf("got %v", diffRowNames(got))
	}
}

func TestSelectWebImageDiffRowsCutsAtLimit(t *testing.T) {
	dir := t.TempDir()
	jobs := []webJob{
		diffJob(t, dir, "a", 100, 10, webImageVerdict{Kind: webImageAutoLossy, Colors: 2000}),
		diffJob(t, dir, "b", 100, 10, webImageVerdict{Kind: webImageAutoLossy, Colors: 3000}),
	}
	if got := selectWebImageDiffRows(jobs, webImageDiffOptions{Limit: 1}, nil); len(got) != 1 {
		t.Fatalf("got %v", diffRowNames(got))
	}
}

func TestSelectWebImageDiffRowsTakesExplicitWithFlag(t *testing.T) {
	dir := t.TempDir()
	jobs := []webJob{diffJob(t, dir, "a", 100, 10, webImageVerdict{Kind: webImageExplicitSame, Colors: 2000, explicitRules: []int{0}})}
	if got := selectWebImageDiffRows(jobs, webImageDiffOptions{Limit: 12, Explicit: true}, nil); len(got) != 1 {
		t.Fatalf("got %v", diffRowNames(got))
	}
}
