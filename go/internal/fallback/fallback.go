package fallback

// fallback — 読み込みの途中で `bug!` して呼ぶ側から選ぶ機会を奪う書き方を止める検査。
//
//	fge-go fallback            ステージした差分の + 行だけ (コミット時と同じ)
//	fge-go fallback --all      対象パッケージの src 配下ぜんぶ
//	fge-go fallback a.flix     指定ファイルだけ
//	fge-go fallback --self-test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// hunkLine は差分の @@ 行から足された側の開始行を取る。
var hunkLine = regexp.MustCompile(`\+(\d+)`)

// Hit は 1 つの `bug!` 呼び出し。
type Hit struct {
	Path    string
	Lineno  int
	Func    string
	Excerpt string
}

// Key は EXEMPT の鍵と同じ字面 (パス::関数名)。
func (h Hit) Key() string { return h.Path + "::" + h.Func }

func isPyWordRune(r rune) bool {
	return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r)
}

// pyIsSpace は空白か（Unicode の空白に U+001C〜U+001F を足した範囲）。
// WhyNot: unicode.IsSpace だけにしないのは、その 4 文字が抜けて抜粋の前後が
// そろわなくなるため。
func pyIsSpace(r rune) bool {
	return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f)
}

func pyStrip(s string) string  { return strings.TrimFunc(s, pyIsSpace) }
func pyLStrip(s string) string { return strings.TrimLeftFunc(s, pyIsSpace) }
func runeLen(s string) int     { return utf8.RuneCountInString(s) }
func headRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// InScope は検査する範囲のファイルかを見る。
func (r *Rules) InScope(path string) bool {
	p := strings.ReplaceAll(path, "\\", "/")
	if !strings.HasSuffix(p, ".flix") {
		return false
	}
	for _, root := range r.SrcRoots {
		if strings.HasPrefix(p, root+"/") {
			return true
		}
	}
	return false
}

// StripComments は `//` から後ろを落とす。文字列リテラルの中の // は落とさない。
func StripComments(line string) string {
	src := []rune(line)
	out := make([]rune, 0, len(src))
	i, quote := 0, false
	for i < len(src) {
		ch := src[i]
		if quote {
			if ch == '\\' {
				end := i + 2
				if end > len(src) {
					end = len(src)
				}
				out = append(out, src[i:end]...)
				i += 2
				continue
			}
			if ch == '"' {
				quote = false
			}
			out = append(out, ch)
		} else {
			switch {
			case ch == '"':
				quote = true
				out = append(out, ch)
			case ch == '/' && i+1 < len(src) && src[i+1] == '/':
				return string(out)
			default:
				out = append(out, ch)
			}
		}
		i++
	}
	return string(out)
}

// hasBug は文字列リテラルを潰した上で `bug!` の呼び出しがあるかを見る。
func (r *Rules) hasBug(code string) bool {
	return r.Bug.Search(r.String.ReplaceAllLiteralString(code, `""`))
}

// Scan は (行番号, 囲んでいる関数名) で `bug!` の呼び出しを拾う。
//
// 囲む def はインデントの深さで決める。Java の匿名クラス (`new ...I { def invoke ... }`)
// のように def は入れ子になるので、最後に見た def を覚えるだけでは、入れ子から
// 出た後の行まで内側の def の物として数えてしまう。
func (r *Rules) Scan(path string, lines []string) []Hit {
	type frame struct {
		indent int
		name   string
	}
	var hits []Hit
	var stack []frame
	for i, raw := range lines {
		lineno := i + 1
		code := StripComments(raw)
		if pyStrip(code) == "" {
			continue
		}
		indent := runeLen(code) - runeLen(pyLStrip(code))
		m := r.Def.FindStringSubmatch(code)
		bug := r.hasBug(code)
		if m != nil {
			for len(stack) > 0 && stack[len(stack)-1].indent >= indent {
				stack = stack[:len(stack)-1]
			}
			stack = append(stack, frame{indent, m[1]})
		} else if bug {
			for len(stack) > 0 && stack[len(stack)-1].indent >= indent {
				stack = stack[:len(stack)-1]
			}
		}
		if bug {
			name := "?"
			if len(stack) > 0 {
				name = stack[len(stack)-1].name
			}
			hits = append(hits, Hit{path, lineno, name, headRunes(pyStrip(code), 78)})
		}
	}
	return hits
}

// Violations は `*OrBug` の中でも EXEMPT でもない `bug!` だけを残す。
func (r *Rules) Violations(hits []Hit) []Hit {
	var bad []Hit
	for _, h := range hits {
		if strings.HasSuffix(h.Func, "OrBug") {
			continue
		}
		if _, ok := r.Exempt[h.Key()]; ok {
			continue
		}
		bad = append(bad, h)
	}
	return bad
}

// ---------------------------------------------------------------- 入力の口

func git(root string, args ...string) (string, error) {
	full := append([]string{"-C", root}, args...)
	cmd := exec.Command("git", full...)
	var out, errOut strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git %s に失敗しました: %v", strings.Join(args, " "), err)
	}
	return out.String(), nil
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// readFile は指定パス、無ければリポジトリのルートからの相対で読む。
func readFile(root, path string) ([]string, bool) {
	full := path
	if !isFile(full) {
		if filepath.IsAbs(path) {
			return nil, false
		}
		full = filepath.Join(root, path)
	}
	if !isFile(full) {
		return nil, false
	}
	src, err := pxlib.LoadTextReplace(full)
	if err != nil {
		return nil, false
	}
	return pxlib.SplitLines(src), true
}

// FileHits は指定したファイル群の `bug!` を拾う。
func (r *Rules) FileHits(root string, paths []string) []Hit {
	var hits []Hit
	for _, p := range paths {
		rel := strings.ReplaceAll(p, "\\", "/")
		lines, ok := readFile(root, rel)
		if !ok {
			continue
		}
		hits = append(hits, r.Scan(rel, lines)...)
	}
	return hits
}

// allPaths は git に入っていない新しいファイルも含めた対象一覧を返す。
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

// pyAtoi は数字を読む。桁あふれは int の最大値で受ける。
// WhyNot: あふれたら 0 に倒さないのは、行番号が小さい値へ化けて的外れな行を
// 違反として数えるため。届かない大きさへ寄せて「当たらない」側で外す。
func pyAtoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return int(^uint(0) >> 1)
	}
	return n
}

// stagedHits は新しく書いた行だけを見る。関数名を知るためにステージ後の全文を読み、
// 差分で足された行番号と突き合わせる (差分の + 行だけでは囲む def が見えない)。
func (r *Rules) stagedHits(root string) ([]Hit, error) {
	diff, err := git(root, "diff", "--cached", "-U0", "--diff-filter=ACMR")
	if err != nil {
		return nil, err
	}
	var order []string
	added := map[string]map[int]bool{}
	path, lineno := "", 0
	for _, line := range pxlib.SplitLines(diff) {
		if strings.HasPrefix(line, "+++ b/") {
			path = line[6:]
			continue
		}
		if strings.HasPrefix(line, "@@") {
			m := hunkLine.FindStringSubmatch(line)
			lineno = 0
			if m != nil {
				lineno = pyAtoi(m[1])
			}
			continue
		}
		if path != "" && r.InScope(path) && strings.HasPrefix(line, "+") && !strings.HasPrefix(line, "+++") {
			if added[path] == nil {
				added[path] = map[int]bool{}
				order = append(order, path)
			}
			added[path][lineno] = true
			lineno++
		}
	}
	var hits []Hit
	for _, p := range order {
		cmd := exec.Command("git", "-C", root, "show", ":"+p)
		var out strings.Builder
		cmd.Stdout = &out
		cmd.Stderr = &strings.Builder{}
		if err := cmd.Run(); err != nil {
			continue
		}
		for _, h := range r.Scan(p, pxlib.SplitLines(out.String())) {
			if added[p][h.Lineno] {
				hits = append(hits, h)
			}
		}
	}
	return hits, nil
}

// ---------------------------------------------------------------- 出力

func (r *Rules) report(out *strings.Builder, bad []Hit, total int, showExempt bool, stale []string) int {
	if showExempt {
		for _, key := range r.ExemptKeys {
			fmt.Fprintf(out, "除外: %s — %s\n", key, r.Exempt[key])
		}
	}
	if len(stale) > 0 {
		for _, key := range stale {
			fmt.Fprintf(out, "  %s は EXEMPT に載っていますが、そこに bug! はもうありません\n", key)
		}
		fmt.Fprintf(out, "[lint-fallback] 古い除外 %d 件。"+
			"宿題の一覧として読めなくなるので EXEMPT から消してください\n", len(stale))
		return 1
	}
	if len(bad) == 0 {
		fmt.Fprintf(out, "[lint-fallback] OK (bug! %d 件を検査 / 除外 %d 件)\n", total, len(r.Exempt))
		return 0
	}
	for _, h := range bad {
		fmt.Fprintf(out, "  %s:%d: %s の中で bug! を呼んでいます\n", h.Path, h.Lineno, h.Func)
		fmt.Fprintf(out, "      %s\n", h.Excerpt)
	}
	fmt.Fprintf(out, "[lint-fallback] 決まり 2 違反 %d 件 (docs/error-handling.md)。"+
		"\n  読み込みなら load* にして Err を返し、止めると決めた所なら"+
		" *OrBug という名前のラッパへ移してください。"+
		"\n  どうしても残すなら bin/lint-fallback.py の EXEMPT へ"+
		" \"パス::関数名\" と理由 1 行を書いてください\n", len(bad))
	return 1
}

// ---------------------------------------------------------------- 自己検査

// Sample は自己検査で読ませる見本。
const Sample = `
mod Demo {
    pub def loadThing(path: String): Result[String, String] = Ok(path)

    /// 失敗したら bug! で止める方針です (この doc コメントは正当化にならない)
    pub def getThing(path: String): String =
        match loadThing(path) {
            case Ok(v)  => v
            case Err(_) => bug!("getThing: ${path}")
        }

    pub def loadThingOrBug(path: String): String =
        match loadThing(path) {
            case Ok(v)  => v
            case Err(e) => bug!("thing: ${e}")
        }

    // ここは bug! と書いてあるだけのコメント
    pub def quiet(): String = "bug! と書いた文字列"
}
`

func (r *Rules) selfTest(out, errOut *strings.Builder) int {
	fail := func(format string, args ...any) int {
		fmt.Fprintf(errOut, "fge-go: self-test 失敗: "+format+"\n", args...)
		return 2
	}
	hits := r.Scan("x.flix", pxlib.SplitLines(Sample))
	funcs := make([]string, 0, len(hits))
	for _, h := range hits {
		funcs = append(funcs, h.Func)
	}
	sort.Strings(funcs)
	if strings.Join(funcs, ",") != "getThing,loadThingOrBug" {
		return fail("%v", funcs)
	}
	badFuncs := make([]string, 0)
	for _, h := range r.Violations(hits) {
		badFuncs = append(badFuncs, h.Func)
	}
	if strings.Join(badFuncs, ",") != "getThing" {
		return fail("%v", badFuncs)
	}
	if got := StripComments(`let s = "a // b" // c`); got != `let s = "a // b" ` {
		return fail("%q", got)
	}
	if !r.InScope("engine/src/App.flix") {
		return fail("engine/src/App.flix")
	}
	for _, p := range []string{"engine/test/TestApp.flix", "templates/x/src/Game.flix", "examples/x/src/Game.flix"} {
		if r.InScope(p) {
			return fail("%s", p)
		}
	}
	for _, key := range r.ExemptKeys {
		if !strings.Contains(key, "::") || pyStrip(r.Exempt[key]) == "" {
			return fail("%s", key)
		}
	}
	fmt.Fprintf(out, "[lint-fallback] self-test OK (除外 %d 件はすべて理由付き)\n", len(r.Exempt))
	return 0
}

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	has := func(flag string) bool {
		for _, a := range args {
			if a == flag {
				return true
			}
		}
		return false
	}
	if has("--self-test") {
		return rules.selfTest(out, errOut), nil
	}
	var files []string
	for _, a := range args {
		if !strings.HasPrefix(a, "--") {
			files = append(files, a)
		}
	}
	var hits []Hit
	var stale []string
	showExempt := false
	switch {
	case len(files) > 0:
		hits = rules.FileHits(root, files)
	case has("--all"):
		paths, err := rules.allPaths(root)
		if err != nil {
			return 2, err
		}
		hits = rules.FileHits(root, paths)
		showExempt = true
		// 全量のときだけ、消えた bug! の除外が残っていないかも見る
		// (差分やファイル指定では全体が見えないので判定できない)
		live := map[string]bool{}
		for _, h := range hits {
			live[h.Key()] = true
		}
		for _, key := range rules.ExemptKeys {
			if !live[key] {
				stale = append(stale, key)
			}
		}
	default:
		hits, err = rules.stagedHits(root)
		if err != nil {
			return 2, err
		}
	}
	return rules.report(out, rules.Violations(hits), len(hits), showExempt, stale), nil
}
