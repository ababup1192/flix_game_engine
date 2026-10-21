package refactor

import (
	"strings"
	"unicode/utf8"
)

// 汎用の AST の式の範囲を、書き替えに使える字の範囲に揃える所（rewrite・extract-function が読む前に 1 回）。
//
// flixlint の範囲は Flix の位置のままで、record の式は字の上の { 〜 } と合わない:
//   - `{ x = a, y = b }`（作る）は最初の欄から閉じかっこまで。開きかっこ { を含まない
//     （Flix は欄ごとの RecordExtend に分け、欄の位置から式の終わりまでを範囲にする）。
//   - `{ x = a | r }`（欄を替える）・`{ -x | r }`（欄を外す）は最初の欄から r まで。{ も } も含まない。
//
// 範囲の字をそのまま写す書き替え（穴の字・def の本体・呼ぶ所の置き換え）は、かっこが片方だけ写って崩れる。
// ここで record の式の頭の節（欄ごとの節の一番外）の範囲を、字の上の { 〜 } に広げる。欄ごとの内側の節
// （`y = b }` の範囲）は字の上の式でないので、recordTail で式の候補から外す。
//
// ほかの括弧で囲む式（tuple・リスト・match・if・呼び出し）は範囲に括弧を含む（internet_dungeon の全部の式で
// かっこの釣り合いを数えて確かめた）。字の補間（"a${x}b"）は構文の作った節（synthetic）が全体の範囲を持ち、
// 字の値の切れ端（`"a${`・`}b"`）が構文の作っていない Expr.Cst になる。切れ端は写せないので、書き出しの前に
// balancedExpr で止める（人へ回す）。

// recordTail は n が record の式の欄ごとの内側の節（親の record の式の続き）か。字の上の式ではない。
func (a *Ast) recordTail(n int32) bool {
	if !isRecordKind(a.KindOf(n)) {
		return false
	}
	p := a.Parent[n]
	if p < 0 {
		return false
	}
	switch a.KindOf(p) {
	case "Expr.RecordExtend":
		return a.SlotOf(n) == "exp2"
	case "Expr.RecordRestrict":
		return a.SlotOf(n) == "exp"
	}
	return false
}

func isRecordKind(k string) bool { return k == "Expr.RecordExtend" || k == "Expr.RecordRestrict" }

// alignSpans は record の式の頭の節の範囲を、字の上の { 〜 } に広げる（2 度目は何もしない）。
func (a *Ast) alignSpans(srcs *reshapeSources) {
	if a.aligned {
		return
	}
	a.aligned = true
	files := map[string]*lineIndex{}
	for _, kind := range []string{"Expr.RecordExtend", "Expr.RecordRestrict"} {
		for _, n := range a.OfKind(kind) {
			if a.Synth[n] != 0 || a.recordTail(n) {
				continue
			}
			f := a.File(n)
			li, ok := files[f]
			if !ok {
				if src, err := srcs.get(f); err == nil {
					li = newLineIndex(src)
				}
				files[f] = li
			}
			if li == nil {
				continue
			}
			s, ok1 := li.byteAt(int(a.Line[n]), int(a.Col[n]))
			e, ok2 := li.byteAt(int(a.EndLine[n]), int(a.EndCol[n]))
			if !ok1 || !ok2 || s > e {
				continue
			}
			ns, ne := widenBraces(li.src, s, e)
			if ns == s && ne == e {
				continue
			}
			l, c := li.posAt(ns)
			el, ec := li.posAt(ne)
			a.Line[n], a.Col[n], a.EndLine[n], a.EndCol[n] = int32(l), int32(c), int32(el), int32(ec)
		}
	}
}

// widenBraces は record の式の字 src[s:e] を、前の { と（中の { が閉じていなければ）後ろの } まで広げる。
// 間の空白・改行・行のコメントは飛ばす。かっこが見つからなければ広げない。
func widenBraces(src string, s, e int) (int, int) {
	if !strings.HasPrefix(src[s:e], "{") {
		if i, ok := braceBefore(src, s); ok {
			s = i
		} else {
			return s, e
		}
	}
	if depth, _ := bracketBalance(src[s:e]); depth > 0 {
		if j, ok := braceAfter(src, e); ok {
			e = j + 1
		}
	}
	return s, e
}

// braceBefore は s の前（空白・空行・コメントだけの行を飛ばして）の { の位置。
func braceBefore(src string, s int) (int, bool) {
	ls := strings.LastIndexByte(src[:s], '\n') + 1
	head := strings.TrimRight(src[ls:s], " \t\r")
	for {
		if head != "" {
			if strings.HasSuffix(head, "{") {
				return ls + len(head) - 1, true
			}
			return 0, false
		}
		if ls == 0 {
			return 0, false
		}
		// 前の行（行のコメントを除いた字）。
		end := ls - 1
		ls = strings.LastIndexByte(src[:end], '\n') + 1
		line := src[ls:end]
		if k := lineCommentAt(line); k >= 0 {
			line = line[:k]
		}
		head = strings.TrimRight(line, " \t\r")
	}
}

// braceAfter は e の後ろ（空白・行のコメント・空行を飛ばして）の } の位置。
func braceAfter(src string, e int) (int, bool) {
	for i := e; i < len(src); {
		switch c := src[i]; {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			i++
		case strings.HasPrefix(src[i:], "//"):
			k := strings.IndexByte(src[i:], '\n')
			if k < 0 {
				return 0, false
			}
			i += k
		case c == '}':
			return i, true
		default:
			return 0, false
		}
	}
	return 0, false
}

// lineCommentAt は行の中の行のコメント // の位置（字の値の中は見ない。無ければ -1）。
func lineCommentAt(line string) int {
	inStr := false
	for i := 0; i < len(line); i++ {
		switch c := line[i]; {
		case inStr && c == '\\':
			i++
		case c == '"':
			inStr = !inStr
		case !inStr && c == '/' && i+1 < len(line) && line[i+1] == '/':
			return i
		}
	}
	return -1
}

// bracketBalance は式の字のかっこを数える。depth は閉じていない { の数（閉じすぎは負）、ok はかっこ（( [ {）・字の値・
// 字の補間（${ … }）が全部閉じて、閉じる側も合っているか。コメントと字の値の中のかっこは数えない。
func bracketBalance(s string) (depth int, ok bool) {
	ok = true
	var stack []byte // ( [ { と、字の値 " と字の補間 $
	top := func() byte {
		if len(stack) == 0 {
			return 0
		}
		return stack[len(stack)-1]
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if top() == '"' {
			switch {
			case c == '\\':
				i++
			case c == '"':
				stack = stack[:len(stack)-1]
			case c == '$' && i+1 < len(s) && s[i+1] == '{':
				stack = append(stack, '$')
				i++
			}
			continue
		}
		switch {
		case c == '/' && i+1 < len(s) && s[i+1] == '/':
			for i < len(s) && s[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			k := strings.Index(s[i+2:], "*/")
			if k < 0 {
				return depth, false
			}
			i += k + 3
		case c == '"':
			stack = append(stack, '"')
		case c == '\'':
			i = skipCharLit(s, i)
		case c == '(' || c == '[' || c == '{':
			stack = append(stack, c)
		case c == ')' || c == ']' || c == '}':
			open := map[byte]byte{')': '(', ']': '[', '}': '{'}[c]
			switch t := top(); {
			case t == open || (c == '}' && t == '$'):
				stack = stack[:len(stack)-1]
			case t == 0:
				ok = false
				if c == '}' {
					depth--
				}
			default:
				ok = false
			}
		}
	}
	for _, x := range stack {
		if x == '{' {
			depth++
		}
	}
	return depth, ok && len(stack) == 0
}

// skipCharLit は s[i] の ' が字の値（'a'・'\n'・'A'）の始まりなら、その終わりの ' の位置を返す（違えば i）。
func skipCharLit(s string, i int) int {
	if i+1 >= len(s) {
		return i
	}
	if s[i+1] == '\\' {
		if k := strings.IndexByte(s[i+2:min(len(s), i+12)], '\''); k >= 0 {
			return i + 2 + k
		}
		return i
	}
	_, size := utf8.DecodeRuneInString(s[i+1:])
	if j := i + 1 + size; j < len(s) && s[j] == '\'' {
		return j
	}
	return i
}

// balancedExpr は字が式 1 つとして写せるか（かっこ・字の値・字の補間が閉じている）。
func balancedExpr(s string) bool {
	_, ok := bracketBalance(s)
	return ok
}

// lineIndex はファイルの行の頭のバイトの位置（行・列 ⇔ バイトを何度も引く時に、ファイルを毎回割らない）。
type lineIndex struct {
	src    string
	starts []int
}

func newLineIndex(src string) *lineIndex {
	li := &lineIndex{src: src, starts: []int{0}}
	for i := 0; i < len(src); i++ {
		if src[i] == '\n' {
			li.starts = append(li.starts, i+1)
		}
	}
	return li
}

// byteAt は行・列（1 から・列は UTF-16）のバイトの位置。
func (li *lineIndex) byteAt(line, col int) (int, bool) {
	if line < 1 || line > len(li.starts) {
		return 0, false
	}
	end := len(li.src)
	if line < len(li.starts) {
		end = li.starts[line]
	}
	off, err := offset([]string{li.src[li.starts[line-1]:end]}, 1, col)
	if err != nil {
		return 0, false
	}
	return li.starts[line-1] + off, true
}

// posAt はバイトの位置の行・列（1 から・列は UTF-16）。
func (li *lineIndex) posAt(b int) (int, int) {
	lo, hi := 0, len(li.starts)-1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if li.starts[mid] <= b {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	col := 1
	for _, r := range li.src[li.starts[lo]:b] {
		col++
		if r > 0xFFFF {
			col++
		}
	}
	return lo + 1, col
}
