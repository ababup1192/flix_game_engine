package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"strings"
)

// ホーム画面に追加した時に全画面のアプリとして開くための物（web app manifest・アイコン・head の meta）。
// 決まりは docs/web-export.md の「ホーム画面に追加して全画面で開く」。
const (
	webManifestFile        = "manifest.webmanifest"
	webAppleTouchIconFile  = "apple-touch-icon.png"
	webAppleTouchIconSide  = 180
	webManifestBackground  = "#0b0e12"
	webManifestThemeColor  = "#000000"
	webEngineLogoIconRatio = 0.75
)

// webManifestIcons は manifest に載せるアイコン（Android の Chrome が 192 と 512 を要る）。
var webManifestIcons = []struct {
	File string
	Side int
}{{"icon-192.png", 192}, {"icon-512.png", 512}}

type webAppIconSettings struct {
	AppIcon string `json:"appIcon"`
}

// resolveWebAppIcon は web.appIcon（ゲームの根からの PNG の道）を絶対の道にする。書いていなければ空（engine のロゴで作る）。
// WhyNot: 書き出しの最後まで読まずにおかない — 組み立てと TeaVM の数分の後に「読めない」で止まる。
func resolveWebAppIcon(game string, raw json.RawMessage) (string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", nil
	}
	var s webAppIconSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", fmt.Errorf("project.json の web.appIcon を読めない: %v\n  次: ゲームの根からの PNG の道にする（例 \"assets/icon.png\"）", err)
	}
	if strings.TrimSpace(s.AppIcon) == "" {
		return "", nil
	}
	rel := filepath.FromSlash(s.AppIcon)
	if filepath.IsAbs(rel) || strings.HasPrefix(filepath.Clean(rel), "..") {
		return "", fmt.Errorf("project.json の web.appIcon %q がゲームのフォルダの外を指す。\n  次: ゲームの根からの道にする（例 \"assets/icon.png\"）", s.AppIcon)
	}
	abs := filepath.Join(game, rel)
	if _, err := loadPNG(abs); err != nil {
		return "", fmt.Errorf("project.json の web.appIcon %q を PNG として読めない: %v\n  次: 正方形の PNG（512px 以上が良い）を置く", s.AppIcon, err)
	}
	return abs, nil
}

func loadPNG(path string) (image.Image, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return png.Decode(f)
}

// webManifest は manifest.webmanifest の形。道は全部 manifest からの相対（GitHub Pages の /<repo>/play/ の下でも動く）。
// WhyNot: display を fullscreen にしない — iOS の Safari がホーム画面のアプリとして開くと書いているのは standalone だけ。
// 全画面を知る Chrome（Android）には display_override で fullscreen を先に読ませる。
type webManifest struct {
	ID              string            `json:"id"`
	Name            string            `json:"name"`
	ShortName       string            `json:"short_name"`
	StartURL        string            `json:"start_url"`
	Scope           string            `json:"scope"`
	Display         string            `json:"display"`
	DisplayOverride []string          `json:"display_override"`
	Orientation     string            `json:"orientation"`
	BackgroundColor string            `json:"background_color"`
	ThemeColor      string            `json:"theme_color"`
	Icons           []webManifestIcon `json:"icons"`
}

type webManifestIcon struct {
	Src     string `json:"src"`
	Sizes   string `json:"sizes"`
	Type    string `json:"type"`
	Purpose string `json:"purpose"`
}

func buildWebManifest(title, orientation string) webManifest {
	if strings.TrimSpace(title) == "" {
		title = "game"
	}
	if orientation == "" {
		orientation = "any"
	}
	m := webManifest{
		ID: "./", Name: title, ShortName: title, StartURL: "./", Scope: "./",
		Display: "standalone", DisplayOverride: []string{"fullscreen", "standalone"}, Orientation: orientation,
		BackgroundColor: webManifestBackground, ThemeColor: webManifestThemeColor,
	}
	for _, ic := range webManifestIcons {
		m.Icons = append(m.Icons, webManifestIcon{ic.File, fmt.Sprintf("%dx%d", ic.Side, ic.Side), "image/png", "any"})
	}
	return m
}

// writeWebApp は manifest.webmanifest と 3 枚のアイコン（180・192・512）を書く。アイコンの元は web.appIcon、無ければ engine のロゴ。
// WhyNot: reference/title.png を元にしない — 横長のタイトルの絵を正方形に切ると題字が欠け、ゲームごとに欠け方が違う。
func writeWebApp(p exportWebPaths, b webBundle) error {
	manifest, err := json.MarshalIndent(buildWebManifest(b.Title, b.Orientation), "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(p.Out, webManifestFile), append(manifest, '\n'), 0o644); err != nil {
		return err
	}
	src, ratio, err := webAppIconSource(p)
	if err != nil {
		return err
	}
	sides := map[string]int{webAppleTouchIconFile: webAppleTouchIconSide}
	for _, ic := range webManifestIcons {
		sides[ic.File] = ic.Side
	}
	for name, side := range sides {
		data, err := encodeSplashPNG(renderWebAppIcon(src, side, ratio))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(p.Out, name), data, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// webAppIconSource はアイコンの元の絵と、正方形の中に占める割合を返す。engine のロゴを読めない時は nil（下地の色だけのアイコン）。
// WhyNot: engine のロゴを端まで広げない — Android は丸や角丸に切り抜き、端の絵が欠ける。
// WhyNot: engine のロゴを読めない時に書き出しを止めない — 起動画面と同じく飾りが欠けるだけで、ゲームは遊べる。
func webAppIconSource(p exportWebPaths) (image.Image, float64, error) {
	if p.AppIcon != "" {
		img, err := loadPNG(p.AppIcon)
		if err != nil {
			return nil, 0, fmt.Errorf("web.appIcon %s を読めない: %v", p.AppIcon, err)
		}
		return img, 1, nil
	}
	img, err := engineLogoImage(p.Engine)
	if err != nil {
		ewLogf("知らせ: ホーム画面のアイコンの元の engine のロゴを読めない（%v）— 下地の色だけのアイコンにした。次: project.json の web.appIcon に PNG を書く", err)
		return nil, 0, nil
	}
	return img, webEngineLogoIconRatio, nil
}

func engineLogoImage(engine string) (image.Image, error) {
	src, err := os.ReadFile(bootFontDataPath(engine))
	if err != nil {
		return nil, err
	}
	d, err := parseBootFontData(string(src))
	if err != nil {
		return nil, err
	}
	data, err := d.logoPNG()
	if err != nil {
		return nil, err
	}
	return png.Decode(bytes.NewReader(data))
}

// renderWebAppIcon は src を side×side の正方形の真ん中に、長い辺が side×ratio になるよう置く。下地は起動画面と同じ色で塗りつぶす。
// 大きくする時は整数倍で近い画素を写し（ドット絵がぼけない）、小さくする時は覆う画素の平均を取る。
// WhyNot: 透明を残さない — iOS はホーム画面のアイコンの透明を黒で埋め、Android は白で埋める端末がある。
func renderWebAppIcon(src image.Image, side int, ratio float64) *image.NRGBA {
	dst := image.NewNRGBA(image.Rect(0, 0, side, side))
	bg := color.NRGBA{0x0b, 0x0e, 0x12, 0xff}
	for i := 0; i < len(dst.Pix); i += 4 {
		dst.Pix[i], dst.Pix[i+1], dst.Pix[i+2], dst.Pix[i+3] = bg.R, bg.G, bg.B, bg.A
	}
	if src == nil {
		return dst
	}
	sb := src.Bounds()
	sw, sh := sb.Dx(), sb.Dy()
	if sw == 0 || sh == 0 {
		return dst
	}
	box := float64(side) * ratio
	scale := box / float64(max(sw, sh))
	// WhyNot: 大きくする倍率に端数を残さない — ドット絵の 1 画素が 2 画素と 3 画素に分かれ、線の太さが揃わない。
	if scale >= 1 {
		scale = math.Floor(scale)
	}
	dw, dh := max(1, int(float64(sw)*scale+0.5)), max(1, int(float64(sh)*scale+0.5))
	ox, oy := (side-dw)/2, (side-dh)/2
	for y := 0; y < dh; y++ {
		y0, y1 := spanOf(y, dh, sh)
		for x := 0; x < dw; x++ {
			x0, x1 := spanOf(x, dw, sw)
			var r, g, b, a float64
			for sy := y0; sy < y1; sy++ {
				for sx := x0; sx < x1; sx++ {
					c := color.NRGBAModel.Convert(src.At(sb.Min.X+sx, sb.Min.Y+sy)).(color.NRGBA)
					w := float64(c.A)
					r, g, b, a = r+float64(c.R)*w, g+float64(c.G)*w, b+float64(c.B)*w, a+w
				}
			}
			n := float64((y1 - y0) * (x1 - x0))
			alpha := a / n / 255
			i := dst.PixOffset(ox+x, oy+y)
			for k, v := range []float64{r, g, b} {
				fg := 0.0
				if a > 0 {
					fg = v / a
				}
				dst.Pix[i+k] = uint8(fg*alpha + float64(dst.Pix[i+k])*(1-alpha) + 0.5)
			}
		}
	}
	return dst
}

// spanOf は dst の d 番目の画素が覆う src の画素の範囲 [lo, hi)（dn 個の dst に sn 個の src を割る）。大きくする時は 1 画素。
func spanOf(d, dn, sn int) (int, int) {
	lo := d * sn / dn
	hi := ((d + 1) * sn) / dn
	if hi <= lo {
		hi = lo + 1
	}
	return lo, min(hi, sn)
}

// webAppHead は index.html の head に足す、題と manifest と apple-touch-icon の行（版の付いた URL）。
// 版の要らない meta（apple-mobile-web-app-capable など）は engine_web/js/index.html に直に書いてある。
// WhyNot: manifest とアイコンを版の無い URL にしない — Service Worker は ?v= の付いた物しか受けず、版の無い URL は置き場の max-age の間、版を上げた後も古い題とアイコンが出る。
func webAppHead(title, hash string) string {
	if strings.TrimSpace(title) == "" {
		title = "game"
	}
	t := html.EscapeString(title)
	v := "?v=" + hash
	return `<meta name="apple-mobile-web-app-title" content="` + t + `">
<link rel="manifest" href="` + webManifestFile + v + `">
<link rel="apple-touch-icon" href="` + webAppleTouchIconFile + v + `">
`
}

// withWebTitle は index.html の <title> の中身を title に替える（無ければそのまま）。
// WhyNot: fge-web.js が題を入れるのを待たない — iOS の「ホーム画面に追加」は頁を読み終える前に押されると <title> の字を名前の既定にする。
func withWebTitle(page, title string) string {
	if strings.TrimSpace(title) == "" {
		return page
	}
	lo := strings.Index(page, "<title>")
	hi := strings.Index(page, "</title>")
	if lo < 0 || hi < lo {
		return page
	}
	return page[:lo+len("<title>")] + html.EscapeString(title) + page[hi:]
}
