package px

// 場面の型の op（昇格ループ 1 周目: 2 作以上・2 ジャンル以上の台本で繰り返し書かれた形）。
// text（字を並べる）・canopy（葉の玉を重ねる木・茂み）。

import (
	"fmt"

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
		Summary:   "文字列を字形の組（font: 5x7・bold6x8）で並べて 1 色で置く（英大文字・数字・. , ! ? - + : ' / x * %。小文字は大文字で引く。shadow を書くと字ごとに右下 1px の影を先に置く）。階調や縁を付ける字は形 text を部品の shape にして gradient_fill・outline",
		Technique: "字（町の名前のラベル・看板・HUD）", Finish: "—",
		Params: []param{
			{Name: "at", Type: tPoint, Required: true, Summary: "1 字目の左上 [x, y]"},
			{Name: "text", Type: tString, Required: true, Summary: "並べる文字列（\\n で次の行）"},
			{Name: "color", Type: tColor, Default: "ink", Summary: "字の色"},
			{Name: "shadow", Type: tColor, Default: "", Summary: "右下 1px の影の色（\"\" で影なし）"},
			{Name: "font", Type: tString, Default: "5x7", Summary: "字形の組: 5x7（線 1px）・bold6x8（線 2px の太い字）"},
			{Name: "advance", Type: tInt, Default: 0.0, Summary: "1 字ごとの送り（0 は組の既定: 5x7 は 6・bold6x8 は 7）", Lo: bound(0), Hi: bound(32)},
			{Name: "line", Type: tInt, Default: 0.0, Summary: "行の送り（\\n の時。0 は組の既定: 5x7 は 9・bold6x8 は 10）", Lo: bound(0), Hi: bound(64)},
		},
		Apply: func(c *ctx, a opArgs) error {
			fill, err := c.Color(a.color("color"))
			if err != nil {
				return err
			}
			pts, err := layoutText(a.str("font"), a.str("text"), a.point("at"), a.int("advance"), a.int("line"))
			if err != nil {
				return err
			}
			if a.str("shadow") != "" {
				shadow, err := c.Color(a.color("shadow"))
				if err != nil {
					return err
				}
				// 影を字ごとに先に置く（後の字の影が前の字を潰さない）。字の画素を 1 字ずつ並べ直さずに済むよう、
				// 影を全部置いてから字を全部置く（字どうしは重ならないので同じ絵）
				for _, p := range pts {
					c.Put(p.X+1, p.Y+1, shadow)
				}
			}
			for _, p := range pts {
				c.Put(p.X, p.Y, fill)
			}
			return nil
		},
	})

	register(&opDef{
		Name: "canopy", Example: `{"canopy": {"center": [8, 8], "r": 6}}`,
		Summary:   "葉の玉を重ねた木・茂み: 玉を奥（上）から手前（下）へ重ね、玉ごとに光の向きの陰・葉の斑・光の側のつや。外側に rim の 1px（部品の塊は玉の和）",
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
					dx, dy := c.ditherAt(p.X, p.Y)
					c.PutAbs(p.X, p.Y, ramp[from+rampIndex(f(p.X, p.Y), dx, dy, to-from+1, a.num("band"))])
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
