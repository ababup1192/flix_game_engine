package px

import (
	"os"
	"path/filepath"
	"testing"
)

// どの kind でも base の上に足す検査が 1 つ以上ある（楽な kind を作らない）。外す検査には理由がある。
func TestEveryKindAddsAndSkipsHaveWhy(t *testing.T) {
	for _, d := range kindTable {
		if len(d.Adds) == 0 {
			t.Errorf("kind %s に足す検査が無い", d.Kind)
		}
		for _, s := range d.Skips {
			if len([]rune(s.Why)) < 6 {
				t.Errorf("kind %s の外す検査 %s に理由が無い", d.Kind, s.Ref)
			}
		}
	}
}

// gate の重さの検査と decl は軸で動けない（fidelity で外れの重さを変えさせない）。
func TestGateChecksDoNotMoveWithFidelity(t *testing.T) {
	for _, c := range checks {
		if c.Fidelity && (c.Level == levelGate || c.Name == checkDecl || c.Name == checkGate) {
			t.Errorf("%s は gate か decl なのに軸で動く", c.Name)
		}
	}
}

// 相反する組は軸の上で重ならず隙間も無い（A の hi = B の lo）。
func TestOpposedRangesTouch(t *testing.T) {
	r, err := loadRules(engineRoot)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range opposedChecks {
		a, b := r.fidelityRangeOf(p[0]), r.fidelityRangeOf(p[1])
		if a.Hi != b.Lo {
			t.Errorf("%s [%v,%v) と %s [%v,%v) の間に重なりか隙間", p[0], a.Lo, a.Hi, p[1], b.Lo, b.Hi)
		}
	}
	// どの fidelity でも、当たる検査（範囲の中）が base＋1 以上
	for _, f := range []float64{0, 0.2, 0.5, 0.9, 1} {
		n := 0
		for name, c := range checks {
			if !c.Fidelity || r.fidelityRangeOf(name).has(f) {
				n++
			}
		}
		if n < len(frameChecks)+len(techFrameChecks)+1 {
			t.Errorf("fidelity %.1f で当たる検査が %d しかない", f, n)
		}
	}
}

// 門の画風 → 機種 → 不明の順。機種だけなら機種の値・どちらも無ければ不明。
func TestFidelitySource(t *testing.T) {
	gate := &colorGate{Default: "day", Styles: map[string]*gateStyle{"day": {Fidelity: ptrF(0.9)}, "night": {}}, Files: map[string]*gateFile{
		"n.sprite.json": {Style: "night"}, "f.sprite.json": {Style: freeStyle, Fidelity: ptrF(0.4)}}}
	nes := &pxStyle{name: "nes", Fidelity: ptrF(0.2)}
	for _, c := range []struct {
		slot    string
		machine *pxStyle
		want    float64
		by      string
	}{
		{"x.sprite.json", nes, 0.9, "門 day"},
		{"n.sprite.json", nes, 0.2, "機種 nes"},
		{"f.sprite.json", nil, 0.4, "門 free"},
	} {
		f := resolveFidelity(gate, c.slot, c.machine)
		if !f.Known || f.Value != c.want || f.By != c.by {
			t.Errorf("%s: %+v（%v %s のはず）", c.slot, f, c.want, c.by)
		}
	}
	if f := resolveFidelity(gate, "n.sprite.json", nil); f.Known {
		t.Errorf("門にも機種にも無いのに分かった: %+v", f)
	}
}

// 閾値の折れ線: fidelity で線形・int の欄は段。点が壊れていれば読み手が止める。
func TestKnobThresholds(t *testing.T) {
	dir := t.TempDir()
	data, err := os.ReadFile(filepath.Join(engineRoot, "bin", "lint-rules", "px.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "bin", "lint-rules"), 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(body []byte) {
		if err := os.WriteFile(filepath.Join(dir, "bin", "lint-rules", "px.json"), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	patched := []byte(string(data[:len(data)-2]) + `, "groundContrastMin": {"by": "fidelity", "at": [[0, 0.2], [1, 0.1]]}, "flatRunPer": {"by": "size", "at": [[1, 4], [32, 8], [1024, 8]]}}` + "\n")
	write(patched)
	r, err := loadRules(dir)
	if err != nil {
		t.Fatal(err)
	}
	if v := r.at(fidelityOf{Value: 0.5, Known: true}, 32).GroundContrastMin; v < 0.149 || v > 0.151 {
		t.Errorf("fidelity 0.5 の groundContrastMin %v（0.15 のはず）", v)
	}
	if v := r.at(fidelityOf{Value: 0.5, Known: true}, 16).FlatRunPer; v != 4 {
		t.Errorf("16px の flatRunPer %v（段なので 4 のはず）", v)
	}
	write([]byte(string(data[:len(data)-2]) + `, "groundContrastMin": {"by": "fidelity", "at": [[0, 0.2], [1, -1]]}}` + "\n"))
	if _, err := loadRules(dir); err == nil {
		t.Error("点の 1 つが下限を割っているのに読めた")
	}
}
