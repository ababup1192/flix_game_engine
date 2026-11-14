package cdp

import (
	"fmt"
	"strings"
)

// 修飾キー（Input.dispatchKeyEvent の modifiers のビット）。
const (
	ModAlt   = 1
	ModCtrl  = 2
	ModMeta  = 4
	ModShift = 8
)

// SetViewport は開いたままの頁の大きさを変える（resize と matchMedia の change が頁へ届く）。
func (p *Page) SetViewport(w, h int, mobile bool) error {
	_, err := p.c.call("Emulation.setDeviceMetricsOverride", map[string]any{
		"width": w, "height": h, "deviceScaleFactor": 1, "mobile": mobile,
	}, pageStep)
	return err
}

// SetTouch は指の機種（touch: true）とマウスの機種を切り替える。
// タッチの点の数と、CSS・matchMedia の pointer / hover（any- も）を一緒に替える。
// WhyNot: setTouchEmulationEnabled だけにしない — タッチの点は増えても (hover: hover) and (pointer: fine) が真のままで、頁はマウスの形を選ぶ
func (p *Page) SetTouch(touch bool) error {
	if _, err := p.c.call("Emulation.setTouchEmulationEnabled", map[string]any{"enabled": touch, "maxTouchPoints": 5}, pageStep); err != nil {
		return err
	}
	pointer, hover := "fine", "hover"
	if touch {
		pointer, hover = "coarse", "none"
	}
	_, err := p.c.call("Emulation.setEmulatedMedia", map[string]any{"features": []map[string]string{
		{"name": "pointer", "value": pointer}, {"name": "hover", "value": hover},
		{"name": "any-pointer", "value": pointer}, {"name": "any-hover", "value": hover},
	}}, pageStep)
	return err
}

// AddInitScript は次に開く頁から、頁のどの script より先に流す script を足す。
func (p *Page) AddInitScript(src string) error {
	_, err := p.c.call("Page.addScriptToEvaluateOnNewDocument", map[string]any{"source": src}, pageStep)
	return err
}

type keyDef struct {
	key, code, text string
	vk              int
}

var namedKeys = map[string]keyDef{
	" ":          {" ", "Space", " ", 32},
	"Enter":      {"Enter", "Enter", "\r", 13},
	"Escape":     {"Escape", "Escape", "", 27},
	"ArrowLeft":  {"ArrowLeft", "ArrowLeft", "", 37},
	"ArrowUp":    {"ArrowUp", "ArrowUp", "", 38},
	"ArrowRight": {"ArrowRight", "ArrowRight", "", 39},
	"ArrowDown":  {"ArrowDown", "ArrowDown", "", 40},
	"Home":       {"Home", "Home", "", 36},
	"End":        {"End", "End", "", 35},
	"[":          {"[", "BracketLeft", "[", 219},
	"]":          {"]", "BracketRight", "]", 221},
}

// keyFor は key（KeyboardEvent.key の名前か英字 1 字）を CDP のキーの字に直す。
func keyFor(key string, mods int) (keyDef, error) {
	k, ok := namedKeys[key]
	if !ok {
		if len(key) != 1 || !strings.ContainsAny(strings.ToLower(key), "abcdefghijklmnopqrstuvwxyz") {
			return keyDef{}, fmt.Errorf("知らないキー %q", key)
		}
		up := strings.ToUpper(key)
		k = keyDef{strings.ToLower(key), "Key" + up, strings.ToLower(key), int(up[0])}
	}
	if mods&ModShift != 0 && len(k.text) == 1 && k.text != " " && k.text != "\r" {
		k.key, k.text = strings.ToUpper(k.key), strings.ToUpper(k.text)
	}
	// WhyNot: ⌘・Ctrl つきで text を送らない — 字の入力として扱われ、入力欄に字が入る
	if mods&(ModCtrl|ModMeta) != 0 {
		k.text = ""
	}
	return k, nil
}

// PressKey は trusted なキーを 1 回押して離す（mods は ModAlt などの和）。
func (p *Page) PressKey(key string, mods int) error {
	k, err := keyFor(key, mods)
	if err != nil {
		return err
	}
	down := map[string]any{"type": "keyDown", "key": k.key, "code": k.code, "windowsVirtualKeyCode": k.vk, "modifiers": mods}
	if k.text != "" {
		down["text"] = k.text
	} else {
		down["type"] = "rawKeyDown"
	}
	if _, err := p.c.call("Input.dispatchKeyEvent", down, pageStep); err != nil {
		return err
	}
	_, err = p.c.call("Input.dispatchKeyEvent", map[string]any{"type": "keyUp", "key": k.key, "code": k.code, "windowsVirtualKeyCode": k.vk, "modifiers": mods}, pageStep)
	return err
}

// MoveMouse はマウスを (x, y)（CSS px）へ動かす（ホバーの吹き出しを出す・消すため）。
func (p *Page) MoveMouse(x, y float64) error {
	_, err := p.c.call("Input.dispatchMouseEvent", map[string]any{"type": "mouseMoved", "x": x, "y": y}, pageStep)
	return err
}

// Touch は指の点を trusted な touch の event として送る（kind は touchStart・touchMove・touchEnd。points は今触れている点の CSS px で、touchEnd は空）。
// 指の機種（SetTouch(true)）の頁にだけ届く。
func (p *Page) Touch(kind string, points ...[2]float64) error {
	touches := make([]map[string]any, len(points))
	for i, pt := range points {
		touches[i] = map[string]any{"x": pt[0], "y": pt[1], "id": i}
	}
	_, err := p.c.call("Input.dispatchTouchEvent", map[string]any{"type": kind, "touchPoints": touches}, pageStep)
	return err
}
