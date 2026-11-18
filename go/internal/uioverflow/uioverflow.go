package uioverflow

// uioverflow — ui.json の text が「折り返し宣言の漏れ」ではみ出さないかを見る検査。
//
//	fge-go ui-overflow                 templates/ の *.ui.json を全部
//	fge-go ui-overflow a.ui.json       指定ファイルだけ
//	fge-go ui-overflow --strict        注意も NG に上げる
//	fge-go ui-overflow --self-test     この検査自身の検査

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// LimitsNote は出力の最後に必ず付く但し書き。
const LimitsNote = "※ この lint は ui.json の構造だけを見る。コードから直組みした Text と" +
	" instance 参照ノードは見えない (それらの wrap / fit は書いた所で自分で付ける)"

// noteBody は宣言漏れ 1 件分の文面。
const noteBody = "%s: 固定幅 %spx の枠内の text が wrap も fit も宣言していない " +
	"— 長い文言が来るとはみ出す。折るなら \"wrap\": \"auto\"、" +
	"意図的な 1 行固定なら \"lint-ui\": \"対象外 — 理由\" を書く"

// stats は数えておく物 (instance ノードは対象外なので件数だけ出す)。
type stats struct{ instances int }

func asObject(v any) (map[string]any, bool) {
	m, ok := v.(map[string]any)
	return m, ok
}

// pyG は数を有効数字 6 桁の短い字面にする (nan / inf も字にする)。
func pyG(v float64) string {
	switch {
	case math.IsNaN(v):
		return "nan"
	case math.IsInf(v, 1):
		return "inf"
	case math.IsInf(v, -1):
		return "-inf"
	}
	return strconv.FormatFloat(v, 'g', 6, 64)
}

// isExcluded は "lint-ui": "対象外 — 理由" が書いてあるかを見る。理由の無い文字列では除外しない。
func (r *Rules) isExcluded(node map[string]any) bool {
	text, ok := node[r.ExemptKey].(string)
	return ok && strings.Contains(text, r.ExemptMarker)
}

// widthKind は width の種類: "px" (数値) / "grow" / "auto" (未指定・"auto"・読めない形)。
func (r *Rules) widthKind(node map[string]any) string {
	value, ok := node["width"]
	if !ok {
		return "auto"
	}
	switch v := value.(type) {
	case bool:
		return "auto"
	case float64:
		_ = v
		return "px"
	case string:
		if v == r.GrowWidth {
			return "grow"
		}
	}
	return "auto"
}

// hasWrapDecl は text の折り返し宣言があるかを見る。
// WhyNot: 真偽値の wrap を数えないのは、それがコンテナの flex wrap で別物のため。
func (r *Rules) hasWrapDecl(node map[string]any) bool {
	switch wrap := node["wrap"].(type) {
	case string:
		if wrap == r.WrapAuto {
			return true
		}
	case float64:
		if wrap > 0 {
			return true
		}
	}
	fit, ok := node["fit"].(bool)
	return ok && fit
}

// fixedWidthOf は text の枠を決める固定幅を返す。固定でなければ ok=false。
//
// 自分の width が px ならそれ。auto/grow なら枠は親で決まるので親をたどる:
// px で確定、grow は更に上へ、auto (auto-size = 中身で枠が決まる) で打ち切り対象外。
func (r *Rules) fixedWidthOf(self map[string]any, ancestors []map[string]any) (float64, bool) {
	if r.widthKind(self) == "px" {
		return self["width"].(float64), true
	}
	for _, node := range ancestors {
		switch r.widthKind(node) {
		case "px":
			return node["width"].(float64), true
		case "auto":
			return 0, false
		}
		// "grow" は親の寸法で決まるので更に上を見る
	}
	return 0, false
}

// resolveUse は "use" のテンプレ値の上にノード値を重ねる (ノード勝ち)。
func (r *Rules) resolveUse(templates, node map[string]any) map[string]any {
	name, ok := node["use"].(string)
	if !ok {
		return node
	}
	tmap, ok := asObject(templates[name])
	if !ok {
		return node
	}
	merged := make(map[string]any, len(tmap)+len(node))
	for k, v := range tmap {
		merged[k] = v
	}
	for k, v := range node {
		merged[k] = v
	}
	return merged
}

func (r *Rules) walk(templates map[string]any, raw any, path string,
	ancestors []map[string]any, notes *[]string, st *stats) {
	node, ok := asObject(raw)
	if !ok {
		return
	}
	if _, isInstance := node["instance"]; isInstance {
		st.instances++
		return
	}
	merged := r.resolveUse(templates, node)
	name, ok := merged["name"].(string)
	if !ok {
		name = anonymousName
	}
	here := name
	if path != "" {
		here = path + "/" + name
	}
	if r.isExcluded(merged) {
		return
	}
	if widget, _ := merged["widget"].(string); widget == r.TextWidget && !r.hasWrapDecl(merged) {
		if width, fixed := r.fixedWidthOf(merged, ancestors); fixed {
			*notes = append(*notes, fmt.Sprintf(noteBody, here, pyG(width)))
		}
	}
	children, ok := merged["children"].([]any)
	if !ok {
		return
	}
	up := append([]map[string]any{merged}, ancestors...)
	for _, child := range children {
		r.walk(templates, child, here, up, notes, st)
	}
}

// CheckDoc はパース済み ui.json 1 つ分の注意一覧を返す。
func (r *Rules) CheckDoc(raw any, st *stats) []string {
	var notes []string
	doc, ok := asObject(raw)
	if !ok || r.isExcluded(doc) {
		return notes
	}
	templates, ok := asObject(doc["templates"])
	if !ok {
		templates = map[string]any{}
	}
	r.walk(templates, doc["root"], "", nil, &notes, st)
	return notes
}

func (r *Rules) checkFile(path string, st *stats) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return []string{fmt.Sprintf("(読めない JSON: %s)", pyOSError(err, path))}
	}
	doc, err := LoadsPyJSON(string(data))
	if err != nil {
		return []string{fmt.Sprintf("(読めない JSON: %s)", err)}
	}
	return r.CheckDoc(doc, st)
}

// ---------------------------------------------------------------- 対象さがし

// discover は templates/ 配下、無ければ自分の assets/ を見る。
//
// エンジンのリポでもゲーム 1 本のリポでも同じ 1 つの入口で動かすため。
func (r *Rules) discover(root string) []string {
	var bases []string
	for _, group := range r.GameRoots {
		groupDir := filepath.Join(root, group)
		if !isDir(groupDir) {
			continue
		}
		names, err := readDirNames(groupDir)
		if err != nil {
			continue
		}
		for _, name := range names {
			rel := filepath.Join(root, group, name)
			if !isDir(rel) {
				continue
			}
			bases = append(bases, rel)
		}
	}
	if len(bases) == 0 {
		bases = []string{root}
	}
	var found []string
	for _, base := range bases {
		r.walkTree(base, &found)
	}
	sort.Strings(found)
	return found
}

// walkTree は上から順に降りる。シンボリックリンクは辿らない。
func (r *Rules) walkTree(dir string, found *[]string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	var dirs, files []string
	for _, e := range entries {
		name := e.Name()
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			files = append(files, name)
			continue
		}
		if info.IsDir() {
			dirs = append(dirs, name)
			continue
		}
		files = append(files, name)
	}
	sort.Strings(files)
	for _, name := range files {
		if strings.HasSuffix(name, r.Suffix) {
			*found = append(*found, filepath.Join(dir, name))
		}
	}
	var kept []string
	for _, name := range dirs {
		if !r.excluded(name) {
			kept = append(kept, name)
		}
	}
	sort.Strings(kept)
	for _, name := range kept {
		sub := filepath.Join(dir, name)
		if info, err := os.Lstat(sub); err == nil && info.Mode()&os.ModeSymlink != 0 {
			continue
		}
		r.walkTree(sub, found)
	}
}

func (r *Rules) excluded(name string) bool {
	for _, d := range r.ExcludedDirs {
		if d == name {
			return true
		}
	}
	return false
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func readDirNames(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names, nil
}

// relPath は root から見た相対パスの字面を返す。
func relPath(path, root string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return path
	}
	rel, err := filepath.Rel(absRoot, abs)
	if err != nil {
		return abs
	}
	return rel
}

// ---------------------------------------------------------------- 入口

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
		return rules.selfTest(out), nil
	}
	strict := has("--strict")
	var targets []string
	for _, a := range args {
		if !strings.HasPrefix(a, "--") {
			targets = append(targets, a)
		}
	}
	if len(targets) == 0 {
		targets = rules.discover(root)
	}
	total := 0
	st := &stats{}
	for _, path := range targets {
		notes := rules.checkFile(path, st)
		if len(notes) == 0 {
			continue
		}
		fmt.Fprintf(out, "\n%s\n", relPath(path, root))
		for _, note := range notes {
			label := "注意"
			if strict {
				label = "NG"
			}
			fmt.Fprintf(out, "  %s: %s\n", label, note)
		}
		total += len(notes)
	}
	label := "注意"
	if strict {
		label = "NG"
	}
	fmt.Fprintf(out, "\n%d ファイル / %s %d 件\n", len(targets), label, total)
	if st.instances > 0 {
		fmt.Fprintf(out, "(instance 参照ノード %d 件は対象外)\n", st.instances)
	}
	fmt.Fprintf(out, "%s\n", LimitsNote)
	if strict && total > 0 {
		return 1, nil
	}
	return 0, nil
}
