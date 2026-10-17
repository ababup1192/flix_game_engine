package px

// 動きの op: 元の絵（部品の画素）を、コマの番号（frames の並び）に応じて書き換える。
// 量はどれも sin でコマごとに回り、最後のコマから最初へつながる（輪が閉じる）。
// 動かした後の欠けや孤立した画素は pixel_perfect と orphan の検査、コマ列は anim の検査で見る。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// animOps は動きの op（これを使うスプライトには anim の検査を自動でかける）。
var animOps = map[string]bool{"sway": true, "bob": true, "squash": true, "palette_cycle": true, "wave_shift": true}

// wave はコマの位相の sin（phase は 1 周 = 1.0 で足す）。
func (c *ctx) wave(phase float64) float64 {
	n := max(1, c.FrameCount)
	return math.Sin(2 * math.Pi * (float64(c.FrameIndex)/float64(n) + phase))
}

// partBox は今の部品の画素の外接箱（画素が無ければ ok = false）。動きの手は箱を先に決めて閉じ込め、
// 子の部品にも同じ箱で当てる（子の画素の箱で測り直すと、親と子で揺れ方がずれる）。
func (c *ctx) partBox() (x0, y0, x1, y1 int, ok bool) {
	var pts []pxlib.Pt
	if c.Part.isPost {
		pts = c.G.Opaque().Points()
	} else {
		pts = c.Part.written.Points()
	}
	if len(pts) == 0 {
		return 0, 0, 0, 0, false
	}
	x0, y0, x1, y1 = pxlib.BBox(pts)
	return x0, y0, x1, y1, true
}

// swayPixels は行ごとに横へずらした画素を返す。根元（root の端の行 y0 か y1）は 0、先端ほど amp·t^curve·sin。
func swayPixels(src map[pxlib.Pt]pxlib.Key, y0, y1 int, amp, curve, s float64, fromTop bool, rowWave float64, frameTurn float64) map[pxlib.Pt]pxlib.Key {
	hgt := math.Max(1, float64(y1-y0))
	out := map[pxlib.Pt]pxlib.Key{}
	for p, k := range src {
		t := math.Max(0, math.Min(1, float64(y1-p.Y)/hgt))
		if fromTop {
			t = math.Max(0, math.Min(1, float64(p.Y-y0)/hgt))
		}
		v := s
		if rowWave != 0 {
			v = math.Sin(2 * math.Pi * (frameTurn - float64(rowWave*t)))
		}
		dx := int(math.Round(amp * math.Pow(t, curve) * v))
		out[pxlib.Pt{X: p.X + dx, Y: p.Y}] = k
	}
	return out
}

// squashPixels は中心 (cx, cy) を基準に、横 sx・縦 sy 倍に伸び縮みさせる（近い画素を拾う）。
func squashPixels(src map[pxlib.Pt]pxlib.Key, sx, sy, cx, cy float64, w, h int) map[pxlib.Pt]pxlib.Key {
	if len(src) == 0 || sx <= 0 || sy <= 0 {
		return src
	}
	out := map[pxlib.Pt]pxlib.Key{}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			srcX := cx + (float64(x)+0.5-cx)/sx
			srcY := cy + (float64(y)+0.5-cy)/sy
			q := pxlib.Pt{X: int(math.Floor(srcX)), Y: int(math.Floor(srcY))}
			if k, ok := src[q]; ok {
				out[pxlib.Pt{X: x, Y: y}] = k
			}
		}
	}
	return out
}

// waveShift は塊 m の中の色を、行ごとに横へ shift px 回す（塊の外形は動かさず、模様＝波頭だけが流れる）。
// ripple は行が 1 つ下がるごとに足すずれ（0 で全部の行が同じ向き・同じ量）。
func waveShift(g *pxlib.Grid, m pxlib.Mask, shift int, ripple float64) map[pxlib.Pt]pxlib.Key {
	out := map[pxlib.Pt]pxlib.Key{}
	for y := 0; y < g.H; y++ {
		var xs []int
		for x := 0; x < g.W; x++ {
			if m.At(x, y) && g.At(x, y) != pxlib.Clear {
				xs = append(xs, x)
			}
		}
		n := len(xs)
		if n < 2 {
			continue
		}
		d := shift + int(math.Round(float64(ripple*float64(y))))
		d = ((d % n) + n) % n
		for i, x := range xs {
			from := xs[((i-d)%n+n)%n]
			out[pxlib.Pt{X: x, Y: y}] = g.At(from, y)
		}
	}
	return out
}

func init() {
	pPhase := param{Name: "phase", Type: tNumber, Default: 0.0, Summary: "位相のずれ（1 周 = 1.0。部品ごとに揺れを遅らせる）", Lo: bound(-1), Hi: bound(1)}
	register(&opDef{
		Name: "sway", Example: `{"sway": {"amp": 1}}`,
		Summary:   "部品の画素を行ごとに横へずらす（根元 0・先端ほど大きく・コマごとに sin）。木・草・旗・髪の揺れ",
		Technique: "アニメ（揺れ。根元を止めて先端を遅らせる）", Finish: "lint orphan・anim（pop・loop）。欠けは pixel_perfect で整える",
		Params: []param{
			{Name: "amp", Type: tNumber, Default: 1.0, Summary: "先端のずれの最大（px）", Lo: bound(-16), Hi: bound(16)},
			{Name: "curve", Type: tNumber, Default: 1.0, Summary: "根元から先端への効き方（1 = まっすぐ・2 = 先端だけ大きく）", Lo: bound(0.1), Hi: bound(8)},
			pPhase,
			{Name: "root", Type: tString, Default: "bottom", Summary: "止める端: bottom（木・草）・top（髪・吊るした旗）"},
			{Name: "ripple", Type: tNumber, Default: 0.0, Summary: "根元から先端へ遅れて伝わる波の数（0 で全体が同じ向き。旗は 0.5 ほど）", Lo: bound(0), Hi: bound(8)},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			root := a.str("root")
			if root != "bottom" && root != "top" {
				return fmt.Errorf("root は bottom か top")
			}
			_, y0, _, y1, ok := c.partBox()
			if !ok {
				return nil
			}
			n := float64(max(1, c.FrameCount))
			turn := float64(c.FrameIndex)/n + a.num("phase")
			amp, curve, s, ripple := a.num("amp"), a.num("curve"), c.wave(a.num("phase")), a.num("ripple")
			c.moveBy(func(src map[pxlib.Pt]pxlib.Key) map[pxlib.Pt]pxlib.Key {
				return swayPixels(src, y0, y1, amp, curve, s, root == "top", ripple, turn)
			})
			return nil
		},
	})
	register(&opDef{
		Name: "bob", Example: `{"bob": {"amp": 1}}`,
		Summary:   "部品を上下に動かす（コマごとに -amp·sin。呼吸・浮遊・歩きの上下）",
		Technique: "アニメ（溜め・弾み）", Finish: "anim（bob・ground）",
		Params: []param{{Name: "amp", Type: tNumber, Default: 1.0, Summary: "上下の幅（px）", Lo: bound(-16), Hi: bound(16)}, pPhase},
		Apply: func(c *ctx, a opArgs) error {
			dy := int(math.Round(-a.num("amp") * c.wave(a.num("phase"))))
			c.moveBy(func(src map[pxlib.Pt]pxlib.Key) map[pxlib.Pt]pxlib.Key {
				out := map[pxlib.Pt]pxlib.Key{}
				for p, k := range src {
					out[pxlib.Pt{X: p.X, Y: p.Y + dy}] = k
				}
				return out
			})
			return nil
		},
	})
	register(&opDef{
		Name: "squash", Example: `{"squash": {"amount": 0.2}}`,
		Summary:   "部品を縦に縮めて横に伸ばす（縦 1 − amount·sin・横 1 + amount·sin。足元を止める）。着地・弾み・呼吸",
		Technique: "アニメ（つぶしと伸ばし）", Finish: "anim（area・ground）",
		Params: []param{
			{Name: "amount", Type: tNumber, Default: 0.2, Summary: "伸び縮みの強さ（0〜0.5 が目安）", Lo: bound(0), Hi: bound(0.9)},
			pPhase,
			{Name: "anchor", Type: tString, Default: "bottom", Summary: "止める所: bottom（足元）・center（真ん中）"},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			anc := a.str("anchor")
			if anc != "bottom" && anc != "center" {
				return fmt.Errorf("anchor は bottom か center")
			}
			x0, y0, x1, y1, ok := c.partBox()
			if !ok {
				return nil
			}
			s := c.wave(a.num("phase"))
			am := a.num("amount")
			cx, cy := float64(x0+x1+1)/2, float64(y0+y1+1)/2
			if anc == "bottom" {
				cy = float64(y1 + 1)
			}
			sx, sy := 1+float64(am*s), 1-float64(am*s)
			w, h := c.G.W, c.G.H
			c.moveBy(func(src map[pxlib.Pt]pxlib.Key) map[pxlib.Pt]pxlib.Key {
				return squashPixels(src, sx, sy, cx, cy, w, h)
			})
			return nil
		},
	})
	register(&opDef{
		Name: "palette_cycle", Example: `{"palette_cycle": {"colors": ["shade", "mid", "light"]}}`,
		Summary:   "塊の中で colors の段をコマごとに step ずつ回す（光のきらめきの補助。水の流れは wave_shift の方が見比べで勝った）",
		Technique: "アニメ（パレットの回転。光のきらめき）", Finish: "anim（pop）",
		Params: []param{
			pShape,
			{Name: "colors", Type: tRows, Required: true, Min: 2, Summary: "回す色の並び（2 色以上）"},
			{Name: "step", Type: tInt, Default: 1.0, Summary: "1 コマで進む段数（負で逆回り）", Lo: bound(-16), Hi: bound(16)},
		},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			cols, err := c.colorList(a.rows("colors"))
			if err != nil {
				return err
			}
			n := len(cols)
			shift := ((c.FrameIndex*a.int("step"))%n + n) % n
			for _, p := range m.Points() {
				k := c.G.At(p.X, p.Y)
				for i, ck := range cols {
					if ck == k {
						c.PutAbs(p.X, p.Y, cols[(i+shift)%n])
						break
					}
				}
			}
			return nil
		},
	})
	register(&opDef{
		Name: "wave_shift", Example: `{"wave_shift": {"speed": 1}}`,
		Summary:   "塊の外形は動かさず、中の模様（波頭・流れ）を行ごとにコマごとに speed px 横へ回す。水・滝・流れる雲の既定",
		Technique: "アニメ（水の波頭を 1px ずつずらす。見比べで palette_cycle に勝った）", Finish: "anim（pop・loop）。輪が閉じるようにコマの数 × speed を塊の幅に合わせる",
		Params: []param{
			pShape,
			{Name: "speed", Type: tInt, Default: 1.0, Summary: "1 コマで流れる px（負で左へ）", Lo: bound(-8), Hi: bound(8)},
			{Name: "ripple", Type: tNumber, Default: 0.0, Summary: "行が 1 つ下がるごとに足すずれ（0 で全部の行がそろって流れる・0.5 で斜めの波）", Lo: bound(-4), Hi: bound(4)},
		},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			for p, k := range waveShift(c.G, m, c.FrameIndex*a.int("speed"), a.num("ripple")) {
				c.PutAbs(p.X, p.Y, k)
			}
			return nil
		},
	})
}
