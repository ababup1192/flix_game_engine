package hoist

// hoist — ループの外に置いたつもりの式が、Flix 0.78 の最適化でループの中へ書き写される形を見る
// (docs/performance.md「ループの外に置いた式がループへ戻る」)。
//
//	fge-go hoist                       ステージした .flix を全部 (コミット時はこれ)
//	fge-go hoist --all                 リポの .flix を全部 (古い除外もここで裁く)
//	fge-go hoist [path/to/X.flix ...]  そのファイルを全部
//	fge-go hoist --warn ...            出す物は同じで、終了コードだけ 0 にする
//	fge-go hoist --root DIR ...        リポジトリのルートを差し替える
//
// 純粋な `let x = 式` がラムダの中で 1 回だけ使われると、0.78 はその式をラムダの中へ書き写す
// (@DontInline でも止まらない)。画素ごと・コマごとに呼ばれるラムダなら、1 回のはずの組み立てが
// 毎回走る。値は変わらないので、テストも絵の比べも気づかない。

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "hoist.json")

// LocalPath はゲームが自分の除外だけを置く所（無くてよい）。
// WhyNot: 除外を RulesPath に書かせないのは、bin/lint-rules/ はエンジンが配るたびに
// 上書きされ、ゲームの除外が次の追従で消えるため。
var LocalPath = filepath.Join("bin", "lint-rules", "hoist.local.json")

type rulesFile struct {
	ScopeSuffixes *[]string          `json:"scopeSuffixes"`
	SkipPrefixes  *[]string          `json:"skipPrefixes"`
	SkipDirNames  *[]string          `json:"skipDirNames"`
	FnReturnScope *[]string          `json:"fnReturnScope"`
	LoopCalls     *[]string          `json:"loopCalls"`
	Once          *string            `json:"once"`
	NotMoved      *map[string]string `json:"notMoved"`
	Effectful     *map[string]string `json:"effectful"`
	Exempt        *map[string]string `json:"exempt"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	ScopeSuffixes []string
	SkipPrefixes  []string
	SkipDirNames  []string
	// FnReturnScope は fn-return を見るパスの頭 (エンジンの塗りの道)。
	FnReturnScope []string
	// LoopCalls は画素・コマごとにラムダを呼ぶ関数の名前。
	LoopCalls []string
	// Once はループの外に留める口の名前 (onceOutsideLoop)。
	Once string
	// NotMoved は書き写されても重くない呼び出し (整数の比べ・数の変換など)。
	NotMoved map[string]bool
	// Effectful は効果のある呼び出し。右辺にあれば let は純粋でないので書き写されない。
	Effectful map[string]bool
	// Exempt は残すと決めた所。鍵は "パス::def" (fn-return) か "パス::def::let の名前" (loop-let)。
	Exempt map[string]string
}

// LoadRules は規約データを読む。読めないときは止める (空の規約で黙って通さない)。
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
	if f.ScopeSuffixes == nil || f.SkipPrefixes == nil || f.SkipDirNames == nil || f.FnReturnScope == nil ||
		f.LoopCalls == nil || f.Once == nil || f.NotMoved == nil || f.Effectful == nil || f.Exempt == nil {
		return nil, fmt.Errorf("規約ファイルに scopeSuffixes / skipPrefixes / skipDirNames / fnReturnScope / loopCalls / once / notMoved / effectful / exempt のどれかがありません (%s)", path)
	}
	exempt := map[string]string{}
	if err := addExempt(exempt, *f.Exempt, path, nil); err != nil {
		return nil, err
	}
	if err := mergeLocal(filepath.Join(root, LocalPath), exempt); err != nil {
		return nil, err
	}
	notMoved, err := namesOf(*f.NotMoved, "notMoved", path)
	if err != nil {
		return nil, err
	}
	effectful, err := namesOf(*f.Effectful, "effectful", path)
	if err != nil {
		return nil, err
	}
	return &Rules{ScopeSuffixes: *f.ScopeSuffixes, SkipPrefixes: *f.SkipPrefixes, SkipDirNames: *f.SkipDirNames,
		FnReturnScope: *f.FnReturnScope, LoopCalls: *f.LoopCalls, Once: *f.Once,
		NotMoved: notMoved, Effectful: effectful, Exempt: exempt}, nil
}

// namesOf は「呼び出しの名前 → 理由 1 行」の表を名前の集合にする（理由の無い行は止める）。
func namesOf(table map[string]string, field, path string) (map[string]bool, error) {
	names := map[string]bool{}
	for name, reason := range table {
		if strings.TrimSpace(reason) == "" {
			return nil, fmt.Errorf("規約ファイルの %s %q に理由 1 行がありません (%s)", field, name, path)
		}
		names[name] = true
	}
	return names, nil
}

func addExempt(into, from map[string]string, path string, engine map[string]string) error {
	for key, reason := range from {
		if !strings.Contains(key, "::") || strings.TrimSpace(reason) == "" {
			return fmt.Errorf("除外 %q は \"パス::def\" か \"パス::def::名前\" と理由 1 行の形にしてください (%s)", key, path)
		}
		if _, dup := engine[key]; dup {
			return fmt.Errorf("除外 %q がエンジンの規約とゲームの除外の両方にあります (%s)", key, path)
		}
		into[key] = reason
	}
	return nil
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
	engine := map[string]string{}
	for k, v := range exempt {
		engine[k] = v
	}
	return addExempt(exempt, *local.Exempt, path, engine)
}

func (r *Rules) inFnReturnScope(rel string) bool {
	for _, p := range r.FnReturnScope {
		if strings.HasPrefix(rel, p) {
			return true
		}
	}
	return false
}

// InScope は --all とステージで見るファイルか。
func (r *Rules) InScope(rel string) bool {
	ok := false
	for _, s := range r.ScopeSuffixes {
		if strings.HasSuffix(rel, s) {
			ok = true
		}
	}
	if !ok {
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
		// リンクの写しで、同じ所を 2 回数えてしまうため。
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

func stagedFiles(root string, r *Rules) ([]string, error) {
	cmd := exec.Command("git", "-C", root, "diff", "--cached", "--name-only", "--diff-filter=ACMR")
	var out, errOut strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("git diff --cached が失敗しました: %v %s", err, errOut.String())
	}
	var files []string
	for _, l := range strings.Split(out.String(), "\n") {
		if l = strings.TrimSpace(l); l != "" && r.InScope(l) {
			files = append(files, l)
		}
	}
	return files, nil
}

// Run は fge hoist の本体。
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
	files := named
	switch {
	case all:
		if files, err = rules.allFiles(root); err != nil {
			return 2, err
		}
	case len(named) == 0:
		if files, err = stagedFiles(root, rules); err != nil {
			return 2, err
		}
	}
	var hits []Hit
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
		hits = append(hits, Scan(filepath.ToSlash(rel), string(body), rules)...)
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
			fmt.Fprintf(errOut, "[lint-hoist] 古い除外 %d 件。hoist.local.json か hoist.json の exempt から消してください\n", len(stale))
			code = 1
		}
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-hoist] OK (除外 %d 件)\n", len(rules.Exempt))
		}
		return finish(errOut, code, warn)
	}
	for _, h := range bad {
		switch h.Kind {
		case "fn-return":
			fmt.Fprintf(errOut, "!! %s:%d (%s) 戻り値が関数の型の def です。中で組み立てた値をラムダが 1 回だけ使うと、"+
				"組み立てが呼ぶたびに走ります\n", h.Path, h.Line, h.Def)
		default:
			fmt.Fprintf(errOut, "!! %s:%d (%s) let %s を %s に渡すラムダの中で使っています。"+
				"式がラムダの中へ書き写され、1 回のはずの計算が毎回走ることがあります\n", h.Path, h.Line, h.Def, h.Name, h.Loop)
		}
	}
	fmt.Fprintf(errOut, "[lint-hoist] %d 件。Flix 0.78 は純粋な let がラムダの中で 1 回だけ使われると式を書き写します (@DontInline でも止まらない)。"+
		"\n  組み立てはデータで返し (関数を返さない)、ループの外で `%s(rc, 式)` で受ける (docs/performance.md「ループの外に置いた式がループへ戻る」)。"+
		"\n  軽い式なら bin/lint-rules/hoist.json の notMoved に呼び出しの名前と理由を、残すと決めた所は exempt (ゲームは hoist.local.json) に"+
		" \"パス::def\" か \"パス::def::名前\" と理由 1 行\n", len(bad), rules.Once)
	return finish(errOut, 1, warn)
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// finish は --warn のとき終了コードだけを 0 にする。
func finish(errOut *strings.Builder, code int, warn bool) int {
	if warn && code != 0 {
		fmt.Fprintln(errOut, "[lint-hoist] --warn なので止めません")
		return 0
	}
	return code
}
