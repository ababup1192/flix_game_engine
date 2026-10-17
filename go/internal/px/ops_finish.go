package px

// 仕上げの op: 遠くの層を空の色へ寄せる（depth_fade）・左右対称に写す（mirror）・金属のつや（glint）・
// タイルの 3×3 の見本と継ぎ目の検査（tile_preview）。

import (
	"fmt"
	"math"
	"sort"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// labDist2 は Oklab の 2 色の距離の 2 乗（積を 1 つずつ丸める）。
func labDist2(p, q pxlib.Oklab) float64 {
	a, b, c := p[0]-q[0], p[1]-q[1], p[2]-q[2]
	return float64(a*a) + float64(b*b) + float64(c*c)
}

// nearestKey は Oklab の色に一番近い候補の色キー（色を足さない）。
func nearestKey(t pxlib.Oklab, cands map[string]string) pxlib.Key {
	best, bestD := "", math.Inf(1)
	for _, k := range sortedKeys(cands) {
		lab, ok := pxlib.OklabOfHex(cands[k])
		if !ok {
			continue
		}
		d := labDist2(lab, t)
		if d < bestD {
			best, bestD = k, d
		}
	}
	return pxlib.Key(best)
}

// fadeCandidates は depth_fade が選ぶ色（style の色の集合、無ければ spec のランプに出る色と相手の色）。
func (c *ctx) fadeCandidates(toward pxlib.Key) map[string]string {
	if c.style != nil && len(c.style.Colors) > 0 {
		return c.style.Colors
	}
	out := map[string]string{}
	for _, r := range c.Spec.Ramps {
		for _, k := range r {
			if h, ok := c.hexOf[k]; ok {
				out[string(k)] = h
			}
		}
	}
	for _, k := range c.Ramp() {
		if h, ok := c.hexOf[k]; ok {
			out[string(k)] = h
		}
	}
	if h, ok := c.hexOf[toward]; ok {
		out[string(toward)] = h
	}
	return out
}

// glintCells は塊の中で光の来る角に一番近い画素から、光の向きの順に 4 近傍で size 画素を選ぶ（縁の 1px は避ける）。
func glintCells(m pxlib.Mask, lx, ly float64, size int) []pxlib.Pt {
	d := m.DistFromEdge()
	score := func(p pxlib.Pt) float64 { return dot(float64(p.X), float64(p.Y), lx, ly) }
	var pool []pxlib.Pt
	for _, p := range m.Points() {
		if d[p.Y][p.X] >= 2 {
			pool = append(pool, p)
		}
	}
	if len(pool) == 0 {
		pool = m.Points()
	}
	if len(pool) == 0 || size < 1 {
		return nil
	}
	inPool := map[pxlib.Pt]bool{}
	for _, p := range pool {
		inPool[p] = true
	}
	better := func(a, b pxlib.Pt) bool {
		sa, sb := score(a), score(b)
		if sa != sb {
			return sa > sb
		}
		if a.Y != b.Y {
			return a.Y < b.Y
		}
		return a.X < b.X
	}
	sort.Slice(pool, func(i, j int) bool { return better(pool[i], pool[j]) })
	chosen := []pxlib.Pt{pool[0]}
	got := map[pxlib.Pt]bool{pool[0]: true}
	for len(chosen) < size {
		var next *pxlib.Pt
		for _, q := range chosen {
			for _, dd := range pxlib.Dirs4 {
				n := pxlib.Pt{X: q.X + dd.X, Y: q.Y + dd.Y}
				if inPool[n] && !got[n] && (next == nil || better(n, *next)) {
					nn := n
					next = &nn
				}
			}
		}
		if next == nil {
			break
		}
		chosen = append(chosen, *next)
		got[*next] = true
	}
	return chosen
}

// mirrorPixels は側 side（left か right）の画素を、軸 axis（x の値。画素の境目なら .5 で終わらない）で写した画素を返す。
func mirrorPixels(g *pxlib.Grid, m pxlib.Mask, axis float64, left bool) map[pxlib.Pt]pxlib.Key {
	out := map[pxlib.Pt]pxlib.Key{}
	for _, p := range m.Points() {
		x := float64(p.X)
		if (left && x >= axis) || (!left && x <= axis) {
			continue
		}
		nx := int(math.Round(2*axis - x))
		if g.In(nx, p.Y) {
			out[pxlib.Pt{X: nx, Y: p.Y}] = g.At(p.X, p.Y)
		}
	}
	return out
}

func init() {
	register(&opDef{
		Name: "depth_fade", Example: `{"depth_fade": {"depth": 0.5, "toward": "light"}}`,
		Summary:   "遠い層ほど、塗った色を空の色 toward へ depth の割合で寄せ（明度差も縮む）、一番近い候補の色に置き換える（色は足さない）",
		Technique: "背景の奥行き（遠いほど明度差が小さく、空の色・青へ寄る）", Finish: "lint value-sep（contrast で測る）",
		Params: []param{
			pShape,
			{Name: "depth", Type: tNumber, Default: 0.5, Summary: "遠さ（0 = そのまま・1 = 空の色）", Lo: bound(0), Hi: bound(1)},
			{Name: "toward", Type: tColor, Default: "", Summary: "寄せる空の色（省くと light.ground の地の色）"},
		},
		Checks: []checkRef{{Check: checkValueSep}},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			var tk pxlib.Key
			if a.str("toward") != "" {
				if tk, err = c.Color(a.color("toward")); err != nil {
					return err
				}
			} else {
				tk = pxlib.Key(c.Spec.Light.Ground)
			}
			th, ok := c.hexOf[tk]
			if !ok {
				th = pxlib.HexOfValue(string(tk))
			}
			tl, ok := pxlib.OklabOfHex(th)
			if !ok {
				return fmt.Errorf("空の色が無い（toward か light.ground を書く）")
			}
			t := math.Max(0, math.Min(1, a.num("depth")))
			cands := c.fadeCandidates(tk)
			for _, p := range m.Points() {
				k := c.G.At(p.X, p.Y)
				lab, ok := pxlib.OklabOfHex(c.hexOf[k])
				if k == pxlib.Clear || !ok {
					continue
				}
				var mix pxlib.Oklab
				for i := range mix {
					mix[i] = float64(lab[i]*(1-t)) + float64(tl[i]*t)
				}
				if nk := nearestKey(mix, cands); nk != "" && nk != k {
					c.PutAbs(p.X, p.Y, nk)
				}
			}
			return nil
		},
	})
	register(&opDef{
		Name: "mirror", Example: `{"mirror": {"side": "left"}}`,
		Summary:   "今の部品が描いた画素のうち side の側を、軸で左右に写す（左右対称の顔・道具・建物）",
		Technique: "左右対称に描く（片側を描いて写す）", Finish: "—",
		Params: []param{
			{Name: "side", Type: tString, Default: "left", Summary: "写す元の側: left（左を右へ）・right（右を左へ）"},
			{Name: "axis", Type: tNumber, Summary: "軸の x（画素の中心は整数・境目は .5。省くと部品の塊の外接箱の真ん中）"},
		},
		Apply: func(c *ctx, a opArgs) error {
			side := a.str("side")
			if side != "left" && side != "right" {
				return fmt.Errorf("side は left か right")
			}
			m := c.Part.written.Union(c.Region())
			pts := m.Points()
			if len(pts) == 0 {
				return nil
			}
			x0, _, x1, _ := pxlib.BBox(pts)
			axis := float64(x0+x1) / 2
			if a.has("axis") {
				axis = a.num("axis") + float64(c.ox)
			}
			c.dropPixels(mirrorPixels(c.G, c.Part.written, axis, side == "left"))
			return nil
		},
	})
	register(&opDef{
		Name: "glint", Example: `{"glint": {"size": 2}}`,
		Summary:   "塊の光の来る角に size 画素のつや（light.gloss、無ければランプの最明段）を置く（縁の 1px は避ける）",
		Technique: "金属のつや（地・影・白 1〜2px の 3 段）", Finish: "lint orphan（つやは例外）",
		Params: []param{
			{Name: "size", Type: tInt, Default: 2.0, Summary: "つやの画素の数（1〜2 が目安）", Lo: bound(1), Hi: bound(8)},
			{Name: "color", Type: tColor, Default: "", Summary: "つやの色（省くと gloss か ramp[-1]）"},
		},
		Exempt: []checkRef{{Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			var k pxlib.Key
			var err error
			switch {
			case a.str("color") != "":
				k, err = c.Color(a.color("color"))
			case c.Spec.Light.Gloss != "":
				k = c.Spec.Light.Gloss
			default:
				k, err = c.Color("ramp[-1]")
			}
			if err != nil {
				return err
			}
			for _, p := range glintCells(c.Region(), c.Spec.Light.Dir[0], c.Spec.Light.Dir[1], a.int("size")) {
				c.PutAbs(p.X, p.Y, k)
			}
			return nil
		},
	})
	register(&opDef{
		Name: "tile_preview", Example: `{"tile_preview": {}}`,
		Summary:   "このスプライトをタイルとして扱う: 3×3 に並べた見本（<名前>.tile.png）を書き、端の継ぎ目を検査する（描かない）",
		Technique: "草のタイル（Aseprite の Tiled Mode。並べて継ぎ目を見る）", Finish: "lint seam",
		Whole: true, PostOnly: true,
		Checks: []checkRef{{Check: checkSeam}},
		Apply: func(c *ctx, a opArgs) error {
			c.tile, c.wrap = true, true
			return nil
		},
	})
}
