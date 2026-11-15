package migrate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// AcceptFile は既定の承認のファイルの名前（new の記録のフォルダの隣に置く）。
const AcceptFile = "migrate-accept.json"

// 承認の種類（10.2）。
const (
	KindIntended   = "intended"
	KindSystematic = "systematic"
	KindNoBaseline = "nobaseline"
)

// AnyFlow は systematic の flow を省いた時と同じ「どの flow にも当てる」印。
const AnyFlow = "*"

// Limits は承認の上限（10.2 の (b)）。
type Limits struct {
	MaxRangeSec    float64 // 1 件の時刻の範囲
	MaxPerFlow     int     // 1 本の flow の件数（同じ why はまとめて 1 件）
	SystematicMean float64 // systematic で通せる 1 枚の画素の差の平均（/255）
}

// DefaultLimits は 10.2 の値。
func DefaultLimits() Limits {
	return Limits{MaxRangeSec: 3, MaxPerFlow: 20, SystematicMean: 6}
}

// Entry は migrate-accept.json の entries の 1 件。
// 当てる所は Node と Seq（台詞の番号）か、From と To（秒の範囲）のどちらか。Size が空ならどの大きさにも当てる。
// Images は承認のファイルのフォルダからの相対パスで、頁でその承認の所に並べる。
type Entry struct {
	ID       string   `json:"id"`
	Kind     string   `json:"kind"`
	Flow     string   `json:"flow"`
	Size     string   `json:"size,omitempty"`
	What     string   `json:"what"`
	Node     string   `json:"node,omitempty"`
	Seq      *int     `json:"seq,omitempty"`
	From     *float64 `json:"from,omitempty"`
	To       *float64 `json:"to,omitempty"`
	Command  string   `json:"command,omitempty"`
	Why      string   `json:"why"`
	Images   []string `json:"images,omitempty"`
	Approved bool     `json:"approved"`
}

// CoverageEntry は通らない命令の行を承認する 1 件。
type CoverageEntry struct {
	Yarn     string `json:"yarn"`
	Line     int    `json:"line"`
	Why      string `json:"why"`
	Approved bool   `json:"approved"`
}

// Accept は migrate-accept.json の全部。
// IDMap は前の版の objects の id → 新しい版の id、RectFree は矩形を比べず数と区間だけを見る id（粒・揺れ）、
// Restore はセーブの名前 → "refused"（新しい版は読まずに知らせる）、
// ProbeMap は問いの名前 → {前の版の値: 新しい版の値}（問いの値の言い方が替わった物。前の値を読み替えてから比べる）。
type Accept struct {
	IDMap    map[string]string            `json:"idMap,omitempty"`
	RectFree []string                     `json:"rectFree,omitempty"`
	Restore  map[string]string            `json:"restore,omitempty"`
	ProbeMap map[string]map[string]string `json:"probeMap,omitempty"`
	Entries  []Entry                      `json:"entries,omitempty"`
	Coverage []CoverageEntry              `json:"coverage,omitempty"`
	dir      string
}

// LoadAccept は承認のファイルを読む。無ければ空。
func LoadAccept(path string) (*Accept, error) {
	a := &Accept{dir: filepath.Dir(path)}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return a, nil
	}
	if err != nil {
		return nil, err
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(a); err != nil {
		return nil, fmt.Errorf("%s を読めない: %w", path, err)
	}
	return a, nil
}

// Validate は上限と書き方の誤りを返す。誤りのある件は承認に使わない（invalid に入る）。
func (a *Accept) Validate(lim Limits) (problems []string, invalid map[int]bool) {
	invalid = map[int]bool{}
	whys := map[string]map[string]bool{}
	for i, e := range a.Entries {
		bad := func(format string, args ...any) {
			problems = append(problems, fmt.Sprintf("承認 %s: ", e.label(i))+fmt.Sprintf(format, args...))
			invalid[i] = true
		}
		if why := e.check(lim); why != "" {
			bad("%s", why)
			continue
		}
		if e.Kind != KindIntended {
			continue
		}
		if whys[e.Flow] == nil {
			whys[e.Flow] = map[string]bool{}
		}
		whys[e.Flow][e.Why] = true
	}
	for _, flow := range sortedKeys(whys) {
		if n := len(whys[flow]); n > lim.MaxPerFlow {
			problems = append(problems, fmt.Sprintf("承認の上限: flow %s の intended が %d 件（同じ why はまとめて数えて %d 件まで）", flow, n, lim.MaxPerFlow))
			for i, e := range a.Entries {
				if e.Flow == flow && e.Kind == KindIntended {
					invalid[i] = true
				}
			}
		}
	}
	for i, e := range a.Coverage {
		if e.Why == "" {
			problems = append(problems, fmt.Sprintf("承認 coverage[%d]（%s:%d）: why が要る", i, e.Yarn, e.Line))
		}
	}
	sort.Strings(problems)
	return problems, invalid
}

// check は 1 件の書き方の誤り（無ければ空）。
func (e Entry) check(lim Limits) string {
	switch e.Kind {
	case KindIntended, KindSystematic, KindNoBaseline:
	default:
		return fmt.Sprintf("kind は intended・systematic・nobaseline のどれか（%q）", e.Kind)
	}
	if e.Why == "" {
		return "why が要る"
	}
	if e.Kind == KindSystematic {
		switch {
		case e.Command == "":
			return "systematic は理由を作った命令（command）を名指しする"
		case e.What != WhatFrame:
			return "systematic で通せるのはコマ（what: frame）だけ"
		}
		return ""
	}
	if e.Flow == "" || e.Flow == AnyFlow {
		return "flow が要る（flow を省けるのは systematic だけ）"
	}
	if e.Kind == KindNoBaseline {
		return ""
	}
	if e.What == "" || e.What == WhatEvent || e.What == WhatMissing {
		return "what が要る（event と missing は承認できない。出来事の並びの違いと撮れていない記録は直す）"
	}
	byRange := e.From != nil && e.To != nil
	byLine := e.Node != "" && e.Seq != nil
	if byRange == byLine {
		return "当てる所は node と seq か、from と to のどちらか 1 つ"
	}
	if byRange && (*e.To < *e.From || *e.To-*e.From > lim.MaxRangeSec) {
		return fmt.Sprintf("時刻の範囲は %g 秒まで（%g〜%g）", lim.MaxRangeSec, *e.From, *e.To)
	}
	return ""
}

func (e Entry) label(i int) string {
	if e.ID != "" {
		return e.ID
	}
	return fmt.Sprintf("entries[%d]", i)
}

// matches は差がこの件に当たるか（承認の有無は見ない）。
func (e Entry) matches(d *Diff, lim Limits) bool {
	anyFlow := e.Kind == KindSystematic && (e.Flow == "" || e.Flow == AnyFlow)
	if !anyFlow && e.Flow != d.Flow || e.Size != "" && e.Size != d.Size {
		return false
	}
	switch e.Kind {
	case KindNoBaseline:
		return d.What == WhatNoBaseline
	case KindSystematic:
		// WhyNot: 撮っていない途中のコマ（After が空）を系統の違いで通さない — 差の大きさが測れず、上限の 6/255 が効かない。
		return d.What == WhatFrame && d.FrameKind == "mid" && d.After != "" && d.Cmd == e.Command && d.Mean <= lim.SystematicMean
	}
	if e.What != d.What {
		return false
	}
	if e.From != nil && e.To != nil {
		return d.T >= *e.From && d.T <= *e.To
	}
	return d.Node == e.Node && e.Seq != nil && d.Seq == *e.Seq
}

func (a *Accept) rectFree(id string) bool {
	for _, x := range a.RectFree {
		if x == id {
			return true
		}
	}
	return false
}

func (a *Accept) mapID(id string) string {
	if to, ok := a.IDMap[id]; ok {
		return to
	}
	return id
}

// mapProbe は前の版の問いの値（比べる字）を probeMap で読み替えた字を返す。当たらなければ false。
func (a *Accept) mapProbe(name, text string) (string, bool) {
	m := a.ProbeMap[name]
	if m == nil {
		return "", false
	}
	var s string
	if json.Unmarshal([]byte(text), &s) != nil {
		return "", false
	}
	to, ok := m[s]
	if !ok {
		return "", false
	}
	b, _ := json.Marshal(to)
	return string(b), true
}

// applyAccept は差に承認を当て、どの差にも当たらなかった承認を Unused に出す。
func (c *comparer) applyAccept(invalid map[int]bool) {
	hits := make([]int, len(c.acc.Entries))
	for _, d := range c.r.Diffs {
		if d.What == WhatEvent || d.What == WhatMissing {
			continue
		}
		for i, e := range c.acc.Entries {
			if invalid[i] || !e.matches(d, c.opt.Lim) {
				continue
			}
			hits[i]++
			if !e.Approved {
				d.Pending = true
				continue
			}
			d.Accepted, d.AcceptKind, d.Why, d.Pending = e.label(i), e.Kind, e.Why, false
			d.EntryImages = c.entryImages(i, e)
			break
		}
	}
	for i, e := range c.acc.Entries {
		if !invalid[i] && hits[i] == 0 {
			c.r.Unused = append(c.r.Unused, fmt.Sprintf("承認 %s（%s）はどの差にも当たらなかった", e.label(i), e.Why))
		}
	}
	open := map[string]bool{}
	for _, u := range c.r.Uncovered {
		open[fmt.Sprintf("%s:%d", u.Yarn, u.Line)] = true
	}
	if c.opt.NoCoverage {
		return
	}
	for _, e := range c.acc.Coverage {
		if !open[fmt.Sprintf("%s:%d", e.Yarn, e.Line)] {
			c.r.Unused = append(c.r.Unused, fmt.Sprintf("coverage の承認 %s:%d は通る行（か台本に無い行）を指している", e.Yarn, e.Line))
		}
	}
}

// entryImages は承認に添えた絵の道（無い絵は注意に出して落とす）。
func (c *comparer) entryImages(i int, e Entry) []string {
	var out []string
	for _, p := range e.Images {
		abs := p
		if !filepath.IsAbs(p) {
			abs = filepath.Join(c.acc.dir, p)
		}
		if fileExists(abs) {
			out = append(out, abs)
			continue
		}
		note := fmt.Sprintf("承認 %s の images の %s が無い", e.label(i), p)
		if !containsString(c.r.Notes, note) {
			c.r.Notes = append(c.r.Notes, note)
		}
	}
	return out
}

func containsString(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
