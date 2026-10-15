package quadratic

// 1 ファイルの本文から、fold (List.foldLeft / foldRight) の中で蓄積を作り直す形を拾う。
//
// 見るのは 2 つ:
//   - append: ラムダの本体で、蓄積 (またはそれをタプルで分解した別名・その欄) を List.append の
//     第 1 引数に置く。List.append は第 1 引数を丸ごと作り直すので、要素数の二乗になる
//   - string: 蓄積の文字列に 1 回ごとに足す ("${acc}…" / String.concat(acc, …) / acc + "…")、
//     または String.concat そのものをfold に渡す。1 回ごとに全体を作り直すので文字数の二乗になる
//
// 名前 (acc) では見ない。ラムダの仮引数のうち蓄積の側 (foldLeft は 1 つ目・foldRight は 2 つ目) を取る。
// ラムダでなく名前付きの関数を渡したfold は、本体が見えないので見ない。

import (
	"regexp"
	"strings"
)

var (
	foldRe  = regexp.MustCompile(`\b(?:List\.)?(foldLeft|foldRight)\s*\(`)
	identRe = regexp.MustCompile(`\b[a-z][A-Za-z0-9_]*\b`)
	defRe   = regexp.MustCompile(`\bdef\s+([a-zA-Z][A-Za-z0-9_]*)`)
)

// Hit は鳴らす 1 件。
type Hit struct {
	Path string
	Line int
	Def  string
	Kind string // "append" / "string"
	Acc  string // 作り直している蓄積の名前
}

func (h Hit) key() string { return h.Path + "::" + h.Def }

// blank は // のコメントを空白に置き換え、strings が true なら文字列の中身も空白に置き換える
// (長さと改行の位置は変えない)。
func blank(text string, strs bool) string {
	b := []byte(text)
	for i := 0; i < len(b); i++ {
		switch {
		case b[i] == '/' && i+1 < len(b) && b[i+1] == '/':
			for i < len(b) && b[i] != '\n' {
				b[i] = ' '
				i++
			}
		case b[i] == '"':
			i++
			for i < len(b) && b[i] != '"' && b[i] != '\n' {
				if b[i] == '\\' && i+1 < len(b) {
					if strs {
						b[i], b[i+1] = ' ', ' '
					}
					i += 2
					continue
				}
				if strs {
					b[i] = ' '
				}
				i++
			}
		}
	}
	return string(b)
}

// matching は open の位置の括弧に対応する閉じ括弧の位置。無ければ -1。
func matching(code string, open int) int {
	depth := 0
	for i := open; i < len(code); i++ {
		switch code[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// argEnd は呼び出しの括弧 open の中で、1 つ目の引数の終わり (深さ 0 のカンマか閉じ括弧)。
func argEnd(code string, open int) int {
	depth := 0
	for i := open + 1; i < len(code); i++ {
		switch code[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			if depth == 0 {
				return i
			}
			depth--
		case ',':
			if depth == 0 {
				return i
			}
		}
	}
	return len(code)
}

// splitTop は深さ 0 のカンマで分ける。
func splitTop(s string) []string {
	var out []string
	depth, from := 0, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, s[from:i])
				from = i + 1
			}
		}
	}
	return append(out, s[from:])
}

// lambdaOf は引数の文字列 (code 上の start から end) がラムダなら、仮引数の並びと本体の始まりを返す。
func lambdaOf(code string, start, end int) ([]string, int, bool) {
	i := start
	for i < end && (code[i] == ' ' || code[i] == '\n' || code[i] == '\t' || code[i] == '\r') {
		i++
	}
	if i >= end || code[i] != '(' {
		return nil, 0, false
	}
	close := matching(code, i)
	if close < 0 || close >= end {
		return nil, 0, false
	}
	rest := strings.TrimLeft(code[close+1:end], " \t\r\n")
	if !strings.HasPrefix(rest, "->") {
		return nil, 0, false
	}
	bodyStart := end - len(rest) + 2
	params := splitTop(code[i+1 : close])
	for k := range params {
		// 仮引数の型注釈 (acc: List[Int32]) は名前だけにする。
		if c := strings.Index(params[k], ":"); c >= 0 && !strings.Contains(params[k], "(") {
			params[k] = params[k][:c]
		}
	}
	return params, bodyStart, true
}

func names(pattern string) []string {
	var out []string
	for _, n := range identRe.FindAllString(pattern, -1) {
		if n != "_" {
			out = append(out, n)
		}
	}
	return out
}

func lineAt(text string, pos int) int { return 1 + strings.Count(text[:pos], "\n") }

func defAt(code string, pos int) string {
	name := "(トップ)"
	for _, m := range defRe.FindAllStringSubmatchIndex(code[:pos], -1) {
		name = code[m[2]:m[3]]
	}
	return name
}

// accTypes は蓄積の名前ごとの手がかり。str は初期値が文字列 ("…") だった名前、
// tuple は初期値がタプルだった名前とその要素 (分解した先の名前を位置で決めるため)。
type accTypes struct {
	str   map[string]bool
	tuple map[string][]string
}

func isStringLit(e string) bool { return strings.HasPrefix(strings.TrimSpace(e), "\"") }

// tupleElems はタプルの式 ( a, b ) なら要素の並び、そうでなければ nil。
func tupleElems(e string) []string {
	e = strings.TrimSpace(e)
	if !strings.HasPrefix(e, "(") || matching(e, 0) != len(e)-1 {
		return nil
	}
	parts := splitTop(e[1 : len(e)-1])
	if len(parts) < 2 {
		return nil
	}
	return parts
}

// bind は仮引数 (または let の左辺) の形 pattern に、初期値 (またはそのタプルの要素) init を位置で当てる。
func (t accTypes) bind(pattern string, init []string) {
	pattern = strings.TrimSpace(pattern)
	if elems := tupleElems(pattern); elems != nil {
		for i, p := range elems {
			if i < len(init) {
				t.bind(p, []string{init[i]})
			}
		}
		return
	}
	if len(init) != 1 {
		return
	}
	for _, n := range names(pattern) {
		if parts := tupleElems(init[0]); parts != nil {
			t.tuple[n] = parts
		} else if isStringLit(init[0]) {
			t.str[n] = true
		}
	}
}

// aliasesOf は本体の中で蓄積を分解・言い換えた名前も蓄積として足す (let (a, b) = acc; / let a = acc#x;)。
// 分解の先は、蓄積の初期値がタプルなら位置で文字列かどうかも引き継ぐ。
func aliasesOf(body string, accs map[string]bool, types accTypes) {
	letRe := regexp.MustCompile(`\blet\s+(\([^)]*\)|[a-z][A-Za-z0-9_]*)\s*=\s*([a-z][A-Za-z0-9_]*)((?:#[A-Za-z0-9_]+)*)\s*;`)
	for changed := true; changed; {
		changed = false
		for _, m := range letRe.FindAllStringSubmatch(body, -1) {
			if !accs[m[2]] {
				continue
			}
			if m[3] == "" {
				if parts, ok := types.tuple[m[2]]; ok {
					types.bind(m[1], parts)
				} else if types.str[m[2]] {
					types.bind(m[1], []string{"\"\""})
				}
			}
			for _, n := range names(m[1]) {
				if !accs[n] {
					accs[n] = true
					changed = true
				}
			}
		}
	}
}

func alternation(accs map[string]bool) string {
	var parts []string
	for n := range accs {
		parts = append(parts, regexp.QuoteMeta(n))
	}
	return strings.Join(parts, "|")
}

// Scan は 1 ファイルの本文から拾う。
func Scan(rel, text string) []Hit {
	code := blank(text, true)
	raw := blank(text, false)
	var hits []Hit
	seen := map[int]bool{}
	add := func(pos int, kind, acc string) {
		line := lineAt(text, pos)
		if seen[line] {
			return
		}
		seen[line] = true
		hits = append(hits, Hit{Path: rel, Line: line, Def: defAt(code, pos), Kind: kind, Acc: acc})
	}
	for _, m := range foldRe.FindAllStringSubmatchIndex(code, -1) {
		open := m[1] - 1
		end := argEnd(code, open)
		first := strings.TrimSpace(code[open+1 : end])
		if first == "String.concat" {
			add(m[0], "string", "String.concat")
			continue
		}
		params, bodyStart, ok := lambdaOf(code, open+1, end)
		if !ok || len(params) != 2 || bodyStart > end {
			continue
		}
		accParam := params[0]
		if code[m[2]:m[3]] == "foldRight" {
			accParam = params[1]
		}
		initEnd := end
		if end < len(code) && code[end] == ',' {
			initEnd = argEnd(code, end)
		}
		types := accTypes{str: map[string]bool{}, tuple: map[string][]string{}}
		if initEnd > end {
			types.bind(accParam, []string{code[end+1 : initEnd]})
		}
		accs := map[string]bool{}
		for _, n := range names(accParam) {
			accs[n] = true
		}
		if len(accs) == 0 {
			continue
		}
		body := code[bodyStart:end]
		aliasesOf(body, accs, types)
		alt := alternation(accs)
		field := `(?:#[A-Za-z0-9_]+)*`
		appendRe := regexp.MustCompile(`\bList\.append\s*\(\s*(` + alt + `)\b` + field + `\s*,`)
		for _, a := range appendRe.FindAllStringSubmatchIndex(body, -1) {
			add(bodyStart+a[0], "append", body[a[2]:a[3]])
		}
		rawBody := raw[bodyStart:end]
		for _, re := range []*regexp.Regexp{
			regexp.MustCompile(`"\$\{\s*(` + alt + `)\b` + field + `\s*\}`),
			regexp.MustCompile(`\bString\.concat\s*\(\s*(` + alt + `)\b` + field + `\s*,`),
			regexp.MustCompile(`\b(` + alt + `)\b` + field + `\s*\+\s*"`),
		} {
			for _, a := range re.FindAllStringSubmatchIndex(rawBody, -1) {
				add(bodyStart+a[0], "string", rawBody[a[2]:a[3]])
			}
		}
		if len(types.str) > 0 {
			plusRe := regexp.MustCompile(`\b(` + alternation(types.str) + `)\b\s*\+`)
			for _, a := range plusRe.FindAllStringSubmatchIndex(body, -1) {
				add(bodyStart+a[0], "string", body[a[2]:a[3]])
			}
		}
	}
	return hits
}
