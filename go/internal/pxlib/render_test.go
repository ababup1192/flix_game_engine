package pxlib

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRGBAOfHex(t *testing.T) {
	if got, ok := RGBAOfValue("#ff8000"); !ok || got != (RGBA{255, 128, 0, 255}) {
		t.Fatalf("16 進の読みが Python と違う: %v", got)
	}
}

func TestHexOfNestedDict(t *testing.T) {
	if got := HexOfValue(map[string]any{"hex": "AABBCC"}); got != "#aabbcc" {
		t.Fatalf("入れ子の色が #aabbcc ではなく %q", got)
	}
}

func TestHexOfRejectsNonColor(t *testing.T) {
	if got := HexOfValue("nope"); got != "" {
		t.Fatalf("色でない文字列から %q が出た", got)
	}
}

// 半透明の画素も、書いて開き直すと同じ値に戻る（乗算済みに変えない）。
func TestPNGRoundTrip(t *testing.T) {
	grid := [][]RGBA{
		{{1, 2, 3, 255}, {0, 0, 0, 0}},
		{{255, 254, 253, 128}, {9, 9, 9, 255}},
	}
	path := filepath.Join(t.TempDir(), "a.png")
	if err := WritePNG(path, ImageOfRows(grid)); err != nil {
		t.Fatal(err)
	}
	img, err := LoadPNG(path)
	if err != nil {
		t.Fatal(err)
	}
	if img.W != 2 || img.H != 2 {
		t.Fatalf("大きさが 2x2 ではなく %dx%d", img.W, img.H)
	}
	rows := img.Rows()
	for y := range grid {
		for x := range grid[y] {
			if rows[y][x] != grid[y][x] {
				t.Fatalf("(%d,%d) が %v ではなく %v", x, y, grid[y][x], rows[y][x])
			}
		}
	}
}

// legend の色は直の hex と、Doc の palette の名前（@ 付きも）の両方から引ける。
func TestRenderDocResolvesLegend(t *testing.T) {
	dir := t.TempDir()
	doc := `{"palette": {"ink": "#102030"}, "legend": {"a": "#ff0000", "b": "@ink", "c": "ink"},
  "sprites": {"s": {"frames": {"idle": ["ab", "c."]}}}}`
	path := filepath.Join(dir, "x.sprite.json")
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	written, err := RenderDoc(path, dir)
	if err != nil || len(written) != 1 {
		t.Fatalf("1 枚のはず: %v %v", written, err)
	}
	img, err := LoadPNG(written[0])
	if err != nil {
		t.Fatal(err)
	}
	rows := img.Rows()
	if img.W != 16 || rows[0][0] != (RGBA{255, 0, 0, 255}) || rows[0][8] != (RGBA{0x10, 0x20, 0x30, 255}) ||
		rows[8][0] != (RGBA{0x10, 0x20, 0x30, 255}) || rows[8][8] != (RGBA{}) {
		t.Fatalf("色の引き方が違う: 幅 %d %v %v %v %v", img.W, rows[0][0], rows[0][8], rows[8][0], rows[8][8])
	}
}
