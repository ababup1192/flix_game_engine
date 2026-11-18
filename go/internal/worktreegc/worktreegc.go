// Package worktreegc は、もう要らない git worktree を一覧にし、頼まれたら git worktree remove で消す。
//
//	fge worktree-gc [--base <枝>] [--age <時間>] [--apply]
//
// 消してよい物 = 次の全部を満たす worktree（main の作業ツリーと、いま居る worktree は数えない）:
//   - HEAD のコミットが base（既定 main）に取り込み済み
//   - 未コミットの変更 0・未追跡のファイル 0（git status --porcelain が空。.gitignore の物は数えない）
//   - その下を今いるフォルダにしているプロセスが無い
//   - 最後に触ってから age 時間（既定 12）より古い（index・HEAD・reflog の時刻）
//   - git worktree lock されていない
//
// 枝は消さない。結果の数と大きさは <git の共通フォルダ>/fge-worktree-gc.json に書き、make status が 1 行に読む。
package worktreegc

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// CacheName は共通フォルダに置く結果の名前。
const CacheName = "fge-worktree-gc.json"

// Cache は make status が読む結果。
type Cache struct {
	Time       time.Time `json:"time"`
	Total      int       `json:"total"`
	Removable  int       `json:"removable"`
	Bytes      int64     `json:"bytes"`
	Base       string    `json:"base"`
	AppliedOut int       `json:"applied,omitempty"`
}

// Worktree は git worktree list --porcelain の 1 件。
type Worktree struct {
	Path     string
	Head     string
	Branch   string // refs/heads/ を外した名前。detached なら空
	Locked   bool
	Prunable bool
	Bare     bool
}

// ParsePorcelain は git worktree list --porcelain の出力を読む（先頭が main の作業ツリー）。
func ParsePorcelain(text string) []Worktree {
	var out []Worktree
	var cur *Worktree
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := sc.Text()
		key, val, _ := strings.Cut(line, " ")
		switch key {
		case "worktree":
			out = append(out, Worktree{Path: val})
			cur = &out[len(out)-1]
		case "HEAD":
			if cur != nil {
				cur.Head = val
			}
		case "branch":
			if cur != nil {
				cur.Branch = strings.TrimPrefix(val, "refs/heads/")
			}
		case "locked":
			if cur != nil {
				cur.Locked = true
			}
		case "prunable":
			if cur != nil {
				cur.Prunable = true
			}
		case "bare":
			if cur != nil {
				cur.Bare = true
			}
		}
	}
	return out
}

// Verdict は 1 本の判定。
type Verdict struct {
	Worktree
	Keep  string // 残す理由（空なら消してよい）
	Age   time.Duration
	Bytes int64
}

type options struct {
	base  string
	age   time.Duration
	apply bool
}

const usage = `fge worktree-gc — 取り込み済みで変更の無い worktree を一覧にする（--apply で git worktree remove）
  fge worktree-gc [--base main] [--age 12] [--apply]
  --base  取り込み済みかを見る枝（既定 main）
  --age   最後に触ってからこの時間（h）より古い物だけ（既定 12。作ったばかりでまだ何も書いていない worktree を消さない）
  --apply 消してよい物を git worktree remove する（枝は残す）
`

// Run は足元（root）の git から worktree を集めて判定し、表を out へ書く。
func Run(out, errOut io.Writer, root string, args []string) (int, error) {
	o := options{base: "main", age: 12 * time.Hour}
	for i := 0; i < len(args); i++ {
		switch a := args[i]; a {
		case "-h", "--help":
			fmt.Fprint(out, usage)
			return 0, nil
		case "--apply":
			o.apply = true
		case "--base", "--age":
			if i+1 >= len(args) {
				return 2, fmt.Errorf("%s の後に値がありません", a)
			}
			i++
			if a == "--base" {
				o.base = args[i]
				continue
			}
			h, err := strconv.ParseFloat(args[i], 64)
			if err != nil || h < 0 {
				return 2, fmt.Errorf("--age は時間の数: %q", args[i])
			}
			o.age = time.Duration(h * float64(time.Hour))
		default:
			return 2, fmt.Errorf("知らない引数: %s\n%s", a, usage)
		}
	}
	common, err := git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return 2, fmt.Errorf("git の中でない: %v", err)
	}
	if _, err := git(root, "rev-parse", "--verify", "--quiet", o.base+"^{commit}"); err != nil {
		return 2, fmt.Errorf("--base %s の枝が無い", o.base)
	}
	listing, err := git(root, "worktree", "list", "--porcelain")
	if err != nil {
		return 2, err
	}
	wts := ParsePorcelain(listing)
	if len(wts) == 0 {
		return 2, fmt.Errorf("worktree が読めない")
	}
	here, _ := git(root, "rev-parse", "--show-toplevel")
	cwds := processCwds()
	now := time.Now()
	vs := make([]Verdict, len(wts)-1)
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i, w := range wts[1:] {
		wg.Add(1)
		go func(i int, w Worktree) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			vs[i] = judge(w, o, here, cwds, now)
		}(i, w)
	}
	wg.Wait()
	sort.Slice(vs, func(i, j int) bool {
		if (vs[i].Keep == "") != (vs[j].Keep == "") {
			return vs[i].Keep == ""
		}
		return vs[i].Path < vs[j].Path
	})
	var removable []Verdict
	var bytesSum int64
	for _, v := range vs {
		if v.Keep == "" {
			removable = append(removable, v)
			bytesSum += v.Bytes
		}
	}
	fmt.Fprintf(out, "[worktree-gc] worktree %d 本（main を除く）のうち、%s に取り込み済み・変更なし・使っているプロセスなし・%s より古い物: %d 本・約 %s\n",
		len(vs), o.base, humanAge(o.age), len(removable), humanBytes(bytesSum))
	for _, v := range removable {
		fmt.Fprintf(out, "  消せる  %-8s %-8s %-28s %s\n", humanBytes(v.Bytes), humanAge(v.Age), branchLabel(v.Worktree), v.Path)
	}
	kept := map[string]int{}
	for _, v := range vs {
		if v.Keep != "" {
			kept[v.Keep]++
		}
	}
	if len(kept) > 0 {
		var parts []string
		for k, n := range kept {
			parts = append(parts, fmt.Sprintf("%s %d", k, n))
		}
		sort.Strings(parts)
		fmt.Fprintf(out, "  残す: %s\n", strings.Join(parts, "・"))
	}
	c := Cache{Time: now, Total: len(vs), Removable: len(removable), Bytes: bytesSum, Base: o.base}
	if !o.apply {
		if len(removable) > 0 {
			fmt.Fprintln(out, "  消すのは make worktree-gc APPLY=1（git worktree remove。枝は残す）")
		}
		writeCache(common, c)
		return 0, nil
	}
	failed := 0
	for _, v := range removable {
		if msg, err := git(root, "worktree", "remove", v.Path); err != nil {
			failed++
			fmt.Fprintf(errOut, "  消せなかった: %s（%s）\n", v.Path, strings.TrimSpace(msg))
			continue
		}
		c.AppliedOut++
	}
	_, _ = git(root, "worktree", "prune")
	c.Removable -= c.AppliedOut
	c.Total -= c.AppliedOut
	c.Bytes = 0
	writeCache(common, c)
	fmt.Fprintf(out, "[worktree-gc] 消した: %d 本（枝は残した）", c.AppliedOut)
	if failed > 0 {
		fmt.Fprintf(out, "・消せなかった: %d 本", failed)
	}
	fmt.Fprintln(out)
	if failed > 0 {
		return 1, nil
	}
	return 0, nil
}

func judge(w Worktree, o options, here string, cwds []string, now time.Time) Verdict {
	v := Verdict{Worktree: w}
	switch {
	case w.Bare:
		v.Keep = "bare"
		return v
	case w.Prunable:
		v.Keep = "フォルダが無い（git worktree prune で片付く）"
		return v
	case w.Locked:
		v.Keep = "lock 済み"
		return v
	case samePath(w.Path, here):
		v.Keep = "いま居る worktree"
		return v
	}
	gitDir, err := git(w.Path, "rev-parse", "--path-format=absolute", "--git-dir")
	if err == nil {
		v.Age = now.Sub(lastTouched(gitDir))
	}
	switch {
	case w.Head == "":
		v.Keep = "HEAD が無い"
	case !isAncestor(w.Path, w.Head, o.base):
		v.Keep = o.base + " に取り込まれていないコミットがある"
	case dirty(w.Path):
		v.Keep = "未コミットの変更か未追跡のファイルがある"
	case inUse(w.Path, cwds):
		v.Keep = "その下で動いているプロセスがある"
	case v.Age < o.age:
		v.Keep = "最近触った"
	}
	if v.Keep == "" {
		v.Bytes = dirBytes(w.Path)
	}
	return v
}

func git(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return strings.TrimSpace(buf.String()), err
}

func isAncestor(dir, head, base string) bool {
	_, err := git(dir, "merge-base", "--is-ancestor", head, base)
	return err == nil
}

func dirty(dir string) bool {
	out, err := git(dir, "status", "--porcelain", "--untracked-files=normal")
	return err != nil || out != ""
}

// lastTouched は worktree の git フォルダの index・HEAD・reflog のうち一番新しい時刻。
func lastTouched(gitDir string) time.Time {
	var t time.Time
	for _, name := range []string{"index", "HEAD", filepath.Join("logs", "HEAD")} {
		if info, err := os.Stat(filepath.Join(gitDir, name)); err == nil && info.ModTime().After(t) {
			t = info.ModTime()
		}
	}
	return t
}

// processCwds は全部のプロセスの今いるフォルダ（lsof が無い・読めない時は空）。
func processCwds() []string {
	out, err := exec.Command("lsof", "-a", "-d", "cwd", "-Fn").Output()
	if err != nil && len(out) == 0 {
		return nil
	}
	var cwds []string
	for _, line := range strings.Split(string(out), "\n") {
		if p, ok := strings.CutPrefix(line, "n"); ok {
			cwds = append(cwds, p)
		}
	}
	return cwds
}

func inUse(path string, cwds []string) bool {
	real := realPath(path)
	for _, c := range cwds {
		for _, p := range []string{path, real} {
			if c == p || strings.HasPrefix(c, p+string(filepath.Separator)) {
				return true
			}
		}
	}
	return false
}

func realPath(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

func samePath(a, b string) bool {
	return a != "" && b != "" && realPath(a) == realPath(b)
}

// dirBytes はフォルダの下の大きさ（symlink の先は数えない。worktree-seed が main から張った lib などを足さない）。
func dirBytes(dir string) int64 {
	var n int64
	_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if info, err := d.Info(); err == nil {
			n += info.Size()
		}
		return nil
	})
	return n
}

func writeCache(common string, c Cache) {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(common, CacheName), append(data, '\n'), 0o644)
}

// ReadCache は共通フォルダの結果を読む（無ければ false）。
func ReadCache(common string) (Cache, bool) {
	var c Cache
	data, err := os.ReadFile(filepath.Join(common, CacheName))
	if err != nil || json.Unmarshal(data, &c) != nil {
		return c, false
	}
	return c, true
}

func branchLabel(w Worktree) string {
	if w.Branch == "" {
		return "(detached)"
	}
	return w.Branch
}

func humanAge(d time.Duration) string {
	switch {
	case d >= 48*time.Hour:
		return fmt.Sprintf("%d日", int(d.Hours()/24))
	case d >= time.Hour:
		return fmt.Sprintf("%d時間", int(d.Hours()))
	default:
		return fmt.Sprintf("%d分", int(d.Minutes()))
	}
}

// HumanBytes は大きさを GB・MB で読みやすくする。
func HumanBytes(n int64) string { return humanBytes(n) }

func humanBytes(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%d MB", n>>20)
	default:
		return fmt.Sprintf("%d KB", n>>10)
	}
}
