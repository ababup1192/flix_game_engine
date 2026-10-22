package refactor

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// change-case-shape と change-signature が共有する所: 名前の直後の引数の並び `(a, b)` を読む・並びに 1 つ足す/消す・
// 式の中で名前として使われている所を探す・小さな式（テンプレート）の名前を呼ぶ所の引数の式で置き換える。
//
// どこを替えるか（作る所・当てる所・呼ぶ所と、その引数の数・関数として渡しているか）は索引（def-use・case-construct・
// case-pattern と flixlint 0.7.1 の arg の行）で決め、引数 1 つずつの範囲はソースの字で読む。
// WhyNot: arg の行の範囲をそのまま使わないのは、コンパイラの record の式の範囲が `{` でなく最初の欄から始まるため
// （`f({ a = 1 })` の引数が `a = 1 }` になる）。並びは名前の直後の `(` から括弧の深さで切り、数を索引の n と比べる。
//
// ここの関数は純粋（ファイルの中身は呼ぶ側が渡す）。

// KindArg は索引の arg の行（呼び出し・作る case・当てる case の引数 1 つ）。
const KindArg = "arg"

// ArgList は名前の直後の `( … )` の引数の並び（位置は中身のバイト）。
type ArgList struct {
	Open, Close int      // `(` と `)` の位置
	Args        [][2]int // 引数 1 つずつの [始まり, 終わり)（前後の空白を除く）
}

// argsAfter は src の nameEnd（名前の終わり）の直後の `( … )` を読む。直後が `(` でなければ ok=false（引数の無い形）。
// `()`（Unit を渡す呼び出し）は引数 0 の並び。
func argsAfter(src string, nameEnd int) (ArgList, bool, error) {
	if nameEnd >= len(src) || src[nameEnd] != '(' {
		return ArgList{}, false, nil
	}
	l := ArgList{Open: nameEnd}
	i := nameEnd + 1
	if j := skipBlank(src, i); j < len(src) && src[j] == ')' {
		l.Close = j
		return l, true, nil
	}
	for {
		stop, at, err := scanTop(src, i, ",)")
		if err != nil {
			return l, true, fmt.Errorf("引数の並びが読めない: %v", err)
		}
		s, e := trimSpan(src, i, at)
		l.Args = append(l.Args, [2]int{s, e})
		if stop == ')' {
			l.Close = at
			return l, true, nil
		}
		i = at + 1
	}
}

// trimSpan は src[s:e] の前後の空白と行のコメントを除いた範囲。
func trimSpan(src string, s, e int) (int, int) {
	s = skipBlank(src, s)
	if s > e {
		return e, e
	}
	t := src[s:e]
	for {
		u := strings.TrimRight(t, " \t\r\n")
		ls := strings.LastIndexByte(u, '\n') + 1
		if c := commentStart(u[ls:]); c >= 0 {
			t = u[:ls+c]
			continue
		}
		return s, s + len(u)
	}
}

// listEdit は引数の並びへの 1 つの書き換え（足す・消す）。名前の直後に並びが無い時（has=false）も扱う。
// 返すのは [start, end) を repl に替える事。
func listEdit(src string, nameEnd int, l ArgList, has bool, add bool, at int, text string) (int, int, string, error) {
	n := len(l.Args)
	if add {
		switch {
		case !has || n == 0:
			if has {
				return l.Open, l.Close + 1, "(" + text + ")", nil
			}
			return nameEnd, nameEnd, "(" + text + ")", nil
		case at < n:
			return l.Args[at][0], l.Args[at][0], text + ", ", nil
		default:
			return l.Args[n-1][1], l.Args[n-1][1], ", " + text, nil
		}
	}
	if !has || at >= n {
		return 0, 0, "", fmt.Errorf("消す %d 番目の引数が無い（%d 個）", at, n)
	}
	switch {
	case n == 1:
		return nameEnd, l.Close + 1, "", nil
	case at < n-1:
		return l.Args[at][0], l.Args[at+1][0], "", nil
	default:
		return l.Args[at-1][1], l.Args[at][1], "", nil
	}
}

// splitTop は "a, f(b, c), d" を深さ 0 の , で切る（前後の空白を除く）。空なら空の列。
func splitTop(s string) ([]string, error) {
	if strings.TrimSpace(s) == "" {
		return nil, nil
	}
	var out []string
	i := 0
	t := s + ")"
	for {
		stop, at, err := scanTop(t, i, ",)")
		if err != nil {
			return nil, fmt.Errorf("%q が読めない: %v", s, err)
		}
		out = append(out, strings.TrimSpace(t[i:at]))
		if stop == ')' {
			if at != len(s) {
				return nil, fmt.Errorf("%q の括弧が合わない", s)
			}
			return out, nil
		}
		i = at + 1
	}
}

// identUses は text の中で names のどれかを「名前として使う」所（[始まり, 終わり)）を返す。数えない物:
// 選択と修飾の後（`x#w`・`M.w`）・record の欄の名前（`{ w = …`・`, w = …`）・文字列とコメントの中
// （文字列の `${ … }` の中は式なので数える）。束ね直し（`let w = …`・`w -> …`）も使う所に数える（安全な側）。
func identUses(text string, names map[string]bool) [][2]int {
	var out [][2]int
	var scan func(from, to int)
	scan = func(from, to int) {
		for i := from; i < to; i++ {
			c := text[i]
			switch {
			case c == '"':
				j := i + 1
				for j < to && text[j] != '"' {
					switch {
					case text[j] == '\\':
						j++
					case text[j] == '$' && j+1 < to && text[j+1] == '{':
						if _, at, err := scanTop(text[:to], j+2, "}"); err == nil {
							scan(j+2, at)
							j = at
						}
					}
					j++
				}
				i = j
			case c == '\'' && i+2 < to && text[i+2] == '\'':
				i += 2
			case c == '\'' && i+3 < to && text[i+1] == '\\' && text[i+3] == '\'':
				i += 3
			case c == '/' && i+1 < to && text[i+1] == '/':
				for i < to && text[i] != '\n' {
					i++
				}
			case c == '/' && i+1 < to && text[i+1] == '*':
				k := strings.Index(text[i+2:to], "*/")
				if k < 0 {
					return
				}
				i += k + 3
			case identByte(c) && (i == 0 || !identByte(text[i-1])):
				j := i
				for j < to && identByte(text[j]) {
					j++
				}
				word := text[i:j]
				if names[word] && !isQualified(text, i) && !isLabel(text, i, j) {
					out = append(out, [2]int{i, j})
				}
				i = j - 1
			}
		}
	}
	scan(0, len(text))
	return out
}

// isQualified は text[i] の名前が `.`・`#` の後か（修飾の後ろ・欄の選択）。
func isQualified(text string, i int) bool {
	return i > 0 && (text[i-1] == '.' || text[i-1] == '#')
}

// isLabel は text[i:j] が record の欄の名前（前が `{` か `,`・後が `=`（`==`・`=>` でない））か。
func isLabel(text string, i, j int) bool {
	k := skipSpace(text, j)
	if k >= len(text) || text[k] != '=' || (k+1 < len(text) && (text[k+1] == '=' || text[k+1] == '>')) {
		return false
	}
	p := i - 1
	for p >= 0 && (text[p] == ' ' || text[p] == '\t' || text[p] == '\n' || text[p] == '\r') {
		p--
	}
	return p >= 0 && (text[p] == '{' || text[p] == ',')
}

var simpleExpr = regexp.MustCompile(`^(?:[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*(?:#[A-Za-z_]\w*)*|-?\d[\w.]*|true|false|\(\)|'(?:\\.|[^'\\])'|"[^"$\\]*")$`)

// isSimple は式が名前・修飾名・欄の選択の連なり・字の値（数・真偽・文字列）だけか（2 回書いても同じ値で、括弧が要らない）。
func isSimple(e string) bool { return simpleExpr.MatchString(strings.TrimSpace(e)) }

// Substitute は template の中の old の名前（の使う所）を、vals の同じ番号の式で置き換える。式が名前より大きい物で、
// template がその名前だけでなければ括弧で包む。
func Substitute(template string, old []string, vals []string) string {
	idx := map[string]int{}
	names := map[string]bool{}
	for i, n := range old {
		idx[n], names[n] = i, true
	}
	uses := identUses(template, names)
	out := template
	for k := len(uses) - 1; k >= 0; k-- {
		u := uses[k]
		v := strings.TrimSpace(vals[idx[template[u[0]:u[1]]]])
		if !isSimple(v) && !(u[0] == 0 && u[1] == len(template)) && !wholeArg(template, u[0], u[1]) {
			v = "(" + v + ")"
		}
		out = out[:u[0]] + v + out[u[1]:]
	}
	return out
}

// wholeArg は text[s:e] が引数 1 つまるごとか（前が `(`・`,`、後が `,`・`)`。間の空白は問わない）。その時は括弧が要らない。
func wholeArg(text string, s, e int) bool {
	p := s - 1
	for p >= 0 && (text[p] == ' ' || text[p] == '\t' || text[p] == '\n') {
		p--
	}
	n := skipSpace(text, e)
	return p >= 0 && (text[p] == '(' || text[p] == ',') && n < len(text) && (text[n] == ',' || text[n] == ')')
}

// countUses は templates の中で old の名前それぞれが使われる数。
func countUses(templates, old []string) map[string]int {
	names := map[string]bool{}
	for _, n := range old {
		names[n] = true
	}
	n := map[string]int{}
	for _, t := range templates {
		for _, u := range identUses(t, names) {
			n[t[u[0]:u[1]]]++
		}
	}
	return n
}

// exprPattern は式 e を、字の間の空白を問わずに探す正規表現（名前の途中・修飾・選択の後ろには当てない）。
func exprPattern(e string) *regexp.Regexp {
	var toks []string
	for i := 0; i < len(e); {
		c := e[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i++
		case identByte(c):
			j := i
			for j < len(e) && identByte(e[j]) {
				j++
			}
			toks = append(toks, regexp.QuoteMeta(e[i:j]))
			i = j
		default:
			toks = append(toks, regexp.QuoteMeta(string(c)))
			i++
		}
	}
	pat := strings.Join(toks, `\s*`)
	if identByte(e[0]) {
		pat = `(?:^|[^\w.#])(` + pat + `)`
	} else {
		pat = `(` + pat + `)`
	}
	if identByte(e[len(e)-1]) {
		pat += `(?:\W|$)`
	}
	return regexp.MustCompile(pat)
}

// replaceExpr は text の中の式 e（空白の違いは問わない）を全部 name に替えた字と、替えた数。
func replaceExpr(text, e, name string) (string, int) {
	re := exprPattern(e)
	n := 0
	var b strings.Builder
	last := 0
	atoms := atomicSpans(text)
	for _, m := range re.FindAllStringSubmatchIndex(text, -1) {
		if splitsAtom(atoms, m[2], m[3]) {
			continue
		}
		b.WriteString(text[last:m[2]])
		b.WriteString(name)
		last = m[3]
		n++
	}
	b.WriteString(text[last:])
	return b.String(), n
}

// dropSelfLets は `let x = x;`（引数にした式を let で先に書いた形の名残り）を行ごと消す。
func dropSelfLets(text string, names []string) string {
	for _, n := range names {
		q := regexp.QuoteMeta(n)
		text = regexp.MustCompile(`(?m)^[ \t]*let\s+`+q+`\s*=\s*`+q+`\s*;[ \t]*\r?\n`).ReplaceAllString(text, "")
		text = regexp.MustCompile(`\blet\s+`+q+`\s*=\s*`+q+`\s*;\s*`).ReplaceAllString(text, "")
	}
	return text
}

// shiftEdits は edits のうち [from, to) の中に収まる物を、from を 0 とする位置へずらした写し。
func shiftEdits(edits []Edit, file string, from, to int) []Edit {
	var out []Edit
	for _, e := range edits {
		if e.File == file && e.Start >= from && e.End <= to {
			c := e
			c.Start -= from
			c.End -= from
			out = append(out, c)
		}
	}
	return out
}

// argRowsAt は索引の arg の行を「of の種類 file sl:sc」ごとにまとめる（引数の数 n と、作り出された引数があるか）。
type argInfo struct {
	N     int
	Synth bool
}

func argRowsAt(rows []Row) map[string]argInfo {
	out := map[string]argInfo{}
	for _, r := range rows {
		if r.Kind != KindArg {
			continue
		}
		k := r.Attr("of") + " " + r.File + " " + r.Attr("at")
		a := out[k]
		a.N = r.AttrInt("n")
		if strings.Contains(" "+r.Extra+" ", " synth ") {
			a.Synth = true
		}
		out[k] = a
	}
	return out
}

func argKey(kind string, r Row) string {
	return fmt.Sprintf("%s %s %d:%d", kind, r.File, r.Line, r.Col)
}

// sortedFixed は場所の順に並べた写し。
func sortedFixed(f []Fixed) []Fixed {
	out := append([]Fixed{}, f...)
	sort.Slice(out, func(i, j int) bool { return less(out[i].Row, out[j].Row) })
	return out
}

// reshapeSources は行のファイルを読む（読んだ物は使い回す）。
type reshapeSources struct {
	root string
	m    map[string]string
}

func (s *reshapeSources) get(f string) (string, error) {
	if t, ok := s.m[f]; ok {
		return t, nil
	}
	b, err := os.ReadFile(filepath.Join(s.root, f))
	if err != nil {
		return "", err
	}
	s.m[f] = string(b)
	return s.m[f], nil
}

// atomicSpans は字の中の、途中で切って当ててはいけない字句の範囲（数の字・字の値の字の部分・文字の値・コメント）。
// 字の補間（"a${x}b"）の ${ } の中はコードなので範囲に入れない（その前後の "a${ と }b" が 1 つずつ）。
//
// WhyNot: 正規表現の境（`(?:\W|$)`）だけでは、`0` が `0.0` の頭に、名前が字の値・コメントの中に当たる
// （change-signature の --args '…, 0' で本体の List.foldLeft(…, 0.0) が `_probe.0` の形になった）。
func atomicSpans(text string) [][2]int {
	var out [][2]int
	digit := func(c byte) bool { return c >= '0' && c <= '9' }
	var scan func(from, to int)
	scan = func(from, to int) {
		for i := from; i < to; i++ {
			c := text[i]
			switch {
			case c == '"':
				start := i
				j := i + 1
				for j < to && text[j] != '"' {
					switch {
					case text[j] == '\\':
						j++
					case text[j] == '$' && j+1 < to && text[j+1] == '{':
						if _, at, err := scanTop(text[:to], j+2, "}"); err == nil {
							out = append(out, [2]int{start, j + 2})
							scan(j+2, at)
							start, j = at, at
						}
					}
					j++
				}
				out = append(out, [2]int{start, min(j+1, to)})
				i = j
			case c == '\'' && i+2 < to && text[i+2] == '\'':
				out = append(out, [2]int{i, i + 3})
				i += 2
			case c == '\'' && i+3 < to && text[i+1] == '\\' && text[i+3] == '\'':
				out = append(out, [2]int{i, i + 4})
				i += 3
			case c == '/' && i+1 < to && text[i+1] == '/':
				j := i
				for j < to && text[j] != '\n' {
					j++
				}
				out = append(out, [2]int{i, j})
				i = j
			case c == '/' && i+1 < to && text[i+1] == '*':
				k := strings.Index(text[i+2:to], "*/")
				if k < 0 {
					out = append(out, [2]int{i, to})
					return
				}
				out = append(out, [2]int{i, i + k + 4})
				i += k + 3
			case digit(c) && (i == 0 || !identByte(text[i-1])):
				j := i
				for j < to && (identByte(text[j]) || (text[j] == '.' && j+1 < to && digit(text[j+1]))) {
					// 指数の符号（1.0e-3）
					if (text[j] == 'e' || text[j] == 'E') && j+2 < to && (text[j+1] == '-' || text[j+1] == '+') && digit(text[j+2]) {
						j += 2
					}
					j++
				}
				out = append(out, [2]int{i, j})
				i = j - 1
			case identByte(c):
				for i+1 < to && identByte(text[i+1]) {
					i++
				}
			}
		}
	}
	scan(0, len(text))
	return out
}

// splitsAtom は当たり [s, e) が字句（atomicSpans）を途中で切るか、その中にだけあるか（字句を丸ごと含む・触れない時は false）。
func splitsAtom(atoms [][2]int, s, e int) bool {
	for _, a := range atoms {
		if a[0] < e && s < a[1] && !(s <= a[0] && a[1] <= e) {
			return true
		}
	}
	return false
}
