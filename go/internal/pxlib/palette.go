package pxlib

// sprite.json の legend と色票を引く入口（sprite の検査と px の描画・色の門が同じ物を使う）。

import (
	"fmt"
	"math"
	"path/filepath"
	"strconv"
	"strings"
)

// KeyText は legend の値を色キーの字面にする。
// WhyNot: 文字列以外も受けるのは、legend に数値や真偽値を書いた Doc でも
// それを色キーとして数え、色数の勘定から漏らさないため。
func KeyText(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case bool:
		if x {
			return "True"
		}
		return "False"
	case nil:
		return "None"
	case float64:
		if x == math.Trunc(x) && math.Abs(x) < 1e15 {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'g', -1, 64)
	default:
		return fmt.Sprint(x)
	}
}

// Legend は legend の字と色キーの対応。
type Legend struct {
	Chars  []string       // 字（Doc に書いた順。map から作ったときは順不同）
	KeyOf  map[string]Key // 字 → 色キー
	CharOf map[Key]string // 色キー → 最初に書いた字
}

// LegendOf は legend（*Obj か map[string]any）を読む。値は KeyText で色キーにする。
func LegendOf(v any) *Legend {
	l := &Legend{KeyOf: map[string]Key{}, CharOf: map[Key]string{}}
	add := func(ch string, val any) {
		k := Key(KeyText(val))
		l.Chars = append(l.Chars, ch)
		l.KeyOf[ch] = k
		if _, dup := l.CharOf[k]; !dup {
			l.CharOf[k] = ch
		}
	}
	switch t := v.(type) {
	case *Obj:
		keys, vals := t.Items()
		for i, ch := range keys {
			add(ch, Plain(vals[i]))
		}
	case map[string]any:
		for ch, val := range t {
			add(ch, val)
		}
	}
	return l
}

// Set は字を足す（build が legend に無い色キーへ字を当てるとき）。
func (l *Legend) Set(ch string, k Key) {
	if _, ok := l.KeyOf[ch]; !ok {
		l.Chars = append(l.Chars, ch)
	}
	l.KeyOf[ch] = k
	if _, dup := l.CharOf[k]; !dup {
		l.CharOf[k] = ch
	}
}

// ColorDialect は色票の値のどの書き方を読むか。
type ColorDialect int

const (
	_ ColorDialect = iota
	// HexOnly は "#rrggbb" と {"hex"|"color"|"value": …} だけ（sprite の ΔE の検査）。
	HexOnly
	// AnyColor はそれに {"rgb": [r, g, b]}・{"hsv": [h, s, v]} を足す（Studio と色の門）。
	AnyColor
)

func hexOf(v any, d ColorDialect) string {
	if d == AnyColor {
		if c, ok := RGBAOfValue(v); ok {
			return HexOfRGBA(c)
		}
		return ""
	}
	return HexOfValue(v)
}

// ColorTable は色票 1 つ（直下と入れ子の colors。同じ名前なら colors が勝つ）を 名前 → #rrggbb にする。
func ColorTable(v any, d ColorDialect) map[string]string {
	found := map[string]string{}
	m, ok := AsObject(Plain(v))
	if !ok {
		return found
	}
	for name, value := range m {
		if got := hexOf(value, d); got != "" {
			found[name] = got
		}
	}
	if nested, ok := AsObject(m["colors"]); ok {
		for name, value := range nested {
			if got := hexOf(value, d); got != "" {
				found[name] = got
			}
		}
	}
	return found
}

// DocPalette は sprite.json の色の名前 → #rrggbb。themes（root からの相対の *.theme.json）・
// paletteFile・直下の palette の順に重ね、後に書いた方が勝つ。
func DocPalette(root string, doc map[string]any, themes []string, d ColorDialect) map[string]string {
	names := map[string]string{}
	merge := func(v any) {
		for k, h := range ColorTable(v, d) {
			names[k] = h
		}
	}
	for _, rel := range themes {
		if strings.HasSuffix(rel, ".theme.json") {
			merge(ReadJSON(filepath.Join(root, rel)))
		}
	}
	if ref, ok := doc["paletteFile"].(string); ok {
		merge(ReadJSON(filepath.Join(root, ref)))
	}
	merge(doc["palette"])
	return names
}

// LegendHexes は legend の値（色キー・"@名前"・"#rrggbb"）→ #rrggbb。解けない値は含めない。
func LegendHexes(legend map[string]any, names map[string]string) map[string]string {
	resolved := map[string]string{}
	for _, value := range legend {
		text, ok := value.(string)
		if !ok {
			continue
		}
		if direct := HexOfValue(text); direct != "" {
			resolved[text] = direct
			continue
		}
		if hex, ok := names[strings.TrimPrefix(text, "@")]; ok {
			resolved[text] = hex
		}
	}
	return resolved
}
