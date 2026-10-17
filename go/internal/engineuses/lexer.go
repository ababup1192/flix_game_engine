package engineuses

// Flix のソースを、名前を数えるのに足りるだけの字句に切る。
// 注釈（// と /* */）と文字列・文字の中身は捨てる。文字列の中の `${ ... }` は式なので字句に入れる。

type tokKind int

const (
	tokIdent tokKind = iota
	tokPunct
)

// token は 1 つの字句。line は 0 始まりの行、depth はその字句の直前のブレースの深さ。
type token struct {
	kind  tokKind
	text  string
	line  int
	depth int
}

func isIdentStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isIdentPart(c byte) bool {
	return isIdentStart(c) || (c >= '0' && c <= '9')
}

// tokenize は src を字句の列にする。
func tokenize(src string) []token {
	var toks []token
	line, depth := 0, 0
	// interp は文字列の中の `${` で入った式の、入った時のブレースの深さの積み重ね。
	var interp []int
	i := 0
	n := len(src)
	// scanString は開きの `"` の次から読み、閉じの `"` の次の位置を返す。`${` で式に入るときは
	// その `{` の次の位置と true を返す。
	scanString := func(j int) (int, bool) {
		for j < n {
			c := src[j]
			switch {
			case c == '\\' && j+1 < n:
				if src[j+1] == '\n' {
					line++
				}
				j += 2
			case c == '"':
				return j + 1, false
			case c == '$' && j+1 < n && src[j+1] == '{':
				return j + 2, true
			default:
				if c == '\n' {
					line++
				}
				j++
			}
		}
		return j, false
	}
	for i < n {
		c := src[i]
		switch {
		case c == '\n':
			line++
			i++
		case c == ' ' || c == '\t' || c == '\r':
			i++
		case c == '/' && i+1 < n && src[i+1] == '/':
			for i < n && src[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < n && src[i+1] == '*':
			i += 2
			for i+1 < n && !(src[i] == '*' && src[i+1] == '/') {
				if src[i] == '\n' {
					line++
				}
				i++
			}
			i += 2
		case c == '"':
			j, inInterp := scanString(i + 1)
			i = j
			if inInterp {
				interp = append(interp, depth)
				depth++
			}
		case c == '\'':
			// 文字: 'x' '\n' 'A'。閉じの ' までを飛ばす（行はまたがない）。
			j := i + 1
			if j < n && src[j] == '\\' {
				j += 2
			} else {
				j++
			}
			for j < n && src[j] != '\'' && src[j] != '\n' {
				j++
			}
			if j < n && src[j] == '\'' {
				i = j + 1
			} else {
				i++
			}
		case isIdentStart(c):
			j := i
			for j < n && isIdentPart(src[j]) {
				j++
			}
			toks = append(toks, token{kind: tokIdent, text: src[i:j], line: line, depth: depth})
			i = j
		case c == ':' && i+1 < n && src[i+1] == ':':
			toks = append(toks, token{kind: tokPunct, text: "::", line: line, depth: depth})
			i += 2
		case c == '{':
			toks = append(toks, token{kind: tokPunct, text: "{", line: line, depth: depth})
			depth++
			i++
		case c == '}':
			if len(interp) > 0 && interp[len(interp)-1] == depth-1 {
				// 文字列の中の式が閉じた。文字列の続きを読む。
				interp = interp[:len(interp)-1]
				depth--
				j, inInterp := scanString(i + 1)
				i = j
				if inInterp {
					interp = append(interp, depth)
					depth++
				}
				continue
			}
			depth--
			toks = append(toks, token{kind: tokPunct, text: "}", line: line, depth: depth})
			i++
		default:
			toks = append(toks, token{kind: tokPunct, text: string(c), line: line, depth: depth})
			i++
		}
	}
	return toks
}
