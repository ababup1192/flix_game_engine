package testselect

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Changes は git の差分（base との差・消したファイルを含む）と追跡していないファイル。base が空なら HEAD。
// since を渡した時は merge-base（since の後に since の側へ入った差を拾わない）。
func Changes(root, since string) ([]Change, error) {
	base := "HEAD"
	if since != "" {
		mb, err := git(root, "merge-base", since, "HEAD")
		if err != nil {
			return nil, fmt.Errorf("git merge-base %s HEAD: %v", since, err)
		}
		base = strings.TrimSpace(mb)
	}
	out, err := git(root, "diff", "--name-status", "--no-renames", base)
	if err != nil {
		return nil, fmt.Errorf("git diff %s: %v", base, err)
	}
	seen := map[string]bool{}
	var list []Change
	for _, line := range strings.Split(out, "\n") {
		status, p, ok := strings.Cut(line, "\t")
		if !ok || seen[p] {
			continue
		}
		seen[p] = true
		c := Change{Path: p, Deleted: strings.HasPrefix(status, "D")}
		if filepath.Base(p) == "flix.toml" && strings.HasPrefix(status, "M") {
			c.VersionOnly = versionOnly(root, base, p)
		}
		list = append(list, c)
	}
	untracked, err := git(root, "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	for _, p := range strings.Split(untracked, "\n") {
		if p != "" && !seen[p] {
			seen[p] = true
			list = append(list, Change{Path: p})
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Path < list[j].Path })
	return list, nil
}

// FilesChanges は --files のパス（差が見えないので flix.toml は version だけとみなさない）。
func FilesChanges(root string, paths []string) []Change {
	var list []Change
	for _, p := range paths {
		p = strings.TrimPrefix(filepath.ToSlash(p), "./")
		_, err := os.Lstat(filepath.Join(root, p))
		list = append(list, Change{Path: p, Deleted: os.IsNotExist(err)})
	}
	return list
}

var versionLine = regexp.MustCompile(`^[+-]\s*version\s*=\s*"[^"]*"\s*$`)

// versionOnly は flix.toml の差が [package] の version の行だけか。
// WhyNot: 依存の行（"x" = { version = … }）を version の差に数えない — 依存の版は全部を流す側。行頭が version = の行だけを見る。
func versionOnly(root, base, p string) bool {
	diff, err := git(root, "diff", "-U0", base, "--", p)
	return err == nil && VersionOnlyDiff(diff)
}

// VersionOnlyDiff は -U0 の diff の足した行と消した行が、全部 version = "…" の行か。
func VersionOnlyDiff(diff string) bool {
	n := 0
	for _, l := range strings.Split(diff, "\n") {
		if strings.HasPrefix(l, "+++") || strings.HasPrefix(l, "---") || !(strings.HasPrefix(l, "+") || strings.HasPrefix(l, "-")) {
			continue
		}
		if !versionLine.MatchString(l) {
			return false
		}
		n++
	}
	return n > 0
}

func git(root string, args ...string) (string, error) {
	// WhyNot: core.quotePath を既定のままにしない — 日本語のパスが "\343…" と引用され、持ち主が引けずに全部へ倒れる。
	cmd := exec.Command("git", append([]string{"-c", "core.quotePath=off"}, args...)...)
	cmd.Dir = root
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("%v: %s", err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimRight(string(out), "\n"), nil
}

// RealEnv は本物の go list と find を使う Env。
type RealEnv struct {
	Root string
	list *goList
}

type goPkg struct {
	path, dir string
	imports   []string
	deps      []string
}

type goList struct {
	module string
	pkgs   map[string]*goPkg
}

func (e *RealEnv) load() (*goList, error) {
	if e.list != nil {
		return e.list, nil
	}
	cmd := exec.Command("go", "list", "-f", "{{.ImportPath}}\t{{.Dir}}\t{{join .Imports \" \"}} {{join .TestImports \" \"}} {{join .XTestImports \" \"}}\t{{join .Deps \" \"}}", "./...")
	cmd.Dir = filepath.Join(e.Root, "go")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("go list: %v: %s", err, strings.TrimSpace(stderr.String()))
	}
	cm := exec.Command("go", "list", "-m")
	cm.Dir = filepath.Join(e.Root, "go")
	mod, err := cm.Output()
	if err != nil {
		return nil, fmt.Errorf("go list -m: %v", err)
	}
	l := &goList{module: strings.TrimSpace(string(mod)), pkgs: map[string]*goPkg{}}
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 1024*1024), 64*1024*1024)
	for sc.Scan() {
		f := strings.Split(sc.Text(), "\t")
		if len(f) < 4 {
			continue
		}
		l.pkgs[f[0]] = &goPkg{path: f[0], dir: f[1], imports: strings.Fields(f[2]), deps: strings.Fields(f[3])}
	}
	e.list = l
	return l, nil
}

// nameOf は import の path の go-test の名前（module 直下 → .・module/internal/<x>/… → x）。module の外は空。
func (l *goList) nameOf(importPath string) string {
	if importPath == l.module {
		return "."
	}
	rest, ok := strings.CutPrefix(importPath, l.module+"/")
	if !ok {
		return ""
	}
	if r, ok := strings.CutPrefix(rest, "internal/"); ok {
		name, _, _ := strings.Cut(r, "/")
		return name
	}
	return "."
}

// GoAllPkgs は go のパッケージの名前の全部。
func (e *RealEnv) GoAllPkgs() ([]string, error) {
	l, err := e.load()
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for path := range l.pkgs {
		if n := l.nameOf(path); n != "" {
			out[n] = true
		}
	}
	return sortedKeys(out), nil
}

// GoImporters は名前の go のパッケージと、import（テストの import を含む）でたどって頼る側。
func (e *RealEnv) GoImporters(names []string) ([]string, error) {
	l, err := e.load()
	if err != nil {
		return nil, err
	}
	importers := map[string][]string{}
	for _, p := range l.pkgs {
		for _, imp := range p.imports {
			importers[imp] = append(importers[imp], p.path)
		}
	}
	want := map[string]bool{}
	for _, n := range names {
		want[n] = true
	}
	seen := map[string]bool{}
	var queue []string
	for path := range l.pkgs {
		if want[l.nameOf(path)] {
			seen[path] = true
			queue = append(queue, path)
		}
	}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		for _, up := range importers[cur] {
			if !seen[up] {
				seen[up] = true
				queue = append(queue, up)
			}
		}
	}
	out := map[string]bool{}
	for path := range seen {
		if n := l.nameOf(path); n != "" {
			out[n] = true
		}
	}
	for n := range want {
		out[n] = true
	}
	return sortedKeys(out), nil
}

// GoExecPkgs は本体かテストか、module の中の import の先に exec.Command を持つ go のパッケージ。
// WhyNot: 標準ライブラリの Deps を数えない — os/exec を経てほぼ全部が -count=1 になり、cache の意味が無くなる。
func (e *RealEnv) GoExecPkgs() ([]string, error) {
	l, err := e.load()
	if err != nil {
		return nil, err
	}
	direct := map[string]bool{}
	for path, p := range l.pkgs {
		if dirExecs(p.dir) {
			direct[path] = true
		}
	}
	out := map[string]bool{}
	for path, p := range l.pkgs {
		hit := direct[path]
		for _, d := range p.deps {
			if direct[d] {
				hit = true
				break
			}
		}
		if hit {
			if n := l.nameOf(path); n != "" {
				out[n] = true
			}
		}
	}
	return sortedKeys(out), nil
}

func dirExecs(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, en := range entries {
		if en.IsDir() || !strings.HasSuffix(en.Name(), ".go") {
			continue
		}
		body, err := os.ReadFile(filepath.Join(dir, en.Name()))
		if err == nil && bytes.Contains(body, []byte("exec.Command")) {
			return true
		}
	}
	return false
}

// EngineSrcDirs は engine_full へ入る src（fpkg の新しさを見る所）。
var EngineSrcDirs = []string{"engine/src", "render_gl/src", "engine_world/src", "engine_tools/src", "render_gl/java"}

// FpkgStale は engine_full の fpkg が無いか、engine 側の src（.flix）か render_gl/java より古いか。
// WhyNot: 差分だけで決めない — commit の後・ブランチを替えた後・pull の後は差分が無くても置き場の fpkg が古い。
func (e *RealEnv) FpkgStale() (bool, string) {
	fpkg := filepath.Join(e.Root, "engine_full", "artifact", "package.fpkg")
	info, err := os.Stat(fpkg)
	if err != nil {
		return true, "engine_full の fpkg が無い"
	}
	newer := ""
	for _, d := range EngineSrcDirs {
		_ = filepath.WalkDir(filepath.Join(e.Root, d), func(p string, de os.DirEntry, err error) error {
			if err != nil || newer != "" {
				return filepath.SkipDir
			}
			if de.IsDir() {
				return nil
			}
			if strings.HasSuffix(p, ".flix") || strings.HasPrefix(d, "render_gl/java") {
				if fi, err := de.Info(); err == nil && fi.ModTime().After(info.ModTime()) {
					newer, _ = filepath.Rel(e.Root, p)
				}
			}
			return nil
		})
	}
	if newer != "" {
		return true, "engine_full の fpkg が " + newer + " より古い"
	}
	return false, ""
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
