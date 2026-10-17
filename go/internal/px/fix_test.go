package px

// レビュー（段 3）と見本 10 題の担当から届いた不具合の直しの例。どれも小さな spec を描いて、
// 直す前に起きていた症状が出ないことを見る。色は c0 < c1 < c2 < c3 を a < b < c < d の 1 字で書く。

import (
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// drawSpec は sprites の JSON を描き、コマ名 → 行（a〜d・'.'）を返す。誤りは返す。
func drawSpec(t *testing.T, sprites string) (map[string]string, *buildResult, error) {
	t.Helper()
	dir := writeSpec(t, specHead+`"sprites": `+sprites+`}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		return nil, nil, err
	}
	short := strings.NewReplacer("c0", "a", "c1", "b", "c2", "c", "c3", "d")
	out := map[string]string{}
	for _, f := range res.Frames {
		out[f.Name] = short.Replace(rowsOfGrid(f.grid))
	}
	return out, res, nil
}

func mustDraw(t *testing.T, sprites string) (map[string]string, *buildResult) {
	t.Helper()
	got, res, err := drawSpec(t, sprites)
	if err != nil {
		t.Fatal(err)
	}
	return got, res
}

// 数の引数の範囲の外は、描く前に場所つきの誤りになる（sel_out の負の drop は panic していた）。
func TestNumberRangeRejected(t *testing.T) {
	for _, op := range []string{`{"sel_out": {"drop": -1}}`, `{"sel_out": {"lit_drop": -3}}`, `{"sway": {"curve": 0}}`,
		`{"squash": {"amount": 1}}`, `{"ramp_pick": {"base": "c1", "n": 1000000000}}`, `{"ground_shadow": {"rows": 100000}}`} {
		_, _, err := drawSpec(t, `{"s": {"size": [4, 4], "ramp": "r", "parts": [{"id": "p", "shape": {"rect": [1, 1, 2, 2]}, "ops": [`+op+`]}], "frames": {"f": {}}}}`)
		if err == nil || !strings.Contains(err.Error(), "範囲の外") || !strings.Contains(err.Error(), "p.ops") {
			t.Errorf("%s: 場所つきの範囲の誤りにならない: %v", op, err)
		}
	}
}

// sel_out の光の側は light.dir から決める（右上の光なら右上の縁が明るい側）。
func TestSelOutFollowsLight(t *testing.T) {
	g := gridOf(".....", ".ccc.", ".ccc.", ".ccc.", ".....")
	c := testCtx(g, opaqueOf(g))
	c.Spec.Light.Dir = [3]float64{1, -1, 0.9}
	applyOp(t, c, `{"sel_out": {}}`)
	expectRows(t, g, ".bbb.", "acccb", "acccb", "acccb", ".aaa.")
}

// pixel_perfect が抜いた画素は、線の下の色（先に描いた地）に戻る（透明の穴を開けない）。
func TestPixelPerfectKeepsGround(t *testing.T) {
	got, _ := mustDraw(t, `{"s": {"size": [4, 4], "ramp": "r", "parts": [
	  {"id": "ground", "shape": {"rect": [0, 0, 4, 4]}, "ops": [{"fill": {"color": "light"}}]},
	  {"id": "line", "ops": [{"put": {"cells": [[0, 0], [1, 0], [1, 1], [2, 1], [2, 2]], "color": "ink"}}, {"pixel_perfect": {}}]}],
	  "frames": {"f": {}}}}`)
	if strings.Contains(got["f"], ".") {
		t.Fatalf("地に穴が開いた: %s", got["f"])
	}
}

// post に置いた bob は、描き終えた絵の全体を動かす（post が描いた画素だけを拾って何もしなかった）。
func TestPostBobMovesPicture(t *testing.T) {
	got, _ := mustDraw(t, `{"s": {"size": [4, 6], "ramp": "r", "parts": [{"id": "p", "shape": {"rect": [1, 2, 2, 3]}, "ops": [{"fill": {"color": "mid"}}]}],
	  "post": [{"bob": {"amp": 1}}], "frames": {"f0": {}, "f1": {}, "f2": {}, "f3": {}}}}`)
	if got["f1"] == got["f3"] {
		t.Fatalf("post の bob で絵が動かない: %v", got)
	}
}

// post の rim_light と aa_corners も、描き終えた絵の外形に当たる（post ではランプが空で何も描かなかった）。
func TestPostEdgeOpsDraw(t *testing.T) {
	plain, _ := mustDraw(t, `{"s": {"size": [6, 6], "ramp": "r", "parts": [{"id": "p", "shape": {"rect": [1, 1, 4, 4]}, "ops": [{"fill": {"color": "shade"}}]}], "frames": {"f": {}}}}`)
	rim, _ := mustDraw(t, `{"s": {"size": [6, 6], "ramp": "r", "parts": [{"id": "p", "shape": {"rect": [1, 1, 4, 4]}, "ops": [{"fill": {"color": "shade"}}]}], "post": [{"rim_light": {}}], "frames": {"f": {}}}}`)
	if plain["f"] == rim["f"] {
		t.Fatal("post の rim_light が何も描かない")
	}
}

// on の子（顔の部品）は、pose で動いた親（頭）と一緒に動く。
func TestPoseChildFollowsHead(t *testing.T) {
	got, _ := mustDraw(t, `{"s": {"size": [8, 10], "ramp": "r", "parts": [
	  {"id": "body", "shape": {"rect": [2, 5, 4, 3]}, "ops": [{"fill": {"color": "mid"}}]},
	  {"id": "head", "shape": {"rect": [2, 1, 4, 3]}, "ops": [{"fill": {"color": "light"}}]},
	  {"id": "eye", "on": "head", "ops": [{"put": {"cells": [[4, 2]], "color": "ink"}}]}],
	  "frames": {"stand": {"pose": "passing"}, "down": {"pose": "down"}}}}`)
	rows := func(f string) []string { return strings.Split(got[f], " / ") }
	if rows("stand")[2][4] != 'a' || rows("down")[3][4] != 'a' {
		t.Fatalf("目が頭と一緒に 1px 下がらない:\n%s\n%s", got["stand"], got["down"])
	}
}

// pose のずらしは部品の元の at に足す（元の at を [0, 1] で上書きしていた）。
func TestPoseShiftAddsToAt(t *testing.T) {
	got, _ := mustDraw(t, `{"s": {"size": [8, 10], "ramp": "r", "parts": [
	  {"id": "head", "at": [2, 2], "shape": {"rect": [0, 0, 1, 1]}, "ops": [{"fill": {"color": "light"}}]}],
	  "frames": {"stand": {"pose": "passing"}, "down": {"pose": "down"}}}}`)
	if strings.Split(got["down"], " / ")[3][2] != 'd' {
		t.Fatalf("down の頭が元の at から 1px 下にない: %s", got["down"])
	}
}

// shade_parts は pose の at のずらしと一緒に使える（格子全体の op として at を断っていた）。
func TestShadePartsWithPose(t *testing.T) {
	if _, _, err := drawSpec(t, `{"s": {"size": [10, 12], "ramp": "r", "parts": [
	  {"id": "head", "shape": {"disk": [5, 4, 3]}, "ops": [{"shade_parts": {}}]}],
	  "frames": {"stand": {"pose": "passing"}, "down": {"pose": "down"}}}}`); err != nil {
		t.Fatal(err)
	}
}

// pose の flip は手前と奥の手足の動きを入れ替える（逆の contact）。
func TestPoseFlip(t *testing.T) {
	got, _ := mustDraw(t, `{"s": {"size": [12, 12], "ramp": "r", "parts": [
	  {"id": "legF", "shape": {"rect": [4, 3, 1, 7]}, "ops": [{"fill": {"color": "mid"}}]},
	  {"id": "legB", "shape": {"rect": [7, 3, 1, 7]}, "ops": [{"fill": {"color": "shade"}}]}],
	  "frames": {"a": {"pose": "contact"}, "b": {"pose": "contact", "flip": true}}}}`)
	if got["a"] == got["b"] {
		t.Fatal("flip で姿勢が変わらない")
	}
}

// sway は部品の ops が描いた模様ごと動かし、on の子の部品も同じ揺れで付いていく。
func TestSwayMovesPatternAndChildren(t *testing.T) {
	got, _ := mustDraw(t, `{"s": {"size": [10, 8], "ramp": "r", "parts": [
	  {"id": "tree", "shape": {"rect": [3, 0, 4, 8]}, "ops": [{"sway": {"amp": 2}}, {"fill": {"color": "mid"}}, {"put": {"cells": [[4, 1]], "color": "ink"}}]},
	  {"id": "fruit", "on": "tree", "ops": [{"put": {"cells": [[5, 1]], "color": "light"}}]}],
	  "frames": {"f0": {}, "f1": {}, "f2": {}, "f3": {}}}}`)
	for f, rows := range got {
		top := strings.Split(rows, " / ")[1]
		ink, fruit := strings.IndexByte(top, 'a'), strings.IndexByte(top, 'd')
		if ink < 0 || fruit != ink+1 {
			t.Errorf("%s: 模様と子が幹と一緒に揺れない: %s", f, top)
		}
	}
}

// 材質の stone は outline: false で sel_out を外せる（タイルの目地を潰さない）。
func TestMaterialOutlineOff(t *testing.T) {
	on, _ := mustDraw(t, `{"s": {"size": [8, 8], "ramp": "r", "parts": [{"id": "m", "shape": {"rect": [1, 1, 6, 6]}, "material": "stone"}], "frames": {"f": {}}}}`)
	off, _ := mustDraw(t, `{"s": {"size": [8, 8], "ramp": "r", "parts": [{"id": "m", "shape": {"rect": [1, 1, 6, 6]}, "material": {"stone": {"outline": false}}}], "frames": {"f": {}}}}`)
	if strings.Split(on["f"], " / ")[0] == "........" || strings.Split(off["f"], " / ")[0] != "........" {
		t.Fatalf("outline の有無で縁取りが変わらない:\n%s\n%s", on["f"], off["f"])
	}
}

// wave_shift は外形を動かさず、中の模様だけをコマごとに流す。
func TestWaveShift(t *testing.T) {
	got, _ := mustDraw(t, `{"s": {"size": [6, 3], "ramp": "r", "parts": [{"id": "w", "shape": {"rect": [0, 1, 5, 1]}, "ops": [{"fill": {"color": "mid"}}, {"put": {"cells": [[0, 1]], "color": "light"}}, {"wave_shift": {}}]}],
	  "frames": {"f0": {}, "f1": {}, "f2": {}}}}`)
	if got["f0"] != "...... / dcccc. / ......" || got["f1"] != "...... / cdccc. / ......" {
		t.Fatalf("波頭が 1px ずつ流れない: %v", got)
	}
}

// pivot は .5（画素の境目）を書ける。frames の patch の shape は丸ごと替わる（ref と二重にならない）。
func TestPivotHalfAndShapePatch(t *testing.T) {
	_, _, err := drawSpec(t, `{"s": {"size": [8, 8], "ramp": "r", "parts": [
	  {"id": "p", "shape": {"ref": "box"}, "rotate": 0, "pivot": [3.5, 3.5], "ops": [{"fill": {"color": "mid"}}]}],
	  "frames": {"a": {}, "b": {"p": {"shape": {"disk": [4, 4, 2]}, "rotate": 30}}}}}`)
	if err == nil || !strings.Contains(err.Error(), "box") {
		t.Fatalf("shapes に無い ref は誤りのはず: %v", err)
	}
	dir := writeSpec(t, specHead+`"shapes": {"box": {"rect": [2, 2, 4, 4]}}, "sprites": {"s": {"size": [8, 8], "ramp": "r", "parts": [
	  {"id": "p", "shape": {"ref": "box"}, "pivot": [3.5, 3.5], "ops": [{"fill": {"color": "mid"}}]}],
	  "frames": {"a": {}, "b": {"p": {"shape": {"disk": [4, 4, 2]}, "rotate": 30}}}}}}`)
	if _, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot}); err != nil {
		t.Fatal(err)
	}
}

// 周りが動かないのに色だけ変わる画素は flicker、縁に触れて動く絵は margin。
func TestFlickerAndMargin(t *testing.T) {
	a := gridOf("....", ".cc.", ".cc.", "....")
	b := gridOf("....", ".cc.", ".cd.", "....")
	vs := sequenceChecks([]string{"a", "b"}, []*pxlib.Grid{a, b})
	if len(vs) == 0 || vs[0].Check != checkFlicker {
		t.Fatalf("ちらつきを見逃した: %v", vs)
	}
	edge1 := gridOf("cc..", "cc..", "....", "....")
	edge2 := gridOf(".cc.", ".cc.", "....", "....")
	found := false
	for _, v := range sequenceChecks([]string{"a", "b"}, []*pxlib.Grid{edge1, edge2}) {
		found = found || v.Check == checkMargin
	}
	if !found {
		t.Fatal("縁に詰まった動きで margin が出ない")
	}
}

// light-dir は、最暗の色が過半数の塊でも光と逆の陰を見つける（中央値で分けると片側が空になっていた）。
func TestLightDirMajorityDark(t *testing.T) {
	cc := techRules(t)
	g := gridOf("aaaa", "aaaa", "aaab", "aabd")
	if countCheck(g, cc, checkLightDir) != 1 {
		t.Fatal("右下が明るい陰（光は左上）を見逃した")
	}
}

// wrap で端を回した散らしは、3×3 に並べて見るので orphan にならない。
func TestWrapScatterNoOrphan(t *testing.T) {
	_, res := mustDraw(t, `{"s": {"size": [8, 8], "ramp": "r", "parts": [{"id": "g", "shape": {"rect": [0, 0, 8, 8]}, "ops": [{"fill": {"color": "mid"}}, {"scatter_clusters": {"colors": ["shade"], "cell": 4, "seed": 1, "wrap": true}}]}],
	  "frames": {"f": {}}}}`)
	for _, v := range res.Violations {
		if v.Rule == "orphan" {
			t.Fatalf("回り込んだ塊が orphan になった: %s", v)
		}
	}
}

// roles の誤りは書いた順に並ぶ（素の map を回して毎回並びが変わっていた）。
func TestRolesErrorOrder(t *testing.T) {
	body := `{"s": {"size": [4, 4], "ramp": "r", "roles": {"legF": 1, "head": "nope", "zzz": "p"},
	  "parts": [{"id": "p", "shape": {"rect": [0, 0, 1, 1]}, "ops": [{"fill": {"color": "mid"}}]}], "frames": {"f": {}}}}`
	_, _, first := drawSpec(t, body)
	for i := 0; i < 20; i++ {
		if _, _, err := drawSpec(t, body); err == nil || first == nil || err.Error() != first.Error() {
			t.Fatalf("誤りの並びが変わった:\n%v\n%v", first, err)
		}
	}
	if !strings.Contains(first.Error(), "文字列で書く") {
		t.Errorf("値が文字列でない時の文言: %v", first)
	}
}
