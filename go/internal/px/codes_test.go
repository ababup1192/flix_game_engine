package px

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

// 違反は newViolation の 1 か所で組み立てる（got と want を必ず持たせる。px-vs など新しい検査もここを通す）。
func TestViolationsAreBuiltInOnePlace(t *testing.T) {
	files, _ := filepath.Glob("*.go")
	lit := regexp.MustCompile(`\bviolation\{[A-Z]`)
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		data, _ := os.ReadFile(f)
		for i, line := range strings.Split(string(data), "\n") {
			if lit.MatchString(line) && !strings.Contains(line, "return violation{Check: check, Level: lv, Got: got, Want: want, Msg: msg}") {
				t.Errorf("%s:%d: violation{…} を直に書いている（newViolation で組み立てる）", f, i+1)
			}
		}
	}
}

// 表の px の code の検査は登録した検査にある（gate を除く）。登録した検査は表に 1 つ以上の code を持つ。
func TestCodeTableMatchesChecks(t *testing.T) {
	has := map[checkName]bool{}
	for _, c := range checkres.All("px.") {
		name := strings.SplitN(strings.TrimPrefix(c.Name, "px."), ".", 2)[0]
		has[checkName(name)] = true
		if _, ok := checks[checkName(name)]; !ok && checkName(name) != checkGate {
			t.Errorf("表の %s の検査 %q が登録に無い", c.Name, name)
		}
	}
	for name := range checks {
		if !has[name] {
			t.Errorf("検査 %q の code が表に無い（codes.go の pxCodes に足す）", name)
		}
	}
}

// testdata の絵を描いて出た違反は、どれも表にある code で、基準の向きが表と同じ（New が panic しない）・got と want を持つ。
func TestEveryResultHasCodeGotWant(t *testing.T) {
	rules, err := checkres.LoadRules(engineRoot)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, tc := range []struct{ dir, spec string }{{"puzzle", "puzzle.pxsrc.json"}, {"relic", "relic.pxsrc.json"}} {
		root := copyTree(t, filepath.Join("testdata", tc.dir))
		res, err := build(root, filepath.Join("art", tc.spec), buildOptions{RulesRoot: engineRoot})
		if err != nil {
			t.Fatal(err)
		}
		for _, v := range res.Violations {
			r := v.result(rules)
			seen[r.Code] = true
			if r.Want.Op == "" || r.Metric == "" || r.Unit == "" || r.Status == checkres.Pass {
				t.Errorf("%s: want・metric・unit・status が足りない: %+v", r.Code, r)
			}
		}
		if res.Check == nil || res.Check.Summary.Applied == nil {
			t.Errorf("%s: まとめに applied が無い", tc.dir)
		}
	}
	t.Logf("testdata で出た code: %d 種", len(seen))
}

// --no-check は周の外: probe に書き、last の report.json を触らない。
func TestNoCheckWritesProbe(t *testing.T) {
	root := copyTree(t, filepath.Join("testdata", "relic"))
	res, err := build(root, filepath.Join("art", "relic.pxsrc.json"), buildOptions{RulesRoot: engineRoot, NoCheck: true})
	if err != nil {
		t.Fatal(err)
	}
	if res.Check.Summary.Round {
		t.Error("--no-check の round が true")
	}
	if _, err := os.Stat(filepath.Join(root, "debug", "px", "relic", "last", "report.json")); err == nil {
		t.Error("--no-check が last に書いた")
	}
	if _, err := os.Stat(filepath.Join(root, "debug", "px", "relic", "probe", "report.json")); err != nil {
		t.Error("--no-check が probe に書いていない")
	}
}
