package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/gates"
	"github.com/ababup1192/flix_game_engine/go/internal/testselect"
)

func init() {
	registerEngineOnly("test-select", "差分から流す門を選ぶ（流さない）。[--since <ref>] [--files <パス…>] [--gui] [--explain] [--json]・流すのは make verify SUITE=affected", cmdTestSelect)
}

// testSelectFilesFrom は precommit-dry に渡すファイルの一覧の置き場（repo の根から）。
const testSelectFilesFrom = "build/test-select/files.txt"

type testSelectArgs struct {
	since   string
	files   []string
	isFiles bool
	gui     bool
}

func parseTestSelectArgs(rest []string) testSelectArgs {
	var a testSelectArgs
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case "--since", "--base":
			if i+1 < len(rest) {
				a.since = rest[i+1]
				i++
			}
		case "--files":
			a.isFiles = true
		case "--gui":
			a.gui = true
		case "--explain", "--json":
		default:
			if a.isFiles && !strings.HasPrefix(rest[i], "--") {
				a.files = append(a.files, rest[i])
			}
		}
	}
	return a
}

// buildPlan は差分を集めて選ぶ。precommit-dry に渡す一覧も書く。
func buildPlan(root string, a testSelectArgs) (*testselect.Plan, error) {
	f, err := gates.Load(root)
	if err != nil {
		return nil, err
	}
	var changes []testselect.Change
	if a.isFiles {
		changes = testselect.FilesChanges(root, a.files)
	} else if changes, err = testselect.Changes(root, a.since); err != nil {
		return nil, err
	}
	var list []string
	for _, c := range changes {
		if !c.Deleted {
			list = append(list, c.Path)
		}
	}
	listPath := filepath.Join(root, testSelectFilesFrom)
	if err := os.MkdirAll(filepath.Dir(listPath), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(listPath, []byte(strings.Join(list, "\n")+"\n"), 0o644); err != nil {
		return nil, err
	}
	env := &testselect.RealEnv{Root: root}
	return testselect.Select(testselect.NewTable(f), changes, env, testselect.ByFeeds,
		testselect.Options{GUI: a.gui, FilesFrom: testSelectFilesFrom})
}

func cmdTestSelect(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	root := repoRoot()
	a := parseTestSelectArgs(rest)
	plan, err := buildPlan(root, a)
	if errors.Is(err, fs.ErrNotExist) {
		errOut.WriteString("[test-select] gates.json がありません（engine のリポでだけ使う道具です）\n")
		return 2
	}
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	if asJSON {
		emitJSON(out, plan)
		return 0
	}
	writePlan(out, plan, a.gui, hasFlag(rest, "--explain"))
	return 0
}

func writePlan(out *strings.Builder, plan *testselect.Plan, gui, explain bool) {
	if len(plan.Files) == 0 {
		out.WriteString("[test-select] 差分がありません\n")
		return
	}
	if len(plan.AllBecause) > 0 {
		fmt.Fprintf(out, "[test-select] 全部にしたファイル（安全側）: %s\n", strings.Join(plan.AllBecause, "・"))
	}
	if explain {
		out.WriteString("ファイル:\n")
		for _, fc := range plan.Files {
			fmt.Fprintf(out, "  %s  [%s]", fc.Path, fc.Kind)
			if fc.Package != "" {
				fmt.Fprintf(out, " パッケージ %s", fc.Package)
				if fc.Local {
					out.WriteString("（下流へ伝えない）")
				}
			}
			if len(fc.Reads) > 0 {
				fmt.Fprintf(out, " 読む側 %s", strings.Join(fc.Reads, ","))
			}
			if len(fc.Gates) > 0 {
				fmt.Fprintf(out, " 門 %s", strings.Join(fc.Gates, ","))
			}
			if len(fc.GoPkgs) > 0 {
				fmt.Fprintf(out, " go %s", strings.Join(fc.GoPkgs, ","))
			}
			out.WriteString("\n")
		}
		out.WriteString("当たったパッケージ:\n")
		for _, id := range sortedPkgIDs(plan.Packages) {
			fmt.Fprintf(out, "  %-20s %s\n", id, strings.Join(plan.Packages[id], " ／ "))
		}
	}
	fmt.Fprintf(out, "流す門（%d）:\n", len(plan.Run))
	for _, l := range plan.Run {
		fmt.Fprintf(out, "  %s   （目安 %s）\n      なぜ: %s\n", l.Display(), l.Time, strings.Join(l.Why, " ／ "))
	}
	if !gui && len(plan.GUI) > 0 {
		fmt.Fprintf(out, "画面を開く門（選んだが流さない・GUI=1 / --gui で流す）:\n")
		for _, l := range plan.GUI {
			fmt.Fprintf(out, "  %s   なぜ: %s\n", l.Display(), strings.Join(l.Why, " ／ "))
		}
	}
	if len(plan.Hold) > 0 {
		out.WriteString("選んだが流さない門（手で）:\n")
		for _, l := range plan.Hold {
			fmt.Fprintf(out, "  %s   — %s\n", l.Display(), l.Reason)
		}
	}
}

func sortedPkgIDs(m map[string][]string) []string {
	var ids []string
	for id := range m {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}
