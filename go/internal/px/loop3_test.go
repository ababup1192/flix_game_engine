package px

// 昇格ループ 3 周目（一人称の 3D ダンジョン）で昇格した形と直しのテスト。

import (
	"image"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// glow は城下町の台本の glow（中心から (1 − d)^power をランプに Bayer で落とし、明るい段だけ上書き・0 段は置かない）と同じ画素を出す。
// 台本の関数を Go に 1 行ずつ写した物と、重なる 2 つのにじみで比べる。
func TestGlowMatchesScriptGlow(t *testing.T) {
	type c struct{ x, y, r, p, xs float64 }
	glows := []c{{6.5, 6.5, 6, 1.3, 1}, {11, 7, 5, 1.6, 1.5}}
	ramp := []string{"c0", "c1", "c2", "c3"}
	want := make([][]string, 14)
	for y := range want {
		want[y] = make([]string, 18)
	}
	pick := func(t float64, x, y int) string {
		t = min(1, max(0, t)) * float64(len(ramp)-1)
		k := int(t)
		if k >= len(ramp)-1 {
			return ramp[len(ramp)-1]
		}
		if t-float64(k) > bayer(x, y) {
			return ramp[k+1]
		}
		return ramp[k]
	}
	index := func(s string) int {
		for i, k := range ramp {
			if k == s {
				return i
			}
		}
		return -1
	}
	for _, g := range glows {
		for y := int(g.y - g.r - 1); y < int(g.y+g.r+2); y++ {
			for x := int(g.x - g.r*g.xs - 1); x < int(g.x+g.r*g.xs+2); x++ {
				d := hypot((float64(x)+0.5-g.x)/g.xs, float64(y)+0.5-g.y) / g.r
				if d >= 1 || y < 0 || y >= 14 || x < 0 || x >= 18 {
					continue
				}
				tv, _ := crPow(1-d, g.p)
				k := pick(tv, x, y)
				if k != ramp[0] && index(k) > index(want[y][x]) {
					want[y][x] = k
				}
			}
		}
	}
	res, err := build(writeSpec(t, specHead+`
  "sprites": {"s": {"size": [18, 14], "ramp": "r", "parts": [{"id": "p", "ops": [
    {"glow": {"centers": [[6.5, 6.5]], "r": 6, "power": 1.3}},
    {"glow": {"centers": [[11, 7]], "r": 5, "power": 1.6, "xscale": 1.5}}]}],
    "frames": {"f": {}}}}}`), "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	g := res.Frames[0].grid
	for y := 0; y < 14; y++ {
		for x := 0; x < 18; x++ {
			if got := string(g.At(x, y)); got != want[y][x] {
				t.Fatalf("(%d,%d) は %q（台本の glow は %q）", x, y, got, want[y][x])
			}
		}
	}
}

// courses の quad は、4 隅が矩形なら等間隔の格子（横の目地は段の境目・縦の目地は段の上下 1px を空けて段ごとに半分ずらす）。
func TestCoursesQuadOnRect(t *testing.T) {
	got := strings.Join(buildRows(t, onePart("13, 9", `[{"fill": {"shape": {"rect": [0, 0, 13, 9]}, "color": "c3"}},
    {"courses": {"quad": [[0, 0], [12, 0], [12, 8], [0, 8]], "grid": [2, 2], "color": "c0"}}]`)), "\n")
	rows := strings.Split(got, "\n")
	// 横の目地は真ん中の行（y = 4）に 1 本
	if strings.Count(rows[4], rows[4][:1]) != 13 {
		t.Fatalf("横の目地が y = 4 に通っていない:\n%s", got)
	}
	ink := rows[4][:1]
	// 1 段目（y = 0..4）の縦の目地は u = 0.5（x = 6）で、段の上下 1px を空けて y = 1..3
	for y := 1; y <= 3; y++ {
		if rows[y][6:7] != ink {
			t.Fatalf("1 段目の縦の目地が x = 6, y = %d に無い:\n%s", y, got)
		}
	}
	if rows[0][6:7] == ink {
		t.Fatalf("縦の目地が段の上の 1px を空けていない:\n%s", got)
	}
	// 2 段目は半分ずれて u = 0.25・0.75（x = 3・9）
	for _, x := range []int{3, 9} {
		if rows[6][x:x+1] != ink {
			t.Fatalf("2 段目の縦の目地が x = %d に無い:\n%s", x, got)
		}
	}
}

// courses の quad は奥ほど詰まる: 台形（奥の辺が短い）の縦の目地の間は、手前より奥が狭い。
func TestCoursesQuadForeshortens(t *testing.T) {
	at := quadMap([][2]float64{{0, 0}, {40, 10}, {40, 30}, {0, 40}})
	x1, _ := at(0.25, 0)
	x2, _ := at(0.5, 0)
	x3, _ := at(0.75, 0)
	if !(x1 > x2-x1 && x2-x1 > x3-x2) {
		t.Fatalf("奥ほど詰まっていない: %v %v %v", x1, x2, x3)
	}
	if x, y := at(1, 1); x != 40 || y != 30 {
		t.Fatalf("奥の下の隅が (40, 30) に写らない: (%v, %v)", x, y)
	}
}

// table の右寄せは、右端（送りを含む）を cols の位置にそろえる（数を桁でそろえる）。
func TestTableAlignRight(t *testing.T) {
	a := buildRows(t, onePart("30, 9", `[{"table": {"at": [0, 0], "cols": [0, 24], "align": "lr", "rows": [["A", "7"]], "color": "c3"}}]`))
	b := buildRows(t, onePart("30, 9", `[{"text": {"at": [0, 0], "text": "A", "color": "c3"}}, {"text": {"at": [18, 0], "text": "7", "color": "c3"}}]`))
	if strings.Join(a, "\n") != strings.Join(b, "\n") {
		t.Fatalf("右寄せの升が text の位置と違う:\n%s\n---\n%s", strings.Join(a, "\n"), strings.Join(b, "\n"))
	}
}

// frame の "a|b" は上と左を a・下と右を b（凹んだ窓の縁）。"" の輪は空ける。
func TestFrameRings(t *testing.T) {
	got := buildRows(t, onePart("6, 5", `[{"frame": {"shape": {"rect": [0, 0, 6, 5]}, "rings": ["c0|c3", "", "c1"], "fill": "c2"}}]`))
	// 文字は legend の字なので、同じ色か違う色かで見る。期待する並び（A = c0・B = c1・C = c2・D = c3）:
	//   AAAAAD / ACCCCD / ACBBCD / ACCCCD / DDDDDD
	same := func(a, b [2]int) bool { return got[a[1]][a[0]] == got[b[1]][b[0]] }
	for _, c := range []struct {
		a, b [2]int
		eq   bool
	}{
		{[2]int{0, 0}, [2]int{4, 0}, true}, {[2]int{0, 0}, [2]int{0, 3}, true}, {[2]int{5, 0}, [2]int{0, 4}, true},
		{[2]int{0, 0}, [2]int{5, 0}, false}, {[2]int{1, 1}, [2]int{4, 3}, true}, {[2]int{2, 2}, [2]int{3, 2}, true},
		{[2]int{1, 1}, [2]int{2, 2}, false}, {[2]int{2, 2}, [2]int{0, 0}, false}, {[2]int{2, 2}, [2]int{5, 0}, false},
	} {
		if same(c.a, c.b) != c.eq {
			t.Fatalf("%v と %v の色の同じ・違うが期待と逆:\n%s", c.a, c.b, strings.Join(got, "\n"))
		}
	}
}

// 1 枚の格子は 1024 まで（640 幅の画面を 1 枚で）。
func TestGridUpTo1024(t *testing.T) {
	if _, err := build(writeSpec(t, onePart("640, 200", `[{"fill": {"shape": {"rect": [0, 0, 640, 200]}, "color": "c1"}}]`)), "t.pxsrc.json",
		buildOptions{RulesRoot: engineRoot, NoCheck: true}); err != nil {
		t.Fatalf("640×200 が描けない: %v", err)
	}
	_, err := build(writeSpec(t, onePart("1025, 8", `[{"fill": {"color": "c1"}}]`)), "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err == nil || !strings.Contains(err.Error(), "1024") {
		t.Fatalf("1025 幅を止めない: %v", err)
	}
}

// style の pixel [1, 2] は --png の PNG を縦 2 倍に引き伸ばす（sprite.json は 1:1 のまま）。
func TestStylePixelAspectStretchesPNG(t *testing.T) {
	dir := writeSpec(t, strings.Replace(onePart("6, 4", `[{"fill": {"shape": {"rect": [0, 0, 6, 4]}, "color": "c1"}}]`),
		`"version": 2,`, `"version": 2, "style": "tall.pxstyle.json",`, 1))
	if err := os.WriteFile(filepath.Join(dir, "tall.pxstyle.json"), []byte(`{"label": "縦長", "pixel": [1, 2]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true, PNG: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Frames[0].Rows) != 4 {
		t.Fatalf("sprite.json の行が引き伸ばされた: %d 行", len(res.Frames[0].Rows))
	}
	fh, err := os.Open(filepath.Join(res.PNGDir, "s.png"))
	if err != nil {
		t.Fatal(err)
	}
	defer fh.Close()
	cfg, _, err := image.DecodeConfig(fh)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Width != 6 || cfg.Height != 8 {
		t.Fatalf("PNG が %d×%d（6×8 のはず）", cfg.Width, cfg.Height)
	}
}
