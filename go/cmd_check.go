package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

const checkUsage = `使い方: bin/fge check codes [--md] [--check] [px|snd]
  検査の code の表（px・snd・state-shape の全部の code の level・metric・unit・want の向き）。
  --md は docs/check-codes.md を書き、--check はずれていれば 1（書かない）。
  1 件の形・score・next・stop・終了コードの決まりは docs/check-results.md。
`

func init() {
	register("check", "検査の code の表 (codes [--md|--check])・結果の形は docs/check-results.md", cmdCheck)
}

func cmdCheck(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	args := dropJSONFlag(rest)
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		out.WriteString(checkUsage)
		if len(args) == 0 {
			return 2
		}
		return 0
	}
	if args[0] != "codes" {
		fmt.Fprintf(errOut, "check: 知らない口 %q\n%s", args[0], checkUsage)
		return 2
	}
	md, check, prefix := false, false, ""
	for _, a := range args[1:] {
		switch a {
		case "--md":
			md = true
		case "--check":
			check = true
		case "px", "snd", "state-shape":
			prefix = a + "."
		default:
			fmt.Fprintf(errOut, "check codes: 知らない指定 %s\n%s", a, checkUsage)
			return 2
		}
	}
	if asJSON {
		data, _ := json.MarshalIndent(checkres.All(prefix), "", "  ")
		out.Write(append(data, '\n'))
		return 0
	}
	if !md && !check {
		out.WriteString(checkres.Text(prefix))
		return 0
	}
	path := filepath.Join(repoRoot(), "docs", "check-codes.md")
	want := checkres.Markdown()
	if check {
		cur, _ := os.ReadFile(path)
		if string(cur) != want {
			fmt.Fprintf(errOut, "check: %s が code の表とずれている（bin/fge check codes --md で作り直す）\n", "docs/check-codes.md")
			return 1
		}
		return 0
	}
	if err := os.WriteFile(path, []byte(want), 0o644); err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 1
	}
	fmt.Fprintln(out, "check: docs/check-codes.md を書いた")
	return 0
}
