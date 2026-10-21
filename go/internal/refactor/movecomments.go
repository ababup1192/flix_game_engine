package refactor

import (
	"regexp"
	"sort"
	"strings"
)

// move の時、.flix のコメント（`///`・`//`・`/* */`）の中の古い名前（`Pointer.at` の Mod.name の形。` ` の中も地の文も）を
// 新しい名前へ書き替える所。コードの名前は索引の行で書き替えるが、コメントは索引に行が無いので字で探す。
//
// WhyNot: 素の名前（`at`）は書き替えない。コメントの地の文の短い語は別の物を指す事が多く、字だけでは決められない。
// 文書（.md）は書き替えず、数を知らせて doc-refs へ回す（文書の書き方は doc-refs の決まりが持つ）。

// commentRanges は .flix の字のコメントの範囲（バイトの [始まり, 終わり)。字の値の中は見ない）。
func commentRanges(src string) [][2]int {
	var out [][2]int
	inStr := false
	for i := 0; i < len(src); i++ {
		c := src[i]
		if inStr {
			if c == '\\' {
				i++
			} else if c == '"' {
				inStr = false
			}
			continue
		}
		switch {
		case c == '"':
			inStr = true
		case c == '\'':
			i = skipCharLit(src, i)
		case c == '/' && i+1 < len(src) && src[i+1] == '/':
			end := strings.IndexByte(src[i:], '\n')
			if end < 0 {
				end = len(src) - i
			}
			out = append(out, [2]int{i, i + end})
			i += end
		case c == '/' && i+1 < len(src) && src[i+1] == '*':
			end := strings.Index(src[i+2:], "*/")
			if end < 0 {
				out = append(out, [2]int{i, len(src)})
				return out
			}
			out = append(out, [2]int{i, i + 2 + end + 2})
			i += 2 + end + 1
		}
	}
	return out
}

// commentRename は古い名前 → 新しい名前の組（Mod.f → Mod2.f）。
type commentRename map[string]string

func (ren commentRename) pattern() *regexp.Regexp {
	olds := make([]string, 0, len(ren))
	for o := range ren {
		olds = append(olds, regexp.QuoteMeta(o))
	}
	// 長い名前から当てる（`A.f` と `A.fx` の両方を移す時）。
	sort.Slice(olds, func(i, j int) bool { return len(olds[i]) > len(olds[j]) })
	return regexp.MustCompile(`(?:^|[^\w.$#])(` + strings.Join(olds, "|") + `)\b`)
}

// hits は src のコメントの中の古い名前の所（バイトの [始まり, 終わり) の並び）。
func (ren commentRename) hits(src string) [][2]int {
	if len(ren) == 0 {
		return nil
	}
	re := ren.pattern()
	var out [][2]int
	for _, cr := range commentRanges(src) {
		text := src[cr[0]:cr[1]]
		for _, m := range re.FindAllStringSubmatchIndex(text, -1) {
			out = append(out, [2]int{cr[0] + m[2], cr[0] + m[3]})
		}
	}
	return out
}

// rewrite は src のコメントの中の古い名前を新しい名前にした字（移す宣言の本体の写しに使う）。
func (ren commentRename) rewrite(src string) string {
	hs := ren.hits(src)
	for i := len(hs) - 1; i >= 0; i-- {
		h := hs[i]
		src = src[:h[0]] + ren[src[h[0]:h[1]]] + src[h[1]:]
	}
	return src
}

// commentEdits は files（根からの相対 → 中身）のコメントの中の古い名前を書き替える書き替え。ほかの書き替え（edits）の
// 範囲と交わる所（移して消す宣言の中など）は書かない（移す本体は rewrite で写しの方を書き替える）。
func (ren commentRename) commentEdits(files map[string]string, edits []Edit) ([]Edit, map[string]int) {
	busy := map[string][]Edit{}
	for _, e := range edits {
		if e.Start < e.End {
			busy[e.File] = append(busy[e.File], e)
		}
	}
	var out []Edit
	perFile := map[string]int{}
	for _, f := range sortedKeys(files) {
		src := files[f]
		if !strings.HasSuffix(f, ".flix") {
			continue
		}
		li := newLineIndex(src)
		for _, h := range ren.hits(src) {
			overlap := false
			for _, e := range busy[f] {
				if e.Start < h[1] && h[0] < e.End {
					overlap = true
					break
				}
			}
			if overlap {
				continue
			}
			old := src[h[0]:h[1]]
			l, c := li.posAt(h[0])
			el, ec := li.posAt(h[1])
			at := Row{Kind: "comment", File: f, Line: l, Col: c, EndLine: el, EndCol: ec, Sym: old}
			repl := ren[old]
			out = append(out, Edit{File: f, Start: h[0], End: h[1], Site: at, Check: []Want{{Span: at, Text: old}},
				Make: func(string) (string, error) { return repl, nil }})
			perFile[f]++
		}
	}
	return out, perFile
}
