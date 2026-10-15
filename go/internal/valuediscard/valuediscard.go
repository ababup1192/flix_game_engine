// Package valuediscard は、Flix で値を `let _ =` で捨てている所を見る。
//
// Flix は純粋な式の値を `let _ =` で捨てると、コード生成で式ごと消す (コンパイラの説明文に
// そう書いてある)。中で unsafe IO を使う知らせ (Log.warn・ViewCtx#warnOnce) も、bug! による
// 止めも、黙って消える。効果のある式なら `discard` で同じことが書け、こちらは純粋な式に
// 使うとコンパイラが止める。だから `let _ =` は全部止めて、直し方を 3 つに分けて出す。
package valuediscard

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
)

// Hit は 1 件の違反。
type Hit struct {
	Path string
	Line int
	Code string
}

// FileHits は指定したファイルだけを見る。
func (r *Rules) FileHits(root string, paths []string) []Hit {
	var hits []Hit
	for _, p := range paths {
		if !r.IsFlix(p) {
			continue
		}
		data, err := os.ReadFile(absOf(root, p))
		if err != nil {
			continue
		}
		hits = append(hits, r.textHits(p, string(data))...)
	}
	return hits
}

func (r *Rules) textHits(path, text string) []Hit {
	var hits []Hit
	for i, line := range strings.Split(text, "\n") {
		if r.Pattern.MatchString(stripNoise(line)) {
			hits = append(hits, Hit{Path: path, Line: i + 1, Code: strings.TrimSpace(line)})
		}
	}
	return hits
}

// stripNoise はコメントと文字列の中身を落とす。
// WhyNot: 落とさないと、説明文 (「`let _ =` と書かない」) を書き方と読み違える。
func stripNoise(line string) string {
	var b strings.Builder
	inStr := false
	for i := 0; i < len(line); i++ {
		c := line[i]
		switch {
		case inStr:
			if c == '\\' {
				i++
				continue
			}
			if c == '"' {
				inStr = false
				b.WriteByte(' ')
			}
		case c == '"':
			inStr = true
			b.WriteByte(' ')
		case c == '/' && i+1 < len(line) && line[i+1] == '/':
			return b.String()
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// Run は fge value-discard の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	var files []string
	all := false
	for _, a := range args {
		switch {
		case a == "--all":
			all = true
		case !strings.HasPrefix(a, "--"):
			files = append(files, a)
		}
	}
	if all {
		paths, err := rules.allPaths(root)
		if err != nil {
			return 2, err
		}
		files = paths
	}
	if len(files) == 0 {
		fmt.Fprintln(out, "[lint-value-discard] 見るファイルがありません")
		return 0, nil
	}
	hits := rules.FileHits(root, files)
	if len(hits) == 0 {
		fmt.Fprintf(out, "[lint-value-discard] OK (%d ファイル)\n", len(files))
		return 0, nil
	}
	for _, h := range hits {
		fmt.Fprintf(errOut, "!! %s:%d 値を let _ = で捨てています: %s\n", h.Path, h.Line, h.Code)
	}
	fmt.Fprintln(errOut, rules.Hint)
	return 1, nil
}

func (r *Rules) allPaths(root string) ([]string, error) {
	tracked, err := git(root, "ls-files", "-z")
	if err != nil {
		return nil, err
	}
	untracked, err := git(root, "ls-files", "-z", "-o", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var paths []string
	for _, p := range append(strings.Split(tracked, "\x00"), strings.Split(untracked, "\x00")...) {
		if p == "" || !r.InScope(p) || seen[p] {
			continue
		}
		seen[p] = true
		paths = append(paths, p)
	}
	sort.Strings(paths)
	return paths, nil
}

func git(root string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = root
	body, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s が失敗しました: %v", strings.Join(args, " "), err)
	}
	return string(body), nil
}

func absOf(root, path string) string {
	if strings.HasPrefix(path, "/") {
		return path
	}
	return root + "/" + path
}
