package pxkit

// 描く手順（op）。1 コマ = op の列で、上から順に格子へ重ねる。
// 作法（光は左上・輪郭はランプの最暗色・帯の境目の市松）は op の中に既定として入っていて、
// spec からは数値のつまみだけを渡す。ランプは暗 → 明の 4 段 [ink, shade, mid, light]。
//
//	{"bevelBox": {"radius": 6.5, "inset": 2, "bands": [0.30, 0.72], "glossUntil": 0.8}}
//	                                          角丸の板（斜めの 3 段 + 縁のつや + 墨の輪郭）。格子は正方形
//	{"glyph": 形}                             白抜きの記号（右下へ墨の影を 1px）
//	{"fill": 形, "color": "shade"}            塊を 1 色で
//	{"put": [[x, y], ...], "color": "mid"}    画素を直に（"color": null で透明へ抜く）
//	{"line": [x0, y0, x1, y1], "color": "light", "within": "glyph"}
//	{"crack": [[x, y], ...]}                  タイルの割れ目（墨 + 右下に切り口の光）
//	{"stamp": {"at": [x, y], "rows": [...]}, "colors": {"#": "gloss"}}
//	{"use": "名前"}                           spec の shared（名前つきの op の列）を差し込む
//	{"normalShade": {...}}                    丸みのある部品の塊を光の向きで塗る（normalshade.go）

import (
	"fmt"
	"math"
)

// ctx は 1 コマを描く間の状態。
type ctx struct {
	g      *Grid
	ramp   []string
	ramps  map[string]any    // spec の ramps（lit3d の部品ごとに引く）
	keyOf  map[string]string // legend の文字 → 色キー（stamp を legend の文字で打つとき）
	gloss  string
	masks  map[string]Mask // 直前の bevelBox / glyph の塊（within・crack が引く）
	shapes map[string]any
	layers map[string]any
	depth  int
	ox, oy int // use の at で足すずらし
}

type errUnknownColor string

func (e errUnknownColor) Error() string {
	return fmt.Sprintf("legend に無い色キー %q", string(e))
}

// mustColor は op の "color" を引く。書き忘れは黙って透明にせず止める（透明へ抜くのは "" と明記した時だけ）。
func (c *ctx) mustColor(m map[string]any) (string, error) {
	v, ok := m["color"]
	if !ok {
		return "", fmt.Errorf("color が無い（透明へ抜くなら \"color\": \"\"）")
	}
	col := c.color(v)
	if col != "" && c.keyOf != nil && !c.hasKey(col) {
		return "", errUnknownColor(col)
	}
	return col, nil
}

func (c *ctx) hasKey(key string) bool {
	for _, k := range c.keyOf {
		if k == key {
			return true
		}
	}
	return false
}

// rampAt はランプの i 段目。段が足りなければ止める（Build の recover が spec の誤りとして報告する）。
func (c *ctx) rampAt(i int) string {
	if i >= len(c.ramp) {
		panic(fmt.Sprintf("ランプの %d 段目が無い（sprite の ramp が %d 段。ink/shade/mid/light を使うなら 4 段で書く）", i+1, len(c.ramp)))
	}
	return c.ramp[i]
}

// need4 は 4 段のランプが要る op（作法がランプの段を使う物）の前提。
func (c *ctx) need4(op string) error {
	if len(c.ramp) < 4 {
		return fmt.Errorf("%s は暗 → 明の 4 段のランプが要る（sprite の ramp を指定する）", op)
	}
	if c.ox != 0 || c.oy != 0 {
		return fmt.Errorf("%s は use の at でずらせない（格子全体に描く op）", op)
	}
	return nil
}

// put は use の at でずらした位置に置く。
func (c *ctx) put(x, y int, col string) { c.g.Put(x+c.ox, y+c.oy, col) }

// shifted は形を use の at の分だけずらす。
func (c *ctx) shifted(f SDF) SDF {
	if c.ox == 0 && c.oy == 0 {
		return f
	}
	dx, dy := float64(c.ox), float64(c.oy)
	return func(x, y float64) float64 { return f(x-dx, y-dy) }
}

// color は "ink" "shade" "mid" "light" "gloss" をランプから引き、ほかは legend のキーそのもの。
func (c *ctx) color(v any) string {
	s, _ := v.(string)
	switch s {
	case "ink":
		return c.rampAt(0)
	case "shade":
		return c.rampAt(1)
	case "mid":
		return c.rampAt(2)
	case "light":
		return c.rampAt(3)
	case "gloss":
		return c.gloss
	}
	return s
}

func (c *ctx) run(ops []any) error {
	c.depth++
	defer func() { c.depth-- }()
	if c.depth > 8 {
		return fmt.Errorf("use の入れ子が深すぎる（輪になっていないか）")
	}
	for _, o := range ops {
		m, ok := o.(map[string]any)
		if !ok {
			return fmt.Errorf("op はオブジェクトで書く: %v", o)
		}
		if err := c.op(m); err != nil {
			return err
		}
	}
	return nil
}

func (c *ctx) op(m map[string]any) error {
	g := c.g
	switch {
	case m["use"] != nil:
		name, _ := m["use"].(string)
		body, ok := c.layers[name].([]any)
		if !ok {
			return fmt.Errorf("shared に %q が無い", name)
		}
		at := nums(m["at"])
		if len(at) == 2 {
			// 部品を (x, y) だけずらして描く（同じ部品を何か所にも置く・歩きのコマで体を上下させる）
			c.ox, c.oy = c.ox+int(at[0]), c.oy+int(at[1])
			defer func() { c.ox, c.oy = c.ox-int(at[0]), c.oy-int(at[1]) }()
		}
		return c.run(body)
	case m["flip"] != nil:
		// 格子全体を左右（"x"）か上下（"y"）に返す。右向きのコマから左向きを作る
		axis, _ := m["flip"].(string)
		g.Flip(axis == "y")
	case m["tilemap"] != nil:
		p, _ := m["tilemap"].(map[string]any)
		return c.tilemap(p)
	case m["bevelBox"] != nil:
		p, _ := m["bevelBox"].(map[string]any)
		if g.W != g.H {
			return fmt.Errorf("bevelBox は正方形の格子だけ（今は %d×%d）", g.W, g.H)
		}
		if err := c.need4("bevelBox"); err != nil {
			return err
		}
		c.masks["bevelBox"] = c.bevelBox(num(p["radius"], 6.5), num(p["inset"], 2.0), nums2(p["bands"], 0.30, 0.72), num(p["glossUntil"], 0.8))
	case m["glyph"] != nil:
		f, err := ShapeOf(m["glyph"], c.shapes)
		if err != nil {
			return err
		}
		if len(c.ramp) < 4 {
			return fmt.Errorf("glyph は暗 → 明の 4 段のランプが要る")
		}
		em := g.MaskOf(c.shifted(f))
		for y := g.H - 1; y >= 0; y-- {
			for x := g.W - 1; x >= 0; x-- {
				if em[y][x] && !g.Inside(em, min(x+1, g.W-1), min(y+1, g.H-1)) {
					g.Put(x+1, y+1, c.ramp[0])
				}
			}
		}
		g.Fill(em, c.gloss)
		c.masks["glyph"] = em
	case m["fill"] != nil:
		f, err := ShapeOf(m["fill"], c.shapes)
		if err != nil {
			return err
		}
		col, err := c.mustColor(m)
		if err != nil {
			return err
		}
		g.Fill(g.MaskOf(c.shifted(f)), col)
	case m["put"] != nil:
		col, err := c.mustColor(m)
		if err != nil {
			return err
		}
		for _, p := range points(m["put"]) {
			c.put(int(p[0]), int(p[1]), col)
		}
	case m["line"] != nil:
		p := nums(m["line"])
		within, _ := m["within"].(string)
		col, err := c.mustColor(m)
		if err != nil {
			return err
		}
		if within != "" && c.masks[within] == nil {
			return fmt.Errorf("line の within %q の塊がまだ無い（先に描く）", within)
		}
		for _, q := range lerpCells([][2]float64{{p[0], p[1]}, {p[2], p[3]}}) {
			if within == "" || g.Inside(c.masks[within], q[0]+c.ox, q[1]+c.oy) {
				c.put(q[0], q[1], col)
			}
		}
	case m["normalShade"] != nil:
		p, _ := m["normalShade"].(map[string]any)
		return c.normalShade(p)
	case m["crack"] != nil:
		if err := c.need4("crack"); err != nil {
			return err
		}
		if c.masks["bevelBox"] == nil {
			return fmt.Errorf("crack は bevelBox の後に書く（割る板が無い）")
		}
		c.crack(points(m["crack"]))
	case m["stamp"] != nil:
		p, _ := m["stamp"].(map[string]any)
		at := nums(p["at"])
		cols, hasCols := m["colors"].(map[string]any)
		rows, _ := p["rows"].([]any)
		for dy, r := range rows {
			s, _ := r.(string)
			for dx, ch := range []rune(s) {
				x, y := int(at[0])+dx, int(at[1])+dy
				if hasCols {
					if v, ok := cols[string(ch)]; ok {
						c.put(x, y, c.color(v))
					}
				} else if ch == '.' {
					c.put(x, y, "") // colors が無ければ legend の文字で打つ（' ' は置かない・'.' は透明へ抜く）
				} else if ch != ' ' {
					key, ok := c.keyOf[string(ch)]
					if !ok {
						return fmt.Errorf("stamp の文字 %q が legend に無い", string(ch))
					}
					c.put(x, y, key)
				}
			}
		}
	default:
		return fmt.Errorf("知らない op: %v", keysOf(m))
	}
	return nil
}

// bevelBox は角丸の板。左上 → 右下の斜めの帯で 光・地・影、縁の 1px につや（左上）と墨（右下）、外側に墨の輪郭。
func (c *ctx) bevelBox(radius, inset float64, bands [2]float64, glossUntil float64) Mask {
	g, r := c.g, c.ramp
	size := g.W
	half := float64(size) / 2
	m := g.MaskOf(func(x, y float64) float64 {
		qx := math.Abs(x-half) - (half - inset) + radius
		qy := math.Abs(y-half) - (half - inset) + radius
		return hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - radius
	})
	span := 2.0 * float64(size-1)
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			if !m[y][x] {
				continue
			}
			t := float64(x+y) / span
			col := r[1]
			if t < bands[0] {
				col = r[3]
			} else if t < bands[1] {
				col = r[2]
			}
			// 帯の境目のギザだけを市松で整える（幅を持った帯にはしない）
			if (math.Abs(t-bands[0]) < 0.012 || math.Abs(t-bands[1]) < 0.012) && (x+y)%2 == 0 {
				col = r[2]
			}
			g.Px[y][x] = col
		}
	}
	d := g.Depth(m)
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			if !m[y][x] || d[y][x] != 1 {
				continue
			}
			up, left := !g.Inside(m, x, y-1), !g.Inside(m, x-1, y)
			down, right := !g.Inside(m, x, y+1), !g.Inside(m, x+1, y)
			if (up || left) && !(down || right) {
				if float64(x+y) < float64(size)*glossUntil {
					g.Px[y][x] = c.gloss
				} else {
					g.Px[y][x] = r[3]
				}
			} else if down || right {
				g.Px[y][x] = r[0]
			}
		}
	}
	g.Outline(m, r[0])
	return m
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

// crack はタイルの割れ目: 墨の 1px と、その右下に切り口の光 1px。
func (c *ctx) crack(pts [][2]float64) {
	g, m := c.g, c.masks["bevelBox"]
	cells := lerpCells(pts)
	seen := map[[2]int]bool{}
	for _, q := range cells {
		seen[q] = true
	}
	for _, q := range cells {
		for _, o := range [2][2]int{{1, 0}, {0, 1}} {
			n := [2]int{q[0] + o[0], q[1] + o[1]}
			if !seen[n] && g.Inside(m, n[0], n[1]) {
				g.Put(n[0], n[1], c.gloss)
			}
		}
	}
	for _, q := range cells {
		if g.Inside(m, q[0], q[1]) {
			g.Put(q[0], q[1], c.ramp[0])
		}
	}
}

func nums2(v any, a, b float64) [2]float64 {
	p := nums(v)
	if len(p) == 2 {
		return [2]float64{p[0], p[1]}
	}
	return [2]float64{a, b}
}

// tilemap はタイル（legend の文字の格子）を、map の文字の並びどおりに敷き詰める。
// map の ' ' と '.' はタイルを置かない。タイルの中の '.' は下の絵を残す（重ねて層にできる）。
//
//	{"tilemap": {"tileSize": [16, 16], "at": [0, 0],
//	             "tiles": {"g": ["16 文字 × 16 行"], "w": [...]},
//	             "map": ["ggggwwgg", ...]}}
func (c *ctx) tilemap(p map[string]any) error {
	ts := nums(p["tileSize"])
	if len(ts) != 2 || ts[0] < 1 || ts[1] < 1 {
		return fmt.Errorf("tilemap: tileSize [w, h] が無い")
	}
	tw, th := int(ts[0]), int(ts[1])
	at := nums(p["at"])
	ax, ay := 0, 0
	if len(at) == 2 {
		ax, ay = int(at[0]), int(at[1])
	}
	tiles, _ := p["tiles"].(map[string]any)
	rows, _ := p["map"].([]any)
	for ty, r := range rows {
		line, _ := r.(string)
		for tx, ch := range []rune(line) {
			if ch == ' ' || ch == '.' {
				continue
			}
			tile, ok := tiles[string(ch)].([]any)
			if !ok {
				return fmt.Errorf("tilemap: タイル %q が tiles に無い", string(ch))
			}
			for y, tr := range tile {
				s, _ := tr.(string)
				for x, pc := range []rune(s) {
					if x >= tw || y >= th || pc == '.' || pc == ' ' {
						continue
					}
					key, ok := c.keyOf[string(pc)]
					if !ok {
						return fmt.Errorf("tilemap: タイル %q の文字 %q が legend に無い", string(ch), string(pc))
					}
					c.put(ax+tx*tw+x, ay+ty*th+y, key)
				}
			}
		}
	}
	return nil
}
