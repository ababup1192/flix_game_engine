package carve

// 期待値はすべて具体値で pin する。ここがずれると彫って描き直した絵が変わる。

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

func TestRunsOfMatchesPython(t *testing.T) {
	got := runsOf([]int{1, 2, 3, 7, 8, 10})
	want := [][2]int{{1, 3}, {7, 8}, {10, 10}}
	if len(got) != len(want) {
		t.Fatalf("区間の数が %d ではなく %d", len(want), len(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%d 個目が %v ではなく %v", i, want[i], got[i])
		}
	}
}

func TestRunsOfEmpty(t *testing.T) {
	if len(runsOf(nil)) != 0 {
		t.Fatal("空の列からは区間が出ない")
	}
}

func TestPointsMatchesPython(t *testing.T) {
	cases := []struct {
		low, high, most int
		want            []int
	}{
		{0, 8, 8, []int{0, 1, 2, 3, 4, 5, 6, 7}},
		{0, 9, 8, []int{0, 1, 2, 3, 4, 5, 6, 7}},
		{3, 4, 8, []int{3}},
		{0, 100, 8, []int{0, 12, 25, 37, 50, 62, 75, 87}},
	}
	for _, c := range cases {
		got := points(c.low, c.high, c.most)
		if len(got) != len(c.want) {
			t.Fatalf("%d..%d: 個数が %d ではなく %d", c.low, c.high, len(c.want), len(got))
		}
		for i := range c.want {
			if got[i] != c.want[i] {
				t.Fatalf("%d..%d: %v ではなく %v", c.low, c.high, c.want, got)
			}
		}
	}
}

func TestQuantizeMatchesPython(t *testing.T) {
	if Quantize(RGB{0, 23, 24}, 24) != (RGB{12, 12, 36}) {
		t.Fatal("丸めが Python と違う")
	}
}

func TestQuantizeKeepsWhiteBelow255(t *testing.T) {
	if Quantize(RGB{255, 255, 255}, 24) != (RGB{252, 252, 252}) {
		t.Fatal("白の丸めが Python と違う")
	}
}

func TestCounterMostCommonKeepsInsertionOrderOnTies(t *testing.T) {
	c := NewCounter[string]()
	for _, v := range []string{"a", "b", "c", "b", "c", "d", "d"} {
		c.Add(v, 1)
	}
	keys, counts := c.MostCommon()
	want := []string{"b", "c", "d", "a"}
	for i := range want {
		if keys[i] != want[i] {
			t.Fatalf("多い順が %v ではなく %v", want, keys)
		}
	}
	if counts[0] != 2 || counts[3] != 1 {
		t.Fatal("回数が違う")
	}
}

func TestCounterMostCommon1IsFirstMax(t *testing.T) {
	c := NewCounter[string]()
	for _, v := range []string{"a", "b", "c", "b", "c"} {
		c.Add(v, 1)
	}
	got, count, ok := c.MostCommon1()
	if !ok || got != "b" || count != 2 {
		t.Fatalf("最頻が b(2) ではなく %s(%d)", got, count)
	}
}

func sampleCells() *Cells {
	cells := pxlib.NewOMap[Pt, RGB]()
	cells.Set(Pt{0, 0}, RGB{1, 1, 1})
	cells.Set(Pt{1, 0}, RGB{1, 1, 1})
	cells.Set(Pt{5, 5}, RGB{2, 2, 2})
	cells.Set(Pt{6, 6}, RGB{2, 2, 2})
	cells.Set(Pt{9, 9}, RGB{3, 3, 3})
	return cells
}

func TestComponentsIsEightConnected(t *testing.T) {
	got := Components(sampleCells())
	want := []int{2, 2, 1}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("塊の大きさが %v ではなく %v", want, got)
		}
	}
}

func TestComponentsAdoptIsFourConnected(t *testing.T) {
	got := ComponentsAdopt(sampleCells())
	want := []int{2, 1, 1, 1}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("塊の大きさが %v ではなく %v", want, got)
		}
	}
}

func TestStanceCenterUsesFeet(t *testing.T) {
	cells := pxlib.NewOMap[Pt, RGB]()
	for _, p := range []Pt{{0, 0}, {4, 0}, {1, 9}, {3, 9}} {
		cells.Set(p, RGB{})
	}
	if got := StanceCenter(cells, 0.18); got != 2.0 {
		t.Fatalf("立ち位置の中心が 2.0 ではなく %v", got)
	}
}

func TestScreenOfMatchesPython(t *testing.T) {
	cases := []struct {
		view  string
		want  Pt
		depth int
	}{
		{"front", Pt{1, 2}, 3},
		{"right", Pt{3, 2}, 8},
		{"back", Pt{8, 2}, -3},
		{"left", Pt{6, 2}, 1},
	}
	for _, c := range cases {
		got, depth := screenOf(c.view, 1, 2, 3, 10)
		if got != c.want || depth != c.depth {
			t.Fatalf("%s が %v/%d ではなく %v/%d", c.view, c.want, c.depth, got, depth)
		}
	}
}

func TestImgXFlipsOnlyLeft(t *testing.T) {
	if imgX("left", 2, 10) != 7 || imgX("right", 2, 10) != 2 {
		t.Fatal("左向きだけ鏡映する")
	}
}

func TestRGBAOfHex(t *testing.T) {
	if RGBAOf("#ff8000") != (RGBA{255, 128, 0, 255}) {
		t.Fatal("16 進の読みが Python と違う")
	}
}

func TestHexOfNestedDict(t *testing.T) {
	obj := pxlib.NewOMap[string, any]()
	obj.Set("hex", "AABBCC")
	if got := HexOf(obj); got != "#aabbcc" {
		t.Fatalf("入れ子の色が #aabbcc ではなく %q", got)
	}
}

func TestHexOfRejectsNonColor(t *testing.T) {
	if got := HexOf("nope"); got != "" {
		t.Fatalf("色でない文字列から %q が出た", got)
	}
}

func TestJSONStringEscapesLikePython(t *testing.T) {
	got := jsonString("a\"b\\cあ\n\t\x01")
	want := `"a\"b\\cあ\n\t\u0001"`
	if got != want {
		t.Fatalf("%s ではなく %s", want, got)
	}
}

// 2×2・2 コマの GIF の頭とお尻のバイト列を pin する。
func TestGifOfMatchesPython(t *testing.T) {
	got := GifOf(2, 2, [][]int{{0, 1, 2, 1}, {1, 1, 0, 2}},
		[]RGB{{0, 0, 0}, {255, 0, 0}, {0, 128, 255}}, 14, 0)
	if len(got) != 857 {
		t.Fatalf("長さが 857 ではなく %d", len(got))
	}
	head, _ := hex.DecodeString("47494638396102000200f70000000000ff000000")
	for i := range head {
		if got[i] != head[i] {
			t.Fatalf("%d バイト目が違う", i)
		}
	}
	tail, _ := hex.DecodeString("000807000104101020200021f904090e0000002c000000000200020000080700030400202020003b")
	for i := range tail {
		if got[len(got)-len(tail)+i] != tail[i] {
			t.Fatalf("末尾 %d バイト目が違う", i)
		}
	}
}

func TestBitsMatchesPython(t *testing.T) {
	codes := make([]int, 300)
	for i := range codes {
		codes[i] = i
	}
	got := hex.EncodeToString(bits(codes, 9, 256, 257))
	want := "00010410308040010307102450b0804103070f204490308142050b173064"
	if got[:len(want)] != want {
		t.Fatalf("LZW の詰め方が違う: %s", got[:len(want)])
	}
}

func TestPNGRoundTrip(t *testing.T) {
	grid := [][]RGBA{
		{{1, 2, 3, 255}, {0, 0, 0, 0}},
		{{255, 254, 253, 128}, {9, 9, 9, 255}},
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "a.png")
	if err := os.WriteFile(path, PNGOf(2, 2, grid), 0o644); err != nil {
		t.Fatal(err)
	}
	w, h, rows, err := ReadPNGSheet(path)
	if err != nil {
		t.Fatal(err)
	}
	if w != 2 || h != 2 {
		t.Fatalf("大きさが 2x2 ではなく %dx%d", w, h)
	}
	for y := range grid {
		for x := range grid[y] {
			if rows[y][x] != grid[y][x] {
				t.Fatalf("(%d,%d) が %v ではなく %v", x, y, grid[y][x], rows[y][x])
			}
		}
	}
}

func TestLoadRulesFailsWhenMissing(t *testing.T) {
	if _, err := LoadRules(t.TempDir()); err == nil {
		t.Fatal("規約が無ければ止まる")
	}
}

func TestLoadRulesFailsOnPartialTable(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "bin", "lint-rules"), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "bin", "lint-rules", "carve.json")
	if err := os.WriteFile(path, []byte(`{"alpha": 8}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadRules(dir); err == nil {
		t.Fatal("欠けた規約は既定値で埋めずに止まる")
	}
}

func TestOMapKeepsPlaceOnOverwrite(t *testing.T) {
	m := pxlib.NewOMap[string, int]()
	m.Set("a", 1)
	m.Set("b", 2)
	m.Set("a", 3)
	keys := m.Keys()
	if keys[0] != "a" || keys[1] != "b" || len(keys) != 2 {
		t.Fatalf("上書きで並びが動いた: %v", keys)
	}
}

func TestOMapReinsertGoesToEnd(t *testing.T) {
	m := pxlib.NewOMap[string, int]()
	m.Set("a", 1)
	m.Set("b", 2)
	m.Delete("a")
	m.Set("a", 9)
	keys := m.Keys()
	if keys[0] != "b" || keys[1] != "a" {
		t.Fatalf("消して入れ直した鍵が末尾に来ない: %v", keys)
	}
}
