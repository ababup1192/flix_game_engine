package fontbake

import (
	"encoding/binary"
	"hash/crc32"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// atlasBytes は RenderFontCache.encode と同じ並びの小さなアトラス（字の数値と画素は 0）。
func atlasBytes(side int, cps []rune) []byte {
	var b []byte
	b = binary.BigEndian.AppendUint64(b, atlasMagic)
	b = binary.BigEndian.AppendUint32(b, 1)
	b = binary.BigEndian.AppendUint32(b, uint32(side))
	for _, v := range []float64{10, 8, 2, 0} {
		b = binary.BigEndian.AppendUint64(b, math.Float64bits(v))
	}
	b = binary.BigEndian.AppendUint32(b, uint32(len(cps)))
	for _, cp := range cps {
		b = binary.BigEndian.AppendUint32(b, uint32(cp))
		b = append(b, make([]byte, 72)...)
	}
	return append(b, make([]byte, side*side+16)...)
}

func writeAtlas(t *testing.T, side int, cps []rune) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "a.fontatlas")
	if err := os.WriteFile(p, atlasBytes(side, cps), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestReadAtlasListsGlyphs(t *testing.T) {
	a, err := ReadAtlas("default", writeAtlas(t, 4, []rune{'A', '泉'}))
	if err != nil || a.Side != 4 || !a.Glyphs['泉'] || len(a.Glyphs) != 2 {
		t.Fatalf("got %+v %v", a, err)
	}
}

func TestReadAtlasRejectsWrongLength(t *testing.T) {
	p := writeAtlas(t, 4, []rune{'A'})
	data, _ := os.ReadFile(p)
	_ = os.WriteFile(p, data[:len(data)-1], 0o644)
	if _, err := ReadAtlas("default", p); err == nil {
		t.Fatal("切れたファイルを読んだ")
	}
}

func TestLeakIsCharInNoAtlas(t *testing.T) {
	cs := newCharset()
	cs.add('泉', Origin{"assets/a.yarn", 3, false})
	cs.add('A', Origin{"assets/a.yarn", 3, false})
	a, _ := ReadAtlas("default", writeAtlas(t, 4, []rune{'A'}))
	leaks := FindLeaks(cs, []*Atlas{a})
	if len(leaks) != 1 || leaks[0].Rune != '泉' || leaks[0].Dev {
		t.Fatalf("got %+v", leaks)
	}
}

func TestCharInAnyAtlasIsNotLeak(t *testing.T) {
	cs := newCharset()
	cs.add('泉', Origin{"assets/a.yarn", 3, false})
	a, _ := ReadAtlas("default", writeAtlas(t, 4, []rune{'A'}))
	b, _ := ReadAtlas("label", writeAtlas(t, 4, []rune{'泉'}))
	if leaks := FindLeaks(cs, []*Atlas{a, b}); len(leaks) != 0 {
		t.Fatalf("got %+v", leaks)
	}
}

func TestDevOnlyLeakIsMarkedDev(t *testing.T) {
	cs := newCharset()
	cs.add('⚠', Origin{"src/sim/A.flix", 1, true})
	a, _ := ReadAtlas("default", writeAtlas(t, 4, nil))
	if leaks := FindLeaks(cs, []*Atlas{a}); len(leaks) != 1 || !leaks[0].Dev {
		t.Fatalf("got %+v", leaks)
	}
}

func TestFormatLeakShowsCodeAndOrigin(t *testing.T) {
	got := FormatLeak(Leak{Rune: '⚠', Origins: []Origin{{"src/A.flix", 9, false}}, Count: 3})
	if !strings.Contains(got, "U+26A0") || !strings.Contains(got, "src/A.flix:9") || !strings.Contains(got, "ほか 2 か所") {
		t.Fatalf("got %s", got)
	}
}

func TestMountComesFromFlixToml(t *testing.T) {
	toml := `"github:ababup1192/flix_game_engine" = { version = "0.84.1", mount = "eng", security = "unrestricted" }`
	if got := mountOf(toml); got != "eng" {
		t.Fatalf("got %s", got)
	}
}

func TestJoinPixelsUndoesSplitPixels(t *testing.T) {
	data := atlasBytes(4, []rune{'A', '泉'})
	for i := range 16 {
		data[headerSize+2*glyphRecord+i] = byte(i * 13)
	}
	rest, pixels, side, err := SplitPixels(data)
	if err != nil || side != 4 {
		t.Fatalf("side %d %v", side, err)
	}
	back, err := JoinPixels(rest, pixels)
	if err != nil || string(back) != string(data) {
		t.Fatalf("組み直しが元と違う（%v）", err)
	}
}

func TestSplitPixelsLeavesNoPixelsInRest(t *testing.T) {
	rest, _, _, _ := SplitPixels(atlasBytes(4, []rune{'A'}))
	if len(rest) != headerSize+glyphRecord+trailerBytes {
		t.Fatalf("残りが %d バイト", len(rest))
	}
}

func filledAtlas(side int, value func(x, y int) byte) []byte {
	data := atlasBytes(side, []rune{'A', '泉'})
	start := headerSize + 2*glyphRecord
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			data[start+y*side+x] = value(x, y)
		}
	}
	return data
}

func TestDownscaleRoundsSideUpToMultipleOfFour(t *testing.T) {
	small, err := Downscale(filledAtlas(20, func(x, y int) byte { return 0 }), 0.5)
	if err != nil {
		t.Fatal(err)
	}
	l, err := layoutOf(small)
	if err != nil || l.side != 12 {
		t.Fatalf("辺 %d（%v）", l.side, err)
	}
}

func TestDownscaleKeepsGlyphTable(t *testing.T) {
	data := filledAtlas(16, func(x, y int) byte { return 0 })
	small, _ := Downscale(data, 0.5)
	if string(small[16:headerSize+2*glyphRecord]) != string(data[16:headerSize+2*glyphRecord]) {
		t.Fatal("字の表が変わった")
	}
}

func TestDownscaleAveragesCoveredPixels(t *testing.T) {
	small, _ := Downscale(filledAtlas(8, func(x, y int) byte { return byte(100 * ((x + y) % 2)) }), 0.5)
	_, pixels, _, _ := SplitPixels(small)
	if pixels[0] != 50 {
		t.Fatalf("2×2 の平均が %d", pixels[0])
	}
}

func TestDownscaleRewritesPixelChecksum(t *testing.T) {
	small, _ := Downscale(filledAtlas(16, func(x, y int) byte { return byte(x * 16) }), 0.5)
	_, pixels, _, _ := SplitPixels(small)
	stored := binary.BigEndian.Uint64(small[len(small)-8:])
	if stored != uint64(crc32.ChecksumIEEE(pixels)) {
		t.Fatal("画素の検算が縮めた画素と合わない")
	}
}

func TestDownscaleRejectsFactorBelowHalf(t *testing.T) {
	if _, err := Downscale(filledAtlas(16, func(x, y int) byte { return 0 }), 0.33); err == nil {
		t.Fatal("0.33 を通した")
	}
}

func TestDownscaleKeepsAtlasWhenSideWouldNotShrink(t *testing.T) {
	data := filledAtlas(4, func(x, y int) byte { return 7 })
	small, _ := Downscale(data, 0.5)
	if string(small) != string(data) {
		t.Fatal("縮まない辺のアトラスが変わった")
	}
}
