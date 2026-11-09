package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// webDefaultStartPrompt は project.json の web.startPrompt が無い時の「押して始める」の文言。
const webDefaultStartPrompt = "Tap to start"

// webSplash は bundle.json の splash。頁が「押して始める」の前に、デスクトップの起動画面（Splash.flix）と同じ絵を
// 自分で描くための材料（組み込みフォントとロゴを PNG にした物・字の表・文言）。
// WhyNot: 頁の HTML の字（system-ui）で題字と一行を描かない — デスクトップはドットのフォントで描くので、押した後も同じ絵に見えない。
// WhyNot: PNG を別のファイルにして取らせない — 起動画面を出すまでの取りが 1 往復増える。どちらも 2KB に届かない。
type webSplash struct {
	StartPrompt    string                `json:"startPrompt"`
	Logo           string                `json:"logo,omitempty"`
	Font           string                `json:"font,omitempty"`
	Glyphs         string                `json:"glyphs,omitempty"`
	FontSize       float64               `json:"fontSize,omitempty"`
	Ascent         float64               `json:"ascent,omitempty"`
	Descent        float64               `json:"descent,omitempty"`
	LineGap        float64               `json:"lineGap,omitempty"`
	CellH          int                   `json:"cellH,omitempty"`
	PortraitDesign *webPortraitDesignOut `json:"portraitDesign,omitempty"`
}

// webPortraitDesignOut は web.portraitDesign を頁が縦の design を決められる形にした物（maxHeight は既定を埋めてある）。
type webPortraitDesignOut struct {
	Width     int `json:"width"`
	MinHeight int `json:"minHeight"`
	MaxHeight int `json:"maxHeight"`
}

// resolveWebStartPrompt は web.startPrompt を読む。無い・空なら既定の文言。
func resolveWebStartPrompt(raw json.RawMessage) (string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return webDefaultStartPrompt, nil
	}
	var s struct {
		StartPrompt *string `json:"startPrompt"`
	}
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", fmt.Errorf("project.json の web.startPrompt を読めない: %v\n  次: 字にする（例 \"タッチして開始\"）", err)
	}
	if s.StartPrompt == nil || strings.TrimSpace(*s.StartPrompt) == "" {
		return webDefaultStartPrompt, nil
	}
	return *s.StartPrompt, nil
}

// portraitDesignOut は web.portraitDesign を頁へ渡す形にする。maxHeight の既定は ProjectLoader と同じ（width × 2.4 と minHeight の大きい方）。
func portraitDesignOut(p *exportPortraitDesign) *webPortraitDesignOut {
	if p == nil || p.Width == nil || p.MinHeight == nil {
		return nil
	}
	out := &webPortraitDesignOut{Width: *p.Width, MinHeight: *p.MinHeight}
	if p.MaxHeight != nil {
		out.MaxHeight = *p.MaxHeight
	} else {
		out.MaxHeight = max(int(float64(*p.Width)*2.4), *p.MinHeight)
	}
	return out
}

// bootFontData は engine/src/render2d/BootFontData.flix（make boot-font の生成物）から読んだ素データ。
type bootFontData struct {
	Side, CellH, LogoSide           int
	FontSize, Ascent, Descent, Gap  float64
	Glyphs, Bits, Palette, LogoBits string
}

var (
	bootIntDefRe    = regexp.MustCompile(`def (\w+)\(\): Int32 = (\d+)`)
	bootFloatDefRe  = regexp.MustCompile(`def (\w+)\(\): Float64 = ([0-9.]+)`)
	bootStringDefRe = regexp.MustCompile(`def (\w+)\(\): String = "([0-9a-fA-F]*)"`)
	bootListDefRe   = regexp.MustCompile(`(?s)def (\w+)\(\): List\[String\] =(.*?)Nil`)
	bootHexLitRe    = regexp.MustCompile(`"([0-9a-fA-F]*)"`)
)

// parseBootFontData は BootFontData.flix の字から素データを抜く（読み解きの決まりは BootFont.flix と同じ）。
func parseBootFontData(src string) (bootFontData, error) {
	var d bootFontData
	ints := map[string]int{}
	for _, m := range bootIntDefRe.FindAllStringSubmatch(src, -1) {
		n, _ := strconv.Atoi(m[2])
		ints[m[1]] = n
	}
	floats := map[string]float64{}
	for _, m := range bootFloatDefRe.FindAllStringSubmatch(src, -1) {
		f, _ := strconv.ParseFloat(m[2], 64)
		floats[m[1]] = f
	}
	strs := map[string]string{}
	for _, m := range bootStringDefRe.FindAllStringSubmatch(src, -1) {
		strs[m[1]] = m[2]
	}
	for _, m := range bootListDefRe.FindAllStringSubmatch(src, -1) {
		var sb strings.Builder
		for _, lit := range bootHexLitRe.FindAllStringSubmatch(m[2], -1) {
			sb.WriteString(lit[1])
		}
		strs[m[1]] = sb.String()
	}
	d.Side, d.CellH, d.LogoSide = ints["side"], ints["cellH"], ints["logoSide"]
	d.FontSize, d.Ascent, d.Descent, d.Gap = floats["fontSize"], floats["ascent"], floats["descent"], floats["lineGap"]
	d.Glyphs, d.Bits, d.Palette, d.LogoBits = strs["glyphsHex"], strs["bitsHex"], strs["logoPaletteHex"], strs["logoHex"]
	if d.Side <= 0 || d.LogoSide <= 0 || d.CellH <= 0 || d.FontSize <= 0 {
		return d, fmt.Errorf("side・cellH・logoSide・fontSize のどれかが読めない")
	}
	if len(d.Bits)*4 != d.Side*d.Side {
		return d, fmt.Errorf("bitsHex が %d 桁（%d×%d の 1bit なら %d 桁）", len(d.Bits), d.Side, d.Side, d.Side*d.Side/4)
	}
	if len(d.LogoBits) != d.LogoSide*d.LogoSide {
		return d, fmt.Errorf("logoHex が %d 桁（%d×%d の 4bit なら %d 桁）", len(d.LogoBits), d.LogoSide, d.LogoSide, d.LogoSide*d.LogoSide)
	}
	if len(d.Palette) == 0 || len(d.Palette)%8 != 0 || len(d.Glyphs) == 0 || len(d.Glyphs)%14 != 0 {
		return d, fmt.Errorf("logoPaletteHex か glyphsHex の桁が合わない")
	}
	return d, nil
}

func hexNibble(c byte) int {
	n, err := strconv.ParseUint(string(c), 16, 8)
	if err != nil {
		return 0
	}
	return int(n)
}

// fontPNG は 1bit のアトラスを白と透明の PNG にする（上位ビットが左）。
func (d bootFontData) fontPNG() ([]byte, error) {
	img := image.NewNRGBA(image.Rect(0, 0, d.Side, d.Side))
	for i := 0; i < len(d.Bits); i++ {
		bits := hexNibble(d.Bits[i])
		for k := 0; k < 4; k++ {
			if bits&(8>>k) != 0 {
				p := i*4 + k
				img.SetNRGBA(p%d.Side, p/d.Side, color.NRGBA{255, 255, 255, 255})
			}
		}
	}
	return encodeSplashPNG(img)
}

// logoPNG は色票の番号（4bit）の並びをロゴの PNG にする。
func (d bootFontData) logoPNG() ([]byte, error) {
	var palette []color.NRGBA
	for i := 0; i+8 <= len(d.Palette); i += 8 {
		b, _ := strconv.ParseUint(d.Palette[i:i+8], 16, 32)
		palette = append(palette, color.NRGBA{uint8(b >> 24), uint8(b >> 16), uint8(b >> 8), uint8(b)})
	}
	img := image.NewNRGBA(image.Rect(0, 0, d.LogoSide, d.LogoSide))
	for i := 0; i < len(d.LogoBits); i++ {
		n := hexNibble(d.LogoBits[i])
		if n < len(palette) {
			img.SetNRGBA(i%d.LogoSide, i/d.LogoSide, palette[n])
		}
	}
	return encodeSplashPNG(img)
}

func encodeSplashPNG(img image.Image) ([]byte, error) {
	var buf bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	if err := enc.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func pngDataURL(b []byte) string {
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(b)
}

// buildWebSplash は engine の BootFontData.flix から起動画面の材料を作る。読めない時は文言だけの splash と知らせの行を返す
// （頁はロゴと題字を描かずにゲージと文言だけを出す）。
// WhyNot: 読めない時に書き出しを止めない — 起動画面の飾りが欠けるだけで、ゲームは遊べる。
func buildWebSplash(engine, prompt string, portrait *webPortraitDesignOut) (webSplash, string) {
	s := webSplash{StartPrompt: prompt, PortraitDesign: portrait}
	path := filepath.Join(engine, "engine", "src", "render2d", "BootFontData.flix")
	src, err := os.ReadFile(path)
	if err != nil {
		return s, fmt.Sprintf("起動画面のロゴと字を読めない（%v）— 頁はゲージと文言だけを出す", err)
	}
	d, err := parseBootFontData(string(src))
	if err != nil {
		return s, fmt.Sprintf("%s を読み解けない（%v）— 頁はゲージと文言だけを出す。次: make boot-font で作り直す", path, err)
	}
	font, err := d.fontPNG()
	if err != nil {
		return s, fmt.Sprintf("起動画面の字を PNG にできない（%v）", err)
	}
	logo, err := d.logoPNG()
	if err != nil {
		return s, fmt.Sprintf("起動画面のロゴを PNG にできない（%v）", err)
	}
	s.Font, s.Logo, s.Glyphs = pngDataURL(font), pngDataURL(logo), d.Glyphs
	s.FontSize, s.Ascent, s.Descent, s.LineGap, s.CellH = d.FontSize, d.Ascent, d.Descent, d.Gap, d.CellH
	return s, ""
}
