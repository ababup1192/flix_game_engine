package main

// 各サブコマンドの芯。判定の境目と、--self-test が見る場面を確かめる。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

func TestSeamQuietFloorPasses(t *testing.T) {
	if got := seamVerdict([]float64{0.0, 0.0}, 0.004); got != "" {
		t.Errorf("静けさの床 0.4%% は常に合格のはず: %q", got)
	}
}

func TestSeamJumpWarns(t *testing.T) {
	if seamVerdict([]float64{0.02, 0.03}, 0.10) == "" {
		t.Error("継ぎ目が跳ねたら警告のはず")
	}
}

func TestSeamSameAsNormalPasses(t *testing.T) {
	if got := seamVerdict([]float64{0.02, 0.03}, 0.04); got != "" {
		t.Errorf("通常コマ間と同程度なら合格のはず: %q", got)
	}
}

func TestSeamAllZeroWithOnePercentWarns(t *testing.T) {
	if seamVerdict([]float64{0.0, 0.0}, 0.01) == "" {
		t.Error("通常が全て 0 で継ぎ目だけ 1%% なら警告のはず")
	}
}

func writeFramePNG(t *testing.T, path string, w, h int, at func(x, y int) pxlib.RGBA) {
	t.Helper()
	grid := make([][]pxlib.RGBA, h)
	for y := 0; y < h; y++ {
		grid[y] = make([]pxlib.RGBA, w)
		for x := 0; x < w; x++ {
			grid[y][x] = at(x, y)
		}
	}
	if err := os.WriteFile(path, encodePNG(w, h, grid), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoopStillFramesPass(t *testing.T) {
	dir := t.TempDir()
	red := func(x, y int) pxlib.RGBA { return pxlib.RGBA{255, 0, 0, 255} }
	for i := 0; i < 3; i++ {
		writeFramePNG(t, filepath.Join(dir, string(rune('0'+i))+".png"), 4, 4, red)
	}
	if got := checkLoopDir(dir); len(got) != 0 {
		t.Errorf("同一 3 コマのループは合格のはず: %v", got)
	}
}

func TestLoopDriftWarns(t *testing.T) {
	dir := t.TempDir()
	for i := 0; i < 3; i++ {
		n := i
		writeFramePNG(t, filepath.Join(dir, string(rune('0'+i))+".png"), 4, 4,
			func(x, y int) pxlib.RGBA {
				if x < n {
					return pxlib.RGBA{0, 0, 255, 255}
				}
				return pxlib.RGBA{255, 0, 0, 255}
			})
	}
	if got := checkLoopDir(dir); len(got) == 0 {
		t.Error("先頭へ戻らないドリフトは警告のはず")
	}
}

func TestPNGRoundTripKeepsPixels(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a.png")
	writeFramePNG(t, path, 3, 2, func(x, y int) pxlib.RGBA {
		return pxlib.RGBA{byte(x * 40), byte(y * 90), 7, byte(200 + x)}
	})
	im, err := pxlib.LoadPNG(path)
	if err != nil {
		t.Fatal(err)
	}
	if im.W != 3 || im.H != 2 {
		t.Fatalf("寸法が違う: %dx%d", im.W, im.H)
	}
	if im.Pix[4] != 40 || im.Pix[7] != 201 {
		t.Errorf("画素が変わった: %v", im.Pix[:8])
	}
}

func TestReadPNGRejectsNonPNG(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a.png")
	if err := os.WriteFile(path, []byte("not a png"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := pxlib.LoadPNG(path)
	if err == nil || err.Error() != "PNG ではない" {
		t.Errorf("PNG でない旨を返すはず: %v", err)
	}
}

func TestIsHexColorAcceptsBareBody(t *testing.T) {
	if !pxlib.IsHexColor("1A2b3C") {
		t.Error("# 無しの 6 桁も色として読めるはず")
	}
}

func TestIsHexColorRejectsShortForm(t *testing.T) {
	if pxlib.IsHexColor("#abc") {
		t.Error("3 桁は色として読まないはず")
	}
}

func TestHexOfValueUnwrapsNestedKey(t *testing.T) {
	v := map[string]any{"color": map[string]any{"hex": "#AABBCC"}}
	if got := pxlib.HexOfValue(v); got != "#aabbcc" {
		t.Errorf("包みを開いて小文字にするはず: %q", got)
	}
}

func TestRGBAOfHSVMatchesPureRed(t *testing.T) {
	if got := pxlib.RGBAOfHSV(0.0, 1.0, 1.0); got != (pxlib.RGBA{255, 0, 0, 255}) {
		t.Errorf("h=0 s=1 v=1 は赤のはず: %v", got)
	}
}

func TestRGBAOfFloatsRoundsToEven(t *testing.T) {
	// 0.5/255 は 0.5 に落ちる。ちょうど半分は偶数側 (0) へ寄せる。
	if got := pxlib.RGBAOfFloats([3]float64{0.5 / 255.0, 0, 0}); got[0] != 0 {
		t.Errorf("ちょうど半分は偶数側へ寄せるはず: %v", got)
	}
}

func TestToGrayUsesLumaWeights(t *testing.T) {
	if got := toGray(pxlib.RGBA{255, 255, 255, 128}); got != (pxlib.RGBA{255, 255, 255, 128}) {
		t.Errorf("白は白のまま・alpha は残すはず: %v", got)
	}
}

func TestImageAllowedTitleException(t *testing.T) {
	if !imageAllowed("templates/rpg-starter/reference/title.png") {
		t.Error("Studio が読む title.png は例外として通すはず")
	}
}

func TestImageAllowedRejectsGeneratedGallery(t *testing.T) {
	if imageAllowed("templates/rpg-starter/gallery/battle.png") {
		t.Error("生成した絵の置き場は通さないはず")
	}
}

func TestHumanSwitchesToMegabytes(t *testing.T) {
	if got := human(2 * 1024 * 1024); got != "2.0MB" {
		t.Errorf("MB 表記になるはず: %q", got)
	}
}

func TestDigestPairReportsIdenticalPixels(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a.png")
	b := filepath.Join(dir, "b.png")
	fill := func(x, y int) pxlib.RGBA { return pxlib.RGBA{1, 2, 3, 255} }
	writeFramePNG(t, a, 2, 2, fill)
	writeFramePNG(t, b, 2, 2, fill)
	lines, rate, err := digestPair(a, b)
	if err != nil {
		t.Fatal(err)
	}
	if rate != 0 || !strings.Contains(lines[0], "重なる範囲の画素は同一") {
		t.Errorf("同一と言うはず: %v %v", rate, lines)
	}
}

func TestUnresolvedOfFindsMissingName(t *testing.T) {
	doc := map[string]any{"legend": map[string]any{"a": "@skin", "b": "#112233"}}
	got := unresolvedOf(doc, map[string]bool{})
	if len(got) != 1 || got[0].char != "a" {
		t.Errorf("色票に無い名前だけを挙げるはず: %v", got)
	}
}

func TestIsRenderFileMatchesSrcRender(t *testing.T) {
	if !isRenderFile(filepath.Join("src", "render", "SfxSynth.flix")) {
		t.Error("src/render/ 配下は書き出し側のはず")
	}
}

// What: engine 専用のサブコマンドが、engine のリポでだけ一覧に出ること。
func TestEngineOnlyCommandsHiddenOutsideEngineRepo(t *testing.T) {
	if !engineOnly["check-refs"] {
		t.Fatal("check-refs が engine 専用として名乗っていない")
	}
	if isEngineRepo(t.TempDir()) {
		t.Error("agents-pack の無い場所を engine のリポと見なしている")
	}
	if !isEngineRepo(filepath.Join("..")) {
		t.Error("engine のリポを engine のリポと見なしていない")
	}
}
