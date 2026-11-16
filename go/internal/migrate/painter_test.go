package migrate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testGPU = "webgpu Dawn Metal IntegratedGPU Test"

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// engine の TestRenderCachePainter.painterKeyOfMatchesGo と同じ値。
func TestPainterKeyIsTheSameFormulaAsTheEngine(t *testing.T) {
	if got := painterKey("abc", "webgpu X"); got != "70f9eafc038469c97ce72e1586c67dbade76b7f3ac2e192cc4a7910e2685dc2a" {
		t.Fatalf("painterKey = %s", got)
	}
}

func TestCachedPNGForKeepsTheKeyForSoftAndMixesThePainterForWebGPU(t *testing.T) {
	key := strings.Repeat("ab", 32)
	if got := cachedPNGFor("/c", PainterSoft, key); got != cachedPNG("/c", key) {
		t.Fatalf("soft = %s", got)
	}
	if got := cachedPNGFor("/c", testGPU, key); got != cachedPNG("/c", painterKey(key, testGPU)) {
		t.Fatalf("webgpu = %s", got)
	}
}

func TestCachedPNGForIsEmptyForAnUnknownPainter(t *testing.T) {
	key := strings.Repeat("ab", 32)
	for _, p := range []string{"", "webgpu", "mixed: soft / " + testGPU} {
		if got := cachedPNGFor("/c", p, key); got != "" {
			t.Errorf("%q = %s", p, got)
		}
	}
}

func TestChoosePainterDefaultsToGPUWithoutABaseline(t *testing.T) {
	if v, _, p := choosePainter("", false, ""); v != painterWebGPU || p != "" {
		t.Fatalf("v=%q p=%q", v, p)
	}
}

func TestChoosePainterTakesCPUWhenAskedWithoutABaseline(t *testing.T) {
	if v, _, _ := choosePainter(PaintCPU, false, ""); v != PainterSoft {
		t.Fatalf("v=%q", v)
	}
}

func TestChoosePainterFollowsACPUBaselineAndSaysSo(t *testing.T) {
	if v, note, _ := choosePainter("", true, PainterSoft); v != PainterSoft || note == "" {
		t.Fatalf("v=%q note=%q", v, note)
	}
}

func TestChoosePainterFollowsAGPUBaseline(t *testing.T) {
	if v, _, p := choosePainter("", true, testGPU); v != painterWebGPU || p != "" {
		t.Fatalf("v=%q p=%q", v, p)
	}
}

func TestChoosePainterStopsWhenGPUIsAskedAgainstACPUBaseline(t *testing.T) {
	if _, _, p := choosePainter(PaintGPU, true, PainterSoft); !strings.Contains(p, "make migrate-baseline MIGRATE_OVERWRITE=1 MIGRATE_PAINT=gpu") {
		t.Fatalf("p=%q", p)
	}
}

func TestChoosePainterStopsWhenCPUIsAskedAgainstAGPUBaseline(t *testing.T) {
	if _, _, p := choosePainter(PaintCPU, true, testGPU); !strings.Contains(p, "MIGRATE_PAINT=cpu") {
		t.Fatalf("p=%q", p)
	}
}

func TestShotPainterTakesTheOnePainterThatPainted(t *testing.T) {
	if got, _, _ := shotPainter([]string{testGPU}, painterWebGPU, ""); got != testGPU {
		t.Fatalf("got %q", got)
	}
}

func TestShotPainterSaysWhenGPUFellBackToCPU(t *testing.T) {
	if got, note, _ := shotPainter([]string{PainterSoft}, painterWebGPU, ""); got != PainterSoft || note == "" {
		t.Fatalf("got %q note %q", got, note)
	}
}

func TestShotPainterStopsOnMixedPainters(t *testing.T) {
	if got, _, p := shotPainter([]string{PainterSoft, testGPU}, painterWebGPU, ""); !strings.HasPrefix(got, "mixed: ") || p == "" {
		t.Fatalf("got %q p %q", got, p)
	}
}

func TestShotPainterTakesTheBaselineWhenNothingWasPainted(t *testing.T) {
	if got, _, _ := shotPainter(nil, painterWebGPU, testGPU); got != testGPU {
		t.Fatalf("got %q", got)
	}
}

func TestPainterMismatchIsEmptyForTheSamePainter(t *testing.T) {
	if got := painterMismatch(testGPU, testGPU); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestPainterMismatchIsEmptyWhenOneIsUnknown(t *testing.T) {
	if got := painterMismatch("", testGPU); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestPainterMismatchNamesTheRebaselineForDifferentGPUs(t *testing.T) {
	if got := painterMismatch(testGPU, "webgpu other"); !strings.Contains(got, rebaselineHint) {
		t.Fatalf("got %q", got)
	}
}

func TestPainterMismatchOffersCPUAgainstACPUBaseline(t *testing.T) {
	if got := painterMismatch(PainterSoft, testGPU); !strings.Contains(got, "MIGRATE_PAINT=cpu") {
		t.Fatalf("got %q", got)
	}
}

func TestRecordPainterReadsTheSummary(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "logs", ShootSummaryFile), `{"painter": "`+testGPU+`"}`)
	if got := recordPainter(root); got != testGPU {
		t.Fatalf("got %q", got)
	}
}

func TestRecordPainterIsSoftForASummaryWithoutPainter(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "logs", ShootSummaryFile), `{"jobs": 3}`)
	if got := recordPainter(root); got != PainterSoft {
		t.Fatalf("got %q", got)
	}
}

func TestRecordPainterIsUnknownWithoutASummary(t *testing.T) {
	if got := recordPainter(t.TempDir()); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestPaintedWithSkipsKeysOnlyFrames(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "flows", "a", "frames", "world", "frames.json"), `{"painter": "none", "paintedWith": ""}`)
	writeFile(t, filepath.Join(root, "flows", "b", "frames", "world", "frames.json"), `{"painter": "webgpu", "paintedWith": "`+testGPU+`"}`)
	writeFile(t, filepath.Join(root, "flows", "c", "frames", "all", "frames.json"), `{"painter": "soft"}`)
	got := strings.Join(paintedWith(root), "|")
	if got != "soft|"+testGPU {
		t.Fatalf("got %q", got)
	}
}

func TestDiffStopsWhenThePaintersDiffer(t *testing.T) {
	base, cur := t.TempDir(), t.TempDir()
	writeFile(t, filepath.Join(base, "logs", ShootSummaryFile), `{"painter": "soft"}`)
	writeFile(t, filepath.Join(cur, "logs", ShootSummaryFile), `{"painter": "`+testGPU+`"}`)
	var out, errOut strings.Builder
	if code := runDiff([]string{base, cur}, &out, &errOut); code != 2 || !strings.Contains(errOut.String(), "描き手が違う") {
		t.Fatalf("code %d err %q", code, errOut.String())
	}
}
