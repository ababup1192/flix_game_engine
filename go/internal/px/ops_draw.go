package px

// 段 1 の op。説明は各 Op の Summary・Technique・Finish・Params にだけ書く。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

var (
	pShape    = Param{Name: "shape", Type: TShape, Summary: "形（省くと部品の塊）"}
	pColor    = Param{Name: "color", Type: TColor, Required: true, Summary: "色（ink・shade・mid・light・ramp[i]・gloss・色キー。\"\" で透明へ抜く）"}
	pPoints   = Param{Name: "points", Type: TPoints, Required: true, Summary: "折れ線の点 [[x, y], ...]"}
	pOptColor = Param{Name: "color", Type: TColor, Summary: "この色の画素だけを相手にする（省くと部品の全部）"}
)

func init() {
	Register(&Op{
		Name: "fill", Summary: "塊を 1 色で塗る",
		Technique: "塊で形を作る", Finish: "—",
		Params: []Param{pShape, pColor},
		Apply: func(c *Ctx, a Args) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			k, err := c.Color(a.Str("color"))
			if err != nil {
				return err
			}
			c.FillAbs(m, k)
			if a.Has("shape") {
				c.AddRegion(m)
			}
			return nil
		},
	})
	Register(&Op{
		Name: "put", Summary: "画素を直に置く",
		Technique: "1px を手で打つ（目・つや・星）", Finish: "既存の lint orphan",
		Params: []Param{{Name: "cells", Type: TPoints, Required: true, Summary: "画素の座標 [[x, y], ...]"}, pColor},
		Apply: func(c *Ctx, a Args) error {
			k, err := c.Color(a.Str("color"))
			if err != nil {
				return err
			}
			for _, p := range a.Points("cells") {
				c.Put(int(p[0]), int(p[1]), k)
			}
			return nil
		},
	})
	Register(&Op{
		Name: "line", Summary: "折れ線を 1px で引く（clip の部品なら親の塊の中だけ）",
		Technique: "1px の線", Finish: "既存の lint corner（角が 2 重なら pixel_perfect）",
		Params: []Param{pPoints, pColor},
		Apply: func(c *Ctx, a Args) error {
			k, err := c.Color(a.Str("color"))
			if err != nil {
				return err
			}
			pts := a.Points("points")
			if len(pts) < 2 {
				return fmt.Errorf("points は 2 点以上")
			}
			for _, q := range lerpCells(pts) {
				c.Put(q[0], q[1], k)
			}
			return nil
		},
	})
	Register(&Op{
		Name: "stamp", Summary: "文字の格子を押す（colors が無ければ legend の文字で打ち、'.' は透明へ抜く）",
		Technique: "手で打った小さな型を置く", Finish: "—",
		Params: []Param{
			{Name: "at", Type: TPoint, Required: true, Summary: "左上の位置 [x, y]"},
			{Name: "rows", Type: TRows, Required: true, Summary: "文字の行"},
			{Name: "colors", Type: TColorMap, Summary: "文字 → 色の名前（書いた文字だけ置く）"},
		},
		Apply: func(c *Ctx, a Args) error {
			at := a.Point("at")
			cols := a.ColorMap("colors")
			for dy, row := range a.Rows("rows") {
				for dx, ch := range []rune(row) {
					x, y := int(at[0])+dx, int(at[1])+dy
					switch {
					case a.Has("colors"):
						if name, ok := cols[string(ch)]; ok {
							k, err := c.Color(name)
							if err != nil {
								return err
							}
							c.Put(x, y, k)
						}
					case ch == '.':
						c.Put(x, y, pxlib.Clear)
					case ch != ' ':
						k, ok := c.keyOf[string(ch)]
						if !ok {
							return fmt.Errorf("文字 %q が legend に無い", string(ch))
						}
						c.Put(x, y, k)
					}
				}
			}
			return nil
		},
	})
	Register(&Op{
		Name: "use", Summary: "macros の op の列を、今の部品の中で順に当てる（at でずらせる）",
		Technique: "同じ部品を何か所にも置く・コマで体を上下させる", Finish: "—",
		Params: []Param{
			{Name: "macro", Type: TString, Required: true, Summary: "macros の名前"},
			{Name: "at", Type: TPoint, Summary: "ずらす量 [dx, dy]"},
		},
		Apply: func(c *Ctx, a Args) error {
			body, ok := c.Spec.Macros[a.Str("macro")]
			if !ok {
				return fmt.Errorf("macros に %q が無い", a.Str("macro"))
			}
			if c.depth >= 8 {
				return fmt.Errorf("use の入れ子が深すぎる（輪になっていないか）")
			}
			c.depth++
			at := a.Point("at")
			dx, dy := int(at[0]), int(at[1])
			c.ox, c.oy = c.ox+dx, c.oy+dy
			ref := c.ref
			defer func() { c.depth--; c.ox, c.oy = c.ox-dx, c.oy-dy; c.ref = ref }()
			for _, call := range body {
				c.ref = pxlib.OpRef{Part: ref.Part, Index: ref.Index, Op: ref.Op + ">" + call.Name}
				if err := c.apply(call); err != nil {
					return err
				}
			}
			return nil
		},
	})
	Register(&Op{
		Name: "flip", Summary: "格子全体を左右（x）か上下（y）に返す（右向きのコマから左向きを作る）",
		Technique: "向きの違うコマを鏡で作る", Finish: "—",
		Params: []Param{{Name: "axis", Type: TAxis, Default: "x", Summary: "\"x\" は左右・\"y\" は上下"}},
		Whole:  true,
		Apply: func(c *Ctx, a Args) error {
			c.G.Flip(a.Str("axis") == "y")
			return nil
		},
	})
	Register(&Op{
		Name: "outline", Summary: "部品の塊の外側 1px を 1 色で縁取る（sel_out の前身）",
		Technique: "輪郭（1 色の外側 1px）", Finish: "lint black-outline（段 3）",
		Params: []Param{{Name: "color", Type: TColor, Default: "ink", Summary: "縁の色"}},
		Apply: func(c *Ctx, a Args) error {
			k, err := c.Color(a.Str("color"))
			if err != nil {
				return err
			}
			c.FillAbs(c.Region().Outline(), k)
			return nil
		},
	})
	Register(&Op{
		Name: "shade_step", Summary: "塗ってある色を、部品のランプの隣の段へ by 段ずらす（端で止まる・ランプの外の色は触らない）",
		Technique: "1 段ずつ塗る（Aseprite の Shading ink）", Finish: "—",
		Params: []Param{
			{Name: "by", Type: TInt, Default: -1.0, Summary: "ずらす段数（負で暗く・正で明るく）"},
			pShape,
		},
		Apply: func(c *Ctx, a Args) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			ramp := c.Ramp()
			if len(ramp) == 0 {
				return fmt.Errorf("部品にランプが無い（部品かスプライトに \"ramp\" を書く）")
			}
			for _, p := range m.Points() {
				from := c.G.Px[p.Y][p.X]
				if to := ShadeStep(ramp, from, a.Int("by")); to != from {
					c.PutAbs(p.X, p.Y, to)
				}
			}
			return nil
		},
	})
	Register(&Op{
		Name: "pixel_perfect", Summary: "1px の線の L 字の角（ダブル）を左上から順に抜く",
		Technique: "pixel-perfect（Aseprite の Pencil の Pixel Perfect）", Finish: "既存の lint corner",
		Params: []Param{pOptColor},
		Checks: []string{"sprite:corner"},
		Apply: func(c *Ctx, a Args) error {
			region := c.Region()
			want := pxlib.Key("")
			if a.Has("color") {
				k, err := c.Color(a.Str("color"))
				if err != nil {
					return err
				}
				want = k
			}
			m := pxlib.NewMask(c.G.W, c.G.H)
			for _, p := range region.Points() {
				k := c.G.Px[p.Y][p.X]
				m[p.Y][p.X] = k != pxlib.Clear && (want == "" || k == want)
			}
			kept := PixelPerfect(m)
			for _, p := range m.Points() {
				if !kept[p.Y][p.X] {
					c.PutAbs(p.X, p.Y, pxlib.Clear)
				}
			}
			return nil
		},
	})
}

// ShadeStep は color をランプの段で d だけずらす。端で止まる。ランプの外の色はそのまま返す。
func ShadeStep(ramp []string, color pxlib.Key, d int) pxlib.Key {
	for i, k := range ramp {
		if pxlib.Key(k) == color {
			return pxlib.Key(ramp[max(0, min(len(ramp)-1, i+d))])
		}
	}
	return color
}

// PixelPerfect は 1px の線の塊から、L 字の角の画素を抜いた塊を返す。左上から順に 1 つずつ抜く。
// 抜くのは次の 3 つがそろう画素: 横の隣と縦の隣が 1 つずつある・その 2 つの間の斜めが空いている・
// 残りの 8 近傍はどれもその 2 つのどちらかと 8 近傍でつながる。
func PixelPerfect(m pxlib.Mask) pxlib.Mask {
	out := pxlib.NewMask(m.W(), m.H())
	for y := range m {
		copy(out[y], m[y])
	}
	for y := range out {
		for x := range out[y] {
			if !out[y][x] {
				continue
			}
			var hs, vs []int
			for _, d := range [2]int{-1, 1} {
				if out.At(x+d, y) {
					hs = append(hs, d)
				}
				if out.At(x, y+d) {
					vs = append(vs, d)
				}
			}
			if len(hs) != 1 || len(vs) != 1 || out.At(x+hs[0], y+vs[0]) {
				continue // 角でない・2×2 の太い所は残す
			}
			keep := [2]pxlib.Pt{{X: x + hs[0], Y: y}, {X: x, Y: y + vs[0]}}
			ok := true
			for dy := -1; dy <= 1 && ok; dy++ {
				for dx := -1; dx <= 1; dx++ {
					q := pxlib.Pt{X: x + dx, Y: y + dy}
					if (dx == 0 && dy == 0) || !out.At(q.X, q.Y) || q == keep[0] || q == keep[1] {
						continue
					}
					near := false
					for _, k := range keep {
						if abs(q.X-k.X) <= 1 && abs(q.Y-k.Y) <= 1 {
							near = true
						}
					}
					if !near {
						ok = false
						break
					}
				}
			}
			if ok {
				out[y][x] = false // 抜いても周りはつながったまま
			}
		}
	}
	return out
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// lerpCells は折れ線を画素に落とす（各区間を長い方の差 + 1 等分し、偶数丸め）。
func lerpCells(pts [][2]float64) [][2]int {
	var cells [][2]int
	for i := 0; i+1 < len(pts); i++ {
		ax, ay, bx, by := pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1]
		n := int(math.Max(math.Abs(bx-ax), math.Abs(by-ay))) + 1
		for k := 0; k <= n; k++ {
			t := float64(k) / float64(max(1, n))
			cells = append(cells, [2]int{int(math.RoundToEven(ax + float64((bx-ax)*t))), int(math.RoundToEven(ay + float64((by-ay)*t)))})
		}
	}
	return cells
}
