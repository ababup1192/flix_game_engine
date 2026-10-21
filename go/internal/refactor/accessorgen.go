package refactor

// field-to-accessor が口（読む def・書き換えた値を返す def）を自分で作る所。口の名前だけ分かっていれば
// （既定は <欄>Of と with<欄>）、ファイルを開かずに 1 コマンドで「口を作る → 直の読み書きを口へ替える → check」まで済む。
//
// 置き場は受け手の型 alias を宣言したファイルの、その mod の既存の読みの口（名前が …Of の def）の並びの一番後ろ。
// 読みの口が 1 つも無ければ alias の宣言の後ろ。ここの関数は純粋（ファイルの中身は呼ぶ側が渡す）。

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// DefaultGetter・DefaultSetter は口の既定の名前（alias の mod の中の <欄>Of・with<欄>）。
func DefaultGetter(mod, label string) string { return mod + "." + label + "Of" }

func DefaultSetter(mod, label string) string { return mod + ".with" + upperFirst(label) }

func upperFirst(s string) string {
	r, n := utf8.DecodeRuneInString(s)
	return string(unicode.ToUpper(r)) + s[n:]
}

func shortName(sym string) string { return sym[strings.LastIndex(sym, ".")+1:] }

// AccessorStubs は口の def の字（前に空行・`///` つき）。getter・setter のどちらかが "" ならそれは作らない。
func AccessorStubs(indent, aliasShort, label, fieldType, getter, setter string) string {
	p := strings.ToLower(aliasShort[:1])
	v := "v"
	if p == v {
		v = "x"
	}
	var b strings.Builder
	if getter != "" {
		fmt.Fprintf(&b, "\n%s/// %s の欄 %s（bin/fge refactor field-to-accessor が作った読みの口）。\n", indent, aliasShort, label)
		fmt.Fprintf(&b, "%spub def %s(%s: %s): %s = %s#%s\n", indent, shortName(getter), p, aliasShort, fieldType, p, label)
	}
	if setter != "" {
		fmt.Fprintf(&b, "\n%s/// 欄 %s を %s にした %s（bin/fge refactor field-to-accessor が作った書きの口）。\n", indent, label, v, aliasShort)
		fmt.Fprintf(&b, "%spub def %s(%s: %s, %s: %s): %s = { %s = %s | %s }\n", indent, shortName(setter), v, fieldType, p, aliasShort, aliasShort, label, v, p)
	}
	return b.String()
}

// StubPlace は口を足す所: ファイル・行の頭のバイトの位置・字下げ・報告の場所。
type StubPlace struct {
	File   string
	Pos    int
	Indent string
	At     Row
}

// FindStubPlace は口を足す所を決める。mod の def で名前が …Of の物のうち、shape と同じファイルで一番後ろの物の次の行。
// 無ければ alias の宣言（shape）の閉じる `}` の次の行。alias に型引数があれば作らない（誤り）。
func FindStubPlace(rows []Row, srcs map[string]string, mod string, shape Shape) (StubPlace, error) {
	src := srcs[shape.File]
	short := shortName(shape.Name)
	if regexp.MustCompile(`\btype\s+alias\s+` + regexp.QuoteMeta(short) + `\[`).MatchString(src) {
		return StubPlace{}, fmt.Errorf("alias %s は型引数を持つ（口の型を決められない。口を手で書いて --getter・--setter で名指し）", short)
	}
	place := StubPlace{File: shape.File}
	end := -1
	for _, r := range rows {
		if r.Kind != KindDefDecl || r.File != shape.File || modOf(r.Sym) != mod || !strings.HasSuffix(shortName(r.Sym), "Of") {
			continue
		}
		ext, err := spanOf(r.File, r.Attr("ext"))
		if err != nil {
			continue
		}
		s, e, err := ByteRange(src, ext)
		if err != nil || e <= end {
			continue
		}
		end = e
		place.At = r
		ls := lineStart(src, s)
		place.Indent = src[ls : ls+len(src[ls:])-len(strings.TrimLeft(src[ls:], " \t"))]
	}
	if end < 0 {
		end = shape.End
		ls := lineStart(src, shape.Brace)
		place.Indent = src[ls : ls+len(src[ls:])-len(strings.TrimLeft(src[ls:], " \t"))]
		place.At = rowAt(shape.File, src, shape.Brace, shape.Name)
	}
	nl := strings.IndexByte(src[end:], '\n')
	if nl < 0 {
		return StubPlace{}, fmt.Errorf("%s: 口を足す行が無い（ファイルの終わり）", shape.File)
	}
	place.Pos = end + nl + 1
	return place, nil
}

// stubEdit は口の def を足す書き換え（長さ 0 の範囲に挿す。当てる前に位置の前の字が変わっていないかを見る）。
func stubEdit(place StubPlace, text string) Edit {
	return Edit{File: place.File, Start: place.Pos, End: place.Pos, Site: place.At,
		Make: func(cur string) (string, error) {
			if cur != "" {
				return "", fmt.Errorf("口を足す所が空でない")
			}
			return text, nil
		}}
}
