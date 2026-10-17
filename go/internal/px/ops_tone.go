package px

// 影の形を 1 段重ねる・明度差を測る op。明るさは Oklab の L（人の目の明るさに近い）で比べる。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// measure は contrast が測った 1 件。
type measure struct {
	Part, Against string
	D, Min        float64
	At            pxlib.Pt
}

// meanL は塊の画素の L の平均（透明と色票に無い色は数えない）。
func (c *ctx) meanL(m pxlib.Mask) (float64, pxlib.Pt, bool) {
	sum, n := 0.0, 0
	var at pxlib.Pt
	for _, p := range m.Points() {
		l, ok := pxlib.Lightness(c.hexOf[c.G.At(p.X, p.Y)])
		if !ok {
			continue
		}
		if n == 0 {
			at = p
		}
		sum += l
		n++
	}
	if n == 0 {
		return 0, at, false
	}
	return sum / float64(n), at, true
}

func init() {
	register(&opDef{
		Name: "shade_mask", Example: `{"shade_mask": {"of": "base", "offset": [1, 1]}}`,
		Summary:   "別の部品 of の塊を光と反対へ offset ずらした形で、今の部品に塗ってある色を by 段ずらす（手前の物が落とす影）",
		Technique: "1 段ずつ塗る（Aseprite の Shading ink）・影の形を重ねる", Finish: "—",
		Params: []param{
			{Name: "of", Type: tString, Required: true, Summary: "影を落とす部品の id（この部品より前の列）"},
			{Name: "by", Type: tInt, Default: -1.0, Summary: "ずらす段数（負で暗く）", Lo: bound(-8), Hi: bound(8)},
			{Name: "offset", Type: tPoint, Summary: "影のずれ [dx, dy]（省くと光と反対へ 1px）"},
		},
		Apply: func(c *ctx, a opArgs) error {
			src, ok := c.parts[a.str("of")]
			if !ok {
				return fmt.Errorf("部品 %q が無い", a.str("of"))
			}
			ramp := c.Ramp()
			if len(ramp) == 0 {
				return fmt.Errorf("部品にランプが無い")
			}
			sx, sy := c.LightSign()
			d := pxlib.Pt{X: -sx, Y: -sy}
			if a.has("offset") {
				d = a.point("offset")
			}
			from := src.Region()
			own := c.Region()
			for _, p := range from.Points() {
				x, y := p.X+d.X, p.Y+d.Y
				if !own.At(x, y) || from.At(x, y) {
					continue
				}
				k := c.G.At(x, y)
				if to := shadeStep(ramp, k, a.int("by")); to != k {
					c.PutAbs(x, y, to)
				}
			}
			return nil
		},
	})
	register(&opDef{
		Name: "contrast", Example: `{"contrast": {"against": "base"}}`,
		Summary:   "今の部品と相手（部品 against か地の色）の明るさ（Oklab の L）の平均の差を測るだけ（描かない）",
		Technique: "背景の奥行き（遠いほど明度差が小さい）・主役と背景を分ける", Finish: "lint value-sep",
		Params: []param{
			{Name: "against", Type: tString, Summary: "相手の部品 id（省くと light.ground の地の色）"},
			{Name: "min", Type: tNumber, Default: 0.0, Summary: "差の下限（0 で bin/lint-rules/px.json の valueSepMin）", Lo: bound(0), Hi: bound(1)},
		},
		Checks: []checkRef{{Check: checkValueSep}},
		Apply: func(c *ctx, a opArgs) error {
			la, at, ok := c.meanL(c.Region().Union(c.Part.written))
			if !ok {
				return fmt.Errorf("測る画素が無い（contrast は塗った後に置く）")
			}
			var lb float64
			name := a.str("against")
			if name != "" {
				p, ok := c.parts[name]
				if !ok {
					return fmt.Errorf("部品 %q が無い", name)
				}
				if lb, _, ok = c.meanL(p.Region().Union(p.written)); !ok {
					return fmt.Errorf("部品 %q に測る画素が無い", name)
				}
			} else {
				g := groundHex(c.Spec.Light.Ground, map[string]string{})
				if h, ok := c.hexOf[pxlib.Key(c.Spec.Light.Ground)]; ok {
					g = h
				}
				var ok bool
				if lb, ok = pxlib.Lightness(g); !ok {
					return fmt.Errorf("相手が無い（against か light.ground を書く）")
				}
				name = "地"
			}
			c.measures = append(c.measures, measure{Part: c.Part.Part.ID, Against: name, D: math.Abs(la - lb), Min: a.num("min"), At: at})
			return nil
		},
	})
}
