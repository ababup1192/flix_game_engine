package pxlib

// 画素の格子。画素には legend の色キー（Key）を置き、"" は透明。
// 各画素は「最後にそこへ書いた op」（OpRef）も覚えていて、検査の違反から原因の op を引ける。
// 文字（legend の 1 字）への置き換えは書き出しの最後に 1 回だけ（Rows）。

import (
	"fmt"
	"sort"
)

// Key は色キー（legend の値。色の実体は色票が持つ）。"" は透明。
type Key string

// Clear は透明。
const Clear Key = ""

// OpRef は画素を最後に書いた op の場所。Part が "" なら op で描いていない（rows から読んだ）画素。
type OpRef struct {
	Part  string `json:"part,omitempty"`
	Index int    `json:"index"`
	Op    string `json:"op,omitempty"`
}

// String は「部品.ops[番号] op 名」の字面（例 body.ops[1] shade_step）。
func (r OpRef) String() string {
	if r.Part == "" && r.Op == "" {
		return ""
	}
	return fmt.Sprintf("%s.ops[%d] %s", r.Part, r.Index, r.Op)
}

// Grid は W×H の画素。px[y][x] が色キー、src[y][x] がそれを書いた op。
// 書けるのは Put・Fill・Flip だけ（どれも OpRef を残す）。読むのは At・SrcAt。
type Grid struct {
	W, H int
	px   [][]Key
	src  [][]OpRef
}

// NewGrid は透明の格子を作る。
func NewGrid(w, h int) *Grid {
	px := make([][]Key, h)
	src := make([][]OpRef, h)
	for y := range px {
		px[y] = make([]Key, w)
		src[y] = make([]OpRef, w)
	}
	return &Grid{W: w, H: h, px: px, src: src}
}

// In は (x, y) が格子の中か。
func (g *Grid) In(x, y int) bool { return x >= 0 && x < g.W && y >= 0 && y < g.H }

// SrcAt は (x, y) を最後に書いた op。格子の外は空。
func (g *Grid) SrcAt(x, y int) OpRef {
	if !g.In(x, y) {
		return OpRef{}
	}
	return g.src[y][x]
}

// At は格子の外を透明として引く。
func (g *Grid) At(x, y int) Key {
	if !g.In(x, y) {
		return Clear
	}
	return g.px[y][x]
}

// Put は 1 画素を書く。格子の外なら何もしない。
func (g *Grid) Put(x, y int, k Key, ref OpRef) {
	if g.In(x, y) {
		g.px[y][x] = k
		g.src[y][x] = ref
	}
}

// Fill は塊を 1 色で塗る。
func (g *Grid) Fill(m Mask, k Key, ref OpRef) {
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			if m.At(x, y) {
				g.px[y][x] = k
				g.src[y][x] = ref
			}
		}
	}
}

// Opaque は透明でない画素の塊。
func (g *Grid) Opaque() Mask {
	m := NewMask(g.W, g.H)
	for y := range m {
		for x := range m[y] {
			m[y][x] = g.px[y][x] != Clear
		}
	}
	return m
}

// Count は透明でない画素の数。
func (g *Grid) Count() int { return g.Opaque().Count() }

// Keys は使っている色キー（透明を除く）を名前の順で。
func (g *Grid) Keys() []Key {
	seen := map[Key]bool{}
	for _, row := range g.px {
		for _, k := range row {
			if k != Clear {
				seen[k] = true
			}
		}
	}
	out := make([]Key, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// Clone は写しを作る。
func (g *Grid) Clone() *Grid {
	c := NewGrid(g.W, g.H)
	for y := 0; y < g.H; y++ {
		copy(c.px[y], g.px[y])
		copy(c.src[y], g.src[y])
	}
	return c
}

// Only は m の中の画素だけを残した写し。
func (g *Grid) Only(m Mask) *Grid {
	c := NewGrid(g.W, g.H)
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			if m.At(x, y) {
				c.px[y][x], c.src[y][x] = g.px[y][x], g.src[y][x]
			}
		}
	}
	return c
}

// Flip は格子を左右（vertical=false）か上下に返す。
func (g *Grid) Flip(vertical bool) {
	if vertical {
		for i, j := 0, g.H-1; i < j; i, j = i+1, j-1 {
			g.px[i], g.px[j] = g.px[j], g.px[i]
			g.src[i], g.src[j] = g.src[j], g.src[i]
		}
		return
	}
	for y := range g.px {
		row, src := g.px[y], g.src[y]
		for i, j := 0, len(row)-1; i < j; i, j = i+1, j-1 {
			row[i], row[j] = row[j], row[i]
			src[i], src[j] = src[j], src[i]
		}
	}
}

// UnknownKeyError は legend に文字の無い色キー。
type UnknownKeyError struct{ Key Key }

func (e UnknownKeyError) Error() string {
	return fmt.Sprintf("legend に無い色キー %q", string(e.Key))
}

// Rows は格子を legend の文字の行にする。透明は '.'。charOf に無い色キーは UnknownKeyError。
func (g *Grid) Rows(charOf map[Key]string) ([]string, error) {
	out := make([]string, g.H)
	for y := 0; y < g.H; y++ {
		b := make([]byte, 0, g.W)
		for x := 0; x < g.W; x++ {
			k := g.px[y][x]
			if k == Clear {
				b = append(b, '.')
				continue
			}
			ch, ok := charOf[k]
			if !ok {
				return nil, UnknownKeyError{k}
			}
			b = append(b, ch...)
		}
		out[y] = string(b)
	}
	return out, nil
}

// GridFromRows は rows（legend の文字の行）を格子にする。幅は 1 行目の文字数。
// legend に無い文字は透明にして、初めて出た順ではなく文字の順で unknown に返す
// （透明の字 '.' などを外すのは呼ぶ側）。
func GridFromRows(rows []string, legend map[string]Key) (g *Grid, unknown []rune) {
	w := 0
	if len(rows) > 0 {
		w = len([]rune(rows[0]))
	}
	g = NewGrid(w, len(rows))
	seen := map[rune]bool{}
	for y, row := range rows {
		x := 0
		for _, ch := range row {
			if k, ok := legend[string(ch)]; ok {
				if x < w {
					g.px[y][x] = k
				}
			} else if !seen[ch] {
				seen[ch] = true
				unknown = append(unknown, ch)
			}
			x++
		}
	}
	sort.Slice(unknown, func(i, j int) bool { return unknown[i] < unknown[j] })
	return g, unknown
}
