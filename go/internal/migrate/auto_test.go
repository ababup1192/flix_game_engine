package migrate

import (
	"image"
	"image/color"
	"testing"
)

// ---- 組む道具 ----

// eyes は what の差のうち、承認の無い、人が見る迷った差の数。
func eyes(r *Result, what string) int {
	n := 0
	for _, d := range r.Diffs {
		if d.What == what && d.Review && d.Accepted == "" && r.needsEye(d) {
			n++
		}
	}
	return n
}

func addSound(r *rec, at float64, name string) {
	r.tape["sounds"] = append(r.tape["sounds"].([]any), map[string]any{"t": at, "name": name, "kind": "se", "label": name})
}

// delayedRecs は選択肢から後ろが新しい版で delay 秒遅れる 2 本（承認した 1 か所の遅れ）。4.5 秒に se_go を鳴らす。
func delayedRecs(delay float64) (*rec, *rec) {
	b := baseRec()
	addSound(b, 4.5, "se_go")
	c := b.clone()
	shiftEvent(c, 1, 3.0+delay)
	shiftEvent(c, 2, 4.0+delay)
	c.tape["sounds"].([]any)[2].(map[string]any)["t"] = 4.5 + delay
	return b, c
}

func timesWorld(t *testing.T, b, c *rec) *world {
	w := newWorld(t, b, c)
	w.times = true
	return w
}

// ---- A. 時刻の合わせ直し ----

func TestSoundAfterDelayPassesWithTimes(t *testing.T) {
	b, c := delayedRecs(0.633)
	if n := eyes(timesWorld(t, b, c).run(t), WhatSound); n != 0 {
		t.Fatalf("直前の出来事と同じだけ遅れた音が人が見る差に残った: %d", n)
	}
}

func TestSoundAfterDelayIsAutoWithTimes(t *testing.T) {
	b, c := delayedRecs(0.633)
	d := diffsOf(timesWorld(t, b, c).run(t), WhatSound)
	if len(d) != 1 || d[0].Auto != AutoAnchor {
		t.Fatalf("合わせ直しで通した音は自動で通した差として残すはず: %+v", d)
	}
}

func TestSoundAfterDelayIsReviewWithoutTimes(t *testing.T) {
	b, c := delayedRecs(0.633)
	if n := eyes(newWorld(t, b, c).run(t), WhatSound); n != 1 {
		t.Fatalf("--times の無い時は頭からの時刻で比べるはず: %d", n)
	}
}

func TestSoundOneFrameOffAnchorPasses(t *testing.T) {
	b, c := delayedRecs(0.633)
	c.tape["sounds"].([]any)[2].(map[string]any)["t"] = 4.5 + 0.633 + 1.0/30
	if n := eyes(timesWorld(t, b, c).run(t), WhatSound); n != 0 {
		t.Fatalf("合わせ直した後の 1 フレームのずれで人が見る差が出た: %d", n)
	}
}

func TestSoundOverOneFrameOffAnchorIsReview(t *testing.T) {
	b, c := delayedRecs(0.633)
	c.tape["sounds"].([]any)[2].(map[string]any)["t"] = 4.5 + 0.633 + 1.0/30 + 0.002
	if n := eyes(timesWorld(t, b, c).run(t), WhatSound); n != 1 {
		t.Fatalf("合わせ直した後も 1 フレームを超えた音は人が見る差のはず: %d", n)
	}
}

// 合わせ直すと音は通るが、ずれの出元は eventTime が 1 件ずつ見ている。
func TestDelaySourceStaysAsEventTime(t *testing.T) {
	b, c := delayedRecs(0.633)
	if n := eyes(timesWorld(t, b, c).run(t), WhatEventTime); n != 1 {
		t.Fatalf("遅れの出元の出来事が eventTime に残らない: %d", n)
	}
}

// earlyEveryEvent は新しい版の出来事が、前の出来事から毎回 early 秒早く来る 2 本。
func earlyEveryEvent(early float64) (*rec, *rec) {
	b := baseRec()
	c := b.clone()
	shiftEvent(c, 0, 1.0-early)
	shiftEvent(c, 1, 3.0-2*early)
	shiftEvent(c, 2, 4.0-3*early)
	return b, c
}

func TestEarlyByOneFrameEveryEventPasses(t *testing.T) {
	b, c := earlyEveryEvent(1.0 / 30)
	if n := eyes(timesWorld(t, b, c).run(t), WhatEventTime); n != 0 {
		t.Fatalf("毎回 1 フレーム早いのは線の内のはず: %d", n)
	}
}

func TestEarlyOverOneFrameEveryEventStaysAsEventTime(t *testing.T) {
	b, c := earlyEveryEvent(1.0/30 + 0.002)
	if n := eyes(timesWorld(t, b, c).run(t), WhatEventTime); n != 3 {
		t.Fatalf("毎回 1 フレーム + 2 ミリ秒早い出来事は、合わせ直しても 1 件ずつ eventTime に残るはず: %d", n)
	}
}

func TestAnchorIncludesWaitEnd(t *testing.T) {
	sa, sb := 1.0, 1.02
	an := buildAnchor(
		[]Event{{T: 2, Kind: "wait", Seconds: &sa}},
		[]Event{{T: 2.5, Kind: "wait", Seconds: &sb}})
	if got := an.offsetAtNew(3.52); got < 0.519 || got > 0.521 {
		t.Fatalf("待ちの明けた所のずれを使っていない: %v", got)
	}
}

func TestObjectSpanAfterDelayPassesWithTimes(t *testing.T) {
	b, c := delayedRecs(0.633)
	b.tape["objects"] = []any{map[string]any{"id": "go", "from": 4.0, "to": 6.0, "rect": map[string]any{"x": 0, "y": 0, "w": 0.5, "h": 0.5}}}
	c.tape["objects"] = []any{map[string]any{"id": "go", "from": 4.633, "to": 6.633, "rect": map[string]any{"x": 0, "y": 0, "w": 0.5, "h": 0.5}}}
	if n := eyes(timesWorld(t, b, c).run(t), WhatObject); n != 0 {
		t.Fatalf("直前の出来事と同じだけ遅れた区間が人が見る差に残った: %d", n)
	}
}

func TestObjectSpanOffAnchorIsReview(t *testing.T) {
	b, c := delayedRecs(0.633)
	b.tape["objects"] = []any{map[string]any{"id": "go", "from": 4.0, "to": 6.0, "rect": map[string]any{"x": 0, "y": 0, "w": 0.5, "h": 0.5}}}
	c.tape["objects"] = []any{map[string]any{"id": "go", "from": 4.733, "to": 6.733, "rect": map[string]any{"x": 0, "y": 0, "w": 0.5, "h": 0.5}}}
	if n := eyes(timesWorld(t, b, c).run(t), WhatObject); n != 1 {
		t.Fatalf("合わせ直しても 0.1 秒ずれた区間は人が見る差のはず: %d", n)
	}
}

func delayedBus(delay float64) (*rec, *rec) {
	b, c := delayedRecs(delay)
	b.tape["buses"] = map[string]any{"bgm": []any{[]any{0, -6.0}, []any{4.0, -20.0}}}
	c.tape["buses"] = map[string]any{"bgm": []any{[]any{0, -6.0}, []any{4.0 + delay, -20.0}}}
	return b, c
}

func TestBusAfterDelayPassesWithTimes(t *testing.T) {
	b, c := delayedBus(0.633)
	if n := eyes(timesWorld(t, b, c).run(t), WhatBus); n != 0 {
		t.Fatalf("直前の出来事と同じだけ遅れた音量の変わり目が人が見る差に残った: %d", n)
	}
}

func TestBusAfterDelayIsReviewWithoutTimes(t *testing.T) {
	b, c := delayedBus(0.633)
	if n := eyes(newWorld(t, b, c).run(t), WhatBus); n != 1 {
		t.Fatalf("--times の無い時は頭からの時刻で音量を比べるはず: %d", n)
	}
}

// smallBusGap は 1 dB の線の内の 0.9 dB の差が 6 秒続く 2 本（合計 0.9 × 6 = 5.4 dB×秒ほど）。
func smallBusGap(t *testing.T, limit float64) *Result {
	x, y := busRecs(-6, -6.9)
	w := newWorld(t, x, y)
	w.acc = &Accept{Thresholds: map[string]float64{"busDBSec": limit}}
	return w.run(t)
}

func TestSmallBusGapUnderSumPasses(t *testing.T) {
	if n := eyes(smallBusGap(t, 6), WhatBus); n != 0 {
		t.Fatalf("合計が線の内の小さな音量の差で人が見る差が出た: %d", n)
	}
}

func TestSmallBusGapOverSumIsReview(t *testing.T) {
	if n := eyes(smallBusGap(t, 5), WhatBus); n != 1 {
		t.Fatalf("線の内でも長く続いた音量の差は合計で 1 件残すはず: %d", n)
	}
}

// ---- 今ある穴: 組になれない音の後ろも比べる ----

func TestSoundAfterExtraSoundIsCompared(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"] = []any{
		map[string]any{"t": 0.0, "name": "amb_room", "kind": "ambience"},
		map[string]any{"t": 0.5, "name": "amb_extra", "kind": "ambience"},
		map[string]any{"t": 2.5, "name": "se_bell", "kind": "se"},
	}
	if n := eyes(newWorld(t, b, c).run(t), WhatSound); n != 1 {
		t.Fatalf("新しい版にだけある音の後ろの音の時刻を比べていない: %d", n)
	}
}

func TestExtraSoundIsStillHard(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"] = []any{
		map[string]any{"t": 0.0, "name": "amb_room", "kind": "ambience"},
		map[string]any{"t": 0.5, "name": "amb_extra", "kind": "ambience"},
		map[string]any{"t": 2.0, "name": "se_bell", "kind": "se"},
	}
	hard := 0
	for _, d := range diffsOf(newWorld(t, b, c).run(t), WhatSound) {
		if !d.Review {
			hard++
		}
	}
	if hard != 1 {
		t.Fatalf("新しい版にだけある 1 音は止める差 1 件のはず: %d", hard)
	}
}

func TestSoundAfterMissingSoundIsCompared(t *testing.T) {
	b := baseRec()
	addSound(b, 1.5, "se_gone")
	c := baseRec()
	c.tape["sounds"].([]any)[1].(map[string]any)["t"] = 2.5
	if n := eyes(newWorld(t, b, c).run(t), WhatSound); n != 1 {
		t.Fatalf("新しい版に無い音の後ろの音の時刻を比べていない: %d", n)
	}
}

// ---- C. 時刻のずれたコマのブロックの比べ ----

// grainy は gradient に ±20 の市松のざらつきを足し、(40,40) から 16 px 四方を patch だけ明るくした絵。
// ざらつきは 8 px 四方の平均で消え、明るくした所だけがブロックの差に残る。
func grainy(patch int) *image.NRGBA {
	img := gradient(100, 100)
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			p := img.NRGBAAt(x, y)
			g := 20
			if (x+y)%2 == 0 {
				g = -20
			}
			if x >= 40 && x < 56 && y >= 40 && y < 56 {
				g += patch
			}
			img.SetNRGBA(x, y, color.NRGBA{R: clampByte(int(p.R) + g), G: clampByte(int(p.G) + g), B: clampByte(int(p.B) + g), A: 255})
		}
	}
	return img
}

func clampByte(v int) uint8 { return uint8(min(max(v, 0), 255)) }

// grainyRecs は lineDone のコマだけを、新しい版で dt 秒ずらして grainy(patch) にした 2 本。
func grainyRecs(patch int, dt float64) (*rec, *rec) {
	b := baseRec()
	c := b.clone()
	c.frames["frames/done.png"] = grainy(patch)
	c.tape["frames"].([]any)[0].(map[string]any)["t"] = 1.5 + dt
	return b, c
}

func TestShiftedGrainyFramePassesByBlocks(t *testing.T) {
	b, c := grainyRecs(0, 0.1)
	if n := eyes(newWorld(t, b, c).run(t), WhatFrame); n != 0 {
		t.Fatalf("時刻のずれたコマのざらつきだけの差が人が見る差に残った: %d", n)
	}
}

func TestSameTimeGrainyFrameKeepsStrictLine(t *testing.T) {
	b, c := grainyRecs(0, 0)
	if n := eyes(newWorld(t, b, c).run(t), WhatFrame); n != 1 {
		t.Fatalf("同じ時刻のコマはブロックの比べで通さないはず: %d", n)
	}
}

func TestShiftedFrameAtBlockLinePasses(t *testing.T) {
	b, c := grainyRecs(10, 0.1)
	if n := eyes(newWorld(t, b, c).run(t), WhatFrame); n != 0 {
		t.Fatalf("ブロックの差 10 は線の内のはず: %d", n)
	}
}

func TestShiftedFrameOverBlockLineIsReview(t *testing.T) {
	b, c := grainyRecs(11, 0.1)
	if n := eyes(newWorld(t, b, c).run(t), WhatFrame); n != 1 {
		t.Fatalf("ブロックの差 11 は人が見る差のはず: %d", n)
	}
}

// watchRecs は lineDone のコマ n 枚を、新しい版で全部 0.1 秒ずらし、ブロックの差 8（通るが BlockWatch の 6 を超える）にした 2 本。
func watchRecs(n int) (*rec, *rec) {
	b := baseRec()
	var frames []any
	b.frames = map[string]*image.NRGBA{}
	for i := 0; i < n; i++ {
		name := "frames/w" + string(rune('a'+i)) + ".png"
		frames = append(frames, map[string]any{"file": name, "t": 1.0 + float64(i)*0.5, "node": "Start", "seq": i, "kind": "lineDone", "layer": "world"})
		b.frames[name] = gradient(100, 100)
	}
	b.tape["frames"] = frames
	c := b.clone()
	for i, f := range c.tape["frames"].([]any) {
		m := f.(map[string]any)
		m["t"] = 1.1 + float64(i)*0.5
		c.frames[m["file"].(string)] = grainy(8)
	}
	return b, c
}

func TestFourNearLineFramesInARowPass(t *testing.T) {
	b, c := watchRecs(4)
	if n := eyes(newWorld(t, b, c).run(t), WhatFrame); n != 0 {
		t.Fatalf("線の近くのコマが 4 枚続いただけで人が見る差が出た: %d", n)
	}
}

func TestFiveNearLineFramesInARowAreReview(t *testing.T) {
	b, c := watchRecs(5)
	if n := eyes(newWorld(t, b, c).run(t), WhatFrame); n != 1 {
		t.Fatalf("線の近くのコマが 5 枚続いたら 1 件残すはず: %d", n)
	}
}

// ---- --strict と --no-auto ----

func TestStrictPassesWithOnlyAutoDiffs(t *testing.T) {
	b, c := grainyRecs(0, 0.1)
	w := newWorld(t, b, c)
	w.strict = true
	if r := w.run(t); !r.Passed {
		t.Fatalf("自動で通した差だけで --strict が止めた: %+v", r.Diffs)
	}
}

func TestNoAutoStrictStopsOnAutoDiffs(t *testing.T) {
	b, c := grainyRecs(0, 0.1)
	w := newWorld(t, b, c)
	w.strict = true
	a, _ := LoadSide(w.base)
	n, _ := LoadSide(w.cur)
	r := Compare(a, n, w.acc, Options{Game: w.game, Strict: true, NoAuto: true, Th: DefaultThresholds(), Lim: DefaultLimits()})
	if r.Passed {
		t.Fatal("--no-auto --strict で自動で通した差が止めない")
	}
}

func TestNoAutoFlagIsParsed(t *testing.T) {
	a, err := parseDiffArgs([]string{"--no-auto", "base", "new"})
	if err != nil || !a.noAuto {
		t.Fatalf("--no-auto を読んでいない: %+v %v", a, err)
	}
}

// ---- D. 人に見せる単位 ----

func TestSameDiffInTwoFlowsIsOneUnit(t *testing.T) {
	b := baseRec()
	c := b.clone()
	c.tape["sounds"].([]any)[1].(map[string]any)["t"] = 2.5
	w := newWorld(t, b, c)
	b.writeFlow(t, w.base, "route2", "design")
	c.writeFlow(t, w.cur, "route2", "design")
	if r := w.run(t); len(r.Units) != 1 {
		t.Fatalf("2 つの flow の同じ所の同じ差が 1 つにまとまらない: %+v", r.Units)
	}
}

func TestConsecutiveFramesAreOneUnit(t *testing.T) {
	b, c := watchRecs(3)
	for _, f := range c.tape["frames"].([]any) {
		c.frames[f.(map[string]any)["file"].(string)] = grainy(40)
	}
	if r := newWorld(t, b, c).run(t); len(r.Units) != 1 {
		t.Fatalf("続いた 3 枚のコマが 1 区間にまとまらない: %+v", r.Units)
	}
}

// ---- E. 新しい版にだけある物 ----

func newObjectWorld(t *testing.T) *world {
	b := baseRec()
	c := b.clone()
	c.tape["objects"] = append(c.tape["objects"].([]any), map[string]any{"id": "fx_new", "from": 2.0, "to": 3.0, "rect": map[string]any{"x": 0, "y": 0, "w": 0.1, "h": 0.1}})
	w := newWorld(t, b, c)
	b.writeFlow(t, w.base, "route2", "design")
	c.writeFlow(t, w.cur, "route2", "design")
	return w
}

func TestNewObjectInTwoFlowsIsOneUnit(t *testing.T) {
	if r := newObjectWorld(t).run(t); len(r.Units) != 1 {
		t.Fatalf("新しい版にだけある物が id ごとに 1 つにまとまらない: %+v", r.Units)
	}
}

func TestNewObjectEntryCoversEveryFlow(t *testing.T) {
	w := newObjectWorld(t)
	w.acc = &Accept{Entries: []Entry{{ID: "o1", Kind: KindIntended, What: WhatNewObject, Object: "fx_new", Why: "足した", Approved: true}}}
	if n := eyes(w.run(t), WhatNewObject); n != 0 {
		t.Fatalf("1 回の承認が全部の flow の新しい版にだけある物に当たらない: %d", n)
	}
}

func TestNewObjectEntryNeedsObject(t *testing.T) {
	a := &Accept{Entries: []Entry{{ID: "o1", Kind: KindIntended, What: WhatNewObject, Why: "足した", Approved: true}}}
	if problems, _ := a.Validate(DefaultLimits()); len(problems) != 1 {
		t.Fatalf("object の無い newObject の承認を止めない: %v", problems)
	}
}

// ---- しきい値の上書き ----

func TestThresholdOverrideIsUsed(t *testing.T) {
	a := &Accept{Thresholds: map[string]float64{"blockP99": 12}}
	if th, _ := a.overrideThresholds(DefaultThresholds()); th.BlockP99 != 12 {
		t.Fatalf("thresholds の上書きを使っていない: %v", th.BlockP99)
	}
}

func TestThresholdOverrideAtLimitIsAccepted(t *testing.T) {
	a := &Accept{Thresholds: map[string]float64{"blockP99": 16}}
	if _, problems := a.overrideThresholds(DefaultThresholds()); len(problems) != 0 {
		t.Fatalf("上限ちょうどの上書きを止めた: %v", problems)
	}
}

func TestThresholdOverrideOverLimitIsProblem(t *testing.T) {
	a := &Accept{Thresholds: map[string]float64{"blockP99": 16.5}}
	if _, problems := a.overrideThresholds(DefaultThresholds()); len(problems) != 1 {
		t.Fatalf("上限を超えた上書きを止めない: %v", problems)
	}
}

func TestUnknownThresholdIsProblem(t *testing.T) {
	a := &Accept{Thresholds: map[string]float64{"busStep": 1}}
	if _, problems := a.overrideThresholds(DefaultThresholds()); len(problems) != 1 {
		t.Fatalf("上書きできない線引きの名前を止めない: %v", problems)
	}
}

func TestEventRoundWidthIsAThreshold(t *testing.T) {
	b := baseRec()
	c := b.clone()
	shiftEvent(c, 1, 3.0+1.0/30+0.0015)
	w := timesWorld(t, b, c)
	w.acc = &Accept{Thresholds: map[string]float64{"eventRoundSec": 0.002}}
	if n := eyes(w.run(t), WhatEventTime); n != 0 {
		t.Fatalf("丸めの幅を 2 ミリ秒にしても 1.5 ミリ秒の超えが残った: %d", n)
	}
}
