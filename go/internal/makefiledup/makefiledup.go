// Package makefiledup は、ゲームの Makefile が engine の mk/game.mk にある共通の口
// (ターゲット) を自分でも作り直していないかを見る lint。
//
//	fge-go makefile-dup [path ...]   名指しの Makefile だけ見る (コミット時はステージした物)
//	fge-go makefile-dup --all        git が知っている Makefile を全部見る (古い除外もここで裁く)
//	fge-go makefile-dup --root DIR   リポジトリのルートを差し替える
//
// 見るのは mk/game.mk を include している Makefile だけ。止めるのは「共通の口と同じ名前のターゲットに、レシピ (タブで始まる行か ; の後ろ) を書いた」形。
// 前提 (依存) を足すだけの行 (`render-all: extra-art`) と、ターゲット別の変数
// (`render: SHOTS = title`) は止めない。どちらも engine のレシピをそのまま使うため。
//
// game.mk の探し方: 根に mk/game.mk があればそれ (engine のリポ。templates/*/Makefile を見る)、
// 無ければ環境変数 ENGINE → local.mk → Makefile の ENGINE (status.FindEngineDir。doc-shape と同じ道具)。見つからなければ
// 何も止めない (fail-open。1 行知らせる)。
//
// WhyNot: 隣に mk/game.mk がある Makefile (engine 自身の Makefile) を見ないのは、
// あれは共通の口を配る側で、写しではないため。
//
// 規約は bin/lint-rules/makefile-dup.json、ゲームの除外は makefile-dup.local.json の exempt
// ("パス::ターゲット名": 理由)。
package makefiledup

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json)。
const Name = "makefile-dup"

// Rules は規約データ。すべて JSON から来る。
type Rules struct {
	Note      string   `json:"note"`
	GameMk    string   `json:"gameMk"`
	Basenames []string `json:"basenames"`
	Hint      string   `json:"hint"`
	exempt    *lintconf.Exempt
}

// LoadRules は規約と除外を読む。
func LoadRules(root string) (*Rules, error) {
	var r Rules
	ex, err := lintconf.Load(root, Name, &r)
	if err != nil {
		return nil, err
	}
	if r.GameMk == "" || len(r.Basenames) == 0 || strings.TrimSpace(r.Hint) == "" {
		return nil, fmt.Errorf("makefile-dup.json には gameMk・basenames・hint が要ります")
	}
	r.exempt = ex
	return &r, nil
}

// Rule は Makefile の 1 つのターゲットの定義。
type Rule struct {
	Target    string
	Line      int
	HasRecipe bool
}

// 「名前 [名前...] : 残り」。:= ::= は変数なので外す (下で見る)。
var ruleRe = regexp.MustCompile(`^([^\s:#=][^:#=]*?)\s*(::?)(.*)$`)

// ターゲット別の変数 (`render: SHOTS = x` / `render: X := y`)。
var targetVarRe = regexp.MustCompile(`^\s*(?:override\s+|export\s+)?[A-Za-z_][\w.-]*\s*(?:[:+?!]|::)?=`)

// ParseRules は Makefile の本文からターゲットの定義を拾う。名前に $ や % を含む物と . で始まる物は外す。
func ParseRules(text string) []Rule {
	lines := strings.Split(text, "\n")
	var out []Rule
	for i, line := range lines {
		if strings.HasPrefix(line, "\t") {
			continue
		}
		m := ruleRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		rest := m[3]
		if strings.HasPrefix(rest, "=") || targetVarRe.MatchString(rest) {
			continue
		}
		recipe := strings.Contains(rest, ";")
		if !recipe {
			for j := i + 1; j < len(lines); j++ {
				next := lines[j]
				if strings.TrimSpace(next) == "" || strings.HasPrefix(strings.TrimSpace(next), "#") {
					continue
				}
				recipe = strings.HasPrefix(next, "\t")
				break
			}
		}
		names := strings.Fields(m[1])
		if !allNames(names) {
			continue
		}
		for _, t := range names {
			if strings.HasPrefix(t, ".") || strings.ContainsAny(t, "$%") {
				continue
			}
			out = append(out, Rule{Target: t, Line: i + 1, HasRecipe: recipe})
		}
	}
	return out
}

// game.mk を取り込む行 (include / -include / sinclude)。
var includeRe = regexp.MustCompile(`(?m)^\s*(?:-|s)?include\s+.*mk/game\.mk\s*$`)

var nameRe = regexp.MustCompile(`^(?:[A-Za-z0-9_./%-]|\$\([A-Za-z0-9_]+\))+$`)

// allNames は行頭の並びがターゲット名だけか ($(error …: …) のような文の行を外す)。
func allNames(names []string) bool {
	for _, t := range names {
		if !nameRe.MatchString(t) {
			return false
		}
	}
	return len(names) > 0
}

// CommonTargets は game.mk の口の名前。
func CommonTargets(gameMk string) map[string]bool {
	set := map[string]bool{}
	for _, r := range ParseRules(gameMk) {
		set[r.Target] = true
	}
	return set
}

// findGameMk は game.mk のパスと、それが根の中 (engine のリポ) かを返す。
func findGameMk(root, rel string) (string, bool) {
	dir, self := status.FindEngineDir(root, rel)
	if dir == "" {
		return "", false
	}
	return filepath.Join(dir, filepath.FromSlash(rel)), self
}

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

// Hit は止める 1 件。
type Hit struct {
	Path, Target string
	Line         int
}

func (h Hit) key() string { return h.Path + "::" + h.Target }

// Run は fge makefile-dup の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	all, files, err := lintconf.Args(root, args)
	if err != nil {
		return 2, err
	}
	mk, _ := findGameMk(root, rules.GameMk)
	if mk == "" {
		fmt.Fprintf(out, "[lint-makefile-dup] %s が見つからないので飛ばします (ENGINE か local.mk の ENGINE を確かめる)\n", rules.GameMk)
		return 0, nil
	}
	body, err := os.ReadFile(mk)
	if err != nil {
		return 2, fmt.Errorf("%s を読めません: %v", mk, err)
	}
	common := CommonTargets(string(body))
	var hits []Hit
	seen := 0
	for _, rel := range files {
		if !rules.isMakefile(rel) {
			continue
		}
		// 隣に mk/game.mk がある Makefile は engine 自身 (配る側) なので見ない。
		if isFile(filepath.Join(root, filepath.FromSlash(path.Join(path.Dir(rel), rules.GameMk)))) {
			continue
		}
		text, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			continue
		}
		// game.mk を include しない Makefile (bench・検査の見本) は共通の口を受け取っていないので、
		// 同じ名前の口を持っていても写しではない。
		if !includeRe.Match(text) {
			continue
		}
		seen++
		for _, r := range ParseRules(string(text)) {
			if r.HasRecipe && common[r.Target] {
				hits = append(hits, Hit{Path: rel, Target: r.Target, Line: r.Line})
			}
		}
	}
	return report(out, errOut, root, rules, hits, all, seen, len(common)), nil
}

func (r *Rules) isMakefile(rel string) bool {
	base := path.Base(rel)
	for _, b := range r.Basenames {
		if base == b {
			return true
		}
	}
	return false
}

func report(out, errOut *strings.Builder, root string, rules *Rules, hits []Hit, all bool, seen, common int) int {
	live := map[string]bool{}
	var bad []Hit
	for _, h := range hits {
		live[h.key()] = true
		if _, ok := rules.exempt.Why[h.key()]; !ok {
			bad = append(bad, h)
		}
	}
	code := 0
	if all {
		for _, k := range rules.exempt.Stale(root, live) {
			fmt.Fprintf(errOut, "  %s は %s の exempt に載っていますが、もう鳴る所がありません（消してください）\n", k, rules.exempt.From[k])
			code = 1
		}
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-makefile-dup] OK (Makefile %d 本 / 共通の口 %d / 除外 %d 件)\n", seen, common, len(rules.exempt.Why))
		}
		return code
	}
	sort.Slice(bad, func(i, j int) bool { return bad[i].key() < bad[j].key() })
	for _, h := range bad {
		fmt.Fprintf(errOut, "!! %s:%d %s は engine の %s にある共通の口です\n", h.Path, h.Line, h.Target, rules.GameMk)
	}
	fmt.Fprintf(errOut, "[lint-makefile-dup] %d 件。%s\n"+
		"  どうしても残すなら bin/lint-rules/makefile-dup.local.json の exempt へ \"パス::ターゲット名\" と理由 1 行\n",
		len(bad), rules.Hint)
	return 1
}
