package cdp

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"time"
)

// Options は Capture の指定。
type Options struct {
	URL    string
	Chrome string        // 空なら FindChrome
	Width  int           // 頁の viewport。0 なら 800
	Height int           // 0 なら 600
	Wait   time.Duration // 合図を待つ上限。0 なら 30 秒
}

// Result は受け取った絵と、頁が名乗った描き手（WebGL の UNMASKED_RENDERER など。無ければ空）。
type Result struct {
	Image    *image.NRGBA
	Renderer string
	Chrome   string
	Version  string
}

// pixelPayload は頁の window.fgeCapture() が返す値（docs/web-capture.md）。
type pixelPayload struct {
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	RGBA     string `json:"rgba"`
	Origin   string `json:"origin"`
	Renderer string `json:"renderer"`
}

const readyProbe = `(() => ({
  ready: window.fgeCaptureReady === true,
  error: typeof window.fgeCaptureError === "string" ? window.fgeCaptureError : "",
  state: document.readyState
}))()`

type probe struct {
	Ready bool   `json:"ready"`
	Error string `json:"error"`
	State string `json:"state"`
}

// Capture は Chrome を起こして URL を開き、頁の合図を待って画素を受け取り、Chrome を止める。
func Capture(opt Options) (*Result, error) {
	if opt.Wait <= 0 {
		opt.Wait = 30 * time.Second
	}
	page, err := OpenPage(PageOptions{Chrome: opt.Chrome, Width: opt.Width, Height: opt.Height})
	if err != nil {
		return nil, err
	}
	defer page.Close()
	if err := page.Navigate(opt.URL); err != nil {
		return nil, err
	}
	c := page.c
	const step = 10 * time.Second
	if err := waitReady(c, opt.Wait); err != nil {
		return nil, err
	}
	raw, err := c.evaluate(`(typeof window.fgeCapture === "function") ? window.fgeCapture() : null`, step)
	if err != nil {
		return nil, err
	}
	img, renderer, err := decodePayload(raw)
	if err != nil {
		return nil, err
	}
	return &Result{Image: img, Renderer: renderer, Chrome: page.Chrome, Version: page.Version}, nil
}

func waitReady(c *client, wait time.Duration) error {
	deadline := time.Now().Add(wait)
	var last probe
	for {
		raw, err := c.evaluate(readyProbe, 5*time.Second)
		if err != nil {
			return err
		}
		// WhyNot: 頁の移り変わりの途中は値が空で返ることがあるので、読めない回は失敗にせず次を待つ。
		if json.Unmarshal(raw, &last) == nil {
			if last.Error != "" {
				return fmt.Errorf("頁が失敗を知らせた (window.fgeCaptureError): %s", last.Error)
			}
			if last.Ready {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s 待っても window.fgeCaptureReady が true にならない (document.readyState=%q)", wait, last.State)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// decodePayload は頁の返した値を絵にする。readPixels の並び（下の行が先）を既定とし、上の行を先に並べ直す。
func decodePayload(raw json.RawMessage) (*image.NRGBA, string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, "", errors.New("window.fgeCapture が無いか null を返した")
	}
	var p pixelPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, "", fmt.Errorf("window.fgeCapture の値の形が違う: %w", err)
	}
	if p.Width <= 0 || p.Height <= 0 {
		return nil, "", fmt.Errorf("window.fgeCapture の width/height が正でない: %dx%d", p.Width, p.Height)
	}
	pix, err := base64.StdEncoding.DecodeString(p.RGBA)
	if err != nil {
		return nil, "", fmt.Errorf("window.fgeCapture の rgba が base64 でない: %w", err)
	}
	stride := p.Width * 4
	if len(pix) != stride*p.Height {
		return nil, "", fmt.Errorf("rgba の長さ %d が %dx%dx4=%d と合わない", len(pix), p.Width, p.Height, stride*p.Height)
	}
	img := image.NewNRGBA(image.Rect(0, 0, p.Width, p.Height))
	switch p.Origin {
	case "", "bottom-left":
		for y := 0; y < p.Height; y++ {
			src := (p.Height - 1 - y) * stride
			copy(img.Pix[y*img.Stride:y*img.Stride+stride], pix[src:src+stride])
		}
	case "top-left":
		for y := 0; y < p.Height; y++ {
			copy(img.Pix[y*img.Stride:y*img.Stride+stride], pix[y*stride:(y+1)*stride])
		}
	default:
		return nil, "", fmt.Errorf("origin は bottom-left か top-left: %q", p.Origin)
	}
	return img, p.Renderer, nil
}

func browserVersion(b *browser) string {
	ws, err := dialWebSocket(b.browserWS, 2*time.Second)
	if err != nil {
		return ""
	}
	defer ws.close()
	c := &client{ws: ws}
	raw, err := c.call("Browser.getVersion", nil, 2*time.Second)
	if err != nil {
		return ""
	}
	var v struct {
		Product string `json:"product"`
	}
	_ = json.Unmarshal(raw, &v)
	return v.Product
}
