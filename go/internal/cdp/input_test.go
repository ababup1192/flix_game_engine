package cdp

import (
	"testing"
)

// keyPage は keydown を window.__keys に溜める空の頁を開く。Chrome が無い機械と -short では飛ばす。
func keyPage(t *testing.T, opt PageOptions) *Page {
	t.Helper()
	if testing.Short() {
		t.Skip("-short")
	}
	if _, err := FindChrome(); err != nil {
		t.Skip(err)
	}
	p, err := OpenPage(opt)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	if err := p.Navigate(`data:text/html,<meta name="viewport" content="width=device-width"><script>window.__keys=[];addEventListener("keydown",e=>__keys.push({key:e.key,meta:e.metaKey,shift:e.shiftKey,trusted:e.isTrusted}))</script>`); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`Array.isArray(window.__keys)`, pageStep); err != nil {
		t.Fatal(err)
	}
	return p
}

func evalBool(t *testing.T, p *Page, expr string) bool {
	t.Helper()
	var b bool
	if err := p.Eval(expr, &b); err != nil {
		t.Fatal(err)
	}
	return b
}

func TestMobileAloneKeepsMousePointer(t *testing.T) {
	// 機種を Mobile にするだけでは pointer: coarse にならない（SetTouch が要る理由）
	p := keyPage(t, PageOptions{Width: 820, Height: 1180, Mobile: true})
	if evalBool(t, p, `matchMedia("(pointer: coarse)").matches`) {
		t.Fatal("Mobile だけで pointer: coarse になった")
	}
}

func TestTouchOptionMakesPointerCoarseAndHoverNone(t *testing.T) {
	p := keyPage(t, PageOptions{Width: 820, Height: 1180, Mobile: true, Touch: true})
	if !evalBool(t, p, `matchMedia("(pointer: coarse) and (hover: none)").matches`) {
		t.Fatal("Touch で pointer: coarse・hover: none にならない")
	}
}

func TestSetTouchFalseGoesBackToMouse(t *testing.T) {
	p := keyPage(t, PageOptions{Width: 820, Height: 1180, Touch: true})
	if err := p.SetTouch(false); err != nil {
		t.Fatal(err)
	}
	if !evalBool(t, p, `matchMedia("(hover: hover) and (pointer: fine)").matches`) {
		t.Fatal("SetTouch(false) でマウスの形に戻らない")
	}
}

func TestSetViewportChangesInnerWidth(t *testing.T) {
	p := keyPage(t, PageOptions{Width: 375, Height: 667})
	if err := p.SetViewport(1440, 900, false); err != nil {
		t.Fatal(err)
	}
	if !evalBool(t, p, `innerWidth === 1440 && innerHeight === 900`) {
		t.Fatal("大きさが 1440×900 にならない")
	}
}

func TestPressKeyWithMetaIsTrusted(t *testing.T) {
	p := keyPage(t, PageOptions{})
	if err := p.PressKey("s", ModMeta); err != nil {
		t.Fatal(err)
	}
	if !evalBool(t, p, `__keys.length === 1 && __keys[0].key === "s" && __keys[0].meta && __keys[0].trusted`) {
		t.Fatal("⌘S が trusted な keydown で届かない")
	}
}

func TestPressKeyWithShiftCarriesShift(t *testing.T) {
	p := keyPage(t, PageOptions{})
	if err := p.PressKey("ArrowLeft", ModShift); err != nil {
		t.Fatal(err)
	}
	if !evalBool(t, p, `__keys[0].key === "ArrowLeft" && __keys[0].shift`) {
		t.Fatal("Shift ← が届かない")
	}
}

func TestPressKeyRejectsUnknownName(t *testing.T) {
	if _, err := keyFor("F13", 0); err == nil {
		t.Fatal("知らないキーを通した")
	}
}
