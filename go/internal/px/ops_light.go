package px

// 光と階調の op: 光の向きだけで決まる明るさの場（directional）と、場をランプの段に落とす gradient_fill・
// 光の源から丸く減っていくにじみ（glow。昇格ループ 3 周目: 城下町の窓・街灯・夕日と路地のネオン・HUD）。
// 段の境目は 4×4 の Bayer で混ぜ、band で混ぜる幅を選ぶ（1 = 段の間を全部ディザ・0 = ベタの帯）。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

var bayer4 = [4][4]float64{{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}}

// bayer は 4×4 の Bayer の閾値（0〜1）。
func bayer(x, y int) float64 { return (bayer4[y&3][x&3] + 0.5) / 16 }

// ditherAt は格子の画素 (x, y) を、Bayer を引く座標にする: 部品の at（と use の at）を引いて、ディザの網目を部品と一緒に動かす
// （画面に固定すると、at でずらすコマの間で境目の画素がちらつく）。at が 0 の部品は格子の座標のまま。
func (c *ctx) ditherAt(x, y int) (int, int) { return x - c.ox, y - c.oy }

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
		v := dot(float64(p.X), float64(p.Y), lx, ly)
		lo, hi = math.Min(lo, v), math.Max(hi, v)
	}
	span := hi - lo
	if span == 0 {
		span = 1
	}
	return func(x, y int) float64 { return (dot(float64(x), float64(y), lx, ly) - lo) / span }
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
			{Name: "band", Type: tNumber, Default: 1.0, Summary: "段の境目のうちディザで混ぜる割合（1 = 全部・0.25 = 境目だけ・0 = ベタの帯）", Lo: bound(0), Hi: bound(1)},
			{Name: "from", Type: tInt, Default: 0.0, Summary: "使う一番暗い段", Lo: bound(0), Hi: bound(15)},
			{Name: "to", Type: tInt, Default: -1.0, Summary: "使う一番明るい段（-1 で最明）", Lo: bound(-1), Hi: bound(15)},
			{Name: "invert", Type: tBool, Default: false, Summary: "明暗を返す"},
			{Name: "per", Type: tString, Default: "part", Summary: "明るさの場を作る単位: part（塊全体で 1 つ）・copy（部品の scroll の写しごと。格子の外へはみ出した写しも写しの全体で 1 つの場）"},
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
			groups := []pxlib.Mask{m}
			switch a.str("per") {
			case "part":
			case "copy":
				if c.Part.copyOf == nil || a.has("shape") {
					return fmt.Errorf("per: copy は scroll のある部品の塊に当てる（shape を書かない）")
				}
				groups = c.Part.copyOf()
			default:
				return fmt.Errorf("per は part か copy")
			}
			sub := ramp[from : to+1]
			for _, g := range groups {
				f, err := c.fieldOf(a.str("field"), g)
				if err != nil {
					return err
				}
				for _, p := range g.Points() {
					v := f(p.X, p.Y)
					if a.bool("invert") {
						v = 1 - v
					}
					dx, dy := c.ditherAt(p.X, p.Y)
					c.PutAbs(p.X, p.Y, sub[rampIndex(v, dx, dy, len(sub), a.num("band"))])
				}
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
			{Name: "band", Type: tNumber, Default: 0.0, Summary: "段の境目のディザの幅（0 = ベタの帯）", Lo: bound(0), Hi: bound(8)},
			{Name: "from", Type: tInt, Default: 0.0, Summary: "使う一番暗い段", Lo: bound(0), Hi: bound(15)},
			{Name: "to", Type: tInt, Default: -1.0, Summary: "使う一番明るい段（-1 で最明）", Lo: bound(-1), Hi: bound(15)},
		},
		Checks: []checkRef{{Check: checkPillow}, {Check: checkLightDir}},
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
			ramp = ramp[from : to+1]
			if len(ramp) < 2 {
				return fmt.Errorf("2 段以上のランプが要る（from・to の間が 1 段）")
			}
			f := directional(m, c.Spec.Light.Dir[0], c.Spec.Light.Dir[1])
			for _, p := range m.Points() {
				dx, dy := c.ditherAt(p.X, p.Y)
				c.PutAbs(p.X, p.Y, ramp[rampIndex(f(p.X, p.Y), dx, dy, len(ramp), a.num("band"))])
			}
			if a.has("shape") {
				c.AddRegion(m)
			}
			return nil
		},
	})
	register(&opDef{
		Name: "glow", Example: `{"glow": {"centers": [[8, 8]], "r": 6, "power": 1.5}}`,
		Summary: "光の源（centers の点）から丸く減っていくにじみ: 中心からの距離 d（r で割る）で明るさ (1 − d)^power をランプの段に Bayer で落とし、" +
			"今の色より明るい段の所だけ塗る（重なったにじみは明るい方が残る。ランプの 0 段 = 光の無い色は置かない）。加算の光の層は先に 0 段で fill してから当てる",
		Technique: "光のにじみ（窓・街灯・夕日・ネオン。中心から減り、外は地のまま）", Finish: "lint banding",
		Params: []param{
			{Name: "centers", Type: tVecs, Required: true, Min: 1, Summary: "光の源の点 [[x, y], ...]（小数も可。画素 (x, y) の中心は x + 0.5）"},
			{Name: "r", Type: tNumber, Required: true, Summary: "にじみの半径（縦。横は r × xscale）", Lo: bound(0.5), Hi: bound(1024)},
			{Name: "power", Type: tNumber, Default: 1.0, Summary: "減り方（1 = まっすぐ・大きいほど芯に寄る）", Lo: bound(0.05), Hi: bound(16)},
			{Name: "xscale", Type: tNumber, Default: 1.0, Summary: "横の伸び（1.5 で横に長い楕円のにじみ）", Lo: bound(0.05), Hi: bound(16)},
			{Name: "from", Type: tInt, Default: 0.0, Summary: "使う一番暗い段（この段は光の無い色で、置かない）", Lo: bound(0), Hi: bound(15)},
			{Name: "to", Type: tInt, Default: -1.0, Summary: "使う一番明るい段（-1 で最明）", Lo: bound(-1), Hi: bound(15)},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "banding"}},
		Apply: func(c *ctx, a opArgs) error {
			ramp := c.Ramp()
			from, to := a.int("from"), a.int("to")
			if to < 0 {
				to += len(ramp)
			}
			if from < 0 || to >= len(ramp) || from >= to {
				return fmt.Errorf("from・to がランプ（%d 段）の外か 1 段だけ（光の無い段と光る段の 2 段以上が要る）", len(ramp))
			}
			sub := ramp[from : to+1]
			idx := map[pxlib.Key]int{}
			for i, k := range sub {
				if _, dup := idx[k]; !dup {
					idx[k] = i
				}
			}
			r, power, xs := a.num("r"), a.num("power"), a.num("xscale")
			painted := pxlib.NewMask(c.G.W, c.G.H)
			for _, ctr := range vecs(a.get("centers")) {
				cx, cy := ctr[0]+float64(c.ox), ctr[1]+float64(c.oy)
				for y := int(cy - r - 1); y < int(cy+r+2); y++ {
					for x := int(cx - float64(r*xs) - 1); x < int(cx+float64(r*xs)+2); x++ {
						d := hypot((float64(x)+0.5-cx)/xs, float64(y)+0.5-cy) / r
						if d >= 1 || !c.G.In(x, y) {
							continue
						}
						t, err := crPow(1-d, power)
						if err != nil {
							return err
						}
						dx, dy := c.ditherAt(x, y)
						i := rampIndex(t, dx, dy, len(sub), 1)
						old, ok := idx[c.G.At(x, y)]
						if !ok || c.G.At(x, y) == pxlib.Clear {
							old = -1
						}
						if i == 0 || i <= old {
							continue
						}
						c.PutAbs(x, y, sub[i])
						painted[y][x] = true
					}
				}
			}
			c.AddRegion(painted)
			return nil
		},
	})
}
