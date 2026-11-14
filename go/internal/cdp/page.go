package cdp

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"time"
)

// PageOptions は OpenPage の指定。
type PageOptions struct {
	Chrome string // 空なら FindChrome
	Width  int    // 0 なら 800
	Height int    // 0 なら 600
	Mobile bool   // viewport の meta とタッチを機種のとおりに効かせる
	// Touch は指の機種にする（SetTouch(true) と同じ。pointer: coarse・hover: none）。
	Touch bool
	// InitScript は頁のどの script よりも先に、頁を開くたびに流す（console を拾う仕掛けなど）。
	InitScript string
}

// Page は自分が起こした Chrome の 1 頁。使い終えたら Close。
type Page struct {
	b       *browser
	c       *client
	Chrome  string
	Version string
}

const pageStep = 10 * time.Second

// OpenPage は Chrome を起こし、about:blank の頁を前へ出して大きさを決めた所で返す。
func OpenPage(opt PageOptions) (*Page, error) {
	if opt.Width <= 0 {
		opt.Width = 800
	}
	if opt.Height <= 0 {
		opt.Height = 600
	}
	exe := opt.Chrome
	if exe == "" {
		found, err := FindChrome()
		if err != nil {
			return nil, err
		}
		exe = found
	}
	b, err := launchChrome(exe, opt.Width, opt.Height, 20*time.Second)
	if err != nil {
		return nil, err
	}
	p := &Page{b: b, Chrome: exe, Version: browserVersion(b)}
	wsURL, err := b.pageWS(10 * time.Second)
	if err != nil {
		b.stop()
		return nil, err
	}
	ws, err := dialWebSocket(wsURL, 5*time.Second)
	if err != nil {
		b.stop()
		return nil, fmt.Errorf("頁の CDP につながらない: %w", err)
	}
	p.c = &client{ws: ws}
	if err := p.setup(opt); err != nil {
		p.Close()
		return nil, err
	}
	return p, nil
}

func (p *Page) setup(opt PageOptions) error {
	// WhyNot: 起動時の頁は --headless=new でも visibilityState が hidden のままで rAF が一度も回らない（Chrome 156・macOS で確認）。
	// 前へ出して focus も装わないと、rAF の中で描く頁は合図を出せない。
	if _, err := p.c.call("Page.bringToFront", nil, pageStep); err != nil {
		return err
	}
	// WhyNot: Page.enable を省かない — 省くと addScriptToEvaluateOnNewDocument が受け付けられるだけで、開いた頁で一度も流れない
	if _, err := p.c.call("Page.enable", nil, pageStep); err != nil {
		return err
	}
	if _, err := p.c.call("Emulation.setFocusEmulationEnabled", map[string]any{"enabled": true}, pageStep); err != nil {
		return err
	}
	if _, err := p.c.call("Emulation.setDeviceMetricsOverride", map[string]any{
		"width": opt.Width, "height": opt.Height, "deviceScaleFactor": 1, "mobile": opt.Mobile,
	}, pageStep); err != nil {
		return err
	}
	if opt.Touch {
		if err := p.SetTouch(true); err != nil {
			return err
		}
	}
	if opt.InitScript != "" {
		if _, err := p.c.call("Page.addScriptToEvaluateOnNewDocument", map[string]any{"source": opt.InitScript}, pageStep); err != nil {
			return err
		}
	}
	return nil
}

// Navigate は URL を開く（頁の load は待たない。合図は Eval で頁を覗いて取る）。
func (p *Page) Navigate(url string) error {
	nav, err := p.c.call("Page.navigate", map[string]any{"url": url}, pageStep)
	if err != nil {
		return err
	}
	var navRes struct {
		ErrorText string `json:"errorText"`
	}
	_ = json.Unmarshal(nav, &navRes)
	if navRes.ErrorText != "" {
		return fmt.Errorf("頁を開けない %s: %s", url, navRes.ErrorText)
	}
	return nil
}

// Eval は頁の中で式を評価し（Promise は解けるまで待つ）、値を out へ読む。out が nil なら捨てる。
func (p *Page) Eval(expr string, out any) error {
	raw, err := p.c.evaluate(expr, 30*time.Second)
	if err != nil {
		return err
	}
	if out == nil || len(raw) == 0 {
		return nil
	}
	return json.Unmarshal(raw, out)
}

// WaitFor は式が true を返すまで待つ。
func (p *Page) WaitFor(expr string, wait time.Duration) error {
	deadline := time.Now().Add(wait)
	for {
		var ok bool
		// WhyNot: 頁の移り変わりの途中は評価が失敗することがあるので、失敗は待ち続ける理由として扱う。
		if err := p.Eval(expr, &ok); err == nil && ok {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s 待っても %s が true にならない", wait, expr)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// Screenshot は今の頁の見えている所を撮る。
func (p *Page) Screenshot() (*image.NRGBA, error) {
	raw, err := p.c.call("Page.captureScreenshot", map[string]any{"format": "png"}, pageStep)
	if err != nil {
		return nil, err
	}
	var res struct {
		Data string `json:"data"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return nil, err
	}
	data, err := base64.StdEncoding.DecodeString(res.Data)
	if err != nil {
		return nil, err
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	out := image.NewNRGBA(img.Bounds())
	draw.Draw(out, out.Bounds(), img, img.Bounds().Min, draw.Src)
	return out, nil
}

// Close は頁の接続を閉じ、Chrome を止める。
func (p *Page) Close() {
	if p.c != nil {
		p.c.ws.close()
	}
	p.b.stop()
}
