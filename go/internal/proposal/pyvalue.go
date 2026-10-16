package proposal

// Python の値の書き方と比べ方。ページを bin/proposal.py（Python 版）の書き出しと
// バイトまで同じにするため、manifest の値を Python が読んだときと同じ形で扱う。

import (
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"strconv"
	"strings"
	"unicode"
)

// isIntLiteral は JSON の数の書き方が整数か（Python の json は . と e の無い数を int に読む）。
func isIntLiteral(n json.Number) bool {
	return !strings.ContainsAny(string(n), ".eE")
}

// pyNum は Python が読んで書き戻した数（int はそのまま・float は repr）。
func pyNum(n json.Number) string {
	if isIntLiteral(n) {
		if i, ok := new(big.Int).SetString(string(n), 10); ok {
			return i.String()
		}
		return string(n)
	}
	f, err := strconv.ParseFloat(string(n), 64)
	if err != nil {
		return string(n)
	}
	return pyFloat(f)
}

// pyFloat は Python の float の repr（最短の桁で、指数が -4 未満か 16 以上なら 1e+16 の形）。
func pyFloat(f float64) string {
	switch {
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	case math.IsNaN(f):
		return "nan"
	}
	e := strconv.FormatFloat(f, 'e', -1, 64)
	mant, expText, _ := strings.Cut(e, "e")
	exp, _ := strconv.Atoi(expText)
	if exp < -4 || exp >= 16 {
		sign := "+"
		if exp < 0 {
			sign, exp = "-", -exp
		}
		return fmt.Sprintf("%se%s%02d", mant, sign, exp)
	}
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}

// pyRepr は Python の repr（str() に列やオブジェクトを渡したときの形）。
func pyRepr(v any) string {
	switch t := v.(type) {
	case string:
		return pyStrRepr(t)
	case []any:
		parts := make([]string, len(t))
		for i, x := range t {
			parts[i] = pyRepr(x)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case *object:
		parts := make([]string, len(t.keys))
		for i, k := range t.keys {
			parts[i] = pyStrRepr(k) + ": " + pyRepr(t.vals[k])
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return str(v)
}

func pyStrRepr(s string) string {
	quote := byte('\'')
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		quote = '"'
	}
	var b strings.Builder
	b.WriteByte(quote)
	for _, r := range s {
		switch {
		case r == '\\':
			b.WriteString(`\\`)
		case r == rune(quote):
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r > 0x7f && !unicode.IsPrint(r):
			if r <= 0xff {
				fmt.Fprintf(&b, `\x%02x`, r)
			} else if r <= 0xffff {
				fmt.Fprintf(&b, `\u%04x`, r)
			} else {
				fmt.Fprintf(&b, `\U%08x`, r)
			}
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte(quote)
	return b.String()
}

// pyKey は Python の == と hash で同じ物を 1 つの鍵にまとめる（True と 1 と 1.0 は同じ・"1" は別）。
func pyKey(v any) string {
	switch t := v.(type) {
	case nil:
		return "none"
	case string:
		return "s:" + t
	case bool:
		if t {
			return "n:1"
		}
		return "n:0"
	case json.Number:
		if isIntLiteral(t) {
			if i, ok := new(big.Int).SetString(string(t), 10); ok {
				return "n:" + i.String()
			}
		}
		f, _ := strconv.ParseFloat(string(t), 64)
		if f == math.Trunc(f) && math.Abs(f) < 1e18 {
			return "n:" + strconv.FormatInt(int64(f), 10)
		}
		return "f:" + strconv.FormatFloat(f, 'g', -1, 64)
	}
	// 列とオブジェクトは Python では鍵にならない。中身で比べる。
	return "x:" + dumps(v)
}

// pyEq は Python の ==。
func pyEq(a, b any) bool { return pyKey(a) == pyKey(b) }
