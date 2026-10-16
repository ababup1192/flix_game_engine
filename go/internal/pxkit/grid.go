package pxkit

// 画素の格子と、塊（mask）に対する作法の部品（縁取り・縁からの距離・光の段）。
// 画素に置くのは legend の意味色キー（"" は透明）。文字への置き換えは書き出しの最後に 1 回だけ。

// Mask は塊。true の画素が塊の中。
type Mask [][]bool

// Grid は w×h の画素。
type Grid struct {
	W, H int
	Px   [][]string
}

// NewGrid は透明の格子を作る。
func NewGrid(w, h int) *Grid {
	px := make([][]string, h)
	for y := range px {
		px[y] = make([]string, w)
	}
	return &Grid{W: w, H: h, Px: px}
}

// Put は格子の外なら何もしない。
func (g *Grid) Put(x, y int, c string) {
	if x >= 0 && x < g.W && y >= 0 && y < g.H {
		g.Px[y][x] = c
	}
}

// MaskOf は形の内側（画素の中心で距離 0 以下）。
func (g *Grid) MaskOf(f SDF) Mask {
	m := make(Mask, g.H)
	for y := 0; y < g.H; y++ {
		m[y] = make([]bool, g.W)
		for x := 0; x < g.W; x++ {
			m[y][x] = f(float64(x)+0.5, float64(y)+0.5) <= 0
		}
	}
	return m
}

// Inside は格子の外を塊の外として扱う。
func (g *Grid) Inside(m Mask, x, y int) bool {
	return x >= 0 && x < g.W && y >= 0 && y < g.H && m[y][x]
}

// Fill は塊を 1 色で塗る。
func (g *Grid) Fill(m Mask, c string) {
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			if m[y][x] {
				g.Px[y][x] = c
			}
		}
	}
}

var dirs4 = [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

// Outline は塊の外側 1px を縁取る。lit を渡すと、塊が右下にある縁（光の側）だけその色。
func (g *Grid) Outline(m Mask, c, lit string) {
	type pt struct {
		x, y int
		lit  bool
	}
	var pts []pt
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			if m[y][x] {
				continue
			}
			any, allLit := false, true
			for _, d := range dirs4 {
				if g.Inside(m, x+d[0], y+d[1]) {
					any = true
					if d[0]+d[1] <= 0 {
						allLit = false
					}
				}
			}
			if any {
				pts = append(pts, pt{x, y, lit != "" && allLit})
			}
		}
	}
	for _, p := range pts {
		if p.lit {
			g.Px[p.y][p.x] = lit
		} else {
			g.Px[p.y][p.x] = c
		}
	}
}

// Depth は塊の各画素の、縁からの距離（4 近傍。縁の画素が 1）。
func (g *Grid) Depth(m Mask) [][]int {
	const inf = 999
	d := make([][]int, g.H)
	var q [][2]int
	for y := 0; y < g.H; y++ {
		d[y] = make([]int, g.W)
		for x := 0; x < g.W; x++ {
			if !m[y][x] {
				continue
			}
			d[y][x] = inf
			for _, dd := range dirs4 {
				if !g.Inside(m, x+dd[0], y+dd[1]) {
					d[y][x] = 1
					q = append(q, [2]int{x, y})
					break
				}
			}
		}
	}
	for len(q) > 0 {
		x, y := q[0][0], q[0][1]
		q = q[1:]
		for _, dd := range dirs4 {
			xx, yy := x+dd[0], y+dd[1]
			if xx >= 0 && xx < g.W && yy >= 0 && yy < g.H && d[yy][xx] > d[y][x]+1 {
				d[yy][xx] = d[y][x] + 1
				q = append(q, [2]int{xx, yy})
			}
		}
	}
	return d
}

// Rows は格子を legend の文字の行にする。知らない色キーは error。
func (g *Grid) Rows(charOf map[string]string) ([]string, error) {
	out := make([]string, g.H)
	for y := 0; y < g.H; y++ {
		b := make([]byte, 0, g.W)
		for x := 0; x < g.W; x++ {
			c := g.Px[y][x]
			if c == "" {
				b = append(b, '.')
				continue
			}
			ch, ok := charOf[c]
			if !ok {
				return nil, errUnknownColor(c)
			}
			b = append(b, ch...)
		}
		out[y] = string(b)
	}
	return out, nil
}
