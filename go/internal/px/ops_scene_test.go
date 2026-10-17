package px

import (
	"bytes"
	"image/color"
	"image/gif"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// buildRows は spec を描いて 1 コマ目の行を返す。
func buildRows(t *testing.T, body string) []string {
	t.Helper()
	res, err := build(writeSpec(t, body), "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	return res.Frames[0].Rows
}

func onePart(size, ops string) string {
	return specHead + `
  "sprites": {"s": {"size": [` + size + `], "ramp": "r",
    "parts": [{"id": "p", "ops": ` + ops + `}],
    "frames": {"f": {}}}}}`
}

// text は字形の '#' を color で、影を右下 1px に先に置く（後の字の影が前の字を潰さない）。
func TestTextDrawsGlyphWithShadow(t *testing.T) {
	rows := buildRows(t, onePart("14, 9", `[{"text": {"at": [0, 0], "text": "LT", "color": "c3", "shadow": "c0"}}]`))
	got := strings.Join(rows, "\n")
	want := buildRows(t, onePart("14, 9", `[
      {"glyph_rows": {"at": [0, 0], "rows": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"], "color": "c3", "shadow": "c0"}},
      {"glyph_rows": {"at": [6, 0], "rows": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."], "color": "c3", "shadow": "c0"}}]`))
	if got != strings.Join(want, "\n") {
		t.Errorf("text が glyph_rows を 6px ずつ並べた物と違う:\n%s\nwant\n%s", got, strings.Join(want, "\n"))
	}
}

func TestTextUnknownCharStops(t *testing.T) {
	_, err := build(writeSpec(t, onePart("8, 8", `[{"text": {"at": [0, 0], "text": "あ"}}]`)), "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err == nil || !strings.Contains(err.Error(), "字形に無い") {
		t.Errorf("字形に無い字で止まらない: %v", err)
	}
}

// canopy は、玉ごとの部品（外の 1px・陰・斑・つや）を並べて書いた物と同じ絵になる（台本で書いていた形の昇格）。
func TestCanopyMatchesHandWrittenBalls(t *testing.T) {
	got := buildRows(t, onePart("24, 24", `[{"canopy": {"center": [12, 12], "r": 8, "seed": 5}}]`))
	n := len(circles(canopyBalls))
	var rim []string
	for k := 0; k < n; k++ {
		bx, by, br := canopyBall(k, 12, 12, 8)
		rim = append(rim, `{"disk": [`+ftoa(bx)+`, `+ftoa(by)+`, `+ftoa(br+1)+`]}`)
	}
	parts := `{"id": "rim", "shape": {"union": [` + strings.Join(rim, ", ") + `]}, "ops": [{"fill": {"color": "c0"}}]}`
	for k := 0; k < n; k++ {
		bx, by, br := canopyBall(k, 12, 12, 8)
		parts += `, {"id": "b` + itoa(k) + `", "shape": {"disk": [` + ftoa(bx) + `, ` + ftoa(by) + `, ` + ftoa(br) + `]}, "ops": [
        {"directional": {"band": 1, "from": 1, "to": 3}},
        {"scatter_clusters": {"colors": ["c1", "c3"], "cell": 3, "seed": ` + itoa(5+k) + `, "keep": 0.5}},
        {"fill": {"shape": {"disk": [` + ftoa(bx-float64(br*0.35)) + `, ` + ftoa(by-float64(br*0.4)) + `, ` + ftoa(float64(br*0.28)) + `]}, "color": "c3"}}]}`
	}
	want := buildRows(t, specHead+`
  "light": {"dir": [-1, -1]},
  "sprites": {"s": {"size": [24, 24], "ramp": "r", "parts": [`+parts+`], "frames": {"f": {}}}}}`)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("canopy が玉ごとの部品と違う:\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func canopyBall(k int, cx, cy, r float64) (float64, float64, float64) {
	v := circles(canopyBalls)[k]
	return cx + float64(v[0]*r), cy + float64(v[1]*r), float64(v[2] * r)
}

// ランプの無い部品では、ink などは同じ名前の色キーを指す（ランプのある部品ではランプの段のまま）。
func TestReservedNameFallsBackToKeyWithoutRamp(t *testing.T) {
	dir := writeFiles(t, map[string]string{
		"assets/t.palette.json": `{"version": 1, "ink": "#101010", "c0": "#202020", "c1": "#606060"}`,
		"t.pxsrc.json": `{"version": 2, "target": "atelier/t.sprite.json", "palette": "assets/t.palette.json", "ramps": {"r": ["c0", "c1"]},
  "sprites": {"s": {"size": [4, 2], "parts": [
    {"id": "a", "shape": {"rect": [0, 0, 2, 1]}, "ops": [{"fill": {"color": "ink"}}]},
    {"id": "b", "shape": {"rect": [0, 1, 2, 1]}, "ramp": "r", "ops": [{"fill": {"color": "ink"}}]}],
  "frames": {"f": {}}}}}`,
	})
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	keyAt := func(x, y int) string { return string(res.Frames[0].grid.At(x, y)) }
	if keyAt(0, 0) != "ink" || keyAt(0, 1) != "c0" {
		t.Errorf("ink の読み方: ランプなし %s（want ink）・ランプあり %s（want c0）", keyAt(0, 0), keyAt(0, 1))
	}
}

// GIF は同じコマから毎回同じバイトになり、コマの数と長さを持つ。
func TestGIFIsDeterministic(t *testing.T) {
	red, clear := color.RGBA{200, 40, 40, 255}, color.RGBA{}
	frames := [][][]color.RGBA{{{red, clear}}, {{clear, red}}, {{red, red}}}
	dir := t.TempDir()
	var data [2][]byte
	for i := range data {
		p := filepath.Join(dir, itoa(i)+".gif")
		if err := writeGIF(p, frames, 2, 20); err != nil {
			t.Fatal(err)
		}
		data[i], _ = os.ReadFile(p)
	}
	if !bytes.Equal(data[0], data[1]) {
		t.Fatal("同じコマから違うバイト")
	}
	g, err := gif.DecodeAll(bytes.NewReader(data[0]))
	if err != nil {
		t.Fatal(err)
	}
	if len(g.Image) != 3 || g.Delay[0] != 20 || g.Image[0].Bounds().Dx() != 4 {
		t.Errorf("コマ %d・長さ %d・幅 %d（want 3・20・4）", len(g.Image), g.Delay[0], g.Image[0].Bounds().Dx())
	}
}

// px.frames は関数の鍵をコマ 0 の値に置き換え、コマごとの差し替えを作る。
func TestStarFrames(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": `
P, F = px.frames(3, [{"id": "a", "ops": lambda i: [i]}, {"id": "b", "ops": []}])
px.write_json("o.json", {"parts": P, "frames": F})
`}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"parts": [{"id": "a", "ops": [0]}, {"id": "b", "ops": []}], "frames": {"f0": {"a": {"ops": [0]}}, "f1": {"a": {"ops": [1]}}, "f2": {"a": {"ops": [2]}}}}`
	if got := strings.Join(strings.Fields(string(res.Files[0].Data)), ""); got != strings.Join(strings.Fields(want), "") {
		t.Errorf("px.frames:\n%s\nwant\n%s", got, want)
	}
}

func itoa(i int) string { return strconv.Itoa(i) }

func ftoa(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }
