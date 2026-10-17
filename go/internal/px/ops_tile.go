package px

// タイルの op（パズルの駒: 角丸の板・白抜きの記号・割れ目）。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

func init() {
	register(&opDef{
		Name: "bevel_box", Example: `{"bevel_box": {"radius": 3.2, "inset": 1}}`, Summary: "角丸の板: 斜めの帯で 光・地・影、縁の 1px につや（光の側）と墨（影の側）、外側に墨の輪郭（格子は正方形）",
		Technique: "陰影（平らな面は 1 色・光源は左上の 1 つ）", Finish: "既存の lint banding",
		Params: []param{
			{Name: "radius", Type: tNumber, Default: 6.5, Summary: "角の丸みの半径"},
			{Name: "inset", Type: tNumber, Default: 2.0, Summary: "格子の縁からの余白"},
			{Name: "bands", Type: tPair, Default: []any{0.30, 0.72}, Summary: "光・地・影の境目（0〜1。左上の角が 0）"},
			{Name: "gloss_until", Type: tNumber, Default: 0.8, Summary: "縁のつやを置く範囲（x+y が格子の幅のこの割合まで）"},
		},
		Exempt: []checkRef{{Check: checkSprite, Rule: "corner"}},
		Whole:  true,
		Apply: func(c *ctx, a opArgs) error {
			if c.G.W != c.G.H {
				return fmt.Errorf("正方形の格子だけ（今は %d×%d）", c.G.W, c.G.H)
			}
			if err := c.NeedRamp(4); err != nil {
				return err
			}
			if sx, sy := c.LightSign(); sx != -1 || sy != -1 {
				return fmt.Errorf("光が左上（light.dir の x・y が負）の時だけ描ける")
			}
			gloss, err := c.Gloss()
			if err != nil {
				return err
			}
			b := a.pair("bands")
			c.AddRegion(c.bevelBox(a.num("radius"), a.num("inset"), b, a.num("gloss_until"), gloss))
			return nil
		},
	})
	register(&opDef{
		Name: "glyph", Example: `{"glyph": {"shape": {"disk": [8, 8, 3]}}}`, Summary: "白抜きの記号: 形をつやの色で塗り、右下へ墨の影を 1px",
		Technique: "白抜きの記号（駒の印）", Finish: "—",
		Params: []param{pShape},
		Apply: func(c *ctx, a opArgs) error {
			if err := c.NeedRamp(4); err != nil {
				return err
			}
			if !a.has("shape") && c.Part.shape == nil {
				return fmt.Errorf("形が無い（引数 shape か部品の shape を書く）")
			}
			em, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			gloss, err := c.Gloss()
			if err != nil {
				return err
			}
			ink, _ := c.RampAt(0)
			g := c.G
			for y := g.H - 1; y >= 0; y-- {
				for x := g.W - 1; x >= 0; x-- {
					if em[y][x] && !em.At(min(x+1, g.W-1), min(y+1, g.H-1)) {
						c.PutAbs(x+1, y+1, ink)
					}
				}
			}
			c.FillAbs(em, gloss)
			c.AddRegion(em)
			return nil
		},
	})
	register(&opDef{
		Name: "crack", Example: `{"crack": {"points": [[3, 8], [6, 9], [9, 7]]}}`, Summary: "親（on）の塊の割れ目: 墨の 1px と、その右下に切り口のつや 1px",
		Technique: "タイルの割れ目", Finish: "—",
		Params: []param{pVecPoints},
		Apply: func(c *ctx, a opArgs) error {
			if err := c.NeedRamp(4); err != nil {
				return err
			}
			m := c.OnRegion()
			if m == nil {
				return fmt.Errorf("割る板が無い（部品に \"on\": 板の部品 id を書く）")
			}
			gloss, err := c.Gloss()
			if err != nil {
				return err
			}
			ink, _ := c.RampAt(0)
			cells := lerpCells(vecs(a.get("points")))
			seen := map[pxlib.Pt]bool{}
			for _, q := range cells {
				seen[q] = true
			}
			for _, q := range cells {
				for _, o := range [2]pxlib.Pt{{X: 1}, {Y: 1}} {
					n := pxlib.Pt{X: q.X + o.X, Y: q.Y + o.Y}
					if !seen[n] && m.At(n.X+c.ox, n.Y+c.oy) {
						c.Put(n.X, n.Y, gloss)
					}
				}
			}
			for _, q := range cells {
				if m.At(q.X+c.ox, q.Y+c.oy) {
					c.Put(q.X, q.Y, ink)
				}
			}
			return nil
		},
	})
}

// bevelBox は角丸の板を描き、板の塊（輪郭を除く）を返す。
func (c *ctx) bevelBox(radius, inset float64, bands [2]float64, glossUntil float64, gloss pxlib.Key) pxlib.Mask {
	g := c.G
	r := c.Ramp()
	size := g.W
	half := float64(size) / 2
	m := pxlib.MaskOf(size, size, func(x, y float64) float64 {
		qx := math.Abs(x-half) - (half - inset) + radius
		qy := math.Abs(y-half) - (half - inset) + radius
		return hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - radius
	})
	span := 2.0 * float64(size-1)
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			if !m[y][x] {
				continue
			}
			t := float64(x+y) / span
			col := r[1]
			if t < bands[0] {
				col = r[3]
			} else if t < bands[1] {
				col = r[2]
			}
			// 帯の境目のギザだけを市松で整える（幅を持った帯にはしない）
			if (math.Abs(t-bands[0]) < 0.012 || math.Abs(t-bands[1]) < 0.012) && (x+y)%2 == 0 {
				col = r[2]
			}
			c.PutAbs(x, y, col)
		}
	}
	d := m.DistFromEdge()
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			if !m[y][x] || d[y][x] != 1 {
				continue
			}
			up, left := !m.At(x, y-1), !m.At(x-1, y)
			down, right := !m.At(x, y+1), !m.At(x+1, y)
			if (up || left) && !(down || right) {
				if float64(x+y) < float64(size)*glossUntil {
					c.PutAbs(x, y, gloss)
				} else {
					c.PutAbs(x, y, r[3])
				}
			} else if down || right {
				c.PutAbs(x, y, r[0])
			}
		}
	}
	c.FillAbs(m.Outline(), r[0])
	return m
}
