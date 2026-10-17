package px

// 技法の検査（段 3）: pillow・light-dir・black-outline・value-sep・ramp-order・seam・anim。
// 閾値は bin/lint-rules/px.json（どれも仮置き）。違反には直し方（fix）を付け、次の周で迷わないようにする。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const (
	checkPillow       checkName = "pillow"        // 縁を一様に暗くした陰
	checkLightDir     checkName = "light-dir"     // 明るい段が光の側に無い
	checkBlackOutline checkName = "black-outline" // 小さい絵の 1 色の最暗の縁
	checkValueSep     checkName = "value-sep"     // 主役と背景の明度差
	checkRampOrder    checkName = "ramp-order"    // ランプの明るさが単調でない・段の差が足りない
	checkSeam         checkName = "seam"          // タイルの継ぎ目
	checkAnim         checkName = "anim"          // コマ列（bin/fge anim の pop・area・ground・bob・loop）
	checkStyle        checkName = "style"         // 機種の決まり
)

// spriteFix は形の規則ごとの直し方。
var spriteFix = map[string]string{
	"orphan":     "put の 1px を消すか隣に足して塊にする。散らしなら scatter_clusters に替える（1px を出さない）",
	"connect":    "部品の at か shape を 1px 寄せて本体とつなぐ",
	"palette":    "legend と色票に色キーを足すか、ランプの色キーに替える",
	"jaggy":      "形の半径を変えて段の長さを単調にする。角の段なら aa_corners を足す",
	"banding":    "gradient_fill の band を上げて境目をディザで混ぜるか、段の境目を斜めにずらす",
	"corner":     "線の後に pixel_perfect を置く",
	"silhouette": "形の大きさか輪郭を変えて、塗りつぶしても何か分かる影にする",
}

// edgeSides は塊の縁の画素を、光の側（外の隣が光の来る向き）と影の側に分ける。
func edgeSides(m pxlib.Mask, sx, sy int) (lit, dark []pxlib.Pt) {
	for _, p := range m.Points() {
		near := (sx != 0 && !m.At(p.X+sx, p.Y)) || (sy != 0 && !m.At(p.X, p.Y+sy))
		far := (sx != 0 && !m.At(p.X-sx, p.Y)) || (sy != 0 && !m.At(p.X, p.Y-sy))
		switch {
		case near && !far:
			lit = append(lit, p)
		case far && !near:
			dark = append(dark, p)
		}
	}
	return lit, dark
}

func signOf(v float64) int {
	switch {
	case v < 0:
		return -1
	case v > 0:
		return 1
	}
	return 0
}

func meanLOf(g *pxlib.Grid, hexOf map[pxlib.Key]string, pts []pxlib.Pt) (float64, bool) {
	sum, n := 0.0, 0
	for _, p := range pts {
		if l, ok := pxlib.Lightness(hexOf[g.At(p.X, p.Y)]); ok {
			sum += l
			n++
		}
	}
	if n == 0 {
		return 0, false
	}
	return sum / float64(n), true
}

// innerRing は塊の縁の輪（外の 1px が 1 色の輪郭なら、その内側の輪）と、その内側の塊を返す。
func innerRing(g *pxlib.Grid, m pxlib.Mask) (ring, inner pxlib.Mask) {
	d := m.DistFromEdge()
	colors := map[pxlib.Key]bool{}
	for _, p := range m.Points() {
		if d[p.Y][p.X] == 1 {
			colors[g.At(p.X, p.Y)] = true
		}
	}
	depth := 1
	if len(colors) == 1 {
		depth = 2
	}
	ring, inner = pxlib.NewMask(g.W, g.H), pxlib.NewMask(g.W, g.H)
	for _, p := range m.Points() {
		switch {
		case d[p.Y][p.X] == depth:
			ring[p.Y][p.X] = true
		case d[p.Y][p.X] > depth:
			inner[p.Y][p.X] = true
		}
	}
	return ring, inner
}

func init() {
	registerCheck(&checkDef{
		Name: checkPillow, Summary: "pillow: 塊の縁が光の側でも影の側でも同じように内側より暗い（縁からの距離で塗った陰）", Level: levelAdvice,
		Fix: "shade_step・shade_parts の陰を directional（か gradient_fill の field light）に替える。光の側の縁は lit_drop を 0 にする",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			sx, sy := signOf(c.Light[0]), signOf(c.Light[1])
			var out []violation
			for _, cells := range blobCells(g.Opaque()) {
				if len(cells) < c.Rules.PillowMinArea {
					continue
				}
				m := pxlib.NewMask(g.W, g.H)
				for _, p := range cells {
					m[p.Y][p.X] = true
				}
				ring, inner := innerRing(g, m)
				lit, dark := edgeSides(ring.Union(inner), sx, sy)
				lit, dark = onlyIn(lit, ring), onlyIn(dark, ring)
				ll, ok1 := meanLOf(g, c.HexOf, lit)
				ld, ok2 := meanLOf(g, c.HexOf, dark)
				li, ok3 := meanLOf(g, c.HexOf, inner.Points())
				if !ok1 || !ok2 || !ok3 {
					continue
				}
				if li-ll >= c.Rules.PillowEdgeGap && math.Abs(ll-ld) < c.Rules.PillowSideGap {
					p := lit[0]
					out = append(out, violation{Check: checkPillow, Level: levelAdvice, X: p.X, Y: p.Y, HasAt: true,
						Msg: fmt.Sprintf("縁の明るさが光の側 %.2f・影の側 %.2f で、内側 %.2f より一様に暗い（光源が無い陰）", ll, ld, li)})
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkLightDir, Summary: "light-dir: 塊の明るさで重みを付けた重心（明るい側 − 暗い側）が光の側（light.dir）に無い", Level: levelAdvice,
		Fix: "陰を directional で塗り直すか、gradient_fill の invert を外す。light.dir が絵の光と合っているかも見る",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, cells := range blobCells(g.Opaque()) {
				if len(cells) < c.Rules.LightDirMinArea {
					continue
				}
				type pl struct {
					p pxlib.Pt
					l float64
				}
				var ps []pl
				for _, p := range cells {
					if l, ok := pxlib.Lightness(c.HexOf[g.At(p.X, p.Y)]); ok {
						ps = append(ps, pl{p, l})
					}
				}
				if len(ps) < 2 {
					continue
				}
				// 明るさの平均からのずれで重みを付けた重心（明るい画素は +・暗い画素は −）。中央値で 2 つに分けると、
				// 最暗か最明の色が過半数の時に片側が空になって見逃す。
				mean := 0.0
				for _, e := range ps {
					mean += e.l
				}
				mean /= float64(len(ps))
				var vx, vy, wsum float64
				for _, e := range ps {
					w := e.l - mean
					vx += float64(w * float64(e.p.X))
					vy += float64(w * float64(e.p.Y))
					wsum += math.Abs(w)
				}
				if wsum == 0 {
					continue
				}
				vx, vy = vx/wsum*2, vy/wsum*2
				if dot(vx, vy, c.Light[0], c.Light[1]) < 0 {
					p := cells[0]
					out = append(out, violation{Check: checkLightDir, Level: levelAdvice, X: p.X, Y: p.Y, HasAt: true,
						Msg: fmt.Sprintf("明るい段が光と反対の側にある（明るい重心 − 暗い重心 = (%.1f, %.1f)・光 (%g, %g)）", vx, vy, c.Light[0], c.Light[1])})
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkBlackOutline, Summary: "black-outline: 小さい絵（blackOutlineMaxSize 未満）で、外の縁が 1 色・絵の中で一番暗い色のまま一周している", Level: levelAdvice,
		Fix: "outline を sel_out に替える（輪郭を部品ごとの色に・光の側を明るく）",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			if max(g.W, g.H) >= c.Rules.BlackOutlineMax {
				return nil
			}
			op := g.Opaque()
			if op.Count() == 0 {
				return nil
			}
			d := op.DistFromEdge()
			var edge pxlib.Key
			var at pxlib.Pt
			for _, p := range op.Points() {
				if d[p.Y][p.X] != 1 {
					continue
				}
				k := g.At(p.X, p.Y)
				if edge == "" {
					edge, at = k, p
				} else if k != edge {
					return nil
				}
			}
			el, ok := pxlib.Lightness(c.HexOf[edge])
			if !ok {
				return nil
			}
			for _, k := range g.Keys() {
				if l, ok := pxlib.Lightness(c.HexOf[k]); ok && l < el {
					return nil
				}
			}
			if op.Count() == len(edgePts(op, d)) {
				return nil // 縁しか無い細い絵（線・文字）
			}
			return []violation{{Check: checkBlackOutline, Level: levelAdvice, X: at.X, Y: at.Y, HasAt: true,
				Msg: fmt.Sprintf("外の縁が 1 色（%s・一番暗い色）で一周している（黒い 1 本線は小さい絵を重くする）", edge)}}
		},
	})
	registerCheck(&checkDef{
		Name: checkValueSep, Summary: "value-sep: contrast で測った部品と相手の明るさの差が下限（min か valueSepMin）を下回る", Level: levelLint,
		Fix: "前の層なら ramp_pick の base を明るく（暗く）、奥の層なら depth_fade の depth を上げて差を広げる",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, m := range c.Measures {
				lim := m.Min
				if lim <= 0 {
					lim = c.Rules.ValueSepMin
				}
				if m.D < lim {
					out = append(out, violation{Check: checkValueSep, Level: levelLint, X: m.At.X, Y: m.At.Y, HasAt: true,
						Msg: fmt.Sprintf("%s と %s の明るさの差 %.3f（%.2f 以上にする）", m.Part, m.Against, m.D, lim)})
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkRampOrder, Summary: "ramp-order: ランプの明るさ（Oklab の L）が暗 → 明に単調でない・隣の段の差が rampMinGap に足りない", Level: levelLint,
		Fix: "ramps の並びを暗 → 明に直すか、ramp_pick の step・min_gap を上げて選び直す",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, name := range sortedKeys(c.Ramps) {
				r := c.Ramps[name]
				for i := 1; i < len(r); i++ {
					a, ok1 := pxlib.Lightness(c.HexOf[r[i-1]])
					b, ok2 := pxlib.Lightness(c.HexOf[r[i]])
					if !ok1 || !ok2 {
						continue
					}
					if b-a < c.Rules.RampMinGap {
						out = append(out, violation{Check: checkRampOrder, Level: levelLint, Sprite: c.RampOwner[name],
							Msg: fmt.Sprintf("ランプ %s の %d → %d 段（%s → %s）の明るさの差 %+.3f（暗 → 明に %.2f 以上）", name, i-1, i, r[i-1], r[i], b-a, c.Rules.RampMinGap)})
					}
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkSeam, Summary: "seam: タイルの端（左と右・上と下）の画素の明るさの差が、内側の隣り合う列の差の seamRatio 倍を超える（並べると継ぎ目が見える）", Level: levelLint,
		Fix: "散らしなら scatter_clusters に wrap: true を付ける。タイルでは gradient_fill をやめる（使うなら field radial か、左右・上下の端の段を揃える）",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			lOf := func(x, y int) float64 {
				l, _ := pxlib.Lightness(c.HexOf[g.At(x, y)])
				return l
			}
			diff := func(ax, ay, bx, by int) float64 { return math.Abs(lOf(ax, ay) - lOf(bx, by)) }
			for _, axis := range []string{"x", "y"} {
				n, m := g.W, g.H
				if axis == "y" {
					n, m = g.H, g.W
				}
				if n < 3 {
					continue
				}
				pair := func(i, j, k int) float64 {
					if axis == "x" {
						return diff(i, k, j, k)
					}
					return diff(k, i, k, j)
				}
				edge, inner, strongest := 0.0, 0.0, 0.0
				for k := 0; k < m; k++ {
					edge += pair(n-1, 0, k)
				}
				for i := 0; i+1 < n; i++ {
					line := 0.0
					for k := 0; k < m; k++ {
						line += pair(i, i+1, k)
					}
					inner += line
					strongest = math.Max(strongest, line/float64(m))
				}
				edge /= float64(m)
				inner /= float64(m * (n - 1))
				// 内側にも同じ強さの線（レンガの目地など）があれば、端の差は模様の一部で継ぎ目ではない
				if edge > inner*c.Rules.SeamRatio+0.02 && edge > strongest+0.02 {
					out = append(out, violation{Check: checkSeam, Level: levelLint,
						Msg: fmt.Sprintf("%s の端の差 %.3f が内側の差 %.3f の %.1f 倍を超える（並べると継ぎ目が見える）", map[string]string{"x": "左右", "y": "上下"}[axis], edge, inner, c.Rules.SeamRatio)})
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkAnim, Summary: "anim: コマ列に bin/fge anim の pop・area・ground・bob・loop をかける（動きの op・pose・rotate を使うスプライト、か anim: true）", Level: levelLint,
		Fix: "sway・bob の amp か squash の amount を下げる。輪が閉じないならコマの数を sin の周期に合わせる",
		Run: func(*pxlib.Grid, *checkCtx) []violation { return nil }, // コマ列を見るので build が直に回す
	})
}

func onlyIn(pts []pxlib.Pt, m pxlib.Mask) []pxlib.Pt {
	var out []pxlib.Pt
	for _, p := range pts {
		if m.At(p.X, p.Y) {
			out = append(out, p)
		}
	}
	return out
}

func edgePts(m pxlib.Mask, d [][]int) []pxlib.Pt {
	var out []pxlib.Pt
	for _, p := range m.Points() {
		if d[p.Y][p.X] == 1 {
			out = append(out, p)
		}
	}
	return out
}

// blobCells は塊を 4 近傍の連結成分に分け、成分ごとの画素を走査順で返す。
func blobCells(m pxlib.Mask) [][]pxlib.Pt {
	seen := pxlib.NewMask(m.W(), m.H())
	var out [][]pxlib.Pt
	for _, start := range m.Points() {
		if seen[start.Y][start.X] {
			continue
		}
		var cells []pxlib.Pt
		stack := []pxlib.Pt{start}
		seen[start.Y][start.X] = true
		for len(stack) > 0 {
			p := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			cells = append(cells, p)
			for _, d := range pxlib.Dirs4 {
				q := pxlib.Pt{X: p.X + d.X, Y: p.Y + d.Y}
				if m.At(q.X, q.Y) && !seen[q.Y][q.X] {
					seen[q.Y][q.X] = true
					stack = append(stack, q)
				}
			}
		}
		pxlib.SortPtsByXY(cells)
		out = append(out, cells)
	}
	return out
}
