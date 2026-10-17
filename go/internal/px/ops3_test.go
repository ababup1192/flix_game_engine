package px

// 段 3 の op と検査の例（px-techniques.md の 2 節と、見回り役が足した動き・仕上げの op）。
// どれも小さな入力と期待する出力。色は 1 字 = 1 色キー（a < b < c < d の灰の 4 段）、'.' は透明。

import (
	"fmt"
	"math"
	"encoding/json"
	"image/color"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/rounds"
)

var grayHex = map[pxlib.Key]string{"a": "#202020", "b": "#606060", "c": "#a0a0a0", "d": "#e0e0e0"}

var rampABCD = []pxlib.Key{"a", "b", "c", "d"}

func gridOf(rows ...string) *pxlib.Grid {
	legend := map[string]pxlib.Key{}
	for _, r := range rows {
		for _, ch := range r {
			if ch != '.' {
				legend[string(ch)] = pxlib.Key(string(ch))
			}
		}
	}
	g, _ := pxlib.GridFromRows(rows, legend)
	return g
}

func rowsOfGrid(g *pxlib.Grid) string {
	var out []string
	for y := 0; y < g.H; y++ {
		var b strings.Builder
		for x := 0; x < g.W; x++ {
			k := g.At(x, y)
			if k == pxlib.Clear {
				b.WriteByte('.')
			} else {
				b.WriteString(string(k))
			}
		}
		out = append(out, b.String())
	}
	return strings.Join(out, " / ")
}

// testCtx は格子 g の上で、塊 region を持つ部品 p を描いている途中の状態（光は左上）。
// 部品が書いた画素は region の中の不透明な画素とする。
func testCtx(g *pxlib.Grid, region pxlib.Mask) *ctx {
	written := pxlib.NewMask(g.W, g.H)
	for _, p := range region.Points() {
		written[p.Y][p.X] = g.At(p.X, p.Y) != pxlib.Clear
	}
	before := g.Clone()
	for _, p := range written.Points() {
		before.Put(p.X, p.Y, pxlib.Clear, pxlib.OpRef{})
	}
	ps := &partState{Part: &part{ID: "p"}, Ramp: rampABCD, shape: region, written: written, before: before}
	return &ctx{G: g, Spec: &specDoc{Light: lightSpec{Dir: [3]float64{-1, -1, 0.9}}, Ramps: map[string][]pxlib.Key{"r": rampABCD}},
		Part: ps, parts: map[string]*partState{"p": ps}, hexOf: grayHex, FrameCount: 1}
}

func opaqueOf(g *pxlib.Grid) pxlib.Mask { return g.Opaque() }

func applyOp(t *testing.T, c *ctx, js string) {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(js), &v); err != nil {
		t.Fatal(err)
	}
	call, err := parseOpCall(v, "t", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.apply(call); err != nil {
		t.Fatal(err)
	}
}

func expectRows(t *testing.T, g *pxlib.Grid, want ...string) {
	t.Helper()
	if got, w := rowsOfGrid(g), strings.Join(want, " / "); got != w {
		t.Errorf("got  %s\nwant %s", got, w)
	}
}

func pear36(t *testing.T) map[string]string {
	t.Helper()
	data, err := os.ReadFile("testdata/gate/art/internet_dungeon.colorgate.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Styles map[string]struct {
			Colors map[string]string `json:"colors"`
		} `json:"styles"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	return doc.Styles["day"].Colors
}

// --- 2 節の例 ---

func TestRampPickExamples(t *testing.T) {
	pal := pear36(t)
	opts := rampPickOpts{N: 4, At: 2, Step: 0.13, Shift: 30, MinGap: 0.05}
	for base, want := range map[string]string{
		"pearAsh":      "pearSlate pearGray pearAsh pearCloud",
		"pearLime":     "pearTeal pearJade pearLime pearLimeLight",
		"pearBlueDeep": "pearIndigoDeep pearIndigo pearBlueDeep pearSky",
	} {
		got, err := rampPick(pal, base, opts)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Join(got, " ") != want {
			t.Errorf("%s: got %v want %s", base, got, want)
		}
	}
	got, err := rampPick(pal, "pearCloud", opts)
	if err != nil {
		t.Fatal(err)
	}
	if got[3] != "pearWhite" {
		t.Errorf("pearCloud の明るい端: got %s want pearWhite（pearMint にならない）", got[3])
	}
}

func TestRampIndexBandExample(t *testing.T) {
	var got []int
	for i := 0; i <= 10; i++ {
		got = append(got, rampIndex(float64(i)/10, 0, 0, 2, 0.3))
	}
	if want := []int{0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1}; !equalInts(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func equalInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestDirectionalExample(t *testing.T) {
	f := directional(maskOf("###", "###", "###"), -1, -1)
	want := [3][3]float64{{1, .75, .5}, {.75, .5, .25}, {.5, .25, 0}}
	for y := 0; y < 3; y++ {
		for x := 0; x < 3; x++ {
			if f(x, y) != want[y][x] {
				t.Errorf("(%d,%d): got %v want %v", x, y, f(x, y), want[y][x])
			}
		}
	}
}

func TestSelOutExample(t *testing.T) {
	g := gridOf(".....", ".cbb.", ".cbb.", ".cbb.", ".....")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"sel_out": {}}`)
	expectRows(t, g, ".baa.", "bcbba", "bcbba", "bcbba", ".aaa.")
}

func TestGroundShadowExample(t *testing.T) {
	g := gridOf("ccccccc", "ccooocc", "ccooocc", "ccccccc", "ccccccc")
	obj := maskOf(".......", "..###..", "..###..", ".......", ".......")
	px := groundShadow(g, obj, []pxlib.Key{"a", "b", "c", "d"}, 2, 1)
	for p, k := range px {
		g.Put(p.X, p.Y, k, pxlib.OpRef{})
	}
	expectRows(t, g, "ccccccc", "ccooocc", "cbooobc", "cbbbbbc", "ccccccc")
}

func TestScatterClustersExample(t *testing.T) {
	m := maskOf("########", "########", "########", "########", "########", "########", "########", "########")
	px, n := scatterClusters(8, 8, m, []pxlib.Key{"x"}, "blob", 4, 1, 1, true)
	if n != 3 {
		t.Errorf("塊の数 %d（3 のはず）", n)
	}
	g := pxlib.NewGrid(8, 8)
	for p, k := range px {
		g.Put(p.X, p.Y, k, pxlib.OpRef{})
	}
	expectRows(t, g, "..x.....", "........", "x.......", "x.......", "x.......", "......x.", ".....xx.", ".xx.....")
}

func TestShadeMaskCastsShadow(t *testing.T) {
	g := gridOf("cccc", "cccc", "cccc", "cccc")
	c := testCtx(g, opaqueOf(g))
	c.parts["box"] = &partState{Part: &part{ID: "box"}, shape: maskOf("##..", "##..", "....", "....")}
	applyOp(t, c, `{"shade_mask": {"of": "box"}}`)
	expectRows(t, g, "cccc", "ccbc", "cbbc", "cccc")
}

func TestDitherPairMixesHalf(t *testing.T) {
	hex := map[pxlib.Key]string{"k": "#000000", "w": "#ffffff"}
	a, b, r, err := ditherPair("#bcbcbc", []pxlib.Key{"k", "w"}, hex)
	if err != nil || a != "k" || b != "w" || r != 0.5 {
		t.Fatalf("got %s %s %v %v（k・w・0.5 のはず）", a, b, r, err)
	}
	a, b, r, _ = ditherPair("#ffffff", []pxlib.Key{"k", "w"}, hex)
	if a != "w" || b != "w" {
		t.Errorf("色票にある色は混ぜない: got %s %s %v", a, b, r)
	}
}

func TestContrastFeedsValueSep(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [8, 8], "ramp": "r",
    "parts": [
      {"id": "bg", "shape": {"rect": [0, 0, 8, 8]}, "ops": [{"fill": {"color": "shade"}}]},
      {"id": "hero", "shape": {"rect": [2, 2, 4, 4]}, "ops": [{"fill": {"color": "mid"}}, {"contrast": {"against": "bg", "min": 0.5}}]}],
    "frames": {"idle": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range res.Violations {
		if v.Check == checkValueSep && strings.Contains(v.Msg, "hero と bg") && v.Fix != "" {
			return
		}
	}
	t.Fatalf("value-sep が出ない: %v", res.Violations)
}

// --- 検査 ---

func techRules(t *testing.T) *checkCtx {
	t.Helper()
	r, err := loadRules(engineRoot)
	if err != nil {
		t.Fatal(err)
	}
	return &checkCtx{Rules: r, HexOf: grayHex, Light: [3]float64{-1, -1, 0.9}, Ramps: map[string][]pxlib.Key{}}
}

func countCheck(g *pxlib.Grid, cc *checkCtx, name checkName) int {
	return len(checks[name].Run(g, cc))
}

func TestPillowCheck(t *testing.T) {
	cc := techRules(t)
	pillow := gridOf("aaaaaa", "abbbba", "abddba", "abddba", "abbbba", "aaaaaa")
	if countCheck(pillow, cc, checkPillow) != 1 {
		t.Error("縁を一様に暗くした陰で pillow が出ない")
	}
	lit := gridOf("aaaaaa", "addcca", "adccba", "accbba", "acbbba", "aaaaaa")
	if n := countCheck(lit, cc, checkPillow); n != 0 {
		t.Errorf("光の向きの陰で pillow が %d 件", n)
	}
}

func TestLightDirCheck(t *testing.T) {
	cc := techRules(t)
	good := gridOf("ddcc", "ddcc", "ccbb", "ccbb")
	bad := gridOf("bbcc", "bbcc", "ccdd", "ccdd")
	if countCheck(good, cc, checkLightDir) != 0 || countCheck(bad, cc, checkLightDir) != 1 {
		t.Error("light-dir: 左上が明るい絵は通し、右下が明るい絵を止める")
	}
}

func TestBlackOutlineCheck(t *testing.T) {
	cc := techRules(t)
	if countCheck(gridOf("aaaa", "acca", "acca", "aaaa"), cc, checkBlackOutline) != 1 {
		t.Error("1 色の最暗の縁で black-outline が出ない")
	}
	if countCheck(gridOf("bbba", "bcca", "bcca", "aaaa"), cc, checkBlackOutline) != 0 {
		t.Error("部品ごとの色の縁で black-outline が出た")
	}
}

func TestRampOrderCheck(t *testing.T) {
	cc := techRules(t)
	cc.Ramps = map[string][]pxlib.Key{"ok": rampABCD, "bad": {"a", "c", "b"}}
	vs := checks[checkRampOrder].Run(nil, cc)
	if len(vs) != 1 || !strings.Contains(vs[0].Msg, "ランプ bad") {
		t.Fatalf("got %v", vs)
	}
}

func TestSeamCheck(t *testing.T) {
	cc := techRules(t)
	ramp := gridOf("aabbccdd", "aabbccdd", "aabbccdd", "aabbccdd") // 並べると d→a で段が切れる
	flat := gridOf("abab", "baba", "abab", "baba")
	grout := gridOf("addddadd", "addddadd", "addddadd", "addddadd") // 目地 a は内側にもある（模様の一部）
	if countCheck(ramp, cc, checkSeam) != 1 || countCheck(flat, cc, checkSeam) != 0 || countCheck(grout, cc, checkSeam) != 0 {
		t.Error("seam: 端で明るさの切れるタイルを止め、つながるタイルと目地のタイルは通す")
	}
}

func TestStyleCheck(t *testing.T) {
	cc := techRules(t)
	cc.Style = &pxStyle{Label: "4 色", Colors: map[string]string{"a": "#202020", "b": "#606060"}, MaxColors: 2, Tile: [2]int{2, 2}, MaxTileColors: 1}
	vs := checks[checkStyle].Run(gridOf("abc."), cc)
	var msgs []string
	for _, v := range vs {
		msgs = append(msgs, v.Msg)
	}
	all := strings.Join(msgs, "\n")
	for _, want := range []string{"色 c", "3 色使っている", "(0,0) に 2 色"} {
		if !strings.Contains(all, want) {
			t.Errorf("%q が無い:\n%s", want, all)
		}
	}
}

// SNES（5 bit）と PC-98（4 bit）の色を、よく使われる 3 つの広げ方の全段で通し、段の間の値は止める。
func TestStyleChannelLevelsAllSteps(t *testing.T) {
	for _, tc := range []struct {
		levels, bits int
	}{{32, 5}, {16, 4}} {
		st := &pxStyle{ChannelLevels: tc.levels}
		ok := map[int]bool{}
		for k := 0; k < tc.levels; k++ {
			shift := k << (8 - tc.bits)
			rep := shift | shift>>tc.bits
			if tc.bits == 4 {
				rep = k * 17
			}
			for _, v := range []int{shift, rep, int(math.Round(float64(k) * 255 / float64(tc.levels-1)))} {
				ok[v] = true
				hex := fmt.Sprintf("#%02x%02x%02x", v, v, v)
				if !st.allowsHex(hex) {
					t.Errorf("%d 段: %s（k=%d）を止めた", tc.levels, hex, k)
				}
			}
		}
		for v := 0; v < 256; v++ {
			if !ok[v] && st.allowsHex(fmt.Sprintf("#%02x0000", v)) {
				t.Errorf("%d 段: 段の間の値 %d を通した", tc.levels, v)
			}
		}
	}
}

// style を書いた spec は、その機種の色キーで描けて、外の色は門で止まる。
func TestStyleInBuild(t *testing.T) {
	head := `{"version": 2, "target": "atelier/t.sprite.json", "palette": "assets/t.palette.json", "style": "gb4",`
	ok := writeSpec(t, head+`
  "ramps": {"g": ["gb0", "gb1", "gb3"]},
  "sprites": {"s": {"size": [8, 8], "ramp": "g", "parts": [{"id": "a", "shape": {"rect": [2, 2, 4, 4]}, "ops": [{"directional": {}}]}], "frames": {"idle": {}}}}}`)
	res, err := build(ok, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil || !res.Wrote {
		t.Fatalf("gb4 の色で書けない: %v %v", err, res)
	}
	bad := writeSpec(t, head+`
  "ramps": {"r": ["c0", "c1", "c2", "c3"]},
  "sprites": {"s": {"size": [8, 8], "ramp": "r", "parts": [{"id": "a", "shape": {"rect": [2, 2, 4, 4]}, "ops": [{"fill": {"color": "mid"}}]}], "frames": {"idle": {}}}}}`)
	res, err = build(bad, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	if res.Wrote || res.Count().Gate == 0 {
		t.Fatal("gb4 の外の色で書けてしまった")
	}
}

// 違反は直し方（fix）を持つ。
func TestViolationsCarryFix(t *testing.T) {
	cc := techRules(t)
	vs, err := runCheck(checkRef{Check: checkPillow}, gridOf("aaaaaa", "abbbba", "abddba", "abddba", "abbbba", "aaaaaa"), cc)
	if err != nil || len(vs) != 1 || !strings.Contains(vs[0].Fix, "directional") {
		t.Fatalf("got %v %v", vs, err)
	}
	if !strings.Contains(vs[0].String(), "→ 直し:") {
		t.Errorf("1 行の字面に直し方が無い: %s", vs[0])
	}
	for _, c := range allChecks() {
		if c.Fix == "" && c.Name != checkSprite && c.Name != checkGate {
			t.Errorf("%s: Fix が空", c.Name)
		}
	}
}

// --- 仕上げの op ---

func TestRimLight(t *testing.T) {
	g := gridOf("bbb", "bbb", "bbb")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"rim_light": {}}`)
	expectRows(t, g, "bbb", "bbc", "bcc")
}

func TestAACorners(t *testing.T) {
	// 外が透明: 縁の墨 a と奥の c の中間 b を置く（2px の段の角だけ・45° の (4,1) には置かない）
	g := gridOf("ca...", "ccaa.", "ccccc")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"aa_corners": {}}`)
	expectRows(t, g, "cab..", "ccaa.", "ccccc")
}

func TestAACornersAgainstOtherPart(t *testing.T) {
	// 外が別の部品の色 d: against any なら b と d の中間 c、既定（clear）なら置かない
	for against, want := range map[string]string{"any": "bbcdd", "clear": "bbddd"} {
		g := gridOf("bbddd", "bbbbd", "bbbbb")
		c := testCtx(g, maskOf("##...", "####.", "#####"))
		applyOp(t, c, `{"aa_corners": {"against": "`+against+`"}}`)
		expectRows(t, g, want, "bbbbd", "bbbbb")
	}
}

func TestDepthFade(t *testing.T) {
	for depth, want := range map[string]string{"0": "a", "0.5": "b", "1": "d"} {
		g := gridOf("a")
		c := testCtx(g, opaqueOf(g))
		applyOp(t, c, `{"depth_fade": {"depth": `+depth+`, "toward": "d"}}`)
		expectRows(t, g, want)
	}
}

func TestMirror(t *testing.T) {
	g := gridOf("ab...")
	c := testCtx(g, maskOf("#####"))
	applyOp(t, c, `{"mirror": {}}`)
	expectRows(t, g, "ab.ba")
}

func TestGlint(t *testing.T) {
	g := gridOf("cccccc", "cccccc", "cccccc", "cccccc", "cccccc", "cccccc")
	c := testCtx(g, opaqueOf(g))
	applyOp(t, c, `{"glint": {"size": 2}}`)
	expectRows(t, g, "cccccc", "cddccc", "cccccc", "cccccc", "cccccc", "cccccc")
}

// --- 動きの op ---

func animCtx(g *pxlib.Grid, i, n int) *ctx {
	c := testCtx(g, opaqueOf(g))
	c.FrameIndex, c.FrameCount = i, n
	return c
}

func TestSway(t *testing.T) {
	g := gridOf("..c..", "..c..", "..c..", "..c..")
	applyOp(t, animCtx(g, 1, 4), `{"sway": {"amp": 2}}`)
	expectRows(t, g, "....c", "...c.", "...c.", "..c..")
	g = gridOf("..c..", "..c..")
	applyOp(t, animCtx(g, 0, 4), `{"sway": {"amp": 2}}`)
	expectRows(t, g, "..c..", "..c..") // 最初のコマは元の絵
}

func TestBob(t *testing.T) {
	want := []string{"... / .c. / ...", ".c. / ... / ...", "... / .c. / ...", "... / ... / .c."}
	for i := 0; i < 4; i++ {
		g := gridOf("...", ".c.", "...")
		applyOp(t, animCtx(g, i, 4), `{"bob": {"amp": 1}}`)
		if got := rowsOfGrid(g); got != want[i] {
			t.Errorf("コマ %d: got %s want %s", i, got, want[i])
		}
	}
}

func TestSquash(t *testing.T) {
	g := gridOf("........", "........", "..cccc..", "..cccc..", "..cccc..", "..cccc..")
	applyOp(t, animCtx(g, 1, 4), `{"squash": {"amount": 0.5}}`)
	expectRows(t, g, "........", "........", "........", "........", ".cccccc.", ".cccccc.")
}

func TestPaletteCycle(t *testing.T) {
	g := gridOf("abc")
	applyOp(t, animCtx(g, 1, 3), `{"palette_cycle": {"colors": ["a", "b", "c"]}}`)
	expectRows(t, g, "bca")
}

func TestRotSpriteKeepsColors(t *testing.T) {
	src := map[pxlib.Pt]pxlib.Key{{X: 3, Y: 1}: "a", {X: 3, Y: 2}: "a", {X: 3, Y: 3}: "b", {X: 3, Y: 4}: "b"}
	out := rotSprite(src, 90, [2]float64{3, 1}, 6, 6)
	g := pxlib.NewGrid(6, 6)
	for p, k := range out {
		g.Put(p.X, p.Y, k, pxlib.OpRef{})
	}
	expectRows(t, g, "......", "bbaa..", "......", "......", "......", "......")
	out = rotSprite(src, 30, [2]float64{3, 1}, 8, 8)
	for _, k := range out {
		if k != "a" && k != "b" {
			t.Fatalf("回すと色 %s が湧いた", k)
		}
	}
}

// 歩きの姿勢: pose から部品の回転が入り、passing は元の絵のまま。コマ列には anim の検査が自動でかかる。
func TestPoseFrames(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [12, 12], "ramp": "r", "roles": {"legF": "leg"},
    "parts": [{"id": "leg", "shape": {"rect": [5, 3, 1, 6]}, "ops": [{"fill": {"color": "mid"}}]}],
    "frames": {"a": {"pose": "passing"}, "b": {"pose": "contact"}, "c": {"pose": "contact", "parts": {"leg": {"rotate": 0}}}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	rows := map[string]string{}
	for _, f := range res.Frames {
		rows[f.Name] = strings.Join(f.Rows, "/")
	}
	if rows["a"] == rows["b"] || rows["a"] != rows["c"] {
		t.Errorf("contact だけ脚が回る（parts の rotate: 0 で打ち消せる）:\n%s\n%s\n%s", rows["a"], rows["b"], rows["c"])
	}
	if !res.Frames[0].Anim {
		t.Error("pose を使うスプライトがコマ列として扱われない")
	}
	bad := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [8, 8], "ramp": "r", "parts": [{"id": "leg", "ops": []}],
    "frames": {"a": {"pose": "jump"}, "b": {"pose": "down", "parts": {"arm": {}}}}}}}`)
	_, err = loadSpec(filepath.Join(bad, "t.pxsrc.json"))
	if err == nil || !strings.Contains(err.Error(), "知らない姿勢 \"jump\"") || !strings.Contains(err.Error(), "frames.b.parts.arm") {
		t.Fatalf("got %v", err)
	}
}

// 動きの op を使うスプライトには anim の検査がかかる（揺れすぎは bob で止まる）。
func TestAnimCheckRunsOnAnimatedSprite(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [8, 12], "ramp": "r",
    "parts": [{"id": "b", "shape": {"rect": [2, 4, 4, 4]}, "ops": [{"fill": {"color": "mid"}}, {"bob": {"amp": 3}}]}],
    "frames": {"f0": {}, "f1": {}, "f2": {}, "f3": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range res.Violations {
		if v.Check == checkAnim && strings.Contains(v.Msg, "上下動") {
			return
		}
	}
	t.Fatalf("anim の bob が出ない: %v", res.Violations)
}

// variants: seed ごとにコマを書き分け、同じ seed なら同じ絵。
func TestVariantsSeeds(t *testing.T) {
	body := specHead + `
  "sprites": {"s": {"size": [12, 12], "ramp": "r", "variants": {"seeds": [1, 2]},
    "parts": [{"id": "g", "shape": {"rect": [0, 0, 12, 12]}, "ops": [{"fill": {"color": "mid"}}, {"scatter_clusters": {"colors": ["ink"], "cell": 3}}]}],
    "frames": {"idle": {}}}}}`
	dir := writeSpec(t, body)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Frames) != 2 || res.Frames[0].Name != "idle_v1" || res.Frames[1].Name != "idle_v2" {
		t.Fatalf("got %v", res.Frames)
	}
	if strings.Join(res.Frames[0].Rows, "") == strings.Join(res.Frames[1].Rows, "") {
		t.Error("seed を変えても同じ絵")
	}
	again, _ := build(writeSpec(t, body), "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if strings.Join(again.Frames[0].Rows, "") != strings.Join(res.Frames[0].Rows, "") {
		t.Error("同じ seed で絵が変わった")
	}
}

// 材質は既存の op の並びに開くだけ（同じ op を手で書いた絵とバイトで同じ）。
func TestMaterialExpandsToOps(t *testing.T) {
	draw := func(part string) string {
		dir := writeSpec(t, specHead+`
  "light": {"gloss": "c3"},
  "sprites": {"s": {"size": [10, 10], "ramp": "r", "parts": [`+part+`], "frames": {"idle": {}}}}}`)
		res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
		if err != nil {
			t.Fatal(err)
		}
		return strings.Join(res.Frames[0].Rows, "/")
	}
	a := draw(`{"id": "m", "shape": {"rect": [2, 2, 6, 6]}, "material": "metal"}`)
	b := draw(`{"id": "m", "shape": {"rect": [2, 2, 6, 6]}, "ops": [{"gradient_fill": {"field": "light", "band": 0}}, {"glint": {"size": 2}}, {"sel_out": {}}]}`)
	if a != b {
		t.Errorf("metal と手書きの op が違う:\n%s\n%s", a, b)
	}
	for _, m := range allMaterials() {
		if len(m.Params) > 3 || m.Summary == "" || m.Technique == "" || m.Finish == "" {
			t.Errorf("材質 %s: 引数は 3 個まで・説明を埋める", m.Name)
		}
		draw(`{"id": "m", "shape": {"rect": [1, 1, 8, 8]}, "material": "` + m.Name + `"}`)
	}
}

// tile_preview は 3×3 の見本を書き、継ぎ目を検査する。
func TestTilePreview(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"t": {"size": [8, 8], "ramp": "r",
    "parts": [{"id": "g", "shape": {"rect": [0, 0, 8, 8]}, "ops": [{"gradient_fill": {"field": "x", "band": 0}}]}],
    "post": [{"tile_preview": {}}],
    "frames": {"idle": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, Sheet: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(res.Sheet), "t.tile.png")); err != nil {
		t.Error("3×3 の見本が無い")
	}
	for _, v := range res.Violations {
		if v.Check == checkSeam {
			return
		}
	}
	t.Error("左から右へ明るくなるタイルで seam が出ない")
}

// --- 周回 ---

func TestRoundsSnapRestoreDiff(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [4, 4], "ramp": "r", "parts": [{"id": "a", "shape": {"rect": [1, 1, 2, 2]}, "ops": [{"fill": {"color": "mid"}}]}], "frames": {"idle": {}}}}}`)
	spec := filepath.Join(dir, "t.pxsrc.json")
	orig, _ := os.ReadFile(spec)
	run := func(args ...string) (int, string) {
		var out, errOut strings.Builder
		code := Run(&out, &errOut, engineRoot, dir, args, false)
		return code, out.String() + errOut.String()
	}
	for i := 1; i <= 5; i++ {
		if i == 2 {
			if err := os.WriteFile(spec, []byte(strings.Replace(string(orig), `"mid"`, `"light"`, 1)), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		code, msg := run("snap", "t.pxsrc.json")
		if code != 0 {
			t.Fatalf("r%d: %s", i, msg)
		}
		if i == 2 && !(strings.Contains(msg, "①") && strings.Contains(msg, "②") && strings.Contains(msg, "③")) {
			t.Errorf("r2 で 3 つを聞かない: %s", msg)
		}
	}
	// 周の上限は fge rounds の rounds.json の 1 か所（px.json には持たない）
	if code, msg := run("snap", "t.pxsrc.json"); code != 1 || !strings.Contains(msg, "5 周を超える") {
		t.Fatalf("6 周目が通った: %d %s", code, msg)
	}
	if code, msg := run("restore", "t.pxsrc.json", "r1"); code != 2 {
		t.Fatalf("px restore は消した（fge rounds restore に 1 本化）: %d %s", code, msg)
	}
	var o, e strings.Builder
	if code, err := rounds.Run(&o, &e, engineRoot, dir, []string{"restore", "t", "r1", "t.pxsrc.json"}); code != 0 || err != nil {
		t.Fatal(code, err, e.String())
	}
	if now, _ := os.ReadFile(spec); string(now) != string(orig) {
		t.Error("restore で r1 の spec に戻らない")
	}
	code, msg := run("diff", "t.pxsrc.json", "r1", "r2")
	if code != 0 || !strings.Contains(msg, "変わったコマ 1") {
		t.Fatalf("diff: %d %s", code, msg)
	}
	if code, msg := run("snap", "t.pxsrc.json", "--new"); code != 0 || !strings.Contains(msg, "退けた") {
		t.Fatalf("--new: %d %s", code, msg)
	}
}

// --- 文書 ---

func TestQuickTableFitsAndNamesOps(t *testing.T) {
	if len(quickRows) > 15 {
		t.Errorf("早見表の上の段は 15 行まで（今 %d 行）", len(quickRows))
	}
	for _, r := range quickRows {
		for _, name := range r.Ops {
			if _, ok := lookupOp(name); !ok && name != "material" {
				t.Errorf("%s: 知らない op %s", r.What, name)
			}
		}
	}
	for _, name := range []string{"ramp_pick", "shade_mask", "directional", "gradient_fill", "sel_out", "dither_pair", "ground_shadow",
		"scatter_clusters", "contrast", "sway", "bob", "squash", "palette_cycle", "rim_light", "aa_corners", "depth_fade", "mirror", "tile_preview", "glint"} {
		if _, ok := lookupOp(name); !ok {
			t.Errorf("段 3 の op %s が無い", name)
		}
	}
}

func TestOnionTintsNeighbours(t *testing.T) {
	ground := pxColor(0, 0, 0)
	cur := [][]pxColorT{{pxColor(255, 255, 255), {}}}
	prev := [][]pxColorT{{{}, pxColor(255, 255, 255)}}
	out := pxlib.Onion(cur, prev, nil, ground)
	if out[0][0] != cur[0][0] || out[0][1] == ground {
		t.Errorf("今のコマは上に・前のコマは薄く重なる: %v", out)
	}
}

type pxColorT = color.RGBA

func pxColor(r, g, b uint8) color.RGBA { return color.RGBA{r, g, b, 0xff} }
