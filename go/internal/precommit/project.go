package precommit

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// projectGates は project.json のうち pre-commit が読む欄（plans/windows.md 4 節）。
type projectGates struct {
	// Precommit はゲームの pre-commit で流す物の並び。1 つは bin/fge の引数を空白で区切った物で、
	// 先頭の語が tasks の名前なら `bin/fge task <名前>` で流す。nil は欄が無い（Makefile のターゲットを使う）。
	Precommit []string `json:"precommit"`
	// Tasks はゲーム固有の作業。ここでは名前だけを見る。
	Tasks map[string]json.RawMessage `json:"tasks"`
}

// readProjectGates は根の project.json を読む。無ければ空（欄が無いのと同じ）。
// WhyNot: 壊れた project.json を「欄が無い」と読んで Makefile の道へ移らないのは、
// 書いたはずの検査が知らせずに流れなくなるため。
func readProjectGates(root string) (projectGates, error) {
	var p projectGates
	data, err := os.ReadFile(filepath.Join(root, "project.json"))
	if errors.Is(err, os.ErrNotExist) {
		return p, nil
	}
	if err != nil {
		return p, fmt.Errorf("project.json を読めません: %v", err)
	}
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	var raw struct {
		Precommit *[]string                  `json:"precommit"`
		Tasks     map[string]json.RawMessage `json:"tasks"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return p, fmt.Errorf("project.json の precommit か tasks が読めません: %v", err)
	}
	if raw.Precommit != nil {
		p.Precommit = append([]string{}, *raw.Precommit...)
	}
	p.Tasks = raw.Tasks
	return p, nil
}

// stepArgs は precommit の 1 つを bin/fge の引数にする。
func (p projectGates) stepArgs(step string) []string {
	args := strings.Fields(step)
	if len(args) == 0 {
		return nil
	}
	if _, ok := p.Tasks[args[0]]; ok {
		return append([]string{"task"}, args...)
	}
	return args
}

// runProjectSteps は project.json の precommit を順に bin/fge で流す。ステージしたファイルは
// Makefile のターゲットと同じく、1 行 1 つで書いた一時ファイルのパスを環境変数 STAGED_FILE で渡す。
// WhyNot: 1 つが落ちても残りを流すのは、1 回のコミットで直す所を全部見せるため（checks と同じ）。
func (r *runner) runProjectSteps(p projectGates, staged []string) (int, error) {
	if len(p.Precommit) == 0 {
		return 0, nil
	}
	fge := r.opts.Fge
	if fge == "" {
		self, err := os.Executable()
		if err != nil {
			return 0, fmt.Errorf("bin/fge の実体を引けません: %v", err)
		}
		fge = self
	}
	name, err := writeStagedFile(staged)
	if err != nil {
		return 0, err
	}
	defer os.Remove(name)
	code := 0
	for _, step := range p.Precommit {
		args := p.stepArgs(step)
		if args == nil {
			continue
		}
		cmd := exec.Command(fge, args...)
		cmd.Dir = r.root
		cmd.Env = append(os.Environ(), "STAGED_FILE="+name)
		cmd.Stdout = r.opts.Stdout
		cmd.Stderr = r.opts.Stderr
		if err := cmd.Run(); err != nil && cmd.ProcessState == nil {
			fmt.Fprintf(r.parent, "[pre-commit] project.json の precommit の %q を起こせません: %v\n", step, err)
			code = 1
			continue
		}
		if cmd.ProcessState.ExitCode() != 0 {
			code = 1
		}
	}
	return code, nil
}
