package carve

// 3 面図から立体を彫り出し、3D で動かして 4 方向へ描き直す。
//
//	fge-go carve 三面図.png --id 名前 --size 32x48
//
// 実行したディレクトリの assets/chars/ と gallery/ に書き出す。

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// Marks は体の高さの目印。
type Marks struct {
	Top, Bottom, Head, Hip int
	Center                 float64
}

// Parts は部位ごとのボクセル。
type Parts = pxlib.OMap[string, *VoxSet]

// VoxSet はボクセルの集まり (色は持たない)。
type VoxSet = pxlib.OMap[Vox, struct{}]

// VoxMoved は動かした後の位置 → 出身位置。
type VoxMoved = pxlib.OMap[Vox, Vox]

// carveViews は描き直す 4 方向。
var carveViews = []string{"front", "right", "back", "left"}

// StanceCenter は立ち位置の中心。外接枠でなく足元で決める。
func StanceCenter(cells *Cells, share float64) float64 {
	var ys []int
	for _, p := range cells.Keys() {
		ys = append(ys, p.Y)
	}
	bottom, top := maxOf(ys), minOf(ys)
	floor := bottom - int(float64(bottom-top)*share)
	var feet []int
	for _, p := range cells.Keys() {
		if p.Y >= floor {
			feet = append(feet, p.X)
		}
	}
	if len(feet) == 0 {
		for _, p := range cells.Keys() {
			feet = append(feet, p.X)
		}
	}
	sort.Ints(feet)
	return float64(feet[0]+feet[len(feet)-1]) / 2
}

// Align は 3 面をまとめて位置合わせする。
func Align(views *pxlib.OMap[string, *Cells], size [2]int, rules *Rules) *pxlib.OMap[string, *Cells] {
	width, height := size[0], size[1]
	floor := 0
	for i, name := range views.Keys() {
		cells, _ := views.Get(name)
		var ys []int
		for _, p := range cells.Keys() {
			ys = append(ys, p.Y)
		}
		if v := maxOf(ys); i == 0 || v > floor {
			floor = v
		}
	}
	out := pxlib.NewOMap[string, *Cells]()
	for _, name := range views.Keys() {
		cells, _ := views.Get(name)
		dy := (height - 2) - floor
		target := float64(width) / 2
		if name == "back" {
			target = float64(width-1) - float64(width)/2
		}
		dx := int(math.RoundToEven(target - StanceCenter(cells, rules.Profile.FeetShare)))
		moved := pxlib.NewOMap[Pt, RGB]()
		for _, p := range cells.Keys() {
			c, _ := cells.Get(p)
			q := Pt{X: p.X + dx, Y: p.Y + dy}
			if 0 <= q.X && q.X < width && 0 <= q.Y && q.Y < height {
				moved.Set(q, c)
			}
		}
		out.Set(name, moved)
	}
	return out
}

// Carve は 3 枚のシルエットが同時に満たす所だけを残す。
//
// WhyNot: 背面図を読まないのは、前面と側面の重なりだけで残る所が決まり、
// 背面の行を足しても彫る結果が変わらないため。
func Carve(front, side *Cells, size [2]int) *VoxSet {
	height := size[1]
	rowsFront := map[int]*PySet[int]{}
	rowsSide := map[int]*PySet[int]{}
	add := func(rows map[int]*PySet[int], y, v int) {
		s, ok := rows[y]
		if !ok {
			s = NewPySet(hashInt)
			rows[y] = s
		}
		s.Add(v)
	}
	for _, p := range front.Keys() {
		add(rowsFront, p.Y, p.X)
	}
	for _, p := range side.Keys() {
		add(rowsSide, p.Y, p.X)
	}
	voxels := pxlib.NewOMap[Vox, struct{}]()
	for y := 0; y < height; y++ {
		xs, okX := rowsFront[y]
		zs, okZ := rowsSide[y]
		if !okX || !okZ || xs.Len() == 0 || zs.Len() == 0 {
			continue
		}
		for _, x := range xs.Items() {
			for _, z := range zs.Items() {
				voxels.Set(Vox{x, y, z}, struct{}{})
			}
		}
	}
	return voxels
}

// runsOf は昇順の値の列を、連続する区間 [始, 終] の列にまとめる。
func runsOf(values []int) [][2]int {
	var out [][2]int
	for _, v := range values {
		if len(out) > 0 && v == out[len(out)-1][1]+1 {
			out[len(out)-1][1] = v
		} else {
			out = append(out, [2]int{v, v})
		}
	}
	return out
}

// Slim は腕と持ち物の奥行きを絞り、幽霊の体積を消す。
func Slim(parts *Parts, front, side *Cells, rules *Rules) (*Parts, string) {
	byRow := map[int][]int{}
	var allZ []int
	for _, p := range side.Keys() {
		byRow[p.Y] = append(byRow[p.Y], p.X)
		allZ = append(allZ, p.X)
	}
	sort.Ints(allZ)
	axis := allZ[len(allZ)/2]
	bodySpan := map[int][2]int{}
	toolCols := map[int]*PySet[int]{}
	var rowOrder []int
	for _, p := range side.Keys() {
		if _, ok := bodySpan[p.Y]; !ok {
			bodySpan[p.Y] = [2]int{}
			rowOrder = append(rowOrder, p.Y)
		}
	}
	for _, y := range rowOrder {
		zs := append([]int{}, byRow[y]...)
		sort.Ints(zs)
		runs := runsOf(zs)
		bodyAt, bodyScore := 0, 0
		for i, r := range runs {
			score := 0
			if !(r[0] <= axis && axis <= r[1]) {
				score = minOf([]int{absInt(r[0] - axis), absInt(r[1] - axis)})
			}
			if i == 0 || score < bodyScore {
				bodyAt, bodyScore = i, score
			}
		}
		bodySpan[y] = [2]int{runs[bodyAt][0], runs[bodyAt][1]}
		cols := NewPySet(hashInt)
		for i, r := range runs {
			if i == bodyAt {
				continue
			}
			for z := r[0]; z <= r[1]; z++ {
				cols.Add(z)
			}
		}
		toolCols[y] = cols
	}

	step := rules.Profile.ToneStep
	tone := func(c RGB) RGB { return RGB{c[0] / step, c[1] / step, c[2] / step} }
	toolTones := NewCounter[RGB]()
	for _, y := range rowOrder {
		for _, z := range toolCols[y].Items() {
			c, _ := side.Get(Pt{X: z, Y: y})
			toolTones.Add(tone(c), 1)
		}
	}
	holder := ""
	if toolTones.Len() > 0 && rules.Profile.Tool != "none" {
		kinship := func(arm string) int {
			total := 0
			cells, ok := parts.Get(arm)
			if !ok {
				return 0
			}
			for _, v := range cells.Keys() {
				if c, ok := front.Get(Pt{X: v.X, Y: v.Y}); ok {
					total += toolTones.Get(tone(c))
				}
			}
			return total
		}
		holder = "armL"
		if kinship("armR") > kinship("armL") {
			holder = "armR"
		}
	}

	kept := pxlib.NewOMap[string, *VoxSet]()
	for _, name := range parts.Keys() {
		cells, _ := parts.Get(name)
		limb := strings.HasPrefix(name, "arm") || strings.HasPrefix(name, "leg")
		widthOf := map[int]map[int]bool{}
		if limb {
			for _, v := range cells.Keys() {
				if widthOf[v.Y] == nil {
					widthOf[v.Y] = map[int]bool{}
				}
				widthOf[v.Y][v.X] = true
			}
		}
		out := pxlib.NewOMap[Vox, struct{}]()
		for _, v := range cells.Keys() {
			if cols, ok := toolCols[v.Y]; ok && cols.Contains(v.Z) {
				if name == holder {
					out.Set(v, struct{}{})
				}
				continue
			}
			if limb {
				lo, hi := v.Z, v.Z
				if span, ok := bodySpan[v.Y]; ok {
					lo, hi = span[0], span[1]
				}
				half := maxOf([]int{1, len(widthOf[v.Y])/2 + rules.Profile.TubeMargin})
				if math.Abs(float64(v.Z)-float64(lo+hi)/2) > float64(half) {
					continue
				}
			}
			out.Set(v, struct{}{})
		}
		kept.Set(name, out)
	}

	haveS := map[Pt]bool{}
	for _, name := range kept.Keys() {
		cells, _ := kept.Get(name)
		for _, v := range cells.Keys() {
			haveS[Pt{X: v.Z, Y: v.Y}] = true
		}
	}
	for _, p := range side.Keys() {
		z, y := p.X, p.Y
		if haveS[Pt{X: z, Y: y}] {
			continue
		}
		type donor struct {
			name string
			hit  []Vox
		}
		var donors []donor
		for _, name := range parts.Keys() {
			cells, _ := parts.Get(name)
			var hit []Vox
			for _, v := range cells.Keys() {
				if v.Y == y && v.Z == z {
					hit = append(hit, v)
				}
			}
			if len(hit) > 0 {
				donors = append(donors, donor{name, hit})
			}
		}
		if len(donors) == 0 {
			continue
		}
		closeness := func(name string) int {
			near := 999
			found := false
			cells, _ := kept.Get(name)
			for _, v := range cells.Keys() {
				if v.Y == y {
					if d := absInt(v.Z - z); !found || d < near {
						near, found = d, true
					}
				}
			}
			return near
		}
		bestAt, bestScore := 0, closeness(donors[0].name)
		for i := 1; i < len(donors); i++ {
			if score := closeness(donors[i].name); score < bestScore {
				bestAt, bestScore = i, score
			}
		}
		target, _ := kept.Get(donors[bestAt].name)
		for _, v := range donors[bestAt].hit {
			target.Set(v, struct{}{})
		}
		haveS[Pt{X: z, Y: y}] = true
	}

	haveF := map[Pt]bool{}
	for _, name := range kept.Keys() {
		cells, _ := kept.Get(name)
		for _, v := range cells.Keys() {
			haveF[Pt{X: v.X, Y: v.Y}] = true
		}
	}
	for _, name := range parts.Keys() {
		cells, _ := parts.Get(name)
		target, _ := kept.Get(name)
		for _, v := range cells.Keys() {
			if !haveF[Pt{X: v.X, Y: v.Y}] {
				target.Set(v, struct{}{})
				haveF[Pt{X: v.X, Y: v.Y}] = true
			}
		}
	}
	return kept, holder
}

// SplitParts は体を頭・胴・腕・脚に分ける。高さと左右の位置だけで決める。
func SplitParts(voxels *VoxSet, rules *Rules) (*Parts, Marks) {
	var ys []int
	for _, v := range voxels.Keys() {
		ys = append(ys, v.Y)
	}
	top, bottom := minOf(ys), maxOf(ys)
	span := bottom - top
	headLine := top + int(float64(span)*rules.Profile.HeadRatio)
	hipLine := top + int(float64(span)*rules.Profile.HipRatio)
	var core []int
	for _, v := range voxels.Keys() {
		if headLine < v.Y && v.Y < hipLine {
			core = append(core, v.X)
		}
	}
	sort.Ints(core)
	trim := len(core) * rules.Profile.CoreTrimPct / 100
	inner := [2]int{core[trim], core[len(core)-trim-1]}
	center := float64(inner[0]+inner[1]) / 2
	parts := pxlib.NewOMap[string, *VoxSet]()
	put := func(name string, v Vox) {
		cells, ok := parts.Get(name)
		if !ok {
			cells = pxlib.NewOMap[Vox, struct{}]()
			parts.Set(name, cells)
		}
		cells.Set(v, struct{}{})
	}
	for _, v := range voxels.Keys() {
		var name string
		switch {
		case v.Y <= headLine:
			name = "head"
		case v.Y >= hipLine:
			name = "legR"
			if float64(v.X) >= center {
				name = "legL"
			}
		case v.X < inner[0]+1:
			name = "armR"
		case v.X > inner[1]-1:
			name = "armL"
		default:
			name = "torso"
		}
		put(name, v)
	}
	arms := []struct {
		name   string
		inBand func(int) bool
	}{
		{"armR", func(x int) bool { return x < inner[0]+1 }},
		{"armL", func(x int) bool { return x > inner[1]-1 }},
	}
	for _, arm := range arms {
		cells, ok := parts.Get(arm.name)
		if !ok {
			continue
		}
		frontier := cells.Keys()
		for len(frontier) > 0 {
			v := frontier[len(frontier)-1]
			frontier = frontier[:len(frontier)-1]
			for _, q := range []Vox{{v.X + 1, v.Y, v.Z}, {v.X - 1, v.Y, v.Z},
				{v.X, v.Y + 1, v.Z}, {v.X, v.Y - 1, v.Z},
				{v.X, v.Y, v.Z + 1}, {v.X, v.Y, v.Z - 1}} {
				if !arm.inBand(q.X) {
					continue
				}
				for _, leg := range []string{"legL", "legR"} {
					legCells, ok := parts.Get(leg)
					if !ok || !legCells.Has(q) {
						continue
					}
					legCells.Delete(q)
					cells.Set(q, struct{}{})
					frontier = append(frontier, q)
				}
			}
		}
	}
	return parts, Marks{Top: top, Bottom: bottom, Head: headLine, Hip: hipLine, Center: center}
}

// Swing は腕と脚を振り、体を沈める。
func Swing(name string, cells *VoxMoved, marks Marks, phase, dip, reach int, rise bool, rules *Rules) *VoxMoved {
	out := pxlib.NewOMap[Vox, Vox]()
	bottom, head, hip := marks.Bottom, marks.Head, marks.Hip
	for _, v := range cells.Keys() {
		origin, _ := cells.Get(v)
		dz := 0
		dy := dip
		switch {
		case strings.HasPrefix(name, "leg"):
			deep := float64(v.Y-hip) / float64(maxOf([]int{1, bottom - hip}))
			dy = int(math.RoundToEven(float64(dip) * (1 - deep)))
			if phase != 0 {
				side := -1
				if strings.HasSuffix(name, "L") {
					side = 1
				}
				dz = int(math.RoundToEven(float64(reach)*deep)) * phase * side
				if side*phase > 0 {
					if deep > rules.Profile.LiftAt {
						dy--
					}
					if deep > 0.92 {
						dy--
					}
				}
			}
		case strings.HasPrefix(name, "arm"):
			deep := 0.0
			if v.Y > hip {
				deep = 1.0
				low := float64(v.Y-hip) / float64(maxOf([]int{1, bottom - hip}))
				dy = int(math.RoundToEven(float64(dip) * (1 - low)))
			} else {
				deep = float64(v.Y-head) / float64(maxOf([]int{1, hip - head}))
			}
			if phase != 0 {
				side := 1
				if strings.HasSuffix(name, "L") {
					side = -1
				}
				dz = int(math.RoundToEven(float64(reach)*deep)) * phase * side
				if rise && phase*side > 0 && deep > 0.6 {
					dy--
				}
			}
		}
		out.Set(Vox{v.X, v.Y + dy, v.Z + dz}, origin)
	}
	return out
}

// screenOf はボクセル位置を、その向きの画面座標と奥行きへ写す。
func screenOf(view string, x, y, z, width int) (Pt, int) {
	switch view {
	case "front":
		return Pt{X: x, Y: y}, z
	case "right":
		return Pt{X: z, Y: y}, width - 1 - x
	case "back":
		return Pt{X: width - 1 - x, Y: y}, -z
	}
	return Pt{X: width - 1 - z, Y: y}, x
}

// imgX は画面 x を元図の x へ戻す。左向きだけ横図の鏡映を見ている。
func imgX(view string, sx, width int) int {
	if view == "left" {
		return width - 1 - sx
	}
	return sx
}

// FaceOwners は止まった姿で「各向きの各画素をどの部位が見せているか」を確定する。
func FaceOwners(parts *Parts, size [2]int) map[string]*pxlib.OMap[Pt, string] {
	width := size[0]
	owner := map[string]*pxlib.OMap[Pt, string]{}
	best := map[string]map[Pt]int{}
	for _, view := range carveViews {
		owner[view] = pxlib.NewOMap[Pt, string]()
		best[view] = map[Pt]int{}
	}
	for _, name := range parts.Keys() {
		cells, _ := parts.Get(name)
		for _, v := range cells.Keys() {
			for _, view := range carveViews {
				key, depth := screenOf(view, v.X, v.Y, v.Z, width)
				if cur, ok := best[view][key]; !ok || depth > cur {
					best[view][key] = depth
					owner[view].Set(key, name)
				}
			}
		}
	}
	return owner
}

type seenPixel struct {
	depth  int
	name   string
	origin Vox
}

// Dress は動かした立体を 1 方向へ落とし、色を元図から着せる。
func Dress(moved *pxlib.OMap[string, *VoxMoved], view string, owner map[string]*pxlib.OMap[Pt, string],
	imgs map[string]*Cells, size [2]int) *Cells {
	width, height := size[0], size[1]
	img := imgs[view]
	screen := pxlib.NewOMap[Pt, seenPixel]()
	for _, name := range moved.Keys() {
		cells, _ := moved.Get(name)
		for _, v := range cells.Keys() {
			origin, _ := cells.Get(v)
			key, depth := screenOf(view, v.X, v.Y, v.Z, width)
			if cur, ok := screen.Get(key); !ok || depth > cur.depth {
				screen.Set(key, seenPixel{depth, name, origin})
			}
		}
	}
	out := pxlib.NewOMap[Pt, RGB]()
	for _, key := range screen.Keys() {
		hit, _ := screen.Get(key)
		if !(0 <= key.X && key.X < width && 0 <= key.Y && key.Y < height) {
			continue
		}
		okey, _ := screenOf(view, hit.origin.X, hit.origin.Y, hit.origin.Z, width)
		var color RGB
		found := false
		if who, ok := owner[view].Get(okey); ok && who == hit.name {
			color, found = img.Get(Pt{X: imgX(view, okey.X, width), Y: okey.Y})
		}
		if !found {
			color, found = kinColor(owner[view], img, view, hit.name, okey, width)
		}
		if !found {
			color, found = imgs["front"].Get(Pt{X: hit.origin.X, Y: hit.origin.Y})
		}
		if !found {
			color = RGB{0, 0, 0}
		}
		out.Set(key, color)
	}
	return out
}

// kinColor は同じ向きでその部位が見せている画素のうち、近い物の色を借りる。
func kinColor(owned *pxlib.OMap[Pt, string], img *Cells, view, name string, okey Pt, width int) (RGB, bool) {
	sx0, y0 := okey.X, okey.Y
	for _, dy := range []int{0, -1, 1, -2, 2, -3, 3} {
		var row []int
		for _, key := range owned.Keys() {
			who, _ := owned.Get(key)
			if key.Y != y0+dy || who != name {
				continue
			}
			if _, ok := img.Get(Pt{X: imgX(view, key.X, width), Y: key.Y}); ok {
				row = append(row, key.X)
			}
		}
		if len(row) > 0 {
			sx := row[0]
			for _, v := range row[1:] {
				if absInt(v-sx0) < absInt(sx-sx0) {
					sx = v
				}
			}
			return img.Get(Pt{X: imgX(view, sx, width), Y: y0 + dy})
		}
	}
	return RGB{}, false
}

// groupsOf はつながった塊に分ける。輪郭の対角つなぎは切らない (8 近傍)。
func groupsOf(cells *Cells) [][]Pt {
	unseen := NewPySetFromKeys(cells.Keys(), hashPt)
	var groups [][]Pt
	for unseen.Len() > 0 {
		start, _ := unseen.Pop()
		todo := []Pt{start}
		var grp []Pt
		for len(todo) > 0 {
			p := todo[0]
			todo = todo[1:]
			grp = append(grp, p)
			for dx := -1; dx <= 1; dx++ {
				for dy := -1; dy <= 1; dy++ {
					q := Pt{X: p.X + dx, Y: p.Y + dy}
					if unseen.Contains(q) {
						unseen.Remove(q)
						todo = append(todo, q)
					}
				}
			}
		}
		groups = append(groups, grp)
	}
	sort.SliceStable(groups, func(a, b int) bool { return len(groups[a]) > len(groups[b]) })
	return groups
}

// Components はつながった塊の大きさを大きい順に返す。
func Components(cells *Cells) []int {
	var out []int
	for _, g := range groupsOf(cells) {
		out = append(out, len(g))
	}
	return out
}

type spriteEntry struct {
	anchorX, anchorY int
	frames           *pxlib.OMap[string, []string]
}

// RunCarve は carve の入口。root は実行したディレクトリ。
func RunCarve(out *strings.Builder, root string, args []string, rules *Rules) (int, error) {
	opts, err := parseArgs(args, map[string]bool{
		"id": true, "size": true, "colors": true, "reach": true, "profile": true,
	})
	if err != nil {
		return 2, err
	}
	if opts.image == "" {
		return 2, fmt.Errorf("三面図の PNG を渡してください")
	}
	id := opts.str("id", "carved")
	colors, err := opts.num("colors", rules.CarveDefaults.Colors)
	if err != nil {
		return 2, err
	}
	if path, ok := opts.flags["profile"]; ok {
		if err := applyProfile(&rules.Profile, path); err != nil {
			return 1, err
		}
	}
	reach, err := opts.num("reach", rules.Profile.Reach)
	if err != nil {
		return 2, err
	}
	size, err := parseSize(opts.str("size", rules.CarveDefaults.Size))
	if err != nil {
		return 2, err
	}

	img, err := OpenImage(opts.image)
	if err != nil {
		return 1, err
	}
	mask := BackdropMask(img, rules)
	spans := SpansOf(img, mask, rules)
	fmt.Fprintf(out, "切り分け %d 体\n", len(spans))
	names := []string{"front", "right", "back"}
	views := pxlib.NewOMap[string, *Cells]()
	for i := 0; i < len(names) && i < len(spans); i++ {
		box := BoundsOf(img, spans[i], mask, rules)
		views.Set(names[i], Resample(img, box, size, mask, rules))
	}
	views = Align(views, size, rules)
	views = ReduceColors(views, colors)
	for _, name := range views.Keys() {
		cells, _ := views.Get(name)
		var ys []int
		for _, p := range cells.Keys() {
			ys = append(ys, p.Y)
		}
		fmt.Fprintf(out, "  %-6s 接地 %d  立ち位置の中心 %s\n", name, maxOf(ys),
			strconv.FormatFloat(StanceCenter(cells, rules.Profile.FeetShare), 'f', 1, 64))
	}

	front, _ := views.Get("front")
	right, _ := views.Get("right")
	back, _ := views.Get("back")
	voxels := Carve(front, right, size)
	fmt.Fprintf(out, "彫り出した立体 %d ボクセル\n", voxels.Len())
	parts, marks := SplitParts(voxels, rules)
	parts, holder := Slim(parts, front, right, rules)
	total := 0
	for _, name := range parts.Keys() {
		cells, _ := parts.Get(name)
		total += cells.Len()
	}
	holderShown := holder
	if holderShown == "" {
		holderShown = "無し"
	}
	fmt.Fprintf(out, "奥行きを絞って %d ボクセル  持ち物は %s\n", total, holderShown)
	sortedNames := append([]string{}, parts.Keys()...)
	sort.Strings(sortedNames)
	var partLine []string
	for _, name := range sortedNames {
		cells, _ := parts.Get(name)
		partLine = append(partLine, fmt.Sprintf("%s:%d", name, cells.Len()))
	}
	fmt.Fprintf(out, "部位 %s\n", strings.Join(partLine, " "))

	imgs := map[string]*Cells{"front": front, "right": right, "back": back, "left": right}
	owner := FaceOwners(parts, size)
	rest := pxlib.NewOMap[string, *VoxMoved]()
	for _, name := range parts.Keys() {
		cells, _ := parts.Get(name)
		still := pxlib.NewOMap[Vox, Vox]()
		for _, v := range cells.Keys() {
			still.Set(v, v)
		}
		rest.Set(name, still)
	}
	idleShot := map[string]*Cells{}
	for _, view := range carveViews {
		idleShot[view] = Dress(rest, view, owner, imgs, size)
	}
	for _, name := range []string{"front", "right", "back"} {
		shot := idleShot[name]
		cells, _ := views.Get(name)
		same := 0
		for _, p := range cells.Keys() {
			c, _ := cells.Get(p)
			if got, ok := shot.Get(p); ok && got == c {
				same++
			}
		}
		gap := 0
		for _, p := range cells.Keys() {
			if !shot.Has(p) {
				gap++
			}
		}
		for _, p := range shot.Keys() {
			if !cells.Has(p) {
				gap++
			}
		}
		fmt.Fprintf(out, "  %-6s 投影の一致 %d/%d  ずれ %dpx\n", name, same, cells.Len(), gap)
	}
	mirror := pxlib.NewOMap[Pt, RGB]()
	for _, p := range idleShot["right"].Keys() {
		c, _ := idleShot["right"].Get(p)
		mirror.Set(Pt{X: size[0] - 1 - p.X, Y: p.Y}, c)
	}
	left := idleShot["left"]
	off, tint := 0, 0
	for _, p := range mirror.Keys() {
		c, _ := mirror.Get(p)
		if got, ok := left.Get(p); !ok {
			off++
		} else if got != c {
			tint++
		}
	}
	for _, p := range left.Keys() {
		if !mirror.Has(p) {
			off++
		}
	}
	fmt.Fprintf(out, "  %-6s 右の鏡映と 位置ずれ %dpx  色違い %dpx\n", "left", off, tint)

	outDir := filepath.Join(root, "gallery", id)
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return 1, err
	}
	frames := pxlib.NewOMap[frameKey, *Cells]()
	for _, m := range walkMotions {
		if frames.Has(frameKey{"front", m.Name}) {
			continue
		}
		moved := pxlib.NewOMap[string, *VoxMoved]()
		for _, name := range parts.Keys() {
			cells, _ := parts.Get(name)
			one := pxlib.NewOMap[Vox, Vox]()
			for _, v := range cells.Keys() {
				one.Set(v, v)
			}
			moved.Set(name, Swing(name, one, marks, m.Phase, m.Sink, reach, name != holder, rules))
		}
		for _, view := range carveViews {
			cells := Dress(moved, view, owner, imgs, size)
			if m.Phase != 0 {
				still := idleShot[view]
				if got, ok := frames.Get(frameKey{view, "idle"}); ok {
					still = got
				}
				groups := groupsOf(cells)
				if len(groups) > 0 {
					groups = groups[1:]
				}
				for _, chunk := range groups {
					touching := false
					for _, p := range chunk {
						if still.Has(p) {
							touching = true
							break
						}
					}
					if len(chunk) <= rules.Profile.CrumbLimit && !touching {
						for _, p := range chunk {
							cells.Delete(p)
						}
					}
				}
			}
			frames.Set(frameKey{view, m.Name}, cells)
			if err := SavePNG(filepath.Join(outDir, fmt.Sprintf("%s-%s.png", view, m.Name)),
				cells, size, 1, nil); err != nil {
				return 1, err
			}
		}
	}
	var poses []string
	for _, m := range walkMotions {
		if !contains(poses, m.Name) {
			poses = append(poses, m.Name)
		}
	}
	for _, view := range carveViews {
		var counts []string
		for _, p := range poses {
			cells, _ := frames.Get(frameKey{view, p})
			counts = append(counts, strconv.Itoa(len(Components(cells))))
		}
		idle, _ := frames.Get(frameKey{view, "idle"})
		walkL, _ := frames.Get(frameKey{view, "walk_l"})
		movedCount := 0
		for _, p := range idle.Keys() {
			if !walkL.Has(p) {
				movedCount++
			}
		}
		for _, p := range walkL.Keys() {
			if !idle.Has(p) {
				movedCount++
			}
		}
		fmt.Fprintf(out, "  %-6s 塊 [%s]  コマ間で動く画素 %d\n", view,
			strings.Join(counts, ", "), movedCount)
	}

	palette := pxlib.NewOMap[string, string]()
	legend := pxlib.NewOMap[string, string]()
	table := map[RGB]string{}
	chars := []rune(rules.LegendChars)
	every := NewCounter[RGB]()
	for _, k := range frames.Keys() {
		cells, _ := frames.Get(k)
		for _, p := range cells.Keys() {
			c, _ := cells.Get(p)
			every.Add(c, 1)
		}
	}
	ranked, _ := every.MostCommon()
	for index, color := range ranked {
		if index >= len(chars) {
			break
		}
		key := fmt.Sprintf("c%02d", index)
		palette.Set(key, fmt.Sprintf("#%02x%02x%02x", color[0], color[1], color[2]))
		legend.Set(string(chars[index]), key)
		table[color] = string(chars[index])
	}
	sprites := pxlib.NewOMap[string, *spriteEntry]()
	for _, view := range carveViews {
		made := pxlib.NewOMap[string, []string]()
		for _, pose := range poses {
			cells, _ := frames.Get(frameKey{view, pose})
			made.Set(pose, gridOf(cells, size, table))
		}
		sprites.Set(fmt.Sprintf("%s_%s", id, view),
			&spriteEntry{anchorX: size[0] / 2, anchorY: size[1] - 1, frames: made})
	}
	note := "3 面図から彫り出した立体を 3D で振り、4 方向へ描き直した。bin/carve.py の生成物"
	path := filepath.Join(root, "assets", "chars", id+".sprite.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return 1, err
	}
	if err := writeSpriteDoc(path, id, note, palette, legend, sprites); err != nil {
		return 1, err
	}

	for _, reel := range []struct {
		name  string
		order []string
	}{{"walk", []string{"idle", "walk_l", "idle", "walk_r"}}} {
		var strips []string
		for index, pose := range reel.order {
			pngPath := filepath.Join(outDir, fmt.Sprintf("_strip-%s%d.png", reel.name, index))
			rows := stripRows(frames, carveViews, pose, size)
			if err := pxlib.WritePNG(pngPath, pxlib.ImageOfRows(rows)); err != nil {
				return 1, err
			}
			strips = append(strips, pngPath)
		}
		gif, err := FromPNGs(strips, 1, rules.GifDelay)
		if err != nil {
			return 1, err
		}
		if err := os.WriteFile(filepath.Join(outDir, reel.name+".gif"), gif, 0o644); err != nil {
			return 1, err
		}
		for _, p := range strips {
			if err := os.Remove(p); err != nil {
				return 1, err
			}
		}
	}
	rel, _ := filepath.Rel(root, path)
	fmt.Fprintln(out, rel)
	rel, _ = filepath.Rel(root, outDir)
	fmt.Fprintln(out, rel)
	return 0, nil
}
