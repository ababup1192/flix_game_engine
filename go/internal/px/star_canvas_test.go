package px

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 台本で格子に帯の場の段を置き、pixels の op で書き出して描ける（原理を組む低い所の部品が通しで動く）。
func TestStarCanvasBandShapeLight(t *testing.T) {
	dir := t.TempDir()
	script := `ramps = px.palette("t.palette.json", {"s": ["#202020", "#505050", "#909090", "#d0d0d0"]})
band = px.band("linear", origin = [0, 0], dir = [1, 1], width = 4, count = 3)
c = px.canvas(8, 8, ramps = ramps)
for y in range(8):
    for x in range(8):
        c.put(x, y, "s", band(x, y))
c.shift(0, 0, 5)
lights = px.shape_light([[0, 0, 4, 4], [4, 4, 4, 4]], band)
for l in lights:
    for p in l["edge"]:
        c.shift(p[0], p[1], 1)
px.write_spec("t.pxsrc.json", {"version": 2, "target": "//atelier/t.sprite.json", "palette": "t.palette.json", "ramps": ramps,
  "sprites": {"t": {"size": [8, 8], "ramp": "s", "parts": [{"id": "g", "ops": [c.to_op()]}], "frames": {"f": {}}}}})
`
	if err := os.WriteFile(filepath.Join(dir, "t.px.star"), []byte(script), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, engineRoot, dir, []string{"build", "t.px.star"}, false); code == 1 {
		t.Fatalf("build が止まった: %s %s", out.String(), errOut.String())
	}
	data, err := os.ReadFile(filepath.Join(dir, "atelier", "t.sprite.json"))
	if err != nil {
		t.Fatal(err)
	}
	// 左上は shift(5) で一番明るい段・右下は帯 2 の上に縁の +1 で一番明るい段
	if !strings.Contains(string(data), `"s3"`) || !strings.Contains(string(data), `"s0"`) {
		t.Errorf("段が書き出されていない: %s", data)
	}
	if strings.Contains(errOut.String(), "stamp が") {
		t.Errorf("canvas の書き出しに stamp の目安が当たった: %s", errOut.String())
	}
}
