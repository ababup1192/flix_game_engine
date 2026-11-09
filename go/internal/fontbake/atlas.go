package fontbake

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
)

// atlasMagic と headerSize は render_gl の RenderFontCache（magic・headerSize）と同じ値。形を変えたら両方を変える。
const (
	atlasMagic   = 0x46474546_4F4E5402
	headerSize   = 8 + 4 + 4 + 8*4 + 4
	glyphRecord  = 76
	trailerBytes = 16
)

// Atlas は生成したアトラスのファイルから読んだ、字の表の要約。
type Atlas struct {
	Name     string
	Path     string
	Side     int
	FontSize float64
	Glyphs   map[rune]bool
	Bytes    int64
}

// ReadAtlas は RenderFontCache.encode の形のファイルを読み、字の表だけを取り出す。
func ReadAtlas(name, path string) (*Atlas, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	l, err := layoutOf(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	glyphs := make(map[rune]bool, l.count)
	for k := 0; k < l.count; k++ {
		at := headerSize + k*glyphRecord
		glyphs[rune(int32(binary.BigEndian.Uint32(data[at:at+4])))] = true
	}
	return &Atlas{Name: name, Path: path, Side: l.side, FontSize: l.fontSize, Glyphs: glyphs, Bytes: int64(len(data))}, nil
}

// atlasLayout はアトラスのファイルの並び: 頭・字の表（count 件）・画素（side×side・1 画素 1 バイト）・検算。
type atlasLayout struct {
	side, count int
	fontSize    float64
}

func (l atlasLayout) pixelStart() int { return headerSize + l.count*glyphRecord }
func (l atlasLayout) pixelEnd() int   { return l.pixelStart() + l.side*l.side }

func layoutOf(data []byte) (atlasLayout, error) {
	if len(data) < headerSize || binary.BigEndian.Uint64(data[0:8]) != atlasMagic {
		return atlasLayout{}, fmt.Errorf("フォントアトラスの形でない（頭の magic が違う）")
	}
	l := atlasLayout{
		side:     int(int32(binary.BigEndian.Uint32(data[12:16]))),
		count:    int(int32(binary.BigEndian.Uint32(data[48:52]))),
		fontSize: math.Float64frombits(binary.BigEndian.Uint64(data[16:24])),
	}
	want := l.pixelEnd() + trailerBytes
	if l.side <= 0 || l.count < 0 || len(data) != want {
		return atlasLayout{}, fmt.Errorf("長さ %d が頭の数（辺 %d・字 %d）から決まる %d と違う", len(data), l.side, l.count, want)
	}
	return l, nil
}

// SplitPixels はアトラスのファイルを、距離場の画素（side×side・1 画素 1 バイト）と、それを抜いた残り（頭・字の表・検算）に分ける。
// JoinPixels と対で、残りの並びは engine_web/js/fge-web.js の fgeJoinAtlasPixels も読む。
func SplitPixels(data []byte) (rest, pixels []byte, side int, err error) {
	l, err := layoutOf(data)
	if err != nil {
		return nil, nil, 0, err
	}
	rest = append(append([]byte{}, data[:l.pixelStart()]...), data[l.pixelEnd():]...)
	return rest, data[l.pixelStart():l.pixelEnd()], l.side, nil
}

// JoinPixels は SplitPixels の残りへ画素を戻し、元のファイルの並びにする。
func JoinPixels(rest, pixels []byte) ([]byte, error) {
	if len(rest) < headerSize {
		return nil, fmt.Errorf("頭が切れている")
	}
	start := headerSize + int(int32(binary.BigEndian.Uint32(rest[48:52])))*glyphRecord
	if start < headerSize || start > len(rest) {
		return nil, fmt.Errorf("字の数が残りの長さに合わない")
	}
	data := append(append(append([]byte{}, rest[:start]...), pixels...), rest[start:]...)
	if _, err := layoutOf(data); err != nil {
		return nil, err
	}
	return data, nil
}

// Leak はどのフォントのアトラスにも無い字。Dev は開発の道具の所にしか出所が無い字（止めずに知らせる）。
type Leak struct {
	Rune    rune
	Origins []Origin
	Count   int
	Dev     bool
}

// FindLeaks は集めた字のうち、どのアトラスにも無い字を小さい順に返す。
// WhyNot: 1 本ずつ全部の字を持てとは言わない — 見出しだけの飾りフォントのように、一部の字しか持たないフォントを
// 足しているゲームがある（どの文がどのフォントで出るかはコードを走らせないと分からない）。
func FindLeaks(cs *Charset, atlases []*Atlas) []Leak {
	var leaks []Leak
	for _, r := range cs.Runes() {
		found := false
		for _, a := range atlases {
			if a.Glyphs[r] {
				found = true
				break
			}
		}
		if !found {
			leaks = append(leaks, Leak{Rune: r, Origins: cs.Origins[r], Count: cs.Count[r], Dev: !cs.Game[r]})
		}
	}
	return leaks
}

// MissingIn は集めた字のうち、そのアトラスに無い字の数（フォントごとの知らせ用）。
func MissingIn(cs *Charset, a *Atlas) int {
	n := 0
	for r := range cs.Origins {
		if !a.Glyphs[r] {
			n++
		}
	}
	return n
}

// FormatLeak は漏れ 1 字の行: 'X' U+XXXX  出所, 出所（ほか N か所）。
func FormatLeak(l Leak) string {
	at := make([]string, 0, len(l.Origins))
	for _, o := range l.Origins {
		at = append(at, o.String())
	}
	sort.Strings(at)
	more := ""
	if l.Count > len(l.Origins) {
		more = fmt.Sprintf("（ほか %d か所）", l.Count-len(l.Origins))
	}
	return fmt.Sprintf("'%c' U+%04X  %s%s", l.Rune, l.Rune, strings.Join(at, ", "), more)
}
