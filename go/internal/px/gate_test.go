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
	gate, err := LoadColorGate(root, "art/internet_dungeon.colorgate.json")
	if err != nil {
		t.Fatal(err)
	}
	for path, want := range expected {
		doc, err := pxlib.ReadOrdered(filepath.Join(root, path))
		if err != nil {
			t.Fatal(err)
		}
		slot := filepath.Base(path)
		bad, known := gate.CheckDoc(root, doc, slot)
		got := [][3]string{}
		for _, b := range bad {
			got = append(got, [3]string{b.Sprite, b.Key, b.Kind})
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
	rep, err := CheckFiles(engineRoot, "testdata/gate", "", []string{"assets/internet_dungeon.day.sprite.json", "neg/internet_dungeon.day.sprite.json"})
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
	_, err := LoadColorGate(dir, "g.json")
	if err == nil {
		t.Fatal("通ってしまった")
	}
	for _, want := range []string{"files.a.sprite.json.style", "files.a.sprite.json.allow[0].why"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("%q が誤りに無い: %v", want, err)
		}
	}
}
