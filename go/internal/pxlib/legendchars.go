package pxlib

// sprite.json の legend と rows の印に使える字（依頼主の決定 2026-10-18）。
// 右から左へ書く字（bidi が R・AL の字: ヘブライ・アラビアなど）・幅が 1 でない字（全角・絵文字・幅 0 の字）・結合文字は使えない
// （行の見た目と画素の並びがずれる）。印は ASCII の表示できる字を先に使い、足りない時だけ LegendPool の決まった並びで広げる。

import (
	"fmt"
	"unicode"
)

// LegendPool は印を振る順（ASCII の表示できる字 → ラテン 1 補助・ラテン拡張 A の文字 → ギリシャ文字 → キリル文字）。
// 頭の 74 字は 0.41.0 までの px build の順のまま（新しい色の印の振り方を変えない）。'.' は透明・'"' と '\' は JSON で崩れるので使わない。
var LegendPool = func() []rune {
	out := []rune("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#@$%&*+=?!~^")
	for _, r := range "'(),-/:;<>[]_`{|}" {
		out = append(out, r)
	}
	for r := rune(0xC0); r <= 0x17F; r++ {
		if r != 0xD7 && r != 0xF7 && unicode.IsLetter(r) {
			out = append(out, r)
		}
	}
	for r := rune(0x391); r <= 0x3C9; r++ {
		if r != 0x3A2 && unicode.IsLetter(r) {
			out = append(out, r)
		}
	}
	for r := rune(0x410); r <= 0x44F; r++ {
		out = append(out, r)
	}
	return out
}()

var rtlScripts = []*unicode.RangeTable{unicode.Hebrew, unicode.Arabic, unicode.Syriac, unicode.Thaana, unicode.Nko,
	unicode.Samaritan, unicode.Mandaic, unicode.Adlam, unicode.Hanifi_Rohingya, unicode.Mende_Kikakui, unicode.Old_Hungarian}

// wide は幅 2 の字（東アジアの全角・ハングル・絵文字）のおおまかな範囲。
var wide = &unicode.RangeTable{R16: []unicode.Range16{
	{Lo: 0x1100, Hi: 0x115F, Stride: 1}, {Lo: 0x2E80, Hi: 0xA4CF, Stride: 1}, {Lo: 0xAC00, Hi: 0xD7A3, Stride: 1},
	{Lo: 0xF900, Hi: 0xFAFF, Stride: 1}, {Lo: 0xFE30, Hi: 0xFE4F, Stride: 1}, {Lo: 0xFF00, Hi: 0xFF60, Stride: 1}, {Lo: 0xFFE0, Hi: 0xFFE6, Stride: 1},
}, R32: []unicode.Range32{{Lo: 0x1F300, Hi: 0x1FAFF, Stride: 1}, {Lo: 0x20000, Hi: 0x3FFFD, Stride: 1}}}

// LegendCharProblem は印に使えない字の理由（使えれば ""）。
func LegendCharProblem(r rune) string {
	switch {
	case r == '.' || r == ' ':
		return "透明の字"
	case r < 0x20 || r == 0x7F || unicode.Is(unicode.Cc, r):
		return "制御文字"
	case unicode.In(r, rtlScripts...) || r == 0x200F || r == 0x061C || (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069):
		return "右から左へ書く字"
	case unicode.In(r, unicode.Mn, unicode.Me, unicode.Mc):
		return "結合文字"
	case unicode.Is(unicode.Cf, r) || r == 0x200B:
		return "幅 0 の字"
	case unicode.Is(wide, r):
		return "幅 2 の字"
	}
	return ""
}

// LegendCharError は印に使えない字の誤りの文。
func LegendCharError(r rune) error {
	if p := LegendCharProblem(r); p != "" {
		return fmt.Errorf("印 %q（U+%04X）は%sなので使えない（bin/fge px relegend で ASCII へ振り直す）", string(r), r, p)
	}
	return nil
}
