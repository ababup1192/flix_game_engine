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

// frameSide は片方の版のコマ。
type frameSide struct {
	frames []Frame
	dir    string
}

// keyed はコマを時刻の順に並べ、鍵の土台に「同じ土台の何回目か」を足した鍵で引けるようにする。
// 同じ土台で同じ時刻のコマが 2 枚あれば、どちらを組にするか決まらないので dup に返す。
// WhyNot: ノードの訪問の回数を出来事の並びから数えない — 台詞の無いノード（場面転換）や同じノードへの続けての入り直しを数えられない。
func keyed(frames []Frame) (byKey map[string]Frame, order []string, dup []Frame) {
	idx := make([]int, len(frames))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(i, j int) bool { return frames[idx[i]].T < frames[idx[j]].T })
	byKey = map[string]Frame{}
	count := map[string]int{}
	last := map[string]float64{}
	for _, i := range idx {
		f := frames[i]
		base := f.Key()
		if n := count[base]; n > 0 && math.Abs(last[base]-f.T) < 1e-9 {
			dup = append(dup, f)
			continue
		}
		key := fmt.Sprintf("%s/%d", base, count[base])
		count[base]++
		last[base] = f.T
		if _, ok := byKey[key]; ok {
			dup = append(dup, f)
			continue
		}
		byKey[key] = f
		order = append(order, key)
	}
	return byKey, order, dup
}

type framePair struct {
	idx    int
	fa, fb Frame
}

func (c *comparer) frames(flow, size string, a, b frameSide, restore bool) {
	if len(a.frames) == 0 {
		c.skip(flow, size, WhatFrame, "前の版に frames が無い")
		return
	}
	byA, orderA, dupA := keyed(a.frames)
	byB, _, dupB := keyed(b.frames)
	for _, side := range []struct {
		name string
		dup  []Frame
	}{{"前", dupA}, {"後", dupB}} {
		for _, f := range side.dup {
			c.add(&Diff{Flow: flow, Size: size, Step: 5, What: WhatMissing, Node: f.Node, Seq: f.Seq, T: f.T, FrameKind: f.Kind,
				Detail: fmt.Sprintf("%sの版の記録の中で、同じ鍵（%s）のコマが同じ時刻に 2 枚ある（どれを組にするか決まらない）", side.name, f.Key())})
		}
	}
	var pairs []framePair
	seconds := midSeconds{seen: map[string]bool{}}
	for i, key := range orderA {
		fa := byA[key]
		if fa.Layer != "world" {
			continue
		}
		fb, ok := byB[key]
		if !ok {
			c.add(c.missingFrame(flow, size, fa, a.dir, key, restore))
			continue
		}
		pairs = append(pairs, framePair{i, fa, fb})
		if fa.Kind == "mid" && !restore {
			if d := seconds.compare(flow, size, fa, fb, a.dir, b.dir); d != nil {
				c.add(d)
			}
		}
	}
	if extra := newOnlyFrames(byA, byB); extra > 0 {
		c.r.Notes = append(c.r.Notes, fmt.Sprintf("%s/%s: 新しい版にだけある world のコマが %d 枚（前の版に組む相手が無いので比べていない）", flow, size, extra))
	}
	if seconds.oneSided > 0 {
		c.r.Notes = append(c.r.Notes, fmt.Sprintf("%s/%s: 途中のコマ %d 枚は片方の版にしか命令の秒（seconds）が無いので、秒を比べていない", flow, size, seconds.oneSided))
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

// newOnlyFrames は新しい版にだけある world のコマの数（新しい版で秒が分かるようになった命令の途中のコマなど）。
func newOnlyFrames(byA, byB map[string]Frame) int {
	n := 0
	for key, f := range byB {
		if _, ok := byA[key]; !ok && f.Layer == "world" {
			n++
		}
	}
	return n
}

// midSeconds は組になった途中のコマの命令の秒を比べる。同じ命令の 0.25・0.5・0.75 の 3 枚は 1 件にまとめる。
type midSeconds struct {
	seen     map[string]bool
	oneSided int
}

// compare は秒が違えば迷った差を返す（同じ命令で 2 回目からは nil）。片方にだけ秒があれば数えるだけ。
func (m *midSeconds) compare(flow, size string, fa, fb Frame, dirA, dirB string) *Diff {
	if (fa.Seconds == nil) != (fb.Seconds == nil) {
		m.oneSided++
		return nil
	}
	if fa.Seconds == nil || math.Abs(*fa.Seconds-*fb.Seconds) <= 1e-9 {
		return nil
	}
	cmdKey := fmt.Sprintf("%s#%d|%d|%s|%g|%g", fa.Node, fa.Seq, fa.Step, fa.Cmd, *fa.Seconds, *fb.Seconds)
	if m.seen[cmdKey] {
		return nil
	}
	m.seen[cmdKey] = true
	return &Diff{Flow: flow, Size: size, Step: 5, What: WhatFrame, Node: fa.Node, Seq: fa.Seq, T: fb.T, FrameKind: fa.Kind, Cmd: fb.Cmd,
		Before: filepath.Join(dirA, fa.File), After: filepath.Join(dirB, fb.File), Review: true,
		Detail: fmt.Sprintf("時間を取る命令 %s の秒が違う（前 %g 秒 / 後 %g 秒。途中のコマは秒に対する割合で撮るので、絵では差が出ない）", fa.Cmd, *fa.Seconds, *fb.Seconds)}
}

// missingFrame は新しい版で撮っていないコマの差。途中のコマは命令を組み替えると生まれない事があるので、
// 止める側のまま intended で承認できる差にする。演出の後のコマと古いセーブのコマは撮れていない記録（承認できない）。
func (c *comparer) missingFrame(flow, size string, fa Frame, dir, key string, restore bool) *Diff {
	d := &Diff{Flow: flow, Size: size, Step: 5, What: WhatMissing, Node: fa.Node, Seq: fa.Seq, T: fa.T, FrameKind: fa.Kind, Cmd: fa.Cmd,
		Before: filepath.Join(dir, fa.File), Detail: "新しい版でこのコマを撮っていない（" + key + "）"}
	if fa.Kind == "mid" && !restore {
		d.What = WhatFrame
		d.Detail += "。命令を組み替えて生まれなくなった途中のコマなら what: frame の intended で承認する"
	}
	return d
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
	c.frames(flow, SingleSize, frameSide{ra.Frames, ra.Dir}, frameSide{rb.Frames, rb.Dir}, true)
	for _, d := range c.r.Diffs[before:] {
		d.Step = 6
	}
}
