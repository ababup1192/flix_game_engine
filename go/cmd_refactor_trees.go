package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/status"
	"github.com/ababup1192/flixlint/go/refactor"
)

// refactorTree は engine のルートの索引（src と各パッケージの test）に入れられない Flix のソースツリー。
// 別の flix.toml で組む物なので、ルートを替えて索引を作り、答えをルートの答えの後ろへ足す。
//
// WhyNot: ルートの索引の sources に足さない。bench はそれぞれ def main を持ち、engine を fpkg（mount = "fge"）で使うので
// ルートの src と 1 つに組めない。engine_web は TeaVM の JSO と fge-web の jar が無いと組めず、ルートの flix.toml に足すと
// ルートの flix build（全パッケージを 1 つに組む確かめ）まで web の jar を要るようになる。
type refactorTree struct {
	Name string // 出す時の名前（bench/crowd2d・engine_web）
	Root string // 索引を作るルート（flix.toml のある所）
	// Own は Root からの相対で、このソースツリーの物とするファイルの頭（"" は全部）。Own の外はルートの索引が持つ物の写し。
	Own string
	// As は Own を engine のルートからの相対へ置き換える頭。
	As string
	// EnginePrefix は、このソースツリーから engine の名前を引く時に付ける頭（fpkg で使うソースツリーの $pkg$…$flix_game_engine.）。
	// 同じ package に engine を持つソースツリーは ""。
	EnginePrefix string
	// Resident は常駐の flixlint で索引を作るか。
	// WhyNot: bench を常駐にしない。ルートごとに JVM が 1 本立ち、bench の数だけ並ぶ。bench の索引は小さく（1 本 3 秒ほど）、
	// 鍵は bench の src と lib の fpkg なので作り直すのは make sync-engine の後だけ。
	Resident bool
}

// webTreeDir は engine_web を engine の src と 1 つに組む生成物のルート（make sync-engine-full-web が作る）。
const webTreeDir = "build/engine_full_web"

// refactorTrees は engine のルート root で、ルートの索引の外にあるソースツリーと、見ていないソースツリーの 1 行。
// engine のルートでなければ空。
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

// enginePkgPrefix は fpkg で engine を使うソースツリーの索引で、engine の名前に付く頭（flix.toml の repository から）。
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

// mapFile はソースツリーのルートからの相対 f を engine のルートからの相対にする。Own の外は false。
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

// treeQuery はソースツリーでも引く問い。
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

// parseTreeQuery はソースツリーでも引く問いか。search・show・usages の名前の問いと usages --unused だけ（欄の問い --label はルートだけ）。
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

// withoutMax は rest から --max N を外した写し（q.at はずれるので、外した後に parseTreeQuery し直す）。
// WhyNot: ソースツリーへ --max を渡さない。--max はルートの答えの歯止めで、ソースツリーの件数で終了コードを決めない。
func withoutMax(rest []string) []string {
	var out []string
	for i := 0; i < len(rest); i++ {
		if rest[i] == "--max" {
			i++
			continue
		}
		if strings.HasPrefix(rest[i], "--max=") {
			continue
		}
		out = append(out, rest[i])
	}
	return out
}

// treeRun はソースツリーのルートで refactor の問いを --json で流す（テストが替える）。
type treeRun func(t refactorTree, rest []string) (stdout, stderr string, code int)

// treeGate は索引を作れなかったソースツリーを覚え、flix.toml・lib・src が新しくなるまで問わない。
//
// WhyNot: 落ちたソースツリーを毎回問い直さない。依存の揃わない bench は問うたびに索引を作りに行き（1 本 2 秒ほど）、
// そのたびに Maven へ取りに行って 429 を受ける。
type treeGate struct {
	path  string // 覚えておくファイル（"" なら覚えない）
	stamp func(t refactorTree) int64
	run   treeRun
	mu    *sync.Mutex // ソースツリーを並べて問う時に、覚えておくファイルの読み書きを 1 つずつにする
}

type treeSkip struct {
	Stamp  int64  `json:"stamp"`
	Reason string `json:"reason"`
}

func (g treeGate) load() map[string]treeSkip {
	out := map[string]treeSkip{}
	if g.path == "" {
		return out
	}
	if b, err := os.ReadFile(g.path); err == nil {
		json.Unmarshal(b, &out)
	}
	return out
}

func (g treeGate) save(m map[string]treeSkip) {
	if g.path == "" {
		return
	}
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return
	}
	os.MkdirAll(filepath.Dir(g.path), 0o755)
	os.WriteFile(g.path, append(b, '\n'), 0o644)
}

// skipped は t を前に覚えていて、それから t が新しくなっていないか。
// WhyNot: 覚えていないソースツリーの時刻を見ない。engine_web の lib と src を毎回たどると、それだけで問いが遅くなる。
func (g treeGate) skipped(t refactorTree) (treeSkip, bool) {
	g.lock()
	defer g.unlock()
	s, ok := g.load()[t.Name]
	return s, ok && g.stamp(t) <= s.Stamp
}

// update は t の覚えを s にする（nil なら消す）。変わらなければ書かない。
func (g treeGate) update(name string, s *treeSkip) {
	g.lock()
	defer g.unlock()
	skips := g.load()
	if _, had := skips[name]; !had && s == nil {
		return
	}
	if s == nil {
		delete(skips, name)
	} else {
		skips[name] = *s
	}
	g.save(skips)
}

func (g treeGate) lock() {
	if g.mu != nil {
		g.mu.Lock()
	}
}

func (g treeGate) unlock() {
	if g.mu != nil {
		g.mu.Unlock()
	}
}

// ask はソースツリー t に rest を問う。問わなかった・索引を作れなかった時は note に 1 行。
func (g treeGate) ask(t refactorTree, rest []string) (string, int, string) {
	if info, err := os.Stat(filepath.Join(t.Root, "lib")); err != nil || !info.IsDir() {
		return "", -1, fmt.Sprintf("%s は依存（lib/）がまだ無いので引いていない（%s で make check して依存を入れる）", t.Name, t.Root)
	}
	if s, skipped := g.skipped(t); skipped {
		return "", -1, fmt.Sprintf("%s は前に索引を作れなかったので引いていない（%s）。flix.toml・lib・src が新しくなったら引き直す", t.Name, s.Reason)
	}
	out, errOut, code := g.run(t, rest)
	if code != 0 && strings.Contains(errOut, "を作れません") {
		reason := shortReason(errOut)
		if strings.Contains(errOut, "flix check") || strings.Contains(errOut, "依存") {
			reason += "。" + t.Root + " で make check して依存を入れる"
		}
		// WhyNot: 問う前の時刻で覚えない。落ちる途中で flix が lib/ に書くので、次の問いで「新しくなった」と取り違える。
		g.update(t.Name, &treeSkip{Stamp: g.stamp(t), Reason: reason})
		return "", code, fmt.Sprintf("%s は索引を作れず飛ばした（%s・ログ %s）。直るまで問わない", t.Name, reason, filepath.Join(t.Root, "build", "refactor", "index-resolved.log"))
	}
	g.update(t.Name, nil)
	return out, code, ""
}

// treeStamp は t の flix.toml・lib・src の中で一番新しい更新時刻（UnixNano）。
// lib の下の symlink（fpkg）は先の時刻を見る（make sync-engine で作り直すと新しくなる）。
func treeStamp(t refactorTree) int64 {
	var newest int64
	see := func(path string) {
		if info, err := os.Stat(path); err == nil && info.ModTime().UnixNano() > newest {
			newest = info.ModTime().UnixNano()
		}
	}
	see(filepath.Join(t.Root, "flix.toml"))
	for _, dir := range []string{"lib", "src"} {
		filepath.WalkDir(filepath.Join(t.Root, dir), func(path string, _ fs.DirEntry, err error) error {
			if err == nil {
				see(path)
			}
			return nil
		})
	}
	return newest
}

// treeAnswer は 1 本のソースツリーの答え（engine のルートからの相対へ置き換え済み）。
type treeAnswer struct {
	Tree    string               `json:"tree"`
	Sym     string               `json:"sym,omitempty"`
	Decl    string               `json:"decl,omitempty"` // usages: 名前の宣言がこのソースツリーにある時の file:line:col
	Found   []refactor.Found     `json:"found,omitempty"`
	Shown   []refactor.Shown     `json:"shown,omitempty"`
	Sites   []refactor.UsageSite `json:"sites,omitempty"`
	Callers []refactor.Caller    `json:"callers,omitempty"`
}

func (a treeAnswer) empty() bool {
	return len(a.Found) == 0 && len(a.Shown) == 0 && len(a.Sites) == 0 && a.Decl == ""
}

// askTree はソースツリー t に q を問い、t の物だけを返す。rootSym はルートが当てた名前の完全な形（当てていなければ ""）。
//
// ルートが当てた名前は engine の物なので、fpkg で使うソースツリーには頭を付けて問う（中の同じ名前の別物を拾わない）。
// ルートが当てない名前（bench の中の名前・engine_web の名前）は書かれた名前のまま問う。
func askTree(g treeGate, t refactorTree, rest []string, q treeQuery, rootSym string) (treeAnswer, bool, string) {
	ans := treeAnswer{Tree: t.Name}
	if q.op == "show" && rootSym != "" {
		return ans, false, ""
	}
	args := rest
	if q.op == "usages" && rootSym != "" && t.EnginePrefix != "" {
		args = q.withTarget(rest, t.EnginePrefix+rootSym)
	}
	out, code, note := g.ask(t, args)
	if code != 0 {
		return ans, false, note
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
		return ans, false, note
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
	return ans, !ans.empty(), note
}

// mapCallers は呼び手の階層から t の物だけを残し、最初の使われ所を engine のルートからの相対にする。
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

// listLimit はルートの答えと同じ一覧の行数（--limit N。--all・-v・--verbose なら 0＝全部）。
func listLimit(rest []string) int {
	if hasAnyArg(rest, "--all", "--verbose", "-v") {
		return 0
	}
	if v, _, ok := declValueFlag(rest, "--limit"); ok {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return n
		}
	}
	return 10
}

// shownCount は n 件のうち limit で切って出す数（limit 0 は全部）。
func shownCount(n, limit int) int {
	if limit > 0 && n > limit {
		return limit
	}
	return n
}

func writeMore(w io.Writer, n, shown int) {
	if n > shown {
		fmt.Fprintf(w, "  …ほか %d 件（--all で全部）\n", n-shown)
	}
}

// renderTreeAnswers はソースツリーの答えをルートの答えの後ろに足す字にする（一覧はルートと同じ件数で切る）。
func renderTreeAnswers(w io.Writer, q treeQuery, answers []treeAnswer, limit int) {
	for _, a := range answers {
		fmt.Fprintf(w, "── 別の package のソースツリー %s（%s）\n", a.Tree, q.op+" "+q.target)
		n := shownCount(len(a.Found), limit)
		for _, f := range a.Found[:n] {
			pub := ""
			if f.Pub {
				pub = "  pub"
			}
			fmt.Fprintf(w, "  %s:%d  %s %s%s\n", f.File, f.Line, f.Kind, f.Sym, pub)
		}
		writeMore(w, len(a.Found), n)
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
			n := shownCount(len(a.Callers), limit)
			renderCallers(w, a.Callers[:n], "  ")
			writeMore(w, len(a.Callers), n)
			continue
		}
		n = shownCount(len(a.Sites), limit)
		for _, s := range a.Sites[:n] {
			fmt.Fprintf(w, "  %s  %s  %s\n", s.Where(), s.Owner, s.What)
		}
		writeMore(w, len(a.Sites), n)
	}
}

func renderCallers(w io.Writer, cs []refactor.Caller, indent string) {
	for _, c := range cs {
		fmt.Fprintf(w, "%s%s  %d  %s\n", indent, c.Owner, c.Count, c.First)
		renderCallers(w, c.Callers, indent+"  ")
	}
}

// usedInTree は --unused の候補のうち、ソースツリーから使われている物 1 つ。
type usedInTree struct {
	Sym   string `json:"sym"`
	Decl  string `json:"decl"`
	Tree  string `json:"tree"`
	First string `json:"first"`
	Count int    `json:"count"`
}

// treeRefs はソースツリーの索引の def の参照を、engine の名前（頭を外した物）ごとに数える。t の物（Own の中）だけ。
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

// usedInTrees はルートの --unused の候補（file:line → sym）のうち、どれかのソースツリーから使われている物。
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

// unusedCandidatesFromJSON はルートの --unused --json の候補の def（file:line → 完全な名前）。
func unusedCandidatesFromJSON(out string) map[string]string {
	var raw struct {
		Sites []struct {
			File string `json:"file"`
			Line int    `json:"line"`
			Sym  string `json:"sym"`
			What string `json:"what"`
		} `json:"sites"`
	}
	cands := map[string]string{}
	if json.Unmarshal([]byte(out), &raw) != nil {
		return cands
	}
	for _, s := range raw.Sites {
		if s.What == "def" {
			cands[fmt.Sprintf("%s:%d", s.File, s.Line)] = s.Sym
		}
	}
	return cands
}

var lastUsagesLine = regexp.MustCompile(`^(\S+\.flix):(\d+):\d+\s+(\S+)`)

// unusedCandidatesFromList はルートが字の --unused で書く一覧（build/refactor/last-usages.txt）の def（file:line → 完全な名前）。
// WhyNot: ルートを --json でもう 1 度流さない。索引の 25 万行を読み直すぶん、問いが倍かかる。
func unusedCandidatesFromList(r io.Reader) map[string]string {
	cands := map[string]string{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		m := lastUsagesLine.FindStringSubmatch(sc.Text())
		if m == nil || m[3] == "use" {
			continue
		}
		cands[m[1]+":"+m[2]] = m[3]
	}
	return cands
}

// usedInTreesShown は --all・-v の無い時に --unused の後ろへ出す行の数（ルートの答えの一覧と同じ 10 行より少し多め）。
const usedInTreesShown = 20

// renderUsedInTrees は --unused の答えの後ろに、ソースツリーから使われている候補を足す字にする（all でなければ頭の usedInTreesShown 件）。
func renderUsedInTrees(w io.Writer, used []usedInTree, all bool) {
	if len(used) == 0 {
		return
	}
	fmt.Fprintf(w, "── 上の候補のうち別の package のソースツリー（bench・engine_web）から使われている物 %d 件（使っている物として扱う。消さない）\n", len(used))
	for i, u := range used {
		if !all && i == usedInTreesShown {
			fmt.Fprintf(w, "  …ほか %d 件（--all で画面に・--json の usedInTrees に全部）\n", len(used)-i)
			break
		}
		fmt.Fprintf(w, "  %s  %s  ← %s %d か所（%s）\n", u.Decl, u.Sym, u.Tree, u.Count, u.First)
	}
}

// appendJSONKey はルートの答えの JSON（object）の終わりに key を足す。ルートの鍵の順と改行はそのまま。読めなければルートの答えのまま。
func appendJSONKey(rootOut, key string, v any) string {
	body := strings.TrimRight(rootOut, " \t\r\n")
	if !strings.HasSuffix(body, "}") || !json.Valid([]byte(body)) {
		return rootOut
	}
	b, err := json.Marshal(v)
	if err != nil {
		return rootOut
	}
	head := strings.TrimRight(body[:len(body)-1], " \t\r\n")
	sep := ","
	if strings.HasSuffix(head, "{") {
		sep = ""
	}
	return head + sep + strconv.Quote(key) + ":" + string(b) + "}" + rootOut[len(body):]
}

// treeLog はソースツリーの索引を作る時の出力から「索引を作ります」の 1 行だけを、ソースツリーの名前を入れて通す。
// WhyNot: 落ちた時のログの終わりを通さない。bench の依存が揃っていないだけでルートの答えが十数行の依存の誤りに埋もれる。
// 落ちた事は treeGate が 1 行で言う。
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

// runTreeRefactor はソースツリー t のルートで refactor を --json で流す（索引を作る時の 1 行はソースツリーの名前つきで標準エラーへ）。
func runTreeRefactor(t refactorTree, rest []string) (string, string, int) {
	var o, e strings.Builder
	runner := heavyRunner
	if !t.Resident {
		runner = func(stage refactor.Stage, desc, dir string, cmd []string, log string) int {
			return heavyRunner(stage, desc, dir, withoutArg(cmd, "--resident"), log)
		}
	}
	code := refactor.Run(&o, &e, t.Root, append(dropJSONFlag(rest), "--json"), refactor.Options{Run: runner, Verify: heavyVerify, Log: treeLog{os.Stderr, t.Name}})
	return o.String(), e.String(), code
}

// readTreeRows はソースツリー t の resolved の索引の行（treeGate で index を流した後に読む）。
func readTreeRows(t refactorTree) ([]refactor.Row, error) {
	return refactor.ReadIndex(filepath.Join(t.Root, "build", "refactor", "spans-resolved.tsv"), refactor.Resolved)
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

// rootStatus はルートの答えが、名前を当てた（found）・当たらなかった（missing）・それ以外で落ちた（どちらも偽）のどれか。
// 当たらなかったのは search の 0 件と、show・usages の「索引にありません」だけ。
// WhyNot: 0 でない終了コードを全部「当たらなかった」としない。--max の歯止めや索引を作れなかった時のルートの答えと
// 終了コードを、ソースツリーの答えで消してしまう。
func rootStatus(q treeQuery, asJSON bool, out, errOut string, code int) (found, missing bool) {
	if code == 0 {
		return true, false
	}
	if q.op == "search" {
		var raw struct {
			Found []refactor.Found `json:"found"`
		}
		empty := strings.Contains(out, ": 0 件")
		if asJSON {
			empty = json.Unmarshal([]byte(out), &raw) == nil && len(raw.Found) == 0
		}
		return false, code == 1 && empty
	}
	return false, strings.Contains(errOut, "索引にありません")
}

// treeRefactor はルートで refactor を流す関数・ソースツリーを問う treeGate・ソースツリーの索引の行を読む関数（テストが替える）。
type treeRefactor struct {
	runRoot   func(rest []string) (string, string, int)
	gate      treeGate
	readRows  func(t refactorTree) ([]refactor.Row, error)
	lastUsage func(since time.Time) (io.ReadCloser, error) // ルートの last-usages.txt（since より古ければ誤り）
}

// rootSymOf はルートが当てた usages の名前の完全な形（--json の sym）。字の問いならルートを --json でもう 1 度流す。
func (r treeRefactor) rootSymOf(rest []string, asJSON bool, out string, q treeQuery) string {
	if !asJSON {
		var code int
		out, _, code = r.runRoot(append(dropJSONFlag(rest), "--json"))
		if code != 0 {
			return q.target
		}
	}
	var raw struct {
		Sym string `json:"sym"`
	}
	if json.Unmarshal([]byte(out), &raw) != nil || raw.Sym == "" {
		return q.target
	}
	return raw.Sym
}

// run は search・show・usages をルートで流し、ルートの索引の外のソースツリーの答えを後ろに足す。
func (r treeRefactor) run(out, errOut *strings.Builder, rest []string, asJSON bool, q treeQuery, trees []refactorTree, notes []string) int {
	if q.unused {
		return r.unused(out, errOut, rest, asJSON, trees, notes)
	}
	rootOut, rootErr, code := r.runRoot(rest)
	found, missing := rootStatus(q, asJSON, rootOut, rootErr, code)
	if !found && !missing {
		out.WriteString(rootOut)
		errOut.WriteString(rootErr)
		return code
	}
	rootSym := ""
	if found && q.op != "search" {
		rootSym = q.target
		if q.op == "usages" && hasEnginePrefix(trees) {
			rootSym = r.rootSymOf(rest, asJSON, rootOut, q)
		}
	}
	treeRest := withoutMax(rest)
	tq, _ := parseTreeQuery(treeRest)
	type asked struct {
		a    treeAnswer
		ok   bool
		note string
	}
	results := make([]asked, len(trees))
	var wg sync.WaitGroup
	for i, t := range trees {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a, ok, note := askTree(r.gate, t, treeRest, tq, rootSym)
			results[i] = asked{a, ok, note}
		}()
	}
	wg.Wait()
	var answers []treeAnswer
	for _, res := range results {
		if res.note != "" {
			notes = append(notes, res.note)
		}
		if res.ok {
			answers = append(answers, res.a)
		}
	}
	if len(answers) == 0 {
		out.WriteString(rootOut)
		errOut.WriteString(rootErr)
		writeTreeNotes(errOut, notes)
		return code
	}
	if missing {
		// ルートに無い名前をソースツリーで当てた。ルートの「索引にありません」・0 件はソースツリーの答えと食い違うので出さない。
		rootOut, rootErr, code = fmt.Sprintf(`{"exit":0,"op":%q,"target":%q}`, q.op, q.target)+"\n", "", 0
		if !asJSON {
			rootOut = ""
		}
	}
	errOut.WriteString(rootErr)
	writeTreeNotes(errOut, notes)
	if asJSON {
		out.WriteString(appendJSONKey(rootOut, "trees", answers))
		return code
	}
	out.WriteString(rootOut)
	var b strings.Builder
	renderTreeAnswers(&b, q, answers, listLimit(rest))
	out.WriteString(b.String())
	return code
}

func hasEnginePrefix(trees []refactorTree) bool {
	for _, t := range trees {
		if t.EnginePrefix != "" {
			return true
		}
	}
	return false
}

func (r treeRefactor) unused(out, errOut *strings.Builder, rest []string, asJSON bool, trees []refactorTree, notes []string) int {
	start := time.Now()
	rootOut, rootErr, code := r.runRoot(rest)
	errOut.WriteString(rootErr)
	if code != 0 {
		out.WriteString(rootOut)
		return code
	}
	var cands map[string]string
	if asJSON {
		cands = unusedCandidatesFromJSON(rootOut)
	} else if f, err := r.lastUsage(start); err == nil {
		cands = unusedCandidatesFromList(f)
		f.Close()
	}
	refs := map[string]map[string][]string{}
	var order []string
	for _, t := range trees {
		if _, c, note := r.gate.ask(t, []string{"index"}); c != 0 {
			if note != "" {
				notes = append(notes, note)
			}
			continue
		}
		rs, err := r.readRows(t)
		if err != nil {
			continue
		}
		refs[t.Name] = treeRefs(t, rs)
		order = append(order, t.Name)
	}
	writeTreeNotes(errOut, notes)
	used := usedInTrees(cands, refs, order)
	if asJSON {
		if len(used) == 0 {
			out.WriteString(rootOut)
		} else {
			out.WriteString(appendJSONKey(rootOut, "usedInTrees", used))
		}
		return code
	}
	out.WriteString(rootOut)
	var b strings.Builder
	renderUsedInTrees(&b, used, hasAnyArg(rest, "--all", "--verbose", "-v"))
	out.WriteString(b.String())
	return code
}

// openFresh は path を、since より後に書かれていれば開く。
func openFresh(path string, since time.Time) (io.ReadCloser, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.ModTime().Before(since.Add(-time.Second)) {
		return nil, fmt.Errorf("%s は今の問いより古い", path)
	}
	return os.Open(path)
}

func writeTreeNotes(errOut *strings.Builder, notes []string) {
	for _, n := range notes {
		fmt.Fprintf(errOut, "[refactor] %s\n", n)
	}
}
