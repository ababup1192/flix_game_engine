package px

// 材質のレシピ: 部品に "material": "metal" か {"metal": {"gloss": 1}} と書くと、既存の op の並びに開いて
// 部品の ops の前に差し込む（新しい描き方は持たない。手順を覚えずに名前だけで呼ぶ高い段の口）。
// 引数は材質ごとに 2〜3 個まで。値はどれも仮置き（大きい見比べで決め直す）。

import (
	"fmt"
	"sort"
)

// materialDef は材質 1 つ。Expand は検査済みの引数から op の JSON の並びを作る。
type materialDef struct {
	Name, Summary, Technique, Finish string
	Params                           []param
	Expand                           func(a map[string]any) []any
}

var materials = map[string]*materialDef{}

func registerMaterial(m *materialDef) { materials[m.Name] = m }

func allMaterials() []*materialDef {
	out := make([]*materialDef, 0, len(materials))
	for _, m := range materials {
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func op1(name string, args map[string]any) any { return map[string]any{name: args} }

func anyNum(v any) float64 { f, _ := v.(float64); return f }

// material は部品の "material" を読んで op の並びに開く。
func (r *reader) material(v any, where string, refs map[string]any) []opCall {
	name, given := "", map[string]any{}
	switch t := v.(type) {
	case string:
		name = t
	case map[string]any:
		if len(t) != 1 {
			r.bad(where, "\"metal\" か {\"metal\": {引数}} で書く")
			return nil
		}
		for k, a := range t {
			name = k
			g, ok := a.(map[string]any)
			if !ok {
				r.bad(where, "引数はオブジェクトで書く（無ければ {}）")
				return nil
			}
			given = g
		}
	default:
		r.bad(where, "\"metal\" か {\"metal\": {引数}} で書く")
		return nil
	}
	m, ok := materials[name]
	if !ok {
		names := make([]string, 0, len(materials))
		for _, d := range allMaterials() {
			names = append(names, d.Name)
		}
		r.bad(where, "知らない材質 %q（%s）", name, joinNames(names))
		return nil
	}
	args := map[string]any{}
	for _, p := range m.Params {
		val, has := given[p.Name]
		if !has {
			args[p.Name] = p.Default
			continue
		}
		if err := checkType(p, val); err != nil {
			r.bad(where+"."+name, "引数 %s は %v", p.Name, err)
			return nil
		}
		args[p.Name] = val
	}
	for k := range given {
		if _, ok := args[k]; !ok {
			r.bad(where+"."+name, "知らない引数 %q", k)
			return nil
		}
	}
	var out []opCall
	for i, e := range m.Expand(args) {
		call, err := parseOpCall(e, fmt.Sprintf("%s(%s)[%d]", where, name, i), refs)
		if err != nil {
			r.probs = append(r.probs, problem{Msg: err.Error()})
			continue
		}
		out = append(out, call)
	}
	return out
}

func init() {
	pSeed := param{Name: "seed", Type: tInt, Default: 0.0, Summary: "散らし方の番号"}
	registerMaterial(&materialDef{
		Name: "metal", Summary: "光の向きでランプの全段をベタの帯に塗り（段の差が大きい）、光の角に 1〜2px のつや、部品の色の輪郭",
		Technique: "金属のつや", Finish: "lint orphan（つやは例外）・pillow",
		Params: []param{
			{Name: "gloss", Type: tInt, Default: 2.0, Summary: "つやの画素の数（0 で付けない）"},
			{Name: "outline", Type: tBool, Default: true, Summary: "sel_out で縁取る"},
		},
		Expand: func(a map[string]any) []any {
			out := []any{op1("gradient_fill", map[string]any{"field": "light", "band": 0.0})}
			if g := anyNum(a["gloss"]); g > 0 {
				out = append(out, op1("glint", map[string]any{"size": g}))
			}
			if a["outline"] == true {
				out = append(out, op1("sel_out", map[string]any{}))
			}
			return out
		},
	})
	registerMaterial(&materialDef{
		Name: "stone", Summary: "光の向きの階調（境目だけディザ）に、暗い段の斑の塊とひびを散らす",
		Technique: "質感（岩・レンガ）", Finish: "既存の lint orphan",
		Params: []param{
			{Name: "cell", Type: tInt, Default: 4.0, Summary: "斑の間隔（小さいほど密）"},
			pSeed,
		},
		Expand: func(a map[string]any) []any {
			seed := anyNum(a["seed"])
			return []any{
				op1("gradient_fill", map[string]any{"field": "light", "band": 0.25}),
				op1("scatter_clusters", map[string]any{"colors": []any{"shade"}, "cell": a["cell"], "seed": seed}),
				op1("scatter_clusters", map[string]any{"colors": []any{"ink"}, "kind": "crack", "cell": anyNum(a["cell"]) * 2, "seed": seed + 1, "keep": 0.5}),
				op1("sel_out", map[string]any{}),
			}
		},
	})
	registerMaterial(&materialDef{
		Name: "wood", Summary: "光の向きの階調に、横の木目の筋と節を散らす",
		Technique: "質感（木）", Finish: "既存の lint orphan",
		Params: []param{
			{Name: "cell", Type: tInt, Default: 3.0, Summary: "木目の間隔"},
			pSeed,
		},
		Expand: func(a map[string]any) []any {
			seed := anyNum(a["seed"])
			return []any{
				op1("gradient_fill", map[string]any{"field": "light", "band": 0.25, "from": 1.0}),
				op1("scatter_clusters", map[string]any{"colors": []any{"shade"}, "kind": "line", "cell": a["cell"], "seed": seed}),
				op1("scatter_clusters", map[string]any{"colors": []any{"ink"}, "cell": anyNum(a["cell"]) * 3, "seed": seed + 2, "keep": 0.3}),
				op1("sel_out", map[string]any{}),
			}
		},
	})
	registerMaterial(&materialDef{
		Name: "cloth", Summary: "大きい面を 2 段のベタで塗り（最暗の段は使わない）、折り目の線を 1 段暗く、部品の色の輪郭",
		Technique: "陰影（平らな面は 1 色）・布の折り目", Finish: "lint pillow・light-dir",
		Params: []param{
			{Name: "fold", Type: tPoints, Summary: "折り目の折れ線 [[x, y], ...]（省くと折り目なし）"},
		},
		Expand: func(a map[string]any) []any {
			out := []any{op1("gradient_fill", map[string]any{"field": "light", "band": 0.0, "from": 1.0})}
			if f, ok := a["fold"].([]any); ok && len(f) >= 2 {
				out = append(out, op1("shade_step", map[string]any{"by": -1.0, "shape": map[string]any{"path": f, "width": 1.0}}))
			}
			return append(out, op1("sel_out", map[string]any{}))
		},
	})
	registerMaterial(&materialDef{
		Name: "foliage", Summary: "葉の塊: 階調に明るい段と暗い段の小さな塊を散らし、部品の色の輪郭。sway で揺らせる",
		Technique: "質感（葉）・塊と孤立 1px・アニメ（揺れ）", Finish: "既存の lint orphan・anim",
		Params: []param{
			{Name: "cell", Type: tInt, Default: 3.0, Summary: "葉の塊の間隔"},
			pSeed,
			{Name: "sway", Type: tNumber, Default: 0.0, Summary: "揺れの幅（px。0 で揺らさない）"},
		},
		Expand: func(a map[string]any) []any {
			seed := anyNum(a["seed"])
			out := []any{
				op1("gradient_fill", map[string]any{"field": "light", "band": 0.5}),
				op1("scatter_clusters", map[string]any{"colors": []any{"light"}, "cell": a["cell"], "seed": seed}),
				op1("scatter_clusters", map[string]any{"colors": []any{"shade"}, "cell": a["cell"], "seed": seed + 3}),
				op1("sel_out", map[string]any{}),
			}
			if s := anyNum(a["sway"]); s > 0 {
				out = append(out, op1("sway", map[string]any{"amp": s}))
			}
			return out
		},
	})
}
