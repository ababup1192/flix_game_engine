package px

// 技法帳の部品（段 2）: 機械的に表せて幅を狭めない物だけ（「技法を丸ごとやる」高い所の op は作らない）。
//
//	tile_wrap_offset  格子をタイルとして 50% ずらす（継ぎ目を中央に出して直す → もう一度ずらして戻す）
//	rim_light         部品の外形の光の側の 1px（縁の光の置き場だけを決める。色は呼ぶ側）
//	panel_seams       点検の継ぎ目（step ごとの 1px の線）と四隅のネジ
//	hazard_stripes    45° の縞（幅 width px）を 2 色で

import (
	"fmt"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

func init() {
	register(&opDef{
		Name: "tile_wrap_offset", Example: `{"tile_wrap_offset": {}}`,
		Summary:   "格子全体をタイルとして回してずらす（既定は縦横 50%）。post の前にずらして継ぎ目を中央に出し、そこを描き直してから、もう一度ずらして戻す",
		Technique: "四辺で繋がる元タイル（粗く描く → 50% ずらす → 中央の継ぎ目を直す → もう一度ずらして確かめる）", Finish: "lint seam",
		Params: []param{
			{Name: "by", Type: tPair, Summary: "ずらす量 [dx, dy]（省くと [幅/2, 高さ/2]）"},
		},
		Whole: true, PostOnly: true,
		Checks: []checkRef{{Check: checkSeam}},
		Apply: func(c *ctx, a opArgs) error {
			dx, dy := c.G.W/2, c.G.H/2
			if a.has("by") {
				p := a.pair("by")
				dx, dy = int(p[0]), int(p[1])
			}
			c.G.Wrap(dx, dy)
			c.wrap = true
			return nil
		},
	})
	register(&opDef{
		Name: "rim_light", Example: `{"rim_light": {"color": "light"}}`,
		Summary:   "部品の外形（外が透明か、against:any でほかの部品）の光の側（light.dir）の 1px を color で塗る。縁の光の置き場だけを決める",
		Technique: "縁の光（リム）は光源の側の外周 1px だけ・明るい側の背景は暗く", Finish: "advice light-dir",
		Params: []param{
			{Name: "color", Type: tColor, Default: "light", Summary: "縁の光の色"},
			{Name: "side", Type: tPair, Summary: "光の来る向き [x, y]（省くと light.dir）"},
			pAgainst,
		},
		Checks: []checkRef{{Check: checkLightDir}},
		Apply: func(c *ctx, a opArgs) error {
			k, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			sx, sy := c.LightSign()
			if a.has("side") {
				p := a.pair("side")
				sx, sy = signOf(p[0]), signOf(p[1])
			}
			if sx == 0 && sy == 0 {
				return fmt.Errorf("光の向きが無い（light.dir か side を書く）")
			}
			m := c.Region()
			any := a.str("against") == "any"
			outside := func(x, y int) bool {
				if !c.G.In(x, y) {
					return true
				}
				if any {
					return !m.At(x, y)
				}
				return c.G.At(x, y) == pxlib.Clear
			}
			for _, p := range m.Points() {
				if (sx != 0 && outside(p.X+sx, p.Y)) || (sy != 0 && outside(p.X, p.Y+sy)) {
					c.PutAbs(p.X, p.Y, k)
				}
			}
			return nil
		},
	})
	register(&opDef{
		Name: "panel_seams", Example: `{"panel_seams": {"step": [8, 8]}}`,
		Summary:   "部品の塊を step ごとの 1px の継ぎ目で区切り、区切った面の四隅の内側に screw のネジを打つ（線の色は下の色を by 段ずらす）",
		Technique: "点検の継ぎ目で面を区切り四隅にネジ（同じ模様を繰り返す）", Finish: "lint banding",
		Params: []param{
			pShape,
			{Name: "step", Type: tPair, Default: []any{8.0, 8.0}, Summary: "継ぎ目の間隔 [横, 縦]（2 以上の整数）"},
			{Name: "origin", Type: tPoint, Default: []any{0.0, 0.0}, Summary: "継ぎ目が通る列と行 [x, y]"},
			{Name: "by", Type: tInt, Default: -1.0, Summary: "継ぎ目の色: 下の色をランプでずらす段数", Lo: bound(-4), Hi: bound(4)},
			{Name: "screw", Type: tColor, Summary: "ネジの色（省くとネジを打たない）"},
		},
		Checks: []checkRef{{Check: checkSprite, Rule: "banding"}},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			st := a.pair("step")
			w, h := int(st[0]), int(st[1])
			if w < 2 || h < 2 {
				return fmt.Errorf("step は 2 以上の整数 [横, 縦]")
			}
			o := a.point("origin")
			ox, oy := o.X+c.ox, o.Y+c.oy
			mod := func(v, n int) int { return ((v % n) + n) % n }
			ramps := c.allRamps()
			for _, p := range m.Points() {
				if mod(p.X-ox, w) == 0 || mod(p.Y-oy, h) == 0 {
					if cur := c.G.At(p.X, p.Y); cur != pxlib.Clear {
						c.PutAbs(p.X, p.Y, shadeStep(rampOf(ramps, cur), cur, a.int("by")))
					}
				}
			}
			if a.has("screw") {
				k, err := c.Color(a.color("screw"))
				if err != nil {
					return err
				}
				for _, p := range m.Points() {
					rx, ry := mod(p.X-ox, w), mod(p.Y-oy, h)
					if (rx == 2 || rx == w-2) && (ry == 2 || ry == h-2) && w >= 6 && h >= 6 {
						c.PutAbs(p.X, p.Y, k)
					}
				}
			}
			return nil
		},
	})
	register(&opDef{
		Name: "hazard_stripes", Example: `{"hazard_stripes": {"a": "light", "b": "ink", "width": 2}}`,
		Summary:   "部品の塊を 45° の縞（width px ごとに a と b）で塗る（危ない所の黄黒の縞）",
		Technique: "危ない所は 45° の黄黒の縞", Finish: "lint flat-run",
		Params: []param{
			pShape,
			{Name: "a", Type: tColor, Default: "light", Summary: "縞の 1 色目"},
			{Name: "b", Type: tColor, Default: "ink", Summary: "縞の 2 色目"},
			{Name: "width", Type: tInt, Default: 2.0, Summary: "縞の幅（px）", Lo: bound(1), Hi: bound(8)},
			{Name: "flip", Type: tBool, Summary: "縞の向きを反対（／ と ＼）に"},
		},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			ka, err := c.Color(a.color("a"))
			if err != nil {
				return err
			}
			kb, err := c.Color(a.color("b"))
			if err != nil {
				return err
			}
			w := a.int("width")
			for _, p := range m.Points() {
				d := p.X + p.Y
				if a.bool("flip") {
					d = p.X - p.Y + 4096
				}
				if (d/w)%2 == 0 {
					c.PutAbs(p.X, p.Y, ka)
				} else {
					c.PutAbs(p.X, p.Y, kb)
				}
			}
			return nil
		},
	})
}
