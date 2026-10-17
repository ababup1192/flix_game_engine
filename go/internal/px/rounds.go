package px

// 周回の口: watch（保存のたびに build）・snap（last を rN に凍らせる）・restore（rN の spec に戻す）・
// diff（2 つの周の画素の差と違反の差）。spike/pxkit の run.go から移した。
//
// 周の上限は bin/lint-rules/px.json の maxRounds（5）。6 周目は拒む（drawing.md の「絵の周回」）。
// r2 で止めて、依頼主に「①どちらが良いか ②続けるか ③直す所 1 つ」だけ聞く。
//
// 置き場: debug/px/<名前>/last（build の出力）・debug/px/<名前>/rN/（凍らせた周。spec の写しつき）。

import (
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// liveOut は watch が結果を流す先（Run の out は戻るまで出ないので、端末へ直に書く）。
var liveOut io.Writer = os.Stdout

func roundsDir(workRoot, spec string) string {
	return filepath.Join(workRoot, "debug", "px", specName(spec))
}

func specPath(workRoot, spec string) string {
	if filepath.IsAbs(spec) {
		return spec
	}
	return filepath.Join(workRoot, spec)
}

// nextRound は次に凍らせる周の番号（r1 から）。
func nextRound(dir string) int {
	n := 1
	for {
		if _, err := os.Stat(filepath.Join(dir, fmt.Sprintf("r%d", n))); err != nil {
			return n
		}
		n++
	}
}

// cmdWatch は spec の更新を 100ms ごとに見て、変わったら build する。止めるまで戻らない。
func cmdWatch(errOut *strings.Builder, engineRoot, workRoot, spec string, noCheck bool) int {
	var last time.Time
	full := specPath(workRoot, spec)
	fmt.Fprintf(liveOut, "px watch: %s を見ている（Ctrl-C で止める）\n", rel(workRoot, full))
	for {
		st, err := os.Stat(full)
		if err == nil && st.ModTime() != last {
			last = st.ModTime()
			res, err := build(workRoot, spec, buildOptions{RulesRoot: engineRoot, NoCheck: noCheck})
			if err != nil {
				fmt.Fprintf(liveOut, "px: %v\n", err)
			} else {
				fmt.Fprint(liveOut, summarize(workRoot, res))
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// cmdSnap は今の spec で描き直し、last を rN に凍らせる。上限を超える周は拒む。
func cmdSnap(out, errOut *strings.Builder, engineRoot, workRoot, spec string, fresh bool) int {
	rules, err := loadRules(engineRoot)
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	dir := roundsDir(workRoot, spec)
	if fresh {
		if n := nextRound(dir); n > 1 {
			old := filepath.Join(dir+"-old", time.Now().Format("20060102-150405"))
			if err := os.MkdirAll(old, 0o755); err != nil {
				fmt.Fprintln(errOut, err)
				return 1
			}
			for i := 1; i < n; i++ {
				r := fmt.Sprintf("r%d", i)
				if err := os.Rename(filepath.Join(dir, r), filepath.Join(old, r)); err != nil {
					fmt.Fprintln(errOut, err)
					return 1
				}
			}
			fmt.Fprintf(out, "前の周回は %s へ退けた\n", rel(workRoot, old))
		}
	}
	n := nextRound(dir)
	if n > rules.MaxRounds {
		fmt.Fprintf(errOut, "px: %d 周目は描かない（作り直しは最大 %d 周。drawing.md の絵の周回）。依頼主に終わりを聞くか、別の作業なら --new で r1 から始める\n", n, rules.MaxRounds)
		return 1
	}
	res, err := build(workRoot, spec, buildOptions{RulesRoot: engineRoot})
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	last := filepath.Dir(res.Sheet)
	cur := filepath.Join(dir, fmt.Sprintf("r%d", n))
	if err := copyDir(last, cur); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	src, err := os.ReadFile(specPath(workRoot, spec))
	if err == nil {
		err = os.WriteFile(filepath.Join(cur, filepath.Base(spec)), src, 0o644)
	}
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	out.WriteString(summarize(workRoot, res))
	fmt.Fprintf(out, "周: %s（spec の写しつき）\n", rel(workRoot, cur))
	if n > 1 {
		prev := filepath.Join(dir, fmt.Sprintf("r%d", n-1), "sheet.png")
		cmp := filepath.Join(cur, "compare.png")
		if err := sideBySide(prev, filepath.Join(cur, "sheet.png"), cmp); err == nil {
			fmt.Fprintf(out, "比べ絵（左 r%d・右 r%d）: %s\n", n-1, n, rel(workRoot, cmp))
		}
	}
	out.WriteString(roundAsk(n, rules.MaxRounds, spec))
	return 0
}

// roundAsk は周ごとに依頼主へ聞くこと。
func roundAsk(n, maxN int, spec string) string {
	switch {
	case n == 2:
		return "r2: ここで止める。依頼主に「①r1 と r2 のどちらが良いか ②続けるか終わりか ③続けるなら直す所を 1 つ」だけ聞き、返事まで r3 を描かない\n"
	case n > 2 && n < maxN:
		return fmt.Sprintf("r%d: 依頼主に「①r%d と r%d のどちらが良いか」を聞く。前が良ければ fge px restore %s r%d で戻す\n", n, n-1, n, spec, n-1)
	case n >= maxN:
		return fmt.Sprintf("r%d: 最後の周。依頼主にどちらを採るかだけ聞き、次は描かない\n", n)
	}
	return ""
}

// cmdRestore は rN の spec の写しを今の spec へ書き戻す。
func cmdRestore(out, errOut *strings.Builder, workRoot, spec, round string) int {
	src := filepath.Join(roundsDir(workRoot, spec), round, filepath.Base(spec))
	data, err := os.ReadFile(src)
	if err != nil {
		fmt.Fprintf(errOut, "px: %s が無い（fge px snap で凍らせた周だけ戻せる）\n", rel(workRoot, src))
		return 1
	}
	if err := os.WriteFile(specPath(workRoot, spec), data, 0o644); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	fmt.Fprintf(out, "%s を %s の spec に戻した（fge px build で描き直す）\n", spec, round)
	return 0
}

// cmdDiff は 2 つの周の画素の差の PNG（左 rA・右 rB・差）と、違反の増減を出す。
func cmdDiff(out, errOut *strings.Builder, workRoot, spec, ra, rb string) int {
	dir := roundsDir(workRoot, spec)
	a := loadPrev(filepath.Join(dir, ra, "report.json"))
	b := loadPrev(filepath.Join(dir, rb, "report.json"))
	if a == nil || b == nil {
		fmt.Fprintf(errOut, "px: %s か %s の report.json が無い（fge px snap で凍らせた周を指す）\n", ra, rb)
		return 1
	}
	hexOf := map[pxlib.Key]string{}
	for _, r := range []*buildResult{a, b} {
		for k, h := range r.Hex {
			hexOf[pxlib.Key(k)] = h
		}
	}
	aRows := map[string][]string{}
	for _, f := range a.Frames {
		aRows[f.Sprite+"/"+f.Name] = f.Rows
	}
	var frames []pxlib.SheetFrame
	changed := 0
	for _, f := range b.Frames {
		sf := pxlib.SheetFrame{Px: colorsOf(f.Rows, b.Legend, hexOf)}
		if rows, ok := aRows[f.Sprite+"/"+f.Name]; ok {
			sf.Prev = colorsOf(rows, a.Legend, hexOf)
			if strings.Join(rows, "/") != strings.Join(f.Rows, "/") {
				changed++
			}
		}
		frames = append(frames, sf)
	}
	png := filepath.Join(dir, fmt.Sprintf("diff-%s-%s.png", ra, rb))
	if err := pxlib.WritePNG(png, pxlib.Sheet(frames, groundColor(""), 4)); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	keys := func(r *buildResult) map[string]violation {
		m := map[string]violation{}
		for _, v := range r.Violations {
			m[v.key()] = v
		}
		return m
	}
	ka, kb := keys(a), keys(b)
	var added, removed []string
	for k, v := range kb {
		if _, ok := ka[k]; !ok {
			added = append(added, v.String())
		}
	}
	for k, v := range ka {
		if _, ok := kb[k]; !ok {
			removed = append(removed, v.String())
		}
	}
	sort.Strings(added)
	sort.Strings(removed)
	fmt.Fprintf(out, "px diff %s → %s: 変わったコマ %d・違反 増えた %d・消えた %d → %s\n", ra, rb, changed, len(added), len(removed), rel(workRoot, png))
	for i, l := range added {
		if i == 5 {
			break
		}
		fmt.Fprintf(out, "  + %s\n", l)
	}
	for i, l := range removed {
		if i == 5 {
			break
		}
		fmt.Fprintf(out, "  - %s\n", l)
	}
	return 0
}

func copyDir(src, dst string) error {
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(src, e.Name()))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dst, e.Name()), data, 0o644); err != nil {
			return err
		}
	}
	return nil
}

func sideBySide(a, b, dst string) error {
	ia, err := readPNG(a)
	if err != nil {
		return err
	}
	ib, err := readPNG(b)
	if err != nil {
		return err
	}
	const gap = 12
	w := ia.Bounds().Dx() + gap + ib.Bounds().Dx()
	h := max(ia.Bounds().Dy(), ib.Bounds().Dy())
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.Draw(img, ia.Bounds(), ia, image.Point{}, draw.Src)
	draw.Draw(img, ib.Bounds().Add(image.Pt(ia.Bounds().Dx()+gap, 0)), ib, image.Point{}, draw.Src)
	fh, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer fh.Close()
	return png.Encode(fh, img)
}

func readPNG(p string) (image.Image, error) {
	fh, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer fh.Close()
	return png.Decode(fh)
}
