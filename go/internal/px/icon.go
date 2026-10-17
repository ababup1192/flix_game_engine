package px

// アイコン（小物）の形と op: 画素の範囲で書く角丸の矩形・輪（annulus）・アイコンの塗り（emblem・bevel）・
// 文字の格子の白抜き（glyph_rows）・1px の円（ring）・光の側で段を分ける（light_bands）・2 次ベジェの粒の線（curve）・
// 扇ごとに別の系統の色で塗り直す（parquet）・縮めて重ねる（scaled）。説明は各定義の Summary・Params にだけ書く。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// pVecPoints は小数も書ける折れ線の点（line・crack）。
var pVecPoints = param{Name: "points", Type: tVecs, Required: true, Min: 2, Summary: "折れ線の点 [[x, y], ...]（小数も可。画素には偶数丸めで落とす）"}

func init() {
	registerShape(&shapeKind{Name: "annulus", Summary: "輪（中心から r の円に沿った、幅 2w の帯）",
		Main: param{Type: tNums, Len: 4, Summary: "[cx, cy, r, w]"},
		Make: func(in shapeIn) sdf {
			p := in.nums
			return func(x, y float64) float64 { return math.Abs(hypot(x-p[0], y-p[1])-p[2]) - p[3] }
		}})
	registerShape(&shapeKind{Name: "roundRect", Summary: "画素の範囲で書く角丸の矩形（x0..x1・y0..y1 の画素を含み、角は内側へ r の丸。塗りの判定専用。smoothUnion・rounded には使えない）",
		Main: param{Type: tNums, Len: 5, Summary: "[x0, y0, x1, y1, r]"},
		Make: func(in shapeIn) sdf {
			p := in.nums
			x0, y0, x1, y1, r := p[0], p[1], p[2], p[3], p[4]
			// 返すのは内外の符号だけ。角は (x0+r, y0+r) などから距離² が r² + 0.5 まで（画素の中心でなく番号で測る）
			return func(x, y float64) float64 {
				px, py := math.Floor(x), math.Floor(y)
				if px < x0 || px > x1 || py < y0 || py > y1 {
					return 1
				}
				cx := math.Min(math.Max(px, x0+r), x1-r)
				cy := math.Min(math.Max(py, y0+r), y1-r)
				return float64((px-cx)*(px-cx)) + float64((py-cy)*(py-cy)) - float64(float64(r*r)+0.5)
			}
		}})

	register(&opDef{
		Name: "emblem", Example: `{"emblem": {"shape": {"roundRect": [3, 3, 9, 9, 1]}}}`,
		Summary:   "塊をアイコンの作りで塗る: 縁（4 近傍で外に接する画素）を edge、光の側の縁のすぐ内側 1 段を top、残りを face",
		Technique: "小さなアイコン（輪郭 + 平らな面 + 光の側のつや 1 段）", Finish: "地との明度差（縁の色が地に沈まないか）",
		Params: []param{
			pShape,
			{Name: "edge", Type: tColor, Default: "ink", Summary: "縁の色"},
			{Name: "face", Type: tColor, Default: "mid", Summary: "面の色"},
			{Name: "top", Type: tColor, Default: "light", Summary: "光の側（light.dir の上下）のつやの色"},
		},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			var keys [3]pxlib.Key
			for i, name := range []string{"edge", "face", "top"} {
				if keys[i], err = c.Color(a.color(name)); err != nil {
					return err
				}
			}
			_, sy := c.LightSign()
			if sy == 0 {
				sy = -1
			}
			for _, p := range m.Points() {
				k := keys[1]
				switch {
				case !m.At(p.X+1, p.Y) || !m.At(p.X-1, p.Y) || !m.At(p.X, p.Y+1) || !m.At(p.X, p.Y-1):
					k = keys[0]
				case !m.At(p.X, p.Y+2*sy):
					k = keys[2]
				}
				c.PutAbs(p.X, p.Y, k)
			}
			if a.has("shape") {
				c.AddRegion(m)
			}
			return nil
		},
	})

	register(&opDef{
		Name: "bevel", Example: `{"bevel": {"shape": {"disk": [8, 8, 4]}}}`,
		Summary:   "小物の陰の段: 光の側の縁を lit、影の側の縁（と影の向きへ 2 つ先が外の画素）を dark、中を face",
		Technique: "小物の陰影（縁で光と影を分ける）", Finish: "既存の lint banding",
		Params: []param{
			pShape,
			{Name: "lit", Type: tColor, Default: "light", Summary: "光の側の縁の色"},
			{Name: "face", Type: tColor, Default: "mid", Summary: "中の色"},
			{Name: "dark", Type: tColor, Default: "shade", Summary: "影の側の縁の色"},
		},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			var keys [3]pxlib.Key
			for i, name := range []string{"lit", "face", "dark"} {
				if keys[i], err = c.Color(a.color(name)); err != nil {
					return err
				}
			}
			sx, sy := c.LightSign()
			for _, p := range m.Points() {
				lit := (sx != 0 && !m.At(p.X+sx, p.Y)) || (sy != 0 && !m.At(p.X, p.Y+sy))
				dark := (sx != 0 && !m.At(p.X-sx, p.Y)) || (sy != 0 && !m.At(p.X, p.Y-sy)) || !m.At(p.X-2*sx, p.Y-2*sy)
				k := keys[1]
				switch {
				case dark:
					k = keys[2]
				case lit:
					k = keys[0]
				}
				c.PutAbs(p.X, p.Y, k)
			}
			if a.has("shape") {
				c.AddRegion(m)
			}
			return nil
		},
	})

	register(&opDef{
		Name: "glyph_rows", Example: `{"glyph_rows": {"at": [4, 4], "rows": ["##", "#."]}}`,
		Summary:   "文字の格子の白抜きの記号: '.' と空白でない字の画素を color で、その右下 1px に shadow の影（影を先に置く）",
		Technique: "白抜きの記号（小さなカード・効果のアイコン）", Finish: "—",
		Params: []param{
			{Name: "at", Type: tPoint, Required: true, Summary: "記号の左上 [x, y]"},
			{Name: "rows", Type: tRows, Required: true, Summary: "記号の行（'.' と空白は外）"},
			{Name: "color", Type: tColor, Default: "gloss", Summary: "記号の色"},
			{Name: "shadow", Type: tColor, Default: "shade", Summary: "右下 1px の影の色"},
		},
		Apply: func(c *ctx, a opArgs) error {
			fill, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			shadow, err := c.Color(a.color("shadow"))
			if err != nil {
				return err
			}
			at := a.point("at")
			for _, pass := range []struct {
				d int
				k pxlib.Key
			}{{1, shadow}, {0, fill}} {
				for dy, row := range a.rows("rows") {
					for dx, ch := range []rune(row) {
						if ch != '.' && ch != ' ' {
							c.Put(at.X+dx+pass.d, at.Y+dy+pass.d, pass.k)
						}
					}
				}
			}
			return nil
		},
	})

	register(&opDef{
		Name: "parquet", Example: `{"parquet": {"from": "r", "ramps": ["r", "r"]}}`,
		Summary:   "寄せ木: center から ramps の数に等分した扇ごとに、ランプ from の色をその扇のランプで塗り直す（from の墨は墨へ、ほかの段は斜めの帯で光・地・影へ。clip の部品なら親の塊の中だけ）",
		Technique: "寄せ木（かけらごとに別の系統の色）", Finish: "—",
		Params: []param{
			{Name: "from", Type: tString, Required: true, Summary: "塗り直す元のランプの名前"},
			{Name: "ramps", Type: tRows, Required: true, Summary: "扇ごとのランプの名前（start から時計回りに）"},
			{Name: "start", Type: tNumber, Default: -math.Pi / 2, Summary: "最初の扇の始まりの向き（ラジアン。既定は真上）"},
			{Name: "center", Type: tPair, Summary: "扇の中心 [x, y]（省くと格子の中央）"},
			{Name: "bands", Type: tPair, Default: []any{0.30, 0.72}, Summary: "光・地・影の境目（0〜1。左上の角が 0）"},
		},
		Apply: func(c *ctx, a opArgs) error {
			from := c.Spec.Ramps[a.str("from")]
			if len(from) < 4 {
				return fmt.Errorf("ramps に 4 段以上の %q が無い", a.str("from"))
			}
			var fans [][]pxlib.Key
			for _, name := range a.rows("ramps") {
				r := c.Spec.Ramps[name]
				if len(r) < 4 {
					return fmt.Errorf("ramps に 4 段以上の %q が無い", name)
				}
				fans = append(fans, r)
			}
			if len(fans) == 0 {
				return fmt.Errorf("ramps に 1 つ以上のランプの名前を書く")
			}
			ctr := [2]float64{float64(c.G.W) / 2, float64(c.G.H) / 2}
			if a.has("center") {
				ctr = a.pair("center")
			}
			b, start := a.pair("bands"), a.num("start")
			span := 2.0 * float64(c.G.W-1)
			turn := 2 * math.Pi
			for y := 0; y < c.G.H; y++ {
				for x := 0; x < c.G.W; x++ {
					old := c.G.At(x, y)
					ang := math.Mod(math.Atan2(float64(y)+0.5-ctr[1], float64(x)+0.5-ctr[0])-start, turn)
					if ang < 0 {
						ang += turn
					}
					r := fans[int(ang/(turn/float64(len(fans))))%len(fans)]
					t := float64(x+y) / span
					switch {
					case old == from[0]:
						c.PutAbs(x, y, r[0])
					case old == from[1] || old == from[2] || old == from[3]:
						k := r[1]
						if t < b[0] {
							k = r[3]
						} else if t < b[1] {
							k = r[2]
						}
						c.PutAbs(x, y, k)
					}
				}
			}
			return nil
		},
	})

	register(&opDef{
		Name: "scaled", Example: `{"scaled": {"macro": "eye", "scale": 0.5, "about": [8, 8]}}`,
		Summary:   "macros の op の列を別の格子に描き、about を中心に scale 倍へ縮め（広げ）て、塗った画素だけ重ねる（近い画素を引く）",
		Technique: "同じ記号を一回り小さく重ねる", Finish: "—",
		Params: []param{
			{Name: "macro", Type: tString, Required: true, Summary: "macros の名前"},
			{Name: "scale", Type: tNumber, Required: true, Summary: "大きさの倍率（0.72 なら 0.72 倍）", Lo: bound(0.01), Hi: bound(8)},
			{Name: "about", Type: tPair, Required: true, Summary: "縮める中心 [x, y]"},
		},
		Whole: true,
		Apply: func(c *ctx, a opArgs) error {
			body, ok := c.Spec.Macros[a.str("macro")]
			if !ok {
				return fmt.Errorf("macros に %q が無い", a.str("macro"))
			}
			if a.num("scale") <= 0 {
				return fmt.Errorf("scale は 0 より大きい数")
			}
			if c.depth >= 8 {
				return fmt.Errorf("use・scaled の入れ子が深すぎる（輪になっていないか）")
			}
			// 別の格子に、clip を外した同じ部品として描く
			sub := *c
			sub.G = pxlib.NewGrid(c.G.W, c.G.H)
			p := *c.Part.Part
			p.Clip = false
			sub.Part = &partState{Part: &p, Ramp: c.Part.Ramp, shape: c.Part.shape, written: pxlib.NewMask(c.G.W, c.G.H)}
			sub.depth++
			for _, call := range body {
				sub.ref = pxlib.OpRef{Part: c.ref.Part, Index: c.ref.Index, Op: c.ref.Op + ">" + call.Name}
				if err := sub.apply(call); err != nil {
					return err
				}
			}
			k, ab := a.num("scale"), a.pair("about")
			for y := 0; y < c.G.H; y++ {
				for x := 0; x < c.G.W; x++ {
					sx := int(math.Trunc(ab[0] + (float64(x)+0.5-ab[0])/k))
					sy := int(math.Trunc(ab[1] + (float64(y)+0.5-ab[1])/k))
					if src := sub.G.At(sx, sy); sub.G.In(sx, sy) && src != pxlib.Clear {
						c.PutAbs(x, y, src)
					}
				}
			}
			return nil
		},
	})

	register(&opDef{
		Name: "ring", Example: `{"ring": {"center": [7, 7], "r": 3, "color": "ink"}}`,
		Summary:   "1px の円を引く（ブレゼンハムの円。角の 2 重が出ず、どこでも 1 画素の太さ）",
		Technique: "円の線（Aseprite の Ellipse の線）", Finish: "既存の lint corner",
		Params: []param{
			{Name: "center", Type: tPoint, Required: true, Summary: "中心の画素 [x, y]"},
			{Name: "r", Type: tInt, Required: true, Summary: "半径（画素の数）", Lo: bound(0), Hi: bound(256)},
			pColor,
		},
		Apply: func(c *ctx, a opArgs) error {
			k, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			if a.int("r") < 1 {
				return fmt.Errorf("r は 1 以上")
			}
			for _, p := range ringCells(a.point("center"), a.int("r")) {
				c.Put(p.X, p.Y, k)
			}
			return nil
		},
	})

	register(&opDef{
		Name: "light_bands", Example: `{"light_bands": {"center": [7, 7], "cut": [1, -1]}}`,
		Summary:   "部品の塊の塗ってある画素を、中心から光の向き（light.dir）へどれだけ寄っているかで lit・base・dark の 3 段に塗り分ける",
		Technique: "光の側を明るく・影の側を暗く（縁の線の明暗）", Finish: "light-dir（段 3）",
		Params: []param{
			{Name: "center", Type: tPair, Required: true, Summary: "中心 [x, y]（画素の番号）"},
			{Name: "cut", Type: tPair, Default: []any{0.0, 0.0}, Summary: "[a, b]: 光への寄り（光の向きの符号で dx・dy を足した値）が a より大きければ lit、b より小さければ dark"},
			{Name: "lit", Type: tColor, Default: "light", Summary: "光の側の色"},
			{Name: "base", Type: tColor, Default: "mid", Summary: "あいだの色"},
			{Name: "dark", Type: tColor, Default: "shade", Summary: "影の側の色"},
		},
		Apply: func(c *ctx, a opArgs) error {
			var keys [3]pxlib.Key
			var err error
			for i, name := range []string{"lit", "base", "dark"} {
				if keys[i], err = c.Color(a.color(name)); err != nil {
					return err
				}
			}
			ctr, cut := a.pair("center"), a.pair("cut")
			sx, sy := c.LightSign()
			for _, p := range c.Region().Points() {
				if c.G.At(p.X, p.Y) == pxlib.Clear {
					continue
				}
				toward := (float64(p.X)-ctr[0])*float64(sx) + (float64(p.Y)-ctr[1])*float64(sy)
				k := keys[1]
				switch {
				case toward > cut[0]:
					k = keys[0]
				case toward < cut[1]:
					k = keys[2]
				}
				c.PutAbs(p.X, p.Y, k)
			}
			return nil
		},
	})

	register(&opDef{
		Name: "curve", Example: `{"curve": {"points": [[2, 2], [4, 12], [12, 10]], "color": "ink", "alt": "light"}}`,
		Summary:   "2 次ベジェを 1px の連なった線で引く（alt で 1 画素ごとに色を交互に・avoid の形の中は飛ばす）",
		Technique: "垂れた紐・鎖（粒を交互の明暗で）", Finish: "既存の lint corner",
		Params: []param{
			{Name: "points", Type: tVecs, Required: true, Min: 3, Max: 3, Summary: "始点・制御点・終点 [[x, y], [x, y], [x, y]]"},
			pColor,
			{Name: "alt", Type: tColor, Summary: "1 画素おきに置く 2 つ目の色（省くと color だけ）"},
			{Name: "avoid", Type: tShape, Summary: "画素の中心がこの形の中なら置かない（数にも入れない）"},
			{Name: "steps", Type: tInt, Default: 400.0, Summary: "曲線を刻む数（多いほど取りこぼしが無い）", Lo: bound(1), Hi: bound(10000)},
		},
		Apply: func(c *ctx, a opArgs) error {
			k, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			alt := k
			if a.has("alt") {
				if alt, err = c.Color(a.color("alt")); err != nil {
					return err
				}
			}
			var avoid sdf
			if a.has("avoid") {
				if avoid, err = shapeOf(a.shape("avoid"), c.Spec.Shapes, "avoid"); err != nil {
					return err
				}
			}
			if a.int("steps") < 1 {
				return fmt.Errorf("steps は 1 以上")
			}
			for i, p := range curveCells(vecs(a.get("points")), a.int("steps"), avoid) {
				if i%2 == 0 {
					c.Put(p.X, p.Y, k)
				} else {
					c.Put(p.X, p.Y, alt)
				}
			}
			return nil
		},
	})
}

// ringCells はブレゼンハム（中点）の円の画素。8 分の 1 を求めて 8 方へ写す。
func ringCells(o pxlib.Pt, r int) []pxlib.Pt {
	seen := map[pxlib.Pt]bool{}
	var out []pxlib.Pt
	x, y, e := r, 0, 1-r
	for x >= y {
		for _, d := range [8][2]int{{x, y}, {y, x}, {-y, x}, {-x, y}, {-x, -y}, {-y, -x}, {y, -x}, {x, -y}} {
			p := pxlib.Pt{X: o.X + d[0], Y: o.Y + d[1]}
			if !seen[p] {
				seen[p] = true
				out = append(out, p)
			}
		}
		y++
		if e < 0 {
			e += 2*y + 1
		} else {
			x--
			e += 2*(y-x) + 1
		}
	}
	return out
}

// curveCells は 2 次ベジェを steps 等分で刻み、画素（小数を切り捨て）の連なりにする。
// 続けて同じ画素は 1 回だけ。avoid の中（中心で距離 0 以下）の画素は置かず、続きの判定にも使わない。
func curveCells(pts [][2]float64, steps int, avoid sdf) []pxlib.Pt {
	var out []pxlib.Pt
	for i := 0; i <= steps; i++ {
		t := float64(i) / float64(steps)
		u := 1 - t
		// 積は 1 つずつ丸める（FMA にまとめると移す元の Python と画素がずれる）
		bx := float64(float64(u*u)*pts[0][0]) + float64(float64(float64(2*u)*t)*pts[1][0]) + float64(float64(t*t)*pts[2][0])
		by := float64(float64(u*u)*pts[0][1]) + float64(float64(float64(2*u)*t)*pts[1][1]) + float64(float64(t*t)*pts[2][1])
		p := pxlib.Pt{X: int(math.Trunc(bx)), Y: int(math.Trunc(by))}
		if len(out) > 0 && out[len(out)-1] == p {
			continue
		}
		if avoid != nil && avoid(float64(p.X)+0.5, float64(p.Y)+0.5) <= 0 {
			continue
		}
		out = append(out, p)
	}
	return out
}

// lerpCells は折れ線を画素に落とす（各区間を長い方の差 + 1 等分し、偶数丸め）。
func lerpCells(pts [][2]float64) []pxlib.Pt {
	var cells []pxlib.Pt
	for i := 0; i+1 < len(pts); i++ {
		ax, ay, bx, by := pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1]
		n := int(math.Max(math.Abs(bx-ax), math.Abs(by-ay))) + 1
		for k := 0; k <= n; k++ {
			t := float64(k) / float64(max(1, n))
			cells = append(cells, pxlib.Pt{X: int(math.RoundToEven(ax + float64((bx-ax)*t))), Y: int(math.RoundToEven(ay + float64((by-ay)*t)))})
		}
	}
	return cells
}
