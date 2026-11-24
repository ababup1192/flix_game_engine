// Package posts はダッシュボードの置き場 posts（AI が見せる物と人の返事）を読み書きする。
// 置き場は main の作業ツリーの <ゲームの根の prefix>/debug/dashboard/posts に 1 つだけ置き、worktree から書いても main 側へ書く。
// 決まりの本文は plans/dashboard.md の 3 節。
package posts

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Roots は今のフォルダから決まる置き場の根。
type Roots struct {
	// GameRoot は今のフォルダから上へたどって最初に flix.toml のあるフォルダ（無ければ今のフォルダ）。
	GameRoot string
	// Worktree は今の作業ツリーの根（git でなければ空）。
	Worktree string
	// Prefix は GameRoot を作業ツリーの根からの相対にした物（/ 区切り・根なら空）。
	Prefix string
	// MainRoot は置き場を置くゲームの根（main の作業ツリー + Prefix）。
	MainRoot string
	// Branch は今の枝の名前（git でない・切り離した HEAD なら空）。
	Branch string
}

// PostsDir は posts の置き場。
func (r Roots) PostsDir() string {
	return filepath.Join(r.MainRoot, "debug", "dashboard", "posts")
}

// Resolve は cwd から置き場の根を決める。
func Resolve(cwd string) Roots {
	game := findFlixToml(cwd)
	if game == "" {
		game = cwd
	}
	game = RealPath(game)
	r := Roots{GameRoot: game, MainRoot: game}
	top := gitOut(game, "rev-parse", "--show-toplevel")
	if top == "" {
		return r
	}
	r.Worktree = RealPath(filepath.FromSlash(top))
	if rel, err := filepath.Rel(r.Worktree, game); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
		r.Prefix = filepath.ToSlash(rel)
	}
	if b := gitOut(game, "symbolic-ref", "--short", "-q", "HEAD"); b != "" {
		r.Branch = b
	}
	common := gitOut(game, "rev-parse", "--git-common-dir")
	if common == "" {
		return r
	}
	common = filepath.FromSlash(common)
	if !filepath.IsAbs(common) {
		common = filepath.Join(game, common)
	}
	// WhyNot: common-dir の名前が .git でない時（bare のリポの worktree・submodule）に親を main と見ない — 親は作業ツリーでない。
	if filepath.Base(common) != ".git" {
		return r
	}
	r.MainRoot = filepath.Join(RealPath(filepath.Dir(common)), filepath.FromSlash(r.Prefix))
	return r
}

// Worktree は git worktree list の 1 件。
type Worktree struct {
	Path   string
	Branch string
}

// Worktrees は dir のリポの全部の作業ツリー（main が先頭）。git でなければ空。
func Worktrees(dir string) []Worktree {
	out := gitOut(dir, "worktree", "list", "--porcelain")
	var list []Worktree
	sc := bufio.NewScanner(strings.NewReader(out))
	bare := false
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "worktree "):
			list = append(list, Worktree{Path: RealPath(filepath.FromSlash(strings.TrimPrefix(line, "worktree ")))})
			bare = false
		case line == "bare":
			bare = true
			list = list[:len(list)-1]
		case strings.HasPrefix(line, "branch ") && len(list) > 0 && !bare:
			list[len(list)-1].Branch = strings.TrimPrefix(strings.TrimPrefix(line, "branch "), "refs/heads/")
		}
	}
	return list
}

func findFlixToml(dir string) string {
	for d := dir; ; d = filepath.Dir(d) {
		if info, err := os.Stat(filepath.Join(d, "flix.toml")); err == nil && info.Mode().IsRegular() {
			return d
		}
		if filepath.Dir(d) == d {
			return ""
		}
	}
}

// RealPath は symlink を辿った絶対パス（辿れなければ絶対パスのまま）。
// WhyNot: 字面のまま比べない — macOS の /var と /private/var のように、git が返す根と今のフォルダの字面が違う。
func RealPath(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		abs = filepath.Clean(p)
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		return real
	}
	return abs
}

// SamePath は 2 つのパスが symlink を辿って同じ所か。
func SamePath(a, b string) bool {
	if a == "" || b == "" {
		return a == b
	}
	return RealPath(a) == RealPath(b)
}

func gitOut(dir string, args ...string) string {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	if cmd.Run() != nil {
		return ""
	}
	return strings.TrimSpace(out.String())
}
