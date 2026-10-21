package refactor

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// VerifyRunner は書き換えの後の確かめ（cmd を dir で流し、出力を全部 log へ）。既定は heavy の枠の中。
type VerifyRunner func(cmd, dir, log string) int

// 書き換えの結末。
const (
	StateDryRun       = "dry-run"       // 計画と diff だけ（ファイルは触らない）
	StateApplied      = "applied"       // 書いて、確かめが通った
	StateReverted     = "reverted"      // 書いたが確かめが落ちたので、その patch だけを戻した
	StateRefused      = "refused"       // 書く前に断った（作業場が汚れている・索引が古い・重なり）
	StateRevertFailed = "revert-failed" // 確かめが落ち、戻そうとしたが戻せないファイルが残った（Unrestored を手で戻す）
	StateNothing      = "nothing"       // 当てる所が無い
)

// Outcome は 1 回の書き換えの結末。
type Outcome struct {
	State      string   `json:"state"`
	Diff       string   `json:"diff,omitempty"`  // build/refactor/last.diff
	Patch      string   `json:"patch,omitempty"` // build/refactor/last.patch（--apply の時）
	DiffLines  int      `json:"diffLines"`
	Files      int      `json:"files"`
	Verify     string   `json:"verify,omitempty"`
	VerifyLog  string   `json:"verifyLog,omitempty"`
	VerifySecs float64  `json:"verifySeconds,omitempty"`
	FirstError string   `json:"firstError,omitempty"`
	Reason     string   `json:"reason,omitempty"`     // refused・revert-failed の理由
	Unrestored []string `json:"unrestored,omitempty"` // revert-failed: 戻せなかったファイル
	LeftDirty  []string `json:"leftDirty,omitempty"`  // 確かめが書き換えて残したファイル（書く前に無かった git の変更。生成物など）
}

// Change は書き換えを当てる流れ（dry-run → --apply → 確かめ → 落ちたら戻す）。
func Change(root string, edits []Edit, apply bool, verify string, run VerifyRunner) Outcome {
	dir := filepath.Join(root, "build", "refactor")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Outcome{State: StateRefused, Reason: err.Error()}
	}
	if len(edits) == 0 {
		return Outcome{State: StateNothing}
	}
	plan, err := Plan(root, edits)
	if err != nil {
		return Outcome{State: StateRefused, Reason: err.Error()}
	}
	diff, err := Diff(dir, plan)
	if err != nil {
		return Outcome{State: StateRefused, Reason: err.Error()}
	}
	diffPath := filepath.Join(dir, "last.diff")
	if err := os.WriteFile(diffPath, []byte(diff), 0o644); err != nil {
		return Outcome{State: StateRefused, Reason: err.Error()}
	}
	out := Outcome{State: StateDryRun, Diff: diffPath, DiffLines: strings.Count(diff, "\n"), Files: len(plan.Files)}
	if !apply {
		return out
	}
	files := make([]string, 0, len(plan.Files))
	for f := range plan.Files {
		files = append(files, f)
	}
	sort.Strings(files)
	if dirty, err := dirtyFiles(root, files); err != nil {
		out.State, out.Reason = StateRefused, err.Error()
		return out
	} else if len(dirty) > 0 {
		out.State, out.Reason = StateRefused, "書き換える所にコミットしていない変更がある（戻す時に混ざるため断る）: "+strings.Join(dirty, "・")
		return out
	}
	before := gitStatus(root)
	patch := filepath.Join(dir, "last.patch")
	if err := os.WriteFile(patch, []byte(diff), 0o644); err != nil {
		out.State, out.Reason = StateRefused, err.Error()
		return out
	}
	out.Patch = patch
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(root, f), []byte(plan.Files[f]), 0o644); err != nil {
			out.Reason = err.Error()
			finishRevert(&out, root, patch, plan, before)
			return out
		}
	}
	out.Verify = verify
	out.VerifyLog = filepath.Join(dir, "verify.log")
	start := time.Now()
	code := run(verify, root, out.VerifyLog)
	out.VerifySecs = time.Since(start).Seconds()
	if code == 0 {
		out.State = StateApplied
		return out
	}
	out.FirstError = firstError(out.VerifyLog)
	finishRevert(&out, root, patch, plan, before)
	return out
}

// finishRevert は patch を戻し、戻せたかで reverted か revert-failed にし、確かめが残した変更を並べる。
func finishRevert(out *Outcome, root, patch string, plan *Planned, before map[string]bool) {
	left, err := revert(root, patch, plan)
	out.State = StateReverted
	if err != nil {
		out.Reason = err.Error()
	}
	if len(left) > 0 {
		out.State, out.Unrestored = StateRevertFailed, left
	}
	mine := map[string]bool{}
	for f := range plan.Files {
		mine[f] = true
	}
	for f := range gitStatus(root) {
		if !before[f] && !mine[f] {
			out.LeftDirty = append(out.LeftDirty, f)
		}
	}
	sort.Strings(out.LeftDirty)
}

// gitStatus は git がコミットしていない変更を持つファイル（未追跡も）の集まり。git の外なら空。
func gitStatus(root string) map[string]bool {
	cmd := exec.Command("git", "status", "--porcelain", "--untracked-files=all")
	cmd.Dir = root
	out, err := cmd.Output()
	set := map[string]bool{}
	if err != nil {
		return set
	}
	for _, l := range strings.Split(string(out), "\n") {
		if len(l) > 3 {
			set[strings.TrimSpace(l[3:])] = true
		}
	}
	return set
}

// revert は last.patch だけを逆に当てる（git apply -R）。git が断れば、触ったファイルが書いたままの時だけ元の中身へ戻す。
// 戻せなかったファイル（書いた後に別の物が変えた・書けない）を返す。
func revert(root, patch string, plan *Planned) ([]string, error) {
	cmd := exec.Command("git", "apply", "-R", patch)
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil, nil
	}
	var left []string
	for f, body := range plan.Files {
		cur, rerr := os.ReadFile(filepath.Join(root, f))
		switch {
		case rerr == nil && string(cur) == plan.Orig[f]:
			// 書けずに終わった物・もう元の中身の物
		case rerr != nil || string(cur) != body:
			left = append(left, f)
		default:
			if os.WriteFile(filepath.Join(root, f), []byte(plan.Orig[f]), 0o644) != nil {
				left = append(left, f)
			}
		}
	}
	sort.Strings(left)
	reason := fmt.Errorf("git apply -R が断った（%s）ので、書いたままのファイルを元の中身へ戻した", strings.TrimSpace(string(out)))
	if len(left) > 0 {
		reason = fmt.Errorf("git apply -R が断った（%s）。書いた後に変わったか書けないファイルは戻していない: %s", strings.TrimSpace(string(out)), strings.Join(left, "・"))
	}
	return left, reason
}

// dirtyFiles は files のうち git がコミットしていない変更を持つ物。git の作業場でなければ誤り。
func dirtyFiles(root string, files []string) ([]string, error) {
	cmd := exec.Command("git", append([]string{"status", "--porcelain", "--"}, files...)...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("--apply は git の作業場でだけ（戻すのに git apply -R を使う）: %v", err)
	}
	var dirty []string
	for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if len(l) > 3 {
			dirty = append(dirty, strings.TrimSpace(l[3:]))
		}
	}
	return dirty, nil
}

var errorLine = regexp.MustCompile(`(?i)(\berror\b|\bfail(ed|ure)?\b|\.flix:\d+|✗|✘|>> )`)

// firstError は確かめの出力の最初の誤りの行（と、続く場所の行）。
func firstError(log string) string {
	f, err := os.Open(log)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	var got []string
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if l == "" {
			continue
		}
		if len(got) > 0 {
			got = append(got, l)
			break
		}
		if errorLine.MatchString(l) && !strings.HasPrefix(l, "make") {
			got = append(got, l)
		}
	}
	s := strings.Join(got, " / ")
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	return s
}
