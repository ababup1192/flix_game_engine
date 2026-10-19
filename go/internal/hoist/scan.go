package hoist

// 1 ファイルの本文から、Flix 0.78 の最適化が「ループの外で 1 回」のつもりの式を
// ループの中へ書き写してしまう形を拾う (docs/performance.md「ループの外に置いた式がループへ戻る」)。
//
// 見るのは 2 つ:
//   - fn-return: 戻り値が関数の型の def (`def f(spec): (A, B) -> C = { let x = 組み立て; (a, b) -> .. }`)。
//     組み立てた値をラムダが 1 回だけ使うと、組み立てが呼ぶたびに走る。規約の fnReturnScope の中だけ見る
//   - loop-let: 画素や毎コマの繰り返し (shadeAll / Array.forEachWithIndex …) に渡すラムダが、
//     ループの外の「呼び出しの結果・record の欄の let」を onceOutsideLoop を通さずに使う形。目安の検査で、
//     軽い式や効果のある式 (書き写されない) は規約の notMoved に名前で載せて外す

import (
	"regexp"
	"strings"
)

var (
	defRe   = regexp.MustCompile(`(?m)^([ \t]*)(?:pub\s+)?def\s+([a-zA-Z][A-Za-z0-9_]*)`)
	letRe   = regexp.MustCompile(`\blet\s+(\(?[A-Za-z_][A-Za-z0-9_,\s()]*?\)?)\s*(?::[^=;]*)?=\s*`)
	callRe  = regexp.MustCompile(`([A-Za-z_][A-Za-z0-9_.]*)\s*\(`)
	identRe = regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*`)
)

// Hit は鳴らす 1 件。
type Hit struct {
	Path string
	Line int
	Def  string
	Kind string // "fn-return" / "loop-let"
	Name string // loop-let のとき、ループへ戻されうる let の名前
	Loop string // loop-let のとき、渡した先 (shadeAll など)
}

func (h Hit) key() string {
	if h.Kind == "fn-return" {
		return h.Path + "::" + h.Def
	}
	return h.Path + "::" + h.Def + "::" + h.Name
}

// Scan は path の本文 body を見る。fnReturn が false なら fn-return は見ない。
func Scan(path, body string, rules *Rules) []Hit {
	code := blank(body)
	var hits []Hit
	locs := defRe.FindAllStringSubmatchIndex(code, -1)
	for i, loc := range locs {
		end := len(code)
		indent := code[loc[2]:loc[3]]
		for _, next := range locs[i+1:] {
			if len(code[next[2]:next[3]]) <= len(indent) {
				end = next[0]
				break
			}
		}
		name := code[loc[4]:loc[5]]
		def := code[loc[0]:end]
		line := 1 + strings.Count(code[:loc[0]], "\n")
		if rules.inFnReturnScope(path) && returnsFunction(def) {
			hits = append(hits, Hit{Path: path, Line: line, Def: name, Kind: "fn-return"})
		}
		for _, h := range loopLets(def, rules) {
			h.Path, h.Def = path, name
			h.Line += line - 1
			hits = append(hits, h)
		}
	}
	return hits
}

// returnsFunction は def の戻り値の型が関数か (効果の \ の前の型に、括弧の外の -> がある)。
// 本体の = が無い def (eff の演算) は見ない。
func returnsFunction(def string) bool {
	open := strings.Index(def, "(")
	if open < 0 {
		return false
	}
	close := matching(def, open)
	if close < 0 {
		return false
	}
	rest := def[close+1:]
	if !strings.HasPrefix(strings.TrimLeft(rest, " \t"), ":") {
		return false
	}
	eq := topLevelEquals(rest)
	if eq < 0 {
		return false
	}
	sig := rest[:eq]
	// 本体の無い宣言の並び (次の行がコメント・閉じ括弧・別の宣言) は、型の中に = が来ない
	if strings.Contains(sig, "\n") {
		for _, l := range strings.Split(sig, "\n")[1:] {
			t := strings.TrimSpace(l)
			if strings.HasPrefix(t, "}") || strings.HasPrefix(t, "def ") || strings.HasPrefix(t, "pub ") {
				return false
			}
		}
	}
	if bs := strings.Index(sig, `\`); bs >= 0 {
		sig = sig[:bs]
	}
	depth := 0
	for i := 0; i+1 < len(sig); i++ {
		switch sig[i] {
		case '[', '{':
			depth++
		case ']', '}':
			depth--
		case '-':
			if sig[i+1] == '>' && depth == 0 {
				return true
			}
		}
	}
	return false
}

// topLevelEquals は括弧の外の最初の「=」(== と => と <= と >= を除く) の位置。
func topLevelEquals(s string) int {
	depth := 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case '=':
			prev, next := byte(' '), byte(' ')
			if i > 0 {
				prev = s[i-1]
			}
			if i+1 < len(s) {
				next = s[i+1]
			}
			if depth == 0 && next != '=' && next != '>' && prev != '=' && prev != '<' && prev != '>' && prev != '!' {
				return i
			}
		}
	}
	return -1
}

type span struct{ from, to int }

func (s span) has(i int) bool { return i >= s.from && i < s.to }

type letBind struct {
	names []string
	at    int // let の位置
	rhsAt int // 右辺の始まり
	rhs   string
}

// loopLets は 1 つの def の中の loop-let を拾う。Line は def の先頭からの行 (1 始まり)。
func loopLets(def string, rules *Rules) []Hit {
	lets := letsOf(def)
	// ループに渡したラムダの本文 (引数に直に書いた物と、let でラムダに名前を付けて渡した物)
	type loop struct {
		call   string
		at     int
		bodies []span
	}
	var loops []loop
	for _, call := range rules.LoopCalls {
		for from := 0; ; {
			i := strings.Index(def[from:], call+"(")
			if i < 0 {
				break
			}
			at := from + i
			from = at + len(call)
			if at > 0 && (isIdent(def[at-1]) || def[at-1] == '.') {
				continue
			}
			open := at + len(call)
			close := matching(def, open)
			if close < 0 {
				continue
			}
			args := def[open+1 : close]
			l := loop{call: call, at: at}
			if strings.Contains(args, "->") {
				l.bodies = append(l.bodies, span{open + 1, close})
			}
			for _, id := range identRe.FindAllString(args, -1) {
				for _, b := range lets {
					if len(b.names) == 1 && b.names[0] == id && b.at < at && strings.Contains(b.rhs, "->") {
						l.bodies = append(l.bodies, span{b.rhsAt, b.rhsAt + len(b.rhs)})
					}
				}
			}
			loops = append(loops, l)
		}
	}
	var hits []Hit
	seen := map[string]bool{}
	for _, l := range loops {
		for _, b := range lets {
			if b.at >= l.at || !rules.movable(b.rhs) || inside(l.bodies, b.at) {
				continue
			}
			for _, n := range b.names {
				if seen[n] || !usedIn(def, l.bodies, n) {
					continue
				}
				seen[n] = true
				hits = append(hits, Hit{Line: 1 + strings.Count(def[:b.at], "\n"),
					Kind: "loop-let", Name: n, Loop: l.call})
			}
		}
	}
	return hits
}

// letsOf は def の中の let を、右辺 (; まで・括弧の中の ; は数えない) と一緒に拾う。
func letsOf(def string) []letBind {
	var out []letBind
	for _, m := range letRe.FindAllStringSubmatchIndex(def, -1) {
		pat := def[m[2]:m[3]]
		start := m[1]
		end := start
		depth := 0
	scan:
		for ; end < len(def); end++ {
			switch def[end] {
			case '(', '[', '{':
				depth++
			case ')', ']', '}':
				depth--
				if depth < 0 {
					break scan
				}
			case ';':
				if depth == 0 {
					break scan
				}
			}
		}
		var names []string
		for _, n := range identRe.FindAllString(pat, -1) {
			if n != "_" && !strings.HasPrefix(n, "_") {
				names = append(names, n)
			}
		}
		out = append(out, letBind{names: names, at: m[0], rhsAt: start, rhs: def[start:end]})
	}
	return out
}

// movable は右辺が「書き写されると重い・純粋かもしれない」式か (呼び出しか record の欄を含む)。
// onceOutsideLoop を通した物・ラムダそのもの・効果のある呼び出しを含む式・notMoved に載った
// 呼び出しだけの式は外す。
func (r *Rules) movable(rhs string) bool {
	t := strings.TrimSpace(rhs)
	if strings.HasPrefix(t, r.Once+"(") || strings.Contains(t, "->") {
		return false
	}
	calls := callRe.FindAllStringSubmatch(t, -1)
	heavy := strings.Contains(t, "#") && !strings.Contains(t, "#{")
	for _, c := range calls {
		if r.Effectful[c[1]] {
			return false
		}
		if !r.NotMoved[c[1]] {
			heavy = true
		}
	}
	return heavy
}

func inside(spans []span, i int) bool {
	for _, s := range spans {
		if s.has(i) {
			return true
		}
	}
	return false
}

// usedIn は name がラムダの本文で値として使われているか (欄の名前 #name・修飾 X.name は除く)。
func usedIn(def string, spans []span, name string) bool {
	for _, s := range spans {
		body := def[s.from:s.to]
		for from := 0; ; {
			i := strings.Index(body[from:], name)
			if i < 0 {
				break
			}
			at := from + i
			from = at + len(name)
			before, after := byte(' '), byte(' ')
			if at > 0 {
				before = body[at-1]
			}
			if at+len(name) < len(body) {
				after = body[at+len(name)]
			}
			if isIdent(before) || isIdent(after) || before == '#' || before == '.' {
				continue
			}
			return true
		}
	}
	return false
}

func isIdent(c byte) bool {
	return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// blank は // のコメントと文字列の中身を空白に置き換える (長さと改行の位置は変えない)。
func blank(text string) string {
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
					b[i], b[i+1] = ' ', ' '
					i += 2
					continue
				}
				b[i] = ' '
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
