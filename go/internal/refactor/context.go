package refactor

// trace と context: 呼ぶ先をたどる口と、直す前に知りたい事を 1 回で返す口（cymbal の trace・context に当たる、読むだけの問い）。
//
//	trace <Mod.f> [--depth N]        この def が呼ぶ def を下へ（既定 2 段）。プロジェクトの def は場所つき、engine と標準は名前だけ
//	context <Mod.f|Enum|Alias> [--limit N]   本文・呼び手（使う def ごと）・呼ぶ先・使う型・テストの呼び手を 1 回で
//
// 呼ぶ・使うの関係は参照の索引 spans-<段>.refs.tsv（全体の索引から def-use・type-use・case の作る／当てる行だけを
// 抜いた物。宣言の索引と同じ時に書く）から取る。全体の索引（20 万行）を読まずに済む。
// 索引の後に直したファイルの行は古い索引の物で、そう断る（行がずれているかもしれない・足した呼び出しは無い）。
//
// WhyNot: usages --callers を呼び直さない。usages は全体の索引を読み、種類（呼び出し・参照…）を字で見分ける。
// context が要るのは「どの def が使うか」だけで、参照の索引で足りる。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// refKinds は参照の索引に入れる行の種類。
var refKinds = map[string]bool{KindDefUse: true, KindTypeUse: true, KindCaseConstruct: true, KindCasePattern: true}

const refsHeader = "# fge-refactor-refs 1"

func (b Builder) refsPath(s Stage) string {
	return filepath.Join(b.Dir(), "spans-"+string(s)+".refs.tsv")
}

// writeRefs は全体の索引から参照の行だけを書く（kind・file・line・col・sym・owner の 6 列）。
func writeRefs(path, src string, rows []Row) {
	var sb strings.Builder
	fmt.Fprintf(&sb, "%s src=%s\n", refsHeader, src)
	for _, r := range rows {
		if refKinds[r.Kind] && r.Owner != "" {
			fmt.Fprintf(&sb, "%s\t%s\t%d\t%d\t%s\t%s\n", r.Kind, r.File, r.Line, r.Col, r.Sym, r.Owner)
		}
	}
	tmp := path + ".tmp"
	if os.WriteFile(tmp, []byte(sb.String()), 0o644) == nil {
		os.Rename(tmp, path)
	}
}

// readRefs は参照の索引を読む（頭の行の src が宣言の索引と違えば ok=false）。
func readRefs(path, src string) ([]Row, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	head, body, _ := strings.Cut(string(data), "\n")
	if head != refsHeader+" src="+src {
		return nil, false
	}
	rows := make([]Row, 0, strings.Count(body, "\n"))
	for _, line := range strings.Split(body, "\n") {
		c := strings.Split(line, "\t")
		if len(c) != 6 {
			continue
		}
		l, _ := strconv.Atoi(c[2])
		col, _ := strconv.Atoi(c[3])
		rows = append(rows, Row{Kind: c[0], File: c[1], Line: l, Col: col, Sym: c[4], Owner: c[5]})
	}
	return rows, true
}

// refs は宣言の索引と同じ時の参照の行。無いか合わなければ作り直す（宣言の索引も書き直す）。
func (ds *declSet) refs() ([]Row, error) {
	if rows, ok := readRefs(ds.b.refsPath(ds.stage), ds.src); ok {
		return rows, nil
	}
	fresh, err := ds.b.rebuildDecls(ds.stage, mustHashes(ds.b), mustKey(ds.b, ds.stage), ds.b.envKey())
	if err != nil {
		return nil, err
	}
	ds.rows, ds.src, ds.stale, ds.changed = fresh.rows, fresh.src, false, nil
	rows, _ := readRefs(ds.b.refsPath(ds.stage), ds.src)
	return rows, nil
}

// Callee は呼ぶ先 1 つ。
type Callee struct {
	Sym     string   `json:"sym"`
	Where   string   `json:"where,omitempty"` // プロジェクトの def の宣言の場所（engine・標準は空）
	From    string   `json:"from"`            // project・engine・std
	Count   int      `json:"count"`
	Seen    bool     `json:"seen,omitempty"` // 上の段で出た（下は辿らない）
	Callees []Callee `json:"callees,omitempty"`
}

// symFrom は sym がどこの物か（宣言が索引にあればプロジェクト・$pkg$ で始まれば engine などのパッケージ・ほかは標準）。
func symFrom(sym string, decl map[string]string) string {
	switch {
	case decl[sym] != "":
		return "project"
	case strings.HasPrefix(sym, "$pkg$"):
		return "engine"
	}
	return "std"
}

// shortSym はパッケージの印（$pkg$github$owner$repo.）を落とした名前。
func shortSym(sym string) string {
	if strings.HasPrefix(sym, "$pkg$") {
		if i := strings.Index(sym, "."); i > 0 {
			return sym[i+1:]
		}
	}
	return sym
}

// isNamed は演算子（|> など）でない名前か。
func isNamed(sym string) bool {
	for _, c := range sym {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' {
			return true
		}
	}
	return false
}

// declWhere は宣言の場所（sym → file:line）。
func declWhere(rows []Row) map[string]string {
	out := map[string]string{}
	for _, r := range rows {
		if declKindsForShow[r.Kind] {
			out[r.Sym] = fmt.Sprintf("%s:%d", r.File, r.Line)
		}
	}
	return out
}

// CalleesOf は owner の中の def の呼び出しを呼ぶ先ごとに畳む（プロジェクト → engine → 標準、同じ内は名前の順）。
func CalleesOf(refs []Row, owner string, decl map[string]string) []Callee {
	by := map[string]*Callee{}
	for _, r := range refs {
		if r.Kind != KindDefUse || r.Owner != owner || r.Sym == owner || !isNamed(r.Sym) {
			continue
		}
		c, ok := by[r.Sym]
		if !ok {
			c = &Callee{Sym: r.Sym, From: symFrom(r.Sym, decl)}
			if c.From == "project" {
				c.Where = decl[r.Sym]
			}
			by[r.Sym] = c
		}
		c.Count++
	}
	out := make([]Callee, 0, len(by))
	for _, c := range by {
		out = append(out, *c)
	}
	rank := map[string]int{"project": 0, "engine": 1, "std": 2}
	sort.Slice(out, func(i, j int) bool {
		if rank[out[i].From] != rank[out[j].From] {
			return rank[out[i].From] < rank[out[j].From]
		}
		return out[i].Sym < out[j].Sym
	})
	return out
}

// CalleeTree は owner から depth 段まで、プロジェクトの def の呼ぶ先を辿る。同じ def は 1 度だけ辿る。
func CalleeTree(refs []Row, owner string, depth int, decl map[string]string) []Callee {
	seen := map[string]bool{owner: true}
	var grow func(o string, level int) []Callee
	grow = func(o string, level int) []Callee {
		cs := CalleesOf(refs, o, decl)
		for i := range cs {
			if cs[i].From != "project" {
				continue
			}
			if seen[cs[i].Sym] {
				cs[i].Seen = true
				continue
			}
			seen[cs[i].Sym] = true
			if level < depth {
				cs[i].Callees = grow(cs[i].Sym, level+1)
			}
		}
		return cs
	}
	return grow(owner, 1)
}

// CallersOf は sym（def・enum・case・型 alias）を使う def ごとに畳む（使う数の多い順）。enum は case の作る・当てるも数える。
func CallersOf(refs []Row, sym string, decl map[string]string) []Callee {
	by := map[string]*Callee{}
	for _, r := range refs {
		if r.Owner == sym || !(r.Sym == sym || isChild(r.Sym, sym)) {
			continue
		}
		c, ok := by[r.Owner]
		if !ok {
			c = &Callee{Sym: r.Owner, Where: fmt.Sprintf("%s:%d", r.File, r.Line), From: "project"}
			by[r.Owner] = c
		}
		c.Count++
	}
	out := make([]Callee, 0, len(by))
	for _, c := range by {
		out = append(out, *c)
	}
	sort.Slice(out, func(i, j int) bool {
		ti, tj := strings.HasPrefix(out[i].Where, "test/"), strings.HasPrefix(out[j].Where, "test/")
		if ti != tj {
			return tj
		}
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Sym < out[j].Sym
	})
	return out
}

// TypesOf は owner が使う型（型の注記・case の作る／当てる）のうち、プロジェクトで宣言した物（名前の順）。
func TypesOf(refs []Row, owner string, decl map[string]string) []Callee {
	by := map[string]*Callee{}
	for _, r := range refs {
		if r.Owner != owner {
			continue
		}
		sym := ""
		switch r.Kind {
		case KindTypeUse:
			sym = r.Sym
		case KindCaseConstruct, KindCasePattern:
			sym = parentSym(r.Sym)
		}
		if sym == "" || sym == owner || decl[sym] == "" {
			continue
		}
		c, ok := by[sym]
		if !ok {
			c = &Callee{Sym: sym, Where: decl[sym], From: "project"}
			by[sym] = c
		}
		c.Count++
	}
	out := make([]Callee, 0, len(by))
	for _, c := range by {
		out = append(out, *c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Sym < out[j].Sym })
	return out
}

// Context は context の答え（--json の形）。
type Context struct {
	Shown   Shown    `json:"shown"`
	Callers []Callee `json:"callers"`
	Tests   []Callee `json:"tests"`
	Callees []Callee `json:"callees"`
	Types   []Callee `json:"types"`
	Stale   []string `json:"stale,omitempty"` // 索引の後に直したファイル（呼ぶ・使うはその前の物）
}

// traceRun・contextRun の終了コード: 0 答えた・2 呼び方か索引の誤り。
func traceRun(out, errOut *strings.Builder, b Builder, s Stage, a args) int {
	ds, refs, decl, code := loadForRefs(errOut, b, s)
	if code != 0 {
		return code
	}
	t, err := ResolveTarget(ds.rows, a.target)
	if err != nil {
		fmt.Fprintf(errOut, "refactor trace: %v\n", err)
		return 2
	}
	if t.Kind != "def" {
		fmt.Fprintf(errOut, "refactor trace: %s は %s（呼ぶ先を辿れるのは def だけ。使う所は context か usages）\n", t.Sym, t.Kind)
		return 2
	}
	depth := a.depth
	if depth <= 0 {
		depth = 2
	}
	tree := CalleeTree(refs, t.Sym, depth, decl)
	if a.asJSON {
		js, _ := json.Marshal(map[string]any{"op": "trace", "sym": t.Sym, "depth": depth, "callees": tree, "stale": sortedKeys(ds.changed)})
		out.Write(js)
		out.WriteString("\n")
		return 0
	}
	fmt.Fprintf(out, "trace %s（%s・%d 段）\n", t.Sym, decl[t.Sym], depth)
	writeCallees(out, tree, 1)
	staleNote(out, ds)
	return 0
}

func contextRun(out, errOut *strings.Builder, b Builder, s Stage, a args) int {
	ds, err := b.LoadDecls(s)
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		return 2
	}
	src := &srcCache{root: b.Root}
	// 本文を先に引く（直したファイルの宣言なら作り直すので、参照の索引もそれに合わせて読む）。
	sh, err := ds.show(a.target, src)
	if err != nil {
		fmt.Fprintf(errOut, "refactor context: %v\n", err)
		return 2
	}
	refs, err := ds.refs()
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		return 2
	}
	decl := declWhere(ds.rows)
	target := sh.Sym
	if sh.Via != "" {
		target = sh.Via // case を名指しした時は、その case を使う所
	}
	all := CallersOf(refs, target, decl)
	c := Context{Shown: sh, Callers: []Callee{}, Tests: []Callee{}, Callees: []Callee{}, Types: []Callee{}, Stale: sortedKeys(ds.changed)}
	for _, x := range all {
		if strings.HasPrefix(x.Where, "test/") {
			c.Tests = append(c.Tests, x)
		} else {
			c.Callers = append(c.Callers, x)
		}
	}
	if sh.Kind == "def" {
		c.Callees = CalleesOf(refs, sh.Sym, decl)
		c.Types = TypesOf(refs, sh.Sym, decl)
	}
	if a.asJSON {
		js, _ := json.Marshal(c)
		out.Write(js)
		out.WriteString("\n")
		return 0
	}
	kind := sh.Kind
	if sh.Via != "" {
		kind += "・" + sh.Via + " を持つ"
	}
	if sh.Note != "" {
		kind += "・" + sh.Note
	}
	fmt.Fprintf(out, "── %s:%d-%d  %s（%s）\n%s\n", sh.File, sh.Start, sh.End, sh.Sym, kind, sh.Text)
	limit := a.limit
	if a.all {
		limit = 0
	}
	writeGroup(out, "呼び手", c.Callers, limit)
	writeGroup(out, "テストの呼び手", c.Tests, limit)
	if sh.Kind == "def" {
		var proj, other []string
		for _, x := range c.Callees {
			if x.From == "project" {
				proj = append(proj, fmt.Sprintf("%s %s", x.Sym, x.Where))
			} else {
				other = append(other, shortSym(x.Sym))
			}
		}
		fmt.Fprintf(out, "呼ぶ先 %d:\n", len(c.Callees))
		for _, p := range proj {
			fmt.Fprintf(out, "  %s\n", p)
		}
		if len(other) > 0 {
			fmt.Fprintf(out, "  engine・標準: %s\n", strings.Join(other, "・"))
		}
		var ts []string
		for _, x := range c.Types {
			ts = append(ts, fmt.Sprintf("%s %s", x.Sym, x.Where))
		}
		if len(ts) > 0 {
			fmt.Fprintf(out, "型 %d: %s\n", len(ts), strings.Join(ts, "・"))
		}
	}
	staleNote(out, ds)
	return 0
}

func loadForRefs(errOut *strings.Builder, b Builder, s Stage) (*declSet, []Row, map[string]string, int) {
	ds, err := b.LoadDecls(s)
	if err == nil {
		var refs []Row
		if refs, err = ds.refs(); err == nil {
			return ds, refs, declWhere(ds.rows), 0
		}
	}
	fmt.Fprintf(errOut, "refactor: %v\n", err)
	return nil, nil, nil, 2
}

func writeGroup(out *strings.Builder, title string, cs []Callee, limit int) {
	n := 0
	for _, c := range cs {
		n += c.Count
	}
	fmt.Fprintf(out, "%s %d（%d か所）:\n", title, len(cs), n)
	for i, c := range cs {
		if limit > 0 && i >= limit {
			fmt.Fprintf(out, "  …ほか %d（--all で全部・使う所の全部は usages）\n", len(cs)-limit)
			break
		}
		times := ""
		if c.Count > 1 {
			times = fmt.Sprintf(" ×%d", c.Count)
		}
		fmt.Fprintf(out, "  %s %s%s\n", c.Sym, c.Where, times)
	}
}

func writeCallees(out *strings.Builder, cs []Callee, level int) {
	pad := strings.Repeat("  ", level)
	var other []string
	for _, c := range cs {
		if c.From != "project" {
			other = append(other, shortSym(c.Sym))
			continue
		}
		mark := ""
		if c.Seen {
			mark = "（上に出た）"
		}
		fmt.Fprintf(out, "%s%s %s%s\n", pad, c.Sym, c.Where, mark)
		writeCallees(out, c.Callees, level+1)
	}
	if len(other) > 0 {
		fmt.Fprintf(out, "%sengine・標準: %s\n", pad, strings.Join(other, "・"))
	}
}

func staleNote(out *strings.Builder, ds *declSet) {
	if len(ds.changed) > 0 {
		fmt.Fprintf(out, "（呼ぶ・使うは索引を作った時の物。その後に直したファイル: %s）\n", strings.Join(sortedKeys(ds.changed), "・"))
	}
}
