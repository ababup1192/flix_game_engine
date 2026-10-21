package refactor

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

// SpanText は src（ファイルの中身）の中で r の範囲が指す字。列はコンパイラの数え方（1 から・UTF-16 の単位）なので、
// BMP の外の字（絵文字）は 2 と数える。範囲が中身の外なら誤り（索引が古い）。
//
// WhyNot: バイトで切らないのは、日本語のコメントや文字列が同じ行にあると列がずれるため。
func SpanText(src string, r Row) (string, error) {
	lines := strings.SplitAfter(src, "\n")
	start, err := offset(lines, r.Line, r.Col)
	if err != nil {
		return "", fmt.Errorf("%s の始まり: %v", r.Where(), err)
	}
	end, err := offset(lines, r.EndLine, r.EndCol)
	if err != nil {
		return "", fmt.Errorf("%s の終わり: %v", r.Where(), err)
	}
	pre := 0
	for i := 0; i < r.Line-1; i++ {
		pre += len(lines[i])
	}
	preEnd := 0
	for i := 0; i < r.EndLine-1; i++ {
		preEnd += len(lines[i])
	}
	a, b := pre+start, preEnd+end
	if a > b {
		return "", fmt.Errorf("%s: 範囲の終わりが始まりより前", r.Where())
	}
	return src[a:b], nil
}

// offset は行 line（1 から）の列 col（1 から・UTF-16）のバイトの位置（行の頭から）。
func offset(lines []string, line, col int) (int, error) {
	if line < 1 || line > len(lines) {
		return 0, fmt.Errorf("行 %d が無い（%d 行）", line, len(lines))
	}
	s := strings.TrimRight(lines[line-1], "\r\n")
	units, i := 1, 0
	for units < col {
		if i >= len(s) {
			return 0, fmt.Errorf("行 %d に列 %d が無い", line, col)
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		i += size
		units++
		if r > 0xFFFF {
			units++
		}
	}
	return i, nil
}
