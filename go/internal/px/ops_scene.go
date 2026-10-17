package px

// 場面の型の op（昇格ループ 1 周目: 2 作以上・2 ジャンル以上の台本で繰り返し書かれた形）。
// text（字を並べる）・canopy（葉の玉を重ねる木・茂み）。

import (
	"fmt"
	"unicode"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// canopyBalls は canopy の既定の玉の並び（中心からのずれ x・y と半径を、木の半径 r に対する割合で）。
// 奥（上）から手前（下）へ重ねる。
var canopyBalls = []any{
	[]any{0.0, -0.45, 0.55}, []any{-0.5, -0.1, 0.5}, []any{0.5, -0.1, 0.5}, []any{-0.25, 0.3, 0.55}, []any{0.3, 0.32, 0.52},
}

func init() {
	register(&opDef{
		Name: "text", Example: `{"text": {"at": [2, 2], "text": "INN", "color": "light"}}`,
		Summary:   "文字列を 5×7 の字で並べる（英大文字・数字・. , ! ? - + : ' / x * %。小文字は大文字で引く。shadow を書くと字ごとに右下 1px の影を先に置く）",
		Technique: "字（町の名前のラベル・看板・HUD）", Finish: "—",
		Params: []param{
			{Name: "at", Type: tPoint, Required: true, Summary: "1 字目の左上 [x, y]"},
			{Name: "text", Type: tString, Required: true, Summary: "並べる文字列（\\n で次の行）"},
			{Name: "color", Type: tColor, Default: "ink", Summary: "字の色"},
			{Name: "shadow", Type: tColor, Default: "", Summary: "右下 1px の影の色（\"\" で影なし）"},
			{Name: "advance", Type: tInt, Default: 6.0, Summary: "1 字ごとの送り（字の幅 5 ＋ 字の間）", Lo: bound(1), Hi: bound(32)},
			{Name: "line", Type: tInt, Default: 9.0, Summary: "行の送り（\\n の時）", Lo: bound(1), Hi: bound(64)},
		},
		Apply: func(c *ctx, a opArgs) error {
			fill, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			hasShadow := a.str("shadow") != ""
			var shadow pxlib.Key
			if hasShadow {
				if shadow, err = c.Color(a.color("shadow")); err != nil {
					return err
				}
			}
			at := a.point("at")
			x, y := at.X, at.Y
			for _, ch := range a.str("text") {
				if ch == '\n' {
					x, y = at.X, y+a.int("line")
					continue
				}
				g, ok := font5x7[ch]
				if !ok {
					g, ok = font5x7[unicode.ToUpper(ch)]
				}
				if !ok && ch != ' ' {
					return fmt.Errorf("字 %q は字形に無い（英大文字・数字・. , ! ? - + : ' / x * %%。ほかは glyph_rows で置く）", string(ch))
				}
				if ok {
					passes := []struct {
						d int
						k pxlib.Key
					}{{0, fill}}
					if hasShadow {
						passes = append([]struct {
							d int
							k pxlib.Key
						}{{1, shadow}}, passes...)
					}
					for _, pass := range passes {
						for dy, row := range g {
							for dx, r := range row {
								if r == '#' {
									c.Put(x+dx+pass.d, y+dy+pass.d, pass.k)
								}
							}
						}
					}
				}
				x += a.int("advance")
			}
			return nil
		},
	})

	register(&opDef{
		Name: "canopy", Example: `{"canopy": {"center": [8, 8], "r": 6}}`,
		Summary: "葉の玉を重ねた木・茂み: 玉を奥（上）から手前（下）へ重ね、玉ごとに光の向きの陰・葉の斑・光の側のつや。外側に rim の 1px（部品の塊は玉の和）",
		Technique: "葉の塊（玉を重ねて塊ごとに陰を付ける。全体に 1 つの陰を掛けない）", Finish: "lint pillow・orphan",
		Params: []param{
			{Name: "center", Type: tPair, Required: true, Summary: "木の中心 [x, y]"},
			{Name: "r", Type: tNumber, Required: true, Summary: "木の半径（玉の位置と大きさはこの割合）", Lo: bound(1), Hi: bound(256)},
			{Name: "balls", Type: tCircles, Default: canopyBalls, Summary: "玉の並び [[x, y, 半径], ...]（どれも r に対する割合・奥から手前の順）"},
			{Name: "rim", Type: tColor, Default: "ink", Summary: "玉の和の外側 1px の色（\"\" で無し）"},
			{Name: "band", Type: tNumber, Default: 1.0, Summary: "玉の陰の段の境目のディザの幅", Lo: bound(0), Hi: bound(8)},
			{Name: "from", Type: tInt, Default: 1.0, Summary: "玉の陰に使う一番暗い段", Lo: bound(0), Hi: bound(15)},
			{Name: "to", Type: tInt, Default: 3.0, Summary: "玉の陰に使う一番明るい段（-1 で最明）", Lo: bound(-1), Hi: bound(15)},
			{Name: "colors", Type: tRows, Default: []any{"ramp[1]", "ramp[3]"}, Summary: "葉の斑の色（scatter_clusters の colors。[] で斑なし）"},
			{Name: "cell", Type: tInt, Default: 3.0, Summary: "斑の升目", Lo: bound(1), Hi: bound(64)},
			{Name: "keep", Type: tNumber, Default: 0.5, Summary: "斑を置く割合", Lo: bound(0), Hi: bound(1)},
			{Name: "seed", Type: tInt, Default: 0.0, Summary: "斑の散らし方の番号（玉 k は seed + k）", Lo: bound(0), Hi: bound(1 << 20)},
			{Name: "gloss", Type: tColor, Default: "ramp[-1]", Summary: "玉の光の側のつやの色（\"\" で無し）"},
		},
		Checks: []checkRef{{Check: checkPillow}, {Check: checkSprite, Rule: "orphan"}},
		Apply: func(c *ctx, a opArgs) error {
			ctr, r := a.pair("center"), a.num("r")
			type ball struct{ x, y, r float64 }
			var balls []ball
			for _, v := range circles(a.get("balls")) {
				// float64(…) で包んで a*b+c を FMA にまとめさせない（台本の計算と同じ値にする）
				balls = append(balls, ball{ctr[0] + float64(v[0]*r), ctr[1] + float64(v[1]*r), float64(v[2] * r)})
			}
			disk := func(x, y, rr float64) (pxlib.Mask, error) {
				return c.MaskOf(map[string]any{"disk": []any{x, y, rr}})
			}
			union := pxlib.NewMask(c.G.W, c.G.H)
			for _, b := range balls {
				m, err := disk(b.x, b.y, b.r+1)
				if err != nil {
					return err
				}
				union = union.Union(m)
			}
			if a.str("rim") != "" {
				k, err := c.Color(a.color("rim"))
				if err != nil {
					return err
				}
				c.FillAbs(union, k)
			}
			ramp := c.Ramp()
			from, to := a.int("from"), a.int("to")
			if to < 0 {
				to += len(ramp)
			}
			if from < 0 || to >= len(ramp) || to-from < 1 {
				return fmt.Errorf("from・to がランプ（%d 段）の外か 1 段だけ（部品かスプライトに葉のランプを書く）", len(ramp))
			}
			cols, err := c.colorList(a.rows("colors"))
			if err != nil {
				return err
			}
			var gloss pxlib.Key
			hasGloss := a.str("gloss") != ""
			if hasGloss {
				if gloss, err = c.Color(a.color("gloss")); err != nil {
					return err
				}
			}
			lx, ly := c.LightSign()
			for k, b := range balls {
				m, err := disk(b.x, b.y, b.r)
				if err != nil {
					return err
				}
				f := directional(m, c.Spec.Light.Dir[0], c.Spec.Light.Dir[1])
				for _, p := range m.Points() {
					c.PutAbs(p.X, p.Y, ramp[from+rampIndex(f(p.X, p.Y), p.X, p.Y, to-from+1, a.num("band"))])
				}
				if len(cols) > 0 {
					px, _ := scatterClusters(c.G.W, c.G.H, m, cols, "blob", a.int("cell"), a.int("seed")+k+c.Seed*7919, a.num("keep"), false)
					c.dropPixels(px)
				}
				if hasGloss {
					g, err := disk(b.x+float64(float64(lx)*b.r*0.35), b.y+float64(float64(ly)*b.r*0.4), float64(b.r*0.28))
					if err != nil {
						return err
					}
					c.FillAbs(g, gloss)
				}
			}
			c.AddRegion(union)
			return nil
		},
	})
}

// circles は [[x, y, r], ...] を読む。
func circles(v any) [][3]float64 {
	var out [][3]float64
	arr, _ := v.([]any)
	for _, e := range arr {
		t := nums(e)
		if len(t) == 3 {
			out = append(out, [3]float64{t[0], t[1], t[2]})
		}
	}
	return out
}
