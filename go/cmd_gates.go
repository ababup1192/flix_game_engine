package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/gates"
)

func init() {
	registerEngineOnly("gates", "engine のリポの門の一覧（--files で当たる門・--suite で流す・--check で Makefile との食い違い）", cmdGates)
}

type gateRow struct {
	ID    string   `json:"id"`
	About string   `json:"about"`
	Run   string   `json:"run"`
	Runs  []string `json:"runs"`
	Time  string   `json:"time"`
	From  string   `json:"from"`
}

func rowsOf(list []gates.Gate) []gateRow {
	rows := []gateRow{}
	for _, g := range list {
		rows = append(rows, gateRow{g.ID, g.About, g.Display(), orEmpty(g.Runs), g.Time, g.From})
	}
	return rows
}

func writeRows(out *strings.Builder, list []gates.Gate) {
	for _, g := range list {
		fmt.Fprintf(out, "%-30s %-24s %-7s %s\n    %s\n", g.ID, strings.Join(g.Runs, ","), g.Time, g.Display(), g.About)
	}
}

// argAfter は flag の次の引数（無ければ空）。
func argAfter(args []string, flag string) string {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func cmdGates(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	root := repoRoot()
	f, err := gates.Load(root)
	if errors.Is(err, fs.ErrNotExist) {
		errOut.WriteString("[gates] gates.json がありません（engine のリポでだけ使う道具です）\n")
		return 2
	}
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	switch {
	case hasFlag(rest, "--check"):
		facts, err := gates.LoadFacts(root, os.Environ())
		if err != nil {
			return orAbort(errOut, 2, err)
		}
		errs := gates.Check(root, f, facts)
		for _, e := range errs {
			fmt.Fprintf(errOut, "[gates] NG: %s\n", e)
		}
		if len(errs) > 0 {
			errOut.WriteString("[gates] 直すのは根の gates.json（書き方はその note）か Makefile\n")
			return 1
		}
		fmt.Fprintf(out, "[gates] OK: gates.json は Makefile とそろっています（門 %d・suite %d）\n", len(f.Gates), len(f.Suites))
		return 0
	case hasFlag(rest, "--suites"):
		for _, s := range f.Suites {
			what := strings.Join(s.Gates, " → ")
			if s.Fallback != "" {
				what = "（今は " + s.Fallback + " を流す）"
			}
			fmt.Fprintf(out, "  make verify SUITE=%-9s %s\n      %s\n", s.Name, s.About, what)
		}
		return 0
	case hasFlag(rest, "--suite"):
		return runSuite(errOut, root, f, rest)
	}
	all, err := gates.All(root, f)
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	if hasFlag(rest, "--files") {
		var paths []string
		for _, a := range dropJSONFlag(rest) {
			if a != "--files" {
				paths = append(paths, strings.TrimPrefix(a, "./"))
			}
		}
		if len(paths) == 0 {
			errOut.WriteString("usage: bin/fge gates --files <パス…>\n")
			return 2
		}
		var hit []gates.Gate
		for _, g := range all {
			if g.Hits(paths) {
				hit = append(hit, g)
			}
		}
		all = hit
	}
	if asJSON {
		emitJSON(out, rowsOf(all))
		return 0
	}
	writeRows(out, all)
	return 0
}

// runSuite は流す道。出力は流しながら stdout / stderr へ直に書く（長い門の出力を貯めない）。
func runSuite(errOut *strings.Builder, root string, f *gates.File, rest []string) int {
	name := argAfter(rest, "--suite")
	all, err := gates.All(root, f)
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	list, note, err := gates.Resolve(f, all, name)
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	var extra []string
	for i, a := range rest {
		if a == "--" {
			extra = rest[i+1:]
			break
		}
	}
	return gates.NewRunner(os.Stdout, os.Stderr, root).Run(list, note, extra, hasFlag(rest, "--dry-run"))
}
