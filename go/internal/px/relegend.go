package px

// relegend: sprite.json の legend の印を、画素はそのままに ASCII の表示できる字から振り直す（印に使えない字を外す）。
// 使える ASCII の字はそのまま残し、それ以外の字（右から左へ書く字・ギリシャ文字など）だけを空いている字へ移す
// （ASCII が尽きた時だけ pxlib.LegendPool の決まった並びで広げる）。書く前に、全部のコマの画素の色キーが同じかを確かめる。

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// relegendDoc は doc の legend と rows の印を振り直す。返すのは 旧 → 新 の字（変えた物だけ）。
func relegendDoc(doc *pxlib.Obj) (map[string]string, error) {
	lv, _ := doc.Get("legend")
	legend, ok := lv.(*pxlib.Obj)
	if !ok {
		return nil, fmt.Errorf("legend が無い")
	}
	chars, vals := legend.Items()
	used := map[rune]bool{}
	keep := map[string]bool{}
	for _, ch := range chars {
		rs := []rune(ch)
		if len(rs) == 1 && rs[0] < 0x7F && pxlib.LegendCharProblem(rs[0]) == "" && rs[0] != '"' && rs[0] != '\\' {
			keep[ch] = true
			used[rs[0]] = true
		}
	}
	moves := map[string]string{}
	next := 0
	for _, ch := range chars {
		if keep[ch] {
			continue
		}
		for next < len(pxlib.LegendPool) && used[pxlib.LegendPool[next]] {
			next++
		}
		if next >= len(pxlib.LegendPool) {
			return nil, fmt.Errorf("印が足りない（%d 字まで）", len(pxlib.LegendPool))
		}
		r := pxlib.LegendPool[next]
		used[r] = true
		moves[ch] = string(r)
	}
	if len(moves) == 0 {
		return moves, nil
	}
	// legend を同じ並びで書き直す
	nl := pxlib.NewObj()
	for i, ch := range chars {
		if to, ok := moves[ch]; ok {
			nl.Set(to, vals[i])
		} else {
			nl.Set(ch, vals[i])
		}
	}
	doc.Set("legend", nl)
	sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
	if sprites == nil {
		return moves, nil
	}
	_, svals := sprites.Items()
	for _, sv := range svals {
		so, _ := sv.(*pxlib.Obj)
		if so == nil {
			continue
		}
		frames, _ := so.GetOr("frames", nil).(*pxlib.Obj)
		if frames == nil {
			continue
		}
		fnames, fvals := frames.Items()
		for i, fn := range fnames {
			rows := strs(fvals[i])
			out := make([]any, len(rows))
			for y, row := range rows {
				var b strings.Builder
				for _, r := range row {
					if to, ok := moves[string(r)]; ok {
						b.WriteString(to)
					} else {
						b.WriteRune(r)
					}
				}
				out[y] = b.String()
			}
			frames.Set(fn, out)
		}
	}
	return moves, nil
}

// sameKeys は 2 つの doc の全部のコマの画素の色キーが同じか（印だけが違う）。
func sameKeys(a, b *pxlib.Obj) error {
	la, _ := a.Get("legend")
	lb, _ := b.Get("legend")
	ka, kb := pxlib.LegendOf(la).KeyOf, pxlib.LegendOf(lb).KeyOf
	sa, _ := a.GetOr("sprites", nil).(*pxlib.Obj)
	sb, _ := b.GetOr("sprites", nil).(*pxlib.Obj)
	if sa == nil || sb == nil {
		return nil
	}
	names, avals := sa.Items()
	for i, n := range names {
		fa, _ := avals[i].(*pxlib.Obj).GetOr("frames", nil).(*pxlib.Obj)
		bo, _ := sb.GetOr(n, nil).(*pxlib.Obj)
		if fa == nil || bo == nil {
			continue
		}
		fb, _ := bo.GetOr("frames", nil).(*pxlib.Obj)
		fnames, fvals := fa.Items()
		for j, fn := range fnames {
			ga, _ := pxlib.GridFromRows(strs(fvals[j]), ka)
			gb, _ := pxlib.GridFromRows(strs(fb.GetOr(fn, nil)), kb)
			if ga.W != gb.W || ga.H != gb.H {
				return fmt.Errorf("%s/%s の大きさが変わった", n, fn)
			}
			for y := 0; y < ga.H; y++ {
				for x := 0; x < ga.W; x++ {
					if ga.At(x, y) != gb.At(x, y) {
						return fmt.Errorf("%s/%s の (%d,%d) の色キーが変わった", n, fn, x, y)
					}
				}
			}
		}
	}
	return nil
}

// cmdRelegend は sprite.json の印を振り直す（--write で書く。書かない時は振り直す字の一覧だけ）。
func cmdRelegend(out, errOut *strings.Builder, workRoot string, paths []string, write bool) int {
	for _, p := range paths {
		full := p
		if !filepath.IsAbs(full) {
			full = filepath.Join(workRoot, p)
		}
		data, err := os.ReadFile(full)
		if err != nil {
			fmt.Fprintf(errOut, "px relegend: %v\n", err)
			return 1
		}
		before, err := pxlib.DecodeOrdered(data)
		if err != nil {
			fmt.Fprintf(errOut, "px relegend: %s: %v\n", p, err)
			return 1
		}
		doc, _ := pxlib.DecodeOrdered(data)
		moves, err := relegendDoc(doc.(*pxlib.Obj))
		if err != nil {
			fmt.Fprintf(errOut, "px relegend: %s: %v\n", p, err)
			return 1
		}
		if len(moves) == 0 {
			fmt.Fprintf(out, "%s: 振り直す印は無い\n", p)
			continue
		}
		if err := sameKeys(before.(*pxlib.Obj), doc.(*pxlib.Obj)); err != nil {
			fmt.Fprintf(errOut, "px relegend: %s: 画素が変わるので書かない: %v\n", p, err)
			return 1
		}
		var pairs []string
		for _, ch := range pxlib.LegendOf(before.(*pxlib.Obj).GetOr("legend", nil)).Chars {
			if to, ok := moves[ch]; ok {
				pairs = append(pairs, ch+"→"+to)
			}
		}
		fmt.Fprintf(out, "%s: 印 %d 字を振り直す（画素の色キーは全部のコマで同じ）: %s\n", p, len(moves), strings.Join(pairs, " "))
		if write {
			if err := os.WriteFile(full, []byte(pxlib.ToJSON(doc, sourceIndent(data))), 0o644); err != nil {
				fmt.Fprintf(errOut, "px relegend: %v\n", err)
				return 1
			}
		}
	}
	if !write {
		out.WriteString("（書くのは --write）\n")
	}
	return 0
}

// sourceIndent は元の字下げ（タブか空白の数）。
func sourceIndent(data []byte) string {
	s := string(data)
	if i := strings.Index(s, "\n"); i >= 0 && i+1 < len(s) {
		rest := s[i+1:]
		n := 0
		for n < len(rest) && (rest[n] == ' ' || rest[n] == '\t') {
			n++
		}
		if n > 0 {
			return rest[:n]
		}
	}
	return "  "
}
