package flow

// fge flow の入口: check（JVM なし）・run と vocab（ゲームの make flow / flow-vocab へ渡す）。

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/suggest"
)

const usage = `使い方:
  fge flow check [<flow>...]   読むだけ（JVM なし・速い）。書き間違いを行番号と近い名前の案つきで全部言う。
                               引数が無ければ e2e/*.flow を全部。名前の一覧は e2e/vocab.json（--vocab <パス> で別の所）
  fge flow run <flow>          画面なしで最後まで流す（make flow FLOW=<flow>。失敗は行番号つきで 1）
  fge flow vocab               e2e/vocab.json を書き直す（make flow-vocab）`

// Run は fge flow の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		out.WriteString(usage + "\n")
		return 0, nil
	}
	switch args[0] {
	case "check":
		return check(out, errOut, root, args[1:])
	case "run":
		if len(args) != 2 {
			return 2, fmt.Errorf("fge flow run <flow>")
		}
		return runMake(root, "flow", "FLOW="+args[1])
	case "vocab":
		return runMake(root, "flow-vocab")
	}
	return 2, fmt.Errorf("知らない口 %q（check / run / vocab）", args[0])
}

func check(out, errOut *strings.Builder, root string, args []string) (int, error) {
	vocabPath := filepath.Join(root, "e2e", "vocab.json")
	given := false
	var files []string
	for i := 0; i < len(args); i++ {
		if args[i] == "--vocab" && i+1 < len(args) {
			vocabPath = args[i+1]
			given = true
			i++
			continue
		}
		files = append(files, args[i])
	}
	vocab, err := LoadVocab(vocabPath)
	if err != nil {
		return 2, fmt.Errorf("語彙 %s が無い・読めない（make flow-vocab で書き出す）: %w", vocabPath, err)
	}
	if note := suggest.Stale(root, vocabPath, "make flow-vocab"); note != "" && !given {
		errOut.WriteString(note + "\n")
	}
	if len(files) == 0 {
		found, _ := filepath.Glob(filepath.Join(root, "e2e", "*.flow"))
		sort.Strings(found)
		for _, f := range found {
			rel, _ := filepath.Rel(root, f)
			files = append(files, rel)
		}
	}
	if len(files) == 0 {
		out.WriteString("e2e/*.flow が無い\n")
		return 0, nil
	}
	code := 0
	for _, f := range files {
		problems, steps := CheckFile(vocab, f)
		if len(problems) > 0 {
			code = 1
			fmt.Fprintf(out, "FAIL %s: %d 行を読めない\n%s\n", f, len(problems), ProblemsText(problems))
		} else {
			fmt.Fprintf(out, "ok %s: %d 手\n", f, steps)
		}
	}
	return code, nil
}

// runMake はゲームの根で make を流し、出力をそのまま見せる（JVM を使う口）。
func runMake(root string, target string, vars ...string) (int, error) {
	cmd := exec.Command("make", append([]string{"-s", target}, vars...)...)
	cmd.Dir = root
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			return exit.ExitCode(), nil
		}
		return 2, err
	}
	return 0, nil
}
