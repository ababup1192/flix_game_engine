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
