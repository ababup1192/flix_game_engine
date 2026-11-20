package main

import (
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"math/rand"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// fakeCwebpByMode は -lossless の時は lossless バイト・ほかは lossy バイトを -o の先へ書く cwebp。
func fakeCwebpByMode(t *testing.T, lossless, lossy int) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("sh の道具で差し替えるので windows では飛ばす")
	}
	script := "#!/bin/sh\n" +
		`out=""; prev=""; size=` + strconv.Itoa(lossy) + `; for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; if [ "$a" = "-lossless" ]; then size=` + strconv.Itoa(lossless) + `; fi; prev="$a"; done` + "\n" +
		`head -c "$size" /dev/zero > "$out"` + "\n"
	p := filepath.Join(t.TempDir(), "cwebp")
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func repoAutoLossyRules(t *testing.T) *webAutoLossyRules {
	t.Helper()
	r, err := loadWebAutoLossyRules("..")
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// 絵の見本。どれも 160×160。
func pixelArtImage() image.Image {
	img := image.NewNRGBA(image.Rect(0, 0, 160, 160))
	for y := 0; y < 160; y++ {
		for x := 0; x < 160; x++ {
			i := (x/10 + y/10*3) % 64
			img.SetNRGBA(x, y, color.NRGBA{uint8(i * 4), uint8(255 - i*4), uint8(i * 2), 255})
		}
	}
	return img
}

func photoImage() image.Image {
	rng := rand.New(rand.NewSource(1))
	img := image.NewNRGBA(image.Rect(0, 0, 160, 160))
	for i := 0; i < len(img.Pix); i += 4 {
		img.Pix[i], img.Pix[i+1], img.Pix[i+2], img.Pix[i+3] = uint8(rng.Intn(256)), uint8(rng.Intn(256)), uint8(rng.Intn(256)), 255
	}
	return img
}

// standingImage は真ん中の 4 割だけ塗りの人物で、まわりが透明の立ち絵。
func standingImage() image.Image {
	rng := rand.New(rand.NewSource(2))
	img := image.NewNRGBA(image.Rect(0, 0, 160, 160))
	for y := 0; y < 160; y++ {
		for x := 48; x < 112; x++ {
			img.SetNRGBA(x, y, color.NRGBA{uint8(rng.Intn(256)), uint8(rng.Intn(256)), uint8(rng.Intn(256)), 255})
		}
	}
	return img
}

// textImage は地と字の 2 組の色の間をアンチエイリアスの中間色でつないだ絵（数百色）。
func textImage() image.Image {
	img := image.NewNRGBA(image.Rect(0, 0, 160, 160))
	for y := 0; y < 160; y++ {
		for x := 0; x < 160; x++ {
			t := uint8((x*7 + y*3) % 256)
			if y < 80 {
				img.SetNRGBA(x, y, color.NRGBA{t, t, 255 - t, 255})
			} else {
				img.SetNRGBA(x, y, color.NRGBA{255 - t, 40, t, 255})
			}
		}
	}
	return img
}

func writePngTo(t *testing.T, p string, img image.Image) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	f.Close()
}

var autoLossySamples = map[string]func() image.Image{
	"assets/dot/hero.png":        pixelArtImage,
	"assets/bg/photo.png":        photoImage,
	"assets/stand/girl.png":      standingImage,
	"assets/ui/label.png":        textImage,
	"assets/fx/water_normal.png": photoImage,
	"assets/fx/flow_n.png":       photoImage,
}

// transcodeSamples は見本を書き出し先に置き、raw の web 欄と cwebp で変換する。
func transcodeSamples(t *testing.T, raw string, cwebp string) webTranscodeReport {
	t.Helper()
	out := t.TempDir()
	var rels []string
	for rel, mk := range autoLossySamples {
		writePngTo(t, exportAssetPath(out, rel), mk())
		rels = append(rels, rel)
	}
	c, err := resolveWebCompress(json.RawMessage(raw))
	if err != nil {
		t.Fatal(err)
	}
	c.Auto = repoAutoLossyRules(t)
	b := webBundle{Images: rels}
	return transcodeWebAssets(out, &b, nil, c, webEncoders{Cwebp: cwebp})
}

func verdictsOf(t *testing.T, raw string) map[string]webImageVerdict {
	t.Helper()
	got := map[string]webImageVerdict{}
	for _, v := range transcodeSamples(t, raw, fakeCwebpByMode(t, 60000, 2000)).Verdicts {
		got[v.Rel] = v
	}
	return got
}

func TestAutoLossyKeepsPixelArtLossless(t *testing.T) {
	if v := verdictsOf(t, `{}`)["assets/dot/hero.png"]; v.Kind != webImageLossless {
		t.Fatalf("got %+v", v)
	}
}

func TestAutoLossyMakesPhotoLossy(t *testing.T) {
	if v := verdictsOf(t, `{}`)["assets/bg/photo.png"]; v.Kind != webImageAutoLossy {
		t.Fatalf("got %+v", v)
	}
}

func TestAutoLossyMakesTransparentStandingLossy(t *testing.T) {
	if v := verdictsOf(t, `{}`)["assets/stand/girl.png"]; v.Kind != webImageAutoLossy {
		t.Fatalf("got %+v", v)
	}
}

func TestAutoLossyCountsStandingAsTransparent(t *testing.T) {
	if v := verdictsOf(t, `{}`)["assets/stand/girl.png"]; !v.isTransparent(repoAutoLossyRules(t)) {
		t.Fatalf("got %+v", v)
	}
}

func TestAutoLossyKeepsAntialiasedTextLossless(t *testing.T) {
	if v := verdictsOf(t, `{}`)["assets/ui/label.png"]; v.Kind != webImageLossless {
		t.Fatalf("got %+v", v)
	}
}

func TestAutoLossyKeepsNormalMapByName(t *testing.T) {
	if v := verdictsOf(t, `{}`)["assets/fx/water_normal.png"]; v.Kind != webImageDataTexture {
		t.Fatalf("got %+v", v)
	}
}

func TestAutoLossyKeepsUnderscoreNByName(t *testing.T) {
	if v := verdictsOf(t, `{}`)["assets/fx/flow_n.png"]; v.Kind != webImageDataTexture {
		t.Fatalf("got %+v", v)
	}
}

func TestAutoLossyRecordsLossyBytes(t *testing.T) {
	if v := verdictsOf(t, `{}`)["assets/bg/photo.png"]; v.LossyBytes != 2000 {
		t.Fatalf("got %+v", v)
	}
}

func TestAutoLossyKeepsLosslessWhenLossyIsNotSmaller(t *testing.T) {
	r := transcodeSamples(t, `{}`, fakeCwebpByMode(t, 60000, 60000))
	for _, v := range r.Verdicts {
		if v.Kind == webImageAutoLossy {
			t.Fatalf("got %+v", v)
		}
	}
}

func TestAutoLossyDropsVerdictWhenPngIsServed(t *testing.T) {
	out := t.TempDir()
	writePngTo(t, exportAssetPath(out, "assets/bg/photo.png"), photoImage())
	c := defaultWebCompress()
	c.Auto = repoAutoLossyRules(t)
	b := webBundle{Images: []string{"assets/bg/photo.png"}}
	// png（約 77 KB）より lossy の方が大きいので png のまま配る。
	r := transcodeWebAssets(out, &b, nil, c, webEncoders{Cwebp: fakeCwebpByMode(t, 200000, 150000)})
	if r.Verdicts[0].Kind != webImageLossless {
		t.Fatalf("got %+v", r.Verdicts)
	}
}

func TestAutoLossyLeavesNoTemporaryFile(t *testing.T) {
	out := t.TempDir()
	writePngTo(t, exportAssetPath(out, "assets/bg/photo.png"), photoImage())
	c := defaultWebCompress()
	c.Auto = repoAutoLossyRules(t)
	b := webBundle{Images: []string{"assets/bg/photo.png"}}
	transcodeWebAssets(out, &b, nil, c, webEncoders{Cwebp: fakeCwebpByMode(t, 60000, 60000)})
	left, _ := filepath.Glob(filepath.Join(out, "assets", "bg", "*.lossy"))
	if len(left) != 0 {
		t.Fatalf("残った: %v", left)
	}
}

func TestExplicitLossyRuleWinsOverLosslessImages(t *testing.T) {
	raw := `{"compress": {"lossyImages": [{"glob": "assets/bg/*.png", "quality": 70}], "losslessImages": [{"glob": "assets/bg/*.png", "why": "w"}, {"glob": "assets/ui/*.png", "why": "w"}]}}`
	if v := verdictsOf(t, raw)["assets/bg/photo.png"]; v.Kind == webImageLosslessByRule {
		t.Fatalf("got %+v", v)
	}
}

func TestLosslessImagesKeepsPhotoLossless(t *testing.T) {
	if v := verdictsOf(t, `{"compress": {"losslessImages": [{"glob": "assets/bg/*.png", "why": "w"}]}}`)["assets/bg/photo.png"]; v.Kind != webImageLosslessByRule {
		t.Fatalf("got %+v", v)
	}
}

func TestShaderReadTextureIsDataTexture(t *testing.T) {
	out := t.TempDir()
	writePngTo(t, exportAssetPath(out, "assets/bg/photo.png"), photoImage())
	c := defaultWebCompress()
	c.Auto = repoAutoLossyRules(t)
	c.DataImages = map[string]bool{"assets/bg/photo.png": true}
	b := webBundle{Images: []string{"assets/bg/photo.png"}}
	r := transcodeWebAssets(out, &b, nil, c, webEncoders{Cwebp: fakeCwebpByMode(t, 60000, 2000)})
	if r.Verdicts[0].Kind != webImageDataTexture {
		t.Fatalf("got %+v", r.Verdicts)
	}
}

func TestAutoLossySkipsSmallLosslessOutput(t *testing.T) {
	out := t.TempDir()
	writePngTo(t, exportAssetPath(out, "assets/bg/photo.png"), photoImage())
	c := defaultWebCompress()
	c.Auto = repoAutoLossyRules(t)
	b := webBundle{Images: []string{"assets/bg/photo.png"}}
	r := transcodeWebAssets(out, &b, nil, c, webEncoders{Cwebp: fakeCwebpByMode(t, 1000, 500)})
	if r.Verdicts[0].Kind != webImageLossless {
		t.Fatalf("got %+v", r.Verdicts)
	}
}

func TestCountOpaqueColorsSkipsTranslucentEdge(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 10, 10))
	for i := 0; i < 100; i++ {
		img.Pix[4*i], img.Pix[4*i+3] = uint8(i), 255
	}
	for i := 0; i < 50; i++ {
		img.Pix[4*i+3] = 100
	}
	if colors, _ := countOpaqueColors(img, 1000, 224); colors != 50 {
		t.Fatalf("colors = %d", colors)
	}
}

func TestCountOpaqueColorsReadsPremultipliedRGBA(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 4, 1))
	for i := 0; i < 4; i++ {
		img.Pix[4*i+1], img.Pix[4*i+3] = uint8(10*i), 255
	}
	if colors, _ := countOpaqueColors(img, 1000, 224); colors != 4 {
		t.Fatalf("colors = %d", colors)
	}
}

func TestCountOpaqueColorsReadsPaletted(t *testing.T) {
	img := image.NewPaletted(image.Rect(0, 0, 4, 1), color.Palette{color.NRGBA{0, 0, 0, 255}, color.NRGBA{9, 9, 9, 255}, color.NRGBA{0, 0, 0, 0}})
	img.Pix = []uint8{0, 1, 2, 1}
	if colors, _ := countOpaqueColors(img, 1000, 224); colors != 2 {
		t.Fatalf("colors = %d", colors)
	}
}

func TestCountOpaqueColorsCapsAtLimit(t *testing.T) {
	if colors, _ := countOpaqueColors(photoImage(), 100, 224); colors != 100 {
		t.Fatalf("colors = %d", colors)
	}
}

func TestResolveWebCompressRejectsLosslessWithoutWhy(t *testing.T) {
	if _, err := resolveWebCompress(json.RawMessage(`{"compress": {"losslessImages": [{"glob": "assets/*.png"}]}}`)); err == nil {
		t.Fatal("why の無い行を通した")
	}
}

func TestCheckLosslessGlobsRejectsGlobWithoutMatch(t *testing.T) {
	c, _ := resolveWebCompress(json.RawMessage(`{"compress": {"losslessImages": [{"glob": "assets/none/*.png", "why": "w"}]}}`))
	if _, err := checkWebLosslessGlobs([]string{"assets/a.png"}, c); err == nil {
		t.Fatal("何にも当たらない glob を通した")
	}
}

func TestCheckLosslessGlobsRejectsGlobShadowedByLossy(t *testing.T) {
	c, _ := resolveWebCompress(json.RawMessage(`{"compress": {"lossyImages": [{"glob": "assets/*.png", "quality": 80}], "losslessImages": [{"glob": "assets/a.png", "why": "w"}]}}`))
	if _, err := checkWebLosslessGlobs([]string{"assets/a.png"}, c); err == nil {
		t.Fatal("lossyImages に全部取られる glob を通した")
	}
}

func broadGlobNotes(t *testing.T, glob string) []string {
	t.Helper()
	c, _ := resolveWebCompress(json.RawMessage(`{"compress": {"losslessImages": [{"glob": "` + glob + `", "why": "w"}]}}`))
	c.Auto = repoAutoLossyRules(t)
	notes, err := checkWebLosslessGlobs([]string{"assets/a.png", "assets/b.png", "assets/c.png", "assets/d.png", "assets/e.png"}, c)
	if err != nil {
		t.Fatal(err)
	}
	return notes
}

func TestCheckLosslessGlobsWarnsBroadGlob(t *testing.T) {
	if notes := broadGlobNotes(t, "assets/**"); len(notes) != 1 {
		t.Fatalf("notes %v", notes)
	}
}

func TestCheckLosslessGlobsQuietForNarrowGlob(t *testing.T) {
	if notes := broadGlobNotes(t, "assets/a.png"); len(notes) != 0 {
		t.Fatalf("notes %v", notes)
	}
}

func summaryOf(t *testing.T, prev map[string]bool) string {
	t.Helper()
	r := transcodeSamples(t, `{}`, fakeCwebpByMode(t, 60000, 2000))
	return strings.Join(buildWebAutoLossySummary(r.Verdicts, repoAutoLossyRules(t), nil, prev), "\n")
}

func TestSummaryCountsAutoLossyImages(t *testing.T) {
	if lines := summaryOf(t, nil); !strings.Contains(lines, "既定で lossy にした 2 枚") {
		t.Fatalf("lines = %s", lines)
	}
}

func TestSummaryNamesFewColorImage(t *testing.T) {
	if lines := summaryOf(t, nil); !strings.Contains(lines, "assets/stand/girl.png") {
		t.Fatalf("lines = %s", lines)
	}
}

func TestSortedByColorsPutsFewestFirst(t *testing.T) {
	got := sortedByColors([]webImageVerdict{{Rel: "b", Colors: 3000}, {Rel: "a", Colors: 1100}})
	if got[0].Rel != "a" {
		t.Fatalf("got %+v", got)
	}
}

func TestSummaryStarsImagesThatWereLossless(t *testing.T) {
	if lines := summaryOf(t, map[string]bool{"assets/bg/photo.png": true}); !strings.Contains(lines, "★ 前の書き出しでは lossless だった絵 1 枚") {
		t.Fatalf("lines = %s", lines)
	}
}

func TestSummaryHasNoStarWithoutPreviousExport(t *testing.T) {
	if lines := summaryOf(t, nil); strings.Contains(lines, "★") {
		t.Fatalf("lines = %s", lines)
	}
}

// explicitSummary は lossyImages を書いた web 欄で写真を 1 枚詰めた時の表の行。
func explicitSummary(t *testing.T, raw string, lossless, lossy int) string {
	t.Helper()
	out := t.TempDir()
	writePngTo(t, exportAssetPath(out, "assets/bg/photo.png"), photoImage())
	c, _ := resolveWebCompress(json.RawMessage(raw))
	c.Auto = repoAutoLossyRules(t)
	b := webBundle{Images: []string{"assets/bg/photo.png"}}
	r := transcodeWebAssets(out, &b, nil, c, webEncoders{Cwebp: fakeCwebpByMode(t, lossless, lossy)})
	return strings.Join(buildWebAutoLossySummary(r.Verdicts, c.Auto, c.LossyImages, nil), "\n")
}

func TestSummarySaysExplicitRuleIsRemovableWhenLossyIsLarge(t *testing.T) {
	lines := explicitSummary(t, `{"compress": {"lossyImages": [{"glob": "assets/bg/*.png", "quality": 90}]}}`, 60000, 50000)
	if !strings.Contains(lines, `"assets/bg/*.png" は消しても`) {
		t.Fatalf("lines = %s", lines)
	}
}

func TestSummarySaysExplicitRuleIsRemovableWhenLossyIsSmall(t *testing.T) {
	lines := explicitSummary(t, `{"compress": {"lossyImages": [{"glob": "assets/bg/*.png", "quality": 90}]}}`, 60000, 20000)
	if !strings.Contains(lines, `"assets/bg/*.png" は消しても`) {
		t.Fatalf("lines = %s", lines)
	}
}

func TestSummaryKeepsExplicitRuleWithOtherQuality(t *testing.T) {
	lines := explicitSummary(t, `{"compress": {"lossyImages": [{"glob": "assets/bg/*.png", "quality": 70}]}}`, 60000, 20000)
	if strings.Contains(lines, "消しても") {
		t.Fatalf("lines = %s", lines)
	}
}

func TestSummarySaysShadowedExplicitRuleIsRemovable(t *testing.T) {
	lines := explicitSummary(t, `{"compress": {"lossyImages": [{"glob": "assets/bg/*.png", "quality": 70}, {"glob": "assets/bg/photo.png", "quality": 60}]}}`, 60000, 20000)
	if !strings.Contains(lines, `"assets/bg/photo.png" は消しても`) {
		t.Fatalf("lines = %s", lines)
	}
}

func TestLoadWebShaderTexturesFindsTexName(t *testing.T) {
	if !shaderTexturesOf(t)["assets/fx/flow.png"] {
		t.Fatal("tex で読む絵を拾わなかった")
	}
}

func TestLoadWebShaderTexturesSkipsUnreadTexture(t *testing.T) {
	if shaderTexturesOf(t)["assets/bg.png"] {
		t.Fatal("読まない絵を拾った")
	}
}

func TestLoadWebShaderTexturesSkipsSchema(t *testing.T) {
	if shaderTexturesOf(t)["assets/fx/schema_only.png"] {
		t.Fatal("schema の中の名前を拾った")
	}
}

func shaderTexturesOf(t *testing.T) map[string]bool {
	t.Helper()
	game := t.TempDir()
	put := func(name, doc string) {
		if err := os.MkdirAll(filepath.Join(game, "assets"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(game, "assets", name), []byte(doc), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	put("water.shader.json", `{"out": {"kind": "fill", "shade": {"kind": "rgb", "r": {"kind": "tex", "name": "flow"}}}}`)
	put("shader.schema.json", `{"example": {"kind": "tex", "name": "schemaOnly"}}`)
	pr := exportProject{Textures: []webTexture{{Name: "flow", Path: "assets/fx/flow.png"}, {Name: "bg", Path: "assets/bg.png"}, {Name: "schemaOnly", Path: "assets/fx/schema_only.png"}}}
	return loadWebShaderTextures(game, pr)
}

func writeWebpHead(t *testing.T, data string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "a.webp")
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestIsWebpLosslessReadsVP8L(t *testing.T) {
	if !isWebpLossless(writeWebpHead(t, "RIFF\x10\x00\x00\x00WEBPVP8L\x04\x00\x00\x00\x00\x00\x00\x00")) {
		t.Fatal("VP8L を劣化なしと読まなかった")
	}
}

func TestIsWebpLosslessSkipsVP8XToLossy(t *testing.T) {
	if isWebpLossless(writeWebpHead(t, "RIFF\x20\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00VP8 \x00\x00\x00\x00")) {
		t.Fatal("VP8 を劣化なしと読んだ")
	}
}

// previousExport は前の書き出しの bundle.json と、lossless（VP8L）と lossy（VP8）の WebP を 1 枚ずつ置いた書き出し先。
func previousExport(t *testing.T) string {
	t.Helper()
	out := t.TempDir()
	bundle := `{"images": ["assets/a.png", "assets/b.png", "assets/c.png"], "transcoded": {"assets/a.png": "a.webp", "assets/b.png": "b.webp"}}`
	files := map[string]string{
		"bundle.json":   bundle,
		"assets/a.webp": "RIFF\x10\x00\x00\x00WEBPVP8L\x04\x00\x00\x00\x00\x00\x00\x00",
		"assets/b.webp": "RIFF\x10\x00\x00\x00WEBPVP8 \x04\x00\x00\x00\x00\x00\x00\x00",
	}
	for rel, data := range files {
		p := filepath.Join(out, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return out
}

func TestLoadPreviousLosslessImagesReadsLosslessWebp(t *testing.T) {
	if !loadPreviousLosslessImages(previousExport(t))["assets/a.png"] {
		t.Fatal("VP8L で配っていた絵を拾わなかった")
	}
}

func TestLoadPreviousLosslessImagesSkipsLossyWebp(t *testing.T) {
	if loadPreviousLosslessImages(previousExport(t))["assets/b.png"] {
		t.Fatal("VP8 で配っていた絵を拾った")
	}
}

func TestLoadPreviousLosslessImagesReadsServedPng(t *testing.T) {
	if !loadPreviousLosslessImages(previousExport(t))["assets/c.png"] {
		t.Fatal("png のまま配っていた絵を拾わなかった")
	}
}

func TestLoadPreviousLosslessImagesWithoutExportIsEmpty(t *testing.T) {
	if got := loadPreviousLosslessImages(t.TempDir()); len(got) != 0 {
		t.Fatalf("got %v", got)
	}
}

func TestPlanWebImagesRecordsAllMatchingLossyRules(t *testing.T) {
	c, _ := resolveWebCompress(json.RawMessage(`{"compress": {"lossyImages": [{"glob": "assets/*.png", "quality": 70}, {"glob": "assets/a.png", "quality": 60}]}}`))
	jobs, _ := planWebImages(t.TempDir(), []string{"assets/a.png"}, c, webEncoders{Cwebp: "cwebp"}, map[string]bool{})
	if !slices.Equal(jobs[0].verdict.explicitRules, []int{0, 1}) {
		t.Fatalf("got %v", jobs[0].verdict.explicitRules)
	}
}
