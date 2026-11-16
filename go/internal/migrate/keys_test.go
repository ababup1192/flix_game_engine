package migrate

import (
	"fmt"
	"image"
	"image/color"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	keyA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	keyB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	keyC = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
)

// keyedRec は baseRec のコマを VideoOut の形（frames/world/f<番号>.png と drawhash.txt）にした記録。
// done は f0001、mid は f0002。keys はその 2 枚の鍵。
func keyedRec(done, mid string) *rec {
	r := baseRec()
	frames := r.tape["frames"].([]any)
	frames[0].(map[string]any)["file"] = "frames/world/f0001.png"
	frames[1].(map[string]any)["file"] = "frames/world/f0002.png"
	r.frames = map[string]*image.NRGBA{
		"frames/world/f0001.png": r.frames["frames/done.png"],
		"frames/world/f0002.png": r.frames["frames/mid.png"],
	}
	r.drawhash = map[string]string{"frames/world": fmt.Sprintf("1 %s\n2 %s\n", done, mid)}
	return r
}

func (w *world) runKeys(t *testing.T, noKeys bool) *Result {
	t.Helper()
	a, err := LoadSide(w.base)
	if err != nil {
		t.Fatal(err)
	}
	b, err := LoadSide(w.cur)
	if err != nil {
		t.Fatal(err)
	}
	return Compare(a, b, w.acc, Options{Game: w.game, NoKeys: noKeys, CachePath: filepath.Join(filepath.Dir(w.cur), DiffCacheFile),
		Th: DefaultThresholds(), Lim: DefaultLimits()})
}

func removeFrame(t *testing.T, root, file string) {
	t.Helper()
	if err := os.Remove(filepath.Join(root, FlowsDir, "route", "design", file)); err != nil {
		t.Fatal(err)
	}
}

func TestSameKeysSkipPixels(t *testing.T) {
	b := keyedRec(keyA, keyB)
	r := newWorld(t, b, b.clone()).runKeys(t, false)
	if !r.Passed || r.KeySame != 2 || r.Frames != 2 {
		t.Fatalf("passed=%v keySame=%d frames=%d", r.Passed, r.KeySame, r.Frames)
	}
}

func TestSameKeysTrustTheKeyOverPixels(t *testing.T) {
	b := keyedRec(keyA, keyB)
	c := b.clone()
	c.frames["frames/world/f0001.png"] = solid(100, 100, color.NRGBA{R: 255, A: 255})
	r := newWorld(t, b, c).runKeys(t, false)
	if len(diffsOf(r, WhatFrame)) != 0 {
		t.Fatalf("鍵が同じコマの画素を読んだ: %+v", r.Diffs)
	}
}

func TestNoKeysCatchesPixelsBehindSameKey(t *testing.T) {
	b := keyedRec(keyA, keyB)
	c := b.clone()
	c.frames["frames/world/f0001.png"] = solid(100, 100, color.NRGBA{R: 255, A: 255})
	r := newWorld(t, b, c).runKeys(t, true)
	if len(diffsOf(r, WhatFrame)) != 1 || r.KeySame != 0 {
		t.Fatalf("--no-keys で画素の差を拾わない: keySame=%d %+v", r.KeySame, r.Diffs)
	}
}

func TestOtherKeysComparePixels(t *testing.T) {
	b := keyedRec(keyA, keyB)
	c := b.clone()
	c.drawhash["frames/world"] = fmt.Sprintf("1 %s\n2 %s\n", keyC, keyB)
	c.frames["frames/world/f0001.png"] = solid(100, 100, color.NRGBA{R: 255, A: 255})
	r := newWorld(t, b, c).runKeys(t, false)
	if len(diffsOf(r, WhatFrame)) != 1 || r.KeySame != 1 {
		t.Fatalf("鍵の違うコマの画素の差を拾わない: keySame=%d %+v", r.KeySame, r.Diffs)
	}
}

func TestDashKeysComparePixels(t *testing.T) {
	b := keyedRec(noKey, noKey)
	c := b.clone()
	c.frames["frames/world/f0001.png"] = solid(100, 100, color.NRGBA{R: 255, A: 255})
	r := newWorld(t, b, c).runKeys(t, false)
	if len(diffsOf(r, WhatFrame)) != 1 || r.KeySame != 0 {
		t.Fatalf("鍵が - どうしを同じと見た: keySame=%d %+v", r.KeySame, r.Diffs)
	}
}

func TestSameKeyWithoutNewPNGPasses(t *testing.T) {
	b := keyedRec(keyA, keyB)
	w := newWorld(t, b, b.clone())
	removeFrame(t, w.cur, "frames/world/f0001.png")
	if r := w.runKeys(t, false); !r.Passed {
		t.Fatalf("鍵だけ撮ったコマで止まった: %+v", r.Diffs)
	}
}

func TestOtherKeyWithoutNewPNGStops(t *testing.T) {
	b := keyedRec(keyA, keyB)
	c := b.clone()
	c.drawhash["frames/world"] = fmt.Sprintf("1 %s\n2 %s\n", keyC, keyB)
	w := newWorld(t, b, c)
	removeFrame(t, w.cur, "frames/world/f0001.png")
	r := w.runKeys(t, false)
	if r.Passed || len(diffsOf(r, WhatMissing)) != 1 {
		t.Fatalf("鍵が違うのに PNG の無いコマを通した: %+v", r.Diffs)
	}
}

func TestSameKeyWithoutBaselinePNGStops(t *testing.T) {
	b := keyedRec(keyA, keyB)
	w := newWorld(t, b, b.clone())
	removeFrame(t, w.base, "frames/world/f0001.png")
	if r := w.runKeys(t, false); r.Passed {
		t.Fatal("前の版の PNG が無いのに通した")
	}
}

func TestSecondDiffUsesRememberedResult(t *testing.T) {
	b := keyedRec(keyA, keyB)
	c := b.clone()
	c.drawhash["frames/world"] = fmt.Sprintf("1 %s\n2 %s\n", keyC, keyB)
	w := newWorld(t, b, c)
	w.runKeys(t, false)
	if r := w.runKeys(t, false); r.CacheHits != 1 || !r.Passed {
		t.Fatalf("2 回目に覚えた結果を使わない: hits=%d passed=%v", r.CacheHits, r.Passed)
	}
}

func TestRememberedResultIsKeyedByThresholds(t *testing.T) {
	b := keyedRec(keyA, keyB)
	c := b.clone()
	c.drawhash["frames/world"] = fmt.Sprintf("1 %s\n2 %s\n", keyC, keyB)
	w := newWorld(t, b, c)
	w.runKeys(t, false)
	w.acc.Thresholds = map[string]float64{"doneRatio": 0.99}
	if r := w.runKeys(t, false); r.CacheHits != 0 {
		t.Fatalf("線引きを変えたのに覚えた結果を使った: hits=%d", r.CacheHits)
	}
}

func TestRememberedResultFollowsChangedPNGWithoutKey(t *testing.T) {
	b := keyedRec(noKey, noKey)
	w := newWorld(t, b, b.clone())
	w.runKeys(t, false)
	red := keyedRec(noKey, noKey)
	red.frames["frames/world/f0001.png"] = solid(100, 100, color.NRGBA{R: 255, A: 255})
	red.writeFlow(t, w.cur, "route", "design")
	r := w.runKeys(t, false)
	if len(diffsOf(r, WhatFrame)) != 1 {
		t.Fatalf("鍵の無いコマの PNG が替わったのに覚えた結果で通した: %+v", r.Diffs)
	}
}

func TestRememberedFailureStillWritesHeat(t *testing.T) {
	b := keyedRec(keyA, keyB)
	c := b.clone()
	c.drawhash["frames/world"] = fmt.Sprintf("1 %s\n2 %s\n", keyC, keyB)
	c.frames["frames/world/f0001.png"] = solid(100, 100, color.NRGBA{R: 255, A: 255})
	w := newWorld(t, b, c)
	out := filepath.Join(w.game, "report")
	run := func() *Result {
		a, _ := LoadSide(w.base)
		n, _ := LoadSide(w.cur)
		return Compare(a, n, w.acc, Options{Game: w.game, Out: out, CachePath: filepath.Join(filepath.Dir(w.cur), DiffCacheFile), Th: DefaultThresholds(), Lim: DefaultLimits()})
	}
	run()
	r := run()
	d := diffsOf(r, WhatFrame)
	if len(d) != 1 || d[0].Heat == "" || !fileExists(d[0].Heat) {
		t.Fatalf("2 回目に差の色の図が無い: %+v", d)
	}
}

func TestOtherEngineKeysFallBackToPixels(t *testing.T) {
	b := keyedRec(keyA, keyB)
	c := b.clone()
	c.drawhash["frames/world"] = fmt.Sprintf("1 %s\n2 %s\n", keyC, strings.Repeat("d", 64))
	r := newWorld(t, b, c).runKeys(t, false)
	if r.KeySame != 0 || r.Frames != 2 || !r.Passed {
		t.Fatalf("鍵が全部違う（engine が違う）のに画素で比べない: keySame=%d frames=%d %+v", r.KeySame, r.Frames, r.Diffs)
	}
}

func TestFrameNumberReadsVideoOutNames(t *testing.T) {
	if n, ok := frameNumber("frames/world/f0126.png"); !ok || n != 126 {
		t.Fatalf("n=%d ok=%v", n, ok)
	}
	if _, ok := frameNumber("frames/done.png"); ok {
		t.Fatal("番号の無い名前を読んだ")
	}
}
