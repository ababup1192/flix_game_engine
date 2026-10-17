package px

// 昇格ループ 2 周目（縦シューティング）で見つかった不具合の直しのテスト。

import (
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// at でずらした部品の gradient_fill は、Bayer のディザの網目も一緒に動く（画面に固定すると、ずらすコマの間で境目がちらつく）。
func TestGradientDitherMovesWithAt(t *testing.T) {
	res, err := build(writeSpec(t, specHead+`
  "sprites": {"s": {"size": [24, 12], "ramp": "r", "parts": [
    {"id": "p", "shape": {"rect": [2, 1, 12, 10]}, "ops": [{"gradient_fill": {"field": "y", "band": 1}}]}],
    "frames": {"f0": {}, "f1": {"p": {"at": [3, 1]}}}}}}`), "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	a, b := res.Frames[0].grid, res.Frames[1].grid
	for y := 1; y < 11; y++ {
		for x := 2; x < 14; x++ {
			if a.At(x, y) != b.At(x+3, y+1) {
				t.Fatalf("(%d,%d) の色がずらした先 (%d,%d) と違う: %s と %s", x, y, x+3, y+1, a.At(x, y), b.At(x+3, y+1))
			}
		}
	}
}

// コマで at（や rotate）が変わる部品の画素は動きなので flicker と数えない（一様にスクロールする層）。
func TestFlickerSkipsMovedParts(t *testing.T) {
	a := gridOf("....", ".cc.", ".cc.", "....")
	b := gridOf("....", ".cc.", ".cd.", "....")
	b.Put(2, 2, "d", pxlib.OpRef{Part: "cloud"})
	still := []map[string]partPose{{"cloud": {}}, {"cloud": {}}}
	if vs := sequenceChecks([]string{"a", "b"}, []*pxlib.Grid{a, b}, true, still); len(vs) == 0 || vs[0].Check != checkFlicker {
		t.Fatalf("動かない部品のちらつきを見逃した: %v", vs)
	}
	moved := []map[string]partPose{{"cloud": {}}, {"cloud": {At: pxlib.Pt{Y: 3}}}}
	for _, v := range sequenceChecks([]string{"a", "b"}, []*pxlib.Grid{a, b}, true, moved) {
		if v.Check == checkFlicker {
			t.Errorf("at が変わった部品の画素を flicker と数えた: %s", v.Msg)
		}
	}
}

// pillow は emissive の部品（光る核・爆発）を見ない（light-dir と同じ）。
func TestPillowSkipsEmissive(t *testing.T) {
	cc := techRules(t)
	g := gridOf("aaaaaa", "abbbba", "abddba", "abddba", "abbbba", "aaaaaa")
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			g.Put(x, y, g.At(x, y), pxlib.OpRef{Part: "core"})
		}
	}
	if countCheck(g, cc, checkPillow) != 1 {
		t.Fatal("emissive でない部品で pillow が出ない")
	}
	cc.Emissive = map[string]bool{"core": true}
	if n := countCheck(g, cc, checkPillow); n != 0 {
		t.Errorf("emissive の部品に pillow が %d 件", n)
	}
}

// build --png の GIF は --gif-delay・--gif-scale で長さと拡大を選べる（既定は 200ms・2 倍）。
func TestPNGGIFDelayAndScale(t *testing.T) {
	var out, errOut strings.Builder
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [4, 4], "ramp": "r", "parts": [{"id": "p", "shape": {"rect": [0, 0, 2, 2]}, "ops": [{"fill": {"color": "c1"}}]}],
    "frames": {"f0": {}, "f1": {"p": {"at": [1, 1]}}}}}}`)
	if code := Run(&out, &errOut, engineRoot, dir, []string{"build", "t.pxsrc.json", "--png", "--gif-delay", "80", "--gif-scale", "3", "--no-check"}, false); code != 0 {
		t.Fatalf("build: %s", errOut.String())
	}
	g := decodeGIF(t, dir+"/debug/px/t/png/s.gif")
	if g.Delay[0] != 8 || g.Image[0].Bounds().Dx() != 12 {
		t.Errorf("長さ %d・幅 %d（want 8・12）", g.Delay[0], g.Image[0].Bounds().Dx())
	}
	errOut.Reset()
	if code := Run(&out, &errOut, engineRoot, dir, []string{"build", "t.pxsrc.json", "--gif-delay", "80"}, false); code != 2 {
		t.Errorf("--png 無しの --gif-delay が通った（%d）", code)
	}
}

// rowsOf は 1 部品の形を fill で塗った 1 コマ目の行（形の書き方を比べる）。
func rowsOf(t *testing.T, size, shape string) string {
	t.Helper()
	return strings.Join(buildRows(t, specHead+`
  "sprites": {"s": {"size": [`+size+`], "ramp": "r", "parts": [{"id": "p", "shape": `+shape+`, "ops": [{"fill": {"color": "c2"}}]}],
    "frames": {"f": {}}}}}`), "\n")
}

// 形の写し: poly の mirror は半分の点を軸で写した多角形・translate はずらし・array と polar は同じ形を並べた和。
func TestShapeCopies(t *testing.T) {
	for _, c := range []struct{ name, got, want string }{
		{"mirror", `{"poly": [[6, 1], [3, 5], [4, 10], [6, 10]], "mirror": 6}`, `{"poly": [[6, 1], [3, 5], [4, 10], [6, 10], [8, 10], [9, 5]]}`},
		{"translate", `{"translate": [3, 2], "of": {"disk": [4, 4, 2.5]}}`, `{"disk": [7, 6, 2.5]}`},
		{"array", `{"array": [[2, 2], [8, 5]], "of": {"rect": [0, 0, 2, 3]}}`, `{"union": [{"rect": [2, 2, 2, 3]}, {"rect": [8, 5, 2, 3]}]}`},
		{"polar", `{"polar": [6, 6, 4], "n": 4, "rings": 2, "step": 1, "twist": 0.7853981633974483, "snap": true, "of": {"disk": [0.5, 0.5, 0.6]}}`,
			`{"union": [{"disk": [10.5, 6.5, 0.6]}, {"disk": [6.5, 10.5, 0.6]}, {"disk": [2.5, 6.5, 0.6]}, {"disk": [6.5, 2.5, 0.6]},
			  {"disk": [10.5, 10.5, 0.6]}, {"disk": [2.5, 10.5, 0.6]}, {"disk": [2.5, 2.5, 0.6]}, {"disk": [10.5, 2.5, 0.6]}]}`},
	} {
		if got, want := rowsOf(t, "14, 14", c.got), rowsOf(t, "14, 14", c.want); got != want {
			t.Errorf("%s:\n%s\nwant\n%s", c.name, got, want)
		}
	}
}

// 形 text は字形の組の画素（bold6x8 は 6×8・送り 7）。部品の shape にして塗れる。
func TestTextShapeBoldFont(t *testing.T) {
	got := rowsOf(t, "13, 8", `{"text": "1-", "font": "bold6x8"}`)
	var rows []string
	for y := 0; y < 8; y++ {
		rows = append(rows, `"`+fontBold6x8['1'][y]+"."+fontBold6x8['-'][y]+`"`)
	}
	if want := rowsOf(t, "13, 8", `{"mask": [`+strings.Join(rows, ", ")+`]}`); got != want {
		t.Errorf("形 text:\n%s\nwant\n%s", got, want)
	}
}

// scroll は形を period（既定 speed × コマ数）おきに写し、コマ i で speed·i ずらす（コマを回すと継ぎ目なく 1 周期）。
// gradient_fill の per: copy は写しを 1 つずつ塗る（part は写し全体で 1 つの場）。
func TestScrollAndPerCopy(t *testing.T) {
	res, err := build(writeSpec(t, specHead+`
  "sprites": {"s": {"size": [4, 12], "ramp": "r", "parts": [
    {"id": "p", "shape": {"rect": [1, 0, 2, 3]}, "scroll": {"speed": [0, 2]}, "ops": [{"gradient_fill": {"field": "y", "band": 0, "per": "copy"}}]}],
    "frames": {"f0": {}, "f1": {}, "f2": {}}}}}`), "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	f0, f1 := res.Frames[0].grid, res.Frames[1].grid
	for y := 0; y < 12; y++ {
		if want := f0.At(1, (y+12-2)%6); f1.At(1, y) != want && y >= 2 {
			t.Fatalf("f1 の (1,%d) が f0 を 2 下げた色と違う: %s と %s", y, f1.At(1, y), want)
		}
	}
	// 周期 6 の写しが 2 つ見え、どちらも上の画素が一番明るい
	if f0.At(1, 0) != "c3" || f0.At(1, 6) != "c3" || f0.At(1, 2) != "c0" {
		t.Errorf("per: copy の塗り: (1,0)=%s (1,6)=%s (1,2)=%s（want c3・c3・c0）", f0.At(1, 0), f0.At(1, 6), f0.At(1, 2))
	}
}

// style の palettes: 部品ごとの色の集合を count 本 × size 色に割り付けられなければ門で止める。
func TestStylePalettesGate(t *testing.T) {
	for _, c := range []struct {
		count int
		bad   bool
	}{{1, true}, {2, false}} {
		dir := writeFiles(t, map[string]string{
			"assets/t.palette.json": `{"version": 1, "c0": "#202020", "c1": "#606060", "c2": "#a0a0a0", "c3": "#e0e0e0"}`,
			"t.pxstyle.json":        `{"label": "試し", "palettes": {"count": ` + itoa(c.count) + `, "size": 2}}`,
			"t.pxsrc.json": `{"version": 2, "target": "atelier/t.sprite.json", "palette": "assets/t.palette.json", "style": "t.pxstyle.json",
  "ramps": {"r": ["c0", "c1", "c2", "c3"]},
  "sprites": {"s": {"size": [4, 2], "ramp": "r", "parts": [
    {"id": "a", "shape": {"rect": [0, 0, 2, 1]}, "ops": [{"fill": {"color": "c0"}}, {"fill": {"shape": {"rect": [1, 0, 1, 1]}, "color": "c1"}}]},
    {"id": "b", "shape": {"rect": [0, 1, 2, 1]}, "ops": [{"fill": {"color": "c2"}}, {"fill": {"shape": {"rect": [1, 1, 1, 1]}, "color": "c3"}}]}],
    "frames": {"f": {}}}}}`,
		})
		res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
		bad := false
		if err == nil {
			for _, v := range res.Violations {
				bad = bad || v.Check == checkStyle && v.Level == levelGate && strings.Contains(v.Msg, "割り付けられない")
			}
		}
		if bad != c.bad {
			t.Errorf("palettes %d 本 × 2 色: 止まった %v（want %v）: %v", c.count, bad, c.bad, err)
		}
	}
}
