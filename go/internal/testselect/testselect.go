// Package testselect は差分のファイルから流す門を選ぶ（bin/fge test-select・make verify SUITE=affected）。
// 表は根の gates.json（packages・go・goReads・wiring・inert と門の select / hold / gui / covers / docsInput）。
//
// 段階は 3 つで、案 B（呼び手のたどり）は Downstream だけを差し替える:
//
//	Classify   ファイル → 種類とパッケージ（と重ねて当たる reads・input・go の表・goReads）
//	Downstream 種類とパッケージ → 当たったパッケージ（今は feeds の閉包）
//	Assemble   当たったパッケージと門 → make の行の並び
package testselect

import (
	"fmt"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/gates"
	"github.com/ababup1192/flix_game_engine/go/internal/precommit"
)

// Kind はファイルの種類（段階 1 で 1 つに決める）。
type Kind string

const (
	KindDocs    Kind = "docs"
	KindVersion Kind = "version"
	KindWiring  Kind = "wiring"
	KindPackage Kind = "package"
	KindGo      Kind = "go"
	KindData    Kind = "data"
	KindInert   Kind = "inert"
	KindUnowned Kind = "unowned"
)

// GoAll は go のパッケージの「全部」。
const GoAll = "*"

// Change は差分のファイル 1 つ。
type Change struct {
	Path    string
	Deleted bool
	// VersionOnly は flix.toml の差が version の行だけの時（--files・新しいファイルでは立てない）。
	VersionOnly bool
}

// FileClass は Classify の答え 1 つ。
type FileClass struct {
	Path    string `json:"path"`
	Kind    Kind   `json:"kind"`
	Package string `json:"package,omitempty"`
	Local   bool   `json:"local,omitempty"`
	Deleted bool   `json:"deleted,omitempty"`
	// All は安全側で「全部」にしたファイル。
	All bool `json:"all,omitempty"`
	// Reads は reads に当たったパッケージ（下流へ伝えない）。
	Reads []string `json:"reads,omitempty"`
	// Gates は input・docsInput・go の表で直に当たった門。
	Gates []string `json:"gates,omitempty"`
	// GoPkgs は go-test で流す go のパッケージ（go/internal/<名前> の名前・. は main・* は全部）。
	GoPkgs []string `json:"goPkgs,omitempty"`
}

// Step は理由の段階 1 つ（file → kind → package → feeds → gate）。B は package の前に declaration の段階を差し込む。
type Step struct {
	Kind  string `json:"kind"`
	Label string `json:"label"`
}

// Why は段階の並び。
type Why []Step

func (w Why) String() string {
	var parts []string
	for _, s := range w {
		parts = append(parts, s.Label)
	}
	return strings.Join(parts, " → ")
}

func (w Why) with(kind, label string) Why {
	return append(append(Why{}, w...), Step{kind, label})
}

// Table は gates.json の中身と、そこから引く索引。
type Table struct {
	File  *gates.File
	pkgs  map[string]*gates.Package
	gates map[string]*gates.Gate
}

// NewTable は索引を作る。
func NewTable(f *gates.File) *Table {
	t := &Table{File: f, pkgs: map[string]*gates.Package{}, gates: map[string]*gates.Gate{}}
	for i := range f.Packages {
		t.pkgs[f.Packages[i].ID] = &f.Packages[i]
	}
	for i := range f.Gates {
		t.gates[f.Gates[i].ID] = &f.Gates[i]
	}
	return t
}

// Owner はパスの持ち主のパッケージ（一番長い dir）。
func (t *Table) Owner(p string) *gates.Package {
	var best *gates.Package
	for i := range t.File.Packages {
		pk := &t.File.Packages[i]
		if strings.HasPrefix(p, pk.Dir) && (best == nil || len(pk.Dir) > len(best.Dir)) {
			best = pk
		}
	}
	return best
}

func matches(m *precommit.Matcher, p string) bool {
	return m != nil && m.Match(p)
}

// selectable は input・docsInput で当ててよい門（make の入口を持ち、never でも束の部品でもない）。
func selectable(g *gates.Gate) bool {
	return g.Make != "" && g.Select != "never" && g.Select != "package" && g.Select != "go"
}

func isDocs(p string) bool {
	return strings.HasSuffix(p, ".md") && !strings.HasPrefix(p, "testdata/") && !strings.HasPrefix(p, "go/")
}

// GoPkgOf は go/ の下のパスの go のパッケージの名前（go/internal/<x>/… → x・go/ 直下 → .・go.mod と go.sum → *）。
func GoPkgOf(p string) string {
	rest := strings.TrimPrefix(p, "go/")
	if rest == "go.mod" || rest == "go.sum" {
		return GoAll
	}
	if r, ok := strings.CutPrefix(rest, "internal/"); ok {
		name, _, _ := strings.Cut(r, "/")
		return name
	}
	return "."
}

// Classify は段階 1（種類を 1 つ）と段階 2（reads・input・go の表・goReads を重ねて足す）。
func Classify(t *Table, changes []Change) []FileClass {
	var out []FileClass
	for _, c := range changes {
		out = append(out, classifyOne(t, c))
	}
	return out
}

func classifyOne(t *Table, c Change) FileClass {
	p := c.Path
	fc := FileClass{Path: p, Deleted: c.Deleted}
	owner := t.Owner(p)
	if owner != nil {
		fc.Package = owner.ID
	}
	switch {
	case isDocs(p):
		fc.Kind = KindDocs
		for i := range t.File.Gates {
			g := &t.File.Gates[i]
			if selectable(g) && matches(g.DocsInput, p) {
				fc.Gates = append(fc.Gates, g.ID)
			}
		}
		for _, r := range t.File.GoReads {
			if r.Docs && r.Reads.Match(p) {
				fc.GoPkgs = append(fc.GoPkgs, r.Pkgs...)
			}
		}
		return fc
	case path.Base(p) == "flix.toml" && c.VersionOnly:
		fc.Kind = KindVersion
		return fc
	case t.File.Wiring.Match(p):
		fc.Kind = KindWiring
		fc.All = owner == nil
	case strings.HasPrefix(p, "go/"):
		fc.Kind = KindGo
		fc.Package = ""
		fc.GoPkgs = []string{GoPkgOf(p)}
		hit := false
		for _, row := range t.File.Go {
			if row.Input.Match(p) {
				hit = true
				fc.Gates = append(fc.Gates, row.Gates...)
				fc.Reads = append(fc.Reads, row.Tests...)
			}
		}
		// go の表のどの行にも当たらない go/ のファイルは、どの道具の物か分からないので全部。
		fc.All = !hit
	case owner != nil:
		fc.Kind = KindPackage
		fc.Local = matches(owner.Local, p)
	case t.File.Inert.Match(p):
		fc.Kind = KindInert
	default:
		fc.Kind = KindUnowned
	}
	// 段階 2: 種類に関わらず重ねて足す。
	for i := range t.File.Packages {
		pk := &t.File.Packages[i]
		if pk.ID != fc.Package && matches(pk.Reads, p) {
			fc.Reads = append(fc.Reads, pk.ID)
		}
	}
	for i := range t.File.Gates {
		g := &t.File.Gates[i]
		if selectable(g) && matches(g.Input, p) {
			fc.Gates = append(fc.Gates, g.ID)
		}
	}
	for _, r := range t.File.GoReads {
		if r.Reads.Match(p) {
			fc.GoPkgs = append(fc.GoPkgs, r.Pkgs...)
		}
	}
	if fc.Kind == KindUnowned {
		if len(fc.Reads) > 0 || len(fc.Gates) > 0 || len(fc.GoPkgs) > 0 {
			fc.Kind = KindData
		} else {
			fc.All = true
		}
	}
	return fc
}

// Affected は当たったパッケージ 1 つと、なぜ当たったか（多くて 3 本）。
type Affected map[string][]Why

const maxWhy = 3

func (a Affected) add(id string, w Why) {
	if len(a[id]) < maxWhy {
		a[id] = append(a[id], w)
	}
}

// DownstreamFunc は「下流の決め方」の段階。B は呼び手のたどりで同じ形の物を作る。
type DownstreamFunc func(t *Table, classes []FileClass) Affected

// ByFeeds は案 A の下流: パッケージの差は feeds の閉包へ伝え、local と reads は伝えない。全部のファイルは全パッケージ。
func ByFeeds(t *Table, classes []FileClass) Affected {
	a := Affected{}
	for _, fc := range classes {
		base := Why{{"file", fc.Path}, {"kind", string(fc.Kind)}}
		if fc.All {
			for _, pk := range t.File.Packages {
				a.add(pk.ID, base.with("all", "全部"))
			}
			continue
		}
		for _, id := range fc.Reads {
			a.add(id, base.with("reads", id+" が読む"))
		}
		if fc.Kind != KindPackage && fc.Kind != KindWiring || fc.Package == "" {
			continue
		}
		start := base.with("package", fc.Package)
		a.add(fc.Package, start)
		if fc.Local {
			continue
		}
		type item struct {
			id string
			w  Why
		}
		queue := []item{{fc.Package, start}}
		seen := map[string]bool{fc.Package: true}
		for len(queue) > 0 {
			cur := queue[0]
			queue = queue[1:]
			pk := t.pkgs[cur.id]
			if pk == nil {
				continue
			}
			for _, next := range pk.Feeds {
				if seen[next] {
					continue
				}
				seen[next] = true
				w := cur.w.with("feeds", next)
				a.add(next, w)
				queue = append(queue, item{next, w})
			}
		}
	}
	return a
}

// Env は外の事実（go の import の向き・exec するパッケージ・fpkg の新しさ）。テストで差し替える。
type Env interface {
	// GoImporters は名前の go のパッケージと、それを import（テストの import を含む）でたどって頼る側の名前。
	GoImporters(names []string) ([]string, error)
	// GoAllPkgs は go のパッケージの名前の全部（go-test の全部を PKG と FRESH に分けるため）。
	GoAllPkgs() ([]string, error)
	// GoExecPkgs は本体かテストか import の先に exec.Command を持つ go のパッケージの名前。
	GoExecPkgs() ([]string, error)
	// FpkgStale は engine_full の fpkg が無いか、engine 側の src・render_gl/java より古い時に理由を返す。
	FpkgStale() (bool, string)
}

// Line は流す門 1 つ。
type Line struct {
	ID     string            `json:"id"`
	Make   string            `json:"make"`
	Vars   map[string]string `json:"vars,omitempty"`
	About  string            `json:"about"`
	Time   string            `json:"time"`
	Prereq bool              `json:"prereq,omitempty"`
	Why    []string          `json:"why"`
	// Reason は流さない門の理由（gui・hold）。
	Reason string `json:"reason,omitempty"`
	order  int
	rank   int
}

// Gate は Runner に渡す形。
func (l Line) Gate() gates.Gate {
	return gates.Gate{ID: l.ID, About: l.About, Make: l.Make, Vars: l.Vars, Time: l.Time, Prereq: l.Prereq}
}

// Display は人が打てる形の make の行（空白を含む値は ” で包む）。
func (l Line) Display() string {
	parts := []string{"make", l.Make}
	keys := make([]string, 0, len(l.Vars))
	for k := range l.Vars {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		v := l.Vars[k]
		if strings.ContainsAny(v, " \t") {
			v = "'" + v + "'"
		}
		parts = append(parts, k+"="+v)
	}
	return strings.Join(parts, " ")
}

// Plan は選んだ答え。
type Plan struct {
	Files      []FileClass         `json:"files"`
	AllBecause []string            `json:"allBecause,omitempty"`
	Packages   map[string][]string `json:"packages"`
	Run        []Line              `json:"run"`
	// GUI は画面を開く門（--gui の時は Run にも入る）。Hold は選んだが流さない門。
	GUI  []Line `json:"gui"`
	Hold []Line `json:"hold"`
}

// NotRun は選んだのに流さない門の id（Runner が最後に知らせる）。
func (p *Plan) NotRun(withGUI bool) []string {
	var ids []string
	if !withGUI {
		for _, l := range p.GUI {
			ids = append(ids, l.ID)
		}
	}
	for _, l := range p.Hold {
		ids = append(ids, l.ID)
	}
	return ids
}

// Options は Assemble のつまみ。
type Options struct {
	GUI bool
	// FilesFrom は precommit-dry に渡すファイルの一覧の置き場（FILES_FROM=）。
	FilesFrom string
}

// Select は 3 つの段階を順に流す。
func Select(t *Table, changes []Change, env Env, down DownstreamFunc, opt Options) (*Plan, error) {
	classes := Classify(t, changes)
	return Assemble(t, classes, down(t, classes), env, opt)
}

type picked struct {
	why []string
}

// Assemble は当たったパッケージと門から make の行の並びを作る。
func Assemble(t *Table, classes []FileClass, aff Affected, env Env, opt Options) (*Plan, error) {
	plan := &Plan{Files: classes, Packages: map[string][]string{}}
	if len(classes) == 0 {
		return plan, nil
	}
	sel := map[string]*picked{}
	add := func(id string, why string) {
		p := sel[id]
		if p == nil {
			p = &picked{}
			sel[id] = p
		}
		for _, w := range p.why {
			if w == why {
				return
			}
		}
		if len(p.why) < maxWhy {
			p.why = append(p.why, why)
		}
	}
	anyCode, anyGo, all := false, false, false
	goPkgs := map[string]bool{}
	var goSrc []string
	for _, fc := range classes {
		if fc.Kind != KindDocs {
			anyCode = true
		}
		if fc.All {
			all = true
			plan.AllBecause = append(plan.AllBecause, fc.Path+"（"+string(fc.Kind)+"）")
		}
		base := Why{{"file", fc.Path}, {"kind", string(fc.Kind)}}
		for _, g := range fc.Gates {
			add(g, base.String())
		}
		if fc.Kind == KindGo {
			anyGo = true
			for _, n := range fc.GoPkgs {
				if n != GoAll {
					goSrc = append(goSrc, n)
				}
			}
		}
		for _, n := range fc.GoPkgs {
			goPkgs[n] = true
		}
		if fc.Kind == KindVersion && fc.Package != "" && t.reachesEngineFull(fc.Package) {
			add("sync-engine-full", base.with("package", fc.Package).String())
		}
	}
	for _, g := range t.File.Gates {
		switch {
		case g.Select == "always":
			add(g.ID, "いつも")
		case g.Select == "code" && anyCode:
			add(g.ID, ".md 以外の差がある")
		case all && selectable(&g):
			add(g.ID, "全部（"+plan.AllBecause[0]+"）")
		}
	}
	var testPkgs, checkDirs []string
	ids := make([]string, 0, len(aff))
	for id := range aff {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	consumers := t.feedClosure("engine_full")
	needFresh := false
	for _, id := range ids {
		pk := t.pkgs[id]
		if pk == nil {
			return nil, fmt.Errorf("下流の段階が知らないパッケージ %s を返しました", id)
		}
		var whys []string
		for _, w := range aff[id] {
			whys = append(whys, w.String())
		}
		plan.Packages[id] = whys
		why := aff[id][0].String()
		if pk.Test {
			testPkgs = append(testPkgs, id)
		}
		if pk.Check {
			checkDirs = append(checkDirs, strings.TrimSuffix(pk.Dir, "/"))
		}
		for _, g := range pk.Gates {
			add(g, why)
		}
		if consumers[id] {
			needFresh = true
		}
	}
	if anyGo || all {
		add("go-build", "go/ の差（道具は作り直すまで門に効かない）")
	}
	var goLine *Line
	if anyGo || all || len(goPkgs) > 0 {
		l, err := goTestLine(t, goPkgs, goSrc, all, env)
		if err != nil {
			return nil, err
		}
		goLine = l
	}
	if needFresh && sel["sync-engine-full"] == nil {
		if stale, reason := env.FpkgStale(); stale {
			add("sync-engine-full", "テンプレートか bench を流すのに "+reason)
		}
	}
	// covers: 覆う側を選んだら、覆われる側（同じ make の入口）を落とす。
	for id := range sel {
		g := t.gates[id]
		if g == nil {
			continue
		}
		for _, prefix := range g.Covers {
			for other := range sel {
				if o := t.gates[other]; o != nil && other != id && strings.HasPrefix(other, prefix) && o.Make == g.Make {
					delete(sel, other)
				}
			}
		}
	}
	order := map[string]int{}
	for i, g := range t.File.Gates {
		order[g.ID] = i
	}
	var lines []Line
	for id, p := range sel {
		g := t.gates[id]
		if g == nil {
			return nil, fmt.Errorf("表が知らない門 %s を選びました（bin/fge gates --check）", id)
		}
		if g.Make == "" {
			continue
		}
		l := Line{ID: id, Make: g.Make, Vars: copyVars(g.Vars), About: g.About, Time: g.Time, Prereq: g.Prereq, Why: p.why, order: order[id]}
		switch {
		case g.Select == "hold":
			l.Reason = g.Hold
			plan.Hold = append(plan.Hold, l)
			continue
		case g.GUI:
			l.Reason = "画面を開く門（GUI=1 で流す）"
			plan.GUI = append(plan.GUI, l)
			if !opt.GUI {
				continue
			}
		}
		if id == "precommit-dry" && opt.FilesFrom != "" {
			l.Vars = map[string]string{"FILES_FROM": opt.FilesFrom}
		}
		lines = append(lines, l)
	}
	if len(testPkgs) > 0 {
		jobs := len(testPkgs)
		if jobs > 6 {
			jobs = 6
		}
		g := t.gates["test"]
		lines = append(lines, Line{ID: "test", Make: "test", Vars: map[string]string{"PKGS": strings.Join(testPkgs, " "), "JOBS": fmt.Sprint(jobs)},
			About: g.About, Time: testTimeOf(t, testPkgs, g.Time), Why: pkgWhy(plan, testPkgs), order: order["test"]})
	}
	if len(checkDirs) > 0 {
		g := t.gates["check-pkgs"]
		var ids []string
		for _, d := range checkDirs {
			ids = append(ids, t.Owner(d+"/").ID)
		}
		lines = append(lines, Line{ID: "check-pkgs", Make: "check-pkgs", Vars: map[string]string{"DIRS": strings.Join(checkDirs, " ")},
			About: g.About, Time: checkTimeOf(t, ids, g.Time), Why: pkgWhy(plan, ids), order: order["check-pkgs"]})
	}
	if goLine != nil {
		goLine.order = order["go-test"]
		lines = append(lines, *goLine)
	}
	for i := range lines {
		lines[i].rank = rankOf(t, lines[i])
	}
	sortLines(lines)
	sortLines(plan.GUI)
	sortLines(plan.Hold)
	plan.Run = lines
	return plan, nil
}

func copyVars(v map[string]string) map[string]string {
	if len(v) == 0 {
		return nil
	}
	out := map[string]string{}
	for k, x := range v {
		out[k] = x
	}
	return out
}

func pkgWhy(plan *Plan, ids []string) []string {
	var out []string
	for _, id := range ids {
		out = append(out, id+": "+plan.Packages[id][0])
	}
	return out
}

// rankOf は並びの組（prereq → 安い確かめ → テスト → 型検査の束 → 生成と比べ）。
func rankOf(t *Table, l Line) int {
	g := t.gates[l.ID]
	switch {
	case l.Prereq:
		return 0
	case g != nil && (g.Select == "always" || g.Select == "code") || l.ID == "check":
		return 1
	case l.ID == "test" || l.ID == "go-test":
		return 2
	case l.ID == "check-pkgs":
		return 3
	}
	return 4
}

func sortLines(lines []Line) {
	sort.SliceStable(lines, func(i, j int) bool {
		if lines[i].rank != lines[j].rank {
			return lines[i].rank < lines[j].rank
		}
		return lines[i].order < lines[j].order
	})
}

func (t *Table) feedClosure(id string) map[string]bool {
	seen := map[string]bool{}
	queue := []string{id}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		if pk := t.pkgs[cur]; pk != nil {
			for _, n := range pk.Feeds {
				if !seen[n] {
					seen[n] = true
					queue = append(queue, n)
				}
			}
		}
	}
	return seen
}

// reachesEngineFull はパッケージが engine_full か、feeds でそこへ届くか（engine 側か）。
func (t *Table) reachesEngineFull(id string) bool {
	if id == "engine_full" || id == "root" {
		return true
	}
	return t.feedClosure(id)["engine_full"]
}

// goTestLine は go-test の行（PKG= は流す go のパッケージ・FRESH= はそのうち exec を持つ物）。
func goTestLine(t *Table, pkgs map[string]bool, src []string, all bool, env Env) (*Line, error) {
	full := all || pkgs[GoAll]
	names := map[string]bool{}
	var why []string
	if full {
		every, err := env.GoAllPkgs()
		if err != nil {
			return nil, err
		}
		for _, n := range every {
			names[n] = true
		}
		why = append(why, "go のテストの全部（go.mod・表と testdata・全部のファイル）")
	} else {
		for n := range pkgs {
			names[n] = true
		}
		if len(src) > 0 {
			imp, err := env.GoImporters(src)
			if err != nil {
				return nil, err
			}
			for _, n := range imp {
				names[n] = true
			}
		}
		why = append(why, "変わった go のパッケージと頼る側・go のテストが読むファイル（goReads）")
	}
	execs, err := env.GoExecPkgs()
	if err != nil {
		return nil, err
	}
	isExec := map[string]bool{}
	for _, n := range execs {
		isExec[n] = true
	}
	// WhyNot: PKG と FRESH を重ねない — 重ねると exec を持つ重いパッケージを cache ありと -count=1 で 2 回流す。
	var run, fresh []string
	for n := range names {
		if isExec[n] {
			fresh = append(fresh, n)
		} else {
			run = append(run, n)
		}
	}
	sort.Strings(run)
	sort.Strings(fresh)
	vars := map[string]string{}
	if len(run) > 0 {
		vars["PKG"] = strings.Join(run, ",")
	}
	if len(fresh) > 0 {
		vars["FRESH"] = strings.Join(fresh, ",")
		why = append(why, "FRESH は exec を持つので cache を使わない（子の読むファイルを cache が追わない）")
	}
	g := t.gates["go-test"]
	return &Line{ID: "go-test", Make: "go-test", Vars: vars, About: g.About, Time: g.Time, Why: why}, nil
}

// testTimeOf は make test の目安（並べた中で一番長い 1 本）。目安を持たないパッケージがあれば門の文のまま。
func testTimeOf(t *Table, ids []string, fallback string) string {
	var longest time.Duration
	who := ""
	for _, id := range ids {
		pk := t.pkgs[id]
		if pk == nil {
			return fallback
		}
		d, err := time.ParseDuration(pk.TestTime)
		if err != nil {
			return fallback
		}
		if d > longest {
			longest, who = d, id
		}
	}
	if len(ids) == 1 {
		return longest.String()
	}
	return fmt.Sprintf("%s（%d 本を並べた中の %s で決まる）", longest, len(ids), who)
}

// checkTimeOf は make check-pkgs の目安（1 本ずつ流すので和）。目安を持たないパッケージがあれば門の文のまま。
func checkTimeOf(t *Table, ids []string, fallback string) string {
	var sum time.Duration
	for _, id := range ids {
		pk := t.pkgs[id]
		if pk == nil {
			return fallback
		}
		d, err := time.ParseDuration(pk.CheckTime)
		if err != nil {
			return fallback
		}
		sum += d
	}
	return fmt.Sprintf("%s（%d 本・1 本ずつ）", sum, len(ids))
}
