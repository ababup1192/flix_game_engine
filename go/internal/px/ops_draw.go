package px

// 段 1 の op。説明は各 Op の Summary・Technique・Finish・Params にだけ書く。

import (
	"fmt"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

var (
	pShape    = param{Name: "shape", Type: tShape, Summary: "形（省くと部品の塊）"}
	pColor    = param{Name: "color", Type: tColor, Required: true, Summary: "色（ink・shade・mid・light・ramp[i]・gloss・key:名前・色キー。\"\" で透明へ抜く）"}
	pOptColor = param{Name: "color", Type: tColor, Summary: "この色の画素だけを相手にする（省くと部品の全部）"}
)

func init() {
	register(&opDef{
		Name: "fill", Example: `{"fill": {"color": "shade"}}`, Summary: "塊を 1 色で塗る",
		Technique: "塊で形を作る", Finish: "—",
		Params: []param{pShape, pColor},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			k, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			c.FillAbs(m, k)
			if a.has("shape") {
				c.AddRegion(m)
			}
			return nil
		},
	})
	register(&opDef{
		Name: "put", Example: `{"put": {"cells": [[4, 4], [5, 4]], "color": "light"}}`, Summary: "画素を直に置く",
		Technique: "1px を手で打つ（目・つや・星）", Finish: "既存の lint orphan",
		Params: []param{{Name: "cells", Type: tPoints, Required: true, Summary: "画素の座標 [[x, y], ...]"}, pColor},
		Apply: func(c *ctx, a opArgs) error {
			k, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			for _, p := range a.points("cells") {
				c.Put(p.X, p.Y, k)
			}
			return nil
		},
	})
	register(&opDef{
		Name: "line", Example: `{"line": {"points": [[3, 3], [8, 6]], "color": "ink"}}`, Summary: "折れ線を 1px で引く（clip の部品なら親の塊の中だけ）",
		Technique: "1px の線", Finish: "既存の lint corner（角が 2 重の画素）",
		Params: []param{pVecPoints, pColor},
		Apply: func(c *ctx, a opArgs) error {
			k, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			pts := a.points("points")
			if len(pts) < 2 {
				return fmt.Errorf("points は 2 点以上")
			}
			for _, q := range lerpCells(vecs(a.get("points"))) {
				c.Put(q.X, q.Y, k)
			}
			return nil
		},
	})
	register(&opDef{
		Name: "stamp", Example: `{"stamp": {"at": [3, 3], "rows": ["#.", ".#"], "colors": {"#": "light"}}}`, Summary: "文字の格子を押す（colors が無ければ legend の文字で打ち、'.' は透明へ抜く）",
		Technique: "手で打った小さな型を置く", Finish: "—",
		Params: []param{
			{Name: "at", Type: tPoint, Required: true, Summary: "左上の位置 [x, y]"},
			{Name: "rows", Type: tRows, Required: true, Summary: "文字の行"},
			{Name: "colors", Type: tColorMap, Summary: "文字 → 色の名前（書いた文字だけ置く）"},
		},
		Apply: func(c *ctx, a opArgs) error {
			at := a.point("at")
			cols := a.colorMap("colors")
			for dy, row := range a.rows("rows") {
				for dx, ch := range []rune(row) {
					x, y := at.X+dx, at.Y+dy
					switch {
					case a.has("colors"):
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
	register(&opDef{
		Name: "pixels", Example: `{"pixels": {"rows": ["ab", ".a"], "colors": {"a": "mid", "b": "light"}}}`,
		Summary:   "台本の格子（px.canvas の to_op）を書き出す: 文字の行と、文字 → 色の名前（'.' と colors に無い字は置かない）",
		Technique: "原理を台本で組んだ画素の格子をそのまま置く（stamp の大きさの目安を当てない）", Finish: "—",
		Params: []param{
			{Name: "rows", Type: tRows, Required: true, Summary: "文字の行（格子の大きさ）"},
			{Name: "colors", Type: tColorMap, Required: true, Summary: "文字 → 色の名前"},
			{Name: "at", Type: tPoint, Summary: "左上の位置 [x, y]（省くと [0, 0]）"},
		},
		Apply: func(c *ctx, a opArgs) error {
			at := a.point("at")
			cols := a.colorMap("colors")
			for dy, row := range a.rows("rows") {
				for dx, ch := range []rune(row) {
					if name, ok := cols[string(ch)]; ok {
						k, err := c.Color(name)
						if err != nil {
							return err
						}
						c.Put(at.X+dx, at.Y+dy, k)
					}
				}
			}
			return nil
		},
	})
	register(&opDef{
		Name: "use", Example: `{"use": {"macro": "eye", "at": [1, 0]}}`, Summary: "macros の op の列を、今の部品の中で順に当てる（at でずらせる）",
		Technique: "同じ部品を何か所にも置く・コマで体を上下させる", Finish: "—",
		Params: []param{
			{Name: "macro", Type: tString, Required: true, Summary: "macros の名前"},
			{Name: "at", Type: tPoint, Summary: "ずらす量 [dx, dy]"},
		},
		Apply: func(c *ctx, a opArgs) error {
			body, ok := c.Spec.Macros[a.str("macro")]
			if !ok {
				return fmt.Errorf("macros に %q が無い", a.str("macro"))
			}
			if c.depth >= 8 {
				return fmt.Errorf("use の入れ子が深すぎる（輪になっていないか）")
			}
			c.depth++
			at := a.point("at")
			dx, dy := at.X, at.Y
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
	register(&opDef{
		Name: "flip", Example: `{"flip": {"axis": "x"}}`, Summary: "格子全体を左右（x）か上下（y）に返す（右向きのコマから左向きを作る）",
		Technique: "向きの違うコマを鏡で作る", Finish: "—",
		Params:   []param{{Name: "axis", Type: tAxis, Default: "x", Summary: "\"x\" は左右・\"y\" は上下"}},
		Whole:    true,
		PostOnly: true,
		Apply: func(c *ctx, a opArgs) error {
			c.G.Flip(a.str("axis") == "y")
			return nil
		},
	})
	register(&opDef{
		Name: "outline", Example: `{"outline": {"color": "ink"}}`, Summary: "部品の塊の外側 1px を 1 色で縁取る（sel_out の前身）",
		Technique: "輪郭（1 色の外側 1px）", Finish: "lint black-outline（部品ごとの色にするなら sel_out）",
		Params: []param{{Name: "color", Type: tColor, Default: "ink", Summary: "縁の色"}},
		Checks: []checkRef{{Check: checkBlackOutline}},
		Apply: func(c *ctx, a opArgs) error {
			k, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			c.FillAbs(c.Region().Outline(), k)
			return nil
		},
	})
	register(&opDef{
		Name: "shade_step", Example: `{"shade_step": {"by": -1, "shape": {"rect": [3, 3, 3, 6]}}}`, Summary: "塗ってある色を、部品のランプの隣の段へ by 段ずらす（端で止まる・ランプの外の色は触らない）",
		Technique: "1 段ずつ塗る（Aseprite の Shading ink）", Finish: "—",
		Params: []param{
			{Name: "by", Type: tInt, Default: -1.0, Summary: "ずらす段数（負で暗く・正で明るく）", Lo: bound(-8), Hi: bound(8)},
			pShape,
		},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			ramp := c.Ramp()
			if len(ramp) == 0 {
				return fmt.Errorf("部品にランプが無い（部品かスプライトに \"ramp\" を書く）")
			}
			for _, p := range m.Points() {
				from := c.G.At(p.X, p.Y)
				if to := shadeStep(ramp, from, a.int("by")); to != from {
					c.PutAbs(p.X, p.Y, to)
				}
			}
			return nil
		},
	})
}

// shadeStep は color をランプの段で d だけずらす。端で止まる。ランプの外の色はそのまま返す。
func shadeStep(ramp []pxlib.Key, color pxlib.Key, d int) pxlib.Key {
	for i, k := range ramp {
		if k == color {
			return ramp[max(0, min(len(ramp)-1, i+d))]
		}
	}
	return color
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
