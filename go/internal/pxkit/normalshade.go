package pxkit

// normalShade — 部品（塊）を高さの場とみなして法線を出し、光の向きとの内積でランプの 4 段に塗る。
// キャラ・魔物の体のように丸みのある物の作法をまとめて持つ:
//   - 光は左上（light で向きを変えられる）
//   - 前の部品が後ろの部品に落とす影（左上 1〜2px に前の部品があれば一段暗く）
//   - 外周: 右下の縁は墨（outline）、光の側の縁は材質の暗色か rim（暗い材質を闇から抜く明るい縁）
//   - 内側の境目: 後ろの別グループの部品に接する縁を暗色で締める
//
//	{"normalShade": {"light": [-0.55, -0.70, 0.55], "parts": [
//	   {"shape": 形, "ramp": "pink", "thick": 11, "group": "body"}, ...],
//	 "details": [op, ...]}}            details は put / line / stamp（顔・つや・小物を手で打つ）

import (
	"fmt"
	"math"
)

// pad は塊を画面の外まで追う幅。画面の端で切った塊で距離を測ると、端の画素だけ平たく塗られる
// （腕を画面の外へ伸ばしたコマで、端の光の段が変わる）。
const pad = 32

// paddedMask は画面の外へ pad ずつ広げた格子で塊を取る（[y+pad][x+pad] で引く）。
func paddedMask(f SDF, w, h int) Mask {
	m := make(Mask, h+2*pad)
	for y := range m {
		m[y] = make([]bool, w+2*pad)
		for x := range m[y] {
			m[y][x] = f(float64(x-pad)+0.5, float64(y-pad)+0.5) <= 0
		}
	}
	return m
}

type part struct {
	mask    Mask
	ramp    []string
	thick   float64
	group   string
	lines   bool
	flat    bool
	bias    float64
	outline string
	rim     string
}

// chamfer は塊の内側の、縁からの距離（3-4 の面取り距離 ÷ 3。塊の外は 0）。
func chamfer(m Mask, w, h int) [][]float64 {
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

func (c *ctx) normalShade(p map[string]any) error {
	g := c.g
	lv := nums(p["light"])
	if len(lv) != 3 {
		lv = []float64{-0.55, -0.70, 0.55}
	}
	n := math.Sqrt(lv[0]*lv[0] + lv[1]*lv[1] + lv[2]*lv[2])
	light := [3]float64{lv[0] / n, lv[1] / n, lv[2] / n}
	ramps := c.ramps
	var parts []part
	arr, _ := p["parts"].([]any)
	for i, e := range arr {
		pm, _ := e.(map[string]any)
		f, err := ShapeOf(pm["shape"], c.shapes)
		if err != nil {
			return fmt.Errorf("parts[%d]: %w", i, err)
		}
		rn, _ := pm["ramp"].(string)
		ramp := strs(ramps[rn])
		if len(ramp) < 4 {
			return fmt.Errorf("parts[%d]: ramp %q は暗 → 明の 4 段で書く", i, rn)
		}
		pt := part{mask: paddedMask(f, g.W, g.H), ramp: ramp, thick: num(pm["thick"], 6), lines: true,
			bias: num(pm["bias"], 0), outline: c.color("ink")}
		pt.group, _ = pm["group"].(string)
		if v, ok := pm["lines"].(bool); ok {
			pt.lines = v
		}
		if v, ok := pm["flat"].(bool); ok {
			pt.flat = v
		}
		if v, ok := pm["outline"]; ok {
			pt.outline = c.color(v) // "" で外周の墨を外す
		}
		if v, ok := pm["rim"]; ok {
			pt.rim = c.color(v)
		}
		parts = append(parts, pt)
	}
	w, h := g.W, g.H
	label := make([][]int, h)
	for y := range label {
		label[y] = make([]int, w)
		for x := range label[y] {
			label[y][x] = -1
			for i, pt := range parts {
				if pt.mask[y+pad][x+pad] {
					label[y][x] = i
				}
			}
		}
	}
	lab := func(x, y int) int {
		if x < 0 || y < 0 || x >= w || y >= h {
			return -1
		}
		return label[y][x]
	}
	fields := make([][][]float64, len(parts))
	for i, pt := range parts {
		fields[i] = chamfer(pt.mask, w+2*pad, h+2*pad)
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			idx := label[y][x]
			if idx < 0 {
				continue
			}
			pt := parts[idx]
			level := 2
			if !pt.flat {
				dist := fields[idx]
				hh := func(px, py int) float64 {
					v := 0.0
					if px+pad >= 0 && py+pad >= 0 && px+pad < w+2*pad && py+pad < h+2*pad {
						v = dist[py+pad][px+pad]
					}
					u := math.Min(1.0, v/pt.thick)
					return math.Sqrt(float64(u * (2.0 - u)))
				}
				gx := float64(hh(x+1, y)-hh(x-1, y)) * 0.5
				gy := float64(hh(x, y+1)-hh(x, y-1)) * 0.5
				k := pt.thick * 0.9
				nx, ny, nz := -gx*k, -gy*k, 1.0
				nl := math.Sqrt(float64(nx*nx) + float64(ny*ny) + float64(nz*nz))
				i := (float64(nx*light[0])+float64(ny*light[1])+float64(nz*light[2]))/nl + pt.bias
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
			}
			// 前の部品が落とす影（光は左上）
			for _, d := range [5][2]int{{-1, -1}, {0, -1}, {-1, 0}, {-2, -2}, {0, -2}} {
				q := lab(x+d[0], y+d[1])
				if q >= 0 && q > idx && parts[q].group != pt.group {
					level = max(0, level-1)
					break
				}
			}
			col := pt.ramp[level]
			up, left := lab(x, y-1) < 0, lab(x-1, y) < 0
			down, right := lab(x, y+1) < 0, lab(x+1, y) < 0
			if up || left || down || right {
				if (down || right) && pt.outline != "" {
					col = pt.outline
				} else if pt.rim != "" {
					col = pt.rim
				} else {
					col = pt.ramp[0]
				}
			} else if pt.lines {
				for _, d := range dirs4 {
					q := lab(x+d[0], y+d[1])
					if q >= 0 && q < idx && parts[q].group != pt.group {
						if level > 0 || pt.outline == "" {
							col = pt.ramp[0]
						} else {
							col = pt.outline
						}
						break
					}
				}
			}
			g.Px[y][x] = col
		}
	}
	details, _ := p["details"].([]any)
	return c.run(details)
}
