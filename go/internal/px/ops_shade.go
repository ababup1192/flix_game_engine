package px

// shade_parts: 部品の塊を高さの場とみなして法線を出し、光（light.dir）との内積でランプの 4 段に塗る。
// 同じコマで shade_parts を持つ部品をまとめて 1 組と見て、前の部品が後ろの部品に落とす影・
// 別グループの部品との境目の線を、その組の中で決める（列の後ろほど手前）。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// pad は塊を画面の外まで追う幅。画面の端で切った塊で距離を測ると、端の画素だけ平たく塗られる。
const pad = 32

type shadeSet struct {
	ids    []string
	idx    map[string]int
	masks  []pxlib.Mask // 画面の外へ pad ずつ広げた塊（[y+pad][x+pad]）
	fields [][][]float64
	label  [][]int
	groups []string
}

func init() {
	register(&opDef{
		Name: "shade_parts", Example: `{"shade_parts": {"thick": 4, "group": "body"}}`, Summary: "丸みのある部品を光の向きでランプの 4 段に塗る（前の部品の落とす影・外周の墨・別グループとの境目の線つき）",
		Technique: "陰影（丸い体・キャラ。光源は 1 つ）", Finish: "lint pillow・light-dir",
		Checks: []checkRef{{Check: checkPillow}, {Check: checkLightDir}},
		Params: []param{
			{Name: "thick", Type: tNumber, Default: 6.0, Summary: "丸みの厚さ（大きいほど縁から奥まで段が続く）", Lo: bound(0.5), Hi: bound(64)},
			{Name: "group", Type: tString, Default: "", Summary: "同じグループの部品どうしは影と境目の線を付けない"},
			{Name: "lines", Type: tBool, Default: true, Summary: "後ろの別グループの部品に接する縁を暗い段で締める"},
			{Name: "flat", Type: tBool, Default: false, Summary: "丸みを付けず地の段で塗る"},
			{Name: "bias", Type: tNumber, Default: 0.0, Summary: "明るさの底上げ（正で明るく）", Lo: bound(-1), Hi: bound(1)},
			{Name: "outline", Type: tColor, Default: "ink", Summary: "影の側の外周の色（\"\" で外す）"},
			{Name: "rim", Type: tColor, Default: "", Summary: "光の側の外周の色（暗い材質を闇から抜く明るい縁。省くとランプの最暗段）"},
			{Name: "bounce", Type: tNumber, Default: 0.0, Summary: "照り返し: 一番暗い段のうち、法線が下（地面）を向く割合がこれ以上の所を 1 段明るく（0 で付けない・0.5 で影の下半分。境目の近くは暗いまま残る）", Lo: bound(0), Hi: bound(1)},
		},
		Apply: func(c *ctx, a opArgs) error {
			// 塊は部品の at（pose のずらしを含む）で組むので、ずらせないのは use の at だけ
			if c.ox != c.Part.Part.At.X || c.oy != c.Part.Part.At.Y {
				return fmt.Errorf("use の at でずらせない（部品の at か pose でずらす）")
			}
			if err := c.NeedRamp(4); err != nil {
				return err
			}
			if c.Part.shape == nil {
				return fmt.Errorf("部品に shape が要る（塊の形から丸みを出す）")
			}
			return c.shadeParts(a)
		},
	})
}

// shadeSetOf は今のコマで shade_parts を持つ部品の組（初めて呼ばれた時に作る）。
func (c *ctx) shadeSetOf() *shadeSet {
	if c.shade != nil {
		return c.shade
	}
	s := &shadeSet{idx: map[string]int{}}
	w, h := c.G.W, c.G.H
	for _, p := range c.order {
		var call *opCall
		for i := range p.Ops {
			if p.Ops[i].Name == "shade_parts" {
				call = &p.Ops[i]
			}
		}
		if call == nil || p.Shape == nil {
			continue
		}
		f, err := shapeOf(p.Shape, c.Spec.Shapes, p.Where+".shape")
		if err != nil {
			continue
		}
		f = shiftSDF(f, p.At.X, p.At.Y)
		m := pxlib.NewMask(w+2*pad, h+2*pad)
		for y := range m {
			for x := range m[y] {
				m[y][x] = f(float64(x-pad)+0.5, float64(y-pad)+0.5) <= 0
			}
		}
		s.idx[p.ID] = len(s.ids)
		s.ids = append(s.ids, p.ID)
		s.masks = append(s.masks, m)
		s.fields = append(s.fields, chamfer(m, w+2*pad, h+2*pad))
		g := call.Args.str("group")
		s.groups = append(s.groups, g)
	}
	s.label = make([][]int, h)
	for y := range s.label {
		s.label[y] = make([]int, w)
		for x := range s.label[y] {
			s.label[y][x] = -1
			for i, m := range s.masks {
				if m[y+pad][x+pad] {
					s.label[y][x] = i
				}
			}
		}
	}
	c.shade = s
	return s
}

func (c *ctx) shadeParts(a opArgs) error {
	s := c.shadeSetOf()
	idx := s.idx[c.Part.Part.ID]
	ramp := c.Ramp()
	outline, err := c.Color(a.color("outline"))
	if err != nil {
		return err
	}
	rim, err := c.Color(a.color("rim"))
	if err != nil {
		return err
	}
	thick, flat, lines, bias, bounce := a.num("thick"), a.bool("flat"), a.bool("lines"), a.num("bias"), a.num("bounce")
	group := s.groups[idx]
	ld := c.Spec.Light.Dir
	n := math.Sqrt(float64(ld[0]*ld[0]) + float64(ld[1]*ld[1]) + float64(ld[2]*ld[2]))
	light := [3]float64{ld[0] / n, ld[1] / n, ld[2] / n}
	w, h := c.G.W, c.G.H
	lab := func(x, y int) int {
		if x < 0 || y < 0 || x >= w || y >= h {
			return -1
		}
		return s.label[y][x]
	}
	sx, sy := c.LightSign()
	dist := s.fields[idx]
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if s.label[y][x] != idx {
				continue
			}
			level := 2
			if !flat {
				hh := func(px, py int) float64 {
					v := 0.0
					if px+pad >= 0 && py+pad >= 0 && px+pad < w+2*pad && py+pad < h+2*pad {
						v = dist[py+pad][px+pad]
					}
					u := math.Min(1.0, v/thick)
					return math.Sqrt(float64(u * (2.0 - u)))
				}
				gx := float64(hh(x+1, y)-hh(x-1, y)) * 0.5
				gy := float64(hh(x, y+1)-hh(x, y-1)) * 0.5
				k := thick * 0.9
				nx, ny, nz := -gx*k, -gy*k, 1.0
				nl := math.Sqrt(float64(nx*nx) + float64(ny*ny) + float64(nz*nz))
				i := (float64(nx*light[0])+float64(ny*light[1])+float64(nz*light[2]))/nl + bias
				switch {
				case i < 0.18:
					level = 0
				case i < 0.50:
					level = 1
				case i < 0.80:
					level = 2
				default:
					level = 3
				}
				// 照り返し: 地面で跳ね返った光が影の下側に入る（境目の近くの core shadow は暗いまま）
				if bounce > 0 && level == 0 && ny/nl >= 1-bounce {
					level = 1
				}
			}
			// 前の部品が落とす影（光の来る側の 1〜2px に手前の部品があれば一段暗く）
			for _, d := range [5][2]int{{1, 1}, {0, 1}, {1, 0}, {2, 2}, {0, 2}} {
				q := lab(x+d[0]*sx, y+d[1]*sy)
				if q >= 0 && q > idx && s.groups[q] != group {
					level = max(0, level-1)
					break
				}
			}
			col := ramp[level]
			up, left := lab(x, y-1) < 0, lab(x-1, y) < 0
			down, right := lab(x, y+1) < 0, lab(x+1, y) < 0
			if up || left || down || right {
				if (down || right) && outline != pxlib.Clear {
					col = outline
				} else if rim != pxlib.Clear {
					col = rim
				} else {
					col = ramp[0]
				}
			} else if lines {
				for _, d := range pxlib.Dirs4 {
					q := lab(x+d.X, y+d.Y)
					if q >= 0 && q < idx && s.groups[q] != group {
						if level > 0 || outline == pxlib.Clear {
							col = ramp[0]
						} else {
							col = outline
						}
						break
					}
				}
			}
			c.PutAbs(x, y, col)
		}
	}
	return nil
}

// chamfer は塊の内側の、縁からの距離（3-4 の面取り距離 ÷ 3。塊の外は 0）。
func chamfer(m pxlib.Mask, w, h int) [][]float64 {
	const inf = 1000000
	d := make([][]int, h)
	for y := range d {
		d[y] = make([]int, w)
		for x := range d[y] {
			if m[y][x] {
				d[y][x] = inf
			}
		}
	}
	at := func(x, y int) int {
		if x < 0 || y < 0 || x >= w || y >= h {
			return 0
		}
		return d[y][x]
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if d[y][x] == 0 {
				continue
			}
			best := d[y][x]
			for _, s := range [4][3]int{{-1, 0, 3}, {0, -1, 3}, {-1, -1, 4}, {1, -1, 4}} {
				best = min(best, at(x+s[0], y+s[1])+s[2])
			}
			d[y][x] = best
		}
	}
	for y := h - 1; y >= 0; y-- {
		for x := w - 1; x >= 0; x-- {
			if d[y][x] == 0 {
				continue
			}
			best := d[y][x]
			for _, s := range [4][3]int{{1, 0, 3}, {0, 1, 3}, {1, 1, 4}, {-1, 1, 4}} {
				best = min(best, at(x+s[0], y+s[1])+s[2])
			}
			d[y][x] = best
		}
	}
	out := make([][]float64, h)
	for y := range out {
		out[y] = make([]float64, w)
		for x := range out[y] {
			out[y][x] = float64(d[y][x]) / 3.0
		}
	}
	return out
}
