package px

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// 期待値は Python の bin/pxkit/gate.py（ゲームの作業場）の判定。testdata/gate の写しは、
// 5 冊の assets を門に効く所（legend・色票・スプライトの順と使う字）だけに縮めた物で、
// 縮める前と後で gate.py の判定が同じことを確かめてから置いた。neg/ はわざと破った例。
// feed（style が free）は決まりの外の例で、色を見ないことを確かめる。
// 作り直す手順: 写しと期待値はゲームの作業場で bin/pxkit/gate.py を使って作った（台本は報告に添付）。
// gate.py は段 2 で消えるので、以後は作り直さない。例を足すときは neg/ に冊を置き、期待値を手で書く。
func TestGateMatchesPython(t *testing.T) {
	root := "testdata/gate"
	data, err := os.ReadFile(filepath.Join(root, "expected.json"))
	if err != nil {
		t.Fatal(err)
	}
	var expected map[string]struct {
		Bad   [][3]string `json:"bad"`
		Known []string    `json:"known"`
	}
	if err := json.Unmarshal(data, &expected); err != nil {
		t.Fatal(err)
	}
	if len(expected) != 9 {
		t.Fatalf("期待値は assets 5 冊 + 破った例 4 冊（今 %d）", len(expected))
	}
	gate, err := loadColorGate(root, "art/internet_dungeon.colorgate.json")
	if err != nil {
		t.Fatal(err)
	}
	for path, want := range expected {
		doc, err := pxlib.LoadOrdered(filepath.Join(root, path))
		if err != nil {
			t.Fatal(err)
		}
		slot := filepath.Base(path)
		bad, known := gate.CheckDoc(root, doc, slot, gateHint{})
		got := [][3]string{}
		for _, b := range bad {
			got = append(got, [3]string{b.Sprite, b.Key, string(b.Kind)})
		}
		gotKnown := []string{}
		for _, k := range known {
			gotKnown = append(gotKnown, slot+"/"+k)
		}
		sort.Strings(gotKnown)
		if want.Bad == nil {
			want.Bad = [][3]string{}
		}
		if want.Known == nil {
			want.Known = []string{}
		}
		if !reflect.DeepEqual(got, want.Bad) {
			t.Errorf("%s: 違反 got %v want %v", path, got, want.Bad)
		}
		if !reflect.DeepEqual(gotKnown, want.Known) {
			t.Errorf("%s: known got %v want %v", path, gotKnown, want.Known)
		}
	}
}

// check は門を通らない冊があれば OK を落とし、行に置き場の名前を付ける。
func TestCheckFilesReportsGate(t *testing.T) {
	rep, err := checkFiles(engineRoot, "testdata/gate", "", []string{"assets/internet_dungeon.day.sprite.json", "neg/internet_dungeon.day.sprite.json"})
	if err != nil {
		t.Fatal(err)
	}
	if rep.OK || len(rep.Gate) != 3 || rep.Gate[0].Msg[:4] != "neg/" {
		t.Fatalf("got ok=%v gate=%v", rep.OK, rep.Gate)
	}
}

// 色の門の Doc の書き損じは、場所つきで止まる（理由の無い allow・styles に無い style）。
func TestColorGateRejectsMissingWhy(t *testing.T) {
	dir := t.TempDir()
	doc := `{"version": 2, "styles": {"day": {"label": "x", "colors": {"a": "#ffffff"}}},
	  "files": {"a.sprite.json": {"style": "dusk", "allow": [{"keys": "^a"}]}}}`
	if err := os.WriteFile(filepath.Join(dir, "g.json"), []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := loadColorGate(dir, "g.json")
	if err == nil {
		t.Fatal("通ってしまった")
	}
	for _, want := range []string{"files.a.sprite.json.style", "files.a.sprite.json.allow[0].why"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("%q が誤りに無い: %v", want, err)
		}
	}
}

// files に無い新しい sprite.json は、spec の style（門の画風）か門の default の画風で見る。
// 決めた色の外は今までどおり止め、どちらも無ければ files に無いことで止める。
func TestColorGateDefaultStyle(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	gateBody := func(def string) string {
		return `{"version": 2, ` + def + `"styles": {"day": {"label": "昼の外", "colors": {"w": "#ffffeb"}}, "night": {"label": "夜の外", "colors": {"k": "#123456"}}}, "files": {}}`
	}
	sprite := func(hex string) *pxlib.Obj {
		o, err := pxlib.DecodeOrdered([]byte(`{"version": 1, "palette": {"c": "` + hex + `"}, "legend": {"a": "c"}, "sprites": {"s": {"frames": {"f": ["a"]}}}}`))
		if err != nil {
			t.Fatal(err)
		}
		return o.(*pxlib.Obj)
	}
	kinds := func(g *colorGate, hex string, hint gateHint) string {
		bad, _ := g.CheckDoc(dir, sprite(hex), "new.sprite.json", hint)
		var ks []string
		for _, b := range bad {
			ks = append(ks, string(b.Kind))
		}
		return strings.Join(ks, ",")
	}
	write("none.json", gateBody(""))
	write("def.json", gateBody(`"default": "day", `))
	none, err := loadColorGate(dir, "none.json")
	if err != nil {
		t.Fatal(err)
	}
	def, err := loadColorGate(dir, "def.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		g    *colorGate
		hex  string
		hint gateHint
		want string
	}{
		{"既定も style も無い", none, "#ffffeb", gateHint{}, "no-entry"},
		{"既定の画風の色", def, "#ffffeb", gateHint{}, ""},
		{"既定の画風の外", def, "#123456", gateHint{}, "outside"},
		{"spec の style が先", def, "#123456", gateHint{Style: "night"}, ""},
		{"spec の style の外", none, "#ffffeb", gateHint{Style: "night"}, "outside"},
	} {
		if got := kinds(tc.g, tc.hex, tc.hint); got != tc.want {
			t.Errorf("%s: got %q want %q", tc.name, got, tc.want)
		}
	}
}
