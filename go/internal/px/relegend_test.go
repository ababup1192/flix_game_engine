package px

import (
	"bytes"
	"image/color"
	"image/png"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// relegend は右から左へ書く字・ギリシャ文字の印を ASCII へ移し、描いた PNG はバイトまで同じ（使える ASCII の字は残す）。
func TestRelegendKeepsPixels(t *testing.T) {
	src := `{"version": 1, "palette": {"r0": "#102030", "r1": "#405060", "g": "#a0b0c0"},
  "legend": {"א": "r0", "Β": "r1", "z": "g"},
  "sprites": {"s": {"anchor": {"x": 0, "y": 0}, "frames": {"f": ["אΒz", "zΒא"], "g": [".א.", "zzΒ"]}}}}`
	before, err := pxlib.DecodeOrdered([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	after, _ := pxlib.DecodeOrdered([]byte(src))
	moves, err := relegendDoc(after.(*pxlib.Obj))
	if err != nil {
		t.Fatal(err)
	}
	if moves["א"] == "" || moves["Β"] == "" || moves["z"] != "" {
		t.Fatalf("移す字が違う: %v", moves)
	}
	for _, to := range moves {
		if r := []rune(to)[0]; r >= 0x7F || pxlib.LegendCharProblem(r) != "" {
			t.Errorf("移した先 %q が ASCII の表示できる字でない", to)
		}
	}
	if err := sameKeys(before.(*pxlib.Obj), after.(*pxlib.Obj)); err != nil {
		t.Fatal(err)
	}
	render := func(doc *pxlib.Obj) []byte {
		plain, _ := pxlib.Plain(doc).(map[string]any)
		pal := pxlib.DocPalette(".", plain, nil, pxlib.AnyColor)
		hex := map[pxlib.Key]string{}
		for k, h := range pal {
			hex[pxlib.Key(k)] = h
		}
		lg := pxlib.LegendOf(doc.GetOr("legend", nil))
		legend := map[string]string{}
		for ch, k := range lg.KeyOf {
			legend[ch] = string(k)
		}
		var buf bytes.Buffer
		frames := doc.GetOr("sprites", nil).(*pxlib.Obj).GetOr("s", nil).(*pxlib.Obj).GetOr("frames", nil).(*pxlib.Obj)
		_, vals := frames.Items()
		for _, v := range vals {
			img := pxlib.Strip([][][]color.RGBA{colorsOf(strs(v), legend, hex)})
			if err := png.Encode(&buf, img); err != nil {
				t.Fatal(err)
			}
		}
		return buf.Bytes()
	}
	if !bytes.Equal(render(before.(*pxlib.Obj)), render(after.(*pxlib.Obj))) {
		t.Error("振り直す前と後で PNG のバイトが違う")
	}
}
