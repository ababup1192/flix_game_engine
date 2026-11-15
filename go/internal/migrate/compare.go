package migrate

import (
	"encoding/json"
	"fmt"
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
	// Images は前の版の記録が無い時に人が見る新しい版のコマの全部（nobaseline）。
	Images []string `json:"images,omitempty"`
	// Accepted・AcceptKind・Why・EntryImages は当たった承認の名前・種類・理由・承認に添えた絵。
	Accepted    string   `json:"accepted,omitempty"`
	AcceptKind  string   `json:"acceptKind,omitempty"`
	Why         string   `json:"why,omitempty"`
	EntryImages []string `json:"entryImages,omitempty"`
	Pending     bool     `json:"pending,omitempty"`
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

// Result は突き合わせの全部。Applied は当てた読み替えと決め（問いの値の読み替え・読まないセーブ）、
// Unused はどの差にも当たらなかった承認。
type Result struct {
	Diffs     []*Diff     `json:"diffs"`
	Skips     []Skip      `json:"skips"`
	Uncovered []Uncovered `json:"uncovered"`
	Problems  []string    `json:"problems"`
	Notes     []string    `json:"notes"`
	Applied   []string    `json:"applied"`
	Unused    []string    `json:"unused"`
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
	r := &Result{Diffs: []*Diff{}, Skips: []Skip{}, Uncovered: []Uncovered{}, Problems: []string{}, Notes: []string{},
		Applied: []string{}, Unused: []string{}, Stopped: []string{}}
	if opt.Out != "" {
		// WhyNot: 前の回の差の色の図を残さない — 直した後の頁に、もう当たらない図が混ざって読み違える。
		_ = os.RemoveAll(filepath.Join(opt.Out, "heat"))
	}
	c := &comparer{r: r, acc: acc, opt: opt, rewrites: map[string]int{}}
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
			if base.Flows[flow][size] != nil {
				continue
			}
			t := cur.Flows[flow][size]
			d := &Diff{Flow: flow, Size: size, What: WhatNoBaseline, Seq: -1, Detail: "前の版の記録が無い（新しい版の絵を人が頁で見て nobaseline で承認する）"}
			for _, f := range t.Frames {
				d.Images = append(d.Images, filepath.Join(t.Dir, f.File))
			}
			c.add(d)
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
	c.reportRewrites()
	r.Strict = opt.Strict
	r.Passed = r.Open(opt.Strict) == 0 && len(r.Problems) == 0
	return r
}

type comparer struct {
	r        *Result
	acc      *Accept
	opt      Options
	rewrites map[string]int // 「問い mode: "Nvl" → "nvl"」→ 読み替えた回数
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
	place := func(at float64) (string, int) { return placeAt(b, at) }
	c.objects(flow, size, a.Objects, b.Objects, frameTol(a), screenOf(a), screenOf(b), place)
	c.frames(flow, size, frameSide{a.Frames, a.Dir, visitsOf(a)}, frameSide{b.Frames, b.Dir, visitsOf(b)}, false)
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
	if a.Has("events") != b.Has("events") {
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

// soundOrder は同じフレームで鳴った音を (フレーム, kind, name) で並べ直した写し。
// WhyNot: 書いた順のまま比べない — 同じフレームの中の順は命令を当てる順で決まり、移行で替わっても聞こえ方は同じ。
func soundOrder(t *Tape) []Sound {
	out := append([]Sound(nil), t.Sounds...)
	frame := func(s Sound) int { return int(math.Round(s.T * t.FPS)) }
	sort.SliceStable(out, func(i, j int) bool {
		fi, fj := frame(out[i]), frame(out[j])
		if fi != fj {
			return fi < fj
		}
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].Name < out[j].Name
	})
	return out
}

func (c *comparer) sounds(flow, size string, a, b *Tape) {
	if !a.Has("sounds") || !b.Has("sounds") {
		c.skip(flow, size, WhatSound, "sounds が無い")
		return
	}
	sa, sb := soundOrder(a), soundOrder(b)
	tol := frameTol(a)
	for i := 0; i < len(sa) || i < len(sb); i++ {
		if i >= len(sa) || i >= len(sb) {
			s, side := sa, "前"
			if i >= len(sa) {
				s, side = sb, "後"
			}
			node, seq := placeAt(b, s[i].T)
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatSound, Node: node, Seq: seq, T: s[i].T,
				Detail: fmt.Sprintf("音の数が違う（前 %d・後 %d）。%d 番目から先は%sにだけある（%s %s）", len(sa), len(sb), i, side, s[i].Kind, s[i].Name)})
			return
		}
		x, y := sa[i], sb[i]
		node, seq := placeAt(b, y.T)
		if x.Name != y.Name || x.Kind != y.Kind {
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatSound, Node: node, Seq: seq, T: y.T,
				Detail: fmt.Sprintf("%d 番目の音が違う（前 %s %s / 後 %s %s）。後ろの音は比べない", i, x.Kind, x.Name, y.Kind, y.Name)})
			return
		}
		if math.Abs(x.T-y.T) > tol {
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatSound, Node: node, Seq: seq, T: y.T, Review: true,
				Detail: fmt.Sprintf("%s の鳴った時刻が %.3f 秒ずれた（前 %.3f / 後 %.3f・許すのは 1 フレーム）", x.Name, y.T-x.T, x.T, y.T)})
		}
	}
}

// ---- 2. バスの音量 ----

func (c *comparer) buses(flow, size string, a, b *Tape) {
	if a.Buses == nil || b.Buses == nil {
		c.skip(flow, size, WhatBus, "buses が無い")
		return
	}
	for _, bus := range sortedKeys(b.Buses) {
		if _, ok := a.Buses[bus]; !ok {
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatBus, Seq: -1, Review: true, Detail: fmt.Sprintf("バス %s は新しい版にだけある", bus)})
		}
	}
	end := math.Min(busEnd(a), busEnd(b))
	for _, bus := range sortedKeys(a.Buses) {
		pb, ok := b.Buses[bus]
		if !ok {
			c.add(&Diff{Flow: flow, Size: size, Step: 2, What: WhatBus, Seq: -1, Review: true, Detail: fmt.Sprintf("バス %s が新しい版に無い", bus)})
			continue
		}
		c.bus(flow, size, bus, a.Buses[bus], pb, end, b)
	}
}

// busEnd は音量を比べる最後の秒（duration が無ければ記録の最後の時刻）。
func busEnd(t *Tape) float64 {
	if t.Duration > 0 {
		return t.Duration
	}
	end := 0.0
	for _, pts := range t.Buses {
		for _, p := range pts {
			end = math.Max(end, p.T)
		}
	}
	if n := len(t.Timeline); n > 0 {
		end = math.Max(end, t.Timeline[n-1].T)
	}
	return end
}

func (c *comparer) bus(flow, size, bus string, pa, pb []BusPoint, end float64, b *Tape) {
	th := c.opt.Th
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
		if d > th.BusDB+1e-9 {
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

// dbGap は 2 つの音量の差。どちらも silent で下に止めてから比べる（無音は silent と同じ）。
// WhyNot: 片方だけ無音の時に無限の差にしない — フェードの終わりで -60 を跨ぐ 1 コマの食い違いが、毎回迷った差になる。
func dbGap(a, b *float64, silent float64) float64 {
	floor := func(v *float64) float64 {
		if v == nil {
			return silent
		}
		return math.Max(*v, silent)
	}
	return math.Abs(floor(a) - floor(b))
}

// ---- 3. 問いの値 ----

// mapProbe は前の版の問いの値を probeMap で読み替える（読み替えたら数える）。
func (c *comparer) mapProbe(name string, raw json.RawMessage) string {
	text := scalarText(raw)
	to, ok := c.acc.mapProbe(name, text)
	if !ok {
		return text
	}
	c.rewrites[fmt.Sprintf("問い %s: %s → %s", name, text, to)]++
	return to
}

func (c *comparer) reportRewrites() {
	for _, k := range sortedKeys(c.rewrites) {
		c.r.Applied = append(c.r.Applied, fmt.Sprintf("probeMap で前の版の値を読み替えた: %s（%d 回）", k, c.rewrites[k]))
	}
	for _, name := range sortedKeys(c.acc.ProbeMap) {
		for _, from := range sortedKeys(c.acc.ProbeMap[name]) {
			text, _ := json.Marshal(from)
			to, _ := json.Marshal(c.acc.ProbeMap[name][from])
			if c.rewrites[fmt.Sprintf("問い %s: %s → %s", name, text, to)] == 0 {
				c.r.Unused = append(c.r.Unused, fmt.Sprintf("probeMap の %s: %s はどの値にも当たらなかった", name, from))
			}
		}
	}
}

func (c *comparer) probes(flow, size string, a, b *Tape) {
	ea, eb := eventsOf(a), eventsOf(b)
	if a.Has("events") && b.Has("events") && allLinesHaveProbes(ea) && allLinesHaveProbes(eb) {
		for i := range ea {
			if ea[i].Kind != "line" {
				continue
			}
			for _, name := range sortedKeys(ea[i].Probes) {
				va := c.mapProbe(name, ea[i].Probes[name])
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
		mapped := make([]ProbePoint, len(a.Probes[name]))
		for i, p := range a.Probes[name] {
			mapped[i] = ProbePoint{T: p.T, Value: c.mapProbe(name, json.RawMessage(p.Value))}
		}
		va, vb := valueRun(mapped), valueRun(pb)
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
