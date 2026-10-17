package px

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// op の説明は Op の構造体の 1 か所だけにある。空の欄があれば文書（px-ops.md・スキーマ）に穴が開く。
func TestOpRegistryHasDocs(t *testing.T) {
	for _, op := range allOps() {
		if op.Summary == "" || op.Technique == "" || op.Finish == "" {
			t.Errorf("%s: Summary・Technique・Finish のどれかが空", op.Name)
		}
		for _, p := range op.Params {
			if p.Summary == "" {
				t.Errorf("%s.%s: 引数の Summary が空", op.Name, p.Name)
			}
			if p.Required && p.Default != nil {
				t.Errorf("%s.%s: 必須なのに既定値がある", op.Name, p.Name)
			}
		}
		for _, c := range append(append([]checkRef(nil), op.Checks...), op.Exempt...) {
			if checks[c.Check] == nil {
				t.Errorf("%s: 知らない検査 %q", op.Name, c)
			}
		}
	}
	for _, name := range []string{"fill", "stamp", "use", "flip", "outline", "shade_step", "shade_parts", "pixel_perfect"} {
		if _, ok := lookupOp(name); !ok {
			t.Errorf("段 1 の op %s が無い", name)
		}
	}
}

// docs/ の生成物は op の登録とずれていない（ずれたら bin/fge px ops --md・bin/fge px schema --write で作り直す）。
func TestDocsUpToDate(t *testing.T) {
	for path, want := range map[string]string{
		"docs/px-ops.md":             opsMarkdown(),
		"docs/pxsrc.schema.json":     specSchema(),
		"docs/colorgate.schema.json": gateSchema(),
	} {
		got, err := os.ReadFile(filepath.Join(engineRoot, path))
		if err != nil || string(got) != want {
			t.Errorf("%s が生成物とずれている（bin/fge px ops --md・bin/fge px schema --write）", path)
		}
	}
}

func writeSpec(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	pal := `{"version": 1, "c0": "#202020", "c1": "#606060", "c2": "#a0a0a0", "c3": "#e0e0e0"}`
	if err := os.WriteFile(filepath.Join(dir, "assets", "t.palette.json"), []byte(pal), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "t.pxsrc.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

const specHead = `{"version": 2, "target": "atelier/t.sprite.json", "palette": "assets/t.palette.json",
  "ramps": {"r": ["c0", "c1", "c2", "c3"]},`

// 違反は、その画素を最後に書いた部品と op の場所を持つ。
func TestViolationPointsToOp(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [8, 8], "ramp": "r",
    "parts": [
      {"id": "body", "shape": {"rect": [1, 1, 3, 3]}, "ops": [{"fill": {"color": "mid"}}]},
      {"id": "spark", "ops": [{"put": {"cells": [[6, 6]], "color": "light"}}]}],
    "frames": {"idle": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range res.Violations {
		if v.Check == checkSprite && v.Rule == "orphan" {
			if v.Op.String() != "spark.ops[0] put" || v.X != 6 || v.Y != 6 {
				t.Fatalf("got %s", v.String())
			}
			return
		}
	}
	t.Fatalf("orphan が出ない: %v", res.Violations)
}

// 指定の書き損じは、部品と op の場所つきで全部返る（1 件目で止めない）。
func TestSpecProblemsHaveLocation(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [8, 8], "ramp": "r",
    "parts": [
      {"id": "body", "ops": [{"fill": {"colour": "mid"}}]},
      {"id": "eye", "on": "hat", "ops": [{"shade_stepp": {}}]}],
    "frames": {"idle": {}, "blink": {"nose": null}}}}}`)
	_, err := loadSpec(filepath.Join(dir, "t.pxsrc.json"))
	if err == nil {
		t.Fatal("通ってしまった")
	}
	for _, want := range []string{"body.ops[0] fill: 知らない引数 \"colour\"", "eye.ops[0]: 知らない op \"shade_stepp\"",
		"parts[1](eye).on", "frames.blink.nose"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("%q が誤りに無い:\n%v", want, err)
		}
	}
}

// コマの patch: null で部品を外し、at でずらし、ほかのコマは元のまま。
func TestFramePatch(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [4, 2], "ramp": "r",
    "parts": [
      {"id": "a", "shape": {"rect": [0, 0, 1, 1]}, "ops": [{"fill": {"color": "ink"}}]},
      {"id": "b", "shape": {"rect": [0, 1, 1, 1]}, "ops": [{"fill": {"color": "light"}}]}],
    "frames": {"idle": {}, "off": {"b": null}, "moved": {"a": {"at": [2, 0]}}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, f := range res.Frames {
		got[f.Name] = strings.Join(f.Rows, "/")
	}
	ink, light := charOfKey(res.Legend, "c0"), charOfKey(res.Legend, "c3")
	want := map[string]string{
		"idle":  ink + ".../" + light + "...",
		"off":   ink + ".../....",
		"moved": ".." + ink + "./" + light + "...",
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s: got %q want %q", k, got[k], w)
		}
	}
}

func charOfKey(legend map[string]string, key string) string {
	for ch, k := range legend {
		if k == key {
			return ch
		}
	}
	return "?"
}

// clip の部品は親の塊の外へ描かない。
func TestClipStaysInsideParent(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [5, 1], "ramp": "r",
    "parts": [
      {"id": "a", "shape": {"rect": [1, 0, 2, 1]}, "ops": [{"fill": {"color": "ink"}}]},
      {"id": "b", "on": "a", "clip": true, "ops": [{"line": {"points": [[0, 0], [4, 0]], "color": "light"}}]}],
    "frames": {"idle": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	l := charOfKey(res.Legend, "c3")
	if got := res.Frames[0].Rows[0]; got != "."+l+l+".." {
		t.Fatalf("got %q", got)
	}
}

// --- 技法の仕様の例（px-techniques.md の 2 節） ---

func maskOf(rows ...string) pxlib.Mask {
	m := pxlib.NewMask(len(rows[0]), len(rows))
	for y, r := range rows {
		for x, ch := range r {
			m[y][x] = ch == '#'
		}
	}
	return m
}

func rowsOfMask(m pxlib.Mask) string {
	var out []string
	for _, row := range m {
		var b strings.Builder
		for _, v := range row {
			if v {
				b.WriteByte('#')
			} else {
				b.WriteByte('.')
			}
		}
		out = append(out, b.String())
	}
	return strings.Join(out, " / ")
}

func TestPixelPerfectExamples(t *testing.T) {
	for _, c := range []struct{ in, want []string }{
		{[]string{"##..", ".#..", ".##.", "..##"}, []string{"#...", ".#..", "..#.", "...#"}},
		{[]string{"###...", "..###."}, []string{"##....", "..###."}},
		{[]string{"##", "##"}, []string{"##", "##"}},
	} {
		got := rowsOfMask(pixelPerfect(maskOf(c.in...)))
		if want := strings.Join(c.want, " / "); got != want {
			t.Errorf("%v: got %s want %s", c.in, got, want)
		}
	}
}

func TestShadeStepExamples(t *testing.T) {
	ramp := []pxlib.Key{"a", "b", "c", "d"}
	for _, c := range []struct {
		from pxlib.Key
		d    int
		want pxlib.Key
	}{{"a", -1, "a"}, {"c", 1, "d"}, {"z", 1, "z"}} {
		if got := shadeStep(ramp, c.from, c.d); got != c.want {
			t.Errorf("(%s, %+d): got %s want %s", c.from, c.d, got, c.want)
		}
	}
}

// shade_step の op は部品の塊の中だけ、ランプの段を動かす。
func TestShadeStepOpStaysInShape(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [4, 1], "ramp": "r",
    "parts": [{"id": "a", "shape": {"rect": [0, 0, 4, 1]},
      "ops": [{"fill": {"color": "mid"}}, {"shade_step": {"by": -1, "shape": {"rect": [2, 0, 2, 1]}}}]}],
    "frames": {"idle": {}}}}}`)
	res, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	m, s := charOfKey(res.Legend, "c2"), charOfKey(res.Legend, "c1")
	if got := res.Frames[0].Rows[0]; got != m+m+s+s {
		t.Fatalf("got %q", got)
	}
}
