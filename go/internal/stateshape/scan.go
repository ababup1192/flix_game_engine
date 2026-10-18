package stateshape

// .flix を構文木にせず文字で読む所。コメントと文字列の中身を空白にしてから当てる（位置と行は保つ）。

import (
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/recordwrap"
)

// Blank はコメント（// と /* */）と文字列・文字の中身を空白に置き換える。改行と位置は保つ。
func Blank(src string) string {
	b := []byte(src)
	n := len(b)
	blank := func(from, to int) {
		for k := from; k < to && k < n; k++ {
			if b[k] != '\n' {
				b[k] = ' '
			}
		}
	}
	for i := 0; i < n; {
		switch {
		case i+1 < n && b[i] == '/' && b[i+1] == '/':
			j := i
			for j < n && b[j] != '\n' {
				j++
			}
			blank(i, j)
			i = j
		case i+1 < n && b[i] == '/' && b[i+1] == '*':
			j := strings.Index(src[i+2:], "*/")
			end := n
			if j >= 0 {
				end = i + 2 + j + 2
			}
			blank(i, end)
			i = end
		case b[i] == '"':
			j := i + 1
			for j < n && b[j] != '"' {
				if b[j] == '\\' {
					j++
				}
				j++
			}
			blank(i+1, j)
			i = j + 1
		case b[i] == '\'' && i+2 < n && (b[i+2] == '\'' || (b[i+1] == '\\' && i+3 < n && b[i+3] == '\'')):
			end := i + 3
			if b[i+1] == '\\' {
				end = i + 4
			}
			blank(i+1, end-1)
			i = end
		default:
			i++
		}
	}
	return string(b)
}

// closeOf は code[open] の括弧と対になる位置。閉じなければ len(code)。
func closeOf(code string, open int) int {
	depth := 0
	for k := open; k < len(code); k++ {
		switch code[k] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
			if depth == 0 {
				return k
			}
		}
	}
	return len(code)
}

func lineOf(code string, pos int) int { return 1 + strings.Count(code[:pos], "\n") }

// record は型エイリアスの record 1 つ（読み方は record-wrap と同じ）。
type record struct {
	Name   string
	Line   int
	From   int // 本体 { の位置
	To     int // 本体 } の次
	Fields []recordwrap.Field
}

func records(rel, code string) []record {
	var out []record
	for _, a := range recordwrap.ParseAliases(rel, code) {
		fs := recordwrap.Fields(a.Body)
		if fs == nil {
			continue
		}
		from := a.Offset + strings.Index(code[a.Offset:], "{")
		out = append(out, record{Name: a.Name, Line: lineOf(code, from), From: from, To: from + len(a.Body), Fields: fs})
	}
	return out
}

var enumRe = regexp.MustCompile(`\benum\s+([A-Z]\w*)[^{\n]*\{`)

// enumDecl は enum 1 つ（名前・本体の範囲・case の名前）。
type enumDecl struct {
	Name     string
	From, To int
	Cases    map[string]bool
}

var caseNameRe = regexp.MustCompile(`\bcase\s+([A-Z]\w*)`)

func enums(code string) []enumDecl {
	var out []enumDecl
	for _, m := range enumRe.FindAllStringSubmatchIndex(code, -1) {
		open := m[1] - 1
		end := closeOf(code, open)
		body := code[open+1 : end]
		cases := map[string]bool{}
		for _, c := range caseNameRe.FindAllStringSubmatchIndex(body, -1) {
			cases[body[c[2]:c[3]]] = true
			// `case A, B, C` の続きの名前も拾う
			rest := body[c[1]:]
			if nl := strings.IndexByte(rest, '\n'); nl >= 0 {
				rest = rest[:nl]
			}
			for _, part := range splitTop(rest) {
				if nm := strings.TrimSpace(part); nm != "" {
					if k := strings.IndexAny(nm, "( "); k >= 0 {
						nm = nm[:k]
					}
					if nm != "" && nm[0] >= 'A' && nm[0] <= 'Z' {
						cases[nm] = true
					}
				}
			}
		}
		out = append(out, enumDecl{Name: code[m[2]:m[3]], From: open, To: end, Cases: cases})
	}
	return out
}

// splitTop は深さ 0 のカンマで切る。
func splitTop(s string) []string {
	var parts []string
	depth, from := 0, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case ',':
			if depth == 0 {
				parts = append(parts, s[from:i])
				from = i + 1
			}
		}
	}
	return append(parts, s[from:])
}

var defRe = regexp.MustCompile(`\bdef\s+([a-zA-Z_]\w*)`)

// def は def 1 つの名前・位置・宣言の効果（\ の後ろ。無ければ ""）。
type def struct {
	Name   string
	At     int
	Effect string
}

func defs(code string) []def {
	ms := defRe.FindAllStringSubmatchIndex(code, -1)
	out := make([]def, 0, len(ms))
	for k, m := range ms {
		limit := len(code)
		if k+1 < len(ms) {
			limit = ms[k+1][0]
		}
		out = append(out, def{Name: code[m[2]:m[3]], At: m[0], Effect: effectOf(code[m[1]:limit])})
	}
	return out
}

// effectOf は def の名前の後ろ（型引数・引数・: 戻りの型 \ 効果 = 本体）から効果の式を取り出す。
func effectOf(s string) string {
	i := skipSpace(s, 0)
	if i < len(s) && s[i] == '[' {
		i = skipSpace(s, closeOf(s, i)+1)
	}
	if i >= len(s) || s[i] != '(' {
		return ""
	}
	i = skipSpace(s, closeOf(s, i)+1)
	if i >= len(s) || s[i] != ':' {
		return ""
	}
	sig := s[i+1:]
	depth := 0
	for j := 0; j < len(sig); j++ {
		switch sig[j] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case '=':
			if depth == 0 && (j+1 >= len(sig) || sig[j+1] != '>') {
				return ""
			}
		case '\\':
			if depth == 0 {
				return strings.TrimSpace(cutEffect(sig[j+1:]))
			}
		}
	}
	return ""
}

// cutEffect は効果の式の終わり（深さ 0 の = か with / where）まで。
func cutEffect(s string) string {
	depth := 0
	for j := 0; j < len(s); j++ {
		switch s[j] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case '=':
			if depth == 0 {
				return s[:j]
			}
		case ' ', '\n', '\t':
			if depth == 0 {
				rest := strings.TrimLeft(s[j:], " \n\t")
				if strings.HasPrefix(rest, "with ") || strings.HasPrefix(rest, "where ") {
					return s[:j]
				}
			}
		}
	}
	return s
}

func skipSpace(s string, i int) int {
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i++
	}
	return i
}

var effTokenRe = regexp.MustCompile(`[A-Za-z_][\w.]*`)

// concreteEffects は効果の式のうち、決まった効果（大文字で始まる名前）。効果の変数（ef など）は数えない。
func concreteEffects(eff string) []string {
	var out []string
	for _, t := range effTokenRe.FindAllString(eff, -1) {
		if t[0] >= 'A' && t[0] <= 'Z' {
			out = append(out, t)
		}
	}
	return out
}

// arm は match の腕 1 つ。
type arm struct {
	Pat     string
	Line    int
	Guarded bool
	Rhs     string
}

// matchBlock は match 1 つの腕の並び。
type matchBlock struct {
	At   int
	Arms []arm
}

var matchRe = regexp.MustCompile(`\bmatch\b`)
var ifRe = regexp.MustCompile(`\bif\b`)

func matches(code string) []matchBlock {
	var out []matchBlock
	for _, m := range matchRe.FindAllStringIndex(code, -1) {
		open := strings.IndexByte(code[m[1]:], '{')
		if open < 0 {
			continue
		}
		open += m[1]
		end := closeOf(code, open)
		body := code[open+1 : end]
		var arms []arm
		depth := 0
		for k := 0; k < len(body); k++ {
			switch c := body[k]; {
			case c == '(' || c == '[' || c == '{':
				depth++
			case c == ')' || c == ']' || c == '}':
				depth--
			case depth == 0 && strings.HasPrefix(body[k:], "case") && !isIdent(body, k-1) && !isIdent(body, k+4):
				arrow := strings.Index(body[k:], "=>")
				if arrow < 0 {
					k = len(body)
					continue
				}
				arrow += k
				pat := strings.TrimSpace(body[k+4 : arrow])
				guarded := ifRe.MatchString(pat)
				if loc := ifRe.FindStringIndex(pat); loc != nil {
					pat = strings.TrimSpace(pat[:loc[0]])
				}
				rhs := body[arrow+2:]
				if nl := strings.IndexByte(rhs, '\n'); nl >= 0 {
					rhs = rhs[:nl]
				}
				arms = append(arms, arm{Pat: pat, Line: lineOf(code, open+1+k), Guarded: guarded, Rhs: strings.TrimSpace(rhs)})
				k = arrow + 1
			}
		}
		out = append(out, matchBlock{At: m[0], Arms: arms})
	}
	return out
}

func isIdent(s string, i int) bool {
	if i < 0 || i >= len(s) {
		return false
	}
	c := s[i]
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
