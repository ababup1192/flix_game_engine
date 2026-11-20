package main

import (
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	_ "image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const webImageDiffUsage = `使い方: bin/fge web-image-diff <ゲーム> [--out <png>] [--limit <枚数>] [--explicit] [--engine <engine>]

  bin/fge export-web が既定で lossy の WebP にする絵（写真寄りの png）を同じ判定で詰め、元と後と差を横に並べた 1 枚の PNG を書く。
  並びは色数の少ない順（字・線・UI の取り違えが起きやすい順）。1 行が 1 枚で、左から 元・lossy・差（8 倍に強めた絶対値）。
  絵は真ん中の %d×%d 画素までを 1:1 で切り出す（縮めると崩れが見えなくなる）。透明の所は市松の地で見せる。

  --out <png>      書く先（既定 <ゲーム>/build/web-image-diff.png）
  --limit <枚数>   並べる枚数の上限（既定 12）
  --explicit       web.compress.lossyImages で明示した絵も並べる
  --engine <dir>   判定の数（bin/lint-rules/export-web.json）を読む engine の根

  終わりの番号: 0 書けた（並べる絵が無い時も 0）/ 1 絵を詰められない / 2 呼び方の誤りか道具が無い`

const webImageDiffCrop = 320

func init() {
	register("web-image-diff", "ブラウザ版で既定で lossy にする絵の元と後を並べた PNG を書く。web-image-diff --help", cmdWebImageDiff)
}

type webImageDiffOptions struct {
	Game, Out, Engine string
	Limit             int
	Explicit          bool
}

func parseWebImageDiffArgs(args []string) (webImageDiffOptions, error) {
	o := webImageDiffOptions{Limit: 12}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--help" || a == "-h":
			return o, errCommandHelp
		case a == "--explicit":
			o.Explicit = true
		case a == "--out" || a == "--engine" || a == "--limit":
			if i+1 >= len(args) {
				return o, fmt.Errorf("%s には値が要る", a)
			}
			i++
			switch a {
			case "--out":
				o.Out = args[i]
			case "--engine":
				o.Engine = args[i]
			default:
				n, err := strconv.Atoi(args[i])
				if err != nil || n < 1 {
					return o, fmt.Errorf("--limit は 1 以上の数: %s", args[i])
				}
				o.Limit = n
			}
		case strings.HasPrefix(a, "--"):
			return o, fmt.Errorf("知らない引数: %s", a)
		case o.Game != "":
			return o, fmt.Errorf("ゲームのフォルダは 1 つだけ: %s と %s", o.Game, a)
		default:
			o.Game = a
		}
	}
	if o.Game == "" {
		return o, errors.New("ゲームのフォルダを渡してください")
	}
	return o, nil
}

func cmdWebImageDiff(out, errOut *strings.Builder, rest []string, _ bool) int {
	o, err := parseWebImageDiffArgs(rest)
	if err != nil {
		if errors.Is(err, errCommandHelp) {
			fmt.Fprintf(out, webImageDiffUsage+"\n", webImageDiffCrop, webImageDiffCrop)
			return 0
		}
		fmt.Fprintf(errOut, "fge web-image-diff: %v\n", err)
		return 2
	}
	code, err := runWebImageDiff(out, o)
	if err != nil {
		fmt.Fprintf(errOut, "fge web-image-diff: %v\n", err)
	}
	return code
}

type webImageDiffRow struct {
	v         webImageVerdict
	src, webp string
}

func runWebImageDiff(out *strings.Builder, o webImageDiffOptions) (int, error) {
	game, err := filepath.Abs(o.Game)
	if err != nil || !dirExists(game) {
		return 2, fmt.Errorf("ゲームのフォルダが無い: %s", o.Game)
	}
	engine := o.Engine
	if engine == "" {
		engine = engineDirOf(repoRoot())
	}
	proj, err := loadExportProject(game)
	if err != nil {
		return 2, err
	}
	c, err := resolveWebCompress(proj.Web)
	if err != nil {
		return 2, err
	}
	if c.Auto, err = loadWebAutoLossyRules(engine); err != nil {
		return 2, err
	}
	c.DataImages = loadWebShaderTextures(game, proj)
	cwebp, dwebp := findWebTool("cwebp", engine), findWebTool("dwebp", engine)
	if cwebp == "" || dwebp == "" {
		return 2, errors.New("cwebp と dwebp（libwebp）が要る。入れ方: brew install webp")
	}
	b, err := buildWebBundle(game, "diff", proj, usesScene3dEntry(readWebEntry(game)))
	if err != nil {
		return 2, err
	}
	tmp, err := os.MkdirTemp("", "fge-web-image-diff-")
	if err != nil {
		return 1, err
	}
	defer os.RemoveAll(tmp)
	for _, rel := range b.Images {
		if err := copyFile(filepath.Join(game, filepath.FromSlash(rel)), exportAssetPath(tmp, rel)); err != nil {
			return 1, err
		}
	}
	jobs, _ := planWebImages(tmp, b.Images, c, webEncoders{Cwebp: cwebp}, map[string]bool{})
	errs := runWebJobs(jobs)
	for i, err := range errs {
		if err != nil {
			return 1, fmt.Errorf("%s を詰められない: %v", jobs[i].rel, err)
		}
	}
	rows := selectWebImageDiffRows(jobs, o, c.Auto)
	if len(rows) == 0 {
		fmt.Fprintln(out, "web-image-diff: 既定で lossy になる絵は無い（並べる物が無いので PNG は書かない）")
		return 0, nil
	}
	dst := o.Out
	if dst == "" {
		dst = filepath.Join(game, "build", "web-image-diff.png")
	}
	lines, err := writeWebImageDiff(dst, rows, dwebp, tmp)
	if err != nil {
		return 1, err
	}
	fmt.Fprintf(out, "web-image-diff: %s（左から 元・lossy・差 ×8。上から色数の少ない順）\n", dst)
	for _, l := range lines {
		fmt.Fprintf(out, "  %s\n", l)
	}
	return 0, nil
}

// selectWebImageDiffRows は並べる絵（既定で lossy になる物と、--explicit なら lossyImages の物）を色数の少ない順に limit 枚まで選ぶ。
// export-web と同じく、WebP が元の絵より大きくなる物は元のまま配るので外す。
func selectWebImageDiffRows(jobs []webJob, o webImageDiffOptions, r *webAutoLossyRules) []webImageDiffRow {
	var rows []webImageDiffRow
	for _, j := range jobs {
		v := *j.verdict
		explicit := o.Explicit && len(v.explicitRules) > 0
		if v.Kind != webImageAutoLossy && !explicit {
			continue
		}
		if size := fileSize(j.dst); size <= 0 || size >= fileSize(j.src) {
			continue
		}
		if explicit && v.Colors == 0 {
			v.Colors, v.OpaqueShare, _ = countImageColors(j.src, r)
		}
		rows = append(rows, webImageDiffRow{v: v, src: j.src, webp: j.dst})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].v.Colors < rows[j].v.Colors })
	if len(rows) > o.Limit {
		rows = rows[:o.Limit]
	}
	return rows
}

// writeWebImageDiff は rows を 1 行ずつ 元・lossy・差 の順に並べた PNG を dst に書き、1 行ずつの説明を返す。
func writeWebImageDiff(dst string, rows []webImageDiffRow, dwebp, tmp string) ([]string, error) {
	type tile struct{ a, b *image.NRGBA }
	tiles := make([]tile, 0, len(rows))
	var lines []string
	width, height := 0, 0
	const gap = 4
	for i, r := range rows {
		rawA, err := decodeImageFile(r.src)
		if err != nil {
			return nil, err
		}
		back := filepath.Join(tmp, fmt.Sprintf("back-%d.png", i))
		if err := runQuiet(dwebp, "-quiet", r.webp, "-o", back); err != nil {
			return nil, fmt.Errorf("%s を dwebp で戻せない: %v", r.v.Rel, err)
		}
		rawB, err := decodeImageFile(back)
		if err != nil {
			return nil, err
		}
		a, bimg := centerCrop(rawA, webImageDiffCrop), centerCrop(rawB, webImageDiffCrop)
		tiles = append(tiles, tile{a, bimg})
		w, h := a.Bounds().Dx(), a.Bounds().Dy()
		width = max(width, 3*w+2*gap)
		height += h + gap
		maxDiff, meanDiff := imageDiffStats(a, bimg)
		lines = append(lines, fmt.Sprintf("%2d. %s  %s 色・不透明 %.0f%%・%s・差の最大 %d・平均 %.2f（切り出した所）",
			i+1, r.v.Rel, groupDigits(r.v.Colors), 100*r.v.OpaqueShare, humanBytes(fileSize(r.webp)), maxDiff, meanDiff))
	}
	canvas := image.NewNRGBA(image.Rect(0, 0, width, height))
	draw.Draw(canvas, canvas.Bounds(), &image.Uniform{color.NRGBA{40, 40, 40, 255}}, image.Point{}, draw.Src)
	y := 0
	for _, t := range tiles {
		w, h := t.a.Bounds().Dx(), t.a.Bounds().Dy()
		drawOverChecker(canvas, image.Rect(0, y, w, y+h), t.a)
		drawOverChecker(canvas, image.Rect(w+gap, y, 2*w+gap, y+h), t.b)
		drawAmplifiedDiff(canvas, image.Rect(2*w+2*gap, y, 3*w+2*gap, y+h), t.a, t.b, 8)
		y += h + gap
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return nil, err
	}
	f, err := os.Create(dst)
	if err != nil {
		return nil, err
	}
	if err := png.Encode(f, canvas); err != nil {
		f.Close()
		return nil, err
	}
	return lines, f.Close()
}

func decodeImageFile(p string) (image.Image, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		return nil, fmt.Errorf("%s を解けない: %v", p, err)
	}
	return img, nil
}

// centerCrop は真ん中の side×side までを切り出し、左上を (0, 0) にした NRGBA で返す。
func centerCrop(img image.Image, side int) *image.NRGBA {
	b := img.Bounds()
	w, h := min(b.Dx(), side), min(b.Dy(), side)
	x0, y0 := b.Min.X+(b.Dx()-w)/2, b.Min.Y+(b.Dy()-h)/2
	out := image.NewNRGBA(image.Rect(0, 0, w, h))
	draw.Draw(out, out.Bounds(), img, image.Point{x0, y0}, draw.Src)
	return out
}

func drawOverChecker(dst *image.NRGBA, r image.Rectangle, img image.Image) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			v := uint8(150)
			if ((x-r.Min.X)/8+(y-r.Min.Y)/8)%2 == 0 {
				v = 200
			}
			dst.SetNRGBA(x, y, color.NRGBA{v, v, v, 255})
		}
	}
	draw.Draw(dst, r, img, image.Point{}, draw.Over)
}

// drawAmplifiedDiff は 2 枚の見える差（visibleDiff）を k 倍して黒地に描く。
func drawAmplifiedDiff(dst *image.NRGBA, r image.Rectangle, a, b *image.NRGBA, k int) {
	for y := 0; y < r.Dy(); y++ {
		for x := 0; x < r.Dx(); x++ {
			d := visibleDiff(a.NRGBAAt(x, y), b.NRGBAAt(x, y))
			dst.SetNRGBA(r.Min.X+x, r.Min.Y+y, color.NRGBA{uint8(min(255, k*d[0])), uint8(min(255, k*d[1])), uint8(min(255, k*d[2])), 255})
		}
	}
}

// visibleDiff は色に α を掛けた値どうしの差（色ごと）。
// WhyNot: 素の RGB を比べない — α の小さいふちの画素は色が大きく替わっても見えず、差の最大がいつも 255 近くになって読めない。
func visibleDiff(pa, pb color.NRGBA) [3]int {
	mul := func(c, a uint8) int { return int(c) * int(a) / 255 }
	return [3]int{
		absInt(mul(pa.R, pa.A) - mul(pb.R, pb.A)),
		absInt(mul(pa.G, pa.A) - mul(pb.G, pb.A)),
		absInt(mul(pa.B, pa.A) - mul(pb.B, pb.A)),
	}
}

func absInt(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// imageDiffStats は見える画素（どちらかの α が 0 でない）の、見える差（visibleDiff の色の最大）の最大と平均。
func imageDiffStats(a, b *image.NRGBA) (int, float64) {
	maxDiff, sum, n := 0, 0, 0
	for y := 0; y < a.Bounds().Dy(); y++ {
		for x := 0; x < a.Bounds().Dx(); x++ {
			pa, pb := a.NRGBAAt(x, y), b.NRGBAAt(x, y)
			if pa.A == 0 && pb.A == 0 {
				continue
			}
			d := visibleDiff(pa, pb)
			m := max(d[0], d[1], d[2])
			maxDiff = max(maxDiff, m)
			sum += m
			n++
		}
	}
	if n == 0 {
		return 0, 0
	}
	return maxDiff, float64(sum) / float64(n)
}
