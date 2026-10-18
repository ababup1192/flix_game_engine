package px

// 昇格ループ 4〜7 周目（GBC の落ち物パズル・PS 初期の SRPG・90 年代の格闘・今どきの牧場）で昇格した形と直しのテスト。

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// 前の build の legend に使わなくなった色キーが残って字が尽きても、どのコマにも出てこない字を空けて新しい色キーに当てる
// （5 周目: 色を減らしても字が空かず、sprite.json を消さないと build が通らなかった）。
func TestLegendReclaimsStaleKeys(t *testing.T) {
	dir := writeSpec(t, specHead+`"sprites": {"s": {"size": [2, 1], "ramp": "r",
    "parts": [{"id": "p", "shape": {"rect": [0, 0, 2, 1]}, "ops": [{"fill": {"color": "mid"}}, {"put": {"cells": [[1, 0]], "color": "ink"}}]}],
    "frames": {"f": {}}}}}`)
	var legend []string
	for i, r := range legendPool {
		key := fmt.Sprintf("old%d", i)
		if r == 'z' {
			key = "c0" // 今のコマも使う字は残る
		}
		legend = append(legend, fmt.Sprintf("%q: %q", string(r), key))
	}
	base := `{"version": 1, "paletteFile": "assets/t.palette.json", "legend": {` + strings.Join(legend, ", ") +
		`}, "sprites": {"other": {"anchor": {"x": 0, "y": 0}, "frames": {"keep": ["ab"]}}}}`
	if err := os.MkdirAll(filepath.Join(dir, "atelier"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "atelier", "t.sprite.json"), []byte(base), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatalf("古い色キーで字が尽きた legend に新しい色キーを当てられない: %v", err)
	}
	got, _ := pxlib.LoadOrdered(filepath.Join(dir, "atelier", "t.sprite.json"))
	lg := pxlib.LegendOf(got.GetOr("legend", nil))
	if len(lg.Chars) != len(legendPool) {
		t.Errorf("legend の字が %d 個（want %d）", len(lg.Chars), len(legendPool))
	}
	if lg.CharOf["c2"] == "" || lg.CharOf["c0"] != "z" {
		t.Errorf("c2 に字が無いか、使っている c0 の字 z が外れた: c2=%q c0=%q", lg.CharOf["c2"], lg.CharOf["c0"])
	}
	for _, ch := range "ab" { // 書き直さない別のスプライトのコマが使う字は残る
		if _, ok := lg.KeyOf[string(ch)]; !ok {
			t.Errorf("ほかのスプライトのコマが使う字 %q を外した", string(ch))
		}
	}
	if res.Frames[0].Rows[0] != lg.CharOf["c2"]+"z" {
		t.Errorf("行 %q（want %q）", res.Frames[0].Rows[0], lg.CharOf["c2"]+"z")
	}
}

// sway を持つ部品（と on の子）の画素はコマで動くので、平らな色の行が 1px ずれた端の 2 画素を flicker と数えない
// （7 周目: canopy の木に sway(amp=1) を付けると、揺れた葉の端をコマごとに 17〜43 画素数えた）。
func TestFlickerSkipsSwayParts(t *testing.T) {
	// 細い頂（3px）と広い胴: 頂と胴の上の行が一緒に 1px ずれると、頂の端の画素だけが変わり周りは変わらない
	sprites := `{"s": {"size": [12, 9], "ramp": "r",
    "parts": [{"id": "bg", "shape": {"rect": [0, 0, 12, 9]}, "ops": [{"fill": {"color": "ink"}}]},
      {"id": "tree", "shape": {"union": [{"rect": [5, 1, 3, 1]}, {"rect": [3, 2, 7, 6]}]}, "ops": [{"fill": {"color": "mid"}}, {"sway": {"amp": 1}}]}],
    "frames": {"f0": {}, "f1": {}, "f2": {}, "f3": {}, "f4": {}, "f5": {}}}}`
	_, res := mustDraw(t, sprites)
	for _, v := range res.Violations {
		if v.Check == checkFlicker {
			t.Errorf("sway の揺れを flicker と数えた: %s", v.Msg)
		}
	}
	var names []string
	var grids []*pxlib.Grid
	var still []map[string]partPose
	for _, f := range res.Frames {
		names, grids = append(names, f.Name), append(grids, f.grid)
		still = append(still, map[string]partPose{"bg": {}, "tree": {}})
	}
	found := false
	for _, v := range sequenceChecks(names, grids, true, still, nil) {
		found = found || v.Check == checkFlicker
	}
	if !found {
		t.Error("この形は動きの op を見ないと flicker になるはず（試しの形が誤検知を起こしていない）")
	}
	poses := partPoses([]*part{{ID: "tree", Ops: []opCall{{Name: "sway"}}}, {ID: "leaf", On: "tree"}, {ID: "rock"}})
	if !poses["tree"].Moves || !poses["leaf"].Moves || poses["rock"].Moves {
		t.Errorf("動きの op の受け継ぎ: %+v", poses)
	}
}

// 1 枚絵（frames を省いた sprite）は {"f0": {}} と同じ 1 コマを描く（6 周目）。
func TestFramesOptionalForStill(t *testing.T) {
	got, _ := mustDraw(t, `{"s": {"size": [2, 1], "ramp": "r", "parts": [{"id": "p", "shape": {"rect": [0, 0, 2, 1]}, "ops": [{"fill": {"color": "mid"}}]}]}}`)
	if len(got) != 1 || got["f0"] != "cc" {
		t.Errorf("frames を省いた絵: %v（want f0 = cc）", got)
	}
}

// px.cycle はコマ i に values[(i + phase) % len] を返す（axis で [v, 0]・[0, v]）。px.frames の鍵の値に置ける。
func TestStarCycle(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": `
up = px.cycle([0, 1, 3], phase = 1, axis = "y")
col = px.cycle(["a", "b"])
P, F = px.frames(4, [{"id": "a", "at": up, "ops": col}])
px.write_json("o.json", {"up": [up(i) for i in range(4)], "frames": F})
`}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"up": [[0, 1], [0, 3], [0, 0], [0, 1]], "frames": {"f0": {"a": {"at": [0, 1], "ops": "a"}}, "f1": {"a": {"at": [0, 3], "ops": "b"}},
  "f2": {"a": {"at": [0, 0], "ops": "a"}}, "f3": {"a": {"at": [0, 1], "ops": "b"}}}}`
	if got := strings.Join(strings.Fields(string(res.Files[0].Data)), ""); got != strings.Join(strings.Fields(want), "") {
		t.Errorf("px.cycle:\n%s\nwant\n%s", got, want)
	}
	if _, err := runScript(t, map[string]string{"a.px.star": `px.cycle(["a"], axis = "y")`}, "a.px.star", starOptions{}); err == nil {
		t.Error("axis に数でない値を通した")
	}
}

// px.frames に場面の関数を渡すと、コマ 0 の列を部品に、コマ 0 と違う鍵だけを patch にする（4 周目の animate と同じ）。
func TestStarFramesScene(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": `
def scene(i):
    return [{"id": "a", "shape": i % 2, "ops": []}, {"id": "b", "shape": 0, "ops": [i]}]
P, F = px.frames(3, scene)
px.write_json("o.json", {"parts": P, "frames": F})
`}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"parts": [{"id": "a", "shape": 0, "ops": []}, {"id": "b", "shape": 0, "ops": [0]}],
  "frames": {"f0": {}, "f1": {"a": {"shape": 1}, "b": {"ops": [1]}}, "f2": {"b": {"ops": [2]}}}}`
	if got := strings.Join(strings.Fields(string(res.Files[0].Data)), ""); got != strings.Join(strings.Fields(want), "") {
		t.Errorf("px.frames(scene):\n%s\nwant\n%s", got, want)
	}
	_, err = runScript(t, map[string]string{"a.px.star": `
def scene(i):
    return [{"id": "a" if i == 0 else "b"}]
px.frames(2, scene)
`}, "a.px.star", starOptions{})
	if err == nil || !strings.Contains(err.Error(), "id") {
		t.Errorf("コマで id の並びが変わったのを通した: %v", err)
	}
}

// 形 flag は 6 周目の台本の旗（上と下の縁を竿から先へ大きくなる波に・先で下の縁が上がる）と同じ点の多角形。
func TestFlagMatchesScriptPoly(t *testing.T) {
	x0, y0, w, h := 2.0, 3.0, 20.0, 9.0
	turn := 2.0/6 + 0.33
	var top, bot []string
	for k := 0; k < 7; k++ {
		tk := float64(k) / 6.0
		a := (turn - tk*0.8) * 2 * math.Pi
		dy := math.Sin(a) * 3 * tk
		dx := -math.Cos(a) * 1.5 * tk
		x := math.RoundToEven(x0 + w*tk + dx)
		top = append(top, fmt.Sprintf("[%g, %g]", x, math.RoundToEven(y0+dy)))
		bot = append([]string{fmt.Sprintf("[%g, %g]", x, math.RoundToEven(y0+h+dy-tk*2))}, bot...)
	}
	poly := strings.Join(onePartRows(t, `{"poly": [`+strings.Join(append(top, bot...), ", ")+`]}`), "\n")
	flag := strings.Join(onePartRows(t, fmt.Sprintf(`{"flag": [2, 3, 20, 9], "t": %v, "amp": 3, "sway": 1.5, "waves": 0.8, "rise": 2}`, turn)), "\n")
	if poly != flag {
		t.Errorf("flag と台本の旗の多角形が違う:\n%s\n---\n%s", flag, poly)
	}
}

func onePartRows(t *testing.T, shape string) []string {
	t.Helper()
	return buildRows(t, specHead+`"sprites": {"s": {"size": [26, 16], "ramp": "r",
    "parts": [{"id": "p", "shape": `+shape+`, "ops": [{"fill": {"color": "mid"}}]}]}}}`)
}

// bar は 6 周目の手書きの体力のバー（減った所を塗る → 残りを段で → 上の 1px のつや → 今減った量）と同じ画素。
func TestBarMatchesHandWritten(t *testing.T) {
	hand := onePart("24, 6", `[{"fill": {"shape": {"rect": [2, 1, 20, 4]}, "color": "c0"}},
    {"gradient_fill": {"shape": {"rect": [2, 1, 6, 4]}, "field": "y", "from": 1, "band": 0.5}},
    {"line": {"points": [[2, 1], [7, 1]], "color": "c3"}},
    {"fill": {"shape": {"rect": [8, 1, 2, 4]}, "color": "c1"}}]`)
	bar := onePart("24, 6", `[{"bar": {"shape": {"rect": [2, 1, 20, 4]}, "rate": 0.3, "empty": "c0", "from": 1, "band": 0.5, "top": "c3",
    "lost": 0.09, "lost_color": "c1"}}]`)
	if a, b := strings.Join(buildRows(t, hand), "\n"), strings.Join(buildRows(t, bar), "\n"); a != b {
		t.Errorf("bar と手書きのバーが違う:\n%s\n---\n%s", b, a)
	}
	got, _ := mustDraw(t, `{"s": {"size": [24, 6], "ramp": "r", "parts": [{"id": "p", "ops": [
    {"bar": {"shape": {"rect": [2, 1, 20, 4]}, "rate": 0.8, "side": "right", "fill": "c2", "empty": "c0"}}]}], "frames": {"f": {}}}}`)
	if row := strings.Split(got["f"], " / ")[2]; row != "..aaaacccccccccccccccc.." {
		t.Errorf("右へ寄せた 8 割のバー: %q", row)
	}
}
