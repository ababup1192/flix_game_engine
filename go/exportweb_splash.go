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
	pathpkg "path"
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
	AfterTap       *webAfterTap          `json:"afterTap,omitempty"`
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

// bootFontDataPath は起動画面のロゴと字の元（make boot-font の生成物）の道。
func bootFontDataPath(engine string) string {
	return filepath.Join(engine, "engine", "src", "render2d", "BootFontData.flix")
}

// buildWebSplash は engine の BootFontData.flix から起動画面の材料を作る。読めない時は文言だけの splash と知らせの行を返す
// （頁はロゴと題字を描かずにゲージと文言だけを出す）。
// WhyNot: 読めない時に書き出しを止めない — 起動画面の飾りが欠けるだけで、ゲームは遊べる。
func buildWebSplash(engine, prompt string, portrait *webPortraitDesignOut) (webSplash, string) {
	s := webSplash{StartPrompt: prompt, PortraitDesign: portrait}
	path := bootFontDataPath(engine)
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

// 押した後のロゴ（project.json の web.splash）の既定と上限。
const (
	webAfterTapMinSeconds = 1.2
	// webAfterTapMaxSeconds は押した後のロゴの上限（人の要件: ロゴで押した後の待ちを延ばさない）。
	webAfterTapMaxSeconds = 3.0
)

// webAfterTap は bundle.json の splash.afterTap。頁が「タッチして開始」を押した後、待つ物が残る時だけ出すロゴの設定。
// Logo と Sound は custom の時の束の中の道（空なら engine のロゴ・合成のジングル）。WaitFor は待つ group。
type webAfterTap struct {
	Mode       string   `json:"mode"`
	Logo       string   `json:"logo,omitempty"`
	Sound      string   `json:"sound,omitempty"`
	MinSeconds float64  `json:"minSeconds"`
	MaxSeconds float64  `json:"maxSeconds"`
	WaitFor    []string `json:"waitFor,omitempty"`
}

type webAfterTapSettings struct {
	AfterTap   string    `json:"afterTap"`
	Logo       string    `json:"logo"`
	Sound      string    `json:"sound"`
	MinSeconds *float64  `json:"minSeconds"`
	MaxSeconds *float64  `json:"maxSeconds"`
	WaitFor    *[]string `json:"waitFor"`
}

// resolveWebAfterTap は web.splash を読み、bundle.json の splash.afterTap にする。
// waitFor の既定は deferredPolicy に最初に出てくる group（group が無ければ空 = 待つ物はコードだけ）。
// bundled は束に入る道（custom の絵と音がそこに無ければ誤り）、deferred は後回しの道（押した直後に要るので誤り）。
func resolveWebAfterTap(raw json.RawMessage, pol webDeferredPolicy, bundled, deferred map[string]bool) (webAfterTap, error) {
	out := webAfterTap{Mode: "engine", MinSeconds: webAfterTapMinSeconds, MaxSeconds: webAfterTapMaxSeconds}
	groups := map[string]bool{}
	for _, row := range pol.Rows {
		if row.Group == "" {
			continue
		}
		if len(groups) == 0 {
			out.WaitFor = []string{row.Group}
		}
		groups[row.Group] = true
	}
	var web struct {
		Splash json.RawMessage `json:"splash"`
	}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &web); err != nil {
			return out, fmt.Errorf("project.json の web を読めない: %v", err)
		}
	}
	if len(web.Splash) == 0 || string(web.Splash) == "null" {
		return out, nil
	}
	var s webAfterTapSettings
	dec := json.NewDecoder(bytes.NewReader(web.Splash))
	// WhyNot: 欄の書き違いを黙って通さない — maxSecond のような字は効かないまま残り、気付けない。
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		return out, fmt.Errorf("project.json の web.splash を読めない: %v\n  次: { \"afterTap\": \"engine|none|custom\", \"logo\", \"sound\", \"minSeconds\", \"maxSeconds\", \"waitFor\" } の形にする", err)
	}
	switch s.AfterTap {
	case "", "engine":
	case "none", "custom":
		out.Mode = s.AfterTap
	default:
		return out, fmt.Errorf("project.json の web.splash.afterTap %q を知らない。\n  次: engine（既定）・none（出さない）・custom（絵と音を替える）のどれかにする", s.AfterTap)
	}
	if s.MinSeconds != nil {
		out.MinSeconds = *s.MinSeconds
	}
	if s.MaxSeconds != nil {
		out.MaxSeconds = *s.MaxSeconds
	}
	if out.MinSeconds < 0 || out.MaxSeconds < out.MinSeconds || out.MaxSeconds > webAfterTapMaxSeconds {
		return out, fmt.Errorf("project.json の web.splash の minSeconds %.2f・maxSeconds %.2f が合わない。\n  次: 0 ≤ minSeconds ≤ maxSeconds ≤ %.0f にする（ロゴで押した後の待ちを延ばさない上限）", out.MinSeconds, out.MaxSeconds, webAfterTapMaxSeconds)
	}
	if s.WaitFor != nil {
		out.WaitFor = nil
		for _, g := range *s.WaitFor {
			if !groups[g] {
				return out, fmt.Errorf("project.json の web.splash.waitFor の %q は web.deferredPolicy のどの行の group にも無い。\n  次: deferredPolicy の行に \"group\": %q を書くか、waitFor から消す", g, g)
			}
			out.WaitFor = append(out.WaitFor, g)
		}
	}
	for _, item := range []struct{ key, rel string }{{"logo", s.Logo}, {"sound", s.Sound}} {
		if item.rel == "" {
			continue
		}
		if out.Mode != "custom" {
			return out, fmt.Errorf("project.json の web.splash.%s は afterTap が custom の時だけ使う（今は %s）。\n  次: afterTap を \"custom\" にするか %s を消す", item.key, out.Mode, item.key)
		}
		rel := pathpkg.Clean(strings.ReplaceAll(item.rel, "\\", "/"))
		if !bundled[rel] {
			return out, fmt.Errorf("project.json の web.splash.%s %q が束に無い。\n  次: assets/ の下に置き、project.json の textures か sounds に宣言する", item.key, item.rel)
		}
		if deferred[rel] {
			return out, fmt.Errorf("project.json の web.splash.%s %q が web.deferred に当たる（押した直後に出すので起動の前に要る）。\n  次: web.deferred から外す", item.key, item.rel)
		}
		if item.key == "logo" {
			out.Logo = rel
		} else {
			out.Sound = rel
		}
	}
	if out.Mode == "custom" && out.Logo == "" {
		return out, fmt.Errorf("project.json の web.splash.afterTap が custom なのに logo が無い。\n  次: logo に束の中の絵の道を書く（絵を替えないなら afterTap を engine に）")
	}
	return out, nil
}
