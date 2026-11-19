// Package gates は engine のリポの門（テスト・検査の make の口）の一覧（根の gates.json）を読み、
// 一覧・当たる門・流し方（suite）・Makefile との食い違いを扱う。
//
//	fge-go gates                      一覧（precommit.json と hooks.json の分も混ぜる）
//	fge-go gates --files <パス…>      当たる門だけ（流さない）
//	fge-go gates --suites             流し方の一覧
//	fge-go gates --suite <名前> [--dry-run] [-- <K=V…>]  流し方の門を順に make で流す
//	fge-go gates --check              gates.json と Makefile の食い違い
package gates

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
	"github.com/ababup1192/flix_game_engine/go/internal/precommit"
)

// RulesPath は一覧の置き場（engine のリポの根からの相対）。
// WhyNot: bin/lint-rules/ に置かない — あのフォルダはゲームと Studio の同梱へ丸ごと配られ、engine の Makefile の口の表を持ち込む。
const RulesPath = "gates.json"

// Gate は門 1 つ。
type Gate struct {
	ID      string             `json:"id"`
	About   string             `json:"about"`
	Make    string             `json:"make"`
	Cmd     string             `json:"cmd"`
	Vars    map[string]string  `json:"vars"`
	Input   *precommit.Matcher `json:"input"`
	Samples []string           `json:"samples"`
	Runs    []string           `json:"runs"`
	Time    string             `json:"time"`
	Prereq  bool               `json:"prereq"`
	// Select は bin/fge test-select の扱い（always・code・never・hold・package。省けば input か packages で選ぶ）。
	Select string `json:"select"`
	// Hold は select が hold の門を流さない理由。
	Hold string `json:"hold"`
	// GUI は画面（隠しウィンドウを含む）を開く門。test-select は --gui の時だけ流す並びに入れる。
	GUI bool `json:"gui"`
	// DocsInput はこの門が読む .md（.md の差は input でなくこれで当てる）。
	DocsInput *precommit.Matcher `json:"docsInput"`
	// Covers はこの門が中身を全部流す、ほかの門の id の頭。
	Covers []string `json:"covers"`
	// From は読んだファイル（gates.json・precommit.json・hooks.json）。JSON には書かない。
	From string `json:"-"`
}

// Suite は流し方 1 つ（make verify SUITE=<名前>）。
type Suite struct {
	Name     string   `json:"name"`
	About    string   `json:"about"`
	Gates    []string `json:"gates"`
	Fallback string   `json:"fallback"`
	// Select は bin/fge test-select の答えを流す suite（make verify SUITE=affected）。
	Select bool `json:"select"`
}

// Package はパッケージの表の 1 件（test-select の「ファイル → パッケージ」と「下流」の正）。
type Package struct {
	ID    string             `json:"id"`
	About string             `json:"about"`
	Dir   string             `json:"dir"`
	Local *precommit.Matcher `json:"local"`
	Reads *precommit.Matcher `json:"reads"`
	Feeds []string           `json:"feeds"`
	Test  bool               `json:"test"`
	Check bool               `json:"check"`
	Gates []string           `json:"gates"`
}

// GoRow は go の表の 1 行（go/ の下のファイル → 足す門）。
type GoRow struct {
	About string            `json:"about"`
	Input precommit.Matcher `json:"input"`
	Gates []string          `json:"gates"`
	// Tests はテストを足すパッケージ（packages の id）。
	Tests []string `json:"tests"`
}

// GoRead は go のテストが読む go/ の外の物 → その go のパッケージ（* は全部）。
type GoRead struct {
	About string            `json:"about"`
	Reads precommit.Matcher `json:"reads"`
	Docs  bool              `json:"docs"`
	Pkgs  []string          `json:"pkgs"`
}

// File は gates.json の中身。
type File struct {
	Note   string            `json:"note"`
	Runs   map[string]string `json:"runs"`
	Gates  []Gate            `json:"gates"`
	Suites []Suite           `json:"suites"`

	Packages []Package         `json:"packages"`
	Go       []GoRow           `json:"go"`
	GoReads  []GoRead          `json:"goReads"`
	Wiring   precommit.Matcher `json:"wiring"`
	Inert    precommit.Matcher `json:"inert"`
}

// Load は gates.json を読む。無ければ os.ErrNotExist を包んで返す。
func Load(root string) (*File, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f File
	// 知らないキー（prereq の綴りの誤りなど）を黙って通さない。
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&f); err != nil {
		return nil, fmt.Errorf("%s が JSON として壊れています: %v", path, err)
	}
	for i := range f.Gates {
		f.Gates[i].From = RulesPath
	}
	return &f, nil
}

// MakeLine は門を流す make の行（make が無い門は空）。vars は名前の順。
func (g Gate) MakeLine(extra []string) []string {
	if g.Make == "" {
		return nil
	}
	line := []string{"make", g.Make}
	keys := make([]string, 0, len(g.Vars))
	for k := range g.Vars {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		line = append(line, k+"="+g.Vars[k])
	}
	return append(line, extra...)
}

// Display は一覧に出す打ち方（空白を含む値は '' で包む）。
func (g Gate) Display() string {
	if l := g.MakeLine(nil); l != nil {
		return ShellLine(l)
	}
	return g.Cmd
}

// ShellLine は make の行をシェルへ貼れる形にする（空白を含む語は '' で包む）。
func ShellLine(line []string) string {
	parts := make([]string, len(line))
	for i, w := range line {
		if k, v, ok := strings.Cut(w, "="); ok && strings.ContainsAny(v, " \t") {
			w = k + "='" + v + "'"
		}
		parts[i] = w
	}
	return strings.Join(parts, " ")
}

// Hits は門が paths のどれかに当たるか（input が無い門はどの変更でも当たる）。
// select が package・go の門は input でなく packages と go の表で選ぶので、ここでは当たらない（bin/fge test-select が引く）。
func (g Gate) Hits(paths []string) bool {
	if g.Select == "package" || g.Select == "go" {
		return false
	}
	if g.Input == nil {
		return true
	}
	for _, p := range paths {
		if g.Input.Match(p) {
			return true
		}
	}
	return false
}

// All は gates.json の門に、precommit.json（checks・docsSync・localGate）と hooks.json（artEdit）の門を足した物。
// WhyNot: precommit と hook の検査を gates.json に書き写さない — precommit.json と hooks.json はゲームへ配られてゲームでも走る正で、
// 写しを持つと片方だけ直して食い違う。
func All(root string, f *File) ([]Gate, error) {
	out := append([]Gate{}, f.Gates...)
	pr, err := precommit.LoadRules(root)
	if err != nil {
		return nil, err
	}
	for _, c := range pr.Checks {
		when := c.When
		cmd := strings.TrimSpace("bin/fge " + c.Sub + " " + strings.Join(c.Flags, " ") + " <ステージした物>")
		out = append(out, Gate{ID: "precommit:" + c.ID, About: "コミットの時の検査（bin/fge " + c.Sub + "）", Cmd: cmd,
			Input: &when, Runs: []string{"precommit"}, Time: "0.1s", From: precommit.RulesPath})
	}
	when := pr.DocsSync.When
	out = append(out, Gate{ID: "precommit:docs-sync", About: "コミットの時の配線の検査（全部）", Make: pr.DocsSync.Target,
		Input: &when, Runs: []string{"precommit"}, Time: "1s", From: precommit.RulesPath})
	if pr.LocalGate.Target != "" {
		out = append(out, Gate{ID: "precommit:local", About: "コミットの時の engine の門（engine では gl-jar-pin-check・写しの検査・触ったテンプレートの lint/rules.flix）", Make: pr.LocalGate.Target,
			Runs: []string{"precommit"}, Time: "1〜5s", From: precommit.RulesPath})
	}
	hr, err := hooks.LoadRules(root)
	if err != nil {
		return nil, err
	}
	for _, c := range hr.ArtEdit.Checks {
		in := precommit.Matcher{Suffixes: []string{c.Suffix}}
		out = append(out, Gate{ID: "hook:" + c.Sub + ":" + strings.TrimPrefix(c.Suffix, "."), About: "書いた直後の検査（bin/fge " + c.Sub + "）",
			Cmd: "bin/fge " + c.Sub + " <書いたファイル>", Input: &in, Runs: []string{"hook"}, Time: "0.1s", From: hooks.RulesPath})
	}
	return out, nil
}

// FindSuite は名前の suite。
func (f *File) FindSuite(name string) (Suite, bool) {
	for _, s := range f.Suites {
		if s.Name == name {
			return s, true
		}
	}
	return Suite{}, false
}

// FindGate は id の門。
func FindGate(all []Gate, id string) (Gate, bool) {
	for _, g := range all {
		if g.ID == id {
			return g, true
		}
	}
	return Gate{}, false
}
