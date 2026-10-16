package proposal

// 何を守るか: ページが bin/proposal.py（Python 版）の書き出しとバイトまで同じであること
// （testdata/*/want.html は Python 版が書いた物）、壊れた manifest を同じ言葉で止めること、
// 決定済みのつまみが Doc に残っていれば数えること。

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func buildIn(t *testing.T, name string) (string, int) {
	t.Helper()
	dir := t.TempDir()
	data, err := os.ReadFile(filepath.Join("testdata", name, "proposal.json"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "proposal.json")
	os.WriteFile(path, data, 0o644)
	var errOut strings.Builder
	code := Build(path, io.Discard, &errOut)
	html, _ := os.ReadFile(filepath.Join(dir, "index.html"))
	if code == 2 {
		return errOut.String(), code
	}
	return string(html), code
}

func TestPageMatchesPythonOutput(t *testing.T) {
	for _, name := range []string{"full", "decided", "plain", "tut"} {
		t.Run(name, func(t *testing.T) {
			got, _ := buildIn(t, name)
			want, err := os.ReadFile(filepath.Join("testdata", name, "want.html"))
			if err != nil {
				t.Fatal(err)
			}
			if got != string(want) {
				i := 0
				for i < len(got) && i < len(want) && got[i] == want[i] {
					i++
				}
				t.Fatalf("Python 版と %d バイト目から違う:\n got: %.120q\nwant: %.120q", i, got[i:], string(want[i:]))
			}
		})
	}
}

func TestMissingMediaIsReported(t *testing.T) {
	if _, code := buildIn(t, "full"); code != 1 {
		t.Fatalf("素材が無いのに %d で終わった", code)
	}
}

func TestBrokenManifestStopsWithSameMessages(t *testing.T) {
	got, code := buildIn(t, "broken")
	want, _ := os.ReadFile(filepath.Join("testdata", "broken", "want.txt"))
	var lines []string
	for _, l := range strings.Split(strings.TrimSpace(got), "\n") {
		if i := strings.Index(l, "proposal.json: "); i >= 0 {
			l = l[i+len("proposal.json: "):]
		}
		lines = append(lines, l)
	}
	if code != 2 || strings.Join(lines, "\n") != strings.TrimSpace(string(want)) {
		t.Fatalf("止め方が Python 版と違う (code %d):\n%s", code, got)
	}
}

func TestKnobsCountsLeftoverDocKey(t *testing.T) {
	top := t.TempDir()
	os.MkdirAll(filepath.Join(top, "assets"), 0o755)
	os.MkdirAll(filepath.Join(top, "src"), 0o755)
	os.WriteFile(filepath.Join(top, "assets", "x.json"), []byte(`{"a": {"b": "cut"}}`), 0o644)
	os.WriteFile(filepath.Join(top, "src", "X.flix"), []byte(`case "slow" => 1`), 0o644)
	manifest := filepath.Join(top, "proposal.json")
	os.WriteFile(manifest, []byte(`{"sections": [{"id": "A", "knob": {"doc": "assets/x.json", "path": "a.b"},
	  "options": [{"id": "A1", "value": "cut"}, {"id": "A2", "value": "slow"}]}],
	  "decision": {"picks": {"A": "A1"}}}`), 0o644)
	wd, _ := os.Getwd()
	defer os.Chdir(wd)
	os.Chdir(top)
	var out strings.Builder
	if code := Knobs([]string{manifest}, &out, io.Discard); code != 1 || !strings.Contains(out.String(), "残っている片付け: 2") {
		t.Fatalf("Doc のつまみと src の読み替えの 2 件を数えない (code %d):\n%s", code, out.String())
	}
}
