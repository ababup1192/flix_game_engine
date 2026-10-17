package px

// 光と階調の op: 光の向きだけで決まる明るさの場（directional）と、場をランプの段に落とす gradient_fill。
// 段の境目は 4×4 の Bayer で混ぜ、band で混ぜる幅を選ぶ（1 = 段の間を全部ディザ・0 = ベタの帯）。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

var bayer4 = [4][4]float64{{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}}

// bayer は 4×4 の Bayer の閾値（0〜1）。
func bayer(x, y int) float64 { return (bayer4[y&3][x&3] + 0.5) / 16 }

// rampIndex は明るさ v（0 = 暗・1 = 明）を n 段のどれかに落とす。段の間は Bayer で混ぜる。
// band（0〜1）は段の境目のうち混ぜる割合: 端数 f を (f − (0.5 − band/2)) / band で 0〜1 に詰め直してから閾値と比べる。
func rampIndex(v float64, x, y, n int, band float64) int {
	v = math.Min(1, math.Max(0, v))
	pos := v * float64(n-1)
	i := int(pos)
	f := pos - float64(i)
	if band < 1 {
		if band > 0 {
			lo := 0.5 - band/2
			f = math.Min(1, math.Max(0, (f-lo)/band))
		} else if f >= 0.5 {
			f = 1
		} else {
			f = 0
		}
	}
	if i+1 < n && f > bayer(x, y) {
		i++
	}
	return i
}

// directional は塊の外接箱の中で、光の向きへの投影を 0〜1 に詰め直した明るさの場（光の来る角が 1）。
// 縁からの距離を使わないので、どの縁も暗い pillow にならない。
func directional(m pxlib.Mask, lx, ly float64) func(x, y int) float64 {
	pts := m.Points()
	if len(pts) == 0 {
		return func(int, int) float64 { return 0.5 }
	}
	lo, hi := math.Inf(1), math.Inf(-1)
	for _, p := range pts {
		v := float64(p.X)*lx + float64(p.Y)*ly
		lo, hi = math.Min(lo, v), math.Max(hi, v)
	}
	span := hi - lo
	if span == 0 {
		span = 1
	}
	return func(x, y int) float64 { return (float64(x)*lx + float64(y)*ly - lo) / span }
}

// fieldOf は gradient_fill の明るさの場。
func (c *ctx) fieldOf(kind string, m pxlib.Mask) (func(x, y int) float64, error) {
	pts := m.Points()
	if len(pts) == 0 {
		return func(int, int) float64 { return 0.5 }, nil
	}
	x0, y0, x1, y1 := pxlib.BBox(pts)
	span := func(a, b int) float64 { return math.Max(1, float64(b-a)) }
	switch kind {
	case "light":
		return directional(m, c.Spec.Light.Dir[0], c.Spec.Light.Dir[1]), nil // 光が左上なら左上が 1
	case "x":
		return func(x, _ int) float64 { return float64(x-x0) / span(x0, x1) }, nil
	case "y":
		return func(_, y int) float64 { return 1 - float64(y-y0)/span(y0, y1) }, nil
	case "radial":
		cx, cy := float64(x0+x1)/2, float64(y0+y1)/2
		r := math.Max(1, math.Hypot(float64(x1-x0), float64(y1-y0))/2)
		return func(x, y int) float64 { return 1 - math.Hypot(float64(x)-cx, float64(y)-cy)/r }, nil
	}
	return nil, fmt.Errorf("field は light・x・y・radial")
}

func init() {
	register(&opDef{
		Name: "gradient_fill", Example: `{"gradient_fill": {"field": "light", "band": 0.25}}`,
		Summary:   "塊を明るさの場（光の向き・x・y・radial）でランプの段に塗る。段の境目は Bayer で混ぜ、band で混ぜる幅を選ぶ",
		Technique: "陰影（光源は 1 つ・平らな面は 1 色）・ディザ（タイルパターン）", Finish: "lint pillow・light-dir・banding",
		Params: []param{
			pShape,
			{Name: "field", Type: tString, Default: "light", Summary: "明るさの場: light（光の向き。directional）・y（上が明るい）・x（右が明るい）・radial（中心が明るい）"},
			{Name: "band", Type: tNumber, Default: 1.0, Summary: "段の境目のうちディザで混ぜる割合（1 = 全部・0.25 = 境目だけ・0 = ベタの帯）"},
			{Name: "from", Type: tInt, Default: 0.0, Summary: "使う一番暗い段"},
			{Name: "to", Type: tInt, Default: -1.0, Summary: "使う一番明るい段（-1 で最明）"},
			{Name: "invert", Type: tBool, Default: false, Summary: "明暗を返す"},
		},
		Checks: []checkRef{{Check: checkPillow}, {Check: checkLightDir}, {Check: checkSprite, Rule: "banding"}},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			ramp := c.Ramp()
			from, to := a.int("from"), a.int("to")
			if to < 0 {
				to += len(ramp)
			}
			if from < 0 || to >= len(ramp) || from > to {
				return fmt.Errorf("from・to がランプ（%d 段）の外", len(ramp))
			}
			f, err := c.fieldOf(a.str("field"), m)
			if err != nil {
				return err
			}
			sub := ramp[from : to+1]
			for _, p := range m.Points() {
				v := f(p.X, p.Y)
				if a.bool("invert") {
					v = 1 - v
				}
				c.PutAbs(p.X, p.Y, sub[rampIndex(v, p.X, p.Y, len(sub), a.num("band"))])
			}
			if a.has("shape") {
				c.AddRegion(m)
			}
			return nil
		},
	})
	register(&opDef{
		Name: "directional", Example: `{"directional": {}}`,
		Summary:   "光の向きだけで塗る陰（gradient_fill の field light・band 0 の短い書き方。縁を一様に暗くしない）",
		Technique: "陰影（光源は 1 つ（左上）。縁を一様に暗くしない）", Finish: "lint pillow・light-dir",
		Params: []param{
			pShape,
			{Name: "band", Type: tNumber, Default: 0.0, Summary: "段の境目のディザの幅（0 = ベタの帯）"},
		},
		Checks: []checkRef{{Check: checkPillow}, {Check: checkLightDir}},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			ramp := c.Ramp()
			if len(ramp) < 2 {
				return fmt.Errorf("2 段以上のランプが要る")
			}
			f := directional(m, c.Spec.Light.Dir[0], c.Spec.Light.Dir[1])
			for _, p := range m.Points() {
				c.PutAbs(p.X, p.Y, ramp[rampIndex(f(p.X, p.Y), p.X, p.Y, len(ramp), a.num("band"))])
			}
			if a.has("shape") {
				c.AddRegion(m)
			}
			return nil
		},
	})
}
