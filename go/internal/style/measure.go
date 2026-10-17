package style

// 1 枚の絵を数値にする測り。

import (
	"math"
	"sort"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// Region は同じ色でつながった大きい面 1 つ。
type Region struct {
	Area float64
	Col  uint32
	Pos  string
	IOU  float64
}

// Stats は 1 枚の測定結果。
type Stats struct {
	Path         string
	Width        int
	Height       int
	Unit         int
	UnitAuto     bool
	Grid         float64
	HasGrid      bool
	AA           float64
	Steps        [4]float64
	Colors       int
	ColorsPerKpx float64
	Cover90      int
	Luma         float64
	Luma3        [3]float64
	Ellipse      float64
	Regions      []Region
	RegionArea   float64
}

func chanMaxDiff(p, q uint32) int {
	d := 0
	for s := 0; s < 3; s++ {
		a := int((p >> (uint(s) * 8)) & 255)
		b := int((q >> (uint(s) * 8)) & 255)
		if a > b {
			a, b = b, a
		}
		if b-a > d {
			d = b - a
		}
	}
	return d
}

type scanResult struct {
	colors map[uint32]int
	aa     float64
	steps  [4]int
	luma3  [3]float64
	luma   float64
}

func (r *Rules) scanImage(im *pxlib.Image) scanResult {
	w, h := im.W, im.H
	counts := make(map[uint32]int)
	soft := 0
	var steps [4]int
	var luma3 [3]int
	lumaSum := 0
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			p := im.RGBAt(x, y)
			counts[p]++
			v := (299*int(p>>16&255) + 587*int(p>>8&255) + 114*int(p&255)) / 1000
			lumaSum += v
			switch {
			case v < 85:
				luma3[0]++
			case v < 171:
				luma3[1]++
			default:
				luma3[2]++
			}
			isSoft := false
			// 右と下だけ数えれば、隣り合う組を 1 回ずつ数えられる。
			for k := 0; k < 2; k++ {
				var q uint32
				if k == 0 {
					if x+1 >= w {
						continue
					}
					q = im.RGBAt(x+1, y)
				} else {
					if y+1 >= h {
						continue
					}
					q = im.RGBAt(x, y+1)
				}
				if q == p {
					continue
				}
				d := chanMaxDiff(p, q)
				switch {
				case d <= r.StepEdges[0]:
					steps[0]++
				case d <= r.StepEdges[1]:
					steps[1]++
				case d <= r.StepEdges[2]:
					steps[2]++
				default:
					steps[3]++
				}
				if d <= r.SoftStep {
					isSoft = true
				}
			}
			// 中間色は左と上も見る (段の分布は数えない)。
			if !isSoft {
				for k := 0; k < 2; k++ {
					var q uint32
					if k == 0 {
						if x == 0 {
							continue
						}
						q = im.RGBAt(x-1, y)
					} else {
						if y == 0 {
							continue
						}
						q = im.RGBAt(x, y-1)
					}
					if q == p {
						continue
					}
					if chanMaxDiff(p, q) <= r.SoftStep {
						isSoft = true
						break
					}
				}
			}
			if isSoft {
				soft++
			}
		}
	}
	total := float64(w * h)
	return scanResult{
		colors: counts,
		aa:     100.0 * float64(soft) / total,
		steps:  steps,
		luma3: [3]float64{
			100.0 * float64(luma3[0]) / total,
			100.0 * float64(luma3[1]) / total,
			100.0 * float64(luma3[2]) / total,
		},
		luma: float64(lumaSum) / total,
	}
}

func gridFit(im *pxlib.Image, unit int) float64 {
	if unit <= 1 {
		return 1.0
	}
	on, off := 0, 0
	for y := 0; y < im.H; y++ {
		for x := 1; x < im.W; x++ {
			if im.RGBAt(x, y) != im.RGBAt(x-1, y) {
				if x%unit != 0 {
					off++
				} else {
					on++
				}
			}
		}
	}
	for y := 1; y < im.H; y++ {
		hit := y%unit == 0
		for x := 0; x < im.W; x++ {
			if im.RGBAt(x, y) != im.RGBAt(x, y-1) {
				if hit {
					on++
				} else {
					off++
				}
			}
		}
	}
	if on+off == 0 {
		return 1.0
	}
	return float64(on) / float64(on+off)
}

// gridScore は格子適合率を「偶然当たる分」で割り戻した値。第 2 の返り値が
// false なら測れなかった（表示は「—」）。
func gridScore(im *pxlib.Image, unit int) (float64, bool) {
	if unit <= 1 {
		return 0, false
	}
	raw := gridFit(im, unit)
	chance := 1.0 / float64(unit)
	return math.Max(0.0, (raw-chance)/(1.0-chance)), true
}

func (r *Rules) findUnit(im *pxlib.Image) (int, float64) {
	best, bestScore := 1, 0.0
	for u := 2; u <= r.MaxUnit; u++ {
		s, ok := gridScore(im, u)
		// 大きい unit は小さい unit の倍数を兼ねるので、同点なら小さい方を採る。
		if ok && s > bestScore+0.02 {
			best, bestScore = u, s
		}
	}
	if bestScore >= r.GridFound {
		return best, bestScore
	}
	return 1, bestScore
}

func (r *Rules) quantize(im *pxlib.Image) []uint32 {
	out := make([]uint32, im.W*im.H)
	step := r.RegionQuant
	for i := range out {
		o := i * 4
		rr := uint32(int(im.Pix[o])/step*step + step/2)
		g := uint32(int(im.Pix[o+1])/step*step + step/2)
		b := uint32(int(im.Pix[o+2])/step*step + step/2)
		out[i] = rr<<16 | g<<8 | b
	}
	return out
}

type rawRegion struct {
	col   uint32
	cells []int32 // y*w+x
}

func (r *Rules) findRegions(q []uint32, w, h, minArea int) []rawRegion {
	seen := make([]bool, w*h)
	var out []rawRegion
	queue := make([]int32, 0, 256)
	for y0 := 0; y0 < h; y0++ {
		for x0 := 0; x0 < w; x0++ {
			start := y0*w + x0
			if seen[start] {
				continue
			}
			col := q[start]
			seen[start] = true
			queue = queue[:0]
			queue = append(queue, int32(start))
			cells := make([]int32, 0, 64)
			for head := 0; head < len(queue); head++ {
				idx := queue[head]
				cells = append(cells, idx)
				x, y := int(idx)%w, int(idx)/w
				if x > 0 && !seen[int(idx)-1] && q[int(idx)-1] == col {
					seen[int(idx)-1] = true
					queue = append(queue, idx-1)
				}
				if x+1 < w && !seen[int(idx)+1] && q[int(idx)+1] == col {
					seen[int(idx)+1] = true
					queue = append(queue, idx+1)
				}
				if y > 0 && !seen[int(idx)-w] && q[int(idx)-w] == col {
					seen[int(idx)-w] = true
					queue = append(queue, idx-int32(w))
				}
				if y+1 < h && !seen[int(idx)+w] && q[int(idx)+w] == col {
					seen[int(idx)+w] = true
					queue = append(queue, idx+int32(w))
				}
			}
			if len(cells) >= minArea {
				out = append(out, rawRegion{col: col, cells: cells})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		return len(out[i].cells) > len(out[j].cells)
	})
	if len(out) > r.RegionCap {
		out = out[:r.RegionCap]
	}
	return out
}

// WhyNot: 塊を拾う探索を幅優先で固定しているのは、順が変わると cells の並びが変わり、
// 楕円の重なり具合の丸め誤差がずれるため。
func regionEllipseIOU(cells []int32, w int) float64 {
	n := float64(len(cells))
	var mx, my float64
	for _, c := range cells {
		mx += float64(int(c) % w)
		my += float64(int(c) / w)
	}
	mx /= n
	my /= n
	var sxx, syy, sxy float64
	for _, c := range cells {
		dx := float64(int(c)%w) - mx
		dy := float64(int(c)/w) - my
		sxx += dx * dx
		syy += dy * dy
		sxy += dx * dy
	}
	sxx /= n
	syy /= n
	sxy /= n
	tr := sxx + syy
	det := sxx*syy - sxy*sxy
	if det <= 1e-9 {
		return 0.0
	}
	disc := math.Sqrt(math.Max(tr*tr/4-det, 0.0))
	l1, l2 := tr/2+disc, tr/2-disc
	if l2 <= 1e-9 {
		return 0.0
	}
	a, b := 2*math.Sqrt(l1), 2*math.Sqrt(l2)
	th := 0.5 * math.Atan2(2*sxy, sxx-syy)
	ct, st := math.Cos(th), math.Sin(th)
	inside := 0
	for _, c := range cells {
		dx := float64(int(c)%w) - mx
		dy := float64(int(c)/w) - my
		u := (dx*ct + dy*st) / a
		v := (-dx*st + dy*ct) / b
		if u*u+v*v <= 1.0 {
			inside++
		}
	}
	union := n + math.Pi*a*b - float64(inside)
	if union > 0 {
		return float64(inside) / union
	}
	return 0.0
}

func (r *Rules) regionWhere(cells []int32, w, h int) string {
	var mx, my float64
	for _, c := range cells {
		mx += float64(int(c) % w)
		my += float64(int(c) / w)
	}
	n := float64(len(cells))
	mx /= n
	my /= n
	by := int(math.Floor(my * 3 / float64(h)))
	bx := int(math.Floor(mx * 3 / float64(w)))
	if by > 2 {
		by = 2
	}
	if bx > 2 {
		bx = 2
	}
	return r.BlockNames[by][bx]
}

func coverCount(counts map[uint32]int, total int) int {
	vals := make([]int, 0, len(counts))
	for _, v := range counts {
		vals = append(vals, v)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(vals)))
	acc, n := 0, 0
	for _, c := range vals {
		acc += c
		n++
		if float64(acc) >= 0.90*float64(total) {
			break
		}
	}
	return n
}

// Measure は 1 枚を測る。hasUnit が false なら unit を自動で探す。
func (r *Rules) Measure(path string, unit int, hasUnit bool) (*Stats, error) {
	im, err := pxlib.LoadPNG(path)
	if err != nil {
		return nil, err
	}
	s := r.scanImage(im)
	total := im.W * im.H
	auto := false
	if !hasUnit {
		unit, _ = r.findUnit(im)
		auto = true
	}
	grid, hasGrid := gridScore(im, unit)
	stepSum := s.steps[0] + s.steps[1] + s.steps[2] + s.steps[3]
	if stepSum == 0 {
		stepSum = 1
	}
	st := &Stats{
		Path: path, Width: im.W, Height: im.H,
		Unit: unit, UnitAuto: auto,
		Grid: grid, HasGrid: hasGrid,
		AA:           s.aa,
		Colors:       len(s.colors),
		ColorsPerKpx: 1000.0 * float64(len(s.colors)) / float64(total),
		Cover90:      coverCount(s.colors, total),
		Luma:         s.luma,
		Luma3:        s.luma3,
	}
	for i := 0; i < 4; i++ {
		st.Steps[i] = 100.0 * float64(s.steps[i]) / float64(stepSum)
	}

	minArea := int(r.RegionMin * float64(total))
	if minArea < 48 {
		minArea = 48
	}
	regs := r.findRegions(r.quantize(im), im.W, im.H, minArea)
	ell := 0
	for _, reg := range regs {
		iou := regionEllipseIOU(reg.cells, im.W)
		if iou >= r.EllipseIoU {
			ell += len(reg.cells)
		}
		st.Regions = append(st.Regions, Region{
			Area: 100.0 * float64(len(reg.cells)) / float64(total),
			Col:  reg.col,
			Pos:  r.regionWhere(reg.cells, im.W, im.H),
			IOU:  iou,
		})
	}
	st.Ellipse = 100.0 * float64(ell) / float64(total)
	for _, reg := range st.Regions {
		st.RegionArea += reg.Area
	}
	return st, nil
}
