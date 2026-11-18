package gates

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/precommit"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// 前提のファイル（# Not a target:）・パターン・変数の行は口として拾わない。
func TestParseTargetsKeepsOnlyExplicitTargets(t *testing.T) {
	db := "lint: sync\n# Not a target:\nrender_gl/java/A.java:\nfoo := a:b\ntest-%:\nbuild/x.jar: y\n"
	got := ParseTargets(db)
	if !got["lint"] || !got["build/x.jar"] || got["render_gl/java/A.java"] || got["foo"] || got["test-%"] || len(got) != 2 {
		t.Errorf("got %v", got)
	}
}

// 呼んだ make のコマンド行の変数（MAKEFLAGS など）は子の make へ持ち込まない。
func TestMakeEnvDropsMakeflags(t *testing.T) {
	got := makeEnv([]string{"PATH=/bin", "MAKEFLAGS=ONLY=x", "MFLAGS=-s", "MAKELEVEL=1", "MAKEOVERRIDES=ONLY=x", "HOME=/h"})
	if strings.Join(got, " ") != "PATH=/bin HOME=/h" {
		t.Errorf("got %v", got)
	}
}

// vars は名前の順に K=V で並び、ARGS の物は後ろに付く。
func TestMakeLineOrdersVarsAndAppendsExtra(t *testing.T) {
	g := Gate{Make: "test", Vars: map[string]string{"JOBS": "6", "ALL": "1"}}
	if got := strings.Join(g.MakeLine([]string{"STUDIO=none"}), " "); got != "make test ALL=1 JOBS=6 STUDIO=none" {
		t.Errorf("got %q", got)
	}
}

// input の無い門はどの変更でも当たり、input のある門は当たるパスがある時だけ。
func TestHitsWithAndWithoutInput(t *testing.T) {
	everything := Gate{}
	only := Gate{Input: &precommit.Matcher{Prefixes: []string{"go/"}}}
	if !everything.Hits([]string{"README.md"}) || only.Hits([]string{"README.md"}) || !only.Hits([]string{"README.md", "go/main.go"}) {
		t.Error("当たり方が違う")
	}
}

func baseFacts() *Facts {
	return &Facts{
		TestPkgs: []string{"engine"}, LintNames: []string{"forbid"}, DocsSyncNames: []string{"rules"},
		ReleaseGates: []string{"sync"}, HelpSuites: "test|affected", Targets: map[string]bool{"sync": true, "check-docs-sync": true, "lint": true},
	}
}

func baseFile() *File {
	return &File{
		Runs: map[string]string{"release": "", "manual": "", "precommit": ""},
		Gates: []Gate{
			{ID: "sync", Make: "sync", Runs: []string{"release"}},
			{ID: "test-engine", Make: "test-engine", Runs: []string{"manual"}},
			{ID: "docs-sync:rules", Make: "check-docs-sync", Vars: map[string]string{"ONLY": "rules"},
				Input: &precommit.Matcher{Prefixes: []string{"docs/"}}, Samples: []string{"docs/x.md"}, Runs: []string{"precommit"}},
		},
		Suites: []Suite{{Name: "test", Gates: []string{"sync", "test-engine"}}, {Name: "affected", Fallback: "test"}},
	}
}

// 揃っている表では何も言わない。
func TestCheckAcceptsAConsistentFile(t *testing.T) {
	if errs := Check(repoRoot(t), baseFile(), baseFacts()); len(errs) != 0 {
		t.Errorf("errs = %v", errs)
	}
}

// Makefile に無い口・門の無いテストのパッケージ・RELEASE_GATES との食い違い・コミットで流れない見本を並べる。
func TestCheckReportsEachMismatch(t *testing.T) {
	f := baseFile()
	f.Gates[0].Make = "sinc"
	f.Gates[1].Make = "test-enigne"
	f.Gates[2].Samples = []string{"docs/x.md", "docs/y.txt"}
	f.Gates[2].Input = &precommit.Matcher{Prefixes: []string{"docs/"}}
	facts := baseFacts()
	facts.HelpSuites = "test"
	errs := strings.Join(Check(repoRoot(t), f, facts), "\n")
	for _, want := range []string{"make の口 sinc が Makefile にありません", "make の口 test-enigne が Makefile にありません",
		"テストのパッケージ engine に test-engine の門がありません", "RELEASE_GATES", "見本 docs/y.txt が precommit.json の docsSync の when に当たらず", "##> make verify SUITE="} {
		if !strings.Contains(errs, want) {
			t.Errorf("%q が出ていない:\n%s", want, errs)
		}
	}
}

// 本物の gates.json は本物の precommit.json と矛盾しない（Makefile を起こさない部分だけ）。
func TestRealGatesJSONLoadsAndMergesPrecommitChecks(t *testing.T) {
	root := repoRoot(t)
	f, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	all, err := All(root, f)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := FindGate(all, "precommit:forbid"); !ok {
		t.Error("precommit.json の forbid が一覧に混ざっていない")
	}
	for _, s := range f.Suites {
		if _, _, err := Resolve(f, all, s.Name); err != nil {
			t.Errorf("suite %s: %v", s.Name, err)
		}
	}
}

// fallback の suite は代わりの suite の門を流し、そう言う 1 行を出す。
func TestResolveFollowsFallback(t *testing.T) {
	f := baseFile()
	gates, note, err := Resolve(f, f.Gates, "affected")
	if err != nil || len(gates) != 2 || !strings.Contains(note, "代わりに test") {
		t.Errorf("gates=%v note=%q err=%v", gates, note, err)
	}
}

type fakeExec struct {
	codes map[string]int
	sig   string
	ran   []string
}

func (f *fakeExec) run(line []string) (int, bool) {
	f.ran = append(f.ran, line[1])
	if line[1] == f.sig {
		return 130, true
	}
	return f.codes[line[1]], false
}

func runWith(fe *fakeExec, gates []Gate) (int, string) {
	var out strings.Builder
	r := &Runner{Out: &out, Err: &out, Exec: fe.run}
	return r.Run(gates, "", nil, false), out.String()
}

// 赤でも次の門へ進み、最後に赤を並べて 1。
func TestRunContinuesAfterARedGate(t *testing.T) {
	fe := &fakeExec{codes: map[string]int{"a": 2}}
	code, out := runWith(fe, []Gate{{ID: "a", Make: "a"}, {ID: "b", Make: "b"}})
	if code != 1 || len(fe.ran) != 2 || !strings.Contains(out, "赤: a") {
		t.Errorf("code=%d ran=%v out=%s", code, fe.ran, out)
	}
}

// 前提の門が赤なら後ろを流さない。
func TestRunStopsAfterARedPrereq(t *testing.T) {
	fe := &fakeExec{codes: map[string]int{"a": 2}}
	code, _ := runWith(fe, []Gate{{ID: "a", Make: "a", Prereq: true}, {ID: "b", Make: "b"}})
	if code != 1 || len(fe.ran) != 1 {
		t.Errorf("code=%d ran=%v", code, fe.ran)
	}
}

// 子が signal で止まったら残りを流さず 130。
func TestRunStopsWhenAGateIsInterrupted(t *testing.T) {
	fe := &fakeExec{sig: "a"}
	code, _ := runWith(fe, []Gate{{ID: "a", Make: "a"}, {ID: "b", Make: "b"}})
	if code != 130 || len(fe.ran) != 1 {
		t.Errorf("code=%d ran=%v", code, fe.ran)
	}
}

// --dry-run は make の行を並べるだけで流さない。
func TestRunDryRunOnlyPrintsLines(t *testing.T) {
	fe := &fakeExec{}
	var out strings.Builder
	r := &Runner{Out: &out, Err: &out, Exec: fe.run}
	code := r.Run([]Gate{{ID: "a", Make: "a", Vars: map[string]string{"ONLY": "x"}}}, "", []string{"K=V"}, true)
	if code != 0 || len(fe.ran) != 0 || out.String() != "make a ONLY=x K=V\n" {
		t.Errorf("code=%d ran=%v out=%q", code, fe.ran, out.String())
	}
}

// make help の 1 行から suite の名前の並びを拾う。
func TestHelpSuitesReadsTheHelpLine(t *testing.T) {
	if got := HelpSuites("x\n##> make verify SUITE=quick|test | 説明\n"); got != "quick|test" {
		t.Errorf("got %q", got)
	}
}
