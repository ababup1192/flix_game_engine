package px

// 縁の op: 部品ごとの色の輪郭（sel_out）・接地影・光と反対の縁の明るい段（rim_light）・段の角の中間色（aa_corners）。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// rampsFor は sel_out が材質のランプを引く並び。names は spec の ramps の名前か、ramp_pick を書いた部品の id。
// 無ければ今の部品のランプ・ramp_pick が選んだランプ（部品 id の順）・spec のランプ全部。
func (c *ctx) rampsFor(names []string) ([][]pxlib.Key, error) {
	var out [][]pxlib.Key
	for _, n := range names {
		if r, ok := c.Spec.Ramps[n]; ok {
			out = append(out, r)
			continue
		}
		if r, ok := c.picked[n]; ok {
			out = append(out, r)
			continue
		}
		return nil, fmt.Errorf("ramps に %q が無い（spec の ramps の名前か、ramp_pick を書いた部品の id）", n)
	}
	if len(out) > 0 {
		return out, nil
	}
	if r := c.Ramp(); len(r) > 0 {
		out = append(out, r)
	}
	for _, id := range sortedKeys(c.picked) {
		out = append(out, c.picked[id])
	}
	for _, n := range sortedKeys(c.Spec.Ramps) {
		out = append(out, c.Spec.Ramps[n])
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("ランプが無い")
	}
	return out, nil
}

// rampOf は色 k を含む最初のランプ（無ければ nil）。
func rampOf(ramps [][]pxlib.Key, k pxlib.Key) []pxlib.Key {
	for _, r := range ramps {
		if rampHas(r, k) {
			return r
		}
	}
	return nil
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

// selOut は塊 m の外側 1px（4 近傍）の画素と色を返す。色は内側の隣（光から遠い側を優先）の色を、
// その材質のランプで drop 段暗くした物。塊が光の側にある縁（内側の隣がどれも光と反対の向き）だけは litDrop 段。
// (sx, sy) は光の来る向きの符号（左上なら (-1, -1)）。
func selOut(g *pxlib.Grid, m pxlib.Mask, ramps [][]pxlib.Key, drop, litDrop, sx, sy int) map[pxlib.Pt]pxlib.Key {
	out := map[pxlib.Pt]pxlib.Key{}
	away := func(d pxlib.Pt) int { return -(d.X*sx + d.Y*sy) } // 光から遠ざかる向きほど大きい
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
			lit := sx != 0 || sy != 0
			for _, d := range nb {
				if away(d) > away(best) {
					best = d
				}
				if away(d) <= 0 {
					lit = false
				}
			}
			inner := g.At(x+best.X, y+best.Y)
			ramp := rampOf(ramps, inner)
			if ramp == nil {
				ramp = ramps[0]
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
			out[pxlib.Pt{X: x, Y: y}] = ramp[min(len(ramp)-1, max(0, i-d))]
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
			if dot(dx, dy, dx, dy) > 1 {
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

// edgeOutside は縁の外を決める: against が "clear" なら外の隣が塊の外で透明な所（絵の外形）だけ、
// "any" なら塊の外ならどこでも（ほかの部品との境目も）。
func edgeOutside(g *pxlib.Grid, m pxlib.Mask, against string) func(x, y int) bool {
	return func(x, y int) bool {
		if m.At(x, y) {
			return false
		}
		return against == "any" || !g.In(x, y) || g.At(x, y) == pxlib.Clear
	}
}

// rimLight は塊の縁のうち、光と反対の側（外の隣が光の来ない向きにある）の画素を by 段明るくした色を返す。
// 色の段は、その画素の色を含むランプで数える。
func rimLight(g *pxlib.Grid, m pxlib.Mask, out func(x, y int) bool, ramps [][]pxlib.Key, sx, sy, by int) map[pxlib.Pt]pxlib.Key {
	res := map[pxlib.Pt]pxlib.Key{}
	for _, p := range m.Points() {
		far := (sx != 0 && out(p.X-sx, p.Y)) || (sy != 0 && out(p.X, p.Y-sy))
		near := (sx != 0 && !m.At(p.X+sx, p.Y)) || (sy != 0 && !m.At(p.X, p.Y+sy))
		if !far || near {
			continue // 光と反対の縁だけ（光の側にも開いた細い所は触らない）
		}
		k := g.At(p.X, p.Y)
		if to := shadeStep(rampOf(ramps, k), k, by); to != k {
			res[p] = to
		}
	}
	return res
}

// aaCorners は塊の段の角（外の画素で、横と縦に塊の隣が 1 つずつある L 字の凹み）のうち、
// どちらかの段が 2px 以上の所に置く画素を返す（45° の 1-1 の段と直線には置かない）。
// 色は内側の色と外の色を Oklab で mix の割合に混ぜた色に一番近い、両者のランプの色（両端の色より混ぜ色に近い物だけ）。
// 外が透明なら外の色に地の色（ground）を、地も無ければ内側のもう 1 つ奥の色を使う。
func aaCorners(g *pxlib.Grid, m pxlib.Mask, out func(x, y int) bool, ramps [][]pxlib.Key, hexOf map[pxlib.Key]string, ground string, mix float64) map[pxlib.Pt]pxlib.Key {
	res := map[pxlib.Pt]pxlib.Key{}
	run := func(x, y, dx, dy, ox, oy int) int {
		// (x, y) から (dx, dy) へ、塊の中で (ox, oy) 側が外の画素を数える
		n := 0
		for m.At(x, y) && !m.At(x+ox, y+oy) {
			n++
			x, y = x+dx, y+dy
		}
		return n
	}
	labOf := func(k pxlib.Key) (pxlib.Oklab, bool) { return pxlib.OklabOfHex(hexOf[k]) }
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			if !out(x, y) || !g.In(x, y) {
				continue
			}
			for _, dx := range [2]int{-1, 1} {
				for _, dy := range [2]int{-1, 1} {
					hx, vy := x+dx, y+dy
					if !m.At(hx, y) || !m.At(x, vy) || m.At(x-dx, y) || m.At(x, y-dy) {
						continue
					}
					if max(run(x, vy, -dx, 0, 0, -dy), run(hx, y, 0, -dy, -dx, 0)) < 2 {
						continue
					}
					in := g.At(hx, y)
					il, ok := labOf(in)
					if !ok {
						continue
					}
					var ol pxlib.Oklab
					outer := g.At(x, y)
					switch {
					case outer != pxlib.Clear:
						if ol, ok = labOf(outer); !ok {
							continue
						}
					case ground != "":
						if ol, ok = pxlib.OklabOfHex(ground); !ok {
							continue
						}
					default:
						deep := g.At(hx+dx, y)
						if !m.At(hx+dx, y) || deep == in {
							continue
						}
						if ol, ok = labOf(deep); !ok {
							continue
						}
					}
					var want pxlib.Oklab
					for i := range want {
						want[i] = float64(il[i]*(1-mix)) + float64(ol[i]*mix)
					}
					limit := math.Min(labDist2(want, il), labDist2(want, ol))
					best, bestD := pxlib.Key(""), limit
					for _, r := range ramps {
						if !rampHas(r, in) && (outer == pxlib.Clear || !rampHas(r, outer)) {
							continue
						}
						for _, k := range r {
							if kl, ok := labOf(k); ok && k != in && k != outer {
								if d := labDist2(want, kl); d < bestD {
									best, bestD = k, d
								}
							}
						}
					}
					if best != "" {
						res[pxlib.Pt{X: x, Y: y}] = best
					}
				}
			}
		}
	}
	return res
}

func (c *ctx) putAll(px map[pxlib.Pt]pxlib.Key) {
	c.dropPixels(px)
}

var pAgainst = param{Name: "against", Type: tString, Default: "clear", Summary: "どの縁に当てるか: clear（絵の外形 = 外が透明な所だけ）・any（ほかの部品との境目にも）"}

func checkAgainst(a opArgs) error {
	if s := a.str("against"); s != "clear" && s != "any" {
		return fmt.Errorf("against は clear か any")
	}
	return nil
}

func hexTable(hexOf map[pxlib.Key]string) map[string]string {
	out := make(map[string]string, len(hexOf))
	for k, h := range hexOf {
		out[string(k)] = h
	}
	return out
}

func init() {
	register(&opDef{
		Name: "sel_out", Quiet: true, Example: `{"sel_out": {}}`,
		Summary:   "塊の外側 1px を、内側の隣の色を材質のランプで drop 段暗くした色で縁取る（光の側は lit_drop 段）",
		Technique: "sel-out（色トレス。輪郭を部品ごとの色に・黒は下と奥に絞る）", Finish: "lint black-outline",
		Params: []param{
			{Name: "drop", Type: tInt, Default: 2.0, Summary: "影の側の縁を暗くする段数", Lo: bound(0), Hi: bound(8)},
			{Name: "lit_drop", Type: tInt, Default: 1.0, Summary: "光の側（light.dir の向き）の縁を暗くする段数（0 で内側と同じ色）", Lo: bound(0), Hi: bound(8)},
			{Name: "ramps", Type: tRows, Summary: "材質のランプの名前か ramp_pick を書いた部品の id（省くと部品のランプ・ramp_pick が選んだランプ・spec のランプ全部）"},
		},
		Checks: []checkRef{{Check: checkBlackOutline}, {Check: checkGroundContrast}},
		Apply: func(c *ctx, a opArgs) error {
			ramps, err := c.rampsFor(a.rows("ramps"))
			if err != nil {
				return err
			}
			sx, sy := c.LightSign()
			c.putAll(selOut(c.G, c.Region(), ramps, a.int("drop"), a.int("lit_drop"), sx, sy))
			return nil
		},
	})
	register(&opDef{
		Name: "ground_shadow", Quiet: true, Example: `{"ground_shadow": {}}`,
		Summary:   "塊の足元に横長の楕円の接地影を落とす（物の上には塗らない。地面の色は 1 段暗く・透明の所は ramp[1]）",
		Technique: "接地影（物を地面に置く）", Finish: "ground-contrast",
		Params: []param{
			{Name: "of", Type: tString, Summary: "影を落とす部品の id（省くと今の部品。post では絵の全部）"},
			{Name: "ramp", Type: tString, Summary: "影の色を引くランプ（省くと部品かスプライトのランプ）"},
			{Name: "rows", Type: tInt, Default: 2.0, Summary: "影の高さ（行）", Lo: bound(1), Hi: bound(16)},
			{Name: "spread", Type: tNumber, Default: 1.0, Summary: "足元の幅から左右にはみ出す量", Lo: bound(0), Hi: bound(16)},
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
				if ramp = c.Spec.Ramps[n]; ramp == nil {
					return fmt.Errorf("ramps に %q が無い", n)
				}
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
		Name: "rim_light", Quiet: true, Example: `{"rim_light": {}}`,
		Summary:   "塊の縁のうち光と反対の側の 1px を by 段明るくする（暗い材質を暗い地から抜く）",
		Technique: "sel-out（光の側は明るく）・照り返しの縁", Finish: "ground-contrast",
		Params: []param{{Name: "by", Type: tInt, Default: 1.0, Summary: "明るくする段数", Lo: bound(1), Hi: bound(4)}, pAgainst},
		Checks: []checkRef{{Check: checkGroundContrast}},
		Apply: func(c *ctx, a opArgs) error {
			if err := checkAgainst(a); err != nil {
				return err
			}
			sx, sy := c.LightSign()
			m := c.Region()
			c.putAll(rimLight(c.G, m, edgeOutside(c.G, m, a.str("against")), c.allRamps(), sx, sy, a.int("by")))
			return nil
		},
	})
	register(&opDef{
		Name: "aa_corners", Example: `{"aa_corners": {}}`,
		Summary:   "2px 以上の段の角の凹みにだけ、内側と外の色の中間に一番近いランプの色を 1px 置く（45° と直線には置かない。中間の色が無ければ置かない）",
		Technique: "手打ち AA（2px 以上の段の角にだけ中間色）", Finish: "lint jaggy・orphan",
		Params: []param{
			{Name: "mix", Type: tNumber, Default: 0.5, Summary: "外の色へ寄せる割合（0.5 = 真ん中）", Lo: bound(0.1), Hi: bound(0.9)},
			pAgainst,
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "jaggy"}},
		Exempt: []checkRef{{Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			if err := checkAgainst(a); err != nil {
				return err
			}
			m := c.Region()
			ground := groundHex(c.Spec.Light.Ground, hexTable(c.hexOf))
			c.putAll(aaCorners(c.G, m, edgeOutside(c.G, m, a.str("against")), c.allRamps(), c.hexOf, ground, a.num("mix")))
			return nil
		},
	})
}
