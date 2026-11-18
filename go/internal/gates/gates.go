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
	// From は読んだファイル（gates.json・precommit.json・hooks.json）。JSON には書かない。
	From string `json:"-"`
}

// Suite は流し方 1 つ（make verify SUITE=<名前>）。
type Suite struct {
	Name     string   `json:"name"`
	About    string   `json:"about"`
	Gates    []string `json:"gates"`
	Fallback string   `json:"fallback"`
}

// File は gates.json の中身。
type File struct {
	Note   string            `json:"note"`
	Runs   map[string]string `json:"runs"`
	Gates  []Gate            `json:"gates"`
	Suites []Suite           `json:"suites"`
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

// Display は一覧に出す打ち方。
func (g Gate) Display() string {
	if l := g.MakeLine(nil); l != nil {
		return strings.Join(l, " ")
	}
	return g.Cmd
}

// Hits は門が paths のどれかに当たるか（input が無い門はどの変更でも当たる）。
func (g Gate) Hits(paths []string) bool {
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
		out = append(out, Gate{ID: "precommit:local", About: "コミットの時の engine の門", Make: pr.LocalGate.Target,
			Runs: []string{"precommit"}, Time: "1s", From: precommit.RulesPath})
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
