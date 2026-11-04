package fontbake

import (
	"encoding/binary"
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
