package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image/png"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveWebStartPromptDefaultsWhenMissing(t *testing.T) {
	got, err := resolveWebStartPrompt(json.RawMessage(`{"orientation": "portrait"}`))
	if err != nil || got != webDefaultStartPrompt {
		t.Errorf("web.startPrompt が無ければ既定の %q のはず: %q %v", webDefaultStartPrompt, got, err)
	}
}

func TestResolveWebStartPromptReadsGivenText(t *testing.T) {
	got, err := resolveWebStartPrompt(json.RawMessage(`{"startPrompt": "タッチして開始"}`))
	if err != nil || got != "タッチして開始" {
		t.Errorf("web.startPrompt の字をそのまま使うはず: %q %v", got, err)
	}
}

func TestResolveWebStartPromptRejectsNonString(t *testing.T) {
	if _, err := resolveWebStartPrompt(json.RawMessage(`{"startPrompt": 3}`)); err == nil {
		t.Error("web.startPrompt が字でなければ誤りのはず")
	}
}

func TestPortraitDesignOutFillsMaxHeightLikeProjectLoader(t *testing.T) {
	w, minH := 540, 960
	got := portraitDesignOut(&exportPortraitDesign{Width: &w, MinHeight: &minH})
	if got == nil || got.MaxHeight != 1296 {
		t.Errorf("maxHeight を書かない時は width × 2.4（1296）のはず: %+v", got)
	}
}

func TestBuildWebSplashDecodesEngineLogoAtItsSide(t *testing.T) {
	s, warning := buildWebSplash(filepath.Join("..", "engine_root_for_test_does_not_exist"), "Tap to start", nil)
	if warning == "" || s.Logo != "" {
		t.Fatalf("BootFontData.flix が無ければ知らせてロゴを持たないはず: %q", warning)
	}
	s, warning = buildWebSplash("..", "Tap to start", nil)
	if warning != "" {
		t.Fatal(warning)
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(s.Logo, "data:image/png;base64,"))
	if err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(bytes.NewReader(raw))
	if err != nil || img.Bounds().Dx() != 64 || img.Bounds().Dy() != 64 {
		t.Errorf("ロゴは BootFontData の一辺（64）の PNG のはず: %v %v", img.Bounds(), err)
	}
}

func TestParseBootFontDataRejectsShortBits(t *testing.T) {
	src := `def side(): Int32 = 8
def cellH(): Int32 = 2
def logoSide(): Int32 = 1
def fontSize(): Float64 = 10.0
def glyphsHex(): String = "0041000000040400"
def bitsHex(): List[String] = "ff" :: Nil
def logoPaletteHex(): String = "00000000"
def logoHex(): List[String] = "0" :: Nil`
	if _, err := parseBootFontData(src); err == nil {
		t.Error("bitsHex の桁が一辺に足りなければ誤りのはず")
	}
}

// テープの頁に渡す起動画面の材料は、ゲームのブラウザ版の bundle.json と同じ字のアトラスを持つ。
func TestTapeSplashCarriesSameFontAsWebSplash(t *testing.T) {
	web, _ := buildWebSplash("..", "", nil)
	got, warning := tapeSplash("..")
	if warning != "" || got.Font == "" || got.Font != web.Font {
		t.Errorf("テープの頁の字のアトラスがゲームのブラウザ版と違う（知らせ %q・%d 字）", warning, len(got.Font))
	}
}

func afterTapPolicy(t *testing.T, rows string) webDeferredPolicy {
	t.Helper()
	pol, err := resolveWebDeferredPolicy(json.RawMessage(`{"deferredPolicy": ` + rows + `}`))
	if err != nil {
		t.Fatal(err)
	}
	return pol
}

func TestAfterTapWaitForDefaultsToFirstGroup(t *testing.T) {
	pol := afterTapPolicy(t, `[{"match": "assets/x/*.png", "onMissing": "placeholder"}, {"match": "assets/a/*.png", "group": "start"}, {"match": "assets/b/*.png", "group": "late"}]`)
	got, err := resolveWebAfterTap(nil, pol, nil, nil)
	if err != nil || len(got.WaitFor) != 1 || got.WaitFor[0] != "start" {
		t.Errorf("waitFor の既定は最初の group のはず: %v %v", got.WaitFor, err)
	}
}

func TestAfterTapWithoutGroupWaitsForNothing(t *testing.T) {
	got, err := resolveWebAfterTap(nil, webDeferredPolicy{}, nil, nil)
	if err != nil || len(got.WaitFor) != 0 {
		t.Errorf("group が無ければ待つ group も無いはず: %v %v", got.WaitFor, err)
	}
}

func TestAfterTapRejectsUnknownGroup(t *testing.T) {
	_, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"waitFor": ["start"]}}`), webDeferredPolicy{}, nil, nil)
	if err == nil {
		t.Error("deferredPolicy に無い group は誤りのはず")
	}
}

func TestAfterTapRejectsMaxOverThreeSeconds(t *testing.T) {
	_, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"maxSeconds": 5}}`), webDeferredPolicy{}, nil, nil)
	if err == nil {
		t.Error("maxSeconds が 3 秒を超えたら誤りのはず")
	}
}

func TestAfterTapNoneTurnsLogoOff(t *testing.T) {
	got, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"afterTap": "none"}}`), webDeferredPolicy{}, nil, nil)
	if err != nil || got.Mode != "none" {
		t.Errorf("none のはず: %q %v", got.Mode, err)
	}
}

func TestAfterTapCustomNeedsLogo(t *testing.T) {
	_, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"afterTap": "custom"}}`), webDeferredPolicy{}, nil, nil)
	if err == nil {
		t.Error("custom で logo が無ければ誤りのはず")
	}
}

func TestAfterTapCustomLogoMustNotBeDeferred(t *testing.T) {
	in := map[string]bool{"assets/ui/logo.png": true}
	_, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"afterTap": "custom", "logo": "assets/ui/logo.png"}}`), webDeferredPolicy{}, in, in)
	if err == nil {
		t.Error("後回しの絵は押した直後に出せないので誤りのはず")
	}
}

func TestAfterTapRejectsUnknownField(t *testing.T) {
	_, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"maxSecond": 2}}`), webDeferredPolicy{}, nil, nil)
	if err == nil {
		t.Error("知らない欄は誤りのはず")
	}
}

func TestAfterTapRejectsMinOverMax(t *testing.T) {
	_, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"minSeconds": 2.5, "maxSeconds": 2}}`), webDeferredPolicy{}, nil, nil)
	if err == nil {
		t.Error("minSeconds が maxSeconds を超えたら誤りのはず")
	}
}

func TestAfterTapCustomTakesBundledLogo(t *testing.T) {
	in := map[string]bool{"assets/ui/logo.png": true}
	got, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"afterTap": "custom", "logo": "assets/ui/logo.png"}}`), webDeferredPolicy{}, in, nil)
	if err != nil || got.Logo != "assets/ui/logo.png" {
		t.Errorf("束の中の絵なら通るはず: %q %v", got.Logo, err)
	}
}

func TestAfterTapEmptyWaitForWaitsForNothing(t *testing.T) {
	pol := afterTapPolicy(t, `[{"match": "assets/a/*.png", "group": "start"}]`)
	got, err := resolveWebAfterTap(json.RawMessage(`{"splash": {"waitFor": []}}`), pol, nil, nil)
	if err != nil || len(got.WaitFor) != 0 {
		t.Errorf("waitFor を空に書いたら group を待たないはず: %v %v", got.WaitFor, err)
	}
}
