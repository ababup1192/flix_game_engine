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
	Backup     string   `json:"backup,omitempty"`     // --apply: 書く前の中身の控え（build/refactor/before/<回>/<パス>）
	// Baseline の時: 書く前の確かめも落ちていた（前から通らない）。誤りの数は書く前・書いた後（ErrorsBefore・ErrorsAfter）。
	BrokenBefore bool `json:"brokenBefore,omitempty"`
	FixedAfter   bool `json:"fixedAfter,omitempty"` // 書く前は落ちていたが、書いた後は通った
	ErrorsBefore int  `json:"errorsBefore,omitempty"`
	ErrorsAfter  int  `json:"errorsAfter,omitempty"`
}

// Apply は --apply の時の当て方。
type Apply struct {
	On           bool         // false は dry-run（diff を書くだけ）
	RequireClean bool         // --require-clean: 書き換えるファイルに git のコミットしていない変更があれば断る（既定は断らない）
	Verify       string       // 書いた後の確かめの口
	Run          VerifyRunner // 確かめを流す所
	// Baseline は書く前にも確かめを流す。前から落ちている（型検査の通らない途中のソース）なら、書いた後の誤りが
	// 書く前の誤りに収まる（新しい誤りが 0）時に通す。誤りは（ファイル・種類・番号）で数える（行は書き換えでずれるので見ない）。
	Baseline bool
}

// Change は書き換えを当てる流れ（dry-run → --apply → 確かめ → 落ちたら戻す）。
//
// 戻しは git に頼らない。書く直前の各ファイルの中身（コミットしていない変更を含む今の中身）を控え
// （build/refactor/before/<回>/ にも写す）、確かめが落ちたらその中身へ正確に戻す。書いた後に別の手が同じファイルを
// 変えていれば（ハッシュが書いた物と違えば）、その手の変更を消さないよう戻さずに revert-failed で知らせ、
// その回の控えに印（REVERT-FAILED.txt）を置く。印が残る間は次の --apply を断る（唯一の控えを上書きしない）。
//
// WhyNot: git の clean を要求しないのは、作業ツリーを手で直している途中でも道具を流せるようにするため
// （git apply -R で戻すと、手の変更と道具の patch が同じ行で重なった時に戻せない）。
func Change(root string, edits []Edit, how Apply) Outcome {
	dir := filepath.Join(root, "build", "refactor")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Outcome{State: StateRefused, Reason: err.Error()}
	}
	if len(edits) == 0 {
		// 前の回の差分を残さない（名指しの回が 0 件の時に、名指し無しの前の回の last.diff を読み違えないように）。
		if err := os.Remove(filepath.Join(dir, "last.diff")); err != nil && !os.IsNotExist(err) {
			return Outcome{State: StateRefused, Reason: err.Error()}
		}
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
	if moved := changedSince(root, files, plan.Orig, plan.New); len(moved) > 0 {
		out.State, out.Reason = StateRefused, "計画を作った後に外から変わった（書いていない）: "+strings.Join(moved, "・")
		return out
	}
	backups := filepath.Join(dir, "before")
	if run, left := pendingRevertFailed(root, backups); run != "" {
		out.State, out.Reason = StateRefused, fmt.Sprintf("前の回が revert-failed のまま（%s）: 戻していない %s。"+
			"控え %s/<パス> と見比べて直したら %s を消す（控えと同じ中身に戻せば印は自然に外れる）",
			relTo(root, run), strings.Join(left, "・"), relTo(root, run), relTo(root, filepath.Join(run, revertFailedMark)))
		return out
	}
	var existed []string // 書く前に在ったファイル（新しく作るファイルは控えない。戻す時は消す）
	for _, f := range files {
		if !plan.New[f] {
			existed = append(existed, f)
		}
	}
	backup, err := saveBackup(backups, existed, plan.Orig, time.Now())
	if err != nil {
		out.State, out.Reason = StateRefused, "書く前の中身を控えられない: "+err.Error()
		return out
	}
	out.Backup = backup
	var baseErrs map[string]int
	if how.Baseline {
		baseLog := filepath.Join(dir, "verify-before.log")
		if how.Run(how.Verify, root, baseLog) != 0 {
			out.BrokenBefore = true
			baseErrs = errorSigs(baseLog)
			out.ErrorsBefore = countSigs(baseErrs)
		}
	}
	before := gitStatus(root)
	patch := filepath.Join(dir, "last.patch")
	if err := os.WriteFile(patch, []byte(diff), 0o644); err != nil {
		out.State, out.Reason = StateRefused, err.Error()
		return out
	}
	out.Patch = patch
	for _, f := range files {
		if plan.New[f] {
			if err := os.MkdirAll(filepath.Dir(filepath.Join(root, f)), 0o755); err != nil {
				out.Reason = err.Error()
				finishRevert(&out, root, plan, before)
				return out
			}
		}
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
		out.FixedAfter = out.BrokenBefore
		return out
	}
	if out.BrokenBefore {
		after := errorSigs(out.VerifyLog)
		out.ErrorsAfter = countSigs(after)
		if added := newSigs(baseErrs, after); len(added) == 0 && out.ErrorsAfter > 0 {
			out.State = StateApplied
			return out
		} else if len(added) > 0 {
			out.FirstError = "新しい誤り: " + strings.Join(added, "・")
		}
	}
	if out.FirstError == "" {
		out.FirstError = firstError(out.VerifyLog)
	}
	finishRevert(&out, root, plan, before)
	return out
}

// relTo は p を root からの相対で（出せなければ p のまま）。
func relTo(root, p string) string {
	if r, err := filepath.Rel(root, p); err == nil {
		return filepath.ToSlash(r)
	}
	return p
}

// finishRevert は書いたファイルを書く前の中身へ戻し、戻せたかで reverted か revert-failed にし、確かめが残した変更を並べる。
func finishRevert(out *Outcome, root string, plan *Planned, before map[string]bool) {
	left, err := revert(root, plan, relTo(root, out.Backup))
	out.State = StateReverted
	if err != nil {
		out.Reason = err.Error()
	}
	if len(left) > 0 {
		out.State, out.Unrestored = StateRevertFailed, left
		markRevertFailed(out.Backup, left, out.Reason)
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

// changedSince は files のうち、今の中身が want と違う物（読めない物も）。absent の物は、まだ無い事を確かめる。
func changedSince(root string, files []string, want map[string]string, absent map[string]bool) []string {
	var moved []string
	for _, f := range files {
		cur, err := os.ReadFile(filepath.Join(root, f))
		if absent[f] {
			if !os.IsNotExist(err) {
				moved = append(moved, f)
			}
			continue
		}
		if err != nil || hashOf(string(cur)) != hashOf(want[f]) {
			moved = append(moved, f)
		}
	}
	return moved
}

// KeepBackups は build/refactor/before/ に残す回の数。超えた分を古い回から消す（revert-failed の印のある回は消さない）。
const KeepBackups = 10

// revertFailedMark は revert-failed の回の控えに置く印（戻していないファイルと訳）。
const revertFailedMark = "REVERT-FAILED.txt"

// backupRun は控えの回のフォルダの名前（書いた時刻。名前の順が時の順）。
var backupRun = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}\.[0-9]{3}(-[0-9]+)?$`)

// saveBackup は書く前の中身を dir/<回>/<パス> に写し、その回のフォルダを返す。戻しは手元の中身で行い、これは人が見る控え。
// 回は書いた時刻で分け、前の回の控えは消さない（KeepBackups を超えた古い回だけ消す）。
func saveBackup(dir string, files []string, orig map[string]string, now time.Time) (string, error) {
	name := now.Format("20060102-150405.000")
	run := filepath.Join(dir, name)
	for i := 2; ; i++ {
		if _, err := os.Stat(run); os.IsNotExist(err) {
			break
		}
		run = filepath.Join(dir, fmt.Sprintf("%s-%d", name, i))
	}
	for _, f := range files {
		p := filepath.Join(run, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(p, []byte(orig[f]), 0o644); err != nil {
			return "", err
		}
	}
	pruneBackups(dir, KeepBackups)
	return run, nil
}

// backupRuns は dir の下の控えの回（古い順）。
func backupRuns(dir string) []string {
	entries, _ := os.ReadDir(dir)
	var runs []string
	for _, e := range entries {
		if e.IsDir() && backupRun.MatchString(e.Name()) {
			runs = append(runs, e.Name())
		}
	}
	sort.Strings(runs)
	return runs
}

// pruneBackups は控えの回を新しい keep 回だけ残す。revert-failed の印のある回は数えず消さない。
func pruneBackups(dir string, keep int) {
	var plain []string
	for _, r := range backupRuns(dir) {
		if _, err := os.Stat(filepath.Join(dir, r, revertFailedMark)); err != nil {
			plain = append(plain, r)
		}
	}
	for len(plain) > keep {
		os.RemoveAll(filepath.Join(dir, plain[0]))
		plain = plain[1:]
	}
}

// markRevertFailed は回の控えに revert-failed の印を置く（1 行目から戻していないファイル・最後に訳）。
func markRevertFailed(run string, left []string, reason string) {
	if run == "" {
		return
	}
	body := strings.Join(left, "\n") + "\n\n" + reason + "\n"
	os.WriteFile(filepath.Join(run, revertFailedMark), []byte(body), 0o644)
}

// pendingRevertFailed は revert-failed の印が残る回（一番古い物）と、まだ控えの中身に戻っていないファイル。
// 印のファイルが全部控えと同じ中身に戻っていれば、片付いたと見て印を外す。無ければ "" と nil。
func pendingRevertFailed(root, dir string) (string, []string) {
	for _, r := range backupRuns(dir) {
		run := filepath.Join(dir, r)
		data, err := os.ReadFile(filepath.Join(run, revertFailedMark))
		if err != nil {
			continue
		}
		head, _, _ := strings.Cut(string(data), "\n\n")
		var left []string
		for _, f := range strings.Split(head, "\n") {
			if f = strings.TrimSpace(f); f == "" {
				continue
			}
			want, werr := os.ReadFile(filepath.Join(run, filepath.FromSlash(f)))
			cur, cerr := os.ReadFile(filepath.Join(root, filepath.FromSlash(f)))
			if werr != nil || cerr != nil || string(want) != string(cur) {
				left = append(left, f)
			}
		}
		if len(left) == 0 {
			os.Remove(filepath.Join(run, revertFailedMark))
			continue
		}
		return run, left
	}
	return "", nil
}

// revert は書いたファイルを書く前の中身（plan.Orig）へ戻す。今の中身のハッシュが書いた物と同じ時だけ書き戻し、
// もう書く前の中身なら何もしない。それ以外（書いた後に別の手が変えた・読めない・書けない）は戻さずに返す。
func revert(root string, plan *Planned, backup string) ([]string, error) {
	var left, moved []string
	for f, body := range plan.Files {
		path := filepath.Join(root, f)
		cur, rerr := os.ReadFile(path)
		switch {
		case plan.New[f] && os.IsNotExist(rerr):
			// 作る前に落ちた・もう消えている
		case plan.New[f] && rerr == nil && hashOf(string(cur)) == hashOf(body):
			if os.Remove(path) != nil {
				left = append(left, f)
			}
		case plan.New[f] && rerr == nil:
			moved = append(moved, f)
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
	return all, fmt.Errorf("%s。書く前の中身は %s/<パス>", strings.Join(why, "・"), backup)
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

// errHead は Flix の誤りの見出しの行（`-- Type Error [E8752] ---- src/X.flix`）、errBrief は make check の要約の行
// （`  src/X.flix:247 — Resolution Error [E2136]`。bin/fge explain-error が残りの誤りを並べる形）。
var (
	errHead  = regexp.MustCompile(`^-- (.+?) \[(E\d+)\] -+ (\S+\.flix)\s*$`)
	errBrief = regexp.MustCompile(`^\s*(\S+\.flix):\d+ — (.+?) \[(E\d+)\]`)
)

// errorSigs は確かめの出力の誤りを（ファイル 種類 [番号]）ごとに数える（行は数えない。書き換えでずれるため）。
func errorSigs(log string) map[string]int {
	data, err := os.ReadFile(log)
	if err != nil {
		return nil
	}
	out := map[string]int{}
	for _, l := range strings.Split(string(data), "\n") {
		l = strings.TrimRight(l, "\r")
		if m := errHead.FindStringSubmatch(l); m != nil {
			out[m[3]+" "+m[1]+" ["+m[2]+"]"]++
		} else if m := errBrief.FindStringSubmatch(l); m != nil {
			out[m[1]+" "+m[2]+" ["+m[3]+"]"]++
		}
	}
	return out
}

func countSigs(m map[string]int) int {
	n := 0
	for _, v := range m {
		n += v
	}
	return n
}

// newSigs は after にあって before に無い（数が増えた）誤り。
func newSigs(before, after map[string]int) []string {
	var out []string
	for k, v := range after {
		if v > before[k] {
			out = append(out, fmt.Sprintf("%s ×%d", k, v-before[k]))
		}
	}
	sort.Strings(out)
	return out
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
