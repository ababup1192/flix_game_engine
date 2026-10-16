package pxkit

// 描く手順（op）。1 コマ = op の列で、上から順に格子へ重ねる。
// 作法（光は左上・輪郭はランプの最暗色・帯の境目の市松）は op の中に既定として入っていて、
// spec からは数値のつまみだけを渡す。ランプは暗 → 明の 4 段 [ink, shade, mid, light]。
//
//	{"tile": {"radius": 6.5, "inset": 2}}    角丸タイル（斜めの 3 段 + 縁のつや + 墨の輪郭）
//	{"emblem": 形}                            白抜きの記号（右下へ墨の影を 1px）
//	{"fill": 形, "color": "shade"}            塊を 1 色で
//	{"put": [[x, y], ...], "color": "mid"}    画素を直に（"color": null で透明へ抜く）
//	{"line": [x0, y0, x1, y1], "color": "light", "within": "emblem"}
//	{"crack": [[x, y], ...]}                  タイルの割れ目（墨 + 右下に切り口の光）
//	{"stamp": {"at": [x, y], "rows": [...]}, "colors": {"#": "gloss"}}
//	{"use": "名前"}                           spec の layers（名前つきの op の列）を差し込む

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
	masks  map[string]Mask // 直前の tile / emblem の塊（within・crack が引く）
	shapes map[string]any
	layers map[string]any
	depth  int
}

type errUnknownColor string

func (e errUnknownColor) Error() string { return fmt.Sprintf("legend に無い色キー %q", string(e)) }

// color は "ink" "shade" "mid" "light" "gloss" をランプから引き、ほかは legend のキーそのもの。
func (c *ctx) color(v any) string {
	s, _ := v.(string)
	switch s {
	case "ink":
		return c.ramp[0]
	case "shade":
		return c.ramp[1]
	case "mid":
		return c.ramp[2]
	case "light":
		return c.ramp[3]
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
			return fmt.Errorf("layers に %q が無い", name)
		}
		return c.run(body)
	case m["tile"] != nil:
		p, _ := m["tile"].(map[string]any)
		c.masks["tile"] = c.tile(num(p["radius"], 6.5), num(p["inset"], 2.0), nums2(p["bands"], 0.30, 0.72))
	case m["emblem"] != nil:
		f, err := ShapeOf(m["emblem"], c.shapes)
		if err != nil {
			return err
		}
		em := g.MaskOf(f)
		for y := g.H - 1; y >= 0; y-- {
			for x := g.W - 1; x >= 0; x-- {
				if em[y][x] && !g.Inside(em, min(x+1, g.W-1), min(y+1, g.H-1)) {
					g.Put(x+1, y+1, c.ramp[0])
				}
			}
		}
		g.Fill(em, c.gloss)
		c.masks["emblem"] = em
	case m["fill"] != nil:
		f, err := ShapeOf(m["fill"], c.shapes)
		if err != nil {
			return err
		}
		g.Fill(g.MaskOf(f), c.color(m["color"]))
	case m["put"] != nil:
		col := c.color(m["color"])
		for _, p := range points(m["put"]) {
			g.Put(int(p[0]), int(p[1]), col)
		}
	case m["line"] != nil:
		p := nums(m["line"])
		within, _ := m["within"].(string)
		col := c.color(m["color"])
		for _, q := range lerpCells([][2]float64{{p[0], p[1]}, {p[2], p[3]}}) {
			if within == "" || g.Inside(c.masks[within], q[0], q[1]) {
				g.Put(q[0], q[1], col)
			}
		}
	case m["lit3d"] != nil:
		p, _ := m["lit3d"].(map[string]any)
		return c.lit3d(p)
	case m["crack"] != nil:
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
						g.Put(x, y, c.color(v))
					}
				} else if ch == '.' {
					g.Put(x, y, "") // colors が無ければ legend の文字で打つ（' ' は置かない・'.' は透明へ抜く）
				} else if ch != ' ' {
					g.Put(x, y, c.keyOf[string(ch)])
				}
			}
		}
	default:
		return fmt.Errorf("知らない op: %v", keysOf(m))
	}
	return nil
}

// tile は角丸タイル。左上 → 右下の斜めの帯で 光・地・影、縁の 1px につや（左上）と墨（右下）、外側に墨の輪郭。
func (c *ctx) tile(radius, inset float64, bands [2]float64) Mask {
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
				if float64(x+y) < float64(size)*0.8 {
					g.Px[y][x] = c.gloss
				} else {
					g.Px[y][x] = r[3]
				}
			} else if down || right {
				g.Px[y][x] = r[0]
			}
		}
	}
	g.Outline(m, r[0], "")
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
			cells = append(cells, [2]int{int(math.RoundToEven(ax + (bx-ax)*t)), int(math.RoundToEven(ay + (by-ay)*t))})
		}
	}
	return cells
}

// crack はタイルの割れ目: 墨の 1px と、その右下に切り口の光 1px。
func (c *ctx) crack(pts [][2]float64) {
	g, m := c.g, c.masks["tile"]
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
