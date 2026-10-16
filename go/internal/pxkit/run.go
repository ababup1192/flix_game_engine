package pxkit

import (
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Run は fge pxkit の入口。
func Run(out, errOut *strings.Builder, root string, args []string, live func(string)) int {
	if len(args) < 2 {
		errOut.WriteString("使い方: fge pxkit build|watch|snap <名前>.spritesrc.json [--new]\n" +
			"        fge pxkit restore <名前>.spritesrc.json rN   （その周の spec に戻す）\n")
		return 2
	}
	verb, spec := args[0], args[1]
	switch verb {
	case "build":
		return report(out, errOut, root, spec)
	case "watch":
		return watch(root, spec, live)
	case "snap":
		return snap(out, errOut, root, spec, len(args) > 2 && args[2] == "--new")
	case "restore":
		if len(args) < 3 {
			errOut.WriteString("使い方: fge pxkit restore <spec> rN\n")
			return 2
		}
		return restore(out, errOut, root, spec, args[2])
	}
	fmt.Fprintf(errOut, "知らない動詞 %q（build / watch / snap）\n", verb)
	return 2
}

func report(out, errOut *strings.Builder, root, spec string) int {
	res, err := Build(root, spec, true)
	if err != nil {
		fmt.Fprintf(errOut, "pxkit: %v\n", err)
		return 1
	}
	same, changed, added := 0, 0, 0
	for _, f := range res.Frames {
		switch {
		case !f.HadBase:
			added++
		case f.Same:
			same++
		default:
			changed++
			fmt.Fprintf(out, "  変わった: %s/%s\n", f.Sprite, f.Name)
		}
	}
	fmt.Fprintf(out, "pxkit: %d コマ（base と同じ %d・変わった %d・新しい %d）→ %s（%d ms）\n",
		len(res.Frames), same, changed, added, res.Target, res.Elapsed.Milliseconds())
	fmt.Fprintf(out, "見本: %s\n", rel(root, res.Sheet))
	for _, l := range res.Lint.Ramp {
		fmt.Fprintln(out, "  ランプ: "+l)
	}
	fmt.Fprintf(out, "  検査（bin/fge sprite と同じ規則・描く前と比べて）: 増えた %d・消えた %d・残った %d\n",
		len(res.Lint.Added), len(res.Lint.Removed), len(res.Lint.Kept))
	for _, l := range res.Lint.Added {
		fmt.Fprintln(out, "    + "+l)
	}
	for _, l := range res.Lint.Removed {
		fmt.Fprintln(out, "    - "+l)
	}
	return 0
}

// watch は spec の更新を 100ms ごとに見て、変わったら build する。止めるまで戻らない。
func watch(root, spec string, live func(string)) int {
	var last time.Time
	for {
		st, err := os.Stat(spec)
		if err == nil && st.ModTime() != last {
			last = st.ModTime()
			var out, errOut strings.Builder
			report(&out, &errOut, root, spec)
			live(out.String() + errOut.String())
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// maxRounds は作り直しの上限（drawing.md の絵の周回: 最大 5 周）。
const maxRounds = 5

// snap は今の見本と spec を debug/history/<名前>/rN.{png,spritesrc.json} に積み、前の周と横に並べた
// compare.png を作る。周ごとに依頼主へ聞くことを出す（drawing.md の絵の周回の決まり）。
// --new は前の周回を old-<時刻>/ へ退けて r1 から始める（別の作業の続き番号にしない）。
func snap(out, errOut *strings.Builder, root, spec string, fresh bool) int {
	dir := filepath.Join(root, "debug", "history", specName(spec))
	if fresh {
		if _, err := os.Stat(dir); err == nil {
			old := filepath.Join(dir+"-old", time.Now().Format("20060102-150405"))
			_ = os.MkdirAll(filepath.Dir(old), 0o755)
			if err := os.Rename(dir, old); err != nil {
				fmt.Fprintln(errOut, err)
				return 1
			}
			fmt.Fprintf(out, "前の周回は %s へ退けた\n", rel(root, old))
		}
	}
	n := 1
	for ; ; n++ {
		if _, err := os.Stat(filepath.Join(dir, fmt.Sprintf("r%d.png", n))); err != nil {
			break
		}
	}
	if n > maxRounds {
		fmt.Fprintf(errOut, "pxkit: %d 周を超える。作り直しは最大 %d 周（drawing.md）。依頼主に終わりを聞くか、--new で別の作業として始める\n", maxRounds, maxRounds)
		return 1
	}
	res, err := Build(root, spec, false)
	if err != nil {
		fmt.Fprintf(errOut, "pxkit: %v\n", err)
		return 1
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	cur := filepath.Join(dir, fmt.Sprintf("r%d.png", n))
	data, _ := os.ReadFile(res.Sheet)
	src, _ := os.ReadFile(spec)
	if err := os.WriteFile(cur, data, 0o644); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	_ = os.WriteFile(filepath.Join(dir, fmt.Sprintf("r%d.spritesrc.json", n)), src, 0o644)
	fmt.Fprintf(out, "周: %s（spec も同じ番号で保存）\n", rel(root, cur))
	if n > 1 {
		prev := filepath.Join(dir, fmt.Sprintf("r%d.png", n-1))
		cmp := filepath.Join(dir, "compare.png")
		if err := sideBySide(prev, cur, cmp); err == nil {
			fmt.Fprintf(out, "比べ絵（左 r%d・右 r%d・実寸と 4 倍）: %s\n", n-1, n, rel(root, cmp))
		}
	}
	switch {
	case n == 2:
		fmt.Fprintln(out, "r2: ここで止める。依頼主に「①r1 と r2 のどちらが良いか ②続けるか終わりか ③続けるなら直す所を 1 つ」だけ聞き、返事まで r3 を描かない")
	case n > 2:
		fmt.Fprintf(out, "r%d: 依頼主に「①r%d と r%d のどちらが良いか」を聞く。前が良ければ fge pxkit restore %s r%d で戻す\n", n, n-1, n, spec, n-1)
	}
	return 0
}

// restore は debug/history に積んだ周の spec を、今の spec へ書き戻す。
func restore(out, errOut *strings.Builder, root, spec, round string) int {
	src := filepath.Join(root, "debug", "history", specName(spec), round+".spritesrc.json")
	data, err := os.ReadFile(src)
	if err != nil {
		fmt.Fprintf(errOut, "pxkit: %s が無い\n", rel(root, src))
		return 1
	}
	if err := os.WriteFile(spec, data, 0o644); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	fmt.Fprintf(out, "%s を %s の spec に戻した（build で描き直す）\n", spec, round)
	return 0
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

func rel(root, p string) string {
	if r, err := filepath.Rel(root, p); err == nil {
		return r
	}
	return p
}
