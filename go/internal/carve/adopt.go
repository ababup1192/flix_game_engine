package carve

// 外から来た絵を取り込んで 4 方向 × 歩き 3 コマに仕立てる。
//
//	fge-go adopt 三面図.png --id mechanic

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

// Pt は 2 次元の位置。
type Pt struct{ X, Y int }

// Vox は 3 次元の位置。
type Vox struct{ X, Y, Z int }

// Cells は位置 → 色。
type Cells = pxlib.OMap[Pt, RGB]

// Mask は背景とみなした升目。
type Mask struct {
	seen   [][]bool
	coarse int
}

// LooksLight は市松の背景に使われがちな、明るくて彩度の無い色か。
func LooksLight(c RGBA, rules *Rules) bool {
	r, g, b, a := c[0], c[1], c[2], c[3]
	if a <= rules.Alpha {
		return true
	}
	hi, lo := maxOf([]int{r, g, b}), minOf([]int{r, g, b})
	return r > rules.Backdrop.LightMin && g > rules.Backdrop.LightMin &&
		b > rules.Backdrop.LightMin && hi-lo < rules.Backdrop.LightSpread
}

// Quantize は補間で散った色を丸める。
func Quantize(c RGB, step int) RGB {
	return RGB{(c[0]/step)*step + step/2, (c[1]/step)*step + step/2, (c[2]/step)*step + step/2}
}

// BackdropMask は背景を縁からの塗りつぶしで決める。
func BackdropMask(img *Image, rules *Rules) *Mask {
	coarse := rules.Backdrop.Coarse
	votes := NewCounter[RGB]()
	for x := 0; x < img.Width(); x += coarse {
		for _, y := range []int{0, img.Height() - 1} {
			c := img.At(x, y)
			votes.Add(Quantize(RGB{c[0], c[1], c[2]}, rules.QuantStep), 1)
		}
	}
	for y := 0; y < img.Height(); y += coarse {
		for _, x := range []int{0, img.Width() - 1} {
			c := img.At(x, y)
			votes.Add(Quantize(RGB{c[0], c[1], c[2]}, rules.QuantStep), 1)
		}
	}
	edgeTone, _, _ := votes.MostCommon1()
	edgeLight := LooksLight(RGBA{edgeTone[0], edgeTone[1], edgeTone[2], 255}, rules)
	isBackdrop := func(c RGBA) bool {
		if LooksLight(c, rules) {
			return true
		}
		if edgeLight {
			return false
		}
		for i := 0; i < 3; i++ {
			if absInt(c[i]-edgeTone[i]) > rules.Backdrop.EdgeTolerant {
				return false
			}
		}
		return true
	}

	wide := (img.Width() + coarse - 1) / coarse
	tall := (img.Height() + coarse - 1) / coarse
	light := make([][]bool, tall)
	for gy := 0; gy < tall; gy++ {
		y := minOf([]int{img.Height() - 1, gy * coarse})
		row := make([]bool, wide)
		for gx := 0; gx < wide; gx++ {
			row[gx] = isBackdrop(img.At(minOf([]int{img.Width() - 1, gx * coarse}), y))
		}
		light[gy] = row
	}
	seen := make([][]bool, tall)
	for i := range seen {
		seen[i] = make([]bool, wide)
	}
	var stack []Pt
	for gx := 0; gx < wide; gx++ {
		for _, gy := range []int{0, tall - 1} {
			if light[gy][gx] {
				stack = append(stack, Pt{gx, gy})
			}
		}
	}
	for gy := 0; gy < tall; gy++ {
		for _, gx := range []int{0, wide - 1} {
			if light[gy][gx] {
				stack = append(stack, Pt{gx, gy})
			}
		}
	}
	for len(stack) > 0 {
		p := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[p.Y][p.X] {
			continue
		}
		seen[p.Y][p.X] = true
		for _, q := range []Pt{{p.X - 1, p.Y}, {p.X + 1, p.Y}, {p.X, p.Y - 1}, {p.X, p.Y + 1}} {
			if 0 <= q.X && q.X < wide && 0 <= q.Y && q.Y < tall && !seen[q.Y][q.X] && light[q.Y][q.X] {
				stack = append(stack, q)
			}
		}
	}
	return &Mask{seen: seen, coarse: coarse}
}

// SolidAt は絵の側の色。背景なら取れない。
func SolidAt(img *Image, x, y int, mask *Mask, rules *Rules) (RGB, bool) {
	c := img.At(x, y)
	if c[3] <= rules.Alpha {
		return RGB{}, false
	}
	if mask != nil {
		gy := minOf([]int{len(mask.seen) - 1, y / mask.coarse})
		gx := minOf([]int{len(mask.seen[0]) - 1, x / mask.coarse})
		if mask.seen[gy][gx] {
			return RGB{}, false
		}
		return RGB{c[0], c[1], c[2]}, true
	}
	if LooksLight(c, rules) {
		return RGB{}, false
	}
	return RGB{c[0], c[1], c[2]}, true
}

// SpansOf は絵のある縦の範囲を探す。3 面図をここで 1 体ずつに切り分ける。
func SpansOf(img *Image, mask *Mask, rules *Rules) [][2]int {
	step, least := rules.Spans.Step, rules.Spans.Least
	var cols []int
	for x := 0; x < img.Width(); x++ {
		for y := 0; y < img.Height(); y += step {
			if _, ok := SolidAt(img, x, y, mask, rules); ok {
				cols = append(cols, x)
				break
			}
		}
	}
	if len(cols) == 0 {
		return nil
	}
	var spans [][2]int
	start, prev := cols[0], cols[0]
	for _, x := range cols[1:] {
		if x != prev+1 {
			spans = append(spans, [2]int{start, prev})
			start = x
		}
		prev = x
	}
	spans = append(spans, [2]int{start, prev})
	var out [][2]int
	for _, s := range spans {
		if s[1]-s[0] >= least {
			out = append(out, s)
		}
	}
	return out
}

// BoundsOf は 1 体の外接枠。
func BoundsOf(img *Image, span [2]int, mask *Mask, rules *Rules) [4]int {
	x0, x1 := span[0], span[1]
	var ys []int
	for y := 0; y < img.Height(); y++ {
		for x := x0; x <= x1; x += rules.BoundsStep {
			if _, ok := SolidAt(img, x, y, mask, rules); ok {
				ys = append(ys, y)
				break
			}
		}
	}
	return [4]int{x0, x1, minOf(ys), maxOf(ys)}
}

// points は low..high から最大 most 点を等間隔で選ぶ。
func points(low, high, most int) []int {
	span := high - low
	if span <= most {
		out := make([]int, 0, span)
		for v := low; v < high; v++ {
			out = append(out, v)
		}
		return out
	}
	out := make([]int, 0, most)
	for i := 0; i < most; i++ {
		out = append(out, low+span*i/most)
	}
	return out
}

type optRGB struct {
	c  RGB
	ok bool
}

// Resample は外接枠を、決めた大きさの升へ面で落とす。各升は丸めた色の多数決。
func Resample(img *Image, box [4]int, size [2]int, mask *Mask, rules *Rules) *Cells {
	x0, x1, y0, y1 := box[0], box[1], box[2], box[3]
	width, height := size[0], size[1]
	step := rules.QuantStep
	most := rules.SamplePoints
	out := pxlib.NewOMap[Pt, RGB]()
	cellBox := func(gx, gy int) (int, int, int, int) {
		sx0 := x0 + (x1-x0+1)*gx/width
		sx1 := maxOf([]int{sx0 + 1, x0 + (x1-x0+1)*(gx+1)/width})
		sy0 := y0 + (y1-y0+1)*gy/height
		sy1 := maxOf([]int{sy0 + 1, y0 + (y1-y0+1)*(gy+1)/height})
		return sx0, sx1, sy0, sy1
	}
	for gy := 0; gy < height; gy++ {
		for gx := 0; gx < width; gx++ {
			sx0, sx1, sy0, sy1 := cellBox(gx, gy)
			xs := points(sx0, sx1, most)
			ys := points(sy0, sy1, most)
			seen := NewCounter[optRGB]()
			for _, y := range ys {
				for _, x := range xs {
					c, ok := SolidAt(img, x, y, mask, rules)
					if ok {
						seen.Add(optRGB{Quantize(c, step), true}, 1)
					} else {
						seen.Add(optRGB{ok: false}, 1)
					}
				}
			}
			color, _, _ := seen.MostCommon1()
			if color.ok {
				out.Set(Pt{gx, gy}, color.c)
			}
		}
	}
	patch := pxlib.NewOMap[Pt, RGB]()
	for gy := 0; gy < height; gy++ {
		for gx := 0; gx < width; gx++ {
			if out.Has(Pt{gx, gy}) {
				continue
			}
			pinched := (out.Has(Pt{gx, gy - 1}) && out.Has(Pt{gx, gy + 1})) ||
				(out.Has(Pt{gx - 1, gy}) && out.Has(Pt{gx + 1, gy}))
			if !pinched {
				continue
			}
			sx0, sx1, sy0, sy1 := cellBox(gx, gy)
			dark := NewCounter[RGB]()
			total, darkTotal := 0, 0
			for _, y := range points(sy0, sy1, most) {
				for _, x := range points(sx0, sx1, most) {
					c := img.At(x, y)
					if c[3] > rules.Alpha {
						total++
						if maxOf([]int{c[0], c[1], c[2]}) < rules.DarkPatch.MaxLevel {
							dark.Add(Quantize(RGB{c[0], c[1], c[2]}, step), 1)
							darkTotal++
						}
					}
				}
			}
			if total != 0 && float64(darkTotal) >= float64(total)*rules.DarkPatch.Share {
				c, _, _ := dark.MostCommon1()
				patch.Set(Pt{gx, gy}, c)
			}
		}
	}
	for _, k := range patch.Keys() {
		v, _ := patch.Get(k)
		out.Set(k, v)
	}
	return out
}

// ReduceColors は色数を上限まで落とす。多い色と、他から遠い色の両方を残す。
func ReduceColors(pieces *pxlib.OMap[string, *Cells], limit int) *pxlib.OMap[string, *Cells] {
	counts := NewCounter[RGB]()
	for _, name := range pieces.Keys() {
		cells, _ := pieces.Get(name)
		for _, k := range cells.Keys() {
			c, _ := cells.Get(k)
			counts.Add(c, 1)
		}
	}
	if counts.Len() <= limit {
		return pieces
	}
	first, _, _ := counts.MostCommon1()
	keep := []RGB{first}
	var rest []RGB
	for _, c := range counts.keys {
		if c != first {
			rest = append(rest, c)
		}
	}
	dist := func(a, b RGB) int {
		return (a[0]-b[0])*(a[0]-b[0]) + (a[1]-b[1])*(a[1]-b[1]) + (a[2]-b[2])*(a[2]-b[2])
	}
	for len(keep) < limit && len(rest) > 0 {
		bestAt, score := -1, -1.0
		for i, color := range rest {
			far := dist(color, keep[0])
			for _, k := range keep[1:] {
				if d := dist(color, k); d < far {
					far = d
				}
			}
			value := float64(counts.Get(color)) * math.Sqrt(float64(far))
			if value > score {
				score, bestAt = value, i
			}
		}
		keep = append(keep, rest[bestAt])
		rest = append(rest[:bestAt], rest[bestAt+1:]...)
	}
	table := map[RGB]RGB{}
	for _, color := range counts.keys {
		near, best := keep[0], dist(color, keep[0])
		inKeep := false
		for _, k := range keep {
			if k == color {
				inKeep = true
				break
			}
		}
		if inKeep {
			table[color] = color
			continue
		}
		for _, k := range keep[1:] {
			if d := dist(color, k); d < best {
				best, near = d, k
			}
		}
		table[color] = near
	}
	out := pxlib.NewOMap[string, *Cells]()
	for _, name := range pieces.Keys() {
		cells, _ := pieces.Get(name)
		made := pxlib.NewOMap[Pt, RGB]()
		for _, k := range cells.Keys() {
			c, _ := cells.Get(k)
			made.Set(k, table[c])
		}
		out.Set(name, made)
	}
	return out
}

// Place は足元を下辺に、左右は絵の中心に合わせて枠へ収める。
func Place(cells *Cells, size [2]int, rules *Rules) *Cells {
	width, height := size[0], size[1]
	var xs, ys []int
	for _, p := range cells.Keys() {
		xs = append(xs, p.X)
		ys = append(ys, p.Y)
	}
	dx := width/2 - (minOf(xs)+maxOf(xs)+1)/2
	dy := height - rules.Adopt.BottomGap - maxOf(ys)
	out := pxlib.NewOMap[Pt, RGB]()
	for _, p := range cells.Keys() {
		c, _ := cells.Get(p)
		q := Pt{p.X + dx, p.Y + dy}
		if 0 <= q.X && q.X < width && 0 <= q.Y && q.Y < height {
			out.Set(q, c)
		}
	}
	return out
}

// LegBand は脚の区画を探す。下の方にあり・中央で割れていて・その割れ目が続いている行。
func LegBand(cells *Cells, size [2]int, rules *Rules) []int {
	width := size[0]
	var ys []int
	for _, p := range cells.Keys() {
		ys = append(ys, p.Y)
	}
	top, bottom := minOf(ys), maxOf(ys)
	floor := top + int(float64(bottom-top)*rules.Adopt.LegFloorShare)
	center := float64(width) / 2
	rows := map[int][]int{}
	for _, p := range cells.Keys() {
		rows[p.Y] = append(rows[p.Y], p.X)
	}
	var band []int
	for y := bottom; y >= floor; y-- {
		xs := append([]int{}, rows[y]...)
		sort.Ints(xs)
		var near []int
		for _, x := range xs {
			if math.Abs(float64(x)-center) <= float64(width)*rules.Adopt.LegNearShare {
				near = append(near, x)
			}
		}
		holes := 0
		for i := 0; i+1 < len(near); i++ {
			if near[i+1]-near[i] > 1 {
				holes++
			}
		}
		if holes == 0 {
			if len(band) > 0 {
				break
			}
			continue
		}
		band = append(band, y)
	}
	sort.Ints(band)
	return band
}

// ShearLegs は脚を付け根から足先へ向かって少しずつずらす。
func ShearLegs(cells *Cells, band []int, size [2]int, phase, swing, dip int, rules *Rules) *Cells {
	out := pxlib.NewOMap[Pt, RGB]()
	if len(band) == 0 {
		for _, p := range cells.Keys() {
			c, _ := cells.Get(p)
			if p.Y+dip < size[1] {
				out.Set(Pt{p.X, p.Y + dip}, c)
			}
		}
		return out
	}
	width := size[0]
	center := float64(width) / 2
	top, bottom := band[0], band[len(band)-1]
	span := maxOf([]int{1, bottom - top})
	for _, p := range cells.Keys() {
		c, _ := cells.Get(p)
		var q Pt
		if phase != 0 && p.Y >= top &&
			math.Abs(float64(p.X)-center) <= float64(width)*rules.Adopt.ShearNearShare {
			deep := float64(p.Y-top) / float64(span)
			side := -1
			if float64(p.X) >= center {
				side = 1
			}
			shift := int(math.RoundToEven(float64(swing)*deep)) * phase * side
			lift := 0
			if side*phase < 0 && deep > rules.Adopt.ShearLiftAt {
				lift = 1
			}
			q = Pt{p.X + shift, p.Y + dip - lift}
		} else {
			q = Pt{p.X, p.Y + dip}
		}
		if 0 <= q.X && q.X < size[0] && 0 <= q.Y && q.Y < size[1] {
			out.Set(q, c)
		}
	}
	return out
}

// walkMotions は歩きのコマ。位相 0 が立ち。±1 で左右の脚が入れ替わる。
var walkMotions = []struct {
	Name  string
	Phase int
	Sink  int
}{{"walk_l", -1, 1}, {"idle", 0, 0}, {"walk_r", 1, 1}}

// MotionFrames は動きの表からコマを作る。元の絵の画素は描き換えない。
func MotionFrames(cells *Cells, size [2]int, swing, dip int, rules *Rules) *pxlib.OMap[string, *Cells] {
	band := LegBand(cells, size, rules)
	made := pxlib.NewOMap[string, *Cells]()
	for _, m := range walkMotions {
		frame := ShearLegs(cells, band, size, m.Phase, swing, m.Sink*dip, rules)
		if len(ComponentsAdopt(frame)) > 1 {
			frame = ShearLegs(cells, band, size, m.Phase, maxOf([]int{1, swing - 1}), m.Sink*dip, rules)
		}
		made.Set(m.Name, frame)
	}
	return made
}

// ComponentsAdopt は 4 近傍のつながりの大きさを大きい順に返す。
func ComponentsAdopt(cells *Cells) []int {
	unseen := NewPySetFromKeys(cells.Keys(), hashPt)
	var sizes []int
	for unseen.Len() > 0 {
		start, _ := unseen.Pop()
		todo := []Pt{start}
		size := 0
		for len(todo) > 0 {
			p := todo[len(todo)-1]
			todo = todo[:len(todo)-1]
			size++
			for _, q := range []Pt{{p.X - 1, p.Y}, {p.X + 1, p.Y}, {p.X, p.Y - 1}, {p.X, p.Y + 1}} {
				if unseen.Contains(q) {
					unseen.Remove(q)
					todo = append(todo, q)
				}
			}
		}
		sizes = append(sizes, size)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(sizes)))
	return sizes
}

// Check は 1 枚の検査。数値で出す。
func Check(cells *Cells, size [2]int) ([]string, []int) {
	var xs, ys []int
	colors := NewCounter[RGB]()
	for _, p := range cells.Keys() {
		xs = append(xs, p.X)
		ys = append(ys, p.Y)
		c, _ := cells.Get(p)
		colors.Add(c, 1)
	}
	holes := 0
	for _, p := range cells.Keys() {
		near := 0
		for _, q := range []Pt{{p.X + 1, p.Y}, {p.X - 1, p.Y}, {p.X, p.Y + 1}, {p.X, p.Y - 1}} {
			if cells.Has(q) {
				near++
			}
		}
		if near <= 1 {
			holes++
		}
	}
	return []string{"幅", "高さ", "接地", "色数", "浮き画素", "画素"},
		[]int{maxOf(xs) - minOf(xs) + 1, maxOf(ys) - minOf(ys) + 1,
			size[1] - 1 - maxOf(ys), colors.Len(), holes, cells.Len()}
}

// SavePNG は 1 枚書き出す。
func SavePNG(path string, cells *Cells, size [2]int, scale int, background *RGBA) error {
	width, height := size[0], size[1]
	var rows [][]RGBA
	for y := 0; y < height; y++ {
		var line []RGBA
		for x := 0; x < width; x++ {
			value := RGBA{0, 0, 0, 0}
			if background != nil {
				value = *background
			}
			if c, ok := cells.Get(Pt{x, y}); ok {
				value = RGBA{c[0], c[1], c[2], 255}
			}
			for i := 0; i < scale; i++ {
				line = append(line, value)
			}
		}
		for i := 0; i < scale; i++ {
			rows = append(rows, line)
		}
	}
	return os.WriteFile(path, PNGOf(width*scale, height*scale, rows), 0o644)
}

func minOf(v []int) int {
	out := v[0]
	for _, x := range v[1:] {
		if x < out {
			out = x
		}
	}
	return out
}

func maxOf(v []int) int {
	out := v[0]
	for _, x := range v[1:] {
		if x > out {
			out = x
		}
	}
	return out
}

// parseSize は "32x48" を読む。
func parseSize(s string) ([2]int, error) {
	parts := strings.Split(strings.ToLower(s), "x")
	if len(parts) != 2 {
		return [2]int{}, fmt.Errorf("大きさは 32x48 の形で書いてください: %s", s)
	}
	w, err := strconv.Atoi(parts[0])
	if err != nil {
		return [2]int{}, err
	}
	h, err := strconv.Atoi(parts[1])
	if err != nil {
		return [2]int{}, err
	}
	return [2]int{w, h}, nil
}

// RunAdopt は adopt の入口。root は assets / gallery を置く根。
func RunAdopt(out *strings.Builder, root string, args []string, rules *Rules) (int, error) {
	opts, err := parseArgs(args, map[string]bool{
		"id": true, "size": true, "order": true, "swing": true, "colors": true,
	})
	if err != nil {
		return 2, err
	}
	if opts.image == "" {
		return 2, fmt.Errorf("三面図の PNG を渡してください")
	}
	id := opts.str("id", "adopted")
	order := strings.Split(opts.str("order", rules.AdoptDefaults.Order), ",")
	swing, err := opts.num("swing", rules.AdoptDefaults.Swing)
	if err != nil {
		return 2, err
	}
	colors, err := opts.num("colors", rules.AdoptDefaults.Colors)
	if err != nil {
		return 2, err
	}
	size, err := parseSize(opts.str("size", rules.AdoptDefaults.Size))
	if err != nil {
		return 2, err
	}

	img, err := OpenImage(opts.image)
	if err != nil {
		return 1, err
	}
	mask := BackdropMask(img, rules)
	spans := SpansOf(img, mask, rules)
	var shown []string
	for _, s := range spans {
		shown = append(shown, fmt.Sprintf("%d..%d", s[0], s[1]))
	}
	fmt.Fprintf(out, "切り分け %d 体: %s\n", len(spans), strings.Join(shown, " "))
	if len(spans) != len(order) {
		fmt.Fprintf(out, "警告: 向きの指定は %d 個だが、絵は %d 体ある\n", len(order), len(spans))
	}
	pieces := pxlib.NewOMap[string, *Cells]()
	for i := 0; i < len(order) && i < len(spans); i++ {
		box := BoundsOf(img, spans[i], mask, rules)
		fmt.Fprintf(out, "  %-6s 元の外接枠 %d x %d px\n", order[i],
			box[1]-box[0]+1, box[3]-box[2]+1)
		pieces.Set(order[i], Resample(img, box, size, mask, rules))
	}
	if pieces.Has("right") && !pieces.Has("left") {
		source, _ := pieces.Get("right")
		var xs []int
		for _, p := range source.Keys() {
			xs = append(xs, p.X)
		}
		wide := maxOf(xs)
		mirror := pxlib.NewOMap[Pt, RGB]()
		for _, p := range source.Keys() {
			c, _ := source.Get(p)
			mirror.Set(Pt{wide - p.X, p.Y}, c)
		}
		pieces.Set("left", mirror)
		fmt.Fprintln(out, "左向きは右向きを反転して作った")
	}
	pieces = ReduceColors(pieces, colors)
	fmt.Fprintf(out, "枠 %d x %d  色 %d まで\n", size[0], size[1], colors)

	outDir := filepath.Join(root, "gallery", id)
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return 1, err
	}
	frames := pxlib.NewOMap[frameKey, *Cells]()
	for _, view := range pieces.Keys() {
		cells, _ := pieces.Get(view)
		stand := Place(cells, size, rules)
		made := MotionFrames(stand, size, swing, rules.AdoptDefaults.Dip, rules)
		for _, pose := range made.Keys() {
			frame, _ := made.Get(pose)
			frames.Set(frameKey{view, pose}, frame)
			if err := SavePNG(filepath.Join(outDir, fmt.Sprintf("%s-%s.png", view, pose)),
				frame, size, 1, nil); err != nil {
				return 1, err
			}
		}
		names, values := Check(stand, size)
		var parts []string
		for i, n := range names {
			parts = append(parts, fmt.Sprintf("%s %d", n, values[i]))
		}
		fmt.Fprintf(out, "  %-6s %s\n", view, strings.Join(parts, "  "))
	}

	every := NewCounter[RGB]()
	for _, k := range frames.Keys() {
		cells, _ := frames.Get(k)
		for _, p := range cells.Keys() {
			c, _ := cells.Get(p)
			every.Add(c, 1)
		}
	}
	palette := pxlib.NewOMap[string, string]()
	legend := pxlib.NewOMap[string, string]()
	paletteNames := map[RGB]string{}
	chars := []rune(rules.LegendChars)
	ranked, _ := every.MostCommon()
	for index, color := range ranked {
		if index >= len(chars) {
			break
		}
		key := fmt.Sprintf("c%02d", index)
		palette.Set(key, fmt.Sprintf("#%02x%02x%02x", color[0], color[1], color[2]))
		legend.Set(string(chars[index]), key)
		paletteNames[color] = string(chars[index])
	}
	fmt.Fprintf(out, "色票 %d 色 (4 方向ぶんを 1 枚に統合)\n", palette.Len())

	sprites := pxlib.NewOMap[string, *spriteEntry]()
	for _, view := range pieces.Keys() {
		made := pxlib.NewOMap[string, []string]()
		for _, pose := range []string{"walk_l", "idle", "walk_r"} {
			cells, _ := frames.Get(frameKey{view, pose})
			made.Set(pose, gridOf(cells, size, paletteNames))
		}
		sprites.Set(fmt.Sprintf("%s_%s", id, view),
			&spriteEntry{anchorX: size[0] / 2, anchorY: size[1] - 1, frames: made})
	}
	note := fmt.Sprintf("%s を取り込み。歩きは脚をずらして生成。元の画素は描き換えていない",
		filepath.Base(opts.image))
	path := filepath.Join(root, "assets", "chars", id+".sprite.json")
	if err := writeSpriteDoc(path, id, note, palette, legend, sprites); err != nil {
		return 1, err
	}

	var viewOrder []string
	for _, v := range []string{"front", "right", "back", "left"} {
		if pieces.Has(v) {
			viewOrder = append(viewOrder, v)
		}
	}
	for _, k := range rules.Adopt.Scales {
		rowsOut := make([][]RGBA, size[1]*k)
		for y := range rowsOut {
			row := make([]RGBA, size[0]*len(viewOrder)*k)
			for x := range row {
				row[x] = rules.Adopt.Background
			}
			rowsOut[y] = row
		}
		for index, view := range viewOrder {
			cells, _ := frames.Get(frameKey{view, "idle"})
			for _, p := range cells.Keys() {
				c, _ := cells.Get(p)
				for dy := 0; dy < k; dy++ {
					for dx := 0; dx < k; dx++ {
						rowsOut[p.Y*k+dy][(index*size[0]+p.X)*k+dx] = RGBA{c[0], c[1], c[2], 255}
					}
				}
			}
		}
		png := PNGOf(size[0]*len(viewOrder)*k, size[1]*k, rowsOut)
		if err := os.WriteFile(filepath.Join(outDir, fmt.Sprintf("_4方向-%dx.png", k)), png, 0o644); err != nil {
			return 1, err
		}
	}

	var strips []string
	for index, pose := range []string{"idle", "walk_l", "idle", "walk_r"} {
		pathPNG := filepath.Join(outDir, fmt.Sprintf("_strip-%d.png", index))
		rowsOut := stripRows(frames, viewOrder, pose, size)
		if err := os.WriteFile(pathPNG,
			PNGOf(size[0]*len(viewOrder), size[1], rowsOut), 0o644); err != nil {
			return 1, err
		}
		strips = append(strips, pathPNG)
	}
	gif, err := FromPNGs(strips, 1, rules.GifDelay)
	if err != nil {
		return 1, err
	}
	if err := os.WriteFile(filepath.Join(outDir, "walk.gif"), gif, 0o644); err != nil {
		return 1, err
	}
	for _, p := range strips {
		if err := os.Remove(p); err != nil {
			return 1, err
		}
	}

	rel, _ := filepath.Rel(root, path)
	fmt.Fprintln(out, rel)
	rel, _ = filepath.Rel(root, outDir)
	fmt.Fprintln(out, rel)
	return 0, nil
}

type frameKey struct {
	view, pose string
}

func stripRows(frames *pxlib.OMap[frameKey, *Cells], viewOrder []string, pose string, size [2]int) [][]RGBA {
	var rowsOut [][]RGBA
	for y := 0; y < size[1]; y++ {
		var line []RGBA
		for _, view := range viewOrder {
			cells, _ := frames.Get(frameKey{view, pose})
			for x := 0; x < size[0]; x++ {
				if c, ok := cells.Get(Pt{x, y}); ok {
					line = append(line, RGBA{c[0], c[1], c[2], 255})
				} else {
					line = append(line, RGBA{0, 0, 0, 0})
				}
			}
		}
		rowsOut = append(rowsOut, line)
	}
	return rowsOut
}

func gridOf(cells *Cells, size [2]int, table map[RGB]string) []string {
	var rows []string
	for y := 0; y < size[1]; y++ {
		var line strings.Builder
		for x := 0; x < size[0]; x++ {
			ch := "."
			if c, ok := cells.Get(Pt{x, y}); ok {
				if s, ok := table[c]; ok {
					ch = s
				}
			}
			line.WriteString(ch)
		}
		rows = append(rows, line.String())
	}
	return rows
}
