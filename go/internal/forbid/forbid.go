// Package forbid は「古い書き方」を 1 行の正規表現で止め、代わりに使う物を示す lint。
//
//	fge-go forbid [path ...]   名指しのファイルだけ見る (コミット時はステージしたファイル)
//	fge-go forbid --all        git が知っているファイルを全部見る (古い除外もここで裁く)
//	fge-go forbid --root DIR   リポジトリのルートを差し替える
//
// 規則はエンジンの bin/lint-rules/forbid.json (配られる・上書きされる) と、ゲームの
// bin/lint-rules/forbid.local.json (ゲーム固有・残る) を足した物。1 件は
// {id, suffixes / basenames / prefixes で見るファイル, pattern, unlessLine, rawLine, skip, skipDirs,
// whenProject, hint}。
// hint には「代わりに何を使うか」を必ず書く (止めるだけの規則は置かない)。
//
// WhyNot: 規則ごとに Go のサブコマンドを足さないのは、古い書き方の大半が 1 行の正規表現で
// 見分けられ、ゲーム固有の書き方 (動画の口の準備など) はエンジンのリリース無しで足したいため。
// 文脈が要る物 (z の表・let _ =) は今までどおり専用の lint が持つ。
package forbid

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var (
	RulesPath = filepath.Join("bin", "lint-rules", "forbid.json")
	LocalPath = filepath.Join("bin", "lint-rules", "forbid.local.json")
)

// Rule は止める書き方 1 つ。
type Rule struct {
	ID         string   `json:"id"`
	Suffixes   []string `json:"suffixes"`
	Basenames  []string `json:"basenames"`
	Prefixes   []string `json:"prefixes"`
	Skip       []string `json:"skip"`
	Pattern    string   `json:"pattern"`
	UnlessLine string   `json:"unlessLine"`
	// RawLine は .flix でも文字列の中身を消さずに照合する（文字列そのものを見る規則のため）。コメントは落とす。
	RawLine bool `json:"rawLine"`
	// SkipDirs はパスのどの段にあっても見ないフォルダ名（"test" ならゲームの test/ もテンプレの test/ も）。
	SkipDirs []string `json:"skipDirs"`
	// WhenProject は、そのファイルのプロジェクト（いちばん近い flix.toml のフォルダ）のどこかの .flix に
	// この正規表現が当たるときだけ規則を効かせる（時計を使い始めたゲームだけ古い口を止める、のように）。
	WhenProject string `json:"whenProject"`
	Hint        string `json:"hint"`
	re          *regexp.Regexp
	unless      *regexp.Regexp
	when        *regexp.Regexp
	from        string
}

type rulesFile struct {
	Rules  []Rule            `json:"rules"`
	Exempt map[string]string `json:"exempt"`
}

// Rules はエンジンとゲームの規則を足した物。Exempt の鍵は "パス::id"。
type Rules struct {
	List       []Rule
	Exempt     map[string]string
	ExemptFrom map[string]string
}

// LoadRules は forbid.json (必須) と forbid.local.json (任意) を読む。
func LoadRules(root string) (*Rules, error) {
	r := &Rules{Exempt: map[string]string{}, ExemptFrom: map[string]string{}}
	for i, rel := range []string{RulesPath, LocalPath} {
		data, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			if i == 1 && errors.Is(err, os.ErrNotExist) {
				continue
			}
			return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
		}
		var f rulesFile
		if err := json.Unmarshal(data, &f); err != nil {
			return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", rel, err)
		}
		for _, rule := range f.Rules {
			if rule.ID == "" || rule.Pattern == "" || strings.TrimSpace(rule.Hint) == "" {
				return nil, fmt.Errorf("%s: 規則には id・pattern・hint (代わりに何を使うか) が要ります: %+v", rel, rule.ID)
			}
			if rule.re, err = regexp.Compile(rule.Pattern); err != nil {
				return nil, fmt.Errorf("%s の %s: pattern が壊れています: %v", rel, rule.ID, err)
			}
			if rule.UnlessLine != "" {
				if rule.unless, err = regexp.Compile(rule.UnlessLine); err != nil {
					return nil, fmt.Errorf("%s の %s: unlessLine が壊れています: %v", rel, rule.ID, err)
				}
			}
			if rule.WhenProject != "" {
				if rule.when, err = regexp.Compile(rule.WhenProject); err != nil {
					return nil, fmt.Errorf("%s の %s: whenProject が壊れています: %v", rel, rule.ID, err)
				}
			}
			rule.from = filepath.ToSlash(rel)
			r.List = append(r.List, rule)
		}
		for k, why := range f.Exempt {
			if _, dup := r.Exempt[k]; dup {
				return nil, fmt.Errorf("除外 %s が forbid.json と forbid.local.json の両方にあります", k)
			}
			r.Exempt[k] = why
			r.ExemptFrom[k] = filepath.ToSlash(rel)
		}
	}
	return r, nil
}

// Applies は規則 rule がファイル rel を見るか。
func (rule Rule) Applies(rel string) bool {
	for _, s := range rule.Skip {
		if strings.HasPrefix(rel, s) {
			return false
		}
	}
	for _, dir := range strings.Split(path.Dir(rel), "/") {
		for _, name := range rule.SkipDirs {
			if dir == name {
				return false
			}
		}
	}
	if len(rule.Prefixes) > 0 && !hasAnyPrefix(rel, rule.Prefixes) {
		return false
	}
	if len(rule.Suffixes) == 0 && len(rule.Basenames) == 0 {
		return true
	}
	for _, s := range rule.Suffixes {
		if strings.HasSuffix(rel, s) {
			return true
		}
	}
	base := path.Base(rel)
	for _, b := range rule.Basenames {
		if base == b {
			return true
		}
	}
	return false
}

func hasAnyPrefix(s string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// Hit は止める 1 行。
type Hit struct {
	Path string
	Line int
	Code string
	Rule *Rule
}

func (h Hit) key() string { return h.Path + "::" + h.Rule.ID }

// TextHits は 1 ファイルの本文から止める行を拾う。
// .flix の行は、文字列とコメントを除いてから当てる (説明の中の古い書き方は止めない)。
func (r *Rules) TextHits(rel, text string) []Hit {
	var hits []Hit
	lines := strings.Split(text, "\n")
	for i := range r.List {
		rule := &r.List[i]
		if !rule.Applies(rel) {
			continue
		}
		for n, line := range lines {
			code := line
			if strings.HasSuffix(rel, ".flix") && rule.RawLine {
				code = stripFlixComment(line)
			} else if strings.HasSuffix(rel, ".flix") {
				code = stripFlixNoise(line)
			}
			if !rule.re.MatchString(code) {
				continue
			}
			if rule.unless != nil && rule.unless.MatchString(line) {
				continue
			}
			hits = append(hits, Hit{Path: rel, Line: n + 1, Code: strings.TrimSpace(line), Rule: rule})
		}
	}
	return hits
}

// stripFlixComment は 1 行から文字列の外の // 以降と doc コメント（/// で始まる行）を落とす。
func stripFlixComment(line string) string {
	if strings.HasPrefix(strings.TrimSpace(line), "//") {
		return ""
	}
	inStr := false
	for i := 0; i < len(line); i++ {
		c := line[i]
		switch {
		case inStr && c == '\\':
			i++
		case c == '"':
			inStr = !inStr
		case !inStr && c == '/' && i+1 < len(line) && line[i+1] == '/':
			return line[:i]
		}
	}
	return line
}

// stripFlixNoise は 1 行から文字列の中身と // 以降を落とす。
func stripFlixNoise(line string) string {
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
		case c == '\'' && i+2 < len(line) && line[i+2] == '\'':
			i += 2
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

// Run はサブコマンドの入口。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	all := false
	var files []string
	for _, a := range args {
		switch {
		case a == "--all":
			all = true
		case !strings.HasPrefix(a, "--"):
			files = append(files, a)
		}
	}
	if all {
		if files, err = gitFiles(root); err != nil {
			return 2, err
		}
	}
	var hits []Hit
	for _, f := range files {
		rel := relTo(root, f)
		data, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			continue
		}
		hits = append(hits, rules.TextHits(rel, string(data))...)
	}
	return report(out, errOut, rules, projectGated(root, hits), all, len(files)), nil
}

// projectGated は whenProject の規則の当たりを、そのプロジェクトが正規表現に当たるものだけに絞る。
// WhyNot: TextHits の中で絞らないのは、プロジェクトを読むのがファイル 1 つの本文の外の仕事で、
// TextHits を本文だけで決まる純粋な関数のまま保つため。
func projectGated(root string, hits []Hit) []Hit {
	uses := map[string]bool{}
	var kept []Hit
	for _, h := range hits {
		if h.Rule.when == nil {
			kept = append(kept, h)
			continue
		}
		project := projectOf(root, h.Path)
		key := project + "\x00" + h.Rule.ID
		used, seen := uses[key]
		if !seen {
			used = projectMatches(filepath.Join(root, project), h.Rule.when)
			uses[key] = used
		}
		if used {
			kept = append(kept, h)
		}
	}
	return kept
}

// projectOf は rel にいちばん近い flix.toml のフォルダ（root からの相対。無ければ "."）。
func projectOf(root, rel string) string {
	for dir := path.Dir(rel); ; dir = path.Dir(dir) {
		if _, err := os.Stat(filepath.Join(root, dir, "flix.toml")); err == nil {
			return dir
		}
		if dir == "." || dir == "/" {
			return "."
		}
	}
}

// projectMatches は dir の下の .flix（lib・build・.layers は見ない）のどれかの、文字列とコメントを
// 除いた行に re が当たるか。
func projectMatches(dir string, re *regexp.Regexp) bool {
	found := false
	_ = filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			switch d.Name() {
			case "lib", "build", ".layers", "node_modules", ".git":
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(p, ".flix") {
			return nil
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return nil
		}
		for _, line := range strings.Split(string(data), "\n") {
			if re.MatchString(stripFlixNoise(line)) {
				found = true
				return filepath.SkipAll
			}
		}
		return nil
	})
	return found
}

func report(out, errOut *strings.Builder, rules *Rules, hits []Hit, all bool, fileCount int) int {
	live := map[string]bool{}
	var bad []Hit
	for _, h := range hits {
		live[h.key()] = true
		if _, ok := rules.Exempt[h.key()]; !ok {
			bad = append(bad, h)
		}
	}
	code := 0
	if all {
		var stale []string
		for k := range rules.Exempt {
			if !live[k] {
				stale = append(stale, k)
			}
		}
		sort.Strings(stale)
		for _, k := range stale {
			fmt.Fprintf(errOut, "  %s は %s の exempt に載っていますが、もう鳴る所がありません（消してください）\n", k, rules.ExemptFrom[k])
			code = 1
		}
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-forbid] OK (%d ファイル / 規則 %d / 除外 %d)\n", fileCount, len(rules.List), len(rules.Exempt))
		}
		return code
	}
	byRule := map[string][]Hit{}
	var order []string
	for _, h := range bad {
		if _, seen := byRule[h.Rule.ID]; !seen {
			order = append(order, h.Rule.ID)
		}
		byRule[h.Rule.ID] = append(byRule[h.Rule.ID], h)
	}
	for _, id := range order {
		hs := byRule[id]
		for _, h := range hs {
			fmt.Fprintf(errOut, "!! %s:%d [%s] %s\n", h.Path, h.Line, id, h.Code)
		}
		fmt.Fprintf(errOut, "   代わりに: %s\n", hs[0].Rule.Hint)
	}
	fmt.Fprintf(errOut, "[lint-forbid] %d 件。どうしても残すなら bin/lint-rules/forbid.local.json の exempt へ \"パス::規則の id\" と理由 1 行\n", len(bad))
	return 1
}

func relTo(root, p string) string {
	if filepath.IsAbs(p) {
		if rel, err := filepath.Rel(root, p); err == nil {
			return filepath.ToSlash(rel)
		}
	}
	return filepath.ToSlash(p)
}

func gitFiles(root string) ([]string, error) {
	cmd := exec.Command("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	cmd.Dir = root
	body, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git ls-files が失敗しました: %v", err)
	}
	var files []string
	for _, p := range strings.Split(string(body), "\x00") {
		if p != "" && !strings.HasPrefix(p, "lib/") && !strings.HasPrefix(p, "build/") {
			files = append(files, p)
		}
	}
	sort.Strings(files)
	return files, nil
}
