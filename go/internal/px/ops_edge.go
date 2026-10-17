package px

// 縁の op: 部品ごとの色の輪郭（sel_out）・接地影・光と反対の縁の明るい段（rim_light）・段の角の中間色（aa_corners）。

import (
	"fmt"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// rampsFor は sel_out が材質のランプを引く並び（引数の名前 → 無ければ今の部品のランプ・spec のランプ全部）。
func (c *ctx) rampsFor(names []string) ([][]pxlib.Key, error) {
	var out [][]pxlib.Key
	for _, n := range names {
		r, ok := c.Spec.Ramps[n]
		if !ok {
			return nil, fmt.Errorf("ramps に %q が無い", n)
		}
		out = append(out, r)
	}
	if len(out) > 0 {
		return out, nil
	}
	if r := c.Ramp(); len(r) > 0 {
		out = append(out, r)
	}
	for _, n := range sortedKeys(c.Spec.Ramps) {
		out = append(out, c.Spec.Ramps[n])
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("ランプが無い")
	}
	return out, nil
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j] < out[j-1]; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

// selOut は塊 m の外側 1px（4 近傍）の画素と色を返す。色は内側の隣（右か下を優先）の色を、
// その材質のランプで drop 段暗くした物。塊が右下にある縁（光の側）だけは litDrop 段。
func selOut(g *pxlib.Grid, m pxlib.Mask, ramps [][]pxlib.Key, drop, litDrop int) map[pxlib.Pt]pxlib.Key {
	out := map[pxlib.Pt]pxlib.Key{}
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			if m.At(x, y) {
				continue
			}
			var nb []pxlib.Pt
			for _, d := range pxlib.Dirs4 {
				if m.At(x+d.X, y+d.Y) {
					nb = append(nb, d)
				}
			}
			if len(nb) == 0 {
				continue
			}
			best := nb[0]
			lit := true
			for _, d := range nb {
				if d.X+d.Y > best.X+best.Y {
					best = d
				}
				if d.X+d.Y <= 0 {
					lit = false
				}
			}
			inner := g.At(x+best.X, y+best.Y)
			ramp := ramps[0]
			for _, r := range ramps {
				if rampHas(r, inner) {
					ramp = r
					break
				}
			}
			i := 0
			for j, k := range ramp {
				if k == inner {
					i = j
				}
			}
			d := drop
			if lit {
				d = litDrop
			}
			out[pxlib.Pt{X: x, Y: y}] = ramp[max(0, i-d)]
		}
	}
	return out
}

func rampHas(r []pxlib.Key, k pxlib.Key) bool {
	for _, e := range r {
		if e == k {
			return true
		}
	}
	return false
}

// groundShadow は塊 obj の足元の横長の楕円の影の画素を返す。中心は (足元の幅の中心, 足元の行 + 1)、
// 半径は (幅/2 + spread, rows/2)。obj の外だけ。地面に塗ってある色は 1 段暗く、透明の所は ramp[1]。
func groundShadow(g *pxlib.Grid, obj pxlib.Mask, ramp []pxlib.Key, rows int, spread float64) map[pxlib.Pt]pxlib.Key {
	out := map[pxlib.Pt]pxlib.Key{}
	y1 := -1
	for y := range obj {
		for x := range obj[y] {
			if obj[y][x] {
				y1 = y
			}
		}
	}
	if y1 < 0 || len(ramp) < 2 {
		return out
	}
	xmin, xmax := g.W, -1
	for y := max(0, y1-1); y <= y1; y++ {
		for x := range obj[y] {
			if obj[y][x] {
				xmin, xmax = min(xmin, x), max(xmax, x)
			}
		}
	}
	cx := float64(xmin+xmax+1) / 2
	cy := float64(y1) + 1
	rx := float64(xmax-xmin+1)/2 + spread
	ry := float64(rows)/2 + 0.01
	for y := y1 - rows + 1; y <= y1+1; y++ {
		for x := 0; x < g.W; x++ {
			if !g.In(x, y) || obj.At(x, y) {
				continue
			}
			dx, dy := (float64(x)+0.5-cx)/rx, (float64(y)+0.5-cy)/ry
			if dx*dx+dy*dy > 1 {
				continue
			}
			k := g.At(x, y)
			if k == pxlib.Clear {
				out[pxlib.Pt{X: x, Y: y}] = ramp[1]
			} else {
				out[pxlib.Pt{X: x, Y: y}] = shadeStep(ramp, k, -1)
			}
		}
	}
	return out
}

// rimLight は塊の縁のうち、光と反対の側（外の隣が光の来ない向きにある）の画素を by 段明るくした色を返す。
func rimLight(g *pxlib.Grid, m pxlib.Mask, ramp []pxlib.Key, sx, sy, by int) map[pxlib.Pt]pxlib.Key {
	out := map[pxlib.Pt]pxlib.Key{}
	for _, p := range m.Points() {
		far := (sx != 0 && !m.At(p.X-sx, p.Y)) || (sy != 0 && !m.At(p.X, p.Y-sy))
		near := (sx != 0 && !m.At(p.X+sx, p.Y)) || (sy != 0 && !m.At(p.X, p.Y+sy))
		if !far || near {
			continue // 光と反対の縁だけ（光の側にも開いた細い所は触らない）
		}
		k := g.At(p.X, p.Y)
		if to := shadeStep(ramp, k, by); to != k {
			out[p] = to
		}
	}
	return out
}

// aaCorners は塊の段の角（外の画素で、横と縦に塊の隣が 1 つずつある L 字の凹み）のうち、
// どちらかの段が 2px 以上の所に置く画素を返す（45° の 1-1 の段と直線には置かない）。
// 色は横の隣の色をランプで by 段ずらした物。
func aaCorners(g *pxlib.Grid, m pxlib.Mask, ramp []pxlib.Key, by int) map[pxlib.Pt]pxlib.Key {
	out := map[pxlib.Pt]pxlib.Key{}
	run := func(x, y, dx, dy, ox, oy int) int {
		// (x, y) から (dx, dy) へ、塊の中で (ox, oy) 側が外の画素を数える
		n := 0
		for m.At(x, y) && !m.At(x+ox, y+oy) {
			n++
			x, y = x+dx, y+dy
		}
		return n
	}
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			if m.At(x, y) {
				continue
			}
			for _, dx := range [2]int{-1, 1} {
				for _, dy := range [2]int{-1, 1} {
					hx, vy := x+dx, y+dy
					if !m.At(hx, y) || !m.At(x, vy) || m.At(x-dx, y) || m.At(x, y-dy) {
						continue
					}
					// 横の段: (x, vy) から -dx へ、上（-dy 側）が外の画素の数
					rh := run(x, vy, -dx, 0, 0, -dy)
					// 縦の段: (hx, y) から -dy へ、横（-dx 側）が外の画素の数
					rv := run(hx, y, 0, -dy, -dx, 0)
					if max(rh, rv) < 2 {
						continue
					}
					k := g.At(hx, y)
					if to := shadeStep(ramp, k, by); to != k {
						out[pxlib.Pt{X: x, Y: y}] = to
					}
				}
			}
		}
	}
	return out
}

func (c *ctx) putAll(px map[pxlib.Pt]pxlib.Key) {
	c.dropPixels(px)
}

func init() {
	register(&opDef{
		Name: "sel_out", Example: `{"sel_out": {}}`,
		Summary:   "塊の外側 1px を、内側の隣の色を材質のランプで drop 段暗くした色で縁取る（光の側は lit_drop 段）",
		Technique: "sel-out（色トレス。輪郭を部品ごとの色に・黒は下と奥に絞る）", Finish: "lint black-outline",
		Params: []param{
			{Name: "drop", Type: tInt, Default: 2.0, Summary: "影の側の縁を暗くする段数"},
			{Name: "lit_drop", Type: tInt, Default: 1.0, Summary: "光の側（左上）の縁を暗くする段数（0 で内側と同じ色）"},
			{Name: "ramps", Type: tRows, Summary: "材質のランプの名前（省くと部品のランプと spec のランプ全部）"},
		},
		Checks: []checkRef{{Check: checkBlackOutline}, {Check: checkGroundContrast}},
		Apply: func(c *ctx, a opArgs) error {
			ramps, err := c.rampsFor(a.rows("ramps"))
			if err != nil {
				return err
			}
			c.putAll(selOut(c.G, c.Region(), ramps, a.int("drop"), a.int("lit_drop")))
			return nil
		},
	})
	register(&opDef{
		Name: "ground_shadow", Example: `{"ground_shadow": {}}`,
		Summary:   "塊の足元に横長の楕円の接地影を落とす（物の上には塗らない。地面の色は 1 段暗く・透明の所は ramp[1]）",
		Technique: "接地影（物を地面に置く）", Finish: "ground-contrast",
		Params: []param{
			{Name: "of", Type: tString, Summary: "影を落とす部品の id（省くと今の部品。post では絵の全部）"},
			{Name: "ramp", Type: tString, Summary: "影の色を引くランプ（省くと部品かスプライトのランプ）"},
			{Name: "rows", Type: tInt, Default: 2.0, Summary: "影の高さ（行）"},
			{Name: "spread", Type: tNumber, Default: 1.0, Summary: "足元の幅から左右にはみ出す量"},
		},
		Checks: []checkRef{{Check: checkGroundContrast}},
		Apply: func(c *ctx, a opArgs) error {
			obj := c.Region()
			if n := a.str("of"); n != "" {
				p, ok := c.parts[n]
				if !ok {
					return fmt.Errorf("部品 %q が無い", n)
				}
				obj = p.Region()
			}
			ramp := c.Ramp()
			if n := a.str("ramp"); n != "" {
				ramp = c.Spec.Ramps[n]
			} else if len(ramp) == 0 && c.Sprite != nil {
				ramp = c.Spec.Ramps[c.Sprite.Ramp]
			}
			if len(ramp) < 2 {
				return fmt.Errorf("2 段以上のランプが要る（ramp を書く）")
			}
			c.putAll(groundShadow(c.G, obj, ramp, a.int("rows"), a.num("spread")))
			return nil
		},
	})
	register(&opDef{
		Name: "rim_light", Example: `{"rim_light": {}}`,
		Summary:   "塊の縁のうち光と反対の側の 1px を by 段明るくする（暗い材質を暗い地から抜く）",
		Technique: "sel-out（光の側は明るく）・照り返しの縁", Finish: "ground-contrast",
		Params: []param{{Name: "by", Type: tInt, Default: 1.0, Summary: "明るくする段数"}},
		Checks: []checkRef{{Check: checkGroundContrast}},
		Apply: func(c *ctx, a opArgs) error {
			sx, sy := c.LightSign()
			c.putAll(rimLight(c.G, c.Region(), c.Ramp(), sx, sy, a.int("by")))
			return nil
		},
	})
	register(&opDef{
		Name: "aa_corners", Example: `{"aa_corners": {}}`,
		Summary:   "2px 以上の段の角の凹みにだけ、隣の色を by 段ずらした中間の色を 1px 置く（45° と直線には置かない）",
		Technique: "手打ち AA（2px 以上の段の角にだけ中間色）", Finish: "lint jaggy・orphan",
		Params: []param{{Name: "by", Type: tInt, Default: -1.0, Summary: "隣の色からずらす段数（負で暗く）"}},
		Checks: []checkRef{{Check: checkSprite, Rule: "jaggy"}},
		Exempt: []checkRef{{Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			c.putAll(aaCorners(c.G, c.Region(), c.Ramp(), a.int("by")))
			return nil
		},
	})
}
