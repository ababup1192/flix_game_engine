package refactor

import (
	"bufio"
	"crypto/sha256"
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
	StateReverted     = "reverted"      // 書いたが確かめが落ちたので、書く前の中身（手の変更を含む）へ戻した
	StateRefused      = "refused"       // 書く前に断った（索引が古い・重なり・計画の後に外から変わった・--require-clean）
	StateRevertFailed = "revert-failed" // 確かめが落ちたが戻さなかったファイルが残った（書いた後に別の手が変えた・書けない。Unrestored）
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
	Backup     string   `json:"backup,omitempty"`     // --apply: 書く前の中身の控え（build/refactor/before/<パス>）
}

// Apply は --apply の時の当て方。
type Apply struct {
	On           bool         // false は dry-run（diff を書くだけ）
	RequireClean bool         // --require-clean: 書き換えるファイルに git のコミットしていない変更があれば断る（既定は断らない）
	Verify       string       // 書いた後の確かめの口
	Run          VerifyRunner // 確かめを流す所
}

// Change は書き換えを当てる流れ（dry-run → --apply → 確かめ → 落ちたら戻す）。
//
// 戻しは git に頼らない。書く直前の各ファイルの中身（コミットしていない変更を含む今の中身）を控え
// （build/refactor/before/ にも写す）、確かめが落ちたらその中身へ正確に戻す。書いた後に別の手が同じファイルを
// 変えていれば（ハッシュが書いた物と違えば）、その手の変更を消さないよう戻さずに revert-failed で知らせる。
//
// WhyNot: git の clean を要求しないのは、作業ツリーを手で直している途中でも道具を流せるようにするため
// （git apply -R で戻すと、手の変更と道具の patch が同じ行で重なった時に戻せない）。
func Change(root string, edits []Edit, how Apply) Outcome {
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
	if !how.On {
		return out
	}
	files := make([]string, 0, len(plan.Files))
	for f := range plan.Files {
		files = append(files, f)
	}
	sort.Strings(files)
	if how.RequireClean {
		if dirty, err := dirtyFiles(root, files); err != nil {
			out.State, out.Reason = StateRefused, err.Error()
			return out
		} else if len(dirty) > 0 {
			out.State, out.Reason = StateRefused, "--require-clean: 書き換える所にコミットしていない変更がある: "+strings.Join(dirty, "・")
			return out
		}
	}
	// 計画を作った後に外から変わったファイルは書かない（計画は読んだ時の中身に当てた物）。
	if moved := changedSince(root, files, plan.Orig); len(moved) > 0 {
		out.State, out.Reason = StateRefused, "計画を作った後に外から変わった（書いていない）: "+strings.Join(moved, "・")
		return out
	}
	backup := filepath.Join(dir, "before")
	if err := saveBackup(backup, files, plan.Orig); err != nil {
		out.State, out.Reason = StateRefused, "書く前の中身を控えられない: "+err.Error()
		return out
	}
	out.Backup = backup
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
			finishRevert(&out, root, plan, before)
			return out
		}
	}
	out.Verify = how.Verify
	out.VerifyLog = filepath.Join(dir, "verify.log")
	start := time.Now()
	code := how.Run(how.Verify, root, out.VerifyLog)
	out.VerifySecs = time.Since(start).Seconds()
	if code == 0 {
		out.State = StateApplied
		return out
	}
	out.FirstError = firstError(out.VerifyLog)
	finishRevert(&out, root, plan, before)
	return out
}

// finishRevert は書いたファイルを書く前の中身へ戻し、戻せたかで reverted か revert-failed にし、確かめが残した変更を並べる。
func finishRevert(out *Outcome, root string, plan *Planned, before map[string]bool) {
	left, err := revert(root, plan)
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
	for _, f := range porcelainPaths(string(out)) {
		set[f] = true
	}
	return set
}

// porcelainPaths は git status --porcelain の各行（XY<空白>パス）のパス。改名は新しい名前。
//
// WhyNot: 出力の全体を TrimSpace しない。最初の行の X が空白（作業ツリーだけの変更 " M a"）の時に頭の空白まで
// 削ると、[3:] がパスの頭の 1 字を食う（rc/scene/… と出た不具合）。
func porcelainPaths(out string) []string {
	var paths []string
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimRight(l, "\r")
		if len(l) < 4 {
			continue
		}
		p := l[3:]
		if _, to, ok := strings.Cut(p, " -> "); ok {
			p = to
		}
		paths = append(paths, strings.Trim(p, `"`))
	}
	return paths
}

func hashOf(s string) [32]byte { return sha256.Sum256([]byte(s)) }

// changedSince は files のうち、今の中身が want と違う物（読めない物も）。
func changedSince(root string, files []string, want map[string]string) []string {
	var moved []string
	for _, f := range files {
		cur, err := os.ReadFile(filepath.Join(root, f))
		if err != nil || hashOf(string(cur)) != hashOf(want[f]) {
			moved = append(moved, f)
		}
	}
	return moved
}

// saveBackup は書く前の中身を dir/<パス> に写す（前の回の物は消す）。戻しは手元の中身で行い、これは人が見る控え。
func saveBackup(dir string, files []string, orig map[string]string) error {
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	for _, f := range files {
		p := filepath.Join(dir, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, []byte(orig[f]), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// revert は書いたファイルを書く前の中身（plan.Orig）へ戻す。今の中身のハッシュが書いた物と同じ時だけ書き戻し、
// もう書く前の中身なら何もしない。それ以外（書いた後に別の手が変えた・読めない・書けない）は戻さずに返す。
func revert(root string, plan *Planned) ([]string, error) {
	var left, moved []string
	for f, body := range plan.Files {
		path := filepath.Join(root, f)
		cur, rerr := os.ReadFile(path)
		switch {
		case rerr != nil:
			left = append(left, f)
		case hashOf(string(cur)) == hashOf(plan.Orig[f]):
			// 書けずに終わった物・もう元の中身の物
		case hashOf(string(cur)) != hashOf(body):
			moved = append(moved, f)
		default:
			if os.WriteFile(path, []byte(plan.Orig[f]), 0o644) != nil {
				left = append(left, f)
			} else if back, err := os.ReadFile(path); err != nil || string(back) != plan.Orig[f] {
				left = append(left, f)
			}
		}
	}
	sort.Strings(left)
	sort.Strings(moved)
	if len(moved) == 0 && len(left) == 0 {
		return nil, nil
	}
	var why []string
	if len(moved) > 0 {
		why = append(why, "書いた後に別の手が変えたので戻していない（その変更を消さないため）: "+strings.Join(moved, "・"))
	}
	if len(left) > 0 {
		why = append(why, "読めないか書けない: "+strings.Join(left, "・"))
	}
	all := append(append([]string{}, moved...), left...)
	sort.Strings(all)
	return all, fmt.Errorf("%s。書く前の中身は build/refactor/before/<パス>", strings.Join(why, "・"))
}

// dirtyFiles は files のうち git がコミットしていない変更を持つ物（--require-clean の時だけ）。git の作業場でなければ誤り。
func dirtyFiles(root string, files []string) ([]string, error) {
	cmd := exec.Command("git", append([]string{"status", "--porcelain", "--"}, files...)...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("--require-clean は git の作業場でだけ: %v", err)
	}
	return porcelainPaths(string(out)), nil
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
