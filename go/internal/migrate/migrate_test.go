package migrate

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// ---- 記録を組む ----

const yarnText = `title: Start
---
<<bg room>>
少女: はじめの台詞
<<audio se se_bell>>
-> 行く
    <<jump Go>>
-> 待つ
    <<wait 1>>
少女: 次の台詞
===
title: Go
---
少女: 行った先
===
`

// Yarn の行番号: 3 bg・4 台詞・5 audio・7 jump・9 wait・10 台詞・14 行った先。
var allCmdLines = []int{3, 5, 7, 9}

type rec struct {
	tape    map[string]any
	frames  map[string]*image.NRGBA // ファイル名 → 絵
	restore map[string]any
}

func intp(n int) *int { return &n }

func gradient(w, h int) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetNRGBA(x, y, color.NRGBA{R: uint8(x * 2), G: uint8(y * 2), B: 40, A: 255})
		}
	}
	return img
}

func solid(w, h int, c color.NRGBA) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for i := 0; i < w*h; i++ {
		img.SetNRGBA(i%w, i/w, c)
	}
	return img
}

func baseRec() *rec {
	return &rec{
		tape: map[string]any{
			"fps": 30, "duration": 6.0, "yarn": "assets/talk/story.yarn",
			"lines": map[string]any{
				"3": map[string]any{"cmd": "<<bg room>>", "node": "Start"},
				"4": map[string]any{"who": "少女", "text": "はじめの台詞", "node": "Start"},
				"5": map[string]any{"cmd": "<<audio se se_bell>>", "node": "Start"},
			},
			"timeline": []any{[]any{0, nil}, []any{1.0, 4}},
			"sounds": []any{
				map[string]any{"t": 0.0, "name": "amb_room", "kind": "ambience", "label": "部屋"},
				map[string]any{"t": 2.0, "name": "se_bell", "kind": "se", "label": "鈴"},
			},
			"objects": []any{
				map[string]any{"id": "message", "name": "枠", "from": 1.0, "to": 6.0, "rect": map[string]any{"x": 0.1, "y": 0.5, "w": 0.8, "h": 0.2}},
			},
			"probes":  map[string]any{"mood": []any{[]any{0, "calm"}, []any{3.0, "tense"}}},
			"choices": []any{map[string]any{"t": 3.0, "line": 6, "node": "Start", "options": []any{"行く", "待つ"}, "picked": 0}},
			"screen":  map[string]any{"w": 100, "h": 100},
			"events": []any{
				map[string]any{"t": 1.0, "node": "Start", "kind": "line", "seq": 0, "who": "少女", "text": "はじめの台詞", "probes": map[string]any{"mood": "calm"}},
				map[string]any{"t": 3.0, "node": "Start", "kind": "choice", "seq": 1, "options": []any{"行く", "待つ"}, "picked": 0},
				map[string]any{"t": 4.0, "node": "Go", "kind": "line", "seq": 0, "who": "少女", "text": "行った先", "probes": map[string]any{"mood": "tense"}},
			},
			"buses": map[string]any{"bgm": []any{[]any{0, -6.0}, []any{5.0, nil}}},
			"frames": []any{
				map[string]any{"file": "frames/done.png", "t": 1.5, "node": "Start", "seq": 0, "kind": "lineDone", "layer": "world"},
				map[string]any{"file": "frames/mid.png", "t": 0.5, "node": "Start", "seq": -1, "kind": "mid", "cmd": "bg", "step": 0, "at": 0.5, "layer": "world"},
			},
			"ranLines": []any{3, 4, 5, 7, 9, 14},
		},
		frames: map[string]*image.NRGBA{
			"frames/done.png": gradient(100, 100),
			"frames/mid.png":  solid(100, 100, color.NRGBA{R: 100, G: 100, B: 100, A: 255}),
		},
		restore: map[string]any{"save": "quick1.json", "node": "Start", "seq": 1, "probes": map[string]any{"mood": "calm"}},
	}
}

// clone は JSON で写して、片方だけを変えられるようにする。
func (r *rec) clone() *rec {
	var b []byte
	b, _ = json.Marshal(r.tape)
	out := &rec{frames: map[string]*image.NRGBA{}}
	_ = json.Unmarshal(b, &out.tape)
	b, _ = json.Marshal(r.restore)
	_ = json.Unmarshal(b, &out.restore)
	for k, v := range r.frames {
		cp := image.NewNRGBA(v.Rect)
		copy(cp.Pix, v.Pix)
		out.frames[k] = cp
	}
	return out
}

func (r *rec) write(t *testing.T, root string) {
	t.Helper()
	r.writeFlow(t, root, "route", "design")
	if r.restore != nil {
		writeJSON(t, filepath.Join(root, SavesDir, "quick1", RestoreFile), r.restore)
	}
}

// writeFlow は tape.json とコマだけを flows/<flow>/<size> に書く。
func (r *rec) writeFlow(t *testing.T, root, flow, size string) {
	t.Helper()
	dir := filepath.Join(root, FlowsDir, flow, size)
	writeJSON(t, filepath.Join(dir, TapeFile), r.tape)
	for name, img := range r.frames {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := writePNG(p, img); err != nil {
			t.Fatal(err)
		}
	}
}

func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(v)
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

type world struct {
	game, base, cur string
	acc             *Accept
	strict          bool
}

func newWorld(t *testing.T, base, cur *rec) *world {
	t.Helper()
	game := t.TempDir()
	if err := os.MkdirAll(filepath.Join(game, "assets", "talk"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(game, "assets", "talk", "story.yarn"), []byte(yarnText), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(game, "project.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	w := &world{game: game, base: filepath.Join(game, "debug", "migrate", "baseline"), cur: filepath.Join(game, "debug", "migrate", "new"), acc: &Accept{}}
	base.write(t, w.base)
	cur.write(t, w.cur)
	return w
}

func (w *world) run(t *testing.T) *Result {
	t.Helper()
	a, err := LoadSide(w.base)
	if err != nil {
		t.Fatal(err)
	}
	b, err := LoadSide(w.cur)
	if err != nil {
		t.Fatal(err)
	}
	return Compare(a, b, w.acc, Options{Game: w.game, Strict: w.strict, Th: DefaultThresholds(), Lim: DefaultLimits()})
}

func diffsOf(r *Result, what string) []*Diff {
	var out []*Diff
	for _, d := range r.Diffs {
		if d.What == what {
			out = append(out, d)
		}
	}
	return out
}

func setWhite(img *image.NRGBA, x0, y0, w, h int) {
	for y := y0; y < y0+h; y++ {
		for x := x0; x < x0+w; x++ {
			img.SetNRGBA(x, y, color.NRGBA{R: 255, G: 255, B: 255, A: 255})
		}
	}
}

// patchFrame は無地の上に、横に 1 px で 4 段ずつ変わる 30×30 の模様を x0 に置いた絵（ずれた量が色の差で分かる）。
func patchFrame(x0 int) *image.NRGBA {
	img := solid(100, 100, color.NRGBA{R: 20, G: 30, B: 40, A: 255})
	for y := 30; y < 60; y++ {
		for x := 0; x < 30; x++ {
			img.SetNRGBA(x0+x, y, color.NRGBA{R: uint8(100 + x*4), G: 200, B: 90, A: 255})
		}
	}
	return img
}

func shifted(img *image.NRGBA, dx int) *image.NRGBA {
	w, h := img.Rect.Dx(), img.Rect.Dy()
	out := image.NewNRGBA(img.Rect)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			sx := min(max(x-dx, 0), w-1)
			out.SetNRGBA(x, y, img.NRGBAAt(sx, y))
		}
	}
	return out
}

func events(r *rec) []any { return r.tape["events"].([]any) }

// ---- 同じ記録で通る ----

func TestSameRecordPasses(t *testing.T) {
	b := baseRec()
	r := newWorld(t, b, b.clone()).run(t)
	if !r.Passed || len(r.Diffs) != 0 {
		t.Fatalf("同じ記録で違いが出た: %+v", r.Diffs)
	}
}

func TestSameRecordComparesFrames(t *testing.T) {
	b := baseRec()
	r := newWorld(t, b, b.clone()).run(t)
	if r.Frames != 2 {
		t.Fatalf("比べたコマ %d 枚（2 枚のはず）", r.Frames)
	}
}

// ---- わざと入れた差で止まる ----

func TestChangedPickStopsAtEvents(t *testing.T) {
	b := baseRec()
	c := b.clone()
	events(c)[1].(map[string]any)["picked"] = 1
	r := newWorld(t, b, c).run(t)
	if r.Passed || len(diffsOf(r, WhatEvent)) != 1 {
		t.Fatalf("選んだ選択肢を替えて止まらない: %+v", r.Diffs)
	}
}

func TestEventMismatchSkipsLaterSteps(t *testing.T) {
	b := baseRec()
	c := b.clone()
	events(c)[0].(map[string]any)["text"] = "書き換えた台詞"
	c.frames["frames/done.png"] = solid(100, 100, color.NRGBA{A: 255})
	r := newWorld(t, b, c).run(t)
	if len(r.Stopped) != 1 || len(diffsOf(r, WhatFrame)) != 0 {
		t.Fatalf("出来事の並びが違うのに後ろを比べた: stopped=%v diffs=%+v", r.Stopped, r.Diffs)
	}
}

func TestAddedWaitStopsAtEvents(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["events"] = append(events(c), map[string]any{"t": 5.0, "node": "Go", "kind": "wait", "seq": 1, "seconds": 1.0})
	r := newWorld(t, b, c).run(t)
	if r.Passed {
		t.Fatal("待ちを足して止まらない")
	}
}

func TestRemovedSoundStops(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"] = c.tape["sounds"].([]any)[:1]
	r := newWorld(t, b, c).run(t)
	if r.Passed || len(diffsOf(r, WhatSound)) != 1 {
		t.Fatalf("効果音を消して止まらない: %+v", r.Diffs)
	}
}

func TestChangedProbeOnLineStops(t *testing.T) {
	b := baseRec()
	c := b.clone()
	events(c)[2].(map[string]any)["probes"] = map[string]any{"mood": "calm"}
	r := newWorld(t, b, c).run(t)
	if r.Passed || len(diffsOf(r, WhatProbe)) != 1 {
		t.Fatalf("台詞の後の問いを替えて止まらない: %+v", r.Diffs)
	}
}

func TestMissingFlowStops(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	if err := os.Rename(filepath.Join(w.cur, FlowsDir, "route", "design"), filepath.Join(w.cur, FlowsDir, "route", "tall")); err != nil {
		t.Fatal(err)
	}
	r := w.run(t)
	if r.Passed || len(diffsOf(r, WhatMissing)) != 1 || len(diffsOf(r, WhatNoBaseline)) != 1 {
		t.Fatalf("撮っていない大きさで止まらない: %+v", r.Diffs)
	}
}

// ---- 迷った差は止めない（--strict なら止める） ----

func TestShiftedSoundIsReviewOnly(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"].([]any)[1].(map[string]any)["t"] = 2.1
	r := newWorld(t, b, c).run(t)
	d := diffsOf(r, WhatSound)
	if !r.Passed || len(d) != 1 || !d[0].Review {
		t.Fatalf("音の時刻のずれは迷った差のはず: passed=%v %+v", r.Passed, d)
	}
}

func TestShiftedSoundFailsWhenStrict(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"].([]any)[1].(map[string]any)["t"] = 2.1
	w := newWorld(t, b, c)
	w.strict = true
	if w.run(t).Passed {
		t.Fatal("--strict で迷った差が止めない")
	}
}

func TestSoundWithinOneFramePasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"].([]any)[1].(map[string]any)["t"] = 2.0 + 1.0/30
	r := newWorld(t, b, c).run(t)
	if len(diffsOf(r, WhatSound)) != 0 {
		t.Fatalf("1 フレームのずれで違いが出た: %+v", r.Diffs)
	}
}

// ---- コマの境目 ----

func TestDoneFrameWith50ChangedPixelsPasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	setWhite(c.frames["frames/done.png"], 10, 10, 5, 10)
	r := newWorld(t, b, c).run(t)
	if len(diffsOf(r, WhatFrame)) != 0 {
		t.Fatalf("0.5%% の画素の差で違いが出た: %+v", r.Diffs)
	}
}

func TestDoneFrameWith51ChangedPixelsIsReview(t *testing.T) {
	b := baseRec()
	c := b.clone()
	setWhite(c.frames["frames/done.png"], 10, 10, 5, 10)
	setWhite(c.frames["frames/done.png"], 60, 60, 1, 1)
	d := diffsOf(newWorld(t, b, c).run(t), WhatFrame)
	if len(d) != 1 || !d[0].Review {
		t.Fatalf("0.51%% の画素の差が迷った差にならない: %+v", d)
	}
}

func TestDoneFrameShiftedTwoPixelsPasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	b.frames["frames/done.png"] = patchFrame(30)
	c.frames["frames/done.png"] = patchFrame(32)
	r := newWorld(t, b, c).run(t)
	if len(diffsOf(r, WhatFrame)) != 0 {
		t.Fatalf("2 px のずれで違いが出た: %+v", r.Diffs)
	}
}

func TestDoneFrameShiftedThreePixelsIsReview(t *testing.T) {
	b := baseRec()
	c := b.clone()
	b.frames["frames/done.png"] = patchFrame(30)
	c.frames["frames/done.png"] = patchFrame(33)
	if len(diffsOf(newWorld(t, b, c).run(t), WhatFrame)) != 1 {
		t.Fatal("3 px のずれで違いが出ない")
	}
}

func TestMidFrameMeanAtLimitPasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.frames["frames/mid.png"] = solid(100, 100, color.NRGBA{R: 103, G: 103, B: 103, A: 255})
	if d := diffsOf(newWorld(t, b, c).run(t), WhatFrame); len(d) != 0 {
		t.Fatalf("差の平均 3/255 で違いが出た: %+v", d)
	}
}

func TestMidFrameMeanOverLimitIsReview(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.frames["frames/mid.png"] = solid(100, 100, color.NRGBA{R: 103, G: 103, B: 104, A: 255})
	if d := diffsOf(newWorld(t, b, c).run(t), WhatFrame); len(d) != 1 {
		t.Fatalf("差の平均 3.33/255 で違いが出ない: %+v", d)
	}
}

func TestMissingNewFrameStops(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["frames"] = c.tape["frames"].([]any)[:1]
	r := newWorld(t, b, c).run(t)
	if r.Passed {
		t.Fatal("撮っていないコマで止まらない")
	}
}

func TestFailingFrameWritesHeat(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.frames["frames/done.png"] = shifted(b.frames["frames/done.png"], 5)
	w := newWorld(t, b, c)
	bs, _ := LoadSide(w.base)
	cs, _ := LoadSide(w.cur)
	out := t.TempDir()
	r := Compare(bs, cs, w.acc, Options{Out: out, Game: w.game, Th: DefaultThresholds(), Lim: DefaultLimits()})
	d := diffsOf(r, WhatFrame)
	if len(d) != 1 || !fileExists(d[0].Heat) {
		t.Fatalf("差の色の図が無い: %+v", d)
	}
}

// ---- 矩形と音量の境目 ----

func TestRectShiftedTwoPixelsPasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["objects"].([]any)[0].(map[string]any)["rect"].(map[string]any)["x"] = 0.12
	if d := diffsOf(newWorld(t, b, c).run(t), WhatObject); len(d) != 0 {
		t.Fatalf("2 px のずれで違いが出た: %+v", d)
	}
}

func TestRectShiftedThreePixelsIsReview(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["objects"].([]any)[0].(map[string]any)["rect"].(map[string]any)["x"] = 0.13
	d := diffsOf(newWorld(t, b, c).run(t), WhatObject)
	if len(d) != 1 || !d[0].Review {
		t.Fatalf("3 px のずれが迷った差にならない: %+v", d)
	}
}

func TestBusWithinOneDBPasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["buses"] = map[string]any{"bgm": []any{[]any{0, -7.0}, []any{5.0, nil}}}
	if d := diffsOf(newWorld(t, b, c).run(t), WhatBus); len(d) != 0 {
		t.Fatalf("1 dB の差で違いが出た: %+v", d)
	}
}

func TestBusOverOneDBIsReview(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["buses"] = map[string]any{"bgm": []any{[]any{0, -7.5}, []any{5.0, nil}}}
	d := diffsOf(newWorld(t, b, c).run(t), WhatBus)
	if len(d) != 1 || !d[0].Review {
		t.Fatalf("1.5 dB の差がひとまとまりの迷った差にならない: %+v", d)
	}
}

// ---- 欄が無い記録 ----

func TestRecordWithoutNewFieldsPassesWithSkips(t *testing.T) {
	b := baseRec()
	for _, k := range []string{"events", "buses", "frames", "ranLines", "screen"} {
		delete(b.tape, k)
	}
	b.frames = nil
	b.restore = nil
	lines := b.tape["lines"].(map[string]any)
	lines["7"] = map[string]any{"cmd": "<<jump Go>>", "node": "Start"}
	lines["9"] = map[string]any{"cmd": "<<wait 1>>", "node": "Start"}
	r := newWorld(t, b, b.clone()).run(t)
	if !r.Passed || len(r.Skips) < 4 {
		t.Fatalf("欄の無い記録で落ちたか、比べていない物が出ない: passed=%v skips=%+v problems=%v", r.Passed, r.Skips, r.Problems)
	}
}

func TestTimelineFallbackStillCatchesTextChange(t *testing.T) {
	b := baseRec()
	delete(b.tape, "events")
	c := b.clone()
	c.tape["lines"].(map[string]any)["4"].(map[string]any)["text"] = "違う台詞"
	if newWorld(t, b, c).run(t).Passed {
		t.Fatal("events の無い記録で台詞の字の違いを見逃した")
	}
}

// ---- カバー率 ----

func TestUncoveredCommandStops(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["ranLines"] = []any{3, 4, 5, 7, 14}
	r := newWorld(t, b, c).run(t)
	if r.Passed || len(r.Uncovered) != 1 || r.Uncovered[0].Line != 9 {
		t.Fatalf("通らない <<wait 1>> の行で止まらない: %+v", r.Uncovered)
	}
}

func TestApprovedCoverageEntryPasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["ranLines"] = []any{3, 4, 5, 7, 14}
	w := newWorld(t, b, c)
	w.acc.Coverage = []CoverageEntry{{Yarn: "assets/talk/story.yarn", Line: 9, Why: "待つ道は flow を足さない", Approved: true}}
	if r := w.run(t); !r.Passed {
		t.Fatalf("承認した行で落ちた: %+v", r.Uncovered)
	}
}

func TestCoverageCountsEveryCommandLine(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["ranLines"] = []any{}
	r := newWorld(t, b, c).run(t)
	if len(r.Uncovered) != len(allCmdLines) {
		t.Fatalf("命令の行 %d 行のはずが %d 行: %+v", len(allCmdLines), len(r.Uncovered), r.Uncovered)
	}
}

func TestMissingGameRootIsProblem(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	w.game = ""
	if w.run(t).Passed {
		t.Fatal("ゲームのルートが無いのにカバー率を黙って外した")
	}
}

// ---- 承認 ----

func reviewWorld(t *testing.T) *world {
	b := baseRec()
	c := b.clone()
	c.frames["frames/done.png"] = shifted(b.frames["frames/done.png"], 5)
	w := newWorld(t, b, c)
	w.strict = true
	return w
}

func TestApprovedEntryClearsDiff(t *testing.T) {
	w := reviewWorld(t)
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, Flow: "route", What: WhatFrame, Node: "Start", Seq: intp(0), Why: "背景を替えた", Approved: true}}
	if r := w.run(t); !r.Passed {
		t.Fatalf("承認した差で落ちた: %+v", r.Diffs)
	}
}

func TestUnapprovedEntryIsPending(t *testing.T) {
	w := reviewWorld(t)
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, Flow: "route", What: WhatFrame, Node: "Start", Seq: intp(0), Why: "背景を替えた"}}
	r := w.run(t)
	if r.Passed || !diffsOf(r, WhatFrame)[0].Pending {
		t.Fatalf("approved の無い件が承認待ちにならない: %+v", r.Diffs)
	}
}

func TestRangeOverThreeSecondsIsRejected(t *testing.T) {
	w := reviewWorld(t)
	from, to := 0.0, 3.5
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, Flow: "route", What: WhatFrame, From: &from, To: &to, Why: "広すぎる", Approved: true}}
	r := w.run(t)
	if r.Passed || len(r.Problems) != 1 {
		t.Fatalf("3 秒を超える範囲を通した: %v", r.Problems)
	}
}

func TestEventDiffCannotBeApproved(t *testing.T) {
	b := baseRec()
	c := b.clone()
	events(c)[1].(map[string]any)["picked"] = 1
	w := newWorld(t, b, c)
	w.acc.Entries = []Entry{{ID: "a1", Kind: KindIntended, Flow: "route", What: WhatEvent, Node: "Start", Seq: intp(1), Why: "通したい", Approved: true}}
	if w.run(t).Passed {
		t.Fatal("出来事の並びの違いを承認で通した")
	}
}

func TestMoreThanTwentyWhysPerFlowIsRejected(t *testing.T) {
	w := reviewWorld(t)
	for i := 0; i < 21; i++ {
		w.acc.Entries = append(w.acc.Entries, Entry{Kind: KindIntended, Flow: "route", What: WhatFrame, Node: "Start", Seq: intp(0), Why: strings.Repeat("x", i+1), Approved: true})
	}
	r := w.run(t)
	if r.Passed || !strings.Contains(strings.Join(r.Problems, "\n"), "承認の上限") {
		t.Fatalf("21 件の理由を通した: %v", r.Problems)
	}
}

func TestSameWhyCountsOnce(t *testing.T) {
	w := reviewWorld(t)
	for i := 0; i < 25; i++ {
		w.acc.Entries = append(w.acc.Entries, Entry{Kind: KindIntended, Flow: "route", What: WhatFrame, Node: "Start", Seq: intp(0), Why: "同じ理由", Approved: true})
	}
	if r := w.run(t); !r.Passed {
		t.Fatalf("同じ理由の 25 件を上限で落とした: %v", r.Problems)
	}
}

func systematicWorld(t *testing.T, blue uint8) *world {
	b := baseRec()
	c := b.clone()
	c.frames["frames/mid.png"] = solid(100, 100, color.NRGBA{R: 100, G: 100, B: blue, A: 255})
	w := newWorld(t, b, c)
	w.strict = true
	w.acc.Entries = []Entry{{ID: "s1", Kind: KindSystematic, Flow: "route", What: WhatFrame, Command: "bg", Why: "ease の既定の差", Approved: true}}
	return w
}

func TestSystematicPassesSmallMidDiff(t *testing.T) {
	if r := systematicWorld(t, 118).run(t); !r.Passed {
		t.Fatalf("差の平均 6/255 の途中のコマを systematic で通せない: %+v", r.Diffs)
	}
}

func TestSystematicRejectsLargeMidDiff(t *testing.T) {
	if systematicWorld(t, 119).run(t).Passed {
		t.Fatal("差の平均 6.33/255 を systematic で通した")
	}
}

func TestSystematicNeedsCommand(t *testing.T) {
	w := systematicWorld(t, 118)
	w.acc.Entries[0].Command = ""
	if w.run(t).Passed {
		t.Fatal("命令を名指ししない systematic を通した")
	}
}

func TestNoBaselineEntryAcceptsNewSize(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	b.clone().write(t, filepath.Join(w.cur, "x"))
	if err := os.Rename(filepath.Join(w.cur, "x", FlowsDir, "route", "design"), filepath.Join(w.cur, FlowsDir, "route", "short")); err != nil {
		t.Fatal(err)
	}
	w.acc.Entries = []Entry{{ID: "n1", Kind: KindNoBaseline, Flow: "route", Size: "short", Why: "前の版は短い画面で撮れない", Approved: true}}
	if r := w.run(t); !r.Passed {
		t.Fatalf("nobaseline の承認で通らない: %+v", r.Diffs)
	}
}

// ---- 古いセーブ ----

func TestRestoreProbeChangeStops(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.restore["probes"] = map[string]any{"mood": "tense"}
	r := newWorld(t, b, c).run(t)
	if r.Passed || len(diffsOf(r, WhatRestore)) != 1 {
		t.Fatalf("読み戻した問いの違いで止まらない: %+v", r.Diffs)
	}
}

func TestRestoreExpectedRefusalPasses(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.restore = map[string]any{"save": "quick1.json", "refused": true}
	w := newWorld(t, b, c)
	w.acc.Restore = map[string]string{"quick1": "refused"}
	if r := w.run(t); !r.Passed {
		t.Fatalf("読まずに知らせる決めで落ちた: %+v", r.Diffs)
	}
}

func TestRestoreExpectedRefusalButLoadedStops(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	w.acc.Restore = map[string]string{"quick1": "refused"}
	if w.run(t).Passed {
		t.Fatal("読まずに知らせるはずが読み戻したのに通した")
	}
}

// ---- 口と頁 ----

func runCLI(args ...string) (int, string) {
	var out, errOut bytes.Buffer
	code := Run(args, &out, &errOut)
	return code, out.String() + errOut.String()
}

func TestCLIExitZeroOnSameRecord(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	if code, msg := runCLI("diff", w.base, w.cur); code != 0 {
		t.Fatalf("終わりの番号 %d: %s", code, msg)
	}
}

func TestCLIWritesPageBesideNew(t *testing.T) {
	b := baseRec()
	w := newWorld(t, b, b.clone())
	runCLI("diff", w.base, w.cur)
	if !fileExists(filepath.Join(filepath.Dir(w.cur), "report", ReportHTML)) {
		t.Fatal("new の隣の report/index.html が無い")
	}
}

func TestCLIExitOneOnHardDiff(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"] = c.tape["sounds"].([]any)[:1]
	w := newWorld(t, b, c)
	if code, _ := runCLI("diff", w.base, w.cur); code != 1 {
		t.Fatalf("終わりの番号 %d（1 のはず）", code)
	}
}

func TestCLIReadsAcceptBesideNew(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.frames["frames/done.png"] = shifted(b.frames["frames/done.png"], 5)
	w := newWorld(t, b, c)
	writeJSON(t, filepath.Join(filepath.Dir(w.cur), AcceptFile), map[string]any{"entries": []any{map[string]any{
		"kind": "intended", "flow": "route", "what": "frame", "node": "Start", "seq": 0, "why": "背景を替えた", "approved": true}}})
	if code, msg := runCLI("diff", "--strict", w.base, w.cur); code != 0 {
		t.Fatalf("隣の承認を読まない: %d %s", code, msg)
	}
}

func TestCLIExitTwoWithoutRecord(t *testing.T) {
	if code, _ := runCLI("diff", t.TempDir(), t.TempDir()); code != 2 {
		t.Fatalf("記録の無いフォルダで終わりの番号 %d（2 のはず）", code)
	}
}

func TestTextListsReviewSeparately(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"].([]any)[1].(map[string]any)["t"] = 2.1
	txt := Text(newWorld(t, b, c).run(t), "")
	if !strings.Contains(txt, "迷った差 1 件") || !strings.Contains(txt, "通った") {
		t.Fatalf("迷った差の一覧が出ない:\n%s", txt)
	}
}

// ---- 横並びの動画 ----

func TestSideBySideWritesVideo(t *testing.T) {
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg が無い")
	}
	dir := t.TempDir()
	clip := func(name, col string) string {
		p := filepath.Join(dir, name)
		cmd := exec.Command(ff, "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c="+col+":s=64x96:d=1", "-f", "lavfi", "-i", "sine=d=1",
			"-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", p)
		if msg, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v %s", err, msg)
		}
		return p
	}
	b := baseRec()
	b.write(t, filepath.Join(dir, "rec"))
	out := filepath.Join(dir, "out", "route.sbs.mp4")
	err = SideBySide(clip("old.mp4", "red"), clip("new.mp4", "blue"), out, filepath.Join(dir, "rec", FlowsDir, "route", "design", TapeFile), ff)
	if err != nil || !fileExists(out) {
		t.Fatalf("横並びの動画が書けない: %v", err)
	}
}
