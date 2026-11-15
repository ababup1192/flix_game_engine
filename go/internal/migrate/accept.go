package migrate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
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

// Limits は承認の上限（10.2 の (b)）。
type Limits struct {
	MaxRangeSec      float64 // 1 件の時刻の範囲
	MaxPerFlow       int     // 1 本の flow の件数（同じ why はまとめて 1 件）
	SystematicMean   float64 // systematic で通せる 1 枚の画素の差の平均（/255）
	CoverageRequired bool
}

// DefaultLimits は 10.2 の値。
func DefaultLimits() Limits {
	return Limits{MaxRangeSec: 3, MaxPerFlow: 20, SystematicMean: 6, CoverageRequired: true}
}

// Entry は migrate-accept.json の entries の 1 件。
// 当てる所は Node と Seq（台詞の番号）か、From と To（秒の範囲）のどちらか。Size が空ならどの大きさにも当てる。
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
// Restore はセーブの名前 → "refused"（新しい版は読まずに知らせる）。
type Accept struct {
	IDMap    map[string]string `json:"idMap,omitempty"`
	RectFree []string          `json:"rectFree,omitempty"`
	Restore  map[string]string `json:"restore,omitempty"`
	Entries  []Entry           `json:"entries,omitempty"`
	Coverage []CoverageEntry   `json:"coverage,omitempty"`
}

// LoadAccept は承認のファイルを読む。無ければ空。
func LoadAccept(path string) (*Accept, error) {
	a := &Accept{}
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
		switch e.Kind {
		case KindIntended, KindSystematic, KindNoBaseline:
		default:
			bad("kind は intended・systematic・nobaseline のどれか（%q）", e.Kind)
			continue
		}
		if e.Flow == "" || e.Why == "" {
			bad("flow と why が要る")
			continue
		}
		if e.Kind == KindNoBaseline {
			continue
		}
		if e.What == "" || e.What == WhatEvent || e.What == WhatMissing {
			bad("what が要る（event と missing は承認できない。出来事の並びの違いと撮れていない記録は直す）")
			continue
		}
		if e.Kind == KindSystematic {
			if e.Command == "" {
				bad("systematic は理由を作った命令（command）を名指しする")
			}
			if e.What != WhatFrame {
				bad("systematic で通せるのはコマ（what: frame）だけ")
			}
			continue
		}
		byRange := e.From != nil && e.To != nil
		byLine := e.Node != "" && e.Seq != nil
		if byRange == byLine {
			bad("当てる所は node と seq か、from と to のどちらか 1 つ")
			continue
		}
		if byRange && (*e.To < *e.From || *e.To-*e.From > lim.MaxRangeSec) {
			bad("時刻の範囲は %g 秒まで（%g〜%g）", lim.MaxRangeSec, *e.From, *e.To)
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
	sort.Strings(problems)
	return problems, invalid
}

func (e Entry) label(i int) string {
	if e.ID != "" {
		return e.ID
	}
	return fmt.Sprintf("entries[%d]", i)
}

// matches は差がこの件に当たるか（承認の有無は見ない）。
func (e Entry) matches(d *Diff, lim Limits) bool {
	if e.Flow != d.Flow || (e.Size != "" && e.Size != d.Size) {
		return false
	}
	switch e.Kind {
	case KindNoBaseline:
		return d.What == WhatNoBaseline
	case KindSystematic:
		return d.What == WhatFrame && d.FrameKind == "mid" && d.Cmd == e.Command && d.Mean <= lim.SystematicMean
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
