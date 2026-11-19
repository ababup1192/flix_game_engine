package main

// bin/fge test-select-replay — 過去のコミットを並べ、選んだ門だけを流した答えと全量の答えが一致するかを数える（plans/test-selection.md の 6 節・12.8）。

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/gates"
	"github.com/ababup1192/flix_game_engine/go/internal/testselect"
)

func init() {
	registerEngineOnly("test-select-replay", "答え合わせ: 過去のコミットの src を戻して作った赤で、選んだ門と全量の答えを比べる。--range <a>..<b> | --commits <sha,…> [--mode red]", cmdTestSelectReplay)
}

const (
	replayDir      = "build/test-select/replay"
	replayLock     = "build/test-select/replay.lock"
	replayWorktree = ".claude/worktrees/replay-scratch"
	// replayMaxFiles を超えるファイルを触ったコミットは台に入れない（6.1: 大きなコミットは別に数える）。
	replayMaxFiles = 40
	replayJobs     = 6
)

// replayToolPaths は台の木に今の物（呼んだ木の HEAD）を重ねる道具の置き場（make の口と台本）。
var replayToolPaths = []string{"Makefile", "mk", "bin"}

type replayArgs struct {
	rng     string
	commits []string
}

func parseReplayArgs(rest []string) (replayArgs, error) {
	var a replayArgs
	for i := 0; i < len(rest); i++ {
		val := func() string {
			if i+1 < len(rest) {
				i++
				return rest[i]
			}
			return ""
		}
		switch rest[i] {
		case "--range":
			a.rng = val()
		case "--commits":
			for _, c := range strings.Split(val(), ",") {
				if c = strings.TrimSpace(c); c != "" {
					a.commits = append(a.commits, c)
				}
			}
		case "--mode":
			if m := val(); m != "red" {
				return a, fmt.Errorf("--mode は red だけ（%s は知らない）", m)
			}
		case "--json":
		default:
			return a, fmt.Errorf("知らない引数 %s", rest[i])
		}
	}
	if (a.rng == "") == (len(a.commits) == 0) {
		return a, fmt.Errorf("--range か --commits のどちらか 1 つを渡す")
	}
	return a, nil
}

// replayFull は全量の結果。
type replayFull struct {
	TestFail   []string `json:"testFail"`
	CheckFail  []string `json:"checkFail"`
	Flaky      []string `json:"flaky"`
	SyncFailed bool     `json:"syncFailed"`
	Seconds    int      `json:"seconds"`
}

type replayRecord struct {
	Commit   string              `json:"commit"`
	Subject  string              `json:"subject"`
	Mode     string              `json:"mode"`
	Reverted []string            `json:"reverted,omitempty"`
	Skipped  string              `json:"skipped,omitempty"`
	Selected map[string]string   `json:"selected,omitempty"`
	NotRun   []string            `json:"notRun,omitempty"`
	Full     *replayFull         `json:"full,omitempty"`
	Red      []string            `json:"selectedRed,omitempty"`
	Verdict  *testselect.Verdict `json:"verdict,omitempty"`
	Seconds  map[string]int      `json:"seconds,omitempty"`
	Error    string              `json:"error,omitempty"`
}

func cmdTestSelectReplay(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	a, err := parseReplayArgs(rest)
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	root := repoRoot()
	unlock, err := takeReplayLock(filepath.Join(root, replayLock))
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	defer unlock()
	commits, err := replayCommits(root, a)
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	wt := filepath.Join(root, replayWorktree)
	if err := ensureReplayWorktree(root, wt); err != nil {
		return orAbort(errOut, 2, err)
	}
	defer exec.Command("git", "-C", root, "worktree", "remove", "--force", wt).Run()
	gatesBlob, err := gitLine(root, "hash-object", "-w", "gates.json")
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	f, err := gates.Load(root)
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	var recs []replayRecord
	for i, c := range commits {
		logf("[replay] (%d/%d) %s", i+1, len(commits), c)
		rec := replayOne(root, wt, gatesBlob, f, c)
		recs = append(recs, rec)
		logf("[replay]   %s", replaySummaryLine(rec))
	}
	path := filepath.Join(root, replayDir, "replay-"+time.Now().Format("20060102-150405")+".json")
	if err := writeJSONFile(path, map[string]any{"mode": "red", "records": recs}); err != nil {
		return orAbort(errOut, 2, err)
	}
	if asJSON {
		emitJSON(out, recs)
		return 0
	}
	writeReplayTable(out, recs)
	fmt.Fprintf(out, "[replay] 結果: %s\n", path)
	return 0
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}

// takeReplayLock は台の worktree を 1 本だけで使う鍵（同じ worktree で 2 本流すと木と fpkg の置き場を食い合う）。
func takeReplayLock(path string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	for range 2 {
		fh, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if err == nil {
			fmt.Fprintf(fh, "%d\n", os.Getpid())
			fh.Close()
			return func() { os.Remove(path) }, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		b, _ := os.ReadFile(path)
		pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
		if pid > 0 && processAlive(pid) {
			return nil, fmt.Errorf("答え合わせは pid %d が流している（%s）", pid, path)
		}
		os.Remove(path)
	}
	return nil, fmt.Errorf("鍵 %s を取れない", path)
}

// processAlive は pid のプロセスが生きているか（Windows では FindProcess が生きている物しか返さない）。
func processAlive(pid int) bool {
	p, err := os.FindProcess(pid)
	return err == nil && p.Signal(syscall.Signal(0)) == nil
}

func gitLine(dir string, args ...string) (string, error) {
	return gitEnv(dir, nil, args...)
}

func gitEnv(dir string, env []string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), env...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	b, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %v %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(string(b)), nil
}

// replayCommits は流すコミット（--range は古い順・merge を除く）。
func replayCommits(root string, a replayArgs) ([]string, error) {
	if len(a.commits) > 0 {
		var out []string
		for _, c := range a.commits {
			sha, err := gitLine(root, "rev-parse", "--verify", c+"^{commit}")
			if err != nil {
				return nil, err
			}
			out = append(out, sha)
		}
		return out, nil
	}
	list, err := gitLine(root, "rev-list", "--no-merges", "--reverse", a.rng)
	if err != nil {
		return nil, err
	}
	var cands []string
	for _, c := range strings.Fields(list) {
		if why := replaySkipReason(root, c); why == "" {
			cands = append(cands, c)
		}
	}
	return cands, nil
}

// replaySkipReason は台に入れない訳（空なら入れる）。
func replaySkipReason(root, c string) string {
	subj, _ := gitLine(root, "log", "-1", "--format=%s", c)
	if strings.HasPrefix(subj, "bump:") {
		return "版を上げるだけのコミット"
	}
	files, err := changedFiles(root, c)
	if err != nil {
		return err.Error()
	}
	if len(files) > replayMaxFiles {
		return fmt.Sprintf("%d ファイル（%d を超える）", len(files), replayMaxFiles)
	}
	if len(revertSources(files)) == 0 {
		return "戻すテストでない .flix が無い"
	}
	return ""
}

func changedFiles(root, c string) ([]string, error) {
	out, err := gitLine(root, "diff-tree", "--no-commit-id", "-r", "--no-renames", "--name-only", c+"^", c)
	if err != nil {
		return nil, err
	}
	return strings.Fields(out), nil
}

func revertSources(files []string) []string {
	var out []string
	for _, f := range files {
		if testselect.IsRevertSource(f) {
			out = append(out, f)
		}
	}
	return out
}

// ensureReplayWorktree は台の worktree を立て（あれば使い回す）、git の外の依存を張る。
func ensureReplayWorktree(root, wt string) error {
	if _, err := os.Stat(filepath.Join(wt, ".git")); err != nil {
		if _, err := gitLine(root, "worktree", "add", "--detach", wt, "HEAD"); err != nil {
			return err
		}
	}
	cmd := exec.Command("make", "--no-print-directory", "worktree-seed", "WT="+wt)
	cmd.Dir = root
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	return cmd.Run()
}

// replayTrees は台の 2 つのコミット（base と target。target の親が base）を作る。どちらにも今の gates.json を重ねる。
// WhyNot: base を target の祖先にしないと、test-select の --since の merge-base が target になり差分が空になる。
// WhyNot: checkout や revert で木を作らない — フックを通らず枝も作らない commit-tree で、ぶつかりも起きない。
// どちらの木にも今の gates.json と道具（replayToolPaths）を重ねる。
// red: base は C の木、target は C のテストのまま src（テストでない .flix）だけを C^ に戻した木（6.1 の 2。C で直したテストが落ちる）。
func replayTrees(root, gatesBlob, c string) (base, target string, reverted []string, err error) {
	tools, err := gitLine(root, "rev-parse", "HEAD")
	if err != nil {
		return "", "", nil, err
	}
	idx := filepath.Join(root, replayDir, "index-"+strconv.Itoa(os.Getpid()))
	if err := os.MkdirAll(filepath.Dir(idx), 0o755); err != nil {
		return "", "", nil, err
	}
	defer os.Remove(idx)
	env := []string{"GIT_INDEX_FILE=" + idx}
	tree := func(from string, swap []string, swapFrom string) (string, error) {
		if _, err := gitEnv(root, env, "read-tree", from); err != nil {
			return "", err
		}
		for _, p := range swap {
			ls, err := gitEnv(root, env, "ls-tree", swapFrom, "--", p)
			if err != nil {
				return "", err
			}
			if ls == "" {
				if _, err := gitEnv(root, env, "update-index", "--force-remove", "--", p); err != nil {
					return "", err
				}
				continue
			}
			meta, _, _ := strings.Cut(ls, "\t")
			parts := strings.Fields(meta)
			if _, err := gitEnv(root, env, "update-index", "--add", "--cacheinfo", parts[0]+","+parts[2]+","+p); err != nil {
				return "", err
			}
		}
		if _, err := gitEnv(root, env, "update-index", "--add", "--cacheinfo", "100644,"+gatesBlob+",gates.json"); err != nil {
			return "", err
		}
		// WhyNot: 過去のコミットの Makefile・mk・bin で流さない — make の口（check-pkgs・test の PKGS と ALL）や配る台本が今と違い、古い木では無い口もある。
		if _, err := gitEnv(root, env, append([]string{"rm", "--cached", "-r", "-q", "-f", "--ignore-unmatch", "--"}, replayToolPaths...)...); err != nil {
			return "", err
		}
		ls, err := gitLine(root, append([]string{"ls-tree", "-r", tools, "--"}, replayToolPaths...)...)
		if err != nil {
			return "", err
		}
		cmd := exec.Command("git", "-C", root, "update-index", "--index-info")
		cmd.Env = append(os.Environ(), env...)
		cmd.Stdin = strings.NewReader(ls + "\n")
		if b, err := cmd.CombinedOutput(); err != nil {
			return "", fmt.Errorf("git update-index --index-info: %v %s", err, b)
		}
		return gitEnv(root, env, "write-tree")
	}
	files, err := changedFiles(root, c)
	if err != nil {
		return "", "", nil, err
	}
	reverted = revertSources(files)
	baseTree, err := tree(c, nil, "")
	if err != nil {
		return
	}
	targetTree, err := tree(c, reverted, c+"^")
	if err != nil {
		return
	}
	if base, err = gitLine(root, "commit-tree", baseTree, "-m", "replay base "+c); err != nil {
		return
	}
	target, err = gitLine(root, "commit-tree", targetTree, "-p", base, "-m", "replay target "+c+" (red)")
	return
}

// checkoutReplay は台の worktree を target にする。
func checkoutReplay(wt, target string) error {
	if _, err := gitLine(wt, "checkout", "-q", "-f", target); err != nil {
		return err
	}
	// WhyNot: 追跡していない残りを消す — test-select は追跡していないファイルも差に数え、前のコミットの木の物を拾う。
	if _, err := gitLine(wt, "clean", "-fdq"); err != nil {
		return err
	}
	// WhyNot: checkout で render_gl/java の mtime が動くと gl-jar を組み直しに行き、javac の無い木で止まる。jar の名前は元の中身の hash なので、中身が同じなら新しい扱いにしてよい。
	jars, _ := filepath.Glob(filepath.Join(wt, "build", "gl-jar", "fge-gl-*.jar"))
	now := time.Now()
	for _, j := range jars {
		os.Chtimes(j, now, now)
	}
	return nil
}

func replayOne(root, wt, gatesBlob string, f *gates.File, c string) replayRecord {
	rec := replayRecord{Commit: c, Mode: "red", Seconds: map[string]int{}}
	rec.Subject, _ = gitLine(root, "log", "-1", "--format=%s", c)
	fail := func(err error) replayRecord {
		rec.Error = err.Error()
		return rec
	}
	base, target, reverted, err := replayTrees(root, gatesBlob, c)
	if err != nil {
		return fail(err)
	}
	rec.Reverted = reverted
	if err := checkoutReplay(wt, target); err != nil {
		return fail(err)
	}
	t0 := time.Now()
	plan, err := buildPlan(wt, testSelectArgs{since: base})
	if err != nil {
		return fail(err)
	}
	rec.Seconds["select"] = int(time.Since(t0).Seconds())
	rec.Selected = map[string]string{}
	for _, l := range plan.Run {
		rec.Selected[l.ID] = strings.TrimSpace(l.Make + " " + varsLine(l.Vars))
	}
	rec.NotRun = plan.NotRun(false)
	allTest, allCheck := allPackages(f)

	t1 := time.Now()
	m := &maker{wt: wt, logDir: filepath.Join(root, replayDir, "logs", shortSHA(c))}
	full := runReplayFull(m, f, allCheck)
	full.Seconds = int(time.Since(t1).Seconds())
	rec.Full = full
	rec.Seconds["full"] = full.Seconds

	t2 := time.Now()
	in := runReplaySelected(m, plan, f)
	rec.Seconds["selected"] = int(time.Since(t2).Seconds())
	in.FullTestFail, in.FullCheckFail = setOf(full.TestFail), setOf(full.CheckFail)
	in.AllTest, in.AllCheck = allTest, allCheck
	rec.Red = sortedSet(in.SelectedRed)
	v := testselect.Judge(in)
	rec.Verdict = &v
	if len(m.errs) > 0 {
		// WhyNot: 読めなかった赤を緑として数えない — 拾い漏れ 0 に見えてしまう。
		rec.Error = strings.Join(m.errs, "／")
	}
	return rec
}

func varsLine(vars map[string]string) string {
	var keys []string
	for k := range vars {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		parts = append(parts, k+"="+vars[k])
	}
	return strings.Join(parts, " ")
}

func shortSHA(c string) string {
	if len(c) > 12 {
		return c[:12]
	}
	return c
}

// allPackages は全量で流すパッケージ（make test ALL=1 の test を持つ物・check-pkgs に束ねる check の物）。
func allPackages(f *gates.File) (test, check map[string]bool) {
	test, check = map[string]bool{}, map[string]bool{}
	for _, p := range f.Packages {
		if p.Test {
			test[p.ID] = true
		}
		if p.Check {
			check[p.ID] = true
		}
	}
	return
}

// engineFullConsumers は engine_full から feeds でたどれるパッケージ（sync-engine-full が落ちたら古い fpkg を読む物）。
func engineFullConsumers(f *gates.File) map[string]bool {
	feeds := map[string][]string{}
	for _, p := range f.Packages {
		feeds[p.ID] = p.Feeds
	}
	seen := map[string]bool{}
	queue := []string{"engine_full"}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		for _, n := range feeds[cur] {
			if !seen[n] {
				seen[n] = true
				queue = append(queue, n)
			}
		}
	}
	return seen
}

func dirOf(f *gates.File, id string) string {
	for _, p := range f.Packages {
		if p.ID == id {
			return strings.TrimSuffix(p.Dir, "/")
		}
	}
	return id
}

func idOfDir(f *gates.File, dir string) string {
	for _, p := range f.Packages {
		if strings.TrimSuffix(p.Dir, "/") == dir {
			return p.ID
		}
	}
	return dir
}

// runMake は台の worktree で make を流し、出力（ログにも残す）と緑かを返す。
// maker は台の worktree で make を流す（ログは台を消しても残るよう呼んだ木の build/test-select/replay/logs/<コミット>/ へ）。
type maker struct {
	wt, logDir string
	// errs は make が赤なのに答えの行を読めなかった物（その答えを数えに使わない）。
	errs []string
}

func (m *maker) run(logName string, args ...string) (string, bool) {
	cmd := exec.Command("make", append([]string{"--no-print-directory"}, args...)...)
	cmd.Dir = m.wt
	var buf strings.Builder
	logPath := filepath.Join(m.logDir, logName+".log")
	os.MkdirAll(filepath.Dir(logPath), 0o755)
	var w io.Writer = &buf
	if fh, err := os.Create(logPath); err == nil {
		defer fh.Close()
		w = io.MultiWriter(&buf, fh)
	}
	cmd.Stdout, cmd.Stderr = w, w
	err := cmd.Run()
	logf("[replay]     make %s → %v", strings.Join(args, " "), map[bool]string{true: "緑", false: "赤"}[err == nil])
	return buf.String(), err == nil
}

// runReplayFull は全量を流す: sync-engine-full → make test ALL=1 → 赤だけ流し直し → check-pkgs（check の物全部）。
// unread は make が赤なのに赤の行を 1 つも読めなかった時に訳を残す。
func (m *maker) unread(logName string, green bool, redFound int) {
	if !green && redFound == 0 {
		m.errs = append(m.errs, "make が赤なのに赤のパッケージを読めない（"+filepath.Join(m.logDir, logName+".log")+"）")
	}
}

func runReplayFull(m *maker, f *gates.File, allCheck map[string]bool) *replayFull {
	full := &replayFull{}
	_, synced := m.run("full-sync", "sync-engine-full")
	full.SyncFailed = !synced
	out, green := m.run("full-test", "test", "ALL=1", "JOBS="+strconv.Itoa(replayJobs))
	first := testselect.ParseTestLines(out)
	var red []string
	for id, ok := range first {
		if !ok {
			red = append(red, id)
		}
	}
	sort.Strings(red)
	m.unread("full-test", green, len(red))
	failed := map[string]bool{}
	if len(red) > 0 {
		// 6.2: 不安定なテストは 2 回とも赤の物だけを数える。2 回目は赤だった物だけ（全部を 2 回流すと 1 本 約 20 分）。
		again, _ := m.run("full-test-again", "test", "PKGS="+strings.Join(red, " "), "JOBS="+strconv.Itoa(max(2, min(len(red), replayJobs))))
		second := testselect.ParseTestLines(again)
		for _, id := range red {
			if ok, ran := second[id]; ran && ok {
				full.Flaky = append(full.Flaky, id)
			} else {
				failed[id] = true
			}
		}
	}
	var dirs []string
	for _, id := range sortedSet(allCheck) {
		dirs = append(dirs, dirOf(f, id))
	}
	checkFailed := map[string]bool{}
	if len(dirs) > 0 {
		out, green := m.run("full-check-pkgs", "check-pkgs", "DIRS="+strings.Join(dirs, " "))
		reds := testselect.ParseCheckPkgsRed(out)
		m.unread("full-check-pkgs", green, len(reds))
		for _, d := range reds {
			checkFailed[idOfDir(f, d)] = true
		}
	}
	if full.SyncFailed {
		// WhyNot: sync が落ちた木のテンプレート・bench の緑を信じない — 置き場に残った前の fpkg を読んで流れている。
		for id := range engineFullConsumers(f) {
			if p := pkgOf(f, id); p != nil && p.Test {
				failed[id] = true
			} else if p != nil && p.Check {
				checkFailed[id] = true
			}
		}
	}
	full.TestFail, full.CheckFail = sortedSet(failed), sortedSet(checkFailed)
	return full
}

func pkgOf(f *gates.File, id string) *gates.Package {
	for i := range f.Packages {
		if f.Packages[i].ID == id {
			return &f.Packages[i]
		}
	}
	return nil
}

// runReplaySelected は選んだ門のうち、パッケージの答えを持つ物（sync-engine-full・check・test・check-pkgs）を流す。
// ほかの門（render-all・gl-parity など）は全量の側に比べる物が無いので流さない（6.2 の flix test 以外は次の段）。
func runReplaySelected(m *maker, plan *testselect.Plan, f *gates.File) testselect.JudgeInput {
	in := testselect.JudgeInput{SelectedTest: map[string]bool{}, SelectedCheck: map[string]bool{}, SelectedRed: map[string]bool{}, TypeRed: map[string]bool{}}
	byID := map[string]testselect.Line{}
	for _, l := range plan.Run {
		byID[l.ID] = l
	}
	if l, ok := byID["sync-engine-full"]; ok {
		if _, green := m.run("sel-sync", l.Make); !green {
			for id := range engineFullConsumers(f) {
				in.TypeRed[id] = true
			}
		}
	}
	if l, ok := byID["check"]; ok {
		if _, green := m.run("sel-check", l.Make); !green {
			// 根の make check は root へ feeds を持つ層と根の src を 1 本の木で組む。
			for _, p := range f.Packages {
				for _, n := range p.Feeds {
					if n == "root" {
						in.TypeRed[p.ID] = true
					}
				}
			}
			in.TypeRed["root"] = true
		}
	}
	if l, ok := byID["test"]; ok {
		pkgs := strings.Fields(l.Vars["PKGS"])
		for _, id := range pkgs {
			in.SelectedTest[id] = true
		}
		// WhyNot: JOBS=1 で流さない — 逐次の make test は最初の赤で止まり、[test] PASS|FAIL の行を出さない。
		out, green := m.run("sel-test", "test", "PKGS="+strings.Join(pkgs, " "), "JOBS="+strconv.Itoa(max(2, min(len(pkgs), replayJobs))))
		n := 0
		for id, ok := range testselect.ParseTestLines(out) {
			if !ok {
				in.SelectedRed[id] = true
				n++
			}
		}
		m.unread("sel-test", green, n)
	}
	if l, ok := byID["check-pkgs"]; ok {
		dirs := strings.Fields(l.Vars["DIRS"])
		for _, d := range dirs {
			in.SelectedCheck[idOfDir(f, d)] = true
		}
		out, green := m.run("sel-check-pkgs", "check-pkgs", "DIRS="+strings.Join(dirs, " "))
		reds := testselect.ParseCheckPkgsRed(out)
		m.unread("sel-check-pkgs", green, len(reds))
		for _, d := range reds {
			in.SelectedRed[idOfDir(f, d)] = true
		}
	}
	return in
}

func setOf(xs []string) map[string]bool {
	m := map[string]bool{}
	for _, x := range xs {
		m[x] = true
	}
	return m
}

func sortedSet(m map[string]bool) []string {
	var out []string
	for k, v := range m {
		if v {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func writeJSONFile(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

func replaySummaryLine(r replayRecord) string {
	if r.Error != "" {
		return "エラー: " + r.Error
	}
	v := r.Verdict
	return fmt.Sprintf("全量の赤 test %d・check %d／選んで拾った %d・型検査で拾った %d・拾い漏れ %d・食い違い %d・倒れた %v／秒 選ぶ %d 全量 %d 選んだ物 %d",
		len(r.Full.TestFail), len(r.Full.CheckFail), len(v.BySelect), len(v.ByType), len(v.Missed), len(v.Mismatch), v.FellBack,
		r.Seconds["select"], r.Seconds["full"], r.Seconds["selected"])
}

func writeReplayTable(out *strings.Builder, recs []replayRecord) {
	out.WriteString("| コミット | 戻した src | 全量の赤 | 選んだ test | 選んで拾った | 型検査で拾った | 拾い漏れ | 食い違い | 倒れた | 全量 秒 | 選んだ物 秒 |\n|---|---|---|---|---|---|---|---|---|---|---|\n")
	for _, r := range recs {
		if r.Error != "" {
			fmt.Fprintf(out, "| %s | エラー: %s |||||||||\n", shortSHA(r.Commit), r.Error)
			continue
		}
		v := r.Verdict
		fmt.Fprintf(out, "| %s | %d | %s | %s | %s | %s | %s | %s | %v | %d | %d |\n", shortSHA(r.Commit), len(r.Reverted),
			strings.Join(append(append([]string{}, r.Full.TestFail...), r.Full.CheckFail...), " "), r.Selected["test"],
			strings.Join(v.BySelect, " "), strings.Join(v.ByType, " "), strings.Join(v.Missed, " "), strings.Join(v.Mismatch, " "), v.FellBack,
			r.Seconds["full"], r.Seconds["selected"])
	}
}
