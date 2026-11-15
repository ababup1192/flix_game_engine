package migrate

import (
	"fmt"
	"image"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
)

// ---- 4. 画面の物 ----

// screenOf は矩形の割合を px に直す画面の大きさ（screen が無ければ world のコマの大きさ）。
func screenOf(t *Tape) *Size {
	if t.Screen != nil {
		return t.Screen
	}
	return frameSize(t.Dir, t.Frames)
}

func frameSize(dir string, frames []Frame) *Size {
	for _, f := range frames {
		fh, err := os.Open(filepath.Join(dir, f.File))
		if err != nil {
			continue
		}
		cfg, err := png.DecodeConfig(fh)
		fh.Close()
		if err == nil {
			return &Size{W: float64(cfg.Width), H: float64(cfg.Height)}
		}
	}
	return nil
}

// placer は秒から、その時に出ていた台詞（ノードと番号）を引く。
type placer func(at float64) (string, int)

func (c *comparer) objects(flow, size string, a, b []Object, tol float64, sa, sb *Size, place placer) {
	if sa == nil || sb == nil {
		c.skip(flow, size, WhatObject, "画面の大きさ（screen）も world のコマも無いので、矩形は比べていない（数と区間だけ比べた）")
	}
	group := func(list []Object, mapped bool) map[string][]Object {
		m := map[string][]Object{}
		for _, o := range list {
			id := o.ID
			if mapped {
				id = c.acc.mapID(id)
			}
			m[id] = append(m[id], o)
		}
		for _, v := range m {
			sort.SliceStable(v, func(i, j int) bool { return v[i].From < v[j].From })
		}
		return m
	}
	add := func(at float64, detail string) {
		node, seq := place(at)
		c.add(&Diff{Flow: flow, Size: size, Step: 4, What: WhatObject, Node: node, Seq: seq, T: at, Review: true, Detail: detail})
	}
	ga, gb := group(a, true), group(b, false)
	for _, id := range sortedKeys(ga) {
		la, lb := ga[id], gb[id]
		if len(la) != len(lb) {
			add(la[0].From, fmt.Sprintf("%s の出た回数が違う（前 %d・後 %d）", id, len(la), len(lb)))
			continue
		}
		for i := range la {
			if why := objectDiff(la[i], lb[i], tol, sa, sb, c.opt.Th.RectPx, c.acc.rectFree(id)); why != "" {
				add(lb[i].From, fmt.Sprintf("%s の %d 回目: %s", id, i, why))
			}
		}
	}
	for _, id := range sortedKeys(gb) {
		if _, ok := ga[id]; !ok {
			add(gb[id][0].From, fmt.Sprintf("%s は新しい版にだけ出る（前の id と同じなら idMap に書く）", id))
		}
	}
}

func objectDiff(a, b Object, tol float64, sa, sb *Size, px float64, rectFree bool) string {
	if math.Abs(a.From-b.From) > tol || math.Abs(a.To-b.To) > tol {
		return fmt.Sprintf("出ていた区間が違う（前 %.3f〜%.3f / 後 %.3f〜%.3f）", a.From, a.To, b.From, b.To)
	}
	if rectFree || sa == nil || sb == nil {
		return ""
	}
	ax := [4]float64{a.Rect.X * sa.W, a.Rect.Y * sa.H, a.Rect.W * sa.W, a.Rect.H * sa.H}
	bx := [4]float64{b.Rect.X * sb.W, b.Rect.Y * sb.H, b.Rect.W * sb.W, b.Rect.H * sb.H}
	for k := range ax {
		if math.Abs(ax[k]-bx[k]) > px+1e-6 {
			return fmt.Sprintf("矩形が %g px より大きくずれた（前 %.0f,%.0f %.0fx%.0f / 後 %.0f,%.0f %.0fx%.0f）", px, ax[0], ax[1], ax[2], ax[3], bx[0], bx[1], bx[2], bx[3])
		}
	}
	return ""
}

// ---- 5. コマ ----

// visitsOf はコマがそのノードの何回目の訪問（0 から）にあるかを、出来事の並びから数える。
// 出来事の並びが前と後で一致した後に引くので、前と後で同じ数え方になる。
func visitsOf(t *Tape) func(Frame) int {
	type entry struct {
		node string
		t    float64
	}
	var entries []entry
	prev := ""
	for _, e := range eventsOf(t) {
		if e.Node != prev {
			entries = append(entries, entry{e.Node, e.T})
			prev = e.Node
		}
	}
	return func(f Frame) int {
		n := 0
		for _, e := range entries {
			if e.node == f.Node && e.t <= f.T+1e-9 {
				n++
			}
		}
		if f.Seq >= 0 {
			return max(n-1, 0)
		}
		return n
	}
}

// frameSide は片方の版のコマと、その読み方。
type frameSide struct {
	frames []Frame
	dir    string
	visit  func(Frame) int
}

func noVisits(Frame) int { return 0 }

type framePair struct {
	idx    int
	fa, fb Frame
}

func (c *comparer) frames(flow, size string, a, b frameSide, restore bool) {
	if len(a.frames) == 0 {
		c.skip(flow, size, WhatFrame, "前の版に frames が無い")
		return
	}
	byKey := map[string]Frame{}
	for _, f := range b.frames {
		byKey[f.Key(b.visit(f))] = f
	}
	var pairs []framePair
	for i, fa := range a.frames {
		if fa.Layer != "world" {
			continue
		}
		key := fa.Key(a.visit(fa))
		fb, ok := byKey[key]
		if !ok {
			c.add(&Diff{Flow: flow, Size: size, Step: 5, What: WhatMissing, Node: fa.Node, Seq: fa.Seq, T: fa.T, FrameKind: fa.Kind, Cmd: fa.Cmd,
				Before: filepath.Join(a.dir, fa.File), Detail: "新しい版でこのコマを撮っていない（" + key + "）"})
			continue
		}
		pairs = append(pairs, framePair{i, fa, fb})
	}
	results := make([]*Diff, len(pairs))
	work := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < runtime.NumCPU(); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for k := range work {
				p := pairs[k]
				results[k] = c.frame(flow, size, p.idx, p.fa, p.fb, a.dir, b.dir, restore)
			}
		}()
	}
	for k := range pairs {
		work <- k
	}
	close(work)
	wg.Wait()
	c.r.Frames += len(pairs)
	for _, d := range results {
		if d != nil {
			c.add(d)
		}
	}
}

// frame は 1 組のコマを比べ、10.3 の線を超えた時だけ差を返す（並べて走るので c.r には書かない）。
func (c *comparer) frame(flow, size string, i int, fa, fb Frame, dirA, dirB string, restore bool) *Diff {
	pa, pb := filepath.Join(dirA, fa.File), filepath.Join(dirB, fb.File)
	d := &Diff{Flow: flow, Size: size, Step: 5, What: WhatFrame, Node: fa.Node, Seq: fa.Seq, T: fb.T, FrameKind: fa.Kind, Cmd: fb.Cmd, Before: pa, After: pb}
	if restore {
		d.Step = 6
	}
	ia, err := loadNRGBA(pa)
	var ib *image.NRGBA
	if err == nil {
		ib, err = loadNRGBA(pb)
	}
	if err != nil {
		d.Detail = "コマを読めない: " + err.Error()
		return d
	}
	th := c.opt.Th
	delta, shift := th.DoneDelta, th.ShiftPx
	if fa.Backdrop3d {
		delta = th.Still3DDelta
	}
	mid := fa.Kind == "mid" && !restore
	if mid {
		// WhyNot: 途中のコマでずれを探さない — なめらかな背景では近くに同じ色が見つかり、overlay の濃さの差が隠れる。
		shift = 0
	}
	st, gaps, cerr := comparePixels(ia, ib, delta, shift)
	d.Mean, d.Max, d.Within = st.Mean, st.Max, st.Within
	if cerr != nil {
		d.Detail = cerr.Error()
		return d
	}
	if d.Detail = c.frameRule(fa, st, delta, mid); d.Detail == "" {
		return nil
	}
	d.Review = true
	if c.opt.Out != "" {
		heat := filepath.Join(c.opt.Out, "heat", fmt.Sprintf("%s_%s_%d.png", safeName(flow), safeName(size), i))
		if os.MkdirAll(filepath.Dir(heat), 0o755) == nil && writeHeat(heat, ia, gaps, delta) == nil {
			d.Heat = heat
		}
	}
	return d
}

// frameRule は 10.3 の線を超えた時にその理由を返す（通れば空）。
func (c *comparer) frameRule(f Frame, st PixelStats, delta int, mid bool) string {
	th := c.opt.Th
	switch {
	case mid:
		if st.Mean > th.MidMean+1e-9 {
			return fmt.Sprintf("途中のコマの差の平均 %.2f/255 が %g/255 を超えた", st.Mean, th.MidMean)
		}
	case f.Backdrop3d:
		if st.Within < th.Still3DRatio {
			return fmt.Sprintf("3D の背景の休みの位置で差が %d/255 以内の画素が %.2f%%（%.1f%% 以上で通る）", delta, st.Within*100, th.Still3DRatio*100)
		}
	default:
		if st.Within < th.DoneRatio {
			return fmt.Sprintf("演出の後のコマで差が %d/255 以内の画素が %.2f%%（%.1f%% 以上で通る・%d px のずれまで許した後・最大の差 %d）", delta, st.Within*100, th.DoneRatio*100, th.ShiftPx, st.Max)
		}
	}
	return ""
}

func safeName(s string) string {
	return strings.NewReplacer("/", "_", "\\", "_", " ", "_", ":", "_").Replace(s)
}

// ---- 6. 古いセーブの読み戻し ----

func (c *comparer) restores(base, cur *Side) {
	if len(base.Restores) == 0 {
		c.skip("saves", SingleSize, WhatRestore, "前の版に saves/<名前>/restore.json が無い")
	}
	for _, name := range sortedKeys(c.acc.Restore) {
		if base.Restores[name] == nil {
			c.r.Unused = append(c.r.Unused, fmt.Sprintf("restore の %s は前の版の記録に無い", name))
		}
	}
	for _, name := range sortedKeys(base.Restores) {
		c.restore(name, base.Restores[name], cur.Restores[name])
	}
}

func (c *comparer) restore(name string, ra, rb *Restore) {
	flow := "saves/" + name
	add := func(detail string) {
		c.add(&Diff{Flow: flow, Size: SingleSize, Step: 6, What: WhatRestore, Node: ra.Node, Seq: ra.Seq, Detail: detail})
	}
	if rb == nil {
		add("新しい版でこのセーブを読み戻していない")
		return
	}
	if c.acc.Restore[name] == "refused" {
		c.r.Applied = append(c.r.Applied, fmt.Sprintf("セーブ %s は新しい版で読まずに知らせる決め（restore: refused）で比べた", name))
		if !rb.Refused {
			add("新しい版は「版が違うので読めない」と知らせてはじめから始めるはずが、読み戻した")
		}
		return
	}
	if ra.Refused != rb.Refused {
		add(fmt.Sprintf("読めたかが違う（前 refused=%v / 後 refused=%v）", ra.Refused, rb.Refused))
		return
	}
	if ra.Node != rb.Node || ra.Seq != rb.Seq {
		add(fmt.Sprintf("戻った所が違う（前 %s#%d / 後 %s#%d）", ra.Node, ra.Seq, rb.Node, rb.Seq))
		return
	}
	for _, p := range sortedKeys(ra.Probes) {
		va := c.mapProbe(p, ra.Probes[p])
		vb, ok := rb.Probes[p]
		if !ok || scalarText(vb) != va {
			add(fmt.Sprintf("読み戻した時の問い %s が違う（前 %s）", p, va))
		}
	}
	sa, sb := ra.Screen, rb.Screen
	if sa == nil {
		sa = frameSize(ra.Dir, ra.Frames)
	}
	if sb == nil {
		sb = frameSize(rb.Dir, rb.Frames)
	}
	before := len(c.r.Diffs)
	place := func(float64) (string, int) { return ra.Node, ra.Seq }
	c.objects(flow, SingleSize, ra.Objects, rb.Objects, math.Inf(1), sa, sb, place)
	c.frames(flow, SingleSize, frameSide{ra.Frames, ra.Dir, noVisits}, frameSide{rb.Frames, rb.Dir, noVisits}, true)
	for _, d := range c.r.Diffs[before:] {
		d.Step = 6
	}
}
