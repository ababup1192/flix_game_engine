package px

import (
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// tile_wrap_offset を 2 度当てると元の格子に戻る（半分ずつ 2 回 = 1 周）。
func TestTileWrapOffsetTwiceIsIdentity(t *testing.T) {
	g := pxlib.NewGrid(6, 4)
	g.Put(0, 0, "a", pxlib.OpRef{Part: "p"})
	g.Put(5, 3, "b", pxlib.OpRef{Part: "q"})
	before, _ := g.Rows(map[pxlib.Key]string{"a": "a", "b": "b"})
	g.Wrap(3, 2)
	if g.At(3, 2) != "a" || g.SrcAt(3, 2).Part != "p" {
		t.Fatalf("ずらした先に元の画素と書き手が無い")
	}
	g.Wrap(3, 2)
	after, _ := g.Rows(map[pxlib.Key]string{"a": "a", "b": "b"})
	if strings.Join(before, "/") != strings.Join(after, "/") {
		t.Errorf("2 度で戻らない: %v → %v", before, after)
	}
}

// rim_light は光の側（左上）の外形の 1px だけを塗る。
func TestRimLightOnlyLitSide(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "light": {"dir": [-1, -1]},
  "sprites": {"s": {"size": [8, 8], "ramp": "r",
    "parts": [{"id": "body", "shape": {"rect": [2, 2, 4, 4]}, "ops": [{"fill": {"color": "mid"}}, {"rim_light": {"color": "light"}}]}],
    "frames": {"f": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	g := res.Frames[0].grid
	if g.At(2, 2) == g.At(4, 4) || g.At(5, 5) == g.At(2, 3) {
		t.Errorf("左上の縁だけが光の色にならない: %v", res.Frames[0].Rows)
	}
}

// courses の widths は段ごとに縦の目地の位置を回す（同じ並びの段が続かない）。
func TestCoursesWidthsVary(t *testing.T) {
	m := pxlib.NewMask(32, 8)
	for y := 0; y < 8; y++ {
		for x := 0; x < 32; x++ {
			m[y][x] = true
		}
	}
	pts := courses(m, 8, 4, pxlib.Pt{}, 0.5, true, 16, 8, 4, 4)
	row := func(y int) string {
		b := []byte(strings.Repeat(".", 32))
		for _, p := range pts {
			if p.Y == y {
				b[p.X] = '|'
			}
		}
		return string(b)
	}
	if row(1) == row(5) {
		t.Errorf("段 0 と段 1 の縦の目地が同じ: %s", row(1))
	}
}
