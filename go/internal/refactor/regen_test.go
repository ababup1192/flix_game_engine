package refactor

// testdata の索引（*-spans-*.tsv）を、一覧 testdata/regen.json のとおり flixlint で作り直す口。
//
//	go test ./internal/refactor -run TestRegenIndex -regen-index <bin/flixlint> [-regen-check] [-regen-resident]
//
// （make refactor-testdata FLIXLINT=<bin/flixlint> が同じ物）。-regen-check は書かずに今のファイルと比べ、違えば落ちる
// （2 回作って同じバイトか・常駐と 1 回きりの JVM で同じバイトかの確かめ）。-regen-resident は flixlint に --resident を付ける。
// 旗が無い時は、testdata の索引のファイルが全部一覧に載っているかだけを見る（一覧に無い索引は作り直せない）。
//
// WhyNot: fixture の中で流さない。flixlint の --build-dir や作業の跡が testdata に残り、次の索引の元に混ざる。
// 写しの根で流しても索引の file の列は根からの相対（src/…）なので同じになる。

import (
	"bytes"
	"encoding/json"
	"flag"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var (
	regenIndex    = flag.String("regen-index", "", "testdata の索引を testdata/regen.json のとおりこの flixlint で作り直す")
	regenCheck    = flag.Bool("regen-check", false, "-regen-index で作った索引を書かずに今のファイルと比べる")
	regenResident = flag.Bool("regen-resident", false, "-regen-index の flixlint に --resident を付ける")
)

type regenEntry struct {
	Index   string   `json:"index"`
	Dir     string   `json:"dir"`
	Stage   Stage    `json:"stage"`
	Sources []string `json:"sources"`
	How     string   `json:"how"`
}

type regenList struct {
	Flixlint string       `json:"flixlint"`
	Indexes  []regenEntry `json:"indexes"`
	Steps    []regenEntry `json:"steps"`
}

func readRegenList(t *testing.T) (regenList, []byte) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "regen.json"))
	if err != nil {
		t.Fatal(err)
	}
	var l regenList
	if err := json.Unmarshal(data, &l); err != nil {
		t.Fatal(err)
	}
	return l, data
}

func TestRegenListNamesEveryIndex(t *testing.T) {
	l, _ := readRegenList(t)
	listed := map[string]bool{}
	for _, e := range append(append([]regenEntry{}, l.Indexes...), l.Steps...) {
		listed[e.Index] = true
	}
	for _, e := range l.Indexes {
		if info, err := os.Stat(filepath.Join("testdata", e.Dir, "flix.toml")); err != nil || info.IsDir() {
			t.Errorf("%s の元 testdata/%s に flix.toml が無い（作り直せない）", e.Index, e.Dir)
		}
	}
	files, _ := filepath.Glob(filepath.Join("testdata", "*.tsv*"))
	for _, f := range files {
		if !listed[filepath.Base(f)] {
			t.Errorf("%s が testdata/regen.json に無い（作り直せない索引を置かない）", f)
		}
	}
}

func TestRegenIndex(t *testing.T) {
	if *regenIndex == "" {
		t.Skip("-regen-index <bin/flixlint> の時だけ")
	}
	flixlint, err := filepath.Abs(*regenIndex)
	if err != nil {
		t.Fatal(err)
	}
	l, raw := readRegenList(t)
	for _, e := range l.Indexes {
		got := regenOne(t, flixlint, e)
		path := filepath.Join("testdata", e.Index)
		if *regenCheck {
			if want, err := os.ReadFile(path); err != nil || !bytes.Equal(got, want) {
				t.Errorf("%s: 作り直した索引が今のファイルと違う", e.Index)
			}
			continue
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if *regenCheck {
		return
	}
	if v := strings.Fields(flixlintVersion(flixlint)); len(v) > 0 {
		re := regexp.MustCompile(`"flixlint": "[^"]*"`)
		out := re.ReplaceAll(raw, []byte(`"flixlint": "`+v[len(v)-1]+`"`))
		if err := os.WriteFile(filepath.Join("testdata", "regen.json"), out, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// regenOne は e の fixture を写した根で flixlint --spans を流し、書いた索引を返す。
func regenOne(t *testing.T, flixlint string, e regenEntry) []byte {
	t.Helper()
	root := filepath.Join(t.TempDir(), e.Dir)
	if err := copyTree(filepath.Join("testdata", e.Dir), root); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(t.TempDir(), "spans.tsv")
	args := []string{}
	if *regenResident {
		// 常駐は根ごとに 1 本なので、写しの根ごとに立つ。すぐ畳む。
		args = append(args, "--resident", "--idle-minutes", "1")
	}
	args = append(args, "--spans", out, "--stage", string(e.Stage), "--build-dir", filepath.Join(t.TempDir(), "build"))
	cmd := exec.Command(flixlint, append(args, e.Sources...)...)
	cmd.Dir = root
	if msg, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s: flixlint が落ちた: %v\n%s", e.Index, err, msg)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func copyTree(from, to string) error {
	return filepath.WalkDir(from, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(from, p)
		dst := filepath.Join(to, rel)
		if d.IsDir() {
			return os.MkdirAll(dst, 0o755)
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(dst, data, 0o644)
	})
}
