package migrate

import (
	"image"
	"image/color"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// ---- 問いの値の読み替え（probeMap） ----

func modeRecs() (*rec, *rec) {
	b := baseRec()
	c := b.clone()
	events(b)[0].(map[string]any)["probes"] = map[string]any{"mood": "calm", "mode": "Nvl"}
	events(b)[2].(map[string]any)["probes"] = map[string]any{"mood": "tense", "mode": "Adv"}
	events(c)[0].(map[string]any)["probes"] = map[string]any{"mood": "calm", "mode": "nvl"}
	events(c)[2].(map[string]any)["probes"] = map[string]any{"mood": "tense", "mode": "bottom"}
	return b, c
}

func TestRenamedProbeValueStopsWithoutMap(t *testing.T) {
	b, c := modeRecs()
	if newWorld(t, b, c).run(t).Passed {
		t.Fatal("mode の値の言い方が替わったのに通した")
	}
}

func TestProbeMapRewritesOldValues(t *testing.T) {
	b, c := modeRecs()
	w := newWorld(t, b, c)
	w.acc.ProbeMap = map[string]map[string]string{"mode": {"Nvl": "nvl", "Adv": "bottom"}}
	if r := w.run(t); !r.Passed {
		t.Fatalf("probeMap で読み替えても落ちた: %+v", r.Diffs)
	}
}

func TestProbeMapIsListedAsApplied(t *testing.T) {
	b, c := modeRecs()
	w := newWorld(t, b, c)
	w.acc.ProbeMap = map[string]map[string]string{"mode": {"Nvl": "nvl", "Adv": "bottom"}}
	if r := w.run(t); len(r.Applied) != 2 {
		t.Fatalf("読み替えが承認済みの一覧に 2 行出ない: %v", r.Applied)
	}
}

func TestProbeMapAppliesToFallbackSeries(t *testing.T) {
	b, c := baseRec(), baseRec()
	delete(b.tape, "events")
	delete(c.tape, "events")
	b.tape["probes"] = map[string]any{"mode": []any{[]any{0, "Nvl"}, []any{3.0, "Adv"}}}
	c.tape["probes"] = map[string]any{"mode": []any{[]any{0, "nvl"}, []any{3.0, "bottom"}}}
	w := newWorld(t, b, c)
	w.acc.ProbeMap = map[string]map[string]string{"mode": {"Nvl": "nvl", "Adv": "bottom"}}
	if r := w.run(t); !r.Passed {
		t.Fatalf("値の移り変わりで probeMap が効かない: %+v", r.Diffs)
	}
}

func TestProbeMapAppliesToRestore(t *testing.T) {
	b := baseRec()
	c := b.clone()
	b.restore["probes"] = map[string]any{"mode": "Adv"}
	c.restore["probes"] = map[string]any{"mode": "bottom"}
	w := newWorld(t, b, c)
	w.acc.ProbeMap = map[string]map[string]string{"mode": {"Adv": "bottom"}}
	if r := w.run(t); !r.Passed {
		t.Fatalf("古いセーブの問いで probeMap が効かない: %+v", r.Diffs)
	}
}

func TestUnusedProbeMapIsListed(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	w.acc.ProbeMap = map[string]map[string]string{"mode": {"Nvl": "nvl"}}
	if r := w.run(t); len(r.Unused) != 1 {
		t.Fatalf("当たらない probeMap が使われていない承認に出ない: %v", r.Unused)
	}
}

// ---- -60 dB の境目 ----

func busRecs(a, b float64) (*rec, *rec) {
	x, y := baseRec(), baseRec()
	x.tape["buses"] = map[string]any{"bgm": []any{[]any{0, a}}}
	y.tape["buses"] = map[string]any{"bgm": []any{[]any{0, b}}}
	return x, y
}

func TestBusAroundSilentFloorPasses(t *testing.T) {
	x, y := busRecs(-61, -59)
	if d := diffsOf(newWorld(t, x, y).run(t), WhatBus); len(d) != 0 {
		t.Fatalf("-61 dB と -59 dB で違いが出た: %+v", d)
	}
}

func TestBusFromSilentFloorIsReview(t *testing.T) {
	x, y := busRecs(-60, -50)
	if d := diffsOf(newWorld(t, x, y).run(t), WhatBus); len(d) != 1 || !d[0].Review {
		t.Fatalf("-60 dB と -50 dB が迷った差にならない: %+v", d)
	}
}

func TestBusOnlyInNewIsReview(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["buses"].(map[string]any)["voice"] = []any{[]any{0, -3.0}}
	if d := diffsOf(newWorld(t, b, c).run(t), WhatBus); len(d) != 1 || !d[0].Review {
		t.Fatalf("新しい版にだけあるバスを知らせない: %+v", d)
	}
}

func TestBusEndFallsBackWithoutDuration(t *testing.T) {
	b := baseRec()
	delete(b.tape, "duration")
	c := b.clone()
	c.tape["buses"] = map[string]any{"bgm": []any{[]any{0, -6.0}, []any{4.0, -20.0}}}
	b.tape["buses"] = map[string]any{"bgm": []any{[]any{0, -6.0}, []any{4.0, -6.0}}}
	if d := diffsOf(newWorld(t, b, c).run(t), WhatBus); len(d) != 1 {
		t.Fatalf("duration の無い記録で終わりの方の音量を比べない: %+v", d)
	}
}

// ---- systematic は flow を省ける ----

func TestSystematicWithoutFlowCoversEveryFlow(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.frames["frames/mid.png"] = solid(100, 100, color.NRGBA{R: 100, G: 100, B: 118, A: 255})
	w := newWorld(t, b, c)
	b.writeFlow(t, w.base, "other", "design")
	c.writeFlow(t, w.cur, "other", "design")
	w.strict = true
	w.acc.Entries = []Entry{{ID: "s1", Kind: KindSystematic, What: WhatFrame, Command: "bg", Why: "ease の既定の差", Approved: true}}
	r := w.run(t)
	accepted := 0
	for _, d := range diffsOf(r, WhatFrame) {
		if d.Accepted == "s1" {
			accepted++
		}
	}
	if !r.Passed || accepted != 2 {
		t.Fatalf("flow を省いた systematic が 2 本の flow に当たらない: %d %v", accepted, r.Problems)
	}
}

func TestSystematicGroupsAcrossFlowsInPage(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.frames["frames/mid.png"] = solid(100, 100, color.NRGBA{R: 100, G: 100, B: 118, A: 255})
	w := newWorld(t, b, c)
	b.writeFlow(t, w.base, "other", "design")
	c.writeFlow(t, w.cur, "other", "design")
	w.acc.Entries = []Entry{{ID: "s1", Kind: KindSystematic, Flow: AnyFlow, What: WhatFrame, Command: "bg", Why: "ease の既定の差", Approved: true}}
	page, err := renderHTML(w.run(t), t.TempDir())
	if err != nil || strings.Count(string(page), "ease の既定の差") != 1 || !strings.Contains(string(page), "（2 件）") {
		t.Fatalf("系統の違いが 1 つの理由にまとまらない: %v", err)
	}
}

func TestIntendedWithoutFlowIsRejected(t *testing.T) {
	w := reviewWorld(t)
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, What: WhatFrame, Node: "Start", Seq: intp(0), Why: "x", Approved: true}}
	if r := w.run(t); r.Passed || len(r.Problems) != 1 {
		t.Fatalf("flow の無い intended を通した: %v", r.Problems)
	}
}

// ---- nobaseline は新しい版の絵を並べる ----

func nobaselineWorld(t *testing.T) *world {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	b.clone().writeFlow(t, w.cur, "route", "short")
	return w
}

func TestUnapprovedNoBaselineStops(t *testing.T) {
	if nobaselineWorld(t).run(t).Passed {
		t.Fatal("承認の無い nobaseline で止まらない")
	}
}

func TestNoBaselineCarriesNewFrames(t *testing.T) {
	d := diffsOf(nobaselineWorld(t).run(t), WhatNoBaseline)
	if len(d) != 1 || len(d[0].Images) != 2 {
		t.Fatalf("nobaseline に新しい版のコマ 2 枚が付かない: %+v", d)
	}
}

func TestApprovedNoBaselineStillShowsFrames(t *testing.T) {
	w := nobaselineWorld(t)
	w.acc.Entries = []Entry{{ID: "n1", Kind: KindNoBaseline, Flow: "route", Size: "short", Why: "前の版は撮れない", Approved: true}}
	page, _ := renderHTML(w.run(t), filepath.Dir(w.cur))
	if !strings.Contains(string(page), "new/flows/route/short/frames/done.png") {
		t.Fatal("承認済みの nobaseline の頁に新しい版のコマが無い")
	}
}

// ---- 同じノードへの入り直し ----

func revisitRecs(t *testing.T) (*rec, *rec) {
	b := baseRec()
	b.tape["events"] = append(events(b),
		map[string]any{"t": 5.0, "node": "Start", "kind": "line", "seq": 0, "who": "少女", "text": "はじめの台詞", "probes": map[string]any{"mood": "tense"}})
	b.tape["frames"] = []any{
		map[string]any{"file": "frames/v0.png", "t": 1.5, "node": "Start", "seq": 0, "kind": "lineDone", "layer": "world"},
		map[string]any{"file": "frames/v1.png", "t": 5.5, "node": "Start", "seq": 0, "kind": "lineDone", "layer": "world"},
	}
	b.frames = map[string]*image.NRGBA{"frames/v0.png": gradient(100, 100), "frames/v1.png": patchFrame(30)}
	c := b.clone()
	return b, c
}

func TestRevisitFramesPairByVisit(t *testing.T) {
	b, c := revisitRecs(t)
	r := newWorld(t, b, c).run(t)
	if len(diffsOf(r, WhatFrame)) != 0 || r.Frames != 2 {
		t.Fatalf("入り直したノードのコマが組にならない: frames=%d %+v", r.Frames, r.Diffs)
	}
}

func TestRevisitSwappedFramesDiffTwice(t *testing.T) {
	b, c := revisitRecs(t)
	c.frames["frames/v0.png"], c.frames["frames/v1.png"] = patchFrame(30), gradient(100, 100)
	if d := diffsOf(newWorld(t, b, c).run(t), WhatFrame); len(d) != 2 {
		t.Fatalf("1 回目と 2 回目を入れ替えたのに違いが 2 件でない: %+v", d)
	}
}

// 台詞の無い場面転換のノード（Fade）を 2 回通り、新しい版から 1 回目の途中のコマを消す。
func TestSilentNodeRevisitMissingFrameStops(t *testing.T) {
	b := baseRec()
	b.tape["frames"] = []any{
		map[string]any{"file": "frames/f0.png", "t": 2.5, "node": "Fade", "seq": -1, "kind": "mid", "cmd": "bg", "step": 0, "at": 0.5, "layer": "world"},
		map[string]any{"file": "frames/f1.png", "t": 4.5, "node": "Fade", "seq": -1, "kind": "mid", "cmd": "bg", "step": 0, "at": 0.5, "layer": "world"},
	}
	b.frames = map[string]*image.NRGBA{"frames/f0.png": gradient(100, 100), "frames/f1.png": gradient(100, 100)}
	c := b.clone()
	c.tape["frames"] = c.tape["frames"].([]any)[1:]
	if newWorld(t, b, c).run(t).Passed {
		t.Fatal("台詞の無いノードの 1 回目のコマを消しても通した")
	}
}

// 同じノードへ続けて入り直し（<<jump 自分>>）、新しい版から 1 回目のコマを消す。
func TestSelfLoopMissingFrameStops(t *testing.T) {
	b, c := revisitRecs(t)
	b.tape["events"] = []any{
		map[string]any{"t": 1.0, "node": "Start", "kind": "line", "seq": 0, "who": "少女", "text": "はじめの台詞", "probes": map[string]any{"mood": "calm"}},
		map[string]any{"t": 5.0, "node": "Start", "kind": "line", "seq": 0, "who": "少女", "text": "はじめの台詞", "probes": map[string]any{"mood": "calm"}},
	}
	delete(b.tape, "choices")
	c = b.clone()
	c.tape["frames"] = c.tape["frames"].([]any)[1:]
	if newWorld(t, b, c).run(t).Passed {
		t.Fatal("続けて入り直したノードの 1 回目のコマを消しても通した")
	}
}

func TestDuplicateFrameKeyAtSameTimeStops(t *testing.T) {
	b := baseRec()
	c := b.clone()
	frames := c.tape["frames"].([]any)
	c.tape["frames"] = append(frames, frames[0])
	r := newWorld(t, b, c).run(t)
	if r.Passed || len(diffsOf(r, WhatMissing)) != 1 {
		t.Fatalf("同じ鍵のコマが同じ時刻に 2 枚あっても止まらない: %+v", r.Diffs)
	}
}

// ---- 画面の物 ----

func TestObjectDiffCarriesPlace(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["objects"].([]any)[0].(map[string]any)["rect"].(map[string]any)["x"] = 0.2
	d := diffsOf(newWorld(t, b, c).run(t), WhatObject)
	if len(d) != 1 || d[0].Node != "Start" || d[0].Seq != 0 {
		t.Fatalf("画面の物の差に台詞の場所が付かない: %+v", d)
	}
}

func TestObjectEntryByLineApplies(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["objects"].([]any)[0].(map[string]any)["rect"].(map[string]any)["x"] = 0.2
	w := newWorld(t, b, c)
	w.strict = true
	w.acc.Entries = []Entry{{ID: "o1", Kind: KindIntended, Flow: "route", What: WhatObject, Node: "Start", Seq: intp(0), Why: "枠を右へ", Approved: true}}
	if r := w.run(t); !r.Passed {
		t.Fatalf("node と seq の object の承認が当たらない: %+v", r.Diffs)
	}
}

func TestIDMapPasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["objects"].([]any)[0].(map[string]any)["id"] = "window"
	w := newWorld(t, b, c)
	w.acc.IDMap = map[string]string{"message": "window"}
	if d := diffsOf(w.run(t), WhatObject); len(d) != 0 {
		t.Fatalf("idMap で読み替えても違いが出た: %+v", d)
	}
}

func TestRectFreeSkipsRect(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["objects"].([]any)[0].(map[string]any)["rect"].(map[string]any)["x"] = 0.4
	w := newWorld(t, b, c)
	w.acc.RectFree = []string{"message"}
	if d := diffsOf(w.run(t), WhatObject); len(d) != 0 {
		t.Fatalf("rectFree の id の矩形を比べた: %+v", d)
	}
}

func TestObjectCountDiffIsReview(t *testing.T) {
	b := baseRec()
	c := b.clone()
	objs := c.tape["objects"].([]any)
	c.tape["objects"] = append(objs, objs[0])
	d := diffsOf(newWorld(t, b, c).run(t), WhatObject)
	if len(d) != 1 || !d[0].Review {
		t.Fatalf("出た回数の違いが迷った差にならない: %+v", d)
	}
}

// ---- 音の組 ----

func TestSoundsMovedIntoSameFramePass(t *testing.T) {
	b := baseRec()
	b.tape["sounds"] = []any{
		map[string]any{"t": 10.0 / 30, "name": "se_z", "kind": "se", "label": "z"},
		map[string]any{"t": 11.0 / 30, "name": "se_a", "kind": "se", "label": "a"},
	}
	c := b.clone()
	c.tape["sounds"] = []any{
		map[string]any{"t": 11.0 / 30, "name": "se_a", "kind": "se", "label": "a"},
		map[string]any{"t": 11.0 / 30, "name": "se_z", "kind": "se", "label": "z"},
	}
	if d := diffsOf(newWorld(t, b, c).run(t), WhatSound); len(d) != 0 {
		t.Fatalf("1 フレームずれて同じフレームに入った音で止まった: %+v", d)
	}
}

func TestExtraSoundInNewStops(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"] = append(c.tape["sounds"].([]any), map[string]any{"t": 5.0, "name": "se_x", "kind": "se", "label": "x"})
	if newWorld(t, b, c).run(t).Passed {
		t.Fatal("新しい版にだけある音で止まらない")
	}
}

// ---- 音の並べ直し ----

func TestSameFrameSoundsInOtherOrderPass(t *testing.T) {
	b := baseRec()
	b.tape["sounds"] = append(b.tape["sounds"].([]any), map[string]any{"t": 2.0, "name": "se_a", "kind": "se", "label": "a"})
	c := b.clone()
	s := c.tape["sounds"].([]any)
	s[1], s[2] = s[2], s[1]
	if d := diffsOf(newWorld(t, b, c).run(t), WhatSound); len(d) != 0 {
		t.Fatalf("同じフレームの音の順の違いで止まった: %+v", d)
	}
}

// ---- コマ ----

func TestMidOverlayDarkerOnSmoothBackgroundIsReview(t *testing.T) {
	b := baseRec()
	b.frames["frames/mid.png"] = gradient(100, 100)
	c := b.clone()
	img := c.frames["frames/mid.png"]
	for i := 0; i < len(img.Pix); i += 4 {
		for k := 0; k < 3; k++ {
			img.Pix[i+k] = uint8(max(int(img.Pix[i+k])-4, 0))
		}
	}
	if d := diffsOf(newWorld(t, b, c).run(t), WhatFrame); len(d) != 1 {
		t.Fatalf("なめらかな背景で overlay の濃さの差が隠れた: %+v", d)
	}
}

func TestFrameSizeMismatchStops(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.frames["frames/done.png"] = gradient(100, 90)
	r := newWorld(t, b, c).run(t)
	if r.Passed {
		t.Fatal("大きさの違うコマで止まらない")
	}
}

func TestMissingDoneFrameCannotBeApproved(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["frames"] = c.tape["frames"].([]any)[1:]
	w := newWorld(t, b, c)
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, Flow: "route", What: WhatFrame, Node: "Start", Seq: intp(0), Why: "x", Approved: true}}
	r := w.run(t)
	if r.Passed || len(diffsOf(r, WhatMissing)) != 1 {
		t.Fatalf("撮っていない演出の後のコマを承認で通した: %+v", r.Diffs)
	}
}

func TestMissingMidFrameStopsWithoutEntry(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["frames"] = c.tape["frames"].([]any)[:1]
	r := newWorld(t, b, c).run(t)
	d := diffsOf(r, WhatFrame)
	if r.Passed || len(d) != 1 || d[0].Review {
		t.Fatalf("撮っていない途中のコマが止める差にならない: %+v", r.Diffs)
	}
}

func TestMissingMidFrameCanBeApproved(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["frames"] = c.tape["frames"].([]any)[:1]
	w := newWorld(t, b, c)
	from, to := 0.0, 1.0
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, Flow: "route", What: WhatFrame, From: &from, To: &to, Why: "bg の 2 つの命令を 1 つにまとめた", Approved: true}}
	if r := w.run(t); !r.Passed {
		t.Fatalf("承認した撮っていない途中のコマで落ちた: %+v", r.Diffs)
	}
}

func TestMissingMidFrameIsNotSystematic(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["frames"] = c.tape["frames"].([]any)[:1]
	w := newWorld(t, b, c)
	w.acc.Entries = []Entry{{ID: "s1", Kind: KindSystematic, What: WhatFrame, Command: "bg", Why: "ease", Approved: true}}
	if w.run(t).Passed {
		t.Fatal("撮っていない途中のコマを系統の違いで通した")
	}
}

func TestTwoSizesAreComparedSeparately(t *testing.T) {
	b := baseRec()
	c := b.clone()
	w := newWorld(t, b, c)
	b.writeFlow(t, w.base, "route", "tall")
	c2 := b.clone()
	c2.tape["sounds"] = c2.tape["sounds"].([]any)[:1]
	c2.writeFlow(t, w.cur, "route", "tall")
	r := w.run(t)
	d := diffsOf(r, WhatSound)
	if len(d) != 1 || d[0].Size != "tall" {
		t.Fatalf("大きさごとに比べていない: %+v", d)
	}
}

// ---- 古いセーブ ----

func restoreFrameRecs() (*rec, *rec) {
	b := baseRec()
	b.restore["frames"] = []any{map[string]any{"file": "r.png", "node": "Start", "seq": 1, "kind": "lineDone", "layer": "world"}}
	b.restore["objects"] = []any{map[string]any{"id": "message", "from": 0, "to": 1, "rect": map[string]any{"x": 0.1, "y": 0.5, "w": 0.8, "h": 0.2}}}
	c := b.clone()
	return b, c
}

func writeRestorePNG(t *testing.T, root string, img *image.NRGBA) {
	t.Helper()
	if err := writePNG(filepath.Join(root, SavesDir, "quick1", "r.png"), img); err != nil {
		t.Fatal(err)
	}
}

func TestRestoreFrameAndObjectDiffsAreReview(t *testing.T) {
	b, c := restoreFrameRecs()
	c.restore["objects"].([]any)[0].(map[string]any)["rect"].(map[string]any)["x"] = 0.3
	w := newWorld(t, b, c)
	writeRestorePNG(t, w.base, gradient(100, 100))
	writeRestorePNG(t, w.cur, patchFrame(10))
	r := w.run(t)
	review := 0
	for _, d := range r.Diffs {
		if d.Step == 6 && d.Review {
			review++
		}
	}
	if !r.Passed || review != 2 {
		t.Fatalf("古いセーブのコマと画面の物が迷った差 2 件にならない: %d %+v", review, r.Diffs)
	}
}

func TestRestoreRefusalIsListedAsApplied(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.restore = map[string]any{"save": "quick1.json", "refused": true}
	w := newWorld(t, b, c)
	w.acc.Restore = map[string]string{"quick1": "refused"}
	if r := w.run(t); len(r.Applied) != 1 {
		t.Fatalf("読まない決めが承認済みの一覧に出ない: %v", r.Applied)
	}
}

// ---- 承認の後始末 ----

func TestUnusedEntryIsListed(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, Flow: "route", What: WhatFrame, Node: "Start", Seq: intp(0), Why: "x", Approved: true}}
	if r := w.run(t); len(r.Unused) != 1 {
		t.Fatalf("どの差にも当たらない承認が出ない: %v", r.Unused)
	}
}

func TestCoverageEntryOnCoveredLineIsUnused(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	w.acc.Coverage = []CoverageEntry{{Yarn: "assets/talk/story.yarn", Line: 3, Why: "x", Approved: true}}
	if r := w.run(t); len(r.Unused) != 1 {
		t.Fatalf("通る行の coverage の承認が出ない: %v", r.Unused)
	}
}

func TestCoverageEntryWithoutWhyIsProblem(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["ranLines"] = []any{3, 4, 5, 7, 14}
	w := newWorld(t, b, c)
	w.acc.Coverage = []CoverageEntry{{Yarn: "assets/talk/story.yarn", Line: 9, Approved: true}}
	if r := w.run(t); r.Passed || len(r.Problems) != 1 {
		t.Fatalf("why の無い coverage の承認を通した: %v", r.Problems)
	}
}

func TestEntryImagesAreResolvedAndMissingNoted(t *testing.T) {
	w := reviewWorld(t)
	w.acc.dir = filepath.Dir(w.cur)
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, Flow: "route", What: WhatFrame, Node: "Start", Seq: intp(0), Why: "背景を替えた", Approved: true,
		Images: []string{"new/flows/route/design/frames/done.png", "nothing.png"}}}
	r := w.run(t)
	d := diffsOf(r, WhatFrame)
	if len(d) != 1 || len(d[0].EntryImages) != 1 || len(r.Notes) == 0 || !strings.Contains(strings.Join(r.Notes, "\n"), "nothing.png") {
		t.Fatalf("承認の絵が引けないか、無い絵を知らせない: %+v %v", d, r.Notes)
	}
}

func TestNoRanLinesAddsNote(t *testing.T) {
	b := baseRec()
	delete(b.tape, "ranLines")
	r := newWorld(t, b, b.clone()).run(t)
	if !strings.Contains(strings.Join(r.Notes, "\n"), "ranLines の無い記録") {
		t.Fatalf("ranLines の無い時の注意が出ない: %v", r.Notes)
	}
}

func TestStaleHeatIsRemoved(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	out := t.TempDir()
	stale := filepath.Join(out, "heat", "old.png")
	if err := os.MkdirAll(filepath.Dir(stale), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stale, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	bs, _ := LoadSide(w.base)
	cs, _ := LoadSide(w.cur)
	Compare(bs, cs, w.acc, Options{Out: out, Game: w.game, Th: DefaultThresholds(), Lim: DefaultLimits()})
	if fileExists(stale) {
		t.Fatal("前の回の差の色の図が残った")
	}
}

// ---- 横並びの動画 ----

func makeClip(t *testing.T, ff, path, col string, seconds string, audio bool) string {
	t.Helper()
	args := []string{"-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=" + col + ":s=64x96:d=" + seconds}
	if audio {
		args = append(args, "-f", "lavfi", "-i", "sine=d="+seconds, "-c:a", "aac")
	}
	args = append(args, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-shortest", path)
	if msg, err := exec.Command(ff, args...).CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, msg)
	}
	return path
}

func clipSeconds(t *testing.T, ff, path string) float64 {
	t.Helper()
	info, err := probeClip(ffprobePath(ff), path)
	if err != nil {
		t.Fatal(err)
	}
	return info.seconds
}

func TestSideBySideKeepsLongerClipWithoutAudio(t *testing.T) {
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg が無い")
	}
	dir := t.TempDir()
	old := makeClip(t, ff, filepath.Join(dir, "old.mp4"), "red", "1", true)
	cur := makeClip(t, ff, filepath.Join(dir, "new.mp4"), "blue", "2", false)
	out := filepath.Join(dir, "sbs.mp4")
	if err := SideBySide(old, cur, out, "", ff); err != nil {
		t.Fatal(err)
	}
	if s := clipSeconds(t, ff, out); s < 1.9 {
		t.Fatalf("短い方で切られた（%.2f 秒）", s)
	}
}

func TestVideoExitTwoWithoutInput(t *testing.T) {
	dir := t.TempDir()
	if code, _ := runCLI("video", "--old", filepath.Join(dir, "a.mp4"), "--new", filepath.Join(dir, "b.mp4"), "--out", filepath.Join(dir, "c.mp4")); code != 2 {
		t.Fatalf("動画が無い時の終わりの番号 %d（2 のはず）", code)
	}
}

func TestSubtitleEndIsAfterStartWithoutDuration(t *testing.T) {
	b := baseRec()
	delete(b.tape, "duration")
	dir := t.TempDir()
	b.writeFlow(t, dir, "route", "design")
	srt := filepath.Join(dir, "x.srt")
	if err := writeSubtitles(filepath.Join(dir, FlowsDir, "route", "design", TapeFile), srt); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(srt)
	if !strings.Contains(string(data), "00:00:04,000 --> 00:00:06,000") {
		t.Fatalf("最後の字幕の終わりが始まりより後にならない:\n%s", data)
	}
}
