package gates

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// Runner は suite の門を 1 つずつ流す。Exec は差し替えられる（テストで make を起こさない）。
type Runner struct {
	Out, Err io.Writer
	Root     string
	Env      []string
	// NotRun は選んだのに流さない門（test-select の gui・hold）。最後の 1 行で知らせる。
	NotRun []string
	// Exec は make の行を流し、終了コードと signal で止まったかを返す。
	Exec func(line []string) (code int, signaled bool)
}

// NewRunner は本物の make を起こす Runner。
func NewRunner(out, errOut io.Writer, root string) *Runner {
	r := &Runner{Out: out, Err: errOut, Root: root, Env: os.Environ()}
	r.Exec = r.execMake
	return r
}

func (r *Runner) execMake(line []string) (int, bool) {
	cmd := exec.Command(line[0], line[1:]...)
	cmd.Dir = r.Root
	cmd.Env = makeEnv(r.Env)
	cmd.Stdout = r.Out
	cmd.Stderr = r.Err
	cmd.Stdin = os.Stdin
	err := cmd.Run()
	if cmd.ProcessState == nil {
		fmt.Fprintf(r.Err, "[verify] %s を起こせません: %v\n", line[0], err)
		return 127, false
	}
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal()), true
	}
	return cmd.ProcessState.ExitCode(), false
}

// Resolve は suite の名前から流す門の並びを決める（fallback をたどる）。note は fallback した時の 1 行。
func Resolve(f *File, all []Gate, name string) (gates []Gate, note string, err error) {
	s, ok := f.FindSuite(name)
	if !ok {
		return nil, "", fmt.Errorf("suite %s はありません（%s）", name, suiteNames(f))
	}
	seen := map[string]bool{}
	for s.Fallback != "" {
		if seen[s.Name] {
			return nil, "", fmt.Errorf("suite %s の fallback が輪になっています", name)
		}
		seen[s.Name] = true
		note = fmt.Sprintf("[verify] %s はまだ作っていないので、代わりに %s を流します", s.Name, s.Fallback)
		if s, ok = f.FindSuite(s.Fallback); !ok {
			return nil, "", fmt.Errorf("suite %s の fallback がありません", name)
		}
	}
	for _, id := range s.Gates {
		g, ok := FindGate(all, id)
		if !ok || g.Make == "" {
			return nil, "", fmt.Errorf("suite %s の門 %s がないか、make の口を持ちません（bin/fge gates --check）", s.Name, id)
		}
		gates = append(gates, g)
	}
	return gates, note, nil
}

func suiteNames(f *File) string {
	var names []string
	for _, s := range f.Suites {
		names = append(names, s.Name)
	}
	return strings.Join(names, "・")
}

// Run は suite を流す。赤でも次の門へ進み、最後に赤を並べて 1 を返す。prereq の門が赤ならそこで止める。
// 子が signal で止まった時・この道具が SIGINT / SIGTERM を受けた時は残りを流さず 130 を返す。
func (r *Runner) Run(gates []Gate, note string, extra []string, dryRun bool) int {
	if note != "" {
		fmt.Fprintln(r.Out, note)
	}
	if dryRun {
		for _, g := range gates {
			fmt.Fprintln(r.Out, ShellLine(g.MakeLine(extra)))
		}
		return 0
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(stop)
	interrupted := func() bool {
		select {
		case <-stop:
			return true
		default:
			return false
		}
	}
	var failed []string
	var lines []string
	for i, g := range gates {
		line := g.MakeLine(extra)
		fmt.Fprintf(r.Out, "\n[verify] (%d/%d) %s  — %s（目安 %s）\n", i+1, len(gates), ShellLine(line), g.About, g.Time)
		start := time.Now()
		code, signaled := r.Exec(line)
		took := time.Since(start).Round(time.Second)
		if signaled || interrupted() {
			fmt.Fprintf(r.Err, "[verify] 止められたので残りを流しません（%s の途中）\n", g.ID)
			return 130
		}
		status := "OK"
		if code != 0 {
			status = fmt.Sprintf("赤 (exit %d)", code)
			failed = append(failed, g.ID)
		}
		lines = append(lines, fmt.Sprintf("  %-22s %-12s %s", g.ID, status, took))
		if code != 0 && g.Prereq {
			fmt.Fprintf(r.Err, "[verify] 前提の門 %s が赤なので、後ろの門は流しません\n", g.ID)
			break
		}
	}
	fmt.Fprintln(r.Out, "\n[verify] まとめ")
	for _, l := range lines {
		fmt.Fprintln(r.Out, l)
	}
	if len(failed) > 0 {
		fmt.Fprintf(r.Out, "[verify] 赤: %s\n", strings.Join(failed, " "))
		return 1
	}
	if len(r.NotRun) > 0 {
		fmt.Fprintf(r.Out, "[verify] OK（流していない門 %d 本: %s）\n", len(r.NotRun), strings.Join(r.NotRun, " "))
		return 0
	}
	fmt.Fprintln(r.Out, "[verify] 全部 OK")
	return 0
}
