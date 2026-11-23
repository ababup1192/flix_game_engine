package main

import (
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebManifestPathsAreRelativeSoSubfolderHostingWorks(t *testing.T) {
	m := buildWebManifest("t", "")
	for name, got := range map[string]string{"start_url": m.StartURL, "scope": m.Scope, "id": m.ID} {
		if got != "./" {
			t.Errorf("%s は ./ のはず: %q", name, got)
		}
	}
}

func TestWebManifestOpensStandaloneAndPrefersFullscreen(t *testing.T) {
	m := buildWebManifest("t", "")
	if m.Display != "standalone" || len(m.DisplayOverride) == 0 || m.DisplayOverride[0] != "fullscreen" {
		t.Errorf("display は standalone・display_override の先頭は fullscreen のはず: %q %v", m.Display, m.DisplayOverride)
	}
}

func TestWebManifestTakesOrientationFromProject(t *testing.T) {
	if got := buildWebManifest("t", "landscape").Orientation; got != "landscape" {
		t.Errorf("orientation は web.orientation のはず: %q", got)
	}
}

func TestWebManifestOrientationDefaultsToAny(t *testing.T) {
	if got := buildWebManifest("t", "").Orientation; got != "any" {
		t.Errorf("web.orientation が無ければ any のはず: %q", got)
	}
}

func TestWebManifestNameIsProjectTitle(t *testing.T) {
	m := buildWebManifest("ルーネの泉", "")
	if m.Name != "ルーネの泉" || m.ShortName != "ルーネの泉" {
		t.Errorf("name と short_name は題のはず: %q %q", m.Name, m.ShortName)
	}
}

func TestWebAppHeadLinksManifestAndIconWithVersion(t *testing.T) {
	head := webAppHead("t", "abc123")
	for _, want := range []string{`href="manifest.webmanifest?v=abc123"`, `rel="apple-touch-icon" href="apple-touch-icon.png?v=abc123"`} {
		if !strings.Contains(head, want) {
			t.Errorf("head に %q が入るはず: %s", want, head)
		}
	}
}

func TestWebAppHeadEscapesTitle(t *testing.T) {
	if head := webAppHead(`a"<b`, "abc"); !strings.Contains(head, `content="a&#34;&lt;b"`) {
		t.Errorf("題は HTML の字に直して入るはず: %s", head)
	}
}

func TestWithWebTitleReplacesTitleText(t *testing.T) {
	if got := withWebTitle("<head><title>game</title></head>", "A&B"); got != "<head><title>A&amp;B</title></head>" {
		t.Errorf("<title> の中身が題になるはず: %s", got)
	}
}

func TestStampWebIndexPutsAppHeadInHead(t *testing.T) {
	got, err := stampWebIndex(stampTestHTML, "abc123", nil, "", webAppHead("t", "abc123"))
	if err != nil {
		t.Fatal(err)
	}
	if head := got[:strings.Index(got, "</head>")]; !strings.Contains(head, `rel="manifest"`) {
		t.Errorf("manifest の行は head に入るはず: %s", head)
	}
}

func writeTestPNG(t *testing.T, path string, img image.Image) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
}

func TestResolveWebAppIconEmptyWhenUnset(t *testing.T) {
	got, err := resolveWebAppIcon(t.TempDir(), json.RawMessage(`{"serviceWorker": true}`))
	if err != nil || got != "" {
		t.Errorf("web.appIcon が無ければ空のはず: %q %v", got, err)
	}
}

func TestResolveWebAppIconRejectsPathOutsideGame(t *testing.T) {
	if _, err := resolveWebAppIcon(t.TempDir(), json.RawMessage(`{"appIcon": "../icon.png"}`)); err == nil {
		t.Error("ゲームのフォルダの外を指す web.appIcon は誤りのはず")
	}
}

func TestResolveWebAppIconRejectsMissingFile(t *testing.T) {
	if _, err := resolveWebAppIcon(t.TempDir(), json.RawMessage(`{"appIcon": "assets/icon.png"}`)); err == nil {
		t.Error("無い web.appIcon は誤りのはず")
	}
}

func TestResolveWebAppIconReturnsAbsolutePath(t *testing.T) {
	game := t.TempDir()
	writeTestPNG(t, filepath.Join(game, "assets", "icon.png"), image.NewNRGBA(image.Rect(0, 0, 4, 4)))
	got, err := resolveWebAppIcon(game, json.RawMessage(`{"appIcon": "assets/icon.png"}`))
	if err != nil || got != filepath.Join(game, "assets", "icon.png") {
		t.Errorf("web.appIcon はゲームの根からの絶対の道になるはず: %q %v", got, err)
	}
}

func TestRenderWebAppIconIsOpaque(t *testing.T) {
	icon := renderWebAppIcon(image.NewNRGBA(image.Rect(0, 0, 8, 8)), 32, 1)
	for i := 3; i < len(icon.Pix); i += 4 {
		if icon.Pix[i] != 255 {
			t.Fatalf("アイコンに透明が残らないはず（%d 番目の alpha が %d）", i/4, icon.Pix[i])
		}
	}
}

func TestRenderWebAppIconUpscalesWithoutBlur(t *testing.T) {
	src := image.NewNRGBA(image.Rect(0, 0, 2, 1))
	src.SetNRGBA(0, 0, color.NRGBA{255, 0, 0, 255})
	src.SetNRGBA(1, 0, color.NRGBA{0, 0, 255, 255})
	icon := renderWebAppIcon(src, 8, 1)
	if got := icon.NRGBAAt(3, 4); got != (color.NRGBA{255, 0, 0, 255}) {
		t.Errorf("大きくしても左半分は元の左の画素の色のままのはず: %v", got)
	}
}

func TestRenderWebAppIconDownscaleAverages(t *testing.T) {
	src := image.NewNRGBA(image.Rect(0, 0, 2, 2))
	src.SetNRGBA(0, 0, color.NRGBA{255, 255, 255, 255})
	src.SetNRGBA(1, 1, color.NRGBA{255, 255, 255, 255})
	src.SetNRGBA(1, 0, color.NRGBA{0, 0, 0, 255})
	src.SetNRGBA(0, 1, color.NRGBA{0, 0, 0, 255})
	if got := renderWebAppIcon(src, 1, 1).NRGBAAt(0, 0); got.R < 126 || got.R > 129 {
		t.Errorf("小さくすると覆う画素の平均（白と黒の半々で 127 前後）のはず: %v", got)
	}
}

func TestRenderWebAppIconCentersEngineLogoWithMargin(t *testing.T) {
	src := image.NewNRGBA(image.Rect(0, 0, 64, 64))
	for i := range src.Pix {
		src.Pix[i] = 255
	}
	icon := renderWebAppIcon(src, 512, webEngineLogoIconRatio)
	if got := icon.NRGBAAt(0, 0); got.R == 255 {
		t.Errorf("engine のロゴの時は端に下地の余白が残るはず: %v", got)
	}
}

func TestWriteWebAppWritesManifestAndIconsOfEachSize(t *testing.T) {
	game, out := t.TempDir(), t.TempDir()
	icon := filepath.Join(game, "icon.png")
	writeTestPNG(t, icon, image.NewNRGBA(image.Rect(0, 0, 600, 600)))
	if err := writeWebApp(exportWebPaths{Out: out, AppIcon: icon}, webBundle{Title: "t"}); err != nil {
		t.Fatal(err)
	}
	for name, side := range map[string]int{"apple-touch-icon.png": 180, "icon-192.png": 192, "icon-512.png": 512} {
		img, err := loadPNG(filepath.Join(out, name))
		if err != nil || img.Bounds().Dx() != side || img.Bounds().Dy() != side {
			t.Errorf("%s は %d px の正方形のはず: %v %v", name, side, err, img)
		}
	}
	if _, err := os.Stat(filepath.Join(out, webManifestFile)); err != nil {
		t.Errorf("%s が書かれるはず: %v", webManifestFile, err)
	}
}

func TestWriteWebAppFallsBackToEngineLogo(t *testing.T) {
	out := t.TempDir()
	if err := writeWebApp(exportWebPaths{Out: out, Engine: filepath.Join("..")}, webBundle{Title: "t"}); err != nil {
		t.Fatalf("web.appIcon が無ければ engine のロゴで作れるはず: %v", err)
	}
}

func TestWebSumsListsManifestAndIcons(t *testing.T) {
	out := t.TempDir()
	if err := writeWebApp(exportWebPaths{Out: out, Engine: filepath.Join("..")}, webBundle{Title: "t"}); err != nil {
		t.Fatal(err)
	}
	if _, err := writeWebSums(out); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(filepath.Join(out, webSumsFile))
	var sums map[string]string
	_ = json.Unmarshal(raw, &sums)
	for _, name := range []string{webManifestFile, webAppleTouchIconFile, "icon-192.png", "icon-512.png"} {
		if sums[name] == "" {
			t.Errorf("sums.json に %s が載るはず（Service Worker が照らせない）", name)
		}
	}
}

func TestWriteWebAppKeepsGoingWithoutEngineLogo(t *testing.T) {
	out := t.TempDir()
	if err := writeWebApp(exportWebPaths{Out: out, Engine: t.TempDir()}, webBundle{Title: "t"}); err != nil {
		t.Fatalf("engine のロゴが無くても書き出しは止まらないはず: %v", err)
	}
}
