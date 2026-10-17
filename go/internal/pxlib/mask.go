package pxlib

// 塊（mask）: 画素ごとに「中か外か」だけを持つ格子。
// ドット絵を描く側（px）と検査する側（sprite）が同じ型で塊を数える。

import "sort"

// Pt は格子の 1 画素の座標。
type Pt struct{ X, Y int }

// Mask は塊。Mask[y][x] が true の画素が塊の中。
type Mask [][]bool

// NewMask は w×h の空の塊を作る。
func NewMask(w, h int) Mask {
	m := make(Mask, h)
	for y := range m {
		m[y] = make([]bool, w)
	}
	return m
}

// MaskOf は形の内側（画素の中心で距離が 0 以下）を塊にする。f は符号付き距離（負が内側）。
func MaskOf(w, h int, f func(x, y float64) float64) Mask {
	m := NewMask(w, h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			m[y][x] = f(float64(x)+0.5, float64(y)+0.5) <= 0
		}
	}
	return m
}

// W は幅。
func (m Mask) W() int {
	if len(m) == 0 {
		return 0
	}
	return len(m[0])
}

// H は高さ。
func (m Mask) H() int { return len(m) }

// At は格子の外を塊の外として引く。
func (m Mask) At(x, y int) bool {
	return y >= 0 && y < len(m) && x >= 0 && x < len(m[y]) && m[y][x]
}

// Count は塊の画素数。
func (m Mask) Count() int {
	n := 0
	for _, row := range m {
		for _, v := range row {
			if v {
				n++
			}
		}
	}
	return n
}

// Points は塊の画素を上の行から順に（同じ行は左から）並べる。
func (m Mask) Points() []Pt {
	var out []Pt
	for y, row := range m {
		for x, v := range row {
			if v {
				out = append(out, Pt{x, y})
			}
		}
	}
	return out
}

// Union は 2 つの塊の和（大きさは m に合わせる）。
func (m Mask) Union(o Mask) Mask {
	out := NewMask(m.W(), m.H())
	for y := range out {
		for x := range out[y] {
			out[y][x] = m[y][x] || o.At(x, y)
		}
	}
	return out
}

// Dirs4 は上下左右の 4 近傍（右・左・下・上の順）。
var Dirs4 = [4]Pt{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

// Outline は塊の外側 1px（4 近傍で塊に接する外の画素）。
func (m Mask) Outline() Mask {
	out := NewMask(m.W(), m.H())
	for y := range out {
		for x := range out[y] {
			if m[y][x] {
				continue
			}
			for _, d := range Dirs4 {
				if m.At(x+d.X, y+d.Y) {
					out[y][x] = true
					break
				}
			}
		}
	}
	return out
}

// DistFromEdge は塊の各画素の「塊の外（格子の外を含む）からの距離」（4 近傍）。
// 縁の画素が 1、その内側が 2 …、塊の外は 0。
func (m Mask) DistFromEdge() [][]int {
	w, h := m.W(), m.H()
	d := make([][]int, h)
	var queue []Pt
	for y := 0; y < h; y++ {
		d[y] = make([]int, w)
		for x := 0; x < w; x++ {
			if !m[y][x] {
				continue
			}
			for _, n := range Dirs4 {
				if !m.At(x+n.X, y+n.Y) {
					d[y][x] = 1
					queue = append(queue, Pt{x, y})
					break
				}
			}
		}
	}
	for head := 0; head < len(queue); head++ {
		p := queue[head]
		for _, n := range Dirs4 {
			q := Pt{p.X + n.X, p.Y + n.Y}
			if !m.At(q.X, q.Y) || d[q.Y][q.X] != 0 {
				continue
			}
			d[q.Y][q.X] = d[p.Y][p.X] + 1
			queue = append(queue, q)
		}
	}
	return d
}

// Blob は連結した塊 1 つ。Start は上の行から走査して最初に見つかった画素。
type Blob struct {
	Size  int
	Start Pt
}

// Blobs は塊を連結成分に分ける。conn は 4（上下左右）か 8（斜めも）。
// 並びは Start の走査順（上の行から、同じ行は左から）。
func (m Mask) Blobs(conn int) []Blob {
	w, h := m.W(), m.H()
	seen := NewMask(w, h)
	var blobs []Blob
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if !m[y][x] || seen[y][x] {
				continue
			}
			seen[y][x] = true
			stack := []Pt{{x, y}}
			size := 0
			for len(stack) > 0 {
				p := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				size++
				for _, n := range neighbors(conn) {
					q := Pt{p.X + n.X, p.Y + n.Y}
					if m.At(q.X, q.Y) && !seen[q.Y][q.X] {
						seen[q.Y][q.X] = true
						stack = append(stack, q)
					}
				}
			}
			blobs = append(blobs, Blob{size, Pt{x, y}})
		}
	}
	return blobs
}

var dirs8 = []Pt{{-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 1}, {1, -1}, {1, 0}, {1, 1}}

func neighbors(conn int) []Pt {
	if conn == 8 {
		return dirs8
	}
	return Dirs4[:]
}

// SortPtsByXY は x が小さい順（同じ x は y が小さい順）に並べる。
func SortPtsByXY(pts []Pt) {
	sort.Slice(pts, func(i, j int) bool {
		if pts[i].X != pts[j].X {
			return pts[i].X < pts[j].X
		}
		return pts[i].Y < pts[j].Y
	})
}

// BBox は点の並びを囲む矩形（両端を含む）。pts は 1 つ以上。
func BBox(pts []Pt) (x0, y0, x1, y1 int) {
	x0, y0, x1, y1 = pts[0].X, pts[0].Y, pts[0].X, pts[0].Y
	for _, p := range pts[1:] {
		x0 = min(x0, p.X)
		y0 = min(y0, p.Y)
		x1 = max(x1, p.X)
		y1 = max(y1, p.Y)
	}
	return x0, y0, x1, y1
}

// Profile は輪郭の高さ列の 1 つ。OK が false の列は塊が無い（透明の切れ目）。
type Profile struct {
	V  int
	OK bool
}

// Profiles は上・下・左・右の 4 方向から見た輪郭の高さ列。
// 上から見た列は x ごとに最初に当たる y、下からは最後の y（左・右は y ごとの x）。
func (m Mask) Profiles() [4][]Profile {
	w, h := m.W(), m.H()
	type axis struct {
		byX            bool
		limitO, limitI int
		last           bool
	}
	var out [4][]Profile
	for ai, a := range [4]axis{{true, w, h, false}, {true, w, h, true}, {false, h, w, false}, {false, h, w, true}} {
		seq := make([]Profile, 0, a.limitO)
		for o := 0; o < a.limitO; o++ {
			found, pick := false, 0
			for i := 0; i < a.limitI; i++ {
				x, y := i, o
				if a.byX {
					x, y = o, i
				}
				if !m.At(x, y) {
					continue
				}
				if !found {
					pick, found = i, true
				} else if a.last {
					pick = i
				}
			}
			seq = append(seq, Profile{pick, found})
		}
		out[ai] = seq
	}
	return out
}

// Run は同じ値が続いた所（値と長さ）。
type Run struct{ Value, N int }

// ProfileRuns は高さ列を透明の切れ目で分け、切れ目ごとに同じ高さの続き（段）の並びにする。
func ProfileRuns(seq []Profile) [][]Run {
	chunks := [][]Run{{}}
	for _, p := range seq {
		if !p.OK {
			chunks = append(chunks, []Run{})
			continue
		}
		cur := chunks[len(chunks)-1]
		if len(cur) > 0 && cur[len(cur)-1].Value == p.V {
			cur[len(cur)-1].N++
		} else {
			cur = append(cur, Run{p.V, 1})
		}
		chunks[len(chunks)-1] = cur
	}
	return chunks
}
