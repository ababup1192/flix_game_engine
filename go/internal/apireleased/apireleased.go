package apireleased

// apireleased — api-digest に載っているのに、リリース済みの版には入っていない宣言を
// 挙げるゲート。
//
//	fge-go check-api-released              未リリースの宣言を一覧する
//	fge-go check-api-released <語>         その語に当たる宣言だけ見る
//	fge-go check-api-released --root DIR   リポジトリのルートを差し替える
//
// 作業ツリーの pub 宣言のうち、`v<VERSION>` のタグのソースに無い名前を挙げる。
// タグが取れないとき（浅い clone など）は何も言わずに 0 で終わる。
//
// WhyNot: 宣言の抽出に flixdecl を使わないのは、タグ側を `git grep` が返す行だけで
// 組み直すため、こちら側も 1 行にかかる正規表現で数える必要があるから。
// flixdecl（複数行の宣言まで解く）に寄せると、作業ツリー側とタグ側で拾う件数が
// 食い違い、未リリース扱いになる名前が変わる。ファイルの並べ方だけ借りる。

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/flixdecl"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// pySpace は空白とみなす字の集合（Unicode の空白すべて）。pyNonSpace はその補集合。
const (
	pySpace    = `[\t\n\v\f\r \x{1c}-\x{1f}\x{85}\p{Z}]`
	pyNonSpace = `[^\t\n\v\f\r \x{1c}-\x{1f}\x{85}\p{Z}]`
)

var (
	versionRe = regexp.MustCompile(`(?m)^VERSION` + pySpace + `*:=` + pySpace + `*(` + pyNonSpace + `+)`)

	// pub 宣言の名前だけを拾う（見る範囲は def / enum / type alias / eff）。
	declBody = pySpace + `*pub` + pySpace + `+(?:def|eff|enum|type` + pySpace +
		`+alias)` + pySpace + `+([A-Za-z_][A-Za-z0-9_]*)`
	declRe = regexp.MustCompile(`(?m)^` + declBody)
	// declLineRe は 1 行に対する match()（先頭固定）。
	declLineRe = regexp.MustCompile(`\A` + declBody)

	modBody     = `(?:pub` + pySpace + `+)?mod` + pySpace + `+([A-Za-z_][A-Za-z0-9_.]*)` + pySpace + `*\{`
	modSplitRe  = regexp.MustCompile(`(?m)^` + modBody)
	modLineRe   = regexp.MustCompile(`\A` + modBody)
	gitGrepExpr = `^((pub[[:space:]]+)?mod[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*\{` +
		`|[[:space:]]*pub[[:space:]]+(def|eff|enum|type[[:space:]]+alias)[[:space:]])`
)

// version は Makefile の `VERSION := x.y.z` を読む。
func version(root string) (string, bool, error) {
	text, err := pxlib.ReadTextReplace(filepath.Join(root, "Makefile"))
	if err != nil {
		return "", false, fmt.Errorf("Makefile を読めません: %v", err)
	}
	m := versionRe.FindStringSubmatch(text)
	if m == nil {
		return "", false, nil
	}
	return m[1], true, nil
}

// perModule は `mod <名前> {` ごとに、その中の pub 宣言の名前を返す。
// WhyNot: mod の入れ子をたたまないのは、`mod ... {` の位置で平らに切るため。
// 内側の mod の後ろに書かれた宣言は内側に属する扱いになる。
func perModule(text string) []struct {
	Mod   string
	Names []string
} {
	type entry = struct {
		Mod   string
		Names []string
	}
	var out []entry
	locs := modSplitRe.FindAllStringSubmatchIndex(text, -1)
	prev := 0
	// chunks（前置き, 名前, 本文, 名前, 本文, ...）の形に切り分ける。
	var chunks []string
	for _, l := range locs {
		chunks = append(chunks, text[prev:l[0]])
		chunks = append(chunks, text[l[2]:l[3]])
		prev = l[1]
	}
	chunks = append(chunks, text[prev:])
	for i := 1; i < len(chunks); i += 2 {
		var names []string
		for _, m := range declRe.FindAllStringSubmatch(chunks[i+1], -1) {
			names = append(names, m[1])
		}
		out = append(out, entry{Mod: chunks[i], Names: names})
	}
	return out
}

// declarationsInTree は作業ツリーの (モジュール → 名前) の表を返す。
func declarationsInTree(root string, pkgs []string) map[string]map[string]bool {
	found := map[string]map[string]bool{}
	for _, pkg := range pkgs {
		for _, path := range flixdecl.FlixFiles(root, pkg+"/src") {
			text, err := pxlib.ReadTextReplace(path)
			if err != nil {
				continue
			}
			for _, e := range perModule(text) {
				if found[e.Mod] == nil {
					found[e.Mod] = map[string]bool{}
				}
				for _, name := range e.Names {
					found[e.Mod][name] = true
				}
			}
		}
	}
	return found
}

// grepRow は git grep の 1 行を解いた物。
type grepRow struct {
	path   string
	lineno int
	text   string
}

// declarationsInRelease はタグ tag のソースの (モジュール → 名前) の表を返す。
// ok が false なら「タグが引けない環境」（呼ぶ側は黙って 0 で終わる）。
func declarationsInRelease(root, tag string, pkgs []string) (map[string]map[string]bool, bool, error) {
	args := []string{"-C", root, "grep", "-n", "-E", gitGrepExpr, tag, "--"}
	for _, p := range pkgs {
		args = append(args, p+"/src")
	}
	stdout, err := exec.Command("git", args...).Output()
	if err != nil {
		exitErr, isExit := err.(*exec.ExitError)
		if !isExit {
			return nil, false, fmt.Errorf("git を呼べません: %v", err)
		}
		// 1 = 当たり無し（タグはある）。それ以外はタグが引けない環境。
		if exitErr.ExitCode() == 1 {
			return map[string]map[string]bool{}, true, nil
		}
		return nil, false, nil
	}

	var rows []grepRow
	for _, line := range pxlib.SplitLines(string(stdout)) {
		// 形は `<tag>:<path>:<lineno>:<本文>`。パスにも本文にも `:` は出るので分割は 3 回だけ。
		parts := strings.SplitN(line, ":", 4)
		if len(parts) < 4 || !strings.HasSuffix(parts[1], ".flix") {
			continue
		}
		n, convErr := strconv.Atoi(parts[2])
		if convErr != nil {
			continue
		}
		rows = append(rows, grepRow{path: parts[1], lineno: n, text: parts[3]})
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].path != rows[j].path {
			return rows[i].path < rows[j].path
		}
		return rows[i].lineno < rows[j].lineno
	})

	found := map[string]map[string]bool{}
	current, hasCurrent := "", false
	seenPath := ""
	for _, row := range rows {
		if row.path != seenPath {
			seenPath = row.path
			current, hasCurrent = "", false // mod はファイルをまたがない
		}
		if m := modLineRe.FindStringSubmatch(row.text); m != nil {
			current, hasCurrent = m[1], true
			if found[current] == nil {
				found[current] = map[string]bool{}
			}
			continue
		}
		if m := declLineRe.FindStringSubmatch(row.text); m != nil && hasCurrent {
			found[current][m[1]] = true
		}
	}
	return found, true, nil
}

// Options は呼ぶ側が差し替えられる所。Rules が nil なら規約ファイルから読む。
type Options struct {
	Rules *Rules
}

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（検査そのものが動かなかったとき）。
func Run(out, errOut *strings.Builder, root string, args []string, opts Options) (int, error) {
	rules := opts.Rules
	if rules == nil {
		loaded, err := LoadRules(root)
		if err != nil {
			return 2, err
		}
		rules = loaded
	}

	// 語は 1 つ目の引数だけを見る。
	needle, hasNeedle := "", false
	if len(args) > 0 {
		needle, hasNeedle = strings.ToLower(args[0]), true
	}

	v, ok, err := version(root)
	if err != nil {
		return 2, err
	}
	if !ok {
		return 0, nil
	}
	tag := "v" + v

	released, ok, err := declarationsInRelease(root, tag, rules.Packages)
	if err != nil {
		return 2, err
	}
	if !ok {
		return 0, nil // タグが引けない環境では黙る
	}

	tree := declarationsInTree(root, rules.Packages)
	mods := make([]string, 0, len(tree))
	for mod := range tree {
		mods = append(mods, mod)
	}
	sort.Strings(mods)

	var rows []string
	for _, mod := range mods {
		var missing []string
		for name := range tree[mod] {
			if !released[mod][name] {
				missing = append(missing, name)
			}
		}
		sort.Strings(missing)
		for _, name := range missing {
			if !hasNeedle ||
				strings.Contains(strings.ToLower(name), needle) ||
				strings.Contains(strings.ToLower(mod), needle) {
				rows = append(rows, mod+"."+name)
			}
		}
	}

	if len(rows) == 0 {
		return 0, nil
	}
	if !hasNeedle {
		fmt.Fprintf(out, "[api] 未リリース（%s の fpkg に無い。ゲームから引くとコンパイルで落ちる）:\n", tag)
	} else {
		fmt.Fprintf(out, "[api] 注意: 次は未リリース。%s の fpkg には無いのでゲームからは引けない:\n", tag)
	}
	for _, row := range rows {
		fmt.Fprintf(out, "  %s\n", row)
	}
	return 0, nil
}
