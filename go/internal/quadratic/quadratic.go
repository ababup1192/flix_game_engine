package quadratic

// quadratic — fold の中で蓄積を作り直す二乗の形を見る (docs/performance.md「二乗を書かない」)。
//
//	fge-go quadratic                       ステージした差分の + 行だけ (コミット時はこれ)
//	fge-go quadratic --all                 リポの .flix を全部 (古い除外もここで裁く)
//	fge-go quadratic [path/to/X.flix ...]  そのファイルを全部
//	fge-go quadratic --warn ...            出す物は同じで、終了コードだけ 0 にする
//	fge-go quadratic --root DIR ...        リポジトリのルートを差し替える
//
// ステージした差分だけを見るのは、今ある二乗 (docs/performance.md の残りの一覧) で
// 触ったファイルのコミットを毎回止めないため。新しく書いた行だけを裁く。

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "quadratic.json")

// LocalPath はゲームが自分の除外だけを置く所（無くてよい）。
// WhyNot: 除外を RulesPath に書かせないのは、bin/lint-rules/ はエンジンが配るたびに
// 上書きされ、ゲームの除外が次の追従で消えるため。配り元に無いファイルは sync で残る。
var LocalPath = filepath.Join("bin", "lint-rules", "quadratic.local.json")

type rulesFile struct {
	ScopeSuffixes *[]string `json:"scopeSuffixes"`
	SkipPrefixes  *[]string `json:"skipPrefixes"`
	SkipDirNames  *[]string `json:"skipDirNames"`
	// Exempt は「残すと決めた二乗」。鍵は "パス::def の名前"、値は残す理由 (1 行必須)。
	Exempt *map[string]string `json:"exempt"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	ScopeSuffixes []string
	SkipPrefixes  []string
	SkipDirNames  []string
	Exempt        map[string]string
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに空の規約で続けないのは、規約ファイルを消しただけで
// 検査が何も言わずに何も見つけない形になるため。呼ぶ側は必ずエラーで止める。
func LoadRules(root string) (*Rules, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	var f rulesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", path, err)
	}
	switch {
	case f.ScopeSuffixes == nil:
		return nil, fmt.Errorf("規約ファイルに scopeSuffixes がありません (%s)", path)
	case f.SkipPrefixes == nil:
		return nil, fmt.Errorf("規約ファイルに skipPrefixes がありません (%s)", path)
	case f.SkipDirNames == nil:
		return nil, fmt.Errorf("規約ファイルに skipDirNames がありません (%s)", path)
	case f.Exempt == nil:
		return nil, fmt.Errorf("規約ファイルに exempt がありません (%s)", path)
	}
	for key, reason := range *f.Exempt {
		if !strings.Contains(key, "::") || strings.TrimSpace(reason) == "" {
			return nil, fmt.Errorf("規約ファイルの exempt %q は \"パス::def の名前\" と理由 1 行の形にしてください (%s)", key, path)
		}
	}
	exempt := map[string]string{}
	for key, reason := range *f.Exempt {
		exempt[key] = reason
	}
	if err := mergeLocal(filepath.Join(root, LocalPath), exempt); err != nil {
		return nil, err
	}
	return &Rules{ScopeSuffixes: *f.ScopeSuffixes, SkipPrefixes: *f.SkipPrefixes,
		SkipDirNames: *f.SkipDirNames, Exempt: exempt}, nil
}

// mergeLocal はゲームの除外 (LocalPath) を足す。ファイルが無ければ何もしない。
func mergeLocal(path string, exempt map[string]string) error {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("ゲームの除外を読めません: %v", err)
	}
	var local struct {
		Exempt *map[string]string `json:"exempt"`
	}
	if err := json.Unmarshal(data, &local); err != nil {
		return fmt.Errorf("ゲームの除外が JSON として壊れています (%s): %v", path, err)
	}
	if local.Exempt == nil {
		return fmt.Errorf("ゲームの除外に exempt がありません (%s)", path)
	}
	for key, reason := range *local.Exempt {
		if !strings.Contains(key, "::") || strings.TrimSpace(reason) == "" {
			return fmt.Errorf("ゲームの除外 %q は \"パス::def の名前\" と理由 1 行の形にしてください (%s)", key, path)
		}
		if _, dup := exempt[key]; dup {
			return fmt.Errorf("除外 %q がエンジンの規約とゲームの除外の両方にあります (%s)", key, path)
		}
		exempt[key] = reason
	}
	return nil
}

// InScope は --all とステージの差分で見るファイルか。
func (r *Rules) InScope(rel string) bool {
	if !r.isFlix(rel) {
		return false
	}
	for _, p := range r.SkipPrefixes {
		if strings.HasPrefix(rel, p) {
			return false
		}
	}
	parts := strings.Split(rel, "/")
	for _, dir := range parts[:len(parts)-1] {
		for _, name := range r.SkipDirNames {
			if dir == name {
				return false
			}
		}
	}
	return true
}

func (r *Rules) isFlix(rel string) bool {
	for _, s := range r.ScopeSuffixes {
		if strings.HasSuffix(rel, s) {
			return true
		}
	}
	return false
}

func git(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	var out, errOut strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git %s が失敗しました: %v %s", strings.Join(args, " "), err, errOut.String())
	}
	return out.String(), nil
}

var hunkLine = regexp.MustCompile(`\+(\d+)`)

// stagedHits は新しく書いた行だけを見る。ラムダの仮引数を知るためにステージ後の全文を読み、
// 差分で足された行番号と突き合わせる (差分の + 行だけでは、どのfoldの中かが見えない)。
func (r *Rules) stagedHits(root string) ([]Hit, error) {
	diff, err := git(root, "diff", "--cached", "-U0", "--diff-filter=ACMR")
	if err != nil {
		return nil, err
	}
	var order []string
	added := map[string]map[int]bool{}
	path, lineno := "", 0
	for _, line := range pxlib.SplitLines(diff) {
		switch {
		case strings.HasPrefix(line, "+++ b/"):
			path = line[6:]
		case strings.HasPrefix(line, "@@"):
			lineno = 0
			if m := hunkLine.FindStringSubmatch(line); m != nil {
				lineno, _ = strconv.Atoi(m[1])
			}
		case path != "" && r.InScope(path) && strings.HasPrefix(line, "+") && !strings.HasPrefix(line, "+++"):
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
		body, err := git(root, "show", ":"+p)
		if err != nil {
			continue
		}
		for _, h := range Scan(p, body) {
			if added[p][h.Line] {
				hits = append(hits, h)
			}
		}
	}
	return hits, nil
}

func (r *Rules) allFiles(root string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if path != root && (strings.HasPrefix(d.Name(), ".") || !r.dirInScope(rel)) {
				return filepath.SkipDir
			}
			return nil
		}
		// WhyNot: リンクを読まないのは、エンジンのルートの src/ が各パッケージの .flix への
		// リンクの写しで、同じ行を 2 回数えてしまうため。
		if d.Type()&os.ModeSymlink == 0 && r.InScope(rel) {
			files = append(files, rel)
		}
		return nil
	})
	sort.Strings(files)
	return files, err
}

func (r *Rules) dirInScope(rel string) bool {
	for _, p := range r.SkipPrefixes {
		if strings.HasPrefix(rel+"/", p) {
			return false
		}
	}
	for _, name := range r.SkipDirNames {
		if filepath.Base(rel) == name {
			return false
		}
	}
	return true
}

// Run は fge quadratic の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	all, warn := false, false
	var named []string
	for _, a := range args {
		switch {
		case a == "--all":
			all = true
		case a == "--warn":
			warn = true
		case strings.HasPrefix(a, "--"):
		default:
			named = append(named, a)
		}
	}
	var hits []Hit
	switch {
	case all || len(named) > 0:
		files := named
		if all {
			if files, err = rules.allFiles(root); err != nil {
				return 2, err
			}
		}
		for _, f := range files {
			abs := f
			if !filepath.IsAbs(abs) {
				abs = filepath.Join(root, f)
			}
			body, err := os.ReadFile(abs)
			if err != nil {
				return 2, fmt.Errorf("読めません: %v", err)
			}
			rel, _ := filepath.Rel(root, abs)
			hits = append(hits, Scan(filepath.ToSlash(rel), string(body))...)
		}
	default:
		if hits, err = rules.stagedHits(root); err != nil {
			return 2, err
		}
	}
	return report(out, errOut, root, rules, hits, all, warn), nil
}

func report(out, errOut *strings.Builder, root string, rules *Rules, hits []Hit, all, warn bool) int {
	var bad []Hit
	live := map[string]bool{}
	for _, h := range hits {
		live[h.key()] = true
		if _, ok := rules.Exempt[h.key()]; !ok {
			bad = append(bad, h)
		}
	}
	code := 0
	if all {
		var stale []string
		for key := range rules.Exempt {
			// WhyNot: このリポに無いファイルの鍵を古いと言わないのは、エンジンの除外
			// (render_gl/… など) がゲームにも同じ規約ファイルで配られ、そこでは必ず空振りするため。
			path := key[:strings.Index(key, "::")]
			if !live[key] && isFile(filepath.Join(root, filepath.FromSlash(path))) {
				stale = append(stale, key)
			}
		}
		sort.Strings(stale)
		for _, key := range stale {
			fmt.Fprintf(errOut, "  %s は exempt に載っていますが、もう鳴る所がありません\n", key)
		}
		if len(stale) > 0 {
			fmt.Fprintf(errOut, "[lint-quadratic] 古い除外 %d 件。quadratic.local.json か quadratic.json の exempt から消してください\n", len(stale))
			code = 1
		}
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-quadratic] OK (除外 %d 件)\n", len(rules.Exempt))
		}
		return finish(errOut, code, warn)
	}
	for _, h := range bad {
		what := fmt.Sprintf("蓄積 %s を List.append の第 1 引数に置いています", h.Acc)
		switch {
		case h.Acc == "String.concat":
			what = "String.concat を渡して、蓄積の文字列に 1 回ごとに足しています"
		case h.Kind == "string":
			what = fmt.Sprintf("蓄積の文字列 %s に 1 回ごとに足しています", h.Acc)
		}
		fmt.Fprintf(errOut, "!! %s:%d (%s) foldLeft / foldRight の中で、%s\n", h.Path, h.Line, h.Def, what)
	}
	fmt.Fprintf(errOut, "[lint-quadratic] %d 件。1 回ごとに蓄積を丸ごと作り直すので、要素数 (文字数) の二乗になります。"+
		"\n  リストは :: で先頭へ積んで最後に List.reverse、文字列は List[Char] に積んで最後に StringBuilder で 1 回だけ組む"+
		" (docs/performance.md「手本と壊れ方」)。"+
		"\n  どうしても残すなら bin/lint-rules/quadratic.local.json (ゲーム) か quadratic.json (エンジン) の exempt へ"+
		" \"パス::def の名前\" と理由 1 行\n", len(bad))
	return finish(errOut, 1, warn)
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// finish は --warn のとき終了コードだけを 0 にする。
func finish(errOut *strings.Builder, code int, warn bool) int {
	if warn && code != 0 {
		fmt.Fprintln(errOut, "[lint-quadratic] --warn なので止めません")
		return 0
	}
	return code
}
