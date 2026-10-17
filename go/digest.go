package main

// digest — 絵の変化を、画像を開かずに数値で掴むダイジェスト。

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// maxDetail は 1 画面に収める不一致の上限。
const maxDetail = 12

type colorStats struct {
	counts map[uint32]int
	luma   float64
	l3     [3]float64
}

func computeColorStats(im *pxlib.Image) colorStats {
	counts := make(map[uint32]int)
	luma := 0
	var dark, mid, light int
	for i := 0; i < im.W*im.H; i++ {
		o := i * 4
		r, g, b := int(im.Pix[o]), int(im.Pix[o+1]), int(im.Pix[o+2])
		counts[uint32(r)<<16|uint32(g)<<8|uint32(b)]++
		v := 299*r + 587*g + 114*b
		luma += v
		switch {
		case v < 85000:
			dark++
		case v < 171000:
			mid++
		default:
			light++
		}
	}
	total := float64(im.W * im.H)
	return colorStats{
		counts: counts,
		luma:   float64(luma) / (1000.0 * total),
		l3: [3]float64{
			100.0 * float64(dark) / total,
			100.0 * float64(mid) / total,
			100.0 * float64(light) / total,
		},
	}
}

func hexColor(c uint32) string {
	return fmt.Sprintf("#%02x%02x%02x", c>>16&255, c>>8&255, c&255)
}

// digestPair は不一致 2 枚の要約行と差分画素率を返す。
func digestPair(oldPath, newPath string) ([]string, float64, error) {
	oldIm, err := pxlib.LoadPNG(oldPath)
	if err != nil {
		return nil, 0, err
	}
	newIm, err := pxlib.LoadPNG(newPath)
	if err != nil {
		return nil, 0, err
	}
	var lines []string
	if oldIm.W != newIm.W || oldIm.H != newIm.H {
		lines = append(lines, fmt.Sprintf(
			"寸法が変わった: %dx%d -> %dx%d (重なる範囲だけ比較)",
			oldIm.W, oldIm.H, newIm.W, newIm.H))
	}
	w, h := min(oldIm.W, newIm.W), min(oldIm.H, newIm.H)

	diff := 0
	minX, minY, maxX, maxY := w, h, -1, -1
	var blocks [3][3]int
	for y := 0; y < h; y++ {
		orow, nrow := oldIm.Row(y), newIm.Row(y)
		if bytes.Equal(orow[:w*4], nrow[:w*4]) {
			continue
		}
		by := min(y*3/h, 2)
		for x := 0; x < w; x++ {
			if !bytes.Equal(orow[x*4:x*4+4], nrow[x*4:x*4+4]) {
				diff++
				blocks[by][min(x*3/w, 2)]++
				if x < minX {
					minX = x
				}
				if x > maxX {
					maxX = x
				}
				if y < minY {
					minY = y
				}
				if y > maxY {
					maxY = y
				}
			}
		}
	}
	total := w * h
	rate := 0.0
	if total != 0 {
		rate = 100.0 * float64(diff) / float64(total)
	}

	if diff == 0 {
		lines = append(lines, "重なる範囲の画素は同一 (差はメタ情報か寸法だけ)")
	} else {
		lines = append(lines, fmt.Sprintf(
			"差分画素 %.1f%% (%d/%dpx)  範囲 x=%d y=%d w=%d h=%d",
			rate, diff, total, minX, minY, maxX-minX+1, maxY-minY+1))
		type rank struct {
			n    int
			name string
		}
		ranked := make([]rank, 0, 9)
		for by := 0; by < 3; by++ {
			for bx := 0; bx < 3; bx++ {
				ranked = append(ranked, rank{blocks[by][bx], BlockNames[by][bx]})
			}
		}
		sort.Slice(ranked, func(i, j int) bool {
			if ranked[i].n != ranked[j].n {
				return ranked[i].n > ranked[j].n
			}
			return ranked[i].name > ranked[j].name
		})
		var top []string
		for _, r := range ranked {
			if len(top) >= 3 {
				break
			}
			if r.n > 0 && float64(r.n) >= float64(ranked[0].n)*0.5 {
				top = append(top, r.name)
			}
		}
		share := 100.0 * float64(ranked[0].n) / float64(diff)
		lines = append(lines, fmt.Sprintf("差の集中: %s (最大ブロックに %.0f%%)",
			strings.Join(top, "/"), share))
	}

	oldCS := computeColorStats(oldIm)
	newCS := computeColorStats(newIm)
	deltaColors := len(newCS.counts) - len(oldCS.counts)
	colorLine := fmt.Sprintf("色数 %d -> %d", len(oldCS.counts), len(newCS.counts))
	if deltaColors >= 8 || deltaColors <= -8 {
		type cn struct {
			n   int
			rgb uint32
		}
		var added []cn
		for rgb, n := range newCS.counts {
			if _, ok := oldCS.counts[rgb]; !ok {
				added = append(added, cn{n, rgb})
			}
		}
		sort.Slice(added, func(i, j int) bool {
			if added[i].n != added[j].n {
				return added[i].n > added[j].n
			}
			return added[i].rgb > added[j].rgb
		})
		if len(added) > 3 {
			added = added[:3]
		}
		if len(added) > 0 {
			parts := make([]string, len(added))
			for i, a := range added {
				parts[i] = hexColor(a.rgb)
			}
			colorLine += "  新顔の代表色: " + strings.Join(parts, " ")
		}
	}
	deltaLuma := newCS.luma - oldCS.luma
	switch {
	case deltaLuma < 0.5 && deltaLuma > -0.5:
		colorLine += fmt.Sprintf("  平均輝度 ほぼ同じ (%.1f)", oldCS.luma)
	case deltaLuma > 0:
		colorLine += fmt.Sprintf("  明るくなった (%.1f -> %.1f)", oldCS.luma, newCS.luma)
	default:
		colorLine += fmt.Sprintf("  暗くなった (%.1f -> %.1f)", oldCS.luma, newCS.luma)
	}
	lines = append(lines, colorLine)
	maxL3 := 0.0
	for i := 0; i < 3; i++ {
		d := oldCS.l3[i] - newCS.l3[i]
		if d < 0 {
			d = -d
		}
		if d > maxL3 {
			maxL3 = d
		}
	}
	if maxL3 >= 2.0 {
		lines = append(lines, fmt.Sprintf(
			"明度 3 段 暗/中/明 %.0f/%.0f/%.0f -> %.0f/%.0f/%.0f",
			oldCS.l3[0], oldCS.l3[1], oldCS.l3[2],
			newCS.l3[0], newCS.l3[1], newCS.l3[2]))
	}
	return lines, rate, nil
}

func listImages(root string) ([]string, map[string]string) {
	found := map[string]string{}
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		low := strings.ToLower(d.Name())
		if strings.HasSuffix(low, ".png") || strings.HasSuffix(low, ".gif") {
			rel, e := filepath.Rel(root, p)
			if e == nil {
				found[filepath.ToSlash(rel)] = p
			}
		}
		return nil
	})
	keys := make([]string, 0, len(found))
	for k := range found {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys, found
}

func oldHashes(oldRoot string) map[string]string {
	data, err := os.ReadFile(filepath.Join(oldRoot, "SHA256SUMS.txt"))
	if err != nil {
		return nil
	}
	table := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		rest := strings.TrimLeft(line[strings.Index(line, f[0])+len(f[0]):], " \t\n\r\f\v")
		table[strings.TrimSpace(rest)] = f[0]
	}
	return table
}

func sameBytes(a, b string) bool {
	x, e1 := os.ReadFile(a)
	y, e2 := os.ReadFile(b)
	return e1 == nil && e2 == nil && bytes.Equal(x, y)
}

func compareFiles(out *strings.Builder, oldPath, newPath string) int {
	if sameBytes(oldPath, newPath) {
		fmt.Fprintln(out, "一致 (バイト同一)")
		return 0
	}
	fmt.Fprintf(out, "%s -> %s: 不一致\n",
		filepath.Base(oldPath), filepath.Base(newPath))
	lines, _, err := digestPair(oldPath, newPath)
	if err != nil {
		fmt.Fprintf(out, "  ダイジェスト不可: %s\n", err)
		return 1
	}
	for _, line := range lines {
		fmt.Fprintf(out, "  %s\n", line)
	}
	return 1
}

func compareDirs(out *strings.Builder, oldRoot, newRoot string, names []string) int {
	oldKeys, oldFiles := listImages(oldRoot)
	newKeys, newFiles := listImages(newRoot)
	if len(names) > 0 {
		wanted := map[string]bool{}
		for _, n := range names {
			wanted[n] = true
		}
		keep := func(rel string) bool {
			return wanted[rel] || wanted[filepath.Base(rel)]
		}
		oldKeys, oldFiles = filterKeys(oldKeys, oldFiles, keep)
		newKeys, newFiles = filterKeys(newKeys, newFiles, keep)
		if len(oldKeys) == 0 && len(newKeys) == 0 {
			fmt.Fprintln(out, "指定した名前の絵がどちらのフォルダにもありません")
			return 1
		}
	}
	isGif := func(p string) bool { return strings.HasSuffix(strings.ToLower(p), ".gif") }
	gifs := map[string]bool{}
	for _, p := range oldKeys {
		if isGif(p) {
			gifs[p] = true
		}
	}
	for _, p := range newKeys {
		if isGif(p) {
			gifs[p] = true
		}
	}
	var onlyOld, onlyNew []string
	for _, p := range oldKeys {
		if _, ok := newFiles[p]; !ok && !gifs[p] {
			onlyOld = append(onlyOld, p)
		}
	}
	for _, p := range newKeys {
		if _, ok := oldFiles[p]; !ok && !gifs[p] {
			onlyNew = append(onlyNew, p)
		}
	}

	hashes := oldHashes(oldRoot)
	same := 0
	var mismatched []string
	for _, rel := range oldKeys {
		if gifs[rel] {
			continue
		}
		if _, ok := newFiles[rel]; !ok {
			continue
		}
		equal := false
		if want, ok := hashes[rel]; ok {
			data, err := os.ReadFile(newFiles[rel])
			if err == nil {
				sum := sha256.Sum256(data)
				equal = hex.EncodeToString(sum[:]) == want
			}
		} else {
			equal = sameBytes(oldFiles[rel], newFiles[rel])
		}
		if equal {
			same++
		} else {
			mismatched = append(mismatched, rel)
		}
	}

	if same > 0 {
		fmt.Fprintf(out, "一致 %d 枚 (詳細略)\n", same)
	}
	if len(gifs) > 0 {
		fmt.Fprintf(out, "GIF %d 本は対象外 (スキップ)\n", len(gifs))
	}
	for _, rel := range onlyOld {
		fmt.Fprintf(out, "消えた: %s (旧側にだけある)\n", rel)
	}
	for _, rel := range onlyNew {
		fmt.Fprintf(out, "増えた: %s (新側にだけある)\n", rel)
	}

	type entry struct {
		rate  float64
		rel   string
		lines []string
	}
	var digests []entry
	for _, rel := range mismatched {
		lines, rate, err := digestPair(oldFiles[rel], newFiles[rel])
		if err != nil {
			digests = append(digests, entry{0.0, rel, []string{"ダイジェスト不可: " + err.Error()}})
		} else {
			digests = append(digests, entry{rate, rel, lines})
		}
	}
	sort.SliceStable(digests, func(i, j int) bool { return digests[i].rate > digests[j].rate })

	shown := digests
	if len(shown) > maxDetail {
		shown = shown[:maxDetail]
	}
	for _, d := range shown {
		fmt.Fprintf(out, "不一致: %s\n", d.rel)
		for _, line := range d.lines {
			fmt.Fprintf(out, "  %s\n", line)
		}
	}
	if len(digests) > maxDetail {
		rest := digests[maxDetail:]
		if len(rest) > 20 {
			rest = rest[:20]
		}
		names := make([]string, len(rest))
		for i, d := range rest {
			names[i] = d.rel
		}
		fmt.Fprintf(out, "他 %d 枚 (差分画素率の小さい順に略): %s\n",
			len(digests)-maxDetail, strings.Join(names, ", "))
	}

	if len(mismatched) == 0 && len(onlyOld) == 0 && len(onlyNew) == 0 {
		fmt.Fprintln(out, "全て一致")
		return 0
	}
	return 1
}

func filterKeys(keys []string, files map[string]string, keep func(string) bool) ([]string, map[string]string) {
	var outKeys []string
	outFiles := map[string]string{}
	for _, k := range keys {
		if keep(k) {
			outKeys = append(outKeys, k)
			outFiles[k] = files[k]
		}
	}
	return outKeys, outFiles
}

func statsOne(out *strings.Builder, path string, unit int) {
	fmt.Fprintln(out, filepath.Base(path))
	st, err := Measure(path, unit)
	if err != nil {
		fmt.Fprintf(out, "%s: ダイジェスト不可: %s\n", filepath.Base(path), err)
		return
	}
	unitTxt := strconv.Itoa(st.Unit)
	if st.UnitAuto {
		unitTxt += "(自動)"
	}
	grid := "—"
	if st.HasGrid {
		grid = fmt.Sprintf("%.0f%%", 100*st.Grid)
	}
	fmt.Fprintf(out, "  %dx%d  unit=%s  中間色 %.1f%%  格子適合 %s  楕円で説明できる面 %.1f%%\n",
		st.Width, st.Height, unitTxt, st.AA, grid, st.Ellipse)
	fmt.Fprintf(out, "  色数 %d (1000 画素あたり %.1f / 画面の 90%% を覆う色 %d)  平均輝度 %.0f\n",
		st.Colors, st.ColorsPerKpx, st.Cover90, st.Luma)
	parts := make([]string, 4)
	for i := 0; i < 4; i++ {
		parts[i] = fmt.Sprintf("%s:%.0f%%", StepLabels[i], st.Steps[i])
	}
	fmt.Fprintln(out, "  隣の色の段: "+strings.Join(parts, "  "))
	fmt.Fprintf(out, "  明度 3 段: 暗 %.0f%% / 中 %.0f%% / 明 %.0f%%\n",
		st.Luma3[0], st.Luma3[1], st.Luma3[2])
	if len(st.Regions) > 0 {
		fmt.Fprintf(out, "  大きい面 (%.0f%% を覆う):\n", st.RegionArea)
		top := st.Regions
		if len(top) > 6 {
			top = top[:6]
		}
		for _, r := range top {
			shape := ""
			if r.IOU >= ellipseIOU {
				shape = "楕円"
			}
			line := fmt.Sprintf("    %s %5.1f%% @%s %s", hexColor(r.Col), r.Area, r.Pos, shape)
			fmt.Fprintln(out, strings.TrimRight(line, " \t\n\r"))
		}
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
