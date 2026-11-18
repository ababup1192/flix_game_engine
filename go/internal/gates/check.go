package gates

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/precommit"
)

// Facts は Makefile から受け取る値（make -s gates-facts の 1 行 1 つ）。
type Facts struct {
	TestPkgs      []string
	LintNames     []string
	DocsSyncNames []string
	ReleaseGates  []string
	// HelpSuites は make help に出す suite の名前の並び（a|b|…）。
	HelpSuites string
	// Targets は Makefile の明示の口（make -pRrq : のデータベースから。前提のファイルとパターンは外す）。
	Targets map[string]bool
}

// makeEnv は子の make の環境。呼んだ make のコマンド行の変数を子へ持ち込まない（make verify SUITE=quick ONLY=x の ONLY が
// lint へ届くなど）。make verify 自身の変数（SUITE・DRY・ARGS）も外す。
// WhyNot: MAKEFLAGS を外すだけにしない — make はコマンド行の変数を MAKEFLAGS に入れるだけでなく、子の環境変数にも書き出す。
// MAKEFLAGS の中の K=V から名前を拾い、その名前の環境変数も外す。
func makeEnv(env []string) []string {
	drop := map[string]bool{"MAKEFLAGS": true, "MFLAGS": true, "MAKELEVEL": true, "MAKEOVERRIDES": true,
		"SUITE": true, "DRY": true, "ARGS": true}
	for _, kv := range env {
		if name, val, _ := strings.Cut(kv, "="); name == "MAKEFLAGS" {
			for _, n := range commandLineVars(val) {
				drop[n] = true
			}
		}
	}
	var out []string
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if !drop[name] {
			out = append(out, kv)
		}
	}
	return out
}

var varName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// commandLineVars は MAKEFLAGS（例「s -- ONLY=x JOBS=3」）の中のコマンド行の変数の名前。値の中の空白は make が \ で逃がす。
func commandLineVars(makeflags string) []string {
	var names []string
	for _, w := range strings.Fields(strings.ReplaceAll(makeflags, `\ `, "\x00")) {
		if name, _, ok := strings.Cut(w, "="); ok && varName.MatchString(name) {
			names = append(names, name)
		}
	}
	return names
}

// LoadFacts は Makefile から値を受け取る。
// WhyNot: 口の有無を make -q <口> で見ない — test-% のパターンで綴りの誤りも「在る」になり、$(MAKE) を含むレシピの行は -q でも走る。
func LoadFacts(root string, env []string) (*Facts, error) {
	cmd := exec.Command("make", "-s", "--no-print-directory", "gates-facts")
	cmd.Dir = root
	cmd.Env = makeEnv(env)
	body, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("make gates-facts が失敗しました: %v", err)
	}
	f := &Facts{}
	for _, line := range strings.Split(string(body), "\n") {
		key, rest, _ := strings.Cut(strings.TrimSpace(line), " ")
		words := strings.Fields(rest)
		switch key {
		case "test-pkgs":
			f.TestPkgs = words
		case "lint-names":
			f.LintNames = words
		case "docs-sync-names":
			f.DocsSyncNames = words
		case "release-gates":
			f.ReleaseGates = words
		}
	}
	db := exec.Command("make", "-pRrq", ":")
	db.Dir = root
	db.Env = makeEnv(env)
	out, _ := db.Output() // -q は「最新でない」で 1 を返す。中身だけ使う。
	f.Targets = ParseTargets(string(out))
	if len(f.Targets) == 0 {
		return nil, fmt.Errorf("make -pRrq : から口を 1 つも読めませんでした")
	}
	mk, err := os.ReadFile(filepath.Join(root, "Makefile"))
	if err != nil {
		return nil, err
	}
	f.HelpSuites = HelpSuites(string(mk))
	return f, nil
}

var helpSuitesLine = regexp.MustCompile(`(?m)^##> make verify SUITE=(\S+)`)

// HelpSuites は make help に出す「##> make verify SUITE=a|b|…」の名前の並び（無ければ空）。
// WhyNot: 名前を Makefile の変数から組まない — help.awk は Makefile の字をそのまま読むので、変数は展開されない。
func HelpSuites(makefile string) string {
	if m := helpSuitesLine.FindStringSubmatch(makefile); m != nil {
		return m[1]
	}
	return ""
}

var targetLine = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9_./-]*):`)

// ParseTargets は make -p のデータベースから明示の口の名前を拾う。直前の行が「# Not a target:」の物（前提のファイル）と、
// % を含むパターンと、変数の行（:=）は外す。
func ParseTargets(db string) map[string]bool {
	out := map[string]bool{}
	prev := ""
	sc := bufio.NewScanner(strings.NewReader(db))
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if prev != "# Not a target:" && !strings.Contains(line, ":=") {
			if m := targetLine.FindStringSubmatch(line); m != nil {
				out[m[1]] = true
			}
		}
		prev = line
	}
	return out
}

// Check は gates.json と Makefile・precommit.json の食い違いを並べる（空なら揃っている）。
func Check(root string, f *File, facts *Facts) []string {
	var errs []string
	add := func(format string, a ...any) { errs = append(errs, fmt.Sprintf(format, a...)) }

	ids := map[string]bool{}
	testPkg := map[string]bool{}
	for _, p := range facts.TestPkgs {
		testPkg[p] = true
	}
	pr, err := precommit.LoadRules(root)
	if err != nil {
		return []string{err.Error()}
	}
	precommitIDs := map[string]bool{}
	for _, c := range pr.Checks {
		precommitIDs[c.ID] = true
		precommitIDs[c.Sub] = true
	}
	inList := func(list []string, s string) bool {
		for _, x := range list {
			if x == s {
				return true
			}
		}
		return false
	}
	var releaseMakes []string
	testGates := map[string]bool{}
	for _, g := range f.Gates {
		if g.ID == "" {
			add("id の無い門があります（about: %s）", g.About)
			continue
		}
		if ids[g.ID] {
			add("%s: id が 2 回あります", g.ID)
		}
		ids[g.ID] = true
		if precommitIDs[g.ID] {
			add("%s: precommit.json の checks にあるので gates.json に書かない（bin/fge gates が読み込む）", g.ID)
		}
		if (g.Make == "") == (g.Cmd == "") {
			add("%s: make か cmd のどちらか 1 つを書く", g.ID)
		}
		if len(g.Runs) == 0 {
			add("%s: runs がありません", g.ID)
		}
		for _, r := range g.Runs {
			if _, ok := f.Runs[r]; !ok {
				add("%s: runs の %s は runs の表にありません", g.ID, r)
			}
		}
		if g.Make != "" {
			pkg, isTest := strings.CutPrefix(g.Make, "test-")
			switch {
			case isTest && testPkg[pkg]:
				testGates[pkg] = true
			case !facts.Targets[g.Make]:
				add("%s: make の口 %s が Makefile にありません", g.ID, g.Make)
			}
		}
		if only, ok := g.Vars["ONLY"]; ok {
			switch g.Make {
			case "lint":
				if !inList(facts.LintNames, only) {
					add("%s: ONLY=%s は make lint の名前にありません", g.ID, only)
				}
			case "check-docs-sync":
				if !inList(facts.DocsSyncNames, only) {
					add("%s: ONLY=%s は check-docs-sync の名前にありません", g.ID, only)
				}
			}
		}
		if inList(g.Runs, "release") {
			releaseMakes = append(releaseMakes, g.Make)
		}
		if strings.HasPrefix(g.ID, "docs-sync:") {
			if len(g.Samples) == 0 {
				add("%s: samples（見本のパス）がありません", g.ID)
			}
			for _, s := range g.Samples {
				if g.Input != nil && !g.Input.Match(s) {
					add("%s: 見本 %s が自分の input に当たりません", g.ID, s)
				}
				if !pr.DocsSync.When.Match(s) {
					add("%s: 見本 %s が precommit.json の docsSync の when に当たらず、コミットで流れません", g.ID, s)
				}
			}
		}
	}
	for _, p := range facts.TestPkgs {
		if !testGates[p] {
			add("テストのパッケージ %s に test-%s の門がありません", p, p)
		}
	}
	for _, n := range facts.DocsSyncNames {
		if !ids["docs-sync:"+n] {
			add("check-docs-sync の %s に docs-sync:%s の門がありません", n, n)
		}
	}
	a := append([]string{}, releaseMakes...)
	b := append([]string{}, facts.ReleaseGates...)
	sort.Strings(a)
	sort.Strings(b)
	if strings.Join(a, " ") != strings.Join(b, " ") {
		add("runs に release を持つ門の make の口（%s）が Makefile の RELEASE_GATES（%s）と違います", strings.Join(a, " "), strings.Join(b, " "))
	}
	var names []string
	for _, s := range f.Suites {
		names = append(names, s.Name)
	}
	if help := strings.Join(names, "|"); facts.HelpSuites != help {
		add("Makefile の「##> make verify SUITE=…」の名前（%s）が gates.json の suites（%s）と違います", facts.HelpSuites, help)
	}
	all, err := All(root, f)
	if err != nil {
		return append(errs, err.Error())
	}
	for _, s := range f.Suites {
		if s.Fallback != "" {
			if _, ok := f.FindSuite(s.Fallback); !ok {
				add("suite %s: fallback の %s がありません", s.Name, s.Fallback)
			}
			continue
		}
		if len(s.Gates) == 0 {
			add("suite %s: gates も fallback もありません", s.Name)
		}
		for _, id := range s.Gates {
			g, ok := FindGate(all, id)
			switch {
			case !ok:
				add("suite %s: 門 %s がありません", s.Name, id)
			case g.Make == "":
				add("suite %s: 門 %s は make の口を持たないので流せません", s.Name, id)
			}
		}
	}
	return errs
}
