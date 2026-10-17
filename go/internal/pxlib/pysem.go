package pxlib

// 検査の出力を左右する細かい振る舞いを 1 か所へ寄せた小物。
// 文字列・パス・正規表現・ディレクトリ走査のうち、標準の既定のままだと
// 出力の行や字面が変わってしまう所だけを置く。

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// SplitLines は \n のほか \r\n・\v・\f・U+2028 等でも行を切る。
// WhyNot: strings.Split(s, "\n") にしないのは、CRLF の行末に \r が残って
// 行頭の判定や、つなぎ直した本文がずれるため。
func SplitLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch r {
		case '\n', '\v', '\f', '\r', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			lines = append(lines, s[start:i])
			i += size
			if r == '\r' && i < len(s) && s[i] == '\n' {
				i++
			}
			start = i
		default:
			i += size
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

// DecodeReplace は不正なバイトを U+FFFD に置き換える。
// WhyNot: 不正なバイトで失敗にしないのは、壊れたファイル 1 つで検査を止めないため。
func DecodeReplace(data []byte) string {
	if utf8.Valid(data) {
		return string(data)
	}
	var b strings.Builder
	for i := 0; i < len(data); {
		r, size := utf8.DecodeRune(data[i:])
		if r == utf8.RuneError && size == 1 {
			b.WriteRune(utf8.RuneError)
			i++
			continue
		}
		b.Write(data[i : i+size])
		i += size
	}
	return b.String()
}

// LoadTextReplace はファイルを読んで DecodeReplace した文字列を返す。
func LoadTextReplace(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return DecodeReplace(data), nil
}

// PosixPath はパスを / 区切りの字面にする。
// 空の要素と "." を落とし、".." は残す。
func PosixPath(s string) string {
	s = filepath.ToSlash(s)
	anchor := ""
	switch {
	case strings.HasPrefix(s, "///"):
		anchor = "/"
	case strings.HasPrefix(s, "//"):
		// WhyNot: 先頭の // を 1 本に潰さないのは POSIX が別の場所として扱うため。
		anchor = "//"
	case strings.HasPrefix(s, "/"):
		anchor = "/"
	}
	var parts []string
	for _, p := range strings.Split(s, "/") {
		if p == "" || p == "." {
			continue
		}
		parts = append(parts, p)
	}
	joined := strings.Join(parts, "/")
	if anchor == "" {
		if joined == "" {
			return "."
		}
		return joined
	}
	return anchor + joined
}

// PathParts は PosixPath した上での要素列と先頭の区切りを返す。
func PathParts(s string) (anchor string, parts []string) {
	p := PosixPath(s)
	switch {
	case strings.HasPrefix(p, "//"):
		anchor, p = "//", strings.TrimPrefix(p, "//")
	case strings.HasPrefix(p, "/"):
		anchor, p = "/", strings.TrimPrefix(p, "/")
	}
	if p == "" || p == "." {
		return anchor, nil
	}
	return anchor, strings.Split(p, "/")
}

// TestdataDir は検査そのものの見本置き場。中身はわざと違反を書いたファイルなので、
// リポ全体を数え上げる検査はここへ降りない。
const TestdataDir = "testdata"

// InTestdata は testdata という名前のフォルダの中かを返す。
// WhyNot: 前方一致 ("testdata/" で始まるか) にしないのは、ゲームのリポで
// もっと深い所に置かれても効かせるため。引数でファイルを名指しされた場合は
// ここを通さない (見本を鳴らす道が塞がる)。
func InTestdata(path string) bool {
	_, parts := PathParts(path)
	if len(parts) == 0 {
		return false
	}
	for _, p := range parts[:len(parts)-1] {
		if p == TestdataDir {
			return true
		}
	}
	return false
}

// Rglob は dir 以下から suffix で終わるファイルを、ディレクトリが返す並びのまま返す。
// WhyNot: filepath.WalkDir を使わないのは、名前順に並べ替えられて
// 検査の出力の行順が変わってしまうため。
func Rglob(dir, suffix string) []string {
	var found []string
	var rec func(d string)
	rec = func(d string) {
		f, err := os.Open(d)
		if err != nil {
			return
		}
		names, err := f.Readdirnames(-1)
		f.Close()
		if err != nil {
			return
		}
		var subdirs []string
		for _, name := range names {
			p := filepath.Join(d, name)
			info, err := os.Stat(p)
			if err != nil {
				continue
			}
			if info.IsDir() {
				subdirs = append(subdirs, p)
				continue
			}
			if strings.HasSuffix(name, suffix) {
				found = append(found, p)
			}
		}
		for _, sub := range subdirs {
			rec(sub)
		}
	}
	rec(dir)
	return found
}

// PyRegexp は語の区切りを Unicode で見る正規表現。
type PyRegexp struct {
	re      *regexp.Regexp
	trailWB bool
}

// CompilePy は正規表現を語の区切りが Unicode で効く形にして包む。
//
// WhyNot: regexp.Compile をそのまま呼ばないのは、語の見方が狭いため。
//   - Go の \w と \b は ASCII だけを語とみなすので、直後が漢字の位置でも
//     語の切れ目とみなして当たってしまう。
//   - そこで \w は Unicode の字類に置き換え、末尾の \b は数える側で見直す。
func CompilePy(pattern string) (*PyRegexp, error) {
	src := strings.ReplaceAll(pattern, `\w`, `[\p{L}\p{N}_]`)
	re, err := regexp.Compile(src)
	if err != nil {
		return nil, err
	}
	return &PyRegexp{re: re, trailWB: strings.HasSuffix(pattern, `\b`)}, nil
}

// FindAll は当たった所を前から順に全部返す。
func (p *PyRegexp) FindAll(s string) []string {
	var found []string
	for pos := 0; pos <= len(s); {
		loc := p.re.FindStringIndex(s[pos:])
		if loc == nil {
			break
		}
		start, end := pos+loc[0], pos+loc[1]
		if p.trailWB && isPyWordAt(s, end) {
			pos = start + 1
			continue
		}
		found = append(found, s[start:end])
		if end == start {
			pos = end + 1
			continue
		}
		pos = end
	}
	return found
}

// FindIndexFrom は s の from バイト目以降で最初に当たった範囲を返す。
//
// WhyNot: FindAll で足りないのは、Go の正規表現に後読みが無いぶんを呼ぶ側が
// 「当たった位置の前後 1 文字を見て捨てる」で補うため。捨てるには位置が要る。
func (p *PyRegexp) FindIndexFrom(s string, from int) (int, int, bool) {
	for pos := from; pos >= 0 && pos <= len(s); {
		loc := p.re.FindStringIndex(s[pos:])
		if loc == nil {
			return 0, 0, false
		}
		start, end := pos+loc[0], pos+loc[1]
		if p.trailWB && isPyWordAt(s, end) {
			pos = start + 1
			continue
		}
		return start, end, true
	}
	return 0, 0, false
}

// MatchString はどこかに当たれば真を返す。
func (p *PyRegexp) MatchString(s string) bool {
	if !p.trailWB {
		return p.re.MatchString(s)
	}
	return len(p.FindAll(s)) > 0
}

func isPyWordAt(s string, i int) bool {
	if i >= len(s) {
		return false
	}
	r, _ := utf8.DecodeRuneInString(s[i:])
	return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r)
}
