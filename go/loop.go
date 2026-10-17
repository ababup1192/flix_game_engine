package main

// loop — ループ GIF の継ぎ目を機械で確かめる。
// 見るのは 1 つだけ: 最終コマ → 先頭コマの差分画素率が、通常のコマ間から外れていないか。

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const (
	loopRatio    = 1.5
	loopAbsFloor = 0.005
)

var loopGameRoots = []string{"templates"}

var loopExcludedDirs = map[string]bool{
	".git": true, "build": true, "lib": true, ".devbox": true,
	"target": true, "node_modules": true, "testdata": true,
}

var frameNameRe = regexp.MustCompile(`^(\d+)\.png$`)

type loopFrame struct {
	w, h int
	px   []uint32
}

func loadFrame(path string) (*loopFrame, error) {
	im, err := pxlib.LoadPNG(path)
	if err != nil {
		return nil, err
	}
	px := make([]uint32, im.W*im.H)
	for i := range px {
		o := i * 4
		px[i] = uint32(im.Pix[o]) | uint32(im.Pix[o+1])<<8 |
			uint32(im.Pix[o+2])<<16 | uint32(im.Pix[o+3])<<24
	}
	return &loopFrame{im.W, im.H, px}, nil
}

func diffRate(a, b *loopFrame) float64 {
	if a.w != b.w || a.h != b.h || a.w*a.h == 0 {
		return 1.0
	}
	n := 0
	for i := range a.px {
		if a.px[i] != b.px[i] {
			n++
		}
	}
	return float64(n) / float64(a.w*a.h)
}

// seamVerdict は通常コマ間の差分率の列と継ぎ目差分率から、指摘文か "" を返す。
func seamVerdict(rates []float64, seam float64) string {
	if seam < loopAbsFloor {
		return ""
	}
	worst := rates[0]
	for _, r := range rates {
		if r > worst {
			worst = r
		}
	}
	ceiling := worst * loopRatio
	if seam <= ceiling {
		return ""
	}
	return fmt.Sprintf(
		"継ぎ目(最終→先頭)で画素の %.1f%% が変わる "+
			"(通常コマ間の最大 %.1f%% × %s = %.1f%% を超過) "+
			"— 繰り返した瞬間に絵が飛ぶ",
		seam*100, worst*100, formatRatio(loopRatio), ceiling*100)
}

// formatRatio は小数を余計な 0 を付けずに書く。
func formatRatio(v float64) string {
	return strconv.FormatFloat(v, 'g', -1, 64)
}

func frameFiles(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	type numbered struct {
		n int
		p string
	}
	var named []numbered
	for _, e := range entries {
		m := frameNameRe.FindStringSubmatch(e.Name())
		if m != nil {
			n, _ := strconv.Atoi(m[1])
			named = append(named, numbered{n, filepath.Join(dir, e.Name())})
		}
	}
	sort.Slice(named, func(i, j int) bool {
		if named[i].n != named[j].n {
			return named[i].n < named[j].n
		}
		return named[i].p < named[j].p
	})
	out := make([]string, len(named))
	for i, v := range named {
		out[i] = v.p
	}
	return out
}

func checkLoopDir(dir string) []string {
	files := frameFiles(dir)
	if len(files) < 3 {
		return nil
	}
	frames := make([]*loopFrame, len(files))
	for i, p := range files {
		f, err := loadFrame(p)
		if err != nil {
			return []string{"読めない PNG がある: " + err.Error()}
		}
		frames[i] = f
	}
	rates := make([]float64, 0, len(frames)-1)
	for i := 0; i+1 < len(frames); i++ {
		rates = append(rates, diffRate(frames[i], frames[i+1]))
	}
	note := seamVerdict(rates, diffRate(frames[len(frames)-1], frames[0]))
	if note == "" {
		return nil
	}
	return []string{note}
}

// discoverLoopDirs は templates/ 配下 (無ければ自分自身) の frames/*/ を探す。
func discoverLoopDirs(root string) []string {
	var bases []string
	for _, group := range loopGameRoots {
		groupDir := filepath.Join(root, group)
		entries, err := os.ReadDir(groupDir)
		if err != nil {
			continue
		}
		var names []string
		for _, e := range entries {
			if e.IsDir() {
				names = append(names, e.Name())
			}
		}
		sort.Strings(names)
		for _, n := range names {
			bases = append(bases, filepath.Join(groupDir, n))
		}
	}
	if len(bases) == 0 {
		bases = []string{root}
	}
	var found []string
	for _, base := range bases {
		walkFrames(base, &found)
	}
	return found
}

func walkFrames(dir string, found *[]string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	var subs []string
	for _, e := range entries {
		if e.IsDir() && !loopExcludedDirs[e.Name()] {
			subs = append(subs, e.Name())
		}
	}
	sort.Strings(subs)
	if filepath.Base(dir) == "frames" {
		for _, s := range subs {
			*found = append(*found, filepath.Join(dir, s))
		}
		return
	}
	for _, s := range subs {
		walkFrames(filepath.Join(dir, s), found)
	}
}

// runLoopSelfTest は --self-test の中身。この検査自身が当たり外れを正しく言うか確かめる。
func runLoopSelfTest(out *strings.Builder) int {
	var results []string
	add := func(name string, hit bool) {
		mark := "NG  "
		if hit {
			mark = "OK  "
		}
		results = append(results, mark+name)
	}
	add("静けさの床: 継ぎ目 0.4% は常に合格", seamVerdict([]float64{0.0, 0.0}, 0.004) == "")
	add("継ぎ目が跳ねると警告", seamVerdict([]float64{0.02, 0.03}, 0.10) != "")
	add("通常コマ間と同程度なら合格", seamVerdict([]float64{0.02, 0.03}, 0.04) == "")
	add("通常が全て 0 で継ぎ目だけ 1% は警告", seamVerdict([]float64{0.0, 0.0}, 0.01) != "")

	tmp, err := os.MkdirTemp("", "fge-loop")
	if err != nil {
		fmt.Fprintln(out, err)
		return 1
	}
	defer os.RemoveAll(tmp)

	write := func(dir string, i int, at func(x, y int) pxlib.RGBA) {
		grid := make([][]pxlib.RGBA, 4)
		for y := 0; y < 4; y++ {
			grid[y] = make([]pxlib.RGBA, 4)
			for x := 0; x < 4; x++ {
				grid[y][x] = at(x, y)
			}
		}
		_ = os.WriteFile(filepath.Join(dir, strconv.Itoa(i)+".png"), encodePNG(4, 4, grid), 0o644)
	}
	loopDir := filepath.Join(tmp, "loop")
	_ = os.Mkdir(loopDir, 0o755)
	for i := 0; i < 3; i++ {
		write(loopDir, i, func(x, y int) pxlib.RGBA { return pxlib.RGBA{255, 0, 0, 255} })
	}
	add("同一 3 コマのループは合格", len(checkLoopDir(loopDir)) == 0)

	// 1 コマにつき 1 列ずつ青へ流れ、先頭へ戻らない列 (ドリフト)。
	driftDir := filepath.Join(tmp, "drift")
	_ = os.Mkdir(driftDir, 0o755)
	for i := 0; i < 3; i++ {
		n := i
		write(driftDir, i, func(x, y int) pxlib.RGBA {
			if x < n {
				return pxlib.RGBA{0, 0, 255, 255}
			}
			return pxlib.RGBA{255, 0, 0, 255}
		})
	}
	add("先頭へ戻らないドリフトは警告", len(checkLoopDir(driftDir)) != 0)

	bad := 0
	for _, line := range results {
		fmt.Fprintln(out, line)
		if strings.HasPrefix(line, "NG") {
			bad++
		}
	}
	fmt.Fprintf(out, "\n%d/%d 件 OK\n", len(results)-bad, len(results))
	if bad > 0 {
		return 1
	}
	return 0
}

func runLoop(out *strings.Builder, root string, targets []string, strict bool) int {
	if len(targets) == 0 {
		targets = discoverLoopDirs(root)
	}
	total := 0
	for _, path := range targets {
		notes := checkLoopDir(path)
		if len(notes) == 0 {
			continue
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			rel = path
		}
		fmt.Fprintf(out, "\n%s\n", rel)
		for _, note := range notes {
			label := "注意"
			if strict {
				label = "NG"
			}
			fmt.Fprintf(out, "  %s: %s\n", label, note)
		}
		total += len(notes)
	}
	label := "注意"
	if strict {
		label = "NG"
	}
	fmt.Fprintf(out, "\n%d ディレクトリ / %s %d 件\n", len(targets), label, total)
	if strict && total > 0 {
		return 1
	}
	return 0
}
