package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/status"
	"github.com/ababup1192/flixlint/go/refactor"
)

// refactorTree は engine の根の索引（src と各パッケージの test）に入れられない Flix のソースの木。
// 別の flix.toml で組む物なので、根を替えて索引を作り、答えを根の答えの後ろへ足す。
//
// WhyNot: 根の索引の sources に足さない。bench はそれぞれ def main を持ち、engine を fpkg（mount = "fge"）で使うので
// 根の src と 1 つに組めない。engine_web は TeaVM の JSO と fge-web の jar が無いと組めず、根の flix.toml に足すと
// 根の flix build（全パッケージを 1 つに組む確かめ）まで web の jar を要るようになる。
type refactorTree struct {
	Name string // 出す時の名前（bench/crowd2d・engine_web）
	Root string // 索引を作る根（flix.toml のある所）
	// Own は Root からの相対で、この木の物とするファイルの頭（"" は全部）。Own の外は根の索引が持つ物の写し。
	Own string
	// As は Own を engine の根からの相対へ置き換える頭。
	As string
	// EnginePrefix は、この木から engine の名前を引く時に付ける頭（fpkg で使う木の $pkg$…$flix_game_engine.）。
	// 同じ package に engine を持つ木は ""。
	EnginePrefix string
	// Resident は常駐の flixlint で索引を作るか。
	// WhyNot: bench を常駐にしない。根ごとに JVM が 1 本立ち、bench の数だけ並ぶ。bench の索引は小さく（1 本 3 秒ほど）、
	// 鍵は bench の src と lib の fpkg なので作り直すのは make sync-engine の後だけ。
	Resident bool
}

// webTreeDir は engine_web を engine の src と 1 つに組む生成物の根（make sync-engine-full-web が作る）。
const webTreeDir = "build/engine_full_web"

// refactorTrees は engine の根 root で、根の索引の外にある木と、見ていない木の 1 行。engine の根でなければ空。
func refactorTrees(root string) ([]refactorTree, []string) {
	if _, self := status.FindEngineDir(root, "mk/game.mk"); !self {
		return nil, nil
	}
	var trees []refactorTree
	var notes []string
	prefix := enginePkgPrefix(root)
	tomls, _ := filepath.Glob(filepath.Join(root, "bench", "*", "flix.toml"))
	sort.Strings(tomls)
	for _, toml := range tomls {
		dir := filepath.Dir(toml)
		if info, err := os.Stat(filepath.Join(dir, "src")); err != nil || !info.IsDir() {
			continue
		}
		name := "bench/" + filepath.Base(dir)
		trees = append(trees, refactorTree{Name: name, Root: dir, As: name + "/", EnginePrefix: prefix})
	}
	if _, err := os.Stat(filepath.Join(root, webTreeDir, "flix.toml")); err == nil {
		trees = append(trees, refactorTree{Name: "engine_web", Root: filepath.Join(root, webTreeDir), Own: "src/engine_web/", As: "engine_web/src/", Resident: true})
	} else if _, err := os.Stat(filepath.Join(root, "engine_web", "src")); err == nil {
		notes = append(notes, "engine_web/src は "+webTreeDir+" が無いので引いていない（make sync-engine-full-web で作る）")
	}
	return trees, notes
}

var repositoryValue = regexp.MustCompile(`(?m)^\s*repository\s*=\s*"([^"]+)"`)

// enginePkgPrefix は fpkg で engine を使う木の索引で、engine の名前に付く頭（flix.toml の repository から）。
func enginePkgPrefix(root string) string {
	b, err := os.ReadFile(filepath.Join(root, "flix.toml"))
	if err != nil {
		return ""
	}
	m := repositoryValue.FindSubmatch(b)
	if m == nil {
		return ""
	}
	return "$pkg$" + strings.NewReplacer(":", "$", "/", "$").Replace(string(m[1])) + "."
}

// mapFile は木の根からの相対 f を engine の根からの相対にする。Own の外（根の索引が持つ物の写し）は false。
func (t refactorTree) mapFile(f string) (string, bool) {
	rest, ok := strings.CutPrefix(f, t.Own)
	if !ok {
		return "", false
	}
	return t.As + rest, true
}

// mapWhere は `file:line:col` の file を mapFile で置き換える。
func (t refactorTree) mapWhere(w string) (string, bool) {
	if w == "" {
		return "", false
	}
	file, pos, _ := strings.Cut(w, ":")
	m, ok := t.mapFile(file)
	if !ok {
		return "", false
	}
	if pos == "" {
		return m, true
	}
	return m + ":" + pos, true
}

// treeQuery は木で流す問い。
type treeQuery struct {
	op     string // search・show・usages
	target string // 名前（usages --unused は ""）
	at     int    // rest の中の target の位置（無ければ -1）
	unused bool
}

// refactorValueFlags は search・show・usages が値を取る旗（target を探す時に値を飛ばす）。
var refactorValueFlags = map[string]bool{
	"--kind": true, "--what": true, "--depth": true, "--lines": true, "--max": true, "--limit": true,
	"--label": true, "--labels-file": true, "--receiver": true, "--outside": true, "--flixlint": true, "--stage": true,
}

// parseTreeQuery は木でも引く問いか。search・show・usages の名前の問いと usages --unused だけ（欄の問い --label は根だけ）。
func parseTreeQuery(rest []string) (treeQuery, bool) {
	q := treeQuery{at: -1}
	var pos []int
	for i := 0; i < len(rest); i++ {
		x := rest[i]
		switch {
		case x == "--unused":
			q.unused = true
		case x == "--label" || x == "--labels-file":
			return q, false
		case refactorValueFlags[x]:
			i++
		case strings.HasPrefix(x, "-"):
		default:
			pos = append(pos, i)
		}
	}
	if len(pos) == 0 {
		return q, false
	}
	q.op = rest[pos[0]]
	if len(pos) > 1 {
		q.at = pos[1]
		q.target = rest[pos[1]]
	}
	switch {
	case q.op == "usages" && q.unused:
		return q, true
	case q.op == "search" || q.op == "show" || q.op == "usages":
		return q, q.target != ""
	}
	return q, false
}

// withTarget は rest の target を name に替えた写し。
func (q treeQuery) withTarget(rest []string, name string) []string {
	out := append([]string(nil), rest...)
	if q.at >= 0 {
		out[q.at] = name
	}
	return out
}

// treeRun は木の根で refactor の問いを --json で流す口（テストが替える）。
type treeRun func(t refactorTree, rest []string) (stdout string, code int)

// treeAnswer は 1 本の木の答え（engine の根からの相対へ置き換え済み）。
type treeAnswer struct {
	Tree    string               `json:"tree"`
	Sym     string               `json:"sym,omitempty"`
	Decl    string               `json:"decl,omitempty"` // usages: 名前の宣言がこの木にある時の file:line:col
	Found   []refactor.Found     `json:"found,omitempty"`
	Shown   []refactor.Shown     `json:"shown,omitempty"`
	Sites   []refactor.UsageSite `json:"sites,omitempty"`
	Callers []refactor.Caller    `json:"callers,omitempty"`
}

func (a treeAnswer) empty() bool {
	return len(a.Found) == 0 && len(a.Shown) == 0 && len(a.Sites) == 0 && a.Decl == ""
}

// askTree は木 t に q を問い、t の物だけを返す。rootFound は根の索引が名前を当てたか。
//
// 根が当てた名前は engine の物なので、fpkg で使う木には頭を付けて問う（木の中の同じ名前の別物を拾わない）。
// 根が当てない名前（bench の中の名前・engine_web の名前）は書かれた名前のまま問う。
func askTree(t refactorTree, rest []string, q treeQuery, rootFound bool, run treeRun) (treeAnswer, bool) {
	ans := treeAnswer{Tree: t.Name}
	if q.op == "show" && rootFound {
		return ans, false
	}
	args := rest
	if q.op == "usages" && rootFound && t.EnginePrefix != "" {
		args = q.withTarget(rest, t.EnginePrefix+q.target)
	}
	out, code := run(t, args)
	if code != 0 {
		return ans, false
	}
	var raw struct {
		Sym     string               `json:"sym"`
		Found   []refactor.Found     `json:"found"`
		Shown   []refactor.Shown     `json:"shown"`
		Sites   []refactor.UsageSite `json:"sites"`
		Callers []refactor.Caller    `json:"callers"`
		Usage   refactor.Target      `json:"usage"`
	}
	if json.Unmarshal([]byte(out), &raw) != nil {
		return ans, false
	}
	ans.Sym = strings.TrimPrefix(raw.Sym, t.EnginePrefix)
	if t.EnginePrefix == "" || ans.Sym == raw.Sym {
		ans.Decl, _ = t.mapWhere(raw.Usage.Decl)
	}
	for _, f := range raw.Found {
		if m, ok := t.mapFile(f.File); ok {
			f.File = m
			ans.Found = append(ans.Found, f)
		}
	}
	for _, s := range raw.Shown {
		if m, ok := t.mapFile(s.File); ok {
			s.File = m
			ans.Shown = append(ans.Shown, s)
		}
	}
	for _, s := range raw.Sites {
		if m, ok := t.mapFile(s.File); ok {
			s.File = m
			ans.Sites = append(ans.Sites, s)
		}
	}
	ans.Callers = mapCallers(t, raw.Callers)
	return ans, !ans.empty()
}

// mapCallers は呼び手の木から t の物だけを残し、最初の使われ所を engine の根からの相対にする。
func mapCallers(t refactorTree, cs []refactor.Caller) []refactor.Caller {
	var out []refactor.Caller
	for _, c := range cs {
		w, ok := t.mapWhere(c.First)
		if !ok {
			continue
		}
		c.First = w
		c.Callers = mapCallers(t, c.Callers)
		out = append(out, c)
	}
	return out
}

// renderTreeAnswers は木の答えを根の答えの後ろに足す字にする。
func renderTreeAnswers(w io.Writer, q treeQuery, answers []treeAnswer) {
	for _, a := range answers {
		fmt.Fprintf(w, "── 別の package のソースの木 %s（%s）\n", a.Tree, q.op+" "+q.target)
		for _, f := range a.Found {
			pub := ""
			if f.Pub {
				pub = "  pub"
			}
			fmt.Fprintf(w, "  %s:%d  %s %s%s\n", f.File, f.Line, f.Kind, f.Sym, pub)
		}
		for _, s := range a.Shown {
			fmt.Fprintf(w, "── %s:%d-%d  %s（%s）\n%s\n", s.File, s.Start, s.End, s.Sym, s.Kind, s.Text)
		}
		if q.op == "usages" {
			decl := "engine の fpkg"
			if a.Decl != "" {
				decl = a.Decl
			}
			fmt.Fprintf(w, "  %s（%s）%d か所\n", a.Sym, decl, len(a.Sites))
		}
		if len(a.Callers) > 0 {
			renderCallers(w, a.Callers, "  ")
			continue
		}
		for _, s := range a.Sites {
			fmt.Fprintf(w, "  %s  %s  %s\n", s.Where(), s.Owner, s.What)
		}
	}
}

func renderCallers(w io.Writer, cs []refactor.Caller, indent string) {
	for _, c := range cs {
		fmt.Fprintf(w, "%s%s  %d  %s\n", indent, c.Owner, c.Count, c.First)
		renderCallers(w, c.Callers, indent+"  ")
	}
}

// usedInTree は --unused の候補のうち、木から使われている物 1 つ。
type usedInTree struct {
	Sym   string `json:"sym"`
	Decl  string `json:"decl"`
	Tree  string `json:"tree"`
	First string `json:"first"`
	Count int    `json:"count"`
}

// treeRefs は木の索引の def の参照を、engine の名前（頭を外した物）ごとに数える。t の物（Own の中）だけ。
// 自分の中の参照（再帰）は数えない（flixlint の --unused と同じ）。
func treeRefs(t refactorTree, rows []refactor.Row) map[string][]string {
	out := map[string][]string{}
	for _, r := range rows {
		if r.Kind != refactor.KindDefUse || r.Owner == r.Sym {
			continue
		}
		where, ok := t.mapWhere(r.Where())
		if !ok {
			continue
		}
		sym := r.Sym
		if t.EnginePrefix != "" {
			if sym, ok = strings.CutPrefix(sym, t.EnginePrefix); !ok {
				continue
			}
		}
		out[sym] = append(out[sym], where)
	}
	return out
}

// usedInTrees は根の --unused の候補（file:line → sym）のうち、どれかの木から使われている物。
func usedInTrees(cands map[string]string, refs map[string]map[string][]string, order []string) []usedInTree {
	var out []usedInTree
	decls := make([]string, 0, len(cands))
	for d := range cands {
		decls = append(decls, d)
	}
	sort.Slice(decls, func(i, j int) bool { return declLess(decls[i], decls[j]) })
	for _, d := range decls {
		sym := cands[d]
		for _, tree := range order {
			if ws := refs[tree][sym]; len(ws) > 0 {
				out = append(out, usedInTree{Sym: sym, Decl: d, Tree: tree, First: ws[0], Count: len(ws)})
			}
		}
	}
	return out
}

// declLess は file:line をファイルの名前の順、同じファイルなら行の数の順に並べる。
func declLess(a, b string) bool {
	fa, la, _ := strings.Cut(a, ":")
	fb, lb, _ := strings.Cut(b, ":")
	if fa != fb {
		return fa < fb
	}
	na, _ := strconv.Atoi(la)
	nb, _ := strconv.Atoi(lb)
	return na < nb
}

func hasAnyArg(rest []string, names ...string) bool {
	for _, a := range rest {
		for _, n := range names {
			if a == n {
				return true
			}
		}
	}
	return false
}

// unusedCandidates は根の --unused の JSON の候補を、根の索引の def の宣言で file:line → 完全な名前にする。
func unusedCandidates(out string, rows []refactor.Row) map[string]string {
	var raw struct {
		Sites []struct {
			File string `json:"file"`
			Line int    `json:"line"`
			What string `json:"what"`
		} `json:"sites"`
	}
	if json.Unmarshal([]byte(out), &raw) != nil {
		return nil
	}
	decl := map[string]string{}
	for _, r := range rows {
		if r.Kind == refactor.KindDefDecl {
			decl[fmt.Sprintf("%s:%d", r.File, r.Line)] = r.Sym
		}
	}
	cands := map[string]string{}
	for _, s := range raw.Sites {
		if s.What != "def" {
			continue
		}
		at := fmt.Sprintf("%s:%d", s.File, s.Line)
		if sym, ok := decl[at]; ok {
			cands[at] = sym
		}
	}
	return cands
}

// usedInTreesShown は --all・-v の無い時に --unused の後ろへ出す行の数（根の答えの一覧と同じ 10 行より少し多め）。
const usedInTreesShown = 20

// renderUsedInTrees は --unused の答えの後ろに、木から使われている候補を足す字にする（all でなければ頭の usedInTreesShown 件）。
func renderUsedInTrees(w io.Writer, used []usedInTree, all bool) {
	if len(used) == 0 {
		return
	}
	fmt.Fprintf(w, "── 上の候補のうち別の package のソースの木（bench・engine_web）から使われている物 %d 件（使っている物として扱う。消さない）\n", len(used))
	for i, u := range used {
		if !all && i == usedInTreesShown {
			fmt.Fprintf(w, "  …ほか %d 件（--all で画面に・--json の usedInTrees に全部）\n", len(used)-i)
			break
		}
		fmt.Fprintf(w, "  %s  %s  ← %s %d か所（%s）\n", u.Decl, u.Sym, u.Tree, u.Count, u.First)
	}
}

// mergeJSON は根の答えの JSON（object）に key を足す。読めなければ根の答えのまま。
func mergeJSON(rootOut, key string, v any) string {
	var obj map[string]json.RawMessage
	if json.Unmarshal([]byte(rootOut), &obj) != nil {
		return rootOut
	}
	b, err := json.Marshal(v)
	if err != nil {
		return rootOut
	}
	obj[key] = b
	merged, err := json.Marshal(obj)
	if err != nil {
		return rootOut
	}
	return string(merged) + "\n"
}

// treeLog は木の索引を作る時の出力から「索引を作ります」の 1 行だけを、木の名前を入れて通す。
// WhyNot: 落ちた時のログの終わりを通さない。木は根の答えに足す物で、bench の依存が揃っていないだけで
// 根の答えが十数行の依存の誤りに埋もれる。落ちた事は runTreeRefactor が 1 行で言う。
type treeLog struct {
	w    io.Writer
	name string
}

func (p treeLog) Write(b []byte) (int, error) {
	for _, l := range strings.SplitAfter(string(b), "\n") {
		if strings.HasPrefix(l, "[refactor] 索引") {
			io.WriteString(p.w, strings.Replace(l, "[refactor]", "[refactor "+p.name+"]", 1))
		}
	}
	return len(b), nil
}

// withoutArg は cmd から a を除いた写し。
func withoutArg(cmd []string, a string) []string {
	var out []string
	for _, c := range cmd {
		if c != a {
			out = append(out, c)
		}
	}
	return out
}

// runTreeRefactor は木 t の根で refactor を --json で流す（索引を作る時の 1 行は木の名前つきで標準エラーへ）。
func runTreeRefactor(t refactorTree, rest []string) (string, int) {
	var o, e strings.Builder
	runner := heavyRunner
	if !t.Resident {
		runner = func(stage refactor.Stage, desc, dir string, cmd []string, log string) int {
			return heavyRunner(stage, desc, dir, withoutArg(cmd, "--resident"), log)
		}
	}
	code := refactor.Run(&o, &e, t.Root, append(dropJSONFlag(rest), "--json"), refactor.Options{Run: runner, Verify: heavyVerify, Log: treeLog{os.Stderr, t.Name}})
	if code != 0 && !strings.Contains(e.String(), "索引にありません") && strings.TrimSpace(e.String()) != "" {
		fmt.Fprintf(os.Stderr, "[refactor %s] 索引を作れず飛ばした（%s。ログ %s）\n", t.Name, shortReason(e.String()), filepath.Join(t.Root, "build", "refactor", "index-resolved.log"))
	}
	return o.String(), code
}

// treeIndexRows は木 t の resolved の索引の行（無ければ作る）。
func treeIndexRows(t refactorTree) ([]refactor.Row, bool) {
	if _, code := runTreeRefactor(t, []string{"index"}); code != 0 {
		return nil, false
	}
	rows, err := refactor.ReadIndex(filepath.Join(t.Root, "build", "refactor", "spans-resolved.tsv"), refactor.Resolved)
	return rows, err == nil
}

// shortReason は refactor の止めた訳の頭（。か（ まで）。
func shortReason(s string) string {
	l, _, _ := strings.Cut(strings.TrimSpace(s), "\n")
	l = strings.TrimPrefix(l, "refactor: ")
	if i := strings.IndexAny(l, "（。"); i > 0 {
		l = l[:i]
	}
	return l
}

// refactorWithTrees は search・show・usages を根で流し、根の索引の外の木の答えを後ろに足す。
func refactorWithTrees(out, errOut *strings.Builder, rest []string, asJSON bool, q treeQuery, trees []refactorTree, notes []string, runRoot func(rest []string) (string, string, int), run treeRun, rows func(t refactorTree) ([]refactor.Row, bool), rootRows func() ([]refactor.Row, bool)) int {
	if q.unused {
		return unusedWithTrees(out, errOut, rest, asJSON, trees, runRoot, rows, rootRows)
	}
	// WhyNot: 根を字と --json の 2 回流さない。名前を当てたかは終了コードで分かる（当てない時は 0 以外）。
	rootOut, rootErr, code := runRoot(rest)
	var answers []treeAnswer
	for _, t := range trees {
		if a, ok := askTree(t, rest, q, code == 0, run); ok {
			answers = append(answers, a)
		}
	}
	if len(answers) == 0 {
		out.WriteString(rootOut)
		errOut.WriteString(rootErr)
		writeTreeNotes(errOut, notes)
		return code
	}
	if code != 0 {
		// 根に無い名前を木で当てた。根の「索引にありません」は木の答えと食い違うので出さない。
		rootOut, rootErr = "", ""
	}
	errOut.WriteString(rootErr)
	writeTreeNotes(errOut, notes)
	if asJSON {
		base := rootOut
		if strings.TrimSpace(base) == "" {
			base = fmt.Sprintf(`{"op":%q,"target":%q,"exit":0}`, q.op, q.target)
		}
		out.WriteString(mergeJSON(base, "trees", answers))
		return 0
	}
	out.WriteString(rootOut)
	var b strings.Builder
	renderTreeAnswers(&b, q, answers)
	out.WriteString(b.String())
	return 0
}

func unusedWithTrees(out, errOut *strings.Builder, rest []string, asJSON bool, trees []refactorTree, runRoot func(rest []string) (string, string, int), rows func(t refactorTree) ([]refactor.Row, bool), rootRows func() ([]refactor.Row, bool)) int {
	rootOut, rootErr, code := runRoot(rest)
	if !asJSON {
		out.WriteString(rootOut)
	}
	errOut.WriteString(rootErr)
	if code != 0 {
		if asJSON {
			out.WriteString(rootOut)
		}
		return code
	}
	jsonOut := rootOut
	if !asJSON {
		var c int
		jsonOut, _, c = runRoot(append(dropJSONFlag(rest), "--json"))
		if c != 0 {
			return code
		}
	}
	all, ok := rootRows()
	if !ok {
		if asJSON {
			out.WriteString(rootOut)
		}
		return code
	}
	cands := unusedCandidates(jsonOut, all)
	refs := map[string]map[string][]string{}
	var order []string
	for _, t := range trees {
		rs, ok := rows(t)
		if !ok {
			continue
		}
		refs[t.Name] = treeRefs(t, rs)
		order = append(order, t.Name)
	}
	used := usedInTrees(cands, refs, order)
	if asJSON {
		if len(used) == 0 {
			out.WriteString(rootOut)
		} else {
			out.WriteString(mergeJSON(rootOut, "usedInTrees", used))
		}
		return code
	}
	var b strings.Builder
	renderUsedInTrees(&b, used, hasAnyArg(rest, "--all", "--verbose", "-v"))
	out.WriteString(b.String())
	return code
}

func writeTreeNotes(errOut *strings.Builder, notes []string) {
	for _, n := range notes {
		fmt.Fprintf(errOut, "[refactor] %s\n", n)
	}
}
