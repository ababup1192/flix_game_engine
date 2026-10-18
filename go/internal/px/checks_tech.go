package px

// 技法の検査（段 3）: pillow・light-dir・black-outline・value-sep・ramp-order・seam・anim。
// 閾値は bin/lint-rules/px.json（どれも仮置き）。違反には直し方（fix）を付け、次の周で迷わないようにする。

import (
	"fmt"
	"math"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
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
	checkFlicker      checkName = "flicker"       // コマの間で周りが動かないのに色だけ変わる画素
	checkMargin       checkName = "margin"        // 動く絵が格子の縁に詰まっている
)

// spriteFix は形の規則ごとの直し方。
var spriteFix = map[string]string{
	"orphan":     "put の 1px を消すか隣に足して塊にする。散らしなら scatter_clusters に替える（1px を出さない）",
	"connect":    "部品の at か shape を 1px 寄せて本体とつなぐ",
	"palette":    "legend と色票に色キーを足すか、ランプの色キーに替える",
	"jaggy":      "形の半径を変えて段の長さを単調にする。角の段なら aa_corners を足す",
	"banding":    "gradient_fill の band を上げて境目をディザで混ぜるか、段の境目を斜めにずらす",
	"corner":     "L 字の角に 2 重に乗った画素を 1 つ消す（線の点を減らすか、角を 1px ずらす）",
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

// offBorder は格子の縁（一番外の 1px）に乗っていない点だけを返す。
func offBorder(pts []pxlib.Pt, w, h int) []pxlib.Pt {
	var out []pxlib.Pt
	for _, p := range pts {
		if p.X > 0 && p.Y > 0 && p.X < w-1 && p.Y < h-1 {
			out = append(out, p)
		}
	}
	return out
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
// 格子の縁で切れた所（画面の外へはみ出した雲など）は形の縁でないので、輪郭かどうかの色の数には入れない。
func innerRing(g *pxlib.Grid, m pxlib.Mask) (ring, inner pxlib.Mask) {
	d := m.DistFromEdge()
	colors, all := map[pxlib.Key]bool{}, map[pxlib.Key]bool{}
	for _, p := range m.Points() {
		if d[p.Y][p.X] == 1 {
			all[g.At(p.X, p.Y)] = true
			if p.X > 0 && p.Y > 0 && p.X < g.W-1 && p.Y < g.H-1 {
				colors[g.At(p.X, p.Y)] = true
			}
		}
	}
	if len(colors) == 0 {
		colors = all // 縁が全部格子の縁に乗る（格子いっぱいの絵）なら、それを縁と見る
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

// litOpaque は描いた画素から、自分で光る部品（部品の emissive。窓の灯り・炎・爆発・画面）の画素を除いた塊。
// 光の向きで明るさが決まらないので、光の陰を見る検査（pillow・light-dir）の対象から外す。
// 部品の検査（c.Part がある時）では、部品の形の中でもほかの部品が描いた画素（形を塗り残した所に見える下の色）を除く。
func litOpaque(g *pxlib.Grid, c *checkCtx) pxlib.Mask {
	opaque := g.Opaque()
	if len(c.Emissive) > 0 || c.Part != "" {
		for _, p := range opaque.Points() {
			src := g.SrcAt(p.X, p.Y).Part
			if c.Emissive[src] || c.Part != "" && src != c.Part {
				opaque[p.Y][p.X] = false
			}
		}
	}
	return opaque
}

func init() {
	registerCheck(&checkDef{
		Name: checkPillow, Summary: "pillow: 塊の縁が光の側でも影の側でも同じように内側より暗い（縁からの距離で塗った陰。emissive の部品は見ない）", Level: levelAdvice,
		Fix: "shade_step・shade_parts の陰を directional（か gradient_fill の field light）に替える。光の側の縁は lit_drop を 0 にする",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			sx, sy := signOf(c.Light[0]), signOf(c.Light[1])
			var out []violation
			for _, cells := range blobCells(litOpaque(g, c)) {
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
				// 格子の縁で切れた所（画面の外へはみ出した雲）は形の縁でないので、光の側・影の側に数えない
				lit, dark = offBorder(lit, g.W, g.H), offBorder(dark, g.W, g.H)
				ll, ok1 := meanLOf(g, c.HexOf, lit)
				ld, ok2 := meanLOf(g, c.HexOf, dark)
				li, ok3 := meanLOf(g, c.HexOf, inner.Points())
				if !ok1 || !ok2 || !ok3 {
					continue
				}
				if li-ll >= c.Rules.PillowEdgeGap && math.Abs(ll-ld) < c.Rules.PillowSideGap {
					// 光の側と影の側の差を pillowSideGap 以上に開けば pillow ではない
					out = append(out, newViolation(checkPillow, levelAdvice, math.Abs(ll-ld), checkres.WantAtLeast(c.Rules.PillowSideGap),
						fmt.Sprintf("縁の明るさが光の側 %.2f・影の側 %.2f で、内側 %.2f より一様に暗い（光源が無い陰）", ll, ld, li)).at(lit[0]))
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkLightDir, Summary: "light-dir: 塊の明るさで重みを付けた重心（明るい側 − 暗い側）が光の側（light.dir）に無い（emissive の部品は見ない）", Level: levelAdvice,
		Fix: "陰を directional で塗り直すか、gradient_fill の invert を外す。自分で光る部品（灯り・炎）なら部品に \"emissive\": true。light.dir が絵の光と合っているかも見る",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, cells := range blobCells(litOpaque(g, c)) {
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
					// 明るい側へ向かう向きと光の向きの内積（正なら光の側が明るい）
					out = append(out, newViolation(checkLightDir, levelAdvice, dot(vx, vy, c.Light[0], c.Light[1]), checkres.WantAtLeast(0),
						fmt.Sprintf("明るい段が光と反対の側にある（明るい重心 − 暗い重心 = (%.1f, %.1f)・光 (%g, %g)）", vx, vy, c.Light[0], c.Light[1])).at(cells[0]))
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkBlackOutline, Summary: "black-outline: 小さい絵（blackOutlineMaxSize 未満）で、外の縁が 1 色・絵の中で一番暗い色のまま一周している", Level: levelAdvice,
		Fix: "outline を sel_out に替える（輪郭を部品ごとの色に・光の側を明るく）", Fidelity: true,
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
			// 縁の色の数（2 色以上にすれば 1 色の黒い輪郭ではない）
			return []violation{newViolation(checkBlackOutline, levelAdvice, 1, checkres.WantAtLeast(2),
				fmt.Sprintf("外の縁が 1 色（%s・一番暗い色）で一周している（黒い 1 本線は小さい絵を重くする）", edge)).at(at).
				fix("", checkres.Try{Op: "outline", Arg: "op", Now: "outline", Try: "sel_out", Expect: checkres.Ptr(2)})}
		},
	})
	registerCheck(&checkDef{
		Name: checkValueSep, Summary: "value-sep: contrast で測った部品と相手の明るさの差が下限（min か valueSepMin）を下回る", Level: levelLint,
		Fix: "前の層なら部品のランプを明るい（暗い）段にし、奥の層なら depth_fade の depth を上げて差を広げる",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, m := range c.Measures {
				lim := m.Min
				if lim <= 0 {
					lim = c.Rules.ValueSepMin
				}
				if m.D < lim {
					out = append(out, newViolation(checkValueSep, levelLint, m.D, checkres.WantAtLeast(lim),
						fmt.Sprintf("%s と %s の明るさの差 %.3f（%.2f 以上にする）", m.Part, m.Against, m.D, lim)).at(m.At))
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkRampOrder, Summary: "ramp-order: ランプの明るさ（Oklab の L）が暗 → 明に単調でない・隣の段の差が rampMinGap に足りない", Level: levelLint,
		Fix: "ramps の並びを暗 → 明に直すか、隣の段との明るさの差が広い色に替える",
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
						out = append(out, newViolation(checkRampOrder, levelLint, b-a, checkres.WantAtLeast(c.Rules.RampMinGap),
							fmt.Sprintf("ランプ %s の %d → %d 段（%s → %s）の明るさの差 %+.3f（暗 → 明に %.2f 以上）", name, i-1, i, r[i-1], r[i], b-a, c.Rules.RampMinGap)))
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
				if lim := math.Max(inner*c.Rules.SeamRatio, strongest) + 0.02; edge > lim {
					out = append(out, newViolation(checkSeam, levelLint, edge, checkres.WantAtMost(lim),
						fmt.Sprintf("%s の端の差 %.3f が内側の差 %.3f の %.1f 倍を超える（並べると継ぎ目が見える）", map[string]string{"x": "左右", "y": "上下"}[axis], edge, inner, c.Rules.SeamRatio)).sub(axis))
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkAnim, Summary: "anim: コマ列に bin/fge anim の pop・area・ground・bob・loop をかける（動きの op・pose・rotate を使うスプライト、か anim: true）", Level: levelLint,
		Fix: "sway の amp を下げる。輪が閉じないならコマの数を sin の周期に合わせる",
		Run: func(*pxlib.Grid, *checkCtx) []violation { return nil }, // コマ列を見るので build が直に回す
	})
	registerCheck(&checkDef{
		Name: checkFlicker, Summary: "flicker: コマの間で周り 8 画素が動かないのに色だけ変わる画素（ちらつき。palette_cycle と wave_shift の画素・コマで at か rotate が変わる部品と、sway を持つ部品（on の子も）の画素は除く）", Level: levelLint,
		Fix: "その画素を描く op がコマごとに違う色を選んでいないか見る（seed・dither の位置をコマで揃える）。色を回したいなら palette_cycle か wave_shift で書く",
		Run: func(*pxlib.Grid, *checkCtx) []violation { return nil }, // コマ列を見るので build が直に回す
	})
	registerCheck(&checkDef{
		Name: checkMargin, Summary: "margin: 動く絵が格子の左・右・上の縁に触れている（動く余白が無い）", Level: levelAdvice,
		Fix: "size を広げるか、部品の at で絵を内側へ寄せて、動く向きに 1〜2px の余白を空ける",
		Run: func(*pxlib.Grid, *checkCtx) []violation { return nil }, // コマ列を見るので build が直に回す
	})
}

// partPose はコマごとの部品の置き方（flicker が動いた部品を見分ける）。
type partPose struct {
	At     pxlib.Pt
	Rotate float64
	Moves  bool // 部品か親（on）が画素を動かす op（sway）を持つ: その画素はコマごとに動くのでちらつきと数えない
}

// moveOps は画素を動かす op（flicker は、これを持つ部品と on の子の画素を動きと見る）。
// 平らな色の行が 1px ずれると端の 2 画素だけが変わり、周りは変わらないので、ちらつきと見分けられない。
var moveOps = map[string]bool{"sway": true}

// partPoses はコマの部品の置き方（部品 id → at・rotate・動きの op の有無。on の子は親の動きを受け継ぐ）。
func partPoses(parts []*part) map[string]partPose {
	moves := map[string]bool{}
	for _, p := range parts {
		for _, call := range p.Ops {
			if moveOps[call.Name] {
				moves[p.ID] = true
			}
		}
	}
	out := map[string]partPose{}
	for _, p := range parts {
		m := moves[p.ID]
		for q, depth := p.On, 0; q != "" && !m && depth < len(parts); depth++ {
			m = moves[q]
			next := ""
			for _, pp := range parts {
				if pp.ID == q {
					next = pp.On
				}
			}
			q = next
		}
		out[p.ID] = partPose{p.At, p.Rotate, m}
	}
	return out
}

// flickerExempt は色を回すのが仕事の op（その画素はちらつきと見ない）。
var flickerExempt = map[string]bool{"palette_cycle": true, "wave_shift": true}

// sequenceChecks はコマ列（並び順）に flicker と margin をかける。loop なら最後から最初へも輪で比べる
// （倒れ・攻撃のように輪にならない列で、最後と最初の差をちらつきと読まない）。
// ats はコマごとの部品の at と rotate（部品 id → 置き方。nil なら見ない）: 2 つのコマで at か rotate が違う部品
// （at でずらすスクロール・移動・回転）の画素は動きなのでちらつきと数えない（格子の縁から入ってくる写しは、
// 格子の中の部分だけで陰が決まり塗りがコマで変わる）。
func sequenceChecks(names []string, grids []*pxlib.Grid, loop bool, ats []map[string]partPose, c *checkCtx) []violation {
	var out []violation
	n := len(grids)
	if n < 2 {
		return nil
	}
	pairs := n - 1
	if loop {
		pairs = n
	}
	for i := 0; i < pairs; i++ {
		a, b := grids[i], grids[(i+1)%n]
		if a.W != b.W || a.H != b.H {
			continue
		}
		moved := func(string) bool { return false }
		if len(ats) == n {
			atA, atB := ats[i], ats[(i+1)%n]
			moved = func(part string) bool {
				pa, okA := atA[part]
				pb, okB := atB[part]
				return okA && okB && (pa != pb || pa.Moves)
			}
		}
		var cells []pxlib.Pt
		for y := 0; y < a.H; y++ {
			for x := 0; x < a.W; x++ {
				ka, kb := a.At(x, y), b.At(x, y)
				if ka == kb || ka == pxlib.Clear || kb == pxlib.Clear {
					continue
				}
				if op := baseOp(a.SrcAt(x, y).Op); flickerExempt[op] || flickerExempt[baseOp(b.SrcAt(x, y).Op)] {
					if c != nil && c.Exempted != nil {
						if !flickerExempt[op] {
							op = baseOp(b.SrcAt(x, y).Op)
						}
						c.Exempted[[2]string{"px.flicker", op}]++
					}
					continue
				}
				if moved(a.SrcAt(x, y).Part) || moved(b.SrcAt(x, y).Part) {
					continue
				}
				still := true
				for dy := -1; dy <= 1 && still; dy++ {
					for dx := -1; dx <= 1; dx++ {
						if (dx != 0 || dy != 0) && a.In(x+dx, y+dy) && a.At(x+dx, y+dy) != b.At(x+dx, y+dy) {
							still = false
							break
						}
					}
				}
				if still {
					cells = append(cells, pxlib.Pt{X: x, Y: y})
				}
			}
		}
		if len(cells) > 0 {
			v := newViolation(checkFlicker, levelLint, float64(len(cells)), checkres.WantAtMost(0),
				fmt.Sprintf("%s → %s で、周りが動かないのに色だけ変わる画素が %d 個（ちらつく）", names[i], names[(i+1)%n], len(cells))).at(cells[0]).fix(checks[checkFlicker].Fix)
			v.Frame, v.Cells = names[(i+1)%n], cells
			out = append(out, v)
		}
	}
	// 動く絵の外接箱が左・右・上の縁に触れていれば、動く余白が無い（足元の下の縁は地面なので見ない）
	moving := false
	for i := 1; i < n && !moving; i++ {
		for y := 0; y < grids[0].H && !moving; y++ {
			for x := 0; x < grids[0].W; x++ {
				if grids[i].At(x, y) != grids[0].At(x, y) {
					moving = true
					break
				}
			}
		}
	}
	if moving {
		var sides []string
		w, h := grids[0].W, grids[0].H
		touch := func(f func(g *pxlib.Grid) bool) bool {
			for _, g := range grids {
				if f(g) {
					return true
				}
			}
			return false
		}
		col := func(x int) func(g *pxlib.Grid) bool {
			return func(g *pxlib.Grid) bool {
				for y := 0; y < h; y++ {
					if g.At(x, y) != pxlib.Clear {
						return true
					}
				}
				return false
			}
		}
		if touch(col(0)) {
			sides = append(sides, "左")
		}
		if touch(col(w - 1)) {
			sides = append(sides, "右")
		}
		if touch(func(g *pxlib.Grid) bool {
			for x := 0; x < w; x++ {
				if g.At(x, 0) != pxlib.Clear {
					return true
				}
			}
			return false
		}) {
			sides = append(sides, "上")
		}
		if len(sides) > 0 {
			out = append(out, newViolation(checkMargin, levelAdvice, float64(len(sides)), checkres.WantAtMost(0),
				fmt.Sprintf("動く絵が%sの縁に触れている（動く余白が無いと動きが縮こまる）", strings.Join(sides, "・"))).fix(checks[checkMargin].Fix))
		}
	}
	if seenProbe != nil {
		for _, v := range out {
			seenProbe(v)
		}
	}
	return out
}

// baseOp は書き手の op の名前（use の中なら最後の op）。
func baseOp(op string) string {
	if i := strings.LastIndex(op, ">"); i >= 0 {
		return op[i+1:]
	}
	return op
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
