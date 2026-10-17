package px

// 明るさの構造の op: 先に明るさの帯（光の範囲）を決めてから、その上の模様の色を帯ごとにランプで 1 段ずつずらす（band_shift）と、
// 形が別の面へ落とす影と接地の一番暗い影（cast_shadow）。
//
// band_shift は草・レンガ・石・地面のどれにも同じ 1 つで当てる（素材ごとの op にしない）。模様は先に普通に描いておき、
// 帯の数だけ「同じ模様をランプで 1 段上げた物」に置き換える: 暗い帯の葉の先の色が明るい帯の葉の胴の色になり、
// 明るい帯にはランプの次の段が新しい先の色として出る（目地・影も同じだけずれる）。
// 帯の境目は by: blob / part で模様の塊（葉・レンガ 1 個・石 1 個）ごとに決めると、丸い帯（banding）が出ずに模様に沿う。

import (
	"fmt"
	"math"
	"sort"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// bandIndex は明るさ v（0〜1）を bands 本の帯のどれかにする。cuts があればその境目で、無ければ等分（band で境目を Bayer で混ぜる）。
func bandIndex(v float64, x, y, bands int, cuts []float64, band float64) int {
	v = math.Min(1, math.Max(0, v))
	if len(cuts) > 0 {
		i := 0
		for _, c := range cuts {
			if v >= c {
				i++
			}
		}
		return i
	}
	pos := v*float64(bands) - 0.5
	i := int(math.Floor(pos))
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
	if f > bayer(x, y) {
		i++
	}
	return max(0, min(bands-1, i))
}

// rangeField は光の範囲（中心 c・半径 r）の明るさ: 中心が 1・半径の外は 0。
func rangeField(cx, cy, r float64) func(x, y int) float64 {
	return func(x, y int) float64 {
		return math.Max(0, 1-math.Hypot(float64(x)+0.5-cx, float64(y)+0.5-cy)/r)
	}
}

// valueBlobs は塗ってある画素を模様の塊に分ける: part は書いた部品ごと、blob は書いた部品が同じで 4 近傍につながる画素
// （seam の色の画素は塊を切る側で、どの塊にも入れない）。
func valueBlobs(g *pxlib.Grid, pts []pxlib.Pt, by string, seam map[pxlib.Key]bool) [][]pxlib.Pt {
	in := map[pxlib.Pt]bool{}
	for _, p := range pts {
		if !seam[g.At(p.X, p.Y)] {
			in[p] = true
		}
	}
	var out [][]pxlib.Pt
	switch by {
	case "part":
		idx := map[string]int{}
		for _, p := range pts {
			if !in[p] {
				continue
			}
			id := g.SrcAt(p.X, p.Y).Part
			i, ok := idx[id]
			if !ok {
				i = len(out)
				idx[id] = i
				out = append(out, nil)
			}
			out[i] = append(out[i], p)
		}
	case "blob":
		seen := map[pxlib.Pt]bool{}
		for _, p := range pts {
			if !in[p] || seen[p] {
				continue
			}
			id := g.SrcAt(p.X, p.Y).Part
			var blob []pxlib.Pt
			stack := []pxlib.Pt{p}
			seen[p] = true
			for len(stack) > 0 {
				q := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				blob = append(blob, q)
				for _, d := range pxlib.Dirs4 {
					n := pxlib.Pt{X: q.X + d.X, Y: q.Y + d.Y}
					if in[n] && !seen[n] && g.SrcAt(n.X, n.Y).Part == id {
						seen[n] = true
						stack = append(stack, n)
					}
				}
			}
			out = append(out, blob)
		}
	}
	return out
}

// sampleOf は塊の帯を決める明るさ: center（塊の重心）・top（一番上の画素）・bottom（一番下）・light（塊の中で一番明るい所）。
func sampleOf(blob []pxlib.Pt, f func(x, y int) float64, how string) float64 {
	switch how {
	case "top", "bottom":
		best := blob[0]
		for _, p := range blob {
			if (how == "top" && p.Y < best.Y) || (how == "bottom" && p.Y > best.Y) {
				best = p
			}
		}
		return f(best.X, best.Y)
	case "light":
		v := math.Inf(-1)
		for _, p := range blob {
			v = math.Max(v, f(p.X, p.Y))
		}
		return v
	}
	sx, sy := 0.0, 0.0
	for _, p := range blob {
		sx += float64(p.X)
		sy += float64(p.Y)
	}
	n := float64(len(blob))
	return f(int(math.Round(sx/n)), int(math.Round(sy/n)))
}

func keySet(c *ctx, names []string) (map[pxlib.Key]bool, error) {
	out := map[pxlib.Key]bool{}
	for _, n := range names {
		k, err := c.Color(colorRef(n))
		if err != nil {
			return nil, err
		}
		out[k] = true
	}
	return out, nil
}

// footOf は塊の接地の画素（真下が塊の外）と、一番下の行。
func footOf(m pxlib.Mask) ([]pxlib.Pt, int) {
	var foot []pxlib.Pt
	bottom := -1
	for _, p := range m.Points() {
		if !m.At(p.X, p.Y+1) {
			foot = append(foot, p)
		}
		bottom = max(bottom, p.Y)
	}
	return foot, bottom
}

// castShape は塊を光と反対の地面へ倒した影の形: 一番下の行からの高さ h の画素を (x + kx·h, 一番下 + ky·h) へ写し、
// 行ごとに左端から右端までを埋める（写した点の間の穴を作らない）。
func castShape(m pxlib.Mask, w, h int, kx, ky float64) pxlib.Mask {
	out := pxlib.NewMask(w, h)
	_, bottom := footOf(m)
	if bottom < 0 {
		return out
	}
	lo, hi := map[int]int{}, map[int]int{}
	for _, p := range m.Points() {
		hh := float64(bottom - p.Y)
		x := int(math.Round(float64(p.X) + kx*hh))
		y := int(math.Round(float64(bottom) + ky*hh))
		if v, ok := lo[y]; !ok || x < v {
			lo[y] = x
		}
		if v, ok := hi[y]; !ok || x > v {
			hi[y] = x
		}
	}
	for y, x0 := range lo {
		for x := x0; x <= hi[y]; x++ {
			if x >= 0 && y >= 0 && x < w && y < h {
				out[y][x] = true
			}
		}
	}
	return out
}

func init() {
	register(&opDef{
		Name: "band_shift", Example: `{"band_shift": {"bands": 3, "field": "y", "by": "blob"}}`,
		Summary: "明るさの帯（光の向き・x・y・radial か光の範囲 center・r）を先に決め、塗ってある模様の色を帯ごとにランプで step 段ずつずらす" +
			"（暗い帯の先の色が明るい帯の胴の色になる。草・レンガ・石・地面に共通。by: blob / part で帯の境目を模様の塊に沿わせる）",
		Technique: "明るさの構造 → 1 段ずらし（帯か光の範囲を先に置き、模様の色を帯ごとに 1 段ずらす・光の範囲の中だけ色を上げる）",
		Finish:    "lint banding（帯が丸く見えたら by: blob）",
		Params: []param{
			pShape,
			{Name: "field", Type: tString, Default: "light", Summary: "帯を決める明るさの場: light（光の向き）・y（上が明るい）・x（右が明るい）・radial（塊の中心が明るい）。center を書くと光の範囲"},
			{Name: "center", Type: tPair, Summary: "光の範囲の中心 [x, y]（書くと field の代わりに、中心が 1・半径 r の外が 0 の場）"},
			{Name: "r", Type: tNumber, Default: 16.0, Summary: "光の範囲の半径（center の時）", Lo: bound(0.5), Hi: bound(1024)},
			{Name: "bands", Type: tInt, Default: 3.0, Summary: "帯の数（暗い帯から 0, 1, 2…）", Lo: bound(2), Hi: bound(8)},
			{Name: "cuts", Type: tNums, Len: -1, Summary: "帯の境目の明るさ（0〜1 を小さい順に bands − 1 個。省くと等分）"},
			{Name: "step", Type: tInt, Default: 1.0, Summary: "帯を 1 つ上がるごとにずらす段数", Lo: bound(-4), Hi: bound(4)},
			{Name: "base", Type: tInt, Default: 0.0, Summary: "一番暗い帯のずらし（-1 で暗い帯を 1 段下げる）", Lo: bound(-8), Hi: bound(8)},
			{Name: "invert", Type: tBool, Default: false, Summary: "明暗を返す"},
			{Name: "band", Type: tNumber, Default: 0.0, Summary: "帯の境目のうちディザで混ぜる割合（by: pixel だけ。cuts を書くと混ぜない）", Lo: bound(0), Hi: bound(1)},
			{Name: "by", Type: tString, Default: "pixel", Summary: "帯を決める単位: pixel（画素ごと）・blob（書いた部品が同じでつながった塊ごと）・part（書いた部品ごと）"},
			{Name: "sample", Type: tString, Default: "center", Summary: "塊の帯を読む所（blob・part の時）: center・top（背の高い葉の先で帯を破る）・bottom・light"},
			{Name: "seams", Type: tRows, Summary: "塊を切る色（目地・葉の間の影）。この色の画素は塊に入れず画素ごとにずらす"},
			{Name: "keep", Type: tRows, Summary: "ずらさない色（輪郭の墨など）"},
			{Name: "ramps", Type: tRows, Summary: "色を引くランプの名前（省くと部品のランプ・spec のランプ全部。色は最初に含むランプでずらす）"},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "banding"}},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			ramps, err := c.rampsFor(a.rows("ramps"))
			if err != nil {
				return err
			}
			seam, err := keySet(c, a.rows("seams"))
			if err != nil {
				return err
			}
			keep, err := keySet(c, a.rows("keep"))
			if err != nil {
				return err
			}
			bands := a.int("bands")
			cuts := nums(a.get("cuts"))
			if a.has("cuts") {
				if len(cuts) != bands-1 {
					return fmt.Errorf("cuts は bands − 1 = %d 個（今は %d 個）", bands-1, len(cuts))
				}
				if !sort.Float64sAreSorted(cuts) {
					return fmt.Errorf("cuts は小さい順に書く")
				}
			}
			var f func(x, y int) float64
			if a.has("center") {
				ctr := a.pair("center")
				f = rangeField(ctr[0]+float64(c.ox), ctr[1]+float64(c.oy), a.num("r"))
			} else if f, err = c.fieldOf(a.str("field"), m); err != nil {
				return err
			}
			if a.bool("invert") {
				g := f
				f = func(x, y int) float64 { return 1 - g(x, y) }
			}
			var pts []pxlib.Pt
			for _, p := range m.Points() {
				if k := c.G.At(p.X, p.Y); k != pxlib.Clear && !keep[k] {
					pts = append(pts, p)
				}
			}
			shiftOf := map[pxlib.Pt]int{}
			by := a.str("by")
			switch by {
			case "pixel":
			case "blob", "part":
				switch a.str("sample") {
				case "center", "top", "bottom", "light":
				default:
					return fmt.Errorf("sample は center・top・bottom・light")
				}
				for _, blob := range valueBlobs(c.G, pts, by, seam) {
					i := bandIndex(sampleOf(blob, f, a.str("sample")), 0, 0, bands, cuts, 0)
					for _, p := range blob {
						shiftOf[p] = i
					}
				}
			default:
				return fmt.Errorf("by は pixel・blob・part")
			}
			step, base := a.int("step"), a.int("base")
			for _, p := range pts {
				i, ok := shiftOf[p]
				if !ok {
					dx, dy := c.ditherAt(p.X, p.Y)
					band := a.num("band")
					if by != "pixel" {
						band = 0
					}
					i = bandIndex(f(p.X, p.Y), dx, dy, bands, cuts, band)
				}
				k := c.G.At(p.X, p.Y)
				if r := rampOf(ramps, k); r != nil {
					if to := shadeStep(r, k, base+i*step); to != k {
						c.PutAbs(p.X, p.Y, to)
					}
				}
			}
			return nil
		},
	})
	register(&opDef{
		Name: "cast_shadow", Example: `{"cast_shadow": {"of": "base", "contact": 1}}`,
		Summary: "形 of を光と反対の地面へ倒した落ち影を、受ける面 onto に塗ってある色を by 段ずらして落とす。" +
			"contact を書くと接地の所（of の真下が面に接する画素の近く）をさらに contact 段暗く（光の届かない一番暗い影）",
		Technique: "落ち影（受ける面への投影）・接地の一番暗い影（ambient occlusion）", Finish: "—",
		Params: []param{
			{Name: "of", Type: tString, Required: true, Summary: "影を落とす部品の id（この部品より前の列）"},
			{Name: "onto", Type: tString, Summary: "影を受ける部品の id（省くと of の外の塗ってある所全部）"},
			{Name: "by", Type: tInt, Default: -1.0, Summary: "落ち影のずらす段数（負で暗く）", Lo: bound(-8), Hi: bound(0)},
			{Name: "slant", Type: tPair, Default: []any{0.5, 0.2}, Summary: "高さ 1px ごとに影が伸びる量 [横, 縦]（光と反対の向きへ。縦が小さいほど地面に寝る）"},
			{Name: "contact", Type: tInt, Default: 0.0, Summary: "接地の所をさらに暗くする段数（0 で付けない）", Lo: bound(0), Hi: bound(4)},
			{Name: "contact_r", Type: tNumber, Default: 1.5, Summary: "接地の暗い影の広さ（of の接地の画素の真下からの距離）", Lo: bound(0.5), Hi: bound(16)},
			{Name: "ramps", Type: tRows, Summary: "色を引くランプの名前（省くと部品のランプ・spec のランプ全部）"},
		},
		Apply: func(c *ctx, a opArgs) error {
			src, ok := c.parts[a.str("of")]
			if !ok {
				return fmt.Errorf("部品 %q が無い", a.str("of"))
			}
			obj := src.Region()
			recv := c.G.Opaque()
			if n := a.str("onto"); n != "" {
				p, ok := c.parts[n]
				if !ok {
					return fmt.Errorf("部品 %q が無い", n)
				}
				recv = p.Region()
			}
			ramps, err := c.rampsFor(a.rows("ramps"))
			if err != nil {
				return err
			}
			sx, sy := c.LightSign()
			sl := a.pair("slant")
			shadow := castShape(obj, c.G.W, c.G.H, -float64(sx)*sl[0], -float64(sy)*sl[1])
			foot, _ := footOf(obj)
			r := a.num("contact_r")
			for _, p := range recv.Points() {
				if obj.At(p.X, p.Y) {
					continue
				}
				d := 0
				if shadow.At(p.X, p.Y) {
					d = a.int("by")
				}
				if a.int("contact") > 0 {
					for _, q := range foot {
						if math.Hypot(float64(p.X-q.X), float64(p.Y-q.Y-1)) <= r {
							d -= a.int("contact")
							break
						}
					}
				}
				if d == 0 {
					continue
				}
				k := c.G.At(p.X, p.Y)
				if rr := rampOf(ramps, k); rr != nil {
					if to := shadeStep(rr, k, d); to != k {
						c.PutAbs(p.X, p.Y, to)
					}
				}
			}
			return nil
		},
	})
}
