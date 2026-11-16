package migrate

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// planWorld は基準と、鍵だけ撮った（PNG の無い）新しい記録を置いた場所。
type planWorld struct{ base, cur string }

func newPlanWorld(t *testing.T) planWorld {
	t.Helper()
	root := t.TempDir()
	return planWorld{base: filepath.Join(root, "baseline"), cur: filepath.Join(root, "new")}
}

// keysOnly は rec を flow に書き、PNG を消す（鍵だけ撮った回）。
func keysOnly(t *testing.T, r *rec, root, flow string) {
	t.Helper()
	r.writeFlow(t, root, flow, "design")
	for name := range r.frames {
		if err := os.Remove(filepath.Join(root, FlowsDir, flow, "design", name)); err != nil {
			t.Fatal(err)
		}
	}
}

func (w planWorld) plan(t *testing.T, cache string) (*paintPlan, *Side, *Side) {
	t.Helper()
	return w.planWith(t, cache, PainterSoft)
}

func (w planWorld) planWith(t *testing.T, cache, painter string) (*paintPlan, *Side, *Side) {
	t.Helper()
	base, err := LoadSide(w.base)
	if err != nil {
		t.Fatal(err)
	}
	cur, err := LoadSide(w.cur)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := planPaint(cur, base, cache, painter)
	if err != nil {
		t.Fatal(err)
	}
	return plan, cur, base
}

func TestPlanPaintsNothingWhenKeysMatch(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyA, keyB), w.cur, "route")
	plan, _, _ := w.plan(t, "")
	if plan.Painted != 0 || plan.KeysOnly != 2 {
		t.Fatalf("painted=%d keysOnly=%d", plan.Painted, plan.KeysOnly)
	}
}

func TestPlanPaintsOnlyTheChangedFrame(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "route")
	plan, _, _ := w.plan(t, "")
	if got := plan.Paint["route"]["world"]; len(got) != 1 || got[0] != 1 {
		t.Fatalf("塗るコマ %v（f0001 だけのはず）", plan.Paint)
	}
}

func TestPlanCopiesFromBaselineBySameKey(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyB, keyB), w.cur, "route")
	plan, _, _ := w.plan(t, "")
	if plan.FromBaseline != 1 || plan.Painted != 0 || !fileExists(filepath.Join(w.cur, FlowsDir, "route", "design", "frames/world/f0001.png")) {
		t.Fatalf("基準の同じ鍵から写さない: %+v", plan)
	}
}

func TestPlanCopiesFromRenderCache(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "route")
	cache := t.TempDir()
	if err := os.MkdirAll(filepath.Join(cache, keyC[:2]), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writePNG(cachedPNG(cache, keyC), solid(100, 100, color.NRGBA{R: 9, A: 255})); err != nil {
		t.Fatal(err)
	}
	plan, _, _ := w.plan(t, cache)
	if plan.FromCache != 1 || plan.Painted != 0 {
		t.Fatalf("render-cache から写さない: %+v", plan)
	}
}

func TestPlanCopiesAGPUFrameFromTheRenderCacheUnderThePainterKey(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "route")
	cache := t.TempDir()
	stored := cachedPNGFor(cache, testGPU, keyC)
	if err := os.MkdirAll(filepath.Dir(stored), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writePNG(stored, solid(100, 100, color.NRGBA{R: 9, A: 255})); err != nil {
		t.Fatal(err)
	}
	plan, _, _ := w.planWith(t, cache, testGPU)
	if plan.FromCache != 1 || plan.Painted != 0 {
		t.Fatalf("描き手の素性つきの名前から写さない: %+v", plan)
	}
}

func TestPlanDoesNotCopyACPUFrameIntoAGPURecord(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "route")
	cache := t.TempDir()
	if err := os.MkdirAll(filepath.Join(cache, keyC[:2]), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writePNG(cachedPNG(cache, keyC), solid(100, 100, color.NRGBA{R: 9, A: 255})); err != nil {
		t.Fatal(err)
	}
	plan, _, _ := w.planWith(t, cache, testGPU)
	if plan.FromCache != 0 || plan.Painted != 1 {
		t.Fatalf("CPU で塗った絵を GPU の記録へ写した: %+v", plan)
	}
}

func TestPlanPaintsASharedKeyOnceAndCopiesToTheOther(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "one", "design")
	keyedRec(keyA, keyB).writeFlow(t, w.base, "two", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "one")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "two")
	plan, _, _ := w.plan(t, "")
	if plan.Painted != 1 || plan.FromSibling != 1 || len(plan.Copies) != 1 {
		t.Fatalf("同じ鍵を 2 か所で塗る: %+v", plan)
	}
}

func TestSharedKeyCopyLetsDiffComparePixels(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "one", "design")
	keyedRec(keyA, keyB).writeFlow(t, w.base, "two", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "one")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "two")
	plan, _, _ := w.plan(t, "")
	painted := keyedRec(keyC, keyB)
	painted.frames["frames/world/f0001.png"] = solid(100, 100, color.NRGBA{R: 255, A: 255})
	if err := writePNG(filepath.Join(w.cur, FlowsDir, "one", "design", "frames/world/f0001.png"), painted.frames["frames/world/f0001.png"]); err != nil {
		t.Fatal(err)
	}
	for _, c := range plan.Copies {
		if err := copyFile(c.src, c.dst); err != nil {
			t.Fatal(err)
		}
	}
	base, _ := LoadSide(w.base)
	cur, _ := LoadSide(w.cur)
	r := Compare(base, cur, &Accept{}, Options{NoCoverage: true, Th: DefaultThresholds(), Lim: DefaultLimits()})
	if n := len(diffsOf(r, WhatFrame)); n != 2 {
		t.Fatalf("写した先の flow でも画素で比べたはず（差 2 件）: %d %+v", n, r.Diffs)
	}
}

func TestMissingPNGsFindsAForgottenCopy(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "one", "design")
	keyedRec(keyA, keyB).writeFlow(t, w.base, "two", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "one")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "two")
	_, cur, base := w.plan(t, "")
	if miss := missingPNGs(cur, base); len(miss) != 2 {
		t.Fatalf("塗る前に PNG の無いコマ %v（2 枚のはず）", miss)
	}
}

func TestFrameRangesJoinsNeighbours(t *testing.T) {
	if got := frameRanges([]int{7, 1, 2, 3, 9}); got != "frames:1-3,7-7,9-9" {
		t.Fatalf("got %q", got)
	}
}

func TestPaintEnvLeavesOtherLayerKeysOnly(t *testing.T) {
	env := paintEnv(map[string][]int{"world": {4}})
	got := fmt.Sprint(env)
	if got != "["+PaintWorldEnv+"=frames:4-4 "+PaintAllEnv+"=none]" {
		t.Fatalf("got %s", got)
	}
}

func TestSameDrawHashesSpotsAChangedKey(t *testing.T) {
	if bad := sameDrawHashes(map[string]string{"a": "1 x\n"}, map[string]string{"a": "1 y\n"}); len(bad) != 1 {
		t.Fatalf("鍵の変わった 2 回目を見逃した: %v", bad)
	}
}

func TestSameDrawHashesSkipsLinesThatHadNoKey(t *testing.T) {
	if bad := sameDrawHashes(map[string]string{"a": "1 -\n2 x\n"}, map[string]string{"a": "1 y\n2 x\n"}); len(bad) != 0 {
		t.Fatalf("1 回目の鍵が - の行（Pass のあるコマ）で止めた: %v", bad)
	}
}

func TestPlanRefusesAnUnknownLayer(t *testing.T) {
	w := newPlanWorld(t)
	b := keyedRec(keyA, keyB)
	b.writeFlow(t, w.base, "route", "design")
	c := keyedRec(keyC, keyB)
	frames := c.tape["frames"].([]any)
	frames[0].(map[string]any)["file"] = "frames/odd/f0001.png"
	c.frames = map[string]*image.NRGBA{"frames/odd/f0001.png": c.frames["frames/world/f0001.png"]}
	c.drawhash = map[string]string{"frames/odd": "1 " + keyC + "\n"}
	keysOnly(t, c, w.cur, "route")
	base, _ := LoadSide(w.base)
	cur, _ := LoadSide(w.cur)
	if _, err := planPaint(cur, base, "", PainterSoft); err == nil {
		t.Fatal("知らない層のコマを world の旗で塗ろうとした")
	}
}

func TestEngineFingerprintReadsVersionAndPackage(t *testing.T) {
	root := t.TempDir()
	toml := `[dependencies]` + "\n" + `"github:ababup1192/flix_game_engine" = { version = "1.2.3", mount = "fge" }` + "\n"
	if err := os.WriteFile(filepath.Join(root, "flix.toml"), []byte(toml), 0o644); err != nil {
		t.Fatal(err)
	}
	pkg := filepath.Join(root, "lib", "github", "ababup1192", "flix_game_engine", "1.2.3")
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pkg, "flix_game_engine-1.2.3.fpkg"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := engineFingerprint(root); !strings.HasPrefix(got, "1.2.3 ") {
		t.Fatalf("got %q", got)
	}
}

func TestEngineDiffersOnlyWhenBothAreKnown(t *testing.T) {
	if engineDiffers("", "1 a") || !engineDiffers("1 a", "2 b") || engineDiffers("1 a", "1 a") {
		t.Fatal("engineDiffers の答えが違う")
	}
}

func TestFillCopiesMissingPNGsFromASibling(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyA, keyB), w.cur, "route")
	var out, errOut bytes.Buffer
	if code := runFill([]string{w.cur}, &out, &errOut); code != 0 {
		t.Fatalf("code=%d %s", code, errOut.String())
	}
	if !fileExists(filepath.Join(w.cur, FlowsDir, "route", "design", "frames/world/f0002.png")) {
		t.Fatal("欠けた PNG を埋めない")
	}
}

func TestFillFailsWhenNoSourceIsLeft(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "route")
	t.Setenv("FGE_RENDER_CACHE", "off")
	var out, errOut bytes.Buffer
	if code := runFill([]string{w.cur}, &out, &errOut); code != 1 {
		t.Fatalf("埋められないコマがあるのに code=%d", code)
	}
}
