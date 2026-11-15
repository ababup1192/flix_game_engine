package migrate

import (
	"fmt"
	"image"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// 差の種類（Diff.What と承認の what）。
const (
	WhatMissing    = "missing"
	WhatNoBaseline = "nobaseline"
	WhatEvent      = "event"
	WhatSound      = "sound"
	WhatBus        = "bus"
	WhatProbe      = "probe"
	WhatObject     = "object"
	WhatFrame      = "frame"
	WhatRestore    = "restore"
)

// Diff は 1 件の違い。Step は 10.2 の番号（0 は記録が揃っていない）。
type Diff struct {
	Flow      string  `json:"flow"`
	Size      string  `json:"size"`
	Step      int     `json:"step"`
	What      string  `json:"what"`
	Node      string  `json:"node,omitempty"`
	Seq       int     `json:"seq"`
	T         float64 `json:"t"`
	Detail    string  `json:"detail"`
	Before    string  `json:"before,omitempty"`
	After     string  `json:"after,omitempty"`
	Heat      string  `json:"heat,omitempty"`
	FrameKind string  `json:"frameKind,omitempty"`
	Cmd       string  `json:"cmd,omitempty"`
	Mean      float64 `json:"mean,omitempty"`
	Max       int     `json:"max,omitempty"`
	Within    float64 `json:"within,omitempty"`
	Accepted  string  `json:"accepted,omitempty"`
	Why       string  `json:"why,omitempty"`
	Pending   bool    `json:"pending,omitempty"`
	// Review は迷った差（絵・矩形・音の時刻・音量）。門は止めず、一覧に溜めて最後に動画と並べて人が見る（10.3 の合格線）。
	Review bool `json:"review,omitempty"`
}

// Skip は比べていない物（欄が無い記録）。門は落とさない。
type Skip struct {
	Flow string `json:"flow"`
	Size string `json:"size"`
	What string `json:"what"`
	Why  string `json:"why"`
}

// Uncovered はどの flow も通らなかった命令の行。
type Uncovered struct {
	Yarn     string `json:"yarn"`
	Line     int    `json:"line"`
	Text     string `json:"text"`
	Accepted bool   `json:"accepted"`
}

// Result は突き合わせの全部。
type Result struct {
	Diffs     []*Diff     `json:"diffs"`
	Skips     []Skip      `json:"skips"`
	Uncovered []Uncovered `json:"uncovered"`
	Problems  []string    `json:"problems"`
	Notes     []string    `json:"notes"`
	Stopped   []string    `json:"stopped"`
	Frames    int         `json:"framesCompared"`
	Strict    bool        `json:"strict"`
	Passed    bool        `json:"passed"`
}

// Open は門を止める違い（承認の無い、迷った差でない物と通らない命令の行）の数。strict なら迷った差も数える。
func (r *Result) Open(strict bool) int {
	n := countOpenUncovered(r)
	for _, d := range r.Diffs {
		if d.Accepted == "" && (strict || !d.Review) {
			n++
		}
	}
	return n
}

// Options は Compare の指定。
type Options struct {
	Out        string // 差の色の図を書く所（空なら書かない）
	Game       string // 新しい版のゲームのルート（カバー率で台本を読む）
	NoCoverage bool
	Strict     bool // 迷った差でも門を止める（10.6 の「わざと入れた読み違いで落ちる」を確かめる時）
	Th         Thresholds
	Lim        Limits
}

// Compare は前と後の記録を突き合わせる。
func Compare(base, cur *Side, acc *Accept, opt Options) *Result {
	r := &Result{Diffs: []*Diff{}, Skips: []Skip{}, Uncovered: []Uncovered{}, Problems: []string{}, Notes: []string{}, Stopped: []string{}}
	c := &comparer{r: r, acc: acc, opt: opt}
	for _, flow := range sortedKeys(base.Flows) {
		sizes := base.Flows[flow]
		for _, size := range sortedKeys(sizes) {
			nt := cur.Flows[flow][size]
			if nt == nil {
				c.add(&Diff{Flow: flow, Size: size, What: WhatMissing, Seq: -1, Detail: "新しい版でこの flow のこの大きさを撮っていない"})
				continue
			}
			c.tape(flow, size, sizes[size], nt)
		}
	}
	for _, flow := range sortedKeys(cur.Flows) {
		for _, size := range sortedKeys(cur.Flows[flow]) {
			if base.Flows[flow][size] == nil {
				c.add(&Diff{Flow: flow, Size: size, What: WhatNoBaseline, Seq: -1, Detail: "前の版の記録が無い（新しい版の絵を人が頁で見て nobaseline で承認する）"})
			}
		}
	}
	c.restores(base, cur)
	if opt.NoCoverage {
		r.Notes = append(r.Notes, "カバー率は --no-coverage で比べていない")
	} else {
		c.coverage(cur)
	}
	problems, invalid := acc.Validate(opt.Lim)
	r.Problems = append(r.Problems, problems...)
	c.applyAccept(invalid)
	r.Strict = opt.Strict
	r.Passed = r.Open(opt.Strict) == 0 && len(r.Problems) == 0
	return r
}

type comparer struct {
	r   *Result
	acc *Accept
	opt Options
}

func (c *comparer) add(d *Diff) { c.r.Diffs = append(c.r.Diffs, d) }

func (c *comparer) skip(flow, size, what, why string) {
	c.r.Skips = append(c.r.Skips, Skip{Flow: flow, Size: size, What: what, Why: why})
}

func (c *comparer) tape(flow, size string, a, b *Tape) {
	if !c.events(flow, size, a, b) {
		c.r.Stopped = append(c.r.Stopped, flow+"/"+size)
		return
	}
	c.sounds(flow, size, a, b)
	c.buses(flow, size, a, b)
	c.probes(flow, size, a, b)
	c.objects(flow, size, a.Objects, b.Objects, frameTol(a), screenOf(a), screenOf(b))
	c.frames(flow, size, a.Frames, b.Frames, a.Dir, b.Dir, false)
}

func frameTol(t *Tape) float64 { return 1/t.FPS + 1e-6 }

// ---- 1. 出来事の並び ----

// eventsOf は比べる出来事の並び。events が無ければ timeline と choices から台詞と選択肢を組む（待ちは入らない）。
func eventsOf(t *Tape) []Event {
	if t.Has("events") {
		var out []Event
		for _, e := range t.Events {
			if e.Kind == "line" || e.Kind == "choice" || e.Kind == "wait" {
				out = append(out, e)
			}
		}
		return out
	}
	var out []Event
	node, seq := "", 0
	ci := 0
	pushChoices := func(until float64) {
		for ci < len(t.Choices) && t.Choices[ci].T <= until {
			ch := t.Choices[ci]
			p := ch.Picked
			s := seq
			if ch.Node != node {
				s = 0
			}
			out = append(out, Event{T: ch.T, Node: ch.Node, Kind: "choice", Seq: s, Options: ch.Options, Picked: &p})
			ci++
		}
	}
	for _, row := range t.Timeline {
		if row.Line == nil {
			continue
		}
		l, ok := t.Lines[*row.Line]
		if !ok || l.Text == nil {
			continue
		}
		pushChoices(row.T - 1e-9)
		if l.Node != node {
			node, seq = l.Node, 0
		}
		who := ""
		if l.Who != nil {
			who = *l.Who
		}
		out = append(out, Event{T: row.T, Node: node, Kind: "line", Seq: seq, Who: who, Text: *l.Text})
		seq++
	}
	pushChoices(math.Inf(1))
	return out
}

func (c *comparer) events(flow, size string, a, b *Tape) bool {
	if !a.Has("events") || !b.Has("events") {
		c.skip(flow, size, WhatEvent, "events が無いので待ちは比べていない（台詞と選択肢は timeline と choices から比べた）")
	}
	ea, eb := eventsOf(a), eventsOf(b)
	if !a.Has("events") && b.Has("events") || a.Has("events") && !b.Has("events") {
		ea, eb = eventsOf(withoutEvents(a)), eventsOf(withoutEvents(b))
	}
	tol := frameTol(a)
	for i := 0; i < len(ea) || i < len(eb); i++ {
		if i >= len(ea) || i >= len(eb) {
			e := pick(ea, eb, i)
			c.add(&Diff{Flow: flow, Size: size, Step: 1, What: WhatEvent, Node: e.Node, Seq: e.Seq, T: e.T,
				Detail: fmt.Sprintf("出来事の数が違う（前 %d・後 %d）。%s の後ろから先が無い", len(ea), len(eb), describeEvent(e))})
			return false
		}
		if why := eventDiff(ea[i], eb[i], tol); why != "" {
			c.add(&Diff{Flow: flow, Size: size, Step: 1, What: WhatEvent, Node: ea[i].Node, Seq: ea[i].Seq, T: eb[i].T,
				Detail: fmt.Sprintf("%d 番目の出来事が違う: %s（前 %s / 後 %s）", i, why, describeEvent(ea[i]), describeEvent(eb[i]))})
			return false
		}
	}
	return true
}

func withoutEvents(t *Tape) *Tape {
	cp := *t
	cp.has = map[string]bool{}
	for k, v := range t.has {
		cp.has[k] = v
	}
	delete(cp.has, "events")
	return &cp
}

func pick(a, b []Event, i int) Event {
	if i < len(a) {
		return a[i]
	}
	return b[i]
}

func eventDiff(a, b Event, tol float64) string {
	switch {
	case a.Kind != b.Kind:
		return "種類"
	case a.Node != b.Node:
		return "ノード"
	case a.Seq != b.Seq:
		return "台詞の番号"
	case a.Who != b.Who:
		return "話し手"
	case a.Text != b.Text:
		return "台詞の字"
	case strings.Join(a.Options, "\x00") != strings.Join(b.Options, "\x00"):
		return "選択肢"
	case (a.Picked == nil) != (b.Picked == nil) || a.Picked != nil && *a.Picked != *b.Picked:
		return "選んだ選択肢"
	case (a.Seconds == nil) != (b.Seconds == nil) || a.Seconds != nil && math.Abs(*a.Seconds-*b.Seconds) > tol:
		return "待ちの秒"
	}
	return ""
}

func describeEvent(e Event) string {
	switch e.Kind {
	case "line":
		return fmt.Sprintf("%s#%d「%s」", e.Node, e.Seq, clip(e.Text, 24))
	case "choice":
		p := -1
		if e.Picked != nil {
			p = *e.Picked
		}
		return fmt.Sprintf("%s#%d 選択肢 %d/%d", e.Node, e.Seq, p, len(e.Options))
	case "wait":
		s := 0.0
		if e.Seconds != nil {
			s = *e.Seconds
		}
		return fmt.Sprintf("%s#%d 待ち %g 秒", e.Node, e.Seq, s)
	}
	return e.Kind
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// placeAt は秒 t の時に出ていた台詞（ノードと番号）。承認を台詞の番号で当てるために、どの差にも付ける。
func placeAt(t *Tape, at float64) (string, int) {
	node, seq := "", -1
	for _, e := range eventsOf(t) {
		if e.T > at+1e-9 {
			break
		}
		if e.Kind == "line" {
			node, seq = e.Node, e.Seq
		}
	}
	return node, seq
}

// ---- 2. 音 ----

func (c *comparer) sounds(flow, size string, a, b *Tape) {
	if !a.Has("sounds") || !b.Has("sounds") {
		c.skip(flow, size, WhatSound, "sounds が無い")
		return
	}
	tol := frameTol(a)
	for i := 0; i < len(a.Sounds) || i < len(b.Sounds); i++ {
		if i >= len(a.Sounds) || i >= len(b.Sounds) {
			s, side := a.Sounds, "前"
			if i >= len(a.Sounds) {
				s, side = b.Sounds, "後"
			}
			node, seq := placeAt(b, s[i].T)
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatSound, Node: node, Seq: seq, T: s[i].T,
				Detail: fmt.Sprintf("音の数が違う（前 %d・後 %d）。%d 番目から先は%sにだけある（%s %s）", len(a.Sounds), len(b.Sounds), i, side, s[i].Kind, s[i].Name)})
			return
		}
		sa, sb := a.Sounds[i], b.Sounds[i]
		node, seq := placeAt(b, sb.T)
		if sa.Name != sb.Name || sa.Kind != sb.Kind {
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatSound, Node: node, Seq: seq, T: sb.T,
				Detail: fmt.Sprintf("%d 番目の音が違う（前 %s %s / 後 %s %s）。後ろの音は比べない", i, sa.Kind, sa.Name, sb.Kind, sb.Name)})
			return
		}
		if math.Abs(sa.T-sb.T) > tol {
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatSound, Node: node, Seq: seq, T: sb.T,
				Review: true, Detail: fmt.Sprintf("%s の鳴った時刻が %.3f 秒ずれた（前 %.3f / 後 %.3f・許すのは 1 フレーム）", sa.Name, sb.T-sa.T, sa.T, sb.T)})
		}
	}
}

// ---- 2. バスの音量 ----

func (c *comparer) buses(flow, size string, a, b *Tape) {
	if a.Buses == nil || b.Buses == nil {
		c.skip(flow, size, WhatBus, "buses が無い")
		return
	}
	th := c.opt.Th
	end := math.Min(a.Duration, b.Duration)
	for _, bus := range sortedKeys(a.Buses) {
		pb, ok := b.Buses[bus]
		if !ok {
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatBus, Seq: -1, Review: true, Detail: fmt.Sprintf("バス %s が新しい版に無い", bus)})
			continue
		}
		pa := a.Buses[bus]
		runFrom, worst := -1.0, 0.0
		flush := func(to float64) {
			if runFrom < 0 {
				return
			}
			node, seq := placeAt(b, runFrom)
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatBus, Node: node, Seq: seq, T: runFrom, Review: true,
				Detail: fmt.Sprintf("バス %s の音量が %.2f〜%.2f 秒で ±%g dB を超えた（最大 %.1f dB）", bus, runFrom, to, th.BusDB, worst)})
			runFrom, worst = -1, 0
		}
		steps := int(math.Floor(end/th.BusStep + 1e-9))
		for k := 0; k <= steps; k++ {
			t := float64(k) * th.BusStep
			d := dbGap(busAt(pa, t), busAt(pb, t), th.SilentDB)
			if d > th.BusDB {
				if runFrom < 0 {
					runFrom = t
				}
				worst = math.Max(worst, d)
			} else {
				flush(t)
			}
		}
		flush(end)
	}
}

func busAt(pts []BusPoint, t float64) *float64 {
	var v *float64
	for _, p := range pts {
		if p.T > t+1e-9 {
			break
		}
		v = p.DB
	}
	return v
}

// dbGap は 2 つの音量の差。無音どうしは 0、片方だけ無音なら無限。
func dbGap(a, b *float64, silent float64) float64 {
	sa := a == nil || *a <= silent
	sb := b == nil || *b <= silent
	switch {
	case sa && sb:
		return 0
	case sa || sb:
		return math.Inf(1)
	}
	return math.Abs(*a - *b)
}

// ---- 3. 問いの値 ----

func (c *comparer) probes(flow, size string, a, b *Tape) {
	ea, eb := eventsOf(a), eventsOf(b)
	if a.Has("events") && b.Has("events") && allLinesHaveProbes(ea) && allLinesHaveProbes(eb) {
		for i := range ea {
			if ea[i].Kind != "line" {
				continue
			}
			for _, name := range sortedKeys(ea[i].Probes) {
				va := scalarText(ea[i].Probes[name])
				vb, ok := eb[i].Probes[name]
				if !ok || scalarText(vb) != va {
					got := "無い"
					if ok {
						got = scalarText(vb)
					}
					c.add(&Diff{Flow: flow, Size: size, Step: 3, What: WhatProbe, Node: ea[i].Node, Seq: ea[i].Seq, T: eb[i].T,
						Detail: fmt.Sprintf("%s を出し終えた時の問い %s が違う（前 %s / 後 %s）", describeEvent(ea[i]), name, va, got)})
				}
			}
		}
		return
	}
	c.skip(flow, size, WhatProbe, "events の台詞に probes が無いので、台詞ごとの問いの値は比べていない（問いごとの値の移り変わりの順だけ比べた）")
	if !a.Has("probes") || !b.Has("probes") {
		c.skip(flow, size, WhatProbe, "probes が無い")
		return
	}
	for _, name := range sortedKeys(a.Probes) {
		pb, ok := b.Probes[name]
		if !ok {
			c.add(&Diff{Flow: flow, Size: size, Step: 3, What: WhatProbe, Seq: -1, Detail: fmt.Sprintf("問い %s が新しい版に無い（同じ名前で出す）", name)})
			continue
		}
		va, vb := valueRun(a.Probes[name]), valueRun(pb)
		for i := 0; i < len(va) || i < len(vb); i++ {
			if i < len(va) && i < len(vb) && va[i].Value == vb[i].Value {
				continue
			}
			p := pickProbe(va, vb, i)
			node, seq := placeAt(b, p.T)
			c.add(&Diff{Flow: flow, Size: size, Step: 3, What: WhatProbe, Node: node, Seq: seq, T: p.T,
				Detail: fmt.Sprintf("問い %s の値の移り変わりが %d 番目から違う（前 %s / 後 %s）", name, i, joinValues(va), joinValues(vb))})
			break
		}
	}
}

func allLinesHaveProbes(es []Event) bool {
	for _, e := range es {
		if e.Kind == "line" && e.Probes == nil {
			return false
		}
	}
	return true
}

// valueRun は続けて同じ値を 1 つにした移り変わり。
func valueRun(ps []ProbePoint) []ProbePoint {
	var out []ProbePoint
	for _, p := range ps {
		if len(out) > 0 && out[len(out)-1].Value == p.Value {
			continue
		}
		out = append(out, p)
	}
	return out
}

func pickProbe(a, b []ProbePoint, i int) ProbePoint {
	if i < len(b) {
		return b[i]
	}
	return a[i]
}

func joinValues(ps []ProbePoint) string {
	parts := make([]string, 0, len(ps))
	for _, p := range ps {
		parts = append(parts, p.Value)
	}
	return clip(strings.Join(parts, " → "), 80)
}

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
		img, err := loadNRGBA(filepath.Join(dir, f.File))
		if err == nil {
			return &Size{W: float64(img.Rect.Dx()), H: float64(img.Rect.Dy())}
		}
	}
	return nil
}

func (c *comparer) objects(flow, size string, a, b []Object, tol float64, sa, sb *Size) {
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
	ga, gb := group(a, true), group(b, false)
	for _, id := range sortedKeys(ga) {
		la, lb := ga[id], gb[id]
		if len(la) != len(lb) {
			t := la[0].From
			c.add(&Diff{Flow: flow, Size: size, Step: 4, What: WhatObject, Seq: -1, T: t, Review: true,
				Detail: fmt.Sprintf("%s の出た回数が違う（前 %d・後 %d）", id, len(la), len(lb))})
			continue
		}
		for i := range la {
			oa, ob := la[i], lb[i]
			if why := objectDiff(oa, ob, tol, sa, sb, c.opt.Th.RectPx, c.acc.rectFree(id)); why != "" {
				c.add(&Diff{Flow: flow, Size: size, Step: 4, What: WhatObject, Seq: -1, T: ob.From, Review: true, Detail: fmt.Sprintf("%s の %d 回目: %s", id, i, why)})
			}
		}
	}
	for _, id := range sortedKeys(gb) {
		if _, ok := ga[id]; !ok {
			c.add(&Diff{Flow: flow, Size: size, Step: 4, What: WhatObject, Seq: -1, T: gb[id][0].From, Review: true,
				Detail: fmt.Sprintf("%s は新しい版にだけ出る（前の id と同じなら idMap に書く）", id)})
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

func (c *comparer) frames(flow, size string, a, b []Frame, dirA, dirB string, restore bool) {
	if len(a) == 0 {
		c.skip(flow, size, WhatFrame, "前の版に frames が無い")
		return
	}
	byKey := map[string]Frame{}
	for _, f := range b {
		byKey[f.Key()] = f
	}
	for i, fa := range a {
		if fa.Layer != "world" {
			continue
		}
		fb, ok := byKey[fa.Key()]
		if !ok {
			c.add(&Diff{Flow: flow, Size: size, Step: 5, What: WhatFrame, Node: fa.Node, Seq: fa.Seq, T: fa.T, FrameKind: fa.Kind, Cmd: fa.Cmd,
				Before: filepath.Join(dirA, fa.File), Detail: "新しい版でこのコマを撮っていない（" + fa.Key() + "）"})
			continue
		}
		c.frame(flow, size, i, fa, fb, dirA, dirB, restore)
	}
}

func (c *comparer) frame(flow, size string, i int, fa, fb Frame, dirA, dirB string, restore bool) {
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
		c.add(d)
		return
	}
	delta := c.opt.Th.DoneDelta
	if fa.Backdrop3d {
		delta = c.opt.Th.Still3DDelta
	}
	st, cerr := comparePixels(ia, ib, delta, c.opt.Th.ShiftPx, "")
	c.r.Frames++
	d.Mean, d.Max, d.Within = st.Mean, st.Max, st.Within
	if cerr != nil {
		d.Detail = cerr.Error()
		c.add(d)
		return
	}
	if d.Detail = c.frameRule(fa, st, delta, restore); d.Detail == "" {
		return
	}
	d.Review = true
	if c.opt.Out != "" {
		heat := filepath.Join(c.opt.Out, "heat", fmt.Sprintf("%s_%s_%d.png", safeName(flow), safeName(size), i))
		if os.MkdirAll(filepath.Dir(heat), 0o755) == nil {
			if _, err := comparePixels(ia, ib, delta, c.opt.Th.ShiftPx, heat); err == nil {
				d.Heat = heat
			}
		}
	}
	c.add(d)
}

// frameRule は 10.3 の線を超えた時にその理由を返す（通れば空）。
func (c *comparer) frameRule(f Frame, st PixelStats, delta int, restore bool) string {
	th := c.opt.Th
	switch {
	case f.Kind == "mid" && !restore:
		if st.Mean > th.MidMean {
			return fmt.Sprintf("途中のコマの差の平均 %.2f/255 が %g/255 を超えた（%d px のずれまで許した後）", st.Mean, th.MidMean, th.ShiftPx)
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
		return
	}
	for _, name := range sortedKeys(base.Restores) {
		flow := "saves/" + name
		ra, rb := base.Restores[name], cur.Restores[name]
		add := func(detail string) {
			c.add(&Diff{Flow: flow, Size: SingleSize, Step: 6, What: WhatRestore, Node: ra.Node, Seq: ra.Seq, Detail: detail})
		}
		if rb == nil {
			add("新しい版でこのセーブを読み戻していない")
			continue
		}
		if c.acc.Restore[name] == "refused" {
			if !rb.Refused {
				add("新しい版は「版が違うので読めない」と知らせてはじめから始めるはずが、読み戻した")
			}
			continue
		}
		if ra.Refused != rb.Refused {
			add(fmt.Sprintf("読めたかが違う（前 refused=%v / 後 refused=%v）", ra.Refused, rb.Refused))
			continue
		}
		if ra.Node != rb.Node || ra.Seq != rb.Seq {
			add(fmt.Sprintf("戻った所が違う（前 %s#%d / 後 %s#%d）", ra.Node, ra.Seq, rb.Node, rb.Seq))
			continue
		}
		for _, p := range sortedKeys(ra.Probes) {
			vb, ok := rb.Probes[p]
			if !ok || scalarText(vb) != scalarText(ra.Probes[p]) {
				add(fmt.Sprintf("読み戻した時の問い %s が違う（前 %s）", p, scalarText(ra.Probes[p])))
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
		c.objects(flow, SingleSize, ra.Objects, rb.Objects, math.Inf(1), sa, sb)
		c.frames(flow, SingleSize, ra.Frames, rb.Frames, ra.Dir, rb.Dir, true)
		for _, d := range c.r.Diffs[before:] {
			d.Step = 6
		}
	}
}

// ---- 承認 ----

func (c *comparer) applyAccept(invalid map[int]bool) {
	for _, d := range c.r.Diffs {
		if d.What == WhatEvent || d.What == WhatMissing {
			continue
		}
		for i, e := range c.acc.Entries {
			if invalid[i] || !e.matches(d, c.opt.Lim) {
				continue
			}
			if !e.Approved {
				d.Pending = true
				continue
			}
			d.Accepted, d.Why = e.label(i), e.Why
			d.Pending = false
			break
		}
	}
}
