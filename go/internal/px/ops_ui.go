package px

// UI の op（昇格ループ 3 周目: 一人称のダンジョンの窓・縦シューティングの字の下の窓・町の名前のラベル・路地の HUD）。
// frame（窓の枠を外から内へ輪で）・table（字を列にそろえて並べる表）。

import (
	"fmt"
	"math"
	"strings"
	"unicode/utf8"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

func init() {
	register(&opDef{
		Name: "frame", Example: `{"frame": {"shape": {"rect": [1, 1, 14, 10]}, "rings": ["light", "", "shade|ink"], "fill": "ink"}}`,
		Summary: "窓の枠: 形（省くと部品の塊）の外接箱に、外から内へ輪を 1px ずつ引く（輪 k は step × k だけ内側。\"\" は空ける・" +
			"\"a|b\" は上と左を a・下と右を b にした凹凸の縁）。fill を書くと先に箱を塗る",
		Technique: "UI の窓・ラベルの板・凹んだ枠（外から内へ 1px の輪を重ねる）", Finish: "—",
		Params: []param{
			pShape,
			{Name: "rings", Type: tRows, Required: true, Min: 1, Summary: "外から内への輪の色（\"\" は空ける・\"a|b\" は上と左が a・下と右が b）"},
			{Name: "step", Type: tPair, Default: []any{1.0, 1.0}, Summary: "輪 1 つごとに内へ寄せる [横, 縦]（輪 k の寄せは k × step を切り捨て。縦長の画素の機種は [1, 0.5]）"},
			{Name: "fill", Type: tColor, Summary: "輪の前に箱を塗る色（省くと塗らない）"},
		},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			pts := m.Points()
			if len(pts) == 0 {
				return fmt.Errorf("枠を引く箱が無い（shape か部品の shape を書く）")
			}
			x0, y0, x1, y1 := pxlib.BBox(pts)
			if a.has("fill") {
				k, err := c.Color(a.color("fill"))
				if err != nil {
					return err
				}
				for y := y0; y <= y1; y++ {
					for x := x0; x <= x1; x++ {
						c.PutAbs(x, y, k)
					}
				}
			}
			st := a.pair("step")
			for i, ring := range a.rows("rings") {
				if ring == "" {
					continue
				}
				tl, br := ring, ring
				if j := strings.Index(ring, "|"); j >= 0 {
					tl, br = ring[:j], ring[j+1:]
				}
				ktl, err := c.Color(colorRef(tl))
				if err != nil {
					return err
				}
				kbr, err := c.Color(colorRef(br))
				if err != nil {
					return err
				}
				ix, iy := int(math.Floor(float64(i)*st[0])), int(math.Floor(float64(i)*st[1]))
				l, t, r, b := x0+ix, y0+iy, x1-ix, y1-iy
				if l > r || t > b {
					return fmt.Errorf("輪 %d（%q）が箱の内に入らない（輪を減らすか step を小さく）", i, ring)
				}
				for x := l; x <= r; x++ {
					c.PutAbs(x, t, ktl)
				}
				for y := t; y <= b; y++ {
					c.PutAbs(l, y, ktl)
				}
				for x := l; x <= r; x++ {
					c.PutAbs(x, b, kbr)
				}
				for y := t; y <= b; y++ {
					c.PutAbs(r, y, kbr)
				}
			}
			box := pxlib.NewMask(c.G.W, c.G.H)
			for y := max(y0, 0); y <= min(y1, c.G.H-1); y++ {
				for x := max(x0, 0); x <= min(x1, c.G.W-1); x++ {
					box[y][x] = true
				}
			}
			c.AddRegion(box)
			return nil
		},
	})

	register(&opDef{
		Name: "bar", Example: `{"bar": {"rate": 0.8, "side": "right", "empty": "ink", "from": 1, "band": 0.5, "top": "light"}}`,
		Summary: "体力のバー: 形（省くと部品の塊）の外接箱を、side の端から rate だけ残りの量で塗る（fill を省くとランプの段を太さの向きに Bayer で）。" +
			"empty は減った所・top は残りの上の 1px のつや・lost は残りの隣の今減った量",
		Technique: "UI（体力・気力・時間のゲージ）", Finish: "—",
		Params: []param{
			pShape,
			{Name: "rate", Type: tNumber, Required: true, Summary: "残りの割合（0〜1。長さは 外接箱の長さ × rate を四捨五入）", Lo: bound(0), Hi: bound(1)},
			{Name: "side", Type: tString, Default: "left", Summary: "残りを寄せる端: left・right（横のバー）・bottom・top（縦のバー）"},
			{Name: "fill", Type: tColor, Summary: "残りの色（省くとランプの from〜to 段を太さの向きに塗る: 横のバーは上が明るい）"},
			{Name: "from", Type: tInt, Default: 0.0, Summary: "fill を省いた時に使う一番暗い段", Lo: bound(0), Hi: bound(15)},
			{Name: "to", Type: tInt, Default: -1.0, Summary: "fill を省いた時に使う一番明るい段（-1 で最明）", Lo: bound(-1), Hi: bound(15)},
			{Name: "band", Type: tNumber, Default: 0.0, Summary: "段の境目をディザで混ぜる割合（gradient_fill と同じ。0 はベタの帯）", Lo: bound(0), Hi: bound(1)},
			{Name: "empty", Type: tColor, Summary: "減った所の色（先に箱全体を塗る。省くと塗らない）"},
			{Name: "top", Type: tColor, Summary: "残りの上の縁（縦のバーは光の側の縁）の 1px の色（省くと引かない）"},
			{Name: "lost", Type: tNumber, Default: 0.0, Summary: "今減った量の割合（残りの隣・減った所の側に lost_color で）", Lo: bound(0), Hi: bound(1)},
			{Name: "lost_color", Type: tColor, Default: "light", Summary: "今減った量の色"},
		},
		Apply: func(c *ctx, a opArgs) error {
			m, err := c.ShapeOrRegion(a)
			if err != nil {
				return err
			}
			pts := m.Points()
			if len(pts) == 0 {
				return fmt.Errorf("バーの箱が無い（shape か部品の shape を書く）")
			}
			x0, y0, x1, y1 := pxlib.BBox(pts)
			side := a.str("side")
			vertical := side == "top" || side == "bottom"
			if !vertical && side != "left" && side != "right" {
				return fmt.Errorf("side は left・right・bottom・top")
			}
			length := x1 - x0 + 1
			if vertical {
				length = y1 - y0 + 1
			}
			cells := func(r float64) int { return int(math.Floor(float64(float64(length)*r) + 0.5)) }
			n := cells(a.num("rate"))
			lost := min(cells(a.num("lost")), length-n)
			// span は端から k 番目〜k+cnt-1 番目の帯（side の端から数える）
			span := func(k, cnt int) pxlib.Mask {
				out := pxlib.NewMask(c.G.W, c.G.H)
				for y := max(y0, 0); y <= min(y1, c.G.H-1); y++ {
					for x := max(x0, 0); x <= min(x1, c.G.W-1); x++ {
						var d int
						switch side {
						case "left":
							d = x - x0
						case "right":
							d = x1 - x
						case "top":
							d = y - y0
						case "bottom":
							d = y1 - y
						}
						if d >= k && d < k+cnt {
							out[y][x] = true
						}
					}
				}
				return out
			}
			paint := func(mask pxlib.Mask, ref colorRef) error {
				k, err := c.Color(ref)
				if err != nil {
					return err
				}
				for _, p := range mask.Points() {
					c.PutAbs(p.X, p.Y, k)
				}
				return nil
			}
			if a.has("empty") {
				if err := paint(span(0, length), a.color("empty")); err != nil {
					return err
				}
			}
			full := span(0, n)
			if n > 0 {
				if a.has("fill") {
					if err := paint(full, a.color("fill")); err != nil {
						return err
					}
				} else {
					field := "y"
					if vertical {
						field = "x"
					}
					if err := c.gradientOn(full, field, a.num("band"), a.int("from"), a.int("to"), false); err != nil {
						return err
					}
				}
				if a.has("top") {
					edge := pxlib.NewMask(c.G.W, c.G.H)
					for _, p := range full.Points() {
						if !vertical && p.Y == max(y0, 0) || vertical && p.X == max(x0, 0) {
							edge[p.Y][p.X] = true
						}
					}
					if err := paint(edge, a.color("top")); err != nil {
						return err
					}
				}
			}
			if lost > 0 {
				if err := paint(span(n, lost), a.color("lost_color")); err != nil {
					return err
				}
			}
			c.AddRegion(span(0, length))
			return nil
		},
	})

	register(&opDef{
		Name: "table", Example: `{"table": {"at": [1, 1], "cols": [0, 20], "align": "lr", "rows": [["HP", "12"], ["MP", ["3", "shade"]]], "color": "light"}}`,
		Summary: "字の表: rows の升を列 cols（at からの横の位置）にそろえ、行を line ずつ下げて text と同じ字形で置く（升は文字列か [文字列, 色]。" +
			"align の 1 字が列のそろえ: l は左端・r は右端（送りを含む）・c は真ん中を cols の位置に）",
		Technique: "字（メニュー・ステータスの表・HUD の数）", Finish: "—",
		Params: []param{
			{Name: "at", Type: tPoint, Required: true, Summary: "1 行目の左上 [x, y]"},
			{Name: "cols", Type: tNums, Len: -1, Min: 1, Required: true, Summary: "列の横の位置（at の x から。align が r なら右端）"},
			{Name: "rows", Type: tCells, Required: true, Summary: "行の並び [[升, ...], ...]（升は文字列か [文字列, 色]。cols より多い升は誤り）"},
			{Name: "align", Type: tString, Default: "", Summary: "列ごとのそろえ（l・r・c を列の数だけ。足りない列は l）"},
			{Name: "color", Type: tColor, Default: "ink", Summary: "升の既定の色"},
			{Name: "colors", Type: tRows, Summary: "列ごとの既定の色（省くと color）"},
			{Name: "shadow", Type: tColor, Default: "", Summary: "右下 1px の影の色（\"\" で影なし）"},
			{Name: "font", Type: tString, Default: "5x7", Summary: "字形の組: 5x7・bold6x8"},
			{Name: "advance", Type: tInt, Default: 0.0, Summary: "1 字ごとの送り（0 は組の既定）", Lo: bound(0), Hi: bound(32)},
			{Name: "line", Type: tInt, Default: 0.0, Summary: "行の送り（0 は組の既定: 5x7 は 9・bold6x8 は 10）", Lo: bound(0), Hi: bound(64)},
		},
		Apply: func(c *ctx, a opArgs) error {
			f, ok := fonts[a.str("font")]
			if !ok {
				return fmt.Errorf("知らない字形の組 %q（%s）", a.str("font"), fontNames())
			}
			adv, line := a.int("advance"), a.int("line")
			if adv <= 0 {
				adv = f.Advance
			}
			if line <= 0 {
				line = f.Line
			}
			cols := nums(a.get("cols"))
			align := a.str("align")
			colColors := a.rows("colors")
			at := a.point("at")
			type item struct {
				pts []pxlib.Pt
				col colorRef
			}
			var items []item
			for r, row := range a.get("rows").([]any) {
				cells := row.([]any)
				if len(cells) > len(cols) {
					return fmt.Errorf("rows[%d] の升が %d 個で cols（%d 列）より多い", r, len(cells), len(cols))
				}
				for i, cell := range cells {
					text, col := "", a.color("color")
					if i < len(colColors) {
						col = colorRef(colColors[i])
					}
					switch v := cell.(type) {
					case string:
						text = v
					case []any:
						text, _ = v[0].(string)
						s, _ := v[1].(string)
						col = colorRef(s)
					}
					if strings.Contains(text, "\n") {
						return fmt.Errorf("rows[%d][%d]: 升に改行は書けない（行を分ける）", r, i)
					}
					x := at.X + int(cols[i])
					w := utf8.RuneCountInString(text) * adv
					if i < len(align) {
						switch align[i] {
						case 'r':
							x -= w
						case 'c':
							x -= w / 2
						case 'l':
						default:
							return fmt.Errorf("align の %d 字目 %q は l・r・c", i+1, string(align[i]))
						}
					}
					pts, err := layoutText(a.str("font"), text, pxlib.Pt{X: x, Y: at.Y + r*line}, adv, line)
					if err != nil {
						return fmt.Errorf("rows[%d][%d]: %w", r, i, err)
					}
					items = append(items, item{pts, col})
				}
			}
			if a.str("shadow") != "" {
				shadow, err := c.Color(a.color("shadow"))
				if err != nil {
					return err
				}
				for _, it := range items {
					for _, p := range it.pts {
						c.Put(p.X+1, p.Y+1, shadow)
					}
				}
			}
			for _, it := range items {
				k, err := c.Color(it.col)
				if err != nil {
					return err
				}
				for _, p := range it.pts {
					c.Put(p.X, p.Y, k)
				}
			}
			return nil
		},
	})
}
