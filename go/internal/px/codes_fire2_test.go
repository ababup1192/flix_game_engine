package px

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// 段 2 の検査の外れる例・合う例（数は bin/lint-rules/px.json の閾値から）。
func TestTechniqueChecksFireAndPass(t *testing.T) {
	rules, err := loadRules(engineRoot)
	if err != nil {
		t.Fatal(err)
	}
	gray := func(n int) (map[pxlib.Key]string, []pxlib.Key) {
		hex := map[pxlib.Key]string{}
		var ks []pxlib.Key
		for i := 0; i < n; i++ {
			k := pxlib.Key(string(rune('a' + i)))
			v := 0x20 + i*(0xd0/max(1, n-1))
			hex[k] = "#" + hex2(v) + hex2(v) + hex2(v)
			ks = append(ks, k)
		}
		return hex, ks
	}
	codes := func(vs []violation) map[string]bool {
		m := map[string]bool{}
		for _, v := range vs {
			m[v.code()] = true
		}
		return m
	}
	// 6 色の 16×16: 最明色で全面を塗る（外れ）・最明色を角 1px だけ（合う）
	hex, ks := gray(6)
	c := &checkCtx{Rules: rules, HexOf: hex}
	bad := pxlib.NewGrid(16, 16)
	good := pxlib.NewGrid(16, 16)
	seed := uint32(7)
	for y := 0; y < 16; y++ {
		for x := 0; x < 16; x++ {
			seed = seed*1103515245 + 12345
			bad.Put(x, y, ks[5], pxlib.OpRef{Part: "p"})
			good.Put(x, y, ks[(seed>>16)%5], pxlib.OpRef{Part: "p"})
		}
	}
	for i := 0; i < 5; i++ {
		bad.Put(i, 0, ks[i], pxlib.OpRef{Part: "p"})
	}
	good.Put(0, 0, ks[5], pxlib.OpRef{Part: "p"})
	got := codes(checks[checkHighlightReserve].Run(bad, c))
	if !got["px.highlight-reserve.area"] || !got["px.highlight-reserve.inside"] {
		t.Errorf("最明色の全面塗りが外れない: %v", got)
	}
	for _, v := range checks[checkHighlightReserve].Run(bad, c) {
		seenProbe(v)
	}
	if vs := checks[checkHighlightReserve].Run(good, c); len(vs) != 0 {
		t.Errorf("角 1px の最明色が外れた: %v", vs)
	}
	// 明暗が細かく散る（市松）と大きな塊が覆う割合が足りない
	vb := checks[checkValueBlobs].Run(good, c)
	if !codes(vb)["px.value-blobs.cover"] {
		t.Errorf("市松が value-blobs.cover に当たらない: %v", vb)
	}
	for _, v := range vb {
		seenProbe(v)
	}
	// ランプの彩度の山が端にある（暗い段が一番鮮やか）
	c2 := &checkCtx{Rules: rules, HexOf: map[pxlib.Key]string{"r0": "#a00000", "r1": "#905050", "r2": "#a08080", "r3": "#c0b0b0", "r4": "#e8e0e0"},
		Ramps: map[string][]pxlib.Key{"r": {"r0", "r1", "r2", "r3", "r4"}}}
	rc := checks[checkRampChroma].Run(nil, c2)
	if !codes(rc)["px.ramp-chroma.peak"] {
		t.Errorf("端の彩度の山が当たらない: %v", rc)
	}
	for _, v := range rc {
		seenProbe(v)
	}
	// 明るく鮮やかな地
	c3 := &checkCtx{Rules: rules, HexOf: hex, Ground: "#ffe000"}
	gc := groundExtraViolations(good, c3)
	if !codes(gc)["px.ground-contrast.chroma"] {
		t.Errorf("明るく鮮やかな地が当たらない: %v", gc)
	}
	for _, v := range gc {
		seenProbe(v)
	}
	// 変種の縁が元と違う
	a, b := pxlib.NewGrid(8, 8), pxlib.NewGrid(8, 8)
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			a.Put(x, y, ks[1], pxlib.OpRef{})
			b.Put(x, y, ks[1], pxlib.OpRef{})
		}
	}
	b.Put(0, 3, ks[2], pxlib.OpRef{})
	tv := tileVariantViolations([]string{"f_v0", "f_v1"}, []*pxlib.Grid{a, b}, rules.TileVariantEdge)
	if len(tv) != 1 {
		t.Errorf("変種の縁の違いが当たらない: %v", tv)
	}
	for _, v := range tv {
		seenProbe(v)
	}
	b.Put(0, 3, ks[1], pxlib.OpRef{})
	b.Put(4, 4, ks[2], pxlib.OpRef{})
	if tv := tileVariantViolations([]string{"f_v0", "f_v1"}, []*pxlib.Grid{a, b}, rules.TileVariantEdge); len(tv) != 0 {
		t.Errorf("中央だけ変えた変種が外れた: %v", tv)
	}
	// 曲線の中の長い直線（上の輪郭の段を 1-1-12-1-1 に。40px の絵では 7px まで）
	runs := []int{1, 1, 12, 1, 1}
	big := pxlib.NewGrid(40, 40)
	x0 := 0
	for i, n := range runs {
		for k := 0; k < n; k++ {
			for y := 20 - i; y < 40; y++ {
				big.Put(x0, y, ks[2], pxlib.OpRef{Part: "p"})
			}
			x0++
		}
	}
	fr, err := runCheck(checkRef{Check: checkFlatRun}, big, &checkCtx{Rules: rules, HexOf: hex})
	if err != nil {
		t.Fatal(err)
	}
	// 同じ長さの段が続く（1-2-2-2-1）
	rep := pxlib.NewGrid(20, 20)
	x0 = 0
	for i, n := range []int{1, 2, 2, 2, 1} {
		for k := 0; k < n; k++ {
			for y := 10 - i; y < 20; y++ {
				rep.Put(x0, y, ks[2], pxlib.OpRef{Part: "p"})
			}
			x0++
		}
	}
	fr2, err := runCheck(checkRef{Check: checkFlatRun}, rep, &checkCtx{Rules: rules, HexOf: hex})
	if err != nil {
		t.Fatal(err)
	}
	if !codes(fr2)["px.flat-run.repeat"] {
		t.Errorf("同じ長さの段の連続が当たらない: %v", codes(fr2))
	}
	if !codes(fr)["px.flat-run.straight"] {
		t.Errorf("曲線の中の長い直線が当たらない: %v", codes(fr))
	}
	if rules.ExemptPerFrameMax < 1 {
		t.Fatal("exemptPerFrameMax")
	}
	ex := exemptOveruse(map[[2]string]int{{"px.sprite.corner", "bevel_box"}: 100}, 2, rules.ExemptPerFrameMax)
	if len(ex) != 1 {
		t.Errorf("Exempt の使い過ぎが当たらない: %v", ex)
	}
	for _, v := range ex {
		seenProbe(v)
	}
}

// 宣言の検査: kind の書き忘れ・推せない・食い違い・material の書き忘れ・fidelity の不明と機種の方が細かい・lint-sprite の知らない名前。
func TestDeclChecks(t *testing.T) {
	dir := writeSpec(t, `{"version": 2, "target": "atelier/t.sprite.json", "palette": "assets/t.palette.json",
  "ramps": {"r": ["c0", "c1", "c2", "c3"]},
  "sprites": {
    "nokind": {"size": [40, 40], "ramp": "r", "parts": [{"id": "body", "shape": {"rect": [2, 2, 30, 30]}, "ops": [{"fill": {"color": "mid"}}]}], "frames": {"f": {}}},
    "mis": {"kind": "tile", "size": [8, 8], "ramp": "r", "parts": [{"id": "p", "shape": {"rect": [0, 0, 8, 8]}, "ops": [{"fill": {"color": "mid"}}]}], "frames": {"f": {}}},
    "pr": {"kind": "prop", "size": [40, 40], "ramp": "r", "parts": [{"id": "big", "shape": {"rect": [2, 2, 30, 30]}, "ops": [{"fill": {"color": "mid"}}]}], "frames": {"f": {}}}}}`)
	if err := os.WriteFile(filepath.Join(dir, "atelier.sprite.json"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, v := range res.Violations {
		got[v.code()] = true
	}
	for _, code := range []string{"px.decl.kind-missing", "px.decl.kind-unknown", "px.decl.kind-mismatch", "px.decl.material-missing", "px.decl.fidelity-unknown"} {
		if !got[code] {
			t.Errorf("%s が出ない: %v", code, got)
		}
	}
	data, _ := os.ReadFile(filepath.Join(dir, "atelier", "t.sprite.json"))
	if !strings.Contains(string(data), `"kind": "tile"`) {
		t.Error("宣言した kind を sprite.json に書いていない")
	}
	// 機種の方が門より細かい
	f := resolveFidelity(&colorGate{Default: "night", Styles: map[string]*gateStyle{"night": {Fidelity: ptrF(0.2)}}, Files: map[string]*gateFile{}}, "x.sprite.json", &pxStyle{name: "snes", Fidelity: ptrF(0.5)})
	if vs := fidelityDecl(f, "x"); len(vs) != 1 || vs[0].code() != "px.decl.fidelity-over" {
		t.Errorf("機種の方が細かいのが当たらない: %v", vs)
	} else {
		seenProbe(vs[0])
	}
	if f.Value != 0.2 || f.By != "門 night" {
		t.Errorf("門の画風の fidelity が先: %+v", f)
	}
	ls := lintSpriteDecl(map[string]any{"sprites": map[string]any{"s": map[string]any{"lint-sprite": "対象外(icon) — 記号"}}}, map[string]bool{"orphan": true})
	if len(ls) != 1 || !strings.Contains(ls[0].Fix, "kind") {
		t.Errorf("知らない規則名 icon が当たらない: %v", ls)
	} else {
		seenProbe(ls[0])
	}
}

func ptrF(v float64) *float64 { return &v }
