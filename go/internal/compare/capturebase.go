package compare

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// CaptureTolerance は gl-capture の基準と今の絵が「小さい差」で済むかの物差し。
type CaptureTolerance struct {
	// Threshold は画素を「違う」と数える成分の差の下限（これを超えた画素だけを数える）。
	Threshold int
	// MaxPixels は Threshold を超えた画素の数の上限（1 コマごと）。
	MaxPixels int
	// MaxDelta は成分の差の最大の上限（1 コマごと）。
	MaxDelta int
}

// DefaultCaptureTolerance の値の根拠は docs/backend-parity.md の「小さい差で通す」。
var DefaultCaptureTolerance = CaptureTolerance{Threshold: 4, MaxPixels: 64, MaxDelta: 40}

// Within は d がこの物差しの内に収まるか。大きさの違う絵は収まらない。
func (t CaptureTolerance) Within(d PixelDiff) bool {
	return d.Pixels >= 0 && d.Over <= t.MaxPixels && d.MaxDelta <= t.MaxDelta
}

// ReadCaptureSums は「<SHA>  <名前>」の一覧を読む（# の行と空の行は読まない）。名前 → SHA。
func ReadCaptureSums(r io.Reader) (map[string]string, error) {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) != 2 {
			return nil, fmt.Errorf("「<SHA>  <名前>」の形でない: %q", line)
		}
		out[f[1]] = f[0]
	}
	return out, sc.Err()
}

// captureSelected は gl-capture.sh の sums_of と同じ絞り方（名前の / の前がフォルダ、その __ の前が頭）。
func captureSelected(name string, only, skip []string) bool {
	dir, _, _ := strings.Cut(name, "/")
	head, _, _ := strings.Cut(dir, "__")
	for _, s := range skip {
		if s == dir {
			return false
		}
	}
	if len(only) == 0 {
		return true
	}
	for _, o := range only {
		if o == dir || o == head {
			return true
		}
	}
	return false
}

func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// CaptureBaselineCheck の入力。
type CaptureBaselineCheck struct {
	// Sums は基準の SHA の一覧（bench/baseline/<版>/gl-capture-*.sha256）。
	Sums string
	// Images は基準の絵を置く手元のフォルダ（git の外）。中の絵は Sums と SHA が合う物だけを使う。
	Images string
	// Current は今回撮ったフォルダ（中に SHA256SUMS と <名前> の PNG）。
	Current string
	// DiffDir は差のあったコマの「基準 | 今 | 差の所」の絵を書くフォルダ。空なら書かない。
	DiffDir    string
	Only, Skip []string
	Tolerance  CaptureTolerance
}

// Run は基準と今の絵を比べ、止めるなら 1 を返す。SHA が同じコマは通し、その絵が Images に無ければ置く（基準と同じバイトなので
// 基準の絵として使える）。SHA が違うコマは Images の基準の絵と画素で比べ、Tolerance の内なら通す。
// WhyNot: SHA の合わない Images の絵と比べない — 基準を撮り直した後に残った古い絵と比べると、古い基準に近いことを確かめてしまう。
func (c CaptureBaselineCheck) Run(out, errOut io.Writer) int {
	base, err := readSumsFile(c.Sums)
	if err != nil {
		fmt.Fprintf(errOut, "[gl-capture] 基準を読めない: %v\n", err)
		return 2
	}
	cur, err := readSumsFile(filepath.Join(c.Current, "SHA256SUMS"))
	if err != nil {
		fmt.Fprintf(errOut, "[gl-capture] 今回の SHA256SUMS を読めない: %v\n", err)
		return 2
	}
	names := map[string]bool{}
	for n := range base {
		if captureSelected(n, c.Only, c.Skip) {
			names[n] = true
		}
	}
	for n := range cur {
		if captureSelected(n, c.Only, c.Skip) {
			names[n] = true
		}
	}
	sorted := make([]string, 0, len(names))
	for n := range names {
		sorted = append(sorted, n)
	}
	sort.Slice(sorted, func(i, j int) bool { return lessCaptureName(sorted[i], sorted[j]) })

	exact, near, failed, seeded := 0, 0, 0, 0
	for _, n := range sorted {
		bs, inBase := base[n]
		cs, inCur := cur[n]
		switch {
		case !inBase:
			fmt.Fprintf(errOut, "[gl-capture] NG %s: 基準に無いコマ\n", n)
			failed++
			continue
		case !inCur:
			fmt.Fprintf(errOut, "[gl-capture] NG %s: 今回撮れていないコマ\n", n)
			failed++
			continue
		}
		img := filepath.Join(c.Images, n)
		if bs == cs {
			exact++
			if have, _ := fileSHA256(img); have != bs {
				if err := copyFile(filepath.Join(c.Current, n), img); err != nil {
					fmt.Fprintf(errOut, "[gl-capture] 基準の絵を置けない（比べには響かない）: %v\n", err)
				} else {
					seeded++
				}
			}
			continue
		}
		if have, _ := fileSHA256(img); have != bs {
			fmt.Fprintf(errOut, "[gl-capture] NG %s: SHA が基準と違い、画素で比べる基準の絵が %s に無い（基準と同じ絵を撮った回で置かれる・撮り直すなら make gl-capture-baseline）\n", n, c.Images)
			failed++
			continue
		}
		a, err := readPNG(img)
		if err != nil {
			fmt.Fprintf(errOut, "[gl-capture] NG %s: 基準の絵を読めない: %v\n", n, err)
			failed++
			continue
		}
		b, err := readPNG(filepath.Join(c.Current, n))
		if err != nil {
			fmt.Fprintf(errOut, "[gl-capture] NG %s: 今の絵を読めない: %v\n", n, err)
			failed++
			continue
		}
		d := DiffNRGBAOver(a, b, true, c.Tolerance.Threshold)
		where := ""
		if c.DiffDir != "" {
			p := filepath.Join(c.DiffDir, strings.ReplaceAll(n, "/", "__"))
			if _, err := writePair(p, a, b); err == nil {
				where = "（差の絵 " + p + "）"
			}
		}
		if d.Pixels < 0 {
			fmt.Fprintf(errOut, "[gl-capture] NG %s: 大きさが違う %dx%d と %dx%d\n", n, a.Bounds().Dx(), a.Bounds().Dy(), b.Bounds().Dx(), b.Bounds().Dy())
			failed++
			continue
		}
		detail := fmt.Sprintf("差 %d px（±%d を超えた %d px・上限 %d）・最大 ±%d（上限 %d）%s",
			d.Pixels, c.Tolerance.Threshold, d.Over, c.Tolerance.MaxPixels, d.MaxDelta, c.Tolerance.MaxDelta, where)
		if c.Tolerance.Within(d) {
			fmt.Fprintf(out, "[gl-capture] 小さい差で通した %s: %s\n", n, detail)
			near++
		} else {
			fmt.Fprintf(errOut, "[gl-capture] NG %s: %s\n", n, detail)
			failed++
		}
	}
	if seeded > 0 {
		fmt.Fprintf(out, "[gl-capture] 基準の絵を %d 枚置いた → %s\n", seeded, c.Images)
	}
	if failed > 0 {
		fmt.Fprintf(errOut, "[gl-capture] 基準と違う絵がある: %d 枚（バイト一致 %d・小さい差 %d）\n", failed, exact, near)
		return 1
	}
	if near > 0 {
		fmt.Fprintf(out, "[gl-capture] 基準と合った: %d 枚（バイト一致 %d・小さい差で通した %d）\n", exact+near, exact, near)
	} else {
		fmt.Fprintf(out, "[gl-capture] 一致: %d 枚がバイトまで同じ\n", exact)
	}
	return 0
}

func readSumsFile(p string) (map[string]string, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ReadCaptureSums(f)
}

// lessCaptureName は「フォルダ/frame-N.png」をフォルダの順・N の数の順に並べる（sort -V と同じ並び）。
func lessCaptureName(a, b string) bool {
	da, fa, _ := strings.Cut(a, "/")
	db, fb, _ := strings.Cut(b, "/")
	if da != db {
		return da < db
	}
	na, ea := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(fa, "frame-"), ".png"))
	nb, eb := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(fb, "frame-"), ".png"))
	if ea == nil && eb == nil {
		return na < nb
	}
	return fa < fb
}

// RunCaptureBaseline は `gl-capture-baseline-check <基準の SHA> <基準の絵のフォルダ> <今のフォルダ> [--only <名前>]… [--skip <フォルダ名>]…
// [--threshold D] [--max-pixels N] [--max-delta M] [--diff-dir <フォルダ>]` の本体。
func RunCaptureBaseline(args []string, out, errOut io.Writer) int {
	c := CaptureBaselineCheck{Tolerance: DefaultCaptureTolerance}
	var paths []string
	usage := "usage: fge gl-capture-baseline-check <基準の SHA の一覧> <基準の絵のフォルダ> <今のフォルダ> [--only <名前>]… [--skip <フォルダ名>]… [--threshold D] [--max-pixels N] [--max-delta M] [--diff-dir <フォルダ>]"
	for i := 0; i < len(args); i++ {
		flag := args[i]
		if !strings.HasPrefix(flag, "--") {
			paths = append(paths, flag)
			continue
		}
		if i+1 >= len(args) {
			fmt.Fprintf(errOut, "%s の後に値が無い\n%s\n", flag, usage)
			return 2
		}
		v := args[i+1]
		i++
		var num *int
		switch flag {
		case "--only":
			c.Only = append(c.Only, v)
		case "--skip":
			c.Skip = append(c.Skip, v)
		case "--diff-dir":
			c.DiffDir = v
		case "--threshold":
			num = &c.Tolerance.Threshold
		case "--max-pixels":
			num = &c.Tolerance.MaxPixels
		case "--max-delta":
			num = &c.Tolerance.MaxDelta
		default:
			fmt.Fprintln(errOut, usage)
			return 2
		}
		if num != nil {
			n, err := strconv.Atoi(v)
			if err != nil || n < 0 {
				fmt.Fprintf(errOut, "%s は 0 以上の数: %q\n", flag, v)
				return 2
			}
			*num = n
		}
	}
	if len(paths) != 3 {
		fmt.Fprintln(errOut, usage)
		return 2
	}
	c.Sums, c.Images, c.Current = paths[0], paths[1], paths[2]
	return c.Run(out, errOut)
}
