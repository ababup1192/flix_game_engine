package px

// 質感の op: 2〜4px の塊を散らす（scatter_clusters）・2 色を混ぜて中間を作る（dither_pair）。
// どれも決定的。乱数は使わず座標のハッシュで散らす（描き直すたびに絵が変わると周回で比べられない）。
// 変種（variants.seeds）は seed に足すだけで、同じ seed なら同じ絵になる。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// hash01 は座標の整数ハッシュを 0〜1 に（bin/pxkit/paint.py と同じ値）。
func hash01(x, y, seed int) float64 {
	h := (int64(x)*374761393 + int64(y)*668265263 + int64(seed)*2246822519) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h ^= h >> 16
	return float64(h) / 4294967296.0
}

// scatterPoints は w×h の中に、cell 間隔の升目を基準に少しずつずらした点を返す（升目 1 つに 1 点まで）。
func scatterPoints(w, h, cell, seed int, jitter, keep float64) []pxlib.Pt {
	var pts []pxlib.Pt
	c := float64(cell)
	for j := 0; j < (h+cell-1)/cell; j++ {
		for i := 0; i < (w+cell-1)/cell; i++ {
			if hash01(i, j, seed) >= keep {
				continue
			}
			ox := (hash01(i, j, seed+101) - 0.5) * jitter * c
			oy := (hash01(i, j, seed+202) - 0.5) * jitter * c
			x, y := int(float64(float64(i)*c)+c/2+ox), int(float64(float64(j)*c)+c/2+oy)
			if x >= 0 && x < w && y >= 0 && y < h {
				pts = append(pts, pxlib.Pt{X: x, Y: y})
			}
		}
	}
	return pts
}

// clusterKinds は散らす塊の型（2〜3px。見比べで 4px の塊は「ぼやっと・ジェルっぽい」と負けた）。blob は葉・石の斑、line は木目の筋、crack はひび。
var clusterKinds = map[string][][]string{
	"blob":  {{"##"}, {"#", "#"}, {"##", "#."}, {"##", ".#"}, {".#", "##"}, {"#.", "##"}, {"###"}, {"#", "#", "#"}},
	"line":  {{"###"}, {"##"}, {"###"}, {"##"}},
	"crack": {{"##.", "..#"}, {".##", "#.."}, {"#.", ".#", ".#"}, {".#", "#.", "#."}},
}

// scatterClusters は塊 m の中に小さな塊を colors から散らして打ち、打った画素と色を返す。
// mask の外にはみ出す塊・既にある塊と重なるか辺で接する塊は飛ばす（角は可）。wrap は座標を w・h で回す。
func scatterClusters(w, h int, m pxlib.Mask, colors []pxlib.Key, kind string, cell, seed int, keep float64, wrap bool) (map[pxlib.Pt]pxlib.Key, int) {
	shapes := clusterKinds[kind]
	out := map[pxlib.Pt]pxlib.Key{}
	taken := map[pxlib.Pt]bool{}
	at := func(x, y int) pxlib.Pt {
		if wrap {
			return pxlib.Pt{X: ((x % w) + w) % w, Y: ((y % h) + h) % h}
		}
		return pxlib.Pt{X: x, Y: y}
	}
	n := 0
	for _, p := range scatterPoints(w, h, cell, seed, 0.8, keep) {
		shape := shapes[int(hash01(p.X, p.Y, seed+7)*float64(len(shapes)))]
		var cells []pxlib.Pt
		for dy, row := range shape {
			for dx, ch := range row {
				if ch == '#' {
					cells = append(cells, at(p.X+dx, p.Y+dy))
				}
			}
		}
		ok := true
		for _, q := range cells {
			if q.X < 0 || q.X >= w || q.Y < 0 || q.Y >= h || !m.At(q.X, q.Y) || taken[q] {
				ok = false
			}
			for _, d := range pxlib.Dirs4 {
				if taken[at(q.X+d.X, q.Y+d.Y)] {
					ok = false
				}
			}
		}
		if !ok {
			continue
		}
		col := colors[int(hash01(p.X, p.Y, seed+11)*float64(len(colors)))]
		for _, q := range cells {
			out[q] = col
			taken[q] = true
		}
		n++
	}
	return out, n
}

// ditherPair は Yliluoma の 1 番目の作り方の 2 色版: 候補の 2 色 (a, b) と混ぜる割合 r/16 のうち、
// 混ぜた色（線形 RGB で混ぜる）と狙いの色の差（Oklab）＋ 2 色の差 × ditherPenalty × (|r/16 − 0.5| + 0.5) が一番小さい組を選ぶ。
// 原典の重み 0.1 は RGB の差の物で、Oklab の差では遠い 2 色を嫌いすぎて白黒の中間が作れないので 0.03（仮置き）。
func ditherPair(target string, cands []pxlib.Key, hexOf map[pxlib.Key]string) (a, b pxlib.Key, ratio float64, err error) {
	tc, ok := pxlib.RGBAOfValue(target)
	if !ok {
		return "", "", 0, fmt.Errorf("狙いの色 %q が #rrggbb でも色キーでもない", target)
	}
	tl := pxlib.OklabOfRGBA(tc)
	lin := func(c pxlib.RGBA) [3]float64 {
		return [3]float64{srgbLin(c[0]), srgbLin(c[1]), srgbLin(c[2])}
	}
	type col struct {
		k   pxlib.Key
		lin [3]float64
		lab pxlib.Oklab
	}
	var cs []col
	for _, k := range cands {
		c, ok := pxlib.RGBAOfValue(hexOf[k])
		if !ok {
			continue
		}
		cs = append(cs, col{k, lin(c), pxlib.OklabOfRGBA(c)})
	}
	if len(cs) == 0 {
		return "", "", 0, fmt.Errorf("候補の色が無い")
	}
	d2 := func(p, q pxlib.Oklab) float64 {
		return labDist2(p, q)
	}
	best := math.Inf(1)
	for i := range cs {
		for j := i; j < len(cs); j++ {
			pen := d2(cs[i].lab, cs[j].lab)
			for r := 0; r <= 16; r++ {
				t := float64(r) / 16
				var mix pxlib.RGBA
				for ch := 0; ch < 3; ch++ {
					mix[ch] = linSrgb(float64(cs[i].lin[ch]*(1-t)) + float64(cs[j].lin[ch]*t))
				}
				mix[3] = 255
				s := d2(tl, pxlib.OklabOfRGBA(mix)) + float64(pen*ditherPenalty*(math.Abs(t-0.5)+0.5))
				if s < best {
					best, a, b, ratio = s, cs[i].k, cs[j].k, t
				}
			}
		}
	}
	return a, b, ratio, nil
}

const ditherPenalty = 0.03

func srgbLin(c byte) float64 {
	v := float64(c) / 255
	if v <= 0.04045 {
		return v / 12.92
	}
	return math.Pow((v+0.055)/1.055, 2.4)
}

func linSrgb(v float64) byte {
	v = math.Max(0, math.Min(1, v))
	if v <= 0.0031308 {
		v *= 12.92
	} else {
		v = float64(1.055*math.Pow(v, 1/2.4)) - 0.055
	}
	return byte(math.Round(v * 255))
}

func (c *ctx) colorList(refs []string) ([]pxlib.Key, error) {
	var out []pxlib.Key
	for _, r := range refs {
		k, err := c.Color(colorRef(r))
		if err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, nil
}

func init() {
	register(&opDef{
		Name: "scatter_clusters", Example: `{"scatter_clusters": {"colors": ["shade"], "cell": 3, "seed": 1}}`,
		Summary:   "塊の中に 2〜3px の小さな塊を散らして打つ（辺で接しない・1px の単発は出ない。wrap でタイルの端を回す）",
		Technique: "質感（岩・レンガ・草）・塊と孤立 1px・草のタイル（Aseprite の Tiled Mode）", Finish: "既存の lint orphan・2×2 に並べて見る（tile_preview）",
		Params: []param{
			pShape,
			{Name: "colors", Type: tRows, Default: []any{"shade"}, Summary: "打つ色の並び（塊ごとにハッシュで選ぶ）"},
			{Name: "kind", Type: tString, Default: "blob", Summary: "塊の型: blob（葉・石の斑）・line（木目の筋）・crack（ひび）"},
			{Name: "cell", Type: tInt, Default: 3.0, Summary: "散らす升目の大きさ（小さいほど密）", Lo: bound(1), Hi: bound(64)},
			{Name: "seed", Type: tInt, Default: 0.0, Summary: "散らし方の番号（variants の seed が足される）", Lo: bound(0), Hi: bound(1 << 20)},
			{Name: "keep", Type: tNumber, Default: 1.0, Summary: "升目に塊を置く割合（0〜1）", Lo: bound(0), Hi: bound(1)},
			{Name: "wrap", Type: tBool, Default: false, Summary: "タイルの端をまたいで反対側へ回す（並べた継ぎ目を隠す）"},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			if _, ok := clusterKinds[a.str("kind")]; !ok {
				return fmt.Errorf("kind は blob・line・crack")
			}
			if a.int("cell") < 1 {
				return fmt.Errorf("cell は 1 以上")
			}
			cols, err := c.colorList(a.rows("colors"))
			if err != nil {
				return err
			}
			if len(cols) == 0 {
				return fmt.Errorf("colors が空")
			}
			c.wrap = c.wrap || a.bool("wrap")
			px, _ := scatterClusters(c.G.W, c.G.H, m, cols, a.str("kind"), a.int("cell"), a.int("seed")+c.Seed*7919, a.num("keep"), a.bool("wrap"))
			c.dropPixels(px)
			return nil
		},
	})
	register(&opDef{
		Name: "dither_pair", Example: `{"dither_pair": {"color": "#808080"}}`,
		Summary:   "色票に無い中間の色を、候補の 2 色の Bayer の混ぜで作って塊を塗る（Yliluoma の 2 色版）",
		Technique: "ディザ（タイルパターン。50% の市松で中間を作る）", Finish: "既存の lint banding・flat-run",
		Params: []param{
			pShape,
			{Name: "color", Type: tString, Required: true, Summary: "狙いの色（#rrggbb か色キー）"},
			{Name: "among", Type: tRows, Summary: "混ぜる候補の色（省くと部品のランプ）"},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "banding"}, {Check: checkFlatRun}},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			cands := c.Ramp()
			if a.has("among") {
				if cands, err = c.colorList(a.rows("among")); err != nil {
					return err
				}
			}
			target := a.str("color")
			if h, ok := c.hexOf[pxlib.Key(target)]; ok {
				target = h
			}
			ka, kb, r, err := ditherPair(target, cands, c.hexOf)
			if err != nil {
				return err
			}
			for _, p := range m.Points() {
				k := ka
				if dx, dy := c.ditherAt(p.X, p.Y); bayer(dx, dy) < r {
					k = kb
				}
				c.PutAbs(p.X, p.Y, k)
			}
			if a.has("shape") {
				c.AddRegion(m)
			}
			return nil
		},
	})
}

// courses は互い違いの格子の目地の画素: 段の高さ h ごとに横の目地、段ごとに offset×w ずらした幅 w ごとに縦の目地
// （origin が目地の通る列と行。vertical が false なら横の目地だけ）。
func courses(m pxlib.Mask, w, h int, origin pxlib.Pt, offset float64, vertical bool) []pxlib.Pt {
	floorMod := func(a, n int) int { return ((a % n) + n) % n }
	shift := int(math.Round(float64(w) * offset))
	var out []pxlib.Pt
	for _, p := range m.Points() {
		dy := p.Y - origin.Y
		row := (dy - floorMod(dy, h)) / h
		joint := floorMod(dy, h) == 0
		if !joint && vertical {
			joint = floorMod(p.X-origin.X-floorMod(row, 2)*shift, w) == 0
		}
		if joint {
			out = append(out, p)
		}
	}
	return out
}

func init() {
	register(&opDef{
		Name: "courses", Example: `{"courses": {"size": [8, 5], "origin": [2, 3]}}`,
		Summary:   "煉瓦・瓦・石積みの目地を引く: 段の高さごとに横の目地、段ごとに半分（offset）ずらした幅ごとに縦の目地（部品の塊の中だけ。色は下の色を by 段暗く）",
		Technique: "敷き詰め（煉瓦・瓦は段ごとに半分ずらす。目地は面より暗い 1px）", Finish: "lint banding・flat-run",
		Params: []param{
			pShape,
			{Name: "size", Type: tPair, Default: []any{8.0, 4.0}, Summary: "1 個の大きさ [幅, 段の高さ]（目地の 1px を含む。2 以上の整数）"},
			{Name: "origin", Type: tPoint, Default: []any{0.0, 0.0}, Summary: "横の目地が通る行・1 段目の縦の目地が通る列 [x, y]（部品の at でずれる）"},
			{Name: "offset", Type: tNumber, Default: 0.5, Summary: "1 段ごとの縦の目地のずらし（幅に対する割合。0 で揃う・0.5 で半分）", Lo: bound(0), Hi: bound(1)},
			{Name: "vertical", Type: tBool, Default: true, Summary: "縦の目地も引く（false で横の目地だけ = 板張り・瓦の段）"},
			{Name: "color", Type: tColor, Summary: "目地の色（省くと下の色を by 段ずらす）"},
			{Name: "by", Type: tInt, Default: -1.0, Summary: "color を省いた時に下の色をランプでずらす段数（負で暗く）", Lo: bound(-4), Hi: bound(4)},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "banding"}},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			sz := a.pair("size")
			w, h := int(sz[0]), int(sz[1])
			if float64(w) != sz[0] || float64(h) != sz[1] || w < 2 || h < 2 {
				return fmt.Errorf("size は 2 以上の整数 2 つ [幅, 段の高さ]（got %v）", sz)
			}
			var fixed pxlib.Key
			hasColor := a.has("color")
			if hasColor {
				if fixed, err = c.Color(a.color("color")); err != nil {
					return err
				}
			}
			o := a.point("origin")
			ramps := c.allRamps()
			for _, p := range courses(m, w, h, pxlib.Pt{X: o.X + c.ox, Y: o.Y + c.oy}, a.num("offset"), a.bool("vertical")) {
				k := fixed
				if !hasColor {
					cur := c.G.At(p.X, p.Y)
					if cur == pxlib.Clear {
						continue
					}
					k = shadeStep(rampOf(ramps, cur), cur, a.int("by"))
				}
				c.PutAbs(p.X, p.Y, k)
			}
			return nil
		},
	})
}
