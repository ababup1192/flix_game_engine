package px

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/anim"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/sprite"
)

// 外れる例: テストのほかの所で出にくい code も、表の基準の向きと got・want つきで出る（TestMain が集めて確かめる）。
func TestRareCodesFire(t *testing.T) {
	rules, err := loadRules(engineRoot)
	if err != nil {
		t.Fatal(err)
	}
	spr, err := sprite.LoadRules(engineRoot)
	if err != nil {
		t.Fatal(err)
	}
	hex := map[pxlib.Key]string{"d": "#202020", "m": "#606060", "l": "#e0e0e0", "x": "#123456"}
	fill := func(w, h int, k pxlib.Key, part string) *pxlib.Grid {
		g := pxlib.NewGrid(w, h)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				g.Put(x, y, k, pxlib.OpRef{Part: part, Op: "fill"})
			}
		}
		return g
	}
	want := func(name string, ref checkRef, g *pxlib.Grid, c *checkCtx, code string) {
		t.Helper()
		vs, err := runCheck(ref, g, c)
		if err != nil {
			t.Fatal(err)
		}
		for _, v := range vs {
			if v.code() == code {
				return
			}
		}
		t.Errorf("%s: %s が出ない（%v）", name, code, vs)
	}
	base := func() *checkCtx { return &checkCtx{Rules: rules, SpriteRules: spr, HexOf: hex} }

	// 外周が地と同じ明るさ
	c := base()
	c.Ground = "#606060"
	want("地に溶ける", checkRef{Check: checkGroundContrast}, fill(8, 8, "m", "p"), c, "px.ground-contrast")

	// 上と下の端だけが大きく違うタイル（左右は揃っている）
	// 上から下へ少しずつ明るくなるタイル（中の隣り合う行の差は小さく、下の端 → 上の端だけが大きく違う）
	c = base()
	c.HexOf = map[pxlib.Key]string{}
	g := pxlib.NewGrid(8, 8)
	for y := 0; y < 8; y++ {
		k := pxlib.Key(string(rune('0' + y)))
		v := 0x20 + y*0x18
		c.HexOf[k] = "#" + hex2(v) + hex2(v) + hex2(v)
		for x := 0; x < 8; x++ {
			g.Put(x, y, k, pxlib.OpRef{Part: "p"})
		}
	}
	want("上下の継ぎ目", checkRef{Check: checkSeam}, g, c, "px.seam.y")

	// 機種の大きさ・色数・升目ごとの色数
	c = base()
	c.Style = &pxStyle{Label: "t", MaxSize: [2]int{4, 4}, MaxColors: 2, Tile: [2]int{8, 8}, MaxTileColors: 2}
	g = fill(8, 8, "d", "p")
	g.Put(1, 1, "m", pxlib.OpRef{Part: "p"})
	g.Put(2, 2, "l", pxlib.OpRef{Part: "p"})
	for _, code := range []string{"px.style.size", "px.style.colors", "px.style.tile-colors"} {
		want("機種の縛り", checkRef{Check: checkStyle}, g, c, code)
	}

	// poly の辺の段の長さが 3 種類以上に散る（上の輪郭を段 2-1-3-2-4-2 にした塊）
	runs := []int{2, 1, 3, 2, 4, 2}
	w := 0
	for _, n := range runs {
		w += n
	}
	g = pxlib.NewGrid(w, len(runs)+4)
	x := 0
	for i, n := range runs {
		for k := 0; k < n; k++ {
			for y := len(runs) - i; y < g.H; y++ {
				g.Put(x, y, "m", pxlib.OpRef{Part: "poly"})
			}
			x++
		}
	}
	c = base()
	c.Poly = map[string]bool{"poly": true}
	want("poly の辺", checkRef{Check: checkFlatRun}, g, c, "px.flat-run.poly")

	// 細長い影（1×10）
	g = pxlib.NewGrid(12, 12)
	for y := 1; y < 11; y++ {
		g.Put(5, y, "m", pxlib.OpRef{Part: "p"})
	}
	want("細長い影", checkRef{Check: checkSprite}, g, base(), "px.sprite.silhouette.thin")

	// コマ列: 輪が閉じない・あるコマだけに色が湧く
	ar, err := anim.LoadRules(engineRoot)
	if err != nil {
		t.Fatal(err)
	}
	// 縦の棒 → 縦の棒 → 横の棒（最後 → 最初で形が入れ替わり、輪が閉じない）
	vbar := []string{"...aa...", "...aa...", "...aa...", "...aa...", "...aa...", "...aa...", "...aa...", "...aa..."}
	hbar := []string{"........", "........", "........", "aaaaaaaa", "aaaaaaaa", "........", "........", "........"}
	got := map[string]bool{}
	for _, note := range ar.MeasureSequence("s", []string{"v1", "v2", "h"}, [][]string{vbar, vbar, hbar}) {
		v := animViolation(note)
		seenProbe(v)
		got[v.code()] = true
	}
	for _, code := range []string{"px.anim.loop"} {
		if !got[code] {
			t.Errorf("コマ列: %s が出ない（%v）", code, got)
		}
	}
}

// 手描きの sprite.json の形の誤り・色の近さ・色数と、色の門の外れ（px check の道）。
func TestRareCodesFireInCheck(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, name)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("art/g.colorgate.json", `{"version": 2, "default": "day", "styles": {"day": {"label": "昼の外", "colors": {"a": "#101010", "b": "#121212"}}},
	  "deny": [{"color": "#ff00ff", "why": "仮色"}], "files": {}}`)
	colors := `"palette": {"a": "#101010", "b": "#121212", "c": "#ff00ff", "e": "#777777"}`
	write("assets/near.sprite.json", `{"version": 1, `+colors+`, "legend": {"a": "a", "b": "b", "c": "c", "e": "e", "z": ""},
	  "sprites": {"s": {"anchor": {"x": 0, "y": 0}, "frames": {"f": ["aabb", "abba", "ceec", "aabb"]}}}}`)
	if _, err := checkFiles(engineRoot, dir, "art/g.colorgate.json", []string{"assets/near.sprite.json", "assets/missing.sprite.json"}); err != nil {
		t.Fatal(err)
	}
	// default の無い門では、files に無い冊は no-entry
	write("art/n.colorgate.json", `{"version": 2, "styles": {"day": {"label": "昼の外", "colors": {"a": "#101010"}}}, "files": {}}`)
	if _, err := checkFiles(engineRoot, dir, "art/n.colorgate.json", []string{"assets/near.sprite.json"}); err != nil {
		t.Fatal(err)
	}
}

func hex2(v int) string {
	const d = "0123456789abcdef"
	return string([]byte{d[v>>4&15], d[v&15]})
}

// 門の Doc の読み手が止める形（styles に無い画風）も、CheckDoc に直に渡せば bad-style の code で出る。
func TestGateBadStyleCode(t *testing.T) {
	g := &colorGate{Path: "g.json", Styles: map[string]*gateStyle{}, Files: map[string]*gateFile{"a.sprite.json": {Style: "dusk"}}}
	doc, err := pxlib.DecodeOrdered([]byte(`{"version": 1, "legend": {}, "sprites": {}}`))
	if err != nil {
		t.Fatal(err)
	}
	bad, _ := g.CheckDoc(t.TempDir(), doc.(*pxlib.Obj), "a.sprite.json")
	if len(bad) != 1 {
		t.Fatalf("got %v", bad)
	}
	v := gateViolation(bad[0], nil)
	seenProbe(v)
	if v.code() != "px.gate.bad-style" {
		t.Errorf("code %s", v.code())
	}
}
