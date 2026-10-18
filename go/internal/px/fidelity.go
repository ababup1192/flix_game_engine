package px

// 塗りの細かさの軸 fidelity（checkset-design §9）: 0 = low-bit 〜 1 = hi-bit。
//
//   - 出どころは上から 1 つ: 門の画風の fidelity（free の冊は files の fidelity）→ 機種（px.json の styles の fidelity）→ 不明。
//     担当は spec に書けない（宣言から値を選ばせない）。機種の方が門より高ければ px.decl.fidelity-over。
//   - 軸で動く検査は checkDef.Fidelity。範囲 [lo, hi) は px.json の fidelityRanges。範囲の外では消さずに advice へ下げ、
//     applied の skipped に「fidelity:0.2」と理由を出す。gate の重さの検査と decl.* は範囲を持てない（テストが止める）。
//   - 閾値は数 1 つか折れ線 {"by": "fidelity"|"size", "at": [[x, v], …]}（knob）。pxRules.at が平たい pxRules を作る。
//
// 0.42.0 は仕組みだけ: 範囲は全部 [0, 1)・閾値は今の数のまま（0.43.0 で採用済みの昼と夜の 2 点で決め直す）。

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
)

// fidelityOf は 1 つの spec（target の slot）の塗りの細かさと出どころ。
type fidelityOf struct {
	Value     float64
	Known     bool
	By        string // 例 "門 night"・"機種 nes"・"不明"
	RampSteps [2]int
	Dither    string
	Over      *float64 // 機種の方が高い時の機種の値（px.decl.fidelity-over）
	Look      string   // 門の画風の名前（報告だけ）
}

// resolveFidelity は門（無ければ nil）と slot と機種（無ければ nil）から fidelity を決める。
func resolveFidelity(g *colorGate, slot string, machine *pxStyle) fidelityOf {
	var out fidelityOf
	if g != nil {
		name, st, f := g.styleOf(slot)
		out.Look = name
		switch {
		case st != nil && st.Fidelity != nil:
			out.Value, out.Known, out.By = *st.Fidelity, true, "門 "+name
			out.RampSteps, out.Dither = st.RampSteps, st.Dither
		case f != nil && f.Style == freeStyle && f.Fidelity != nil:
			out.Value, out.Known, out.By = *f.Fidelity, true, "門 free"
		}
	}
	if machine != nil && machine.Fidelity != nil {
		if !out.Known {
			out.Value, out.Known, out.By = *machine.Fidelity, true, "機種 "+machine.name
		} else if *machine.Fidelity > out.Value {
			v := *machine.Fidelity
			out.Over = &v // 機種の方が細かい = 門の画風から外れる
		}
		if out.Dither == "" {
			out.Dither = machine.Dither
		}
	}
	if !out.Known {
		out.By = "不明"
	}
	return out
}

// styleOf は slot の画風の名前と、画風（free なら nil）と files の行（無ければ nil）。
func (g *colorGate) styleOf(slot string) (string, *gateStyle, *gateFile) {
	f := g.Files[slot]
	name := g.Default
	if f != nil {
		name = f.Style
	}
	if name == freeStyle {
		return name, nil, f
	}
	return name, g.Styles[name], f
}

// fidelityRange は軸で動く検査の当たる範囲 [Lo, Hi)。
type fidelityRange struct{ Lo, Hi float64 }

func (r fidelityRange) has(f float64) bool { return f >= r.Lo && (f < r.Hi || r.Hi >= 1 && f <= 1) }

// opposedChecks は軸の両端で入れ替わる組（A の hi = B の lo で、重ならず隙間も無い）。0.42.0 はまだ無い。
var opposedChecks = [][2]checkName{}

// ---------------------------------------------------------------- knob（閾値の折れ線）

// knob は閾値 1 つ（数か、fidelity か大きさで動く折れ線）。
type knob struct {
	By string       `json:"by"`
	At [][2]float64 `json:"at"`
}

// value は x での値（int の欄は段: x 以下で最後の点。float は線形）。
func (k knob) value(x float64, isInt bool) float64 {
	pts := k.At
	if x <= pts[0][0] {
		return pts[0][1]
	}
	for i := 1; i < len(pts); i++ {
		if x <= pts[i][0] {
			if isInt {
				if x == pts[i][0] {
					return pts[i][1]
				}
				return pts[i-1][1]
			}
			t := (x - pts[i-1][0]) / (pts[i][0] - pts[i-1][0])
			return pts[i-1][1] + t*(pts[i][1]-pts[i-1][1])
		}
	}
	return pts[len(pts)-1][1]
}

// readKnobs は px.json の中の折れ線の欄を読む（数の欄はそのまま）。点は 3 つまで・x は昇順で両端を含む。
func readKnobs(data []byte) (map[string]knob, map[string]json.RawMessage, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, nil, err
	}
	knobs := map[string]knob{}
	for name, v := range raw {
		if len(v) == 0 || v[0] != '{' {
			continue
		}
		var k knob
		if json.Unmarshal(v, &k) != nil || k.By == "" {
			continue // styles・why など、折れ線でないオブジェクト
		}
		lo, hi := 0.0, 1.0
		if k.By == "size" {
			lo, hi = 1, float64(maxGrid)
		} else if k.By != "fidelity" {
			return nil, nil, fmt.Errorf("%s.by は fidelity か size", name)
		}
		if len(k.At) < 2 || len(k.At) > 3 || k.At[0][0] != lo || k.At[len(k.At)-1][0] != hi {
			return nil, nil, fmt.Errorf("%s.at は [[x, 値], …] の 2〜3 点（x は %v から %v まで昇順で両端を含む）", name, lo, hi)
		}
		for i := 1; i < len(k.At); i++ {
			if k.At[i][0] <= k.At[i-1][0] {
				return nil, nil, fmt.Errorf("%s.at の x が昇順でない", name)
			}
		}
		knobs[name] = k
	}
	return knobs, raw, nil
}

// intRuleKeys は段で動かす（線形にしない）欄。
var intRuleKeys = map[string]bool{"flatRunRepeat": true, "flatRunStraight": true, "flatRunPer": true, "pillowMinArea": true,
	"lightDirMinArea": true, "blackOutlineMaxSize": true, "highlightMinColors": true, "valueBlobsMin": true, "valueBlobsMax": true,
	"tileVariantEdge": true, "outerAAMax": true}

// at は fidelity（不明なら 0.5）と絵の長い辺での閾値。折れ線が無ければ自分を返す。
func (r *pxRules) at(f fidelityOf, size int) *pxRules {
	if len(r.knobs) == 0 {
		return r
	}
	x := 0.5
	if f.Known {
		x = f.Value
	}
	key := fmt.Sprintf("%.4f|%d", x, size)
	if c, ok := r.cache[key]; ok {
		return c
	}
	m := map[string]json.RawMessage{}
	for k, v := range r.raw {
		m[k] = v
	}
	for name, k := range r.knobs {
		in := x
		if k.By == "size" {
			in = float64(size)
		}
		v := k.value(in, intRuleKeys[name])
		if intRuleKeys[name] {
			v = math.Round(v)
		}
		m[name], _ = json.Marshal(v)
	}
	data, _ := json.Marshal(m)
	out := &pxRules{}
	_ = json.Unmarshal(data, out)
	out.knobs, out.raw, out.cache, out.ranges = nil, nil, nil, r.ranges
	r.cache[key] = out
	return out
}

// fidelityRangeOf は検査の当たる範囲（px.json の fidelityRanges。無ければ全域）。
func (r *pxRules) fidelityRangeOf(c checkName) fidelityRange {
	if rg, ok := r.ranges[string(c)]; ok {
		return rg
	}
	return fidelityRange{0, 1}
}

// readRanges は fidelityRanges を読み、登録した軸で動く検査とだけ突き合わせる。
func readRanges(raw map[string]json.RawMessage) (map[string]fidelityRange, error) {
	out := map[string]fidelityRange{}
	v, ok := raw["fidelityRanges"]
	if !ok {
		return out, nil
	}
	var m map[string][2]float64
	if err := json.Unmarshal(v, &m); err != nil {
		return nil, fmt.Errorf("fidelityRanges は 検査の名前 → [lo, hi]: %v", err)
	}
	names := make([]string, 0, len(m))
	for n := range m {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		ck, ok := checks[checkName(n)]
		if !ok || !ck.Fidelity {
			return nil, fmt.Errorf("fidelityRanges の %q は軸で動く検査でない（checkDef.Fidelity）", n)
		}
		rg := m[n]
		if rg[0] < 0 || rg[1] > 1 || rg[0] >= rg[1] {
			return nil, fmt.Errorf("fidelityRanges.%s は 0 ≤ lo < hi ≤ 1", n)
		}
		out[n] = fidelityRange{rg[0], rg[1]}
	}
	return out, nil
}
