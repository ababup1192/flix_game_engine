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
var animOps = map[string]bool{"sway": true, "bob": true, "squash": true, "palette_cycle": true}

// wave はコマの位相の sin（phase は 1 周 = 1.0 で足す）。
func (c *ctx) wave(phase float64) float64 {
	n := max(1, c.FrameCount)
	return math.Sin(2 * math.Pi * (float64(c.FrameIndex)/float64(n) + phase))
}

// swayPixels は行ごとに横へずらした画素を返す。根元（root の端の行）は 0、先端ほど amp·t^curve·sin。
func swayPixels(src map[pxlib.Pt]pxlib.Key, amp, curve, s float64, fromTop bool, rowWave float64, frameTurn float64) map[pxlib.Pt]pxlib.Key {
	if len(src) == 0 {
		return src
	}
	pts := make([]pxlib.Pt, 0, len(src))
	for p := range src {
		pts = append(pts, p)
	}
	_, y0, _, y1 := pxlib.BBox(pts)
	hgt := math.Max(1, float64(y1-y0))
	out := map[pxlib.Pt]pxlib.Key{}
	for p, k := range src {
		t := float64(y1-p.Y) / hgt
		if fromTop {
			t = float64(p.Y-y0) / hgt
		}
		v := s
		if rowWave != 0 {
			v = math.Sin(2 * math.Pi * (frameTurn - rowWave*t))
		}
		dx := int(math.Round(amp * math.Pow(t, curve) * v))
		out[pxlib.Pt{X: p.X + dx, Y: p.Y}] = k
	}
	return out
}

// squashPixels は塊を足元（bottom）か真ん中（center）を基準に、横 sx・縦 sy 倍に伸び縮みさせる（近い画素を拾う）。
func squashPixels(src map[pxlib.Pt]pxlib.Key, sx, sy float64, bottom bool, w, h int) map[pxlib.Pt]pxlib.Key {
	if len(src) == 0 || sx <= 0 || sy <= 0 {
		return src
	}
	pts := make([]pxlib.Pt, 0, len(src))
	for p := range src {
		pts = append(pts, p)
	}
	x0, y0, x1, y1 := pxlib.BBox(pts)
	cx := float64(x0+x1+1) / 2
	cy := float64(y0+y1+1) / 2
	if bottom {
		cy = float64(y1 + 1)
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

func init() {
	pPhase := param{Name: "phase", Type: tNumber, Default: 0.0, Summary: "位相のずれ（1 周 = 1.0。部品ごとに揺れを遅らせる）"}
	register(&opDef{
		Name: "sway", Example: `{"sway": {"amp": 1}}`,
		Summary:   "部品の画素を行ごとに横へずらす（根元 0・先端ほど大きく・コマごとに sin）。木・草・旗・髪の揺れ",
		Technique: "アニメ（揺れ。根元を止めて先端を遅らせる）", Finish: "lint orphan・anim（pop・loop）。欠けは pixel_perfect で整える",
		Params: []param{
			{Name: "amp", Type: tNumber, Default: 1.0, Summary: "先端のずれの最大（px）"},
			{Name: "curve", Type: tNumber, Default: 1.0, Summary: "根元から先端への効き方（1 = まっすぐ・2 = 先端だけ大きく）"},
			pPhase,
			{Name: "root", Type: tString, Default: "bottom", Summary: "止める端: bottom（木・草）・top（髪・吊るした旗）"},
			{Name: "ripple", Type: tNumber, Default: 0.0, Summary: "根元から先端へ遅れて伝わる波の数（0 で全体が同じ向き。旗は 0.5 ほど）"},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			root := a.str("root")
			if root != "bottom" && root != "top" {
				return fmt.Errorf("root は bottom か top")
			}
			n := float64(max(1, c.FrameCount))
			turn := float64(c.FrameIndex)/n + a.num("phase")
			src := c.liftPart()
			c.dropPixels(swayPixels(src, a.num("amp"), a.num("curve"), c.wave(a.num("phase")), root == "top", a.num("ripple"), turn))
			return nil
		},
	})
	register(&opDef{
		Name: "bob", Example: `{"bob": {"amp": 1}}`,
		Summary:   "部品を上下に動かす（コマごとに -amp·sin。呼吸・浮遊・歩きの上下）",
		Technique: "アニメ（溜め・弾み）", Finish: "anim（bob・ground）",
		Params: []param{{Name: "amp", Type: tNumber, Default: 1.0, Summary: "上下の幅（px）"}, pPhase},
		Apply: func(c *ctx, a opArgs) error {
			dy := int(math.Round(-a.num("amp") * c.wave(a.num("phase"))))
			src := c.liftPart()
			out := map[pxlib.Pt]pxlib.Key{}
			for p, k := range src {
				out[pxlib.Pt{X: p.X, Y: p.Y + dy}] = k
			}
			c.dropPixels(out)
			return nil
		},
	})
	register(&opDef{
		Name: "squash", Example: `{"squash": {"amount": 0.2}}`,
		Summary:   "部品を縦に縮めて横に伸ばす（縦 1 − amount·sin・横 1 + amount·sin。足元を止める）。着地・弾み・呼吸",
		Technique: "アニメ（つぶしと伸ばし）", Finish: "anim（area・ground）",
		Params: []param{
			{Name: "amount", Type: tNumber, Default: 0.2, Summary: "伸び縮みの強さ（0〜0.5 が目安）"},
			pPhase,
			{Name: "anchor", Type: tString, Default: "bottom", Summary: "止める所: bottom（足元）・center（真ん中）"},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			anc := a.str("anchor")
			if anc != "bottom" && anc != "center" {
				return fmt.Errorf("anchor は bottom か center")
			}
			s := c.wave(a.num("phase"))
			am := a.num("amount")
			src := c.liftPart()
			c.dropPixels(squashPixels(src, 1+am*s, 1-am*s, anc == "bottom", c.G.W, c.G.H))
			return nil
		},
	})
	register(&opDef{
		Name: "palette_cycle", Example: `{"palette_cycle": {"colors": ["shade", "mid", "light"]}}`,
		Summary:   "塊の中で colors の段をコマごとに step ずつ回す（水・光・滝。形は動かさない）",
		Technique: "アニメ（パレットの回転。カラーサイクリング）", Finish: "anim（pop）",
		Params: []param{
			pShape,
			{Name: "colors", Type: tRows, Required: true, Min: 2, Summary: "回す色の並び（2 色以上）"},
			{Name: "step", Type: tInt, Default: 1.0, Summary: "1 コマで進む段数（負で逆回り）"},
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
}
