package compare

import (
	"bufio"
	"fmt"
	"image"
	"image/color"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// PixelDiff は 2 枚の PNG を、前乗せしない色（NRGBA）のまま成分ごとに比べた結果。
type PixelDiff struct {
	// Pixels は 1 成分でも違う画素の数。大きさが違えば -1。
	Pixels int
	// MaxDelta は成分（R・G・B・A）の差の最大（0〜255）。
	MaxDelta int
	// Total は画素の総数。
	Total int
	// Over は成分の差の最大が DiffNRGBAOver の threshold を超えた画素の数（DiffNRGBA では Pixels と同じ）。
	Over int
}

// DiffNRGBA は a と b を NRGBA のまま比べる。大きさが違えば Pixels = -1。
// WhyNot: pixelAt（color.RGBA）で比べない — RGBA は前乗せの色で、半透明の画素の色の差が alpha で潰れる。
func DiffNRGBA(a, b image.Image, withAlpha bool) PixelDiff {
	return DiffNRGBAOver(a, b, withAlpha, 0)
}

// DiffNRGBAOver は DiffNRGBA に加えて、成分の差の最大が threshold を超えた画素を Over に数える。
func DiffNRGBAOver(a, b image.Image, withAlpha bool, threshold int) PixelDiff {
	ra, rb := a.Bounds(), b.Bounds()
	if ra.Dx() != rb.Dx() || ra.Dy() != rb.Dy() {
		return PixelDiff{Pixels: -1, Total: ra.Dx() * ra.Dy()}
	}
	d := PixelDiff{Total: ra.Dx() * ra.Dy()}
	for y := 0; y < ra.Dy(); y++ {
		for x := 0; x < ra.Dx(); x++ {
			ca := color.NRGBAModel.Convert(a.At(ra.Min.X+x, ra.Min.Y+y)).(color.NRGBA)
			cb := color.NRGBAModel.Convert(b.At(rb.Min.X+x, rb.Min.Y+y)).(color.NRGBA)
			m := max(absDiff(ca.R, cb.R), absDiff(ca.G, cb.G), absDiff(ca.B, cb.B))
			if withAlpha {
				m = max(m, absDiff(ca.A, cb.A))
			}
			if m > 0 {
				d.Pixels++
				d.MaxDelta = max(d.MaxDelta, m)
			}
			if m > threshold {
				d.Over++
			}
		}
	}
	return d
}

func absDiff(a, b uint8) int {
	if a > b {
		return int(a - b)
	}
	return int(b - a)
}

// ReadTolerances は「場面<TAB>許す差<TAB>理由」の表を読む（# の行と空の行は読まない）。
func ReadTolerances(r io.Reader) (map[string]int, error) {
	out := map[string]int{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		cols := strings.Split(line, "\t")
		if len(cols) < 2 {
			return nil, fmt.Errorf("列が足りない: %q", line)
		}
		n, err := strconv.Atoi(strings.TrimSpace(cols[1]))
		if err != nil {
			return nil, fmt.Errorf("許す差が数でない: %q", line)
		}
		out[strings.TrimSpace(cols[0])] = n
	}
	return out, sc.Err()
}

// RunPixelDiff は `pixel-diff <A> <B> [--tolerance <tsv>] [--name <場面>] [--out <差の絵>] [--ignore-alpha]` の本体（--ignore-alpha は RGB だけを比べる。opaque な canvas と alpha を持つ FBO の絵を比べる時）。
// 場面の名前（既定は A のファイル名から .png を除いた物）の許す差を表から引き（無ければ 0）、成分の差の最大がそれを超えたら 1 を返す。
// 差があれば A | B | 差の所 の絵を書く（既定 debug/pixel-diff/<場面>.png）。
func RunPixelDiff(args []string, out, errOut io.Writer) int {
	var paths []string
	tolerance, name, diffOut := "", "", ""
	withAlpha := true
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--ignore-alpha":
			withAlpha = false
		case "--tolerance", "--name", "--out":
			if i+1 >= len(args) {
				fmt.Fprintf(errOut, "pixel-diff: %s の後に値が無い\n", args[i])
				return 2
			}
			switch args[i] {
			case "--tolerance":
				tolerance = args[i+1]
			case "--name":
				name = args[i+1]
			default:
				diffOut = args[i+1]
			}
			i++
		default:
			paths = append(paths, args[i])
		}
	}
	if len(paths) != 2 {
		fmt.Fprintln(errOut, "usage: fge pixel-diff <A.png> <B.png> [--tolerance <tsv>] [--name <場面>] [--out <差の絵.png>] [--ignore-alpha]")
		return 2
	}
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(paths[0]), filepath.Ext(paths[0]))
	}
	limit := 0
	if tolerance != "" {
		f, err := os.Open(tolerance)
		if err != nil {
			fmt.Fprintf(errOut, "pixel-diff: 許す差の表を読めない: %v\n", err)
			return 2
		}
		table, err := ReadTolerances(f)
		f.Close()
		if err != nil {
			fmt.Fprintf(errOut, "pixel-diff: %s: %v\n", tolerance, err)
			return 2
		}
		limit = table[name]
	}
	a, err := readPNG(paths[0])
	if err != nil {
		fmt.Fprintf(errOut, "pixel-diff: %s を読めない: %v\n", paths[0], err)
		return 2
	}
	b, err := readPNG(paths[1])
	if err != nil {
		fmt.Fprintf(errOut, "pixel-diff: %s を読めない: %v\n", paths[1], err)
		return 2
	}
	d := DiffNRGBA(a, b, withAlpha)
	if d.Pixels < 0 {
		fmt.Fprintf(out, "[pixel-diff] %s NG 大きさが違う %dx%d と %dx%d\n", name, a.Bounds().Dx(), a.Bounds().Dy(), b.Bounds().Dx(), b.Bounds().Dy())
		return 1
	}
	if d.Pixels > 0 {
		if diffOut == "" {
			diffOut = filepath.Join("debug", "pixel-diff", name+".png")
		}
		if _, err := writePair(diffOut, a, b); err != nil {
			fmt.Fprintf(errOut, "pixel-diff: 差の絵を書けない: %v\n", err)
		}
	}
	verdict := "OK"
	if d.MaxDelta > limit {
		verdict = "NG"
	}
	suffix := ""
	if d.Pixels > 0 {
		suffix = "（差の絵 " + diffOut + "）"
	}
	fmt.Fprintf(out, "[pixel-diff] %s %s 差 %d px / %d px・max ±%d（許容 %d）%s\n", name, verdict, d.Pixels, d.Total, d.MaxDelta, limit, suffix)
	if verdict == "NG" {
		return 1
	}
	return 0
}
