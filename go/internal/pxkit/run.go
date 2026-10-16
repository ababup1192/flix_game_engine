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
		errOut.WriteString("使い方: fge pxkit build|watch|snap <名前>.spritesrc.json\n")
		return 2
	}
	verb, spec := args[0], args[1]
	switch verb {
	case "build":
		return report(out, errOut, root, spec)
	case "watch":
		return watch(root, spec, live)
	case "snap":
		return snap(out, errOut, root, spec)
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
	for _, l := range res.Lint {
		fmt.Fprintln(out, "  検査: "+l)
	}
	if len(res.Lint) == 0 {
		fmt.Fprintln(out, "  検査: base から増えた注意なし（bin/fge sprite と同じ規則）")
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

// snap は今の見本を debug/history/<名前>/rN.png に積み、前の周と横に並べた compare.png を作る。
func snap(out, errOut *strings.Builder, root, spec string) int {
	res, err := Build(root, spec, false)
	if err != nil {
		fmt.Fprintf(errOut, "pxkit: %v\n", err)
		return 1
	}
	dir := filepath.Join(root, "debug", "history", specName(spec))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	n := 1
	for ; ; n++ {
		if _, err := os.Stat(filepath.Join(dir, fmt.Sprintf("r%d.png", n))); err != nil {
			break
		}
	}
	cur := filepath.Join(dir, fmt.Sprintf("r%d.png", n))
	data, _ := os.ReadFile(res.Sheet)
	if err := os.WriteFile(cur, data, 0o644); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	fmt.Fprintf(out, "周: %s\n", rel(root, cur))
	if n > 1 {
		prev := filepath.Join(dir, fmt.Sprintf("r%d.png", n-1))
		cmp := filepath.Join(dir, "compare.png")
		if err := sideBySide(prev, cur, cmp); err == nil {
			fmt.Fprintf(out, "比べ絵（左 r%d・右 r%d）: %s\n", n-1, n, rel(root, cmp))
		}
	}
	if n >= 2 {
		fmt.Fprintln(out, "r2 まで来た: ここで止めて依頼主に「①どちらが良いか ②続けるか ③直す所を 1 つ」を聞く（drawing.md の周回の決まり）")
	}
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
