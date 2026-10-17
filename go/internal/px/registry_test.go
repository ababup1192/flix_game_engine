package px

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// どの op も、例を実際に描ける（Params に無い名前で引数を引くと panic するので、ここで捕まる）。
func TestEveryOpExampleDraws(t *testing.T) {
	for _, op := range allOps() {
		t.Run(op.Name, func(t *testing.T) {
			if op.Example == "" {
				t.Fatal("Example が空")
			}
			var ex any
			if err := json.Unmarshal([]byte(op.Example), &ex); err != nil {
				t.Fatalf("Example が JSON でない: %v", err)
			}
			ops, post := `[`+op.Example+`]`, `[]`
			if op.PostOnly {
				ops, post = `[]`, `[`+op.Example+`]`
			}
			dir := writeSpec(t, specHead+`
  "light": {"gloss": "c3"},
  "macros": {"eye": [{"fill": {"color": "light", "shape": {"rect": [5, 5, 2, 2]}}}]},
  "sprites": {"s": {"size": [16, 16], "ramp": "r",
    "parts": [
      {"id": "base", "shape": {"rect": [2, 2, 10, 10]}, "ops": [{"fill": {"color": "mid"}}]},
      {"id": "p", "on": "base", "shape": {"rect": [3, 3, 6, 6]}, "ops": `+ops+`}],
    "post": `+post+`,
    "frames": {"idle": {}}}}}`)
			if _, err := build(dir, "t.pxsrc.json", buildOptions{RulesRoot: engineRoot}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// 引数を Params に無い名前で引くと panic する。
func TestArgsPanicOnUndeclaredName(t *testing.T) {
	op, _ := lookupOp("fill")
	defer func() {
		if recover() == nil {
			t.Fatal("panic しない")
		}
	}()
	opArgs{op: op, v: map[string]any{}}.str("colour")
}

// 既定値は引数の型に合う（op と形の両方）。必須の引数は既定値を持たない。
func TestParamDefaultsMatchType(t *testing.T) {
	var all []param
	for _, op := range allOps() {
		all = append(all, op.Params...)
	}
	for _, k := range allShapes() {
		all = append(all, k.Extra...)
	}
	for _, p := range all {
		if p.Required && p.Default != nil {
			t.Errorf("%s: 必須なのに既定値がある", p.Name)
		}
		if p.Default == nil {
			continue
		}
		if err := checkType(p, p.Default); err != nil {
			t.Errorf("%s: 既定値 %v が型 %s に合わない: %v", p.Name, p.Default, p.Type, err)
		}
	}
}

// 形の書き損じは、読む段で場所つきの誤りになる（panic しない・黙って 0 にしない）。
func TestShapeRejectsBadForms(t *testing.T) {
	refs := map[string]any{"loop": map[string]any{"ref": "loop"}}
	for _, c := range []struct{ in, want string }{
		{`{"disk": [4, 4]}`, "s.disk: [cx, cy, r] で書く"},
		{`{"disk": [4, "a", 2]}`, "s.disk: [cx, cy, r] で書く"},
		{`{"rotate": 0.25, "of": {"disk": [1, 1, 1]}}`, "s.rotate: about が無い"},
		{`{"rotate": 0.25, "about": [1, 1]}`, "s.rotate: of が無い"},
		{`{"poly": [[1, 1]]}`, "s.poly: [[x, y], ...]（3 点以上"},
		{`{"poly": [[1, 1], [2, 3]]}`, "3 点以上で書く（mirror を書けば"},
		{`{"union": []}`, "s.union: [形, 形, ...]（2 つ以上） で書く"},
		{`{"inter": [{"disk": [1, 1, 1]}]}`, "s.inter: [形, 形, ...]（2 つ以上） で書く"},
		{`{"union": [{"disk": [1, 1, 1]}, {"disk": [1, 1]}]}`, "s.union[1].disk:"},
		{`{"smoothUnion": [{"disk": [1, 1, 1]}, {"disk": [2, 2, 1]}], "k": 0}`, "s.smoothUnion.k:"},
		{`{"disk": [1, 1, 1], "width": 2}`, `s.disk: 知らない鍵 "width"`},
		{`{"disk": [1, 1, 1], "rect": [0, 0, 1, 1]}`, "形の種類が 2 つある"},
		{`{"blob": [1]}`, "知らない形"},
		{`{"ref": "nope"}`, `shapes に "nope" が無い`},
		{`{"ref": "loop"}`, "深すぎる"},
		{`{"mask": ["#"], "at": [0.5, 0]}`, "s.mask.at:"},
		{`{"ellipse": [4, 4, 0, 2]}`, "rx と ry は 0 にしない"},
	} {
		var v any
		if err := json.Unmarshal([]byte(c.in), &v); err != nil {
			t.Fatal(err)
		}
		_, err := shapeOf(v, refs, "s")
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: got %v want %q", c.in, err, c.want)
		}
	}
}

// capsule・poly・taper・rotate+star・smoothUnion+ellipse の塊が、Python（bin/pxkit/shapes.py）と同じ。
// 期待値は乱数で選んだ小数の引数で描いた 32 例（縁に乗った画素の内外で、積と和の丸めの違いが出る）。
func TestShapesMatchPython(t *testing.T) {
	data, err := os.ReadFile("testdata/shapes/python.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Shape any      `json:"shape"`
		Rows  []string `json:"rows"`
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	for i, c := range cases {
		f, err := shapeOf(c.Shape, nil, "case")
		if err != nil {
			t.Fatalf("%d: %v", i, err)
		}
		m := pxlib.MaskOf(len(c.Rows[0]), len(c.Rows), f)
		if got, want := rowsOfMask(m), strings.Join(c.Rows, " / "); got != want {
			t.Errorf("%d %v: Python と違う", i, c.Shape)
		}
	}
}

// 検査の説明が空なら、docs/px-ops.md に穴が開く。
func TestCheckRegistryHasDocs(t *testing.T) {
	for _, c := range allChecks() {
		if c.Summary == "" {
			t.Errorf("%s: Summary が空", c.Name)
		}
		if !c.Level.Valid() {
			t.Errorf("%s: Level が不正", c.Name)
		}
	}
	for _, k := range allShapes() {
		if k.Summary == "" || k.Main.Summary == "" {
			t.Errorf("形 %s: Summary が空", k.Name)
		}
	}
}

// スキーマに書ける鍵と、読み手（spec.go）が受ける鍵は同じ。
func TestSchemaKeysMatchReader(t *testing.T) {
	var schema map[string]any
	if err := json.Unmarshal([]byte(specSchema()), &schema); err != nil {
		t.Fatal(err)
	}
	props := func(v any) []string {
		m, _ := v.(map[string]any)
		p, _ := m["properties"].(map[string]any)
		out := keysOf(p)
		sort.Strings(out)
		return out
	}
	defs := schema["definitions"].(map[string]any)
	root := schema["properties"].(map[string]any)
	for _, c := range []struct {
		name   string
		schema any
		reader []string
	}{
		{"一番外", schema, specKeys},
		{"light", root["light"], lightKeys},
		{"sprite", defs["sprite"], spriteKeys},
		{"part", defs["part"], partKeys},
	} {
		want := slices.Clone(c.reader)
		sort.Strings(want)
		if got := props(c.schema); !slices.Equal(got, want) {
			t.Errorf("%s: スキーマ %v・読み手 %v", c.name, got, want)
		}
	}
}

// flip は post にだけ書ける。
func TestFlipOnlyInPost(t *testing.T) {
	dir := writeSpec(t, specHead+`
  "sprites": {"s": {"size": [4, 4], "ramp": "r",
    "parts": [{"id": "a", "ops": [{"flip": {}}]}],
    "frames": {"idle": {}}}}}`)
	_, err := loadSpec(filepath.Join(dir, "t.pxsrc.json"))
	if err == nil || !strings.Contains(err.Error(), "a.ops[0] flip: 格子全体を動かす op なので、スプライトの post にだけ書ける") {
		t.Fatalf("got %v", err)
	}
}

// level は 0 と知らない名前を通さない。
func TestLevelRejectsInvalid(t *testing.T) {
	var l level
	if err := json.Unmarshal([]byte(`"loud"`), &l); err == nil {
		t.Error("知らない名前が通った")
	}
	if _, err := json.Marshal(level(0)); err == nil {
		t.Error("0 が書けた")
	}
}

// 知らない指定は止める（黙って読み飛ばさない）。
func TestRunRejectsUnknownFlag(t *testing.T) {
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, engineRoot, ".", []string{"build", "x.pxsrc.json", "--no-chek"}, false); code != 2 {
		t.Fatalf("code %d: %s", code, errOut.String())
	}
	if code := Run(&out, &errOut, engineRoot, ".", []string{"ops", "--gate", "g.json"}, false); code != 2 {
		t.Fatalf("--gate が ops で通った")
	}
}

// bevel_box の角の段は corner の対象外（駒の作法として置く形）。
func TestBevelBoxCornerExempt(t *testing.T) {
	root := copyTree(t, "testdata/puzzle")
	res, err := build(root, "art/puzzle.pxsrc.json", buildOptions{RulesRoot: engineRoot})
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range res.Violations {
		if v.Check == checkSprite && v.Rule == "corner" && strings.HasPrefix(v.Op.Op, "bevel_box") {
			t.Fatalf("bevel_box の角が残った: %s", v)
		}
	}
}

// 上位の件は、前の周に無かった物を先に出す。
func TestSummaryPutsNewFirst(t *testing.T) {
	old := violation{Check: checkFlatRun, Level: levelGate, Msg: "古い"}
	nw := violation{Check: checkFlatRun, Level: levelLint, Msg: "新しい"}
	res := &buildResult{Violations: []violation{old, nw}, prevKeys: map[string]bool{old.key(): true}}
	lines := strings.Split(summarize(".", res), "\n")
	if !strings.Contains(lines[2], "新しい") {
		t.Fatalf("got %q", lines)
	}
}

// advice は上位の件に出さない（数だけ出す。直さなくても絵が崩れない物で周回を回させない）。
func TestSummaryHidesAdvice(t *testing.T) {
	res := &buildResult{Violations: []violation{{Check: checkFlatRun, Level: levelAdvice, Msg: "助言"}}}
	if out := summarize(".", res); strings.Contains(out, "助言") || !strings.Contains(out, "advice 1") {
		t.Fatalf("got %q", out)
	}
}
