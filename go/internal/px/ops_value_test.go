package px

// 明るさの構造の op（band_shift・cast_shadow）・shade_parts の照り返し・地の色の検査の例。
// 色は 1 字 = 1 色キー（a < b < c < d の灰の 4 段）、'.' は透明。

import (
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// 帯ごとに 1 段ずつ: 上の帯（y の場で明るい側）は模様の色がランプで 1 段上がる。
func TestBandShiftPixelRaisesUpperBand(t *testing.T) {
	g := gridOf("bbbb", "bbbb", "bbbb", "bbbb")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"band_shift": {"bands": 2, "field": "y"}}`)
	expectRows(t, g, "cccc", "cccc", "bbbb", "bbbb")
}

// 模様の色は全部同じだけずれる: 暗い帯の先の色（c）が、明るい帯では胴の色の位置に来て、先は次の段（d）になる。
func TestBandShiftMovesWholeRampOneStep(t *testing.T) {
	g := gridOf("bcbc", "bcbc", "bcbc", "bcbc")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"band_shift": {"bands": 2, "field": "y"}}`)
	expectRows(t, g, "cdcd", "cdcd", "bcbc", "bcbc")
}

// by: blob は塊ごとに 1 つの帯（帯の境目が模様の形に沿う）。背の高い塊は重心では暗い帯。
func TestBandShiftBlobFollowsPattern(t *testing.T) {
	g := gridOf("b.b", "b.b", "b..", "b..", "b..", "b..")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"band_shift": {"bands": 2, "field": "y", "by": "blob"}}`)
	expectRows(t, g, "b.c", "b.c", "b..", "b..", "b..", "b..")
}

// sample: top は塊の一番上で帯を読む（暗い帯の中の背の高い葉に、先から光が当たって帯を破る）。
func TestBandShiftTopSampleBreaksBand(t *testing.T) {
	g := gridOf("b.b", "b.b", "b..", "b..", "b..", "b..")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"band_shift": {"bands": 2, "field": "y", "by": "blob", "sample": "top"}}`)
	expectRows(t, g, "c.c", "c.c", "c..", "c..", "c..", "c..")
}

// keep の色はずらさない・ランプの端で止まる。
func TestBandShiftKeepsAndClamps(t *testing.T) {
	g := gridOf("adda", "adda", "abba", "abba")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"band_shift": {"bands": 2, "field": "y", "keep": ["a"]}}`)
	expectRows(t, g, "adda", "adda", "abba", "abba")
}

// 光の範囲（center・r）の中だけ色を上げる。範囲の外の帯 0 はそのまま。
func TestBandShiftLightRange(t *testing.T) {
	g := gridOf("bbbbbbb", "bbbbbbb", "bbbbbbb")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"band_shift": {"bands": 2, "center": [3.5, 1.5], "r": 2.5}}`)
	expectRows(t, g, "bbbcbbb", "bbcccbb", "bbbcbbb")
}

// 落ち影は光と反対（右下）へ倒れ、接地の所はさらに暗い。物の上と影の外は触らない。
func TestCastShadowFallsAwayFromLightAndContactIsDarkest(t *testing.T) {
	g := gridOf(
		".dd.....",
		".dd.....",
		"cddccccc",
		"cddccccc",
		"cccccccc",
		"cccccccc")
	obj := maskOf(".##.....", ".##.....", ".##.....", ".##.....", "........", "........")
	c := testCtx(g, opaqueOf(g))
	c.parts["obj"] = &partState{Part: &part{ID: "obj"}, shape: obj, written: obj}
	applyOp(t, c, `{"cast_shadow": {"of": "obj", "contact": 1}}`)
	for _, w := range []struct {
		x, y int
		want pxlib.Key
		why  string
	}{
		{3, 4, "a", "落ち影 + 接地"},
		{4, 4, "b", "落ち影だけ"},
		{0, 4, "b", "接地だけ"},
		{1, 1, "d", "物の上"},
		{7, 2, "c", "影の外"},
	} {
		if got := g.At(w.x, w.y); got != w.want {
			t.Errorf("(%d,%d) %s: got %s want %s", w.x, w.y, w.why, got, w.want)
		}
	}
}

// shadeBall は 24×24 の球を shade_parts で描いた行（extra は shade_parts の引数に足す JSON）。
func shadeBall(t *testing.T, extra string) ([]string, map[string]string) {
	t.Helper()
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [24, 24], "ramp": "r",
    "parts": [{"id": "ball", "shape": {"disk": [12, 12, 10]}, "ops": [{"shade_parts": {"thick": 8`+extra+`}}]}],
    "frames": {"idle": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	return res.Frames[0].Rows, res.Legend
}

// 照り返し: 影の下側（地面の側）が 1 段明るくなり、境目の近くの一番暗い影（core shadow）は残る。既定は付けない。
func TestShadePartsBounceLiftsGroundSideOfShadow(t *testing.T) {
	count := func(rows []string, legend map[string]string, key string) int {
		n := 0
		for y, r := range rows {
			for x, ch := range strings.Split(r, "") {
				// 外周（墨・縁）を除いた内側だけを数える
				if y < 3 || y > 20 || x < 3 || x > 20 {
					continue
				}
				if legend[ch] == key {
					n++
				}
			}
		}
		return n
	}
	plain, lg := shadeBall(t, "")
	same, _ := shadeBall(t, `, "bounce": 0`)
	if strings.Join(plain, "/") != strings.Join(same, "/") {
		t.Fatal("bounce: 0 で絵が変わる（既定の見た目を変えない）")
	}
	lit, lg2 := shadeBall(t, `, "bounce": 0.5`)
	before, after := count(plain, lg, "c0"), count(lit, lg2, "c0")
	if after >= before {
		t.Errorf("一番暗い段が減らない: %d → %d", before, after)
	}
	if after == 0 {
		t.Error("境目の近くの一番暗い影まで消えた")
	}
}

// groundRun は 8×8 の絵を地 ground で描いて、ground-contrast の規則 rule の違反の数を返す。
func groundRun(t *testing.T, ground, rule string) int {
	t.Helper()
	dir := writeSpec(t, specHead+`
  "light": {"ground": "`+ground+`"},
  "sprites": {"s": {"size": [8, 8], "ramp": "r",
    "parts": [{"id": "box", "shape": {"rect": [1, 1, 6, 6]}, "ops": [{"directional": {}}]}],
    "frames": {"idle": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, v := range res.Violations {
		if v.Check == checkGroundContrast && v.Rule == rule {
			n++
		}
	}
	return n
}

// 地は絵のハイライト（c3 = #e0e0e0）より明るくしない。
func TestGroundBrighterThanHighlight(t *testing.T) {
	if n := groundRun(t, "#f4f4f4", "highlight"); n != 1 {
		t.Errorf("ハイライトより明るい地: %d 件", n)
	}
	if n := groundRun(t, "#c0c0c0", "highlight"); n != 0 {
		t.Errorf("ハイライトより暗い地: %d 件", n)
	}
}

// 明るい地は彩度を低く（暗い地の彩度は問わない）。
func TestBrightGroundChroma(t *testing.T) {
	if n := groundRun(t, "#d8e890", "chroma"); n != 1 {
		t.Errorf("明るく彩度の高い地: %d 件", n)
	}
	if n := groundRun(t, "#d0d4c8", "chroma"); n != 0 {
		t.Errorf("明るく彩度の低い地: %d 件", n)
	}
	if n := groundRun(t, "#304010", "chroma"); n != 0 {
		t.Errorf("暗い地: %d 件", n)
	}
}

// 部品ごとの範囲で回る ground-contrast（sel_out の後など）では、地の色の決まりを見ない（部品の一番明るい画素はハイライトではない）。
func TestGroundToneOnlyOnWholeFrame(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "light": {"ground": "#c0c0c0"},
  "sprites": {"s": {"size": [12, 8], "ramp": "r",
    "parts": [
      {"id": "dark", "shape": {"rect": [1, 1, 4, 4]}, "ops": [{"fill": {"color": "c1"}}, {"sel_out": {}}]},
      {"id": "lit", "shape": {"rect": [7, 1, 4, 4]}, "ops": [{"fill": {"color": "c3"}}]}],
    "frames": {"idle": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range res.Violations {
		if v.Check == checkGroundContrast && v.Rule == "highlight" {
			t.Errorf("絵の全体のハイライト（c3）より暗い地で出た: %s", v)
		}
	}
}
