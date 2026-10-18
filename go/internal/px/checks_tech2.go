package px

// 技法帳の検査（段 2）: highlight-reserve・ground-contrast の highlight と chroma・ramp-hue・ramp-chroma・value-blobs・
// tile-variant-edge・outer-aa。どれも advice（gate にしない）。閾値は bin/lint-rules/px.json（決めた根拠はその note）。
//
// 1 つの検査は「測る（measure: 全部の値を返す）」と「基準で外れを選ぶ（Run）」に分ける。bin/fge px measure が
// 測る方だけを回して、採用済みの絵の値の分布を出す（閾値を決め直す材料）。

import (
	"fmt"
	"math"
	"sort"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const (
	checkHighlightReserve checkName = "highlight-reserve" // 最明色はハイライト専用（面積と置き場）
	checkRampHue          checkName = "ramp-hue"          // ランプの色相の回し方
	checkRampChroma       checkName = "ramp-chroma"       // ランプの彩度の形
	checkValueBlobs       checkName = "value-blobs"       // 明暗の骨格（大きな塊の数）
	checkTileVariantEdge  checkName = "tile-variant-edge" // タイルの変種の縁が元と同じ
	checkOuterAA          checkName = "outer-aa"          // 透明に接する外周の中間色
)

// sample は測った値 1 つ（code の末尾の測り方・値・場所・文の材料）。
type sample struct {
	Sub  string
	Got  float64
	At   pxlib.Pt
	Has  bool
	Note string
}

// measureFn は 1 コマ（か spec 全体）を測る。
type measureFn func(g *pxlib.Grid, c *checkCtx) []sample

// measures は測る口の表（px measure が回す。spec 全体の物は ramp-hue・ramp-chroma）。
var measures = map[checkName]measureFn{}

// oklch は色の明るさ・彩度・色相（度）。
func oklch(hex string) (l, ch, h float64, ok bool) {
	lab, ok := pxlib.OklabOfHex(hex)
	if !ok {
		return 0, 0, 0, false
	}
	ch = math.Hypot(lab[1], lab[2])
	h = math.Atan2(lab[2], lab[1]) * 180 / math.Pi
	if h < 0 {
		h += 360
	}
	return lab[0], ch, h, true
}

// hsv は #rrggbb の V と S（0〜1。技法帳の「V≥90 の段は S≤35」を測る）。
func hsv(hex string) (s, v float64, ok bool) {
	c, ok := pxlib.RGBAOfValue(hex)
	if !ok {
		return 0, 0, false
	}
	mx := math.Max(float64(c[0]), math.Max(float64(c[1]), float64(c[2]))) / 255
	mn := math.Min(float64(c[0]), math.Min(float64(c[1]), float64(c[2]))) / 255
	if mx == 0 {
		return 0, 0, true
	}
	return (mx - mn) / mx, mx, true
}

// litPixels は検査に使う画素（emissive の部品を除く）と、その明るさ。
func litPixels(g *pxlib.Grid, c *checkCtx) (pts []pxlib.Pt, ls map[pxlib.Key]float64) {
	ls = map[pxlib.Key]float64{}
	m := litOpaque(g, c)
	for _, p := range m.Points() {
		k := g.At(p.X, p.Y)
		if _, seen := ls[k]; !seen {
			l, ok := pxlib.Lightness(c.HexOf[k])
			if !ok {
				continue
			}
			ls[k] = l
		}
		pts = append(pts, p)
	}
	return pts, ls
}

func init() {
	// highlight-reserve: 最明色は面積が小さく（brightMaxShare 以下）、面の境（隣に別の色）から 1px 以内だけに置く
	measures[checkHighlightReserve] = func(g *pxlib.Grid, c *checkCtx) []sample {
		pts, ls := litPixels(g, c)
		if len(ls) < c.Rules.HighlightMinColors || len(pts) < 16 {
			return nil // 色が少ない絵（3〜4 色の記号）は最明色が面を塗るのが普通なので見ない
		}
		var top pxlib.Key
		best := -1.0
		for k, l := range ls {
			if l > best || l == best && k < top {
				top, best = k, l
			}
		}
		n, inside := 0, 0
		var at pxlib.Pt
		for _, p := range pts {
			if g.At(p.X, p.Y) != top {
				continue
			}
			n++
			edge := false
			for _, d := range pxlib.Dirs4 {
				if g.At(p.X+d.X, p.Y+d.Y) != top {
					edge = true
				}
			}
			if !edge {
				if inside == 0 {
					at = p
				}
				inside++
			}
		}
		share := float64(n) / float64(len(pts))
		first := pxlib.Pt{}
		for _, p := range pts {
			if g.At(p.X, p.Y) == top {
				first = p
				break
			}
		}
		return []sample{
			{Sub: "area", Got: share, At: first, Has: true, Note: fmt.Sprintf("最明色 %s が描いた画素の %.1f%%", top, share*100)},
			{Sub: "inside", Got: float64(inside) / float64(max(1, n)), At: at, Has: inside > 0, Note: fmt.Sprintf("最明色 %s の画素の %d / %d が面の中（四方が同じ色）", top, inside, n)},
		}
	}
	registerCheck(&checkDef{
		Name: checkHighlightReserve, Summary: "highlight-reserve: 最明色（emissive の部品は除く）が描いた画素の highlightMaxShare を超える・面の中（四方が同じ色）に置いてある。最明色はハイライト専用", Level: levelAdvice,
		Fix: "面の塗りに最明色を使わず、1 つ下の段にする。最明色は面の境の 1px（光の側の角）だけに置く",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, s := range measures[checkHighlightReserve](g, c) {
				want := checkres.WantAtMost(c.Rules.HighlightMaxShare)
				if s.Sub == "inside" {
					want = checkres.WantAtMost(c.Rules.HighlightInsideMax)
				}
				if s.Got > want.Value {
					v := newViolation(checkHighlightReserve, levelAdvice, s.Got, want, s.Note).sub(s.Sub)
					if s.Has {
						v = v.at(s.At)
					}
					out = append(out, v)
				}
			}
			return out
		},
	})

	// ground-contrast の足し: 地は絵のハイライトより暗く（highlight）・明るい地は彩度を低く（chroma）。地が無ければ見ない
	measures[checkGroundContrast+".extra"] = func(g *pxlib.Grid, c *checkCtx) []sample {
		gl, gch, _, ok := oklch(c.Ground)
		if !ok {
			return nil
		}
		_, ls := litPixels(g, c)
		if len(ls) == 0 {
			return nil
		}
		best := 0.0
		for _, l := range ls {
			best = math.Max(best, l)
		}
		out := []sample{{Sub: "highlight", Got: best - gl, Note: fmt.Sprintf("絵の最明色の明るさ %.3f・地 %s %.3f", best, c.Ground, gl)}}
		if gl >= c.Rules.GroundBrightL {
			out = append(out, sample{Sub: "chroma", Got: gch, Note: fmt.Sprintf("明るい地 %s（L %.2f）の彩度 %.3f", c.Ground, gl, gch)})
		}
		return out
	}

	// ramp-hue: ランプの色相は明るくなるたびに同じ向きへ回す（1 段 rampHueMaxStep 度まで・全体で rampHueMinTotal 度以上）。
	// 灰色に近いランプ（彩度の平均が rampGrayChroma 未満）は色相が決まらないので見ない
	measures[checkRampHue] = func(_ *pxlib.Grid, c *checkCtx) []sample {
		var out []sample
		for _, name := range sortedKeys(c.Ramps) {
			r := c.Ramps[name]
			if len(r) < 3 {
				continue
			}
			var hs, chs []float64
			for _, k := range r {
				_, ch, h, ok := oklch(c.HexOf[k])
				if !ok {
					hs = nil
					break
				}
				hs, chs = append(hs, h), append(chs, ch)
			}
			if hs == nil || mean(chs) < c.Rules.RampGrayChroma {
				continue
			}
			maxStep, total, turns, dir := 0.0, 0.0, 0, 0
			for i := 1; i < len(hs); i++ {
				d := math.Mod(hs[i]-hs[i-1]+540, 360) - 180 // -180〜180
				if math.Min(chs[i], chs[i-1]) < c.Rules.RampGrayChroma {
					continue // 端の灰色の段は色相が飛ぶ
				}
				maxStep = math.Max(maxStep, math.Abs(d))
				total += math.Abs(d)
				if s := signOf(d); s != 0 && math.Abs(d) >= 2 {
					if dir != 0 && s != dir {
						turns++
					}
					dir = s
				}
			}
			out = append(out,
				sample{Sub: "step", Got: maxStep, Note: name + fmt.Sprintf("（隣の段の色相の差の最大 %.0f°）", maxStep)},
				sample{Sub: "turn", Got: float64(turns), Note: name + fmt.Sprintf("（色相の回る向きが %d 回変わる）", turns)},
				sample{Sub: "flat", Got: total, Note: name + fmt.Sprintf("（暗 → 明で色相が合わせて %.0f° 回る）", total)})
		}
		return out
	}
	registerCheck(&checkDef{
		Name: checkRampHue, Summary: "ramp-hue: ランプの色相が明るくなるたびに同じ向きへ回らない・1 段 rampHueMaxStep 度を超える・全体で rampHueMinTotal 度未満（平板）。灰色のランプは見ない", Level: levelAdvice,
		Fix: "明るい側を黄寄り・暗い側を青紫寄りへ、1 段 10〜20° ずつ同じ向きに回した色に替える（px.palette の色を選び直す）",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, s := range measures[checkRampHue](g, c) {
				var want checkres.Want
				bad := false
				switch s.Sub {
				case "step":
					want, bad = checkres.WantAtMost(c.Rules.RampHueMaxStep), s.Got > c.Rules.RampHueMaxStep
				case "turn":
					want, bad = checkres.WantAtMost(0), s.Got > 0
				case "flat":
					want, bad = checkres.WantAtLeast(c.Rules.RampHueMinTotal), s.Got < c.Rules.RampHueMinTotal
				}
				if bad {
					out = append(out, newViolation(checkRampHue, levelAdvice, s.Got, want, "ランプ "+s.Note).sub(s.Sub))
				}
			}
			return out
		},
	})

	// ramp-chroma: 彩度は山の形（一番高い段が真ん中 ±rampChromaPeakSlack 段）・明るい段（V ≥ rampBrightV）は S ≤ rampBrightSMax
	measures[checkRampChroma] = func(_ *pxlib.Grid, c *checkCtx) []sample {
		var out []sample
		for _, name := range sortedKeys(c.Ramps) {
			r := c.Ramps[name]
			if len(r) < 3 {
				continue
			}
			peak, best, worstS := 0, -1.0, 0.0
			bright := false
			for i, k := range r {
				_, ch, _, ok := oklch(c.HexOf[k])
				s, v, ok2 := hsv(c.HexOf[k])
				if !ok || !ok2 {
					continue
				}
				if ch > best {
					peak, best = i, ch
				}
				if v >= c.Rules.RampBrightV {
					bright = true
					worstS = math.Max(worstS, s)
				}
			}
			mid := float64(len(r)-1) / 2
			off := math.Max(0, math.Abs(float64(peak)-mid)-0.5) // 段が偶数の時は真ん中の 2 段のどちらでも 0
			out = append(out, sample{Sub: "peak", Got: off, Note: fmt.Sprintf("%s（彩度の一番高い段 %d・真ん中 %.1f）", name, peak, mid)})
			if bright {
				out = append(out, sample{Sub: "bright", Got: worstS, Note: fmt.Sprintf("%s（V ≥ %.2f の段の S の最大 %.2f）", name, c.Rules.RampBrightV, worstS)})
			}
		}
		return out
	}
	registerCheck(&checkDef{
		Name: checkRampChroma, Summary: "ramp-chroma: ランプの彩度が山の形でない（一番高い段が真ん中から rampChromaPeakSlack 段より外）・明るい段（V ≥ rampBrightV）の S が rampBrightSMax を超える（高明度 × 高彩度）", Level: levelAdvice,
		Fix: "真ん中の段の彩度を一番高くし、明るい段ほど彩度を下げた色に替える（暗い段は彩度を上げると濁らない）",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, s := range measures[checkRampChroma](g, c) {
				want := checkres.WantAtMost(c.Rules.RampChromaPeakSlack)
				if s.Sub == "bright" {
					want = checkres.WantAtMost(c.Rules.RampBrightSMax)
				}
				if s.Got > want.Value {
					out = append(out, newViolation(checkRampChroma, levelAdvice, s.Got, want, "ランプ "+s.Note).sub(s.Sub))
				}
			}
			return out
		},
	})

	// value-blobs: 明るさを 3 段に分けた時の大きな塊（描いた画素の valueBlobsMinShare 以上）の数と、それが覆う割合。
	// 描き込みの後も 2〜3 段の明暗の塊が読めるか（塊が多すぎる・覆う割合が低い = 細かい明暗が散って骨格が崩れた）
	measures[checkValueBlobs] = func(g *pxlib.Grid, c *checkCtx) []sample {
		pts, ls := litPixels(g, c)
		if len(pts) < 64 || len(ls) < 3 {
			return nil
		}
		var all []float64
		for _, p := range pts {
			all = append(all, ls[g.At(p.X, p.Y)])
		}
		sort.Float64s(all)
		t1, t2 := all[len(all)/3], all[2*len(all)/3]
		level := func(p pxlib.Pt) int {
			l := ls[g.At(p.X, p.Y)]
			switch {
			case l < t1:
				return 0
			case l < t2:
				return 1
			}
			return 2
		}
		big, covered := 0, 0
		for lv := 0; lv < 3; lv++ {
			m := pxlib.NewMask(g.W, g.H)
			for _, p := range pts {
				if ls[g.At(p.X, p.Y)] >= 0 && level(p) == lv {
					m[p.Y][p.X] = true
				}
			}
			for _, cells := range blobCells(m) {
				if float64(len(cells)) >= c.Rules.ValueBlobsMinShare*float64(len(pts)) {
					big++
					covered += len(cells)
				}
			}
		}
		cover := float64(covered) / float64(len(pts))
		return []sample{
			{Sub: "count", Got: float64(big), Note: fmt.Sprintf("明るさ 3 段の大きな塊が %d", big)},
			{Sub: "cover", Got: cover, Note: fmt.Sprintf("大きな塊が描いた画素の %.0f%% を覆う", cover*100)},
		}
	}
	registerCheck(&checkDef{
		Name: checkValueBlobs, Summary: "value-blobs: 明るさを 3 段に分けた大きな塊の数が valueBlobsMin〜valueBlobsMax の外・塊が覆う割合が valueBlobsCoverMin 未満（明暗の骨格が描き込みで崩れた）", Level: levelAdvice,
		Fix: "先に 2〜3 段の明暗の塊を置き（px.band・shade_step）、模様はその上で同じランプの 1 段ずらしにする。細かい明暗を減らす",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, s := range measures[checkValueBlobs](g, c) {
				switch s.Sub {
				case "count":
					lo, hi := float64(c.Rules.ValueBlobsMin), float64(c.Rules.ValueBlobsMax)
					if s.Got < lo || s.Got > hi {
						out = append(out, newViolation(checkValueBlobs, levelAdvice, s.Got, checkres.WantRange(lo, hi), s.Note).sub(s.Sub))
					}
				case "cover":
					if s.Got < c.Rules.ValueBlobsCoverMin {
						out = append(out, newViolation(checkValueBlobs, levelAdvice, s.Got, checkres.WantAtLeast(c.Rules.ValueBlobsCoverMin), s.Note).sub(s.Sub))
					}
				}
			}
			return out
		},
	})

	// outer-aa: 透明に接する外周に、外周にしか使わない中間色の 1px（段の角のなめらかし）を置いている
	measures[checkOuterAA] = func(g *pxlib.Grid, c *checkCtx) []sample {
		op := g.Opaque()
		if op.Count() < 16 {
			return nil
		}
		d := op.DistFromEdge()
		onRing, inner := map[pxlib.Key]int{}, map[pxlib.Key]bool{}
		for _, p := range op.Points() {
			if d[p.Y][p.X] == 1 {
				onRing[g.At(p.X, p.Y)]++
			} else {
				inner[g.At(p.X, p.Y)] = true
			}
		}
		n := 0
		var at pxlib.Pt
		for _, p := range op.Points() {
			k := g.At(p.X, p.Y)
			if d[p.Y][p.X] != 1 || inner[k] || onRing[k] > max(2, op.Count()/50) {
				continue
			}
			// 段の角: 外周の上で、同じ色の隣が無く、斜めにしか外周が続かない 1px
			same, ortho := 0, 0
			for _, dd := range pxlib.Dirs4 {
				q := pxlib.Pt{X: p.X + dd.X, Y: p.Y + dd.Y}
				if g.At(q.X, q.Y) == k {
					same++
				}
				if op.At(q.X, q.Y) {
					ortho++
				}
			}
			if same == 0 && ortho <= 2 {
				if n == 0 {
					at = p
				}
				n++
			}
		}
		return []sample{{Got: float64(n), At: at, Has: n > 0, Note: fmt.Sprintf("透明に接する外周の段の角に、外周にしか使わない中間色の 1px が %d", n)}}
	}
	registerCheck(&checkDef{
		Name: checkOuterAA, Summary: "outer-aa: 透明に接する外周の段の角に、外周にしか使わない中間色の 1px（外周の AA）がある。どの地に置いても縁が濁るので全域で避ける", Level: levelAdvice,
		Fix: "外周の角の中間色を外す（aa_corners は内側の段だけに。外周は透明か輪郭の色のまま）",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, s := range measures[checkOuterAA](g, c) {
				if s.Got > float64(c.Rules.OuterAAMax) {
					v := newViolation(checkOuterAA, levelAdvice, s.Got, checkres.WantAtMost(float64(c.Rules.OuterAAMax)), s.Note)
					if s.Has {
						v = v.at(s.At)
					}
					out = append(out, v)
				}
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkTileVariantEdge, Summary: "tile-variant-edge: タイルの変種（seeds のコマ）の縁から tileVariantEdge px が、最初の種のコマと画素で違う（変種は中央だけ変える）", Level: levelAdvice,
		Fix: "変種の違い（散らし・ひび）を縁から tileVariantEdge px より内側に置く（scatter_clusters の範囲を内側の矩形に）",
		Run: func(*pxlib.Grid, *checkCtx) []violation { return nil }, // 種ごとのコマを比べるので build が直に回す（tileVariantViolations）
	})
}

func mean(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	s := 0.0
	for _, x := range xs {
		s += x
	}
	return s / float64(len(xs))
}

// groundExtraViolations は ground-contrast の足し（highlight・chroma）。ground-contrast の Run から呼ぶ。
func groundExtraViolations(g *pxlib.Grid, c *checkCtx) []violation {
	var out []violation
	for _, s := range measures[checkGroundContrast+".extra"](g, c) {
		switch s.Sub {
		case "highlight":
			if s.Got < 0 {
				out = append(out, newViolation(checkGroundContrast, levelAdvice, s.Got, checkres.WantAtLeast(0), "地が絵のハイライトより明るい（"+s.Note+"）").sub("highlight").
					fix("地を絵の最明色より暗くする（light.ground を 1 段暗い色に）"))
			}
		case "chroma":
			if s.Got > c.Rules.GroundBrightChromaMax {
				out = append(out, newViolation(checkGroundContrast, levelAdvice, s.Got, checkres.WantAtMost(c.Rules.GroundBrightChromaMax), s.Note).sub("chroma").
					fix("明るい地は彩度を下げる（灰色寄りに。反対の色相なら明暗の差が効く）"))
			}
		}
	}
	return out
}

// tileVariantViolations は同じコマの種ごとの格子（最初の種が元）の縁を比べる。
func tileVariantViolations(names []string, grids []*pxlib.Grid, edge int) []violation {
	var out []violation
	if len(grids) < 2 {
		return nil
	}
	base := grids[0]
	for i := 1; i < len(grids); i++ {
		g := grids[i]
		if g.W != base.W || g.H != base.H {
			continue
		}
		n := 0
		var at pxlib.Pt
		for y := 0; y < g.H; y++ {
			for x := 0; x < g.W; x++ {
				if x >= edge && y >= edge && x < g.W-edge && y < g.H-edge {
					continue
				}
				if g.At(x, y) != base.At(x, y) {
					if n == 0 {
						at = pxlib.Pt{X: x, Y: y}
					}
					n++
				}
			}
		}
		if n > 0 {
			v := newViolation(checkTileVariantEdge, levelAdvice, float64(n), checkres.WantAtMost(0),
				fmt.Sprintf("変種 %s の縁 %dpx が元 %s と %d 画素違う（並べると継ぎ目がずれる）", names[i], edge, names[0], n)).at(at)
			v.Frame = names[i]
			out = append(out, v)
		}
	}
	return out
}
