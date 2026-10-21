package refactor

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// DeadQuery は remove-dead の問い。
type DeadQuery struct {
	WithTests bool
	Only      string // "" は両方・test-only・unreferenced
	TestDirs  []string
	Skip      map[string]bool
	// Engine は engine の根（ゲームの Makefile が include する mk/*.mk も入口の名前を持つ）。空なら見ない。
	Engine string
	// Def は候補をこの def だけに絞る（Mod.name。終わりで当てる）。
	Def string
	// Library は fpkg で配るライブラリか（pub の def は使う側がこの索引の外にいるので、消さずに fix へ回す）。
	Library bool
}

// DeadPlan は remove-dead の計画。
type DeadPlan struct {
	Targets  []Fixed // 消す def（why は test-only・unreferenced・道連れ）
	Tests    []Fixed // 一緒に消すテスト
	Fix      []Fixed // 消さずに人へ回す物
	Edits    []Edit
	Docs     []Fixed // doc を移す転送先（消す包みの doc を受ける def）
	Sites    int     // 候補の数（--skip・fix を含む）
	TestOnly int     // test-only の数（flixlint の test-only-api と同じ決め方。同じ mod の中で使う物も含む）
}

type defInfo struct {
	Row
	Pub, Inst, Test bool
	Ext             Row
}

func (d defInfo) isTestFile(dirs []string) bool {
	for _, t := range dirs {
		if strings.HasPrefix(d.File, t+"/") {
			return true
		}
	}
	return false
}

func inDirs(file string, dirs []string) bool {
	for _, t := range dirs {
		if strings.HasPrefix(file, t+"/") {
			return true
		}
	}
	return false
}

// PlanDead は消してよい def の計画。候補は src の pub な def のうち、参照がテストからだけの物（test-only）と
// 参照が 0 の物（unreferenced）。自分の中の参照（再帰）は数えない。
//   - テストから参照される候補は --with-tests の時だけ消す。参照する def が全部 @Test で、その @Test が src の def を
//     候補（と道連れ）のほかに使わない時だけ、テストごと消す。それ以外は fix。
//   - 消す def だけが使っていた pub でない def（private の助け）は道連れで消す（残すとコンパイラが使われない def で止まる）。
//   - 名前が .flix の外（Makefile・json・flow など git の知るファイル）に字で出る候補は fix（入口かもしれない）。
func PlanDead(root string, rows []Row, q DeadQuery) (DeadPlan, error) {
	var plan DeadPlan
	defs, order := defTable(rows)
	for _, s := range order {
		if d := defs[s]; d.Ext.File == "" {
			return plan, fmt.Errorf("%s: def の範囲が無い（索引の形が古い。flixlint を上げる）", d.Where())
		}
	}
	refs := refsBySym(rows)      // sym → 参照（自分の中の物は除く）
	usesOf := map[string][]Row{} // owner → その def の中の参照
	for _, r := range rows {
		if r.Kind == KindDefUse && r.Owner != r.Sym {
			usesOf[r.Owner] = append(usesOf[r.Owner], r)
		}
	}
	type cand struct {
		d   defInfo
		why string
	}
	var cands []cand
	for _, s := range order {
		d := defs[s]
		if !d.Pub || d.Inst || d.Test || inDirs(d.File, q.TestDirs) || strings.HasSuffix(s, ".main") || s == "main" || (q.Def != "" && !nameMatches(s, q.Def)) {
			continue
		}
		rs := refs[s]
		fromTest, fromOwnMod, fromOtherSrc := 0, 0, 0
		for _, r := range rs {
			switch {
			case inDirs(r.File, q.TestDirs):
				fromTest++
			case modOf(r.Owner) == modOf(s):
				fromOwnMod++
			default:
				fromOtherSrc++
			}
		}
		// test-only は flixlint の規則 test-only-api と同じ決め方（テストから呼ばれ、ほかの mod の src からは呼ばれない）。
		// 同じ mod の中で使われる物は消せない（pub を外すかは人が決める）ので fix。
		switch {
		case len(rs) == 0 && q.Only != "test-only":
			cands = append(cands, cand{d, "unreferenced"})
		case fromTest > 0 && fromOtherSrc == 0 && q.Only != "unreferenced":
			plan.TestOnly++
			if fromOwnMod > 0 {
				plan.Fix = append(plan.Fix, Fixed{d.Row, fmt.Sprintf("test-only・同じ mod の中で %d か所使う（消せない。pub を外すかテストを直すのは人）", fromOwnMod)})
				continue
			}
			cands = append(cands, cand{d, "test-only"})
		}
	}
	plan.Sites = len(cands) + len(plan.Fix)
	mentioned, err := mentionedOutsideFlix(root, q.Engine)
	if err != nil {
		return plan, err
	}
	removed := map[string]bool{}
	var targets []cand
	for _, c := range cands {
		switch {
		case q.Skip[c.d.File+":"+fmt.Sprint(c.d.Line)]:
			plan.Fix = append(plan.Fix, Fixed{c.d.Row, "--skip で外した"})
		case q.Library:
			plan.Fix = append(plan.Fix, Fixed{c.d.Row, c.why + "・ライブラリ（fpkg で配る）の pub は使う側が索引の外にいる（使う側を確かめて手で消す）"})
		case mentioned[c.d.Sym] != "":
			plan.Fix = append(plan.Fix, Fixed{c.d.Row, c.why + "・名前が .flix の外の " + mentioned[c.d.Sym] + " に字で出る（入口か文書かもしれない。確かめて手で消す）"})
		default:
			targets = append(targets, c)
			removed[c.d.Sym] = true
		}
	}
	// テストが参照する候補: --with-tests で、そのテストが候補のほかに src の def を使わなければテストごと消す。
	tests := map[string]bool{}
	var keep []cand
	for _, c := range targets {
		if c.why != "test-only" {
			keep = append(keep, c)
			continue
		}
		if !q.WithTests {
			removed[c.d.Sym] = false
			plan.Fix = append(plan.Fix, Fixed{c.d.Row, fmt.Sprintf("テストが参照する（%d か所）。--with-tests でテストごと消す", len(refs[c.d.Sym]))})
			continue
		}
		ok, why := true, ""
		for _, r := range refs[c.d.Sym] {
			o, known := defs[r.Owner]
			if !known || !o.Test {
				ok, why = false, fmt.Sprintf("@Test でない %s が参照する", r.Owner)
				break
			}
			for _, u := range usesOf[r.Owner] {
				ud, project := defs[u.Sym]
				if project && !inDirs(ud.File, q.TestDirs) && !removed[u.Sym] && u.Extra != "sugar" {
					ok, why = false, fmt.Sprintf("テスト %s が src の %s も使う（テストを直すか残すかは人が決める）", r.Owner, u.Sym)
					break
				}
			}
			if !ok {
				break
			}
		}
		if !ok {
			removed[c.d.Sym] = false
			plan.Fix = append(plan.Fix, Fixed{c.d.Row, why})
			continue
		}
		keep = append(keep, c)
		for _, r := range refs[c.d.Sym] {
			tests[r.Owner] = true
		}
	}
	targets = keep
	for t := range tests {
		removed[t] = true
	}
	// 道連れ: 消す def だけが使っていた pub でない def（何度か回して、道連れの道連れも）。
	var along []string
	for changed := true; changed; {
		changed = false
		for _, s := range order {
			d := defs[s]
			if removed[s] || d.Pub || d.Inst || d.Test || len(refs[s]) == 0 {
				continue
			}
			all := true
			for _, r := range refs[s] {
				if !removed[r.Owner] {
					all = false
					break
				}
			}
			if all {
				removed[s] = true
				along = append(along, s)
				changed = true
			}
		}
	}
	for _, c := range targets {
		plan.Targets = append(plan.Targets, Fixed{c.d.Row, c.why})
	}
	for _, s := range along {
		plan.Targets = append(plan.Targets, Fixed{defs[s].Row, "道連れ（消す def だけが使っていた）"})
	}
	for t := range tests {
		plan.Tests = append(plan.Tests, Fixed{defs[t].Row, "消す def だけを試すテスト"})
	}
	sort.Slice(plan.Tests, func(i, j int) bool { return less(plan.Tests[i].Row, plan.Tests[j].Row) })
	for _, group := range [][]Fixed{plan.Targets, plan.Tests} {
		for _, f := range group {
			e, err := deleteEdit(root, defs[f.Sym])
			if err != nil {
				return plan, err
			}
			plan.Edits = append(plan.Edits, e)
		}
	}
	// 転送するだけの包み（本体が別の def を呼ぶだけ）を消す時は、その doc を転送先へ移す（転送先に doc が無いか、
	// 転送先の doc が消える包みの名前を指す時。指さない doc は人が書いた物なので残す）。
	for _, f := range plan.Targets {
		e, ok, err := moveDocEdit(root, defs, usesOf[f.Sym], defs[f.Sym], removed)
		if err != nil {
			return plan, err
		}
		if ok {
			plan.Edits = append(plan.Edits, e)
			plan.Docs = append(plan.Docs, Fixed{e.Site, "doc を " + f.Sym + " から移す"})
		}
	}
	sort.Slice(plan.Fix, func(i, j int) bool { return less(plan.Fix[i].Row, plan.Fix[j].Row) })
	return plan, nil
}

// defTable は索引の def-decl を名前ごとに（order は出てきた順）。ext の読めない def は Ext が空のまま。
func defTable(rows []Row) (map[string]defInfo, []string) {
	defs := map[string]defInfo{}
	var order []string
	for _, r := range rows {
		if r.Kind != KindDefDecl {
			continue
		}
		ext, _ := spanOf(r.File, r.Attr("ext"))
		f := strings.Fields(r.Extra)
		has := func(w string) bool {
			for _, x := range f {
				if x == w {
					return true
				}
			}
			return false
		}
		ann := "," + r.Attr("ann") + ","
		d := defInfo{Row: r, Pub: has("pub"), Inst: has("inst"), Test: strings.Contains(ann, ",test,"), Ext: ext}
		if _, dup := defs[r.Sym]; !dup {
			order = append(order, r.Sym)
		}
		defs[r.Sym] = d
	}
	return defs, order
}

// refsBySym は def の参照を参照される def ごとに（自分の中の参照＝再帰は除く）。
func refsBySym(rows []Row) map[string][]Row {
	refs := map[string][]Row{}
	for _, r := range rows {
		if r.Kind == KindDefUse && r.Owner != r.Sym {
			refs[r.Sym] = append(refs[r.Sym], r)
		}
	}
	return refs
}

var docOrAnn = regexp.MustCompile(`^\s*(///|@[A-Z])`)

// deleteEdit は def を、前の `///` と注記（@Test など）の行ごと、行単位で消す書き換え。
// 前後が空行なら片方の空行も消す（空行が 2 つ並ばないように）。
func deleteEdit(root string, d defInfo) (Edit, error) {
	data, err := os.ReadFile(filepath.Join(root, d.File))
	if err != nil {
		return Edit{}, err
	}
	src := string(data)
	lines := strings.SplitAfter(src, "\n")
	first, last := d.Ext.Line, d.Ext.EndLine // 1 から
	for first > 1 && docOrAnn.MatchString(lines[first-2]) {
		first--
	}
	if strings.TrimSpace(lineAfter(lines[last-1], d.Ext.EndCol)) != "" {
		return Edit{}, fmt.Errorf("%s: def の後ろの同じ行に別の物がある（行ごと消せない）", d.Where())
	}
	// 定義の始まりの行で、始まりより前に字がある（`mod X { pub def …` のような 1 行）なら行ごとは消せない。
	// 見るのは ext の始まりの行だけ（上の `///` や注記の行の字下げは関係ない）。
	startLine := lines[d.Ext.Line-1]
	if prefix := startLine[:byteCol(startLine, d.Ext.Col)]; strings.TrimSpace(prefix) != "" {
		return Edit{}, fmt.Errorf("%s: def の前の同じ行に別の物がある（行ごと消せない）", d.Where())
	}
	blank := func(i int) bool { return i >= 1 && i <= len(lines) && strings.TrimSpace(lines[i-1]) == "" }
	switch {
	case blank(first-1) && blank(last+1):
		last++
	case blank(first-1) && last+1 <= len(lines) && strings.HasPrefix(strings.TrimSpace(lines[last]), "}"):
		first-- // 閉じ括弧の前に空行を残さない
	}
	start := 0
	for i := 0; i < first-1; i++ {
		start += len(lines[i])
	}
	end := start
	for i := first - 1; i < last && i < len(lines); i++ {
		end += len(lines[i])
	}
	name := d.Sym[strings.LastIndex(d.Sym, ".")+1:]
	return Edit{File: d.File, Start: start, End: end, Site: d.Row,
		Check: []Want{{Span: d.Row, Text: name}},
		Make:  func(string) (string, error) { return "", nil }}, nil
}

// moveDocEdit は消す def w が転送するだけの包み（本体がプロジェクトの別の def T の呼び出し 1 つ: `T(…)`。引数の中の
// 呼び出しは問わない）で、w に doc がある時、その doc を T の前へ書く書き換え。T に doc が無ければ足し、T の doc が
// w の名前を指していれば置き換える。それ以外（T も消す・T の doc が w を指さない・包みでない）は ok=false。
func moveDocEdit(root string, defs map[string]defInfo, uses []Row, w defInfo, removed map[string]bool) (Edit, bool, error) {
	data, err := os.ReadFile(filepath.Join(root, w.File))
	if err != nil {
		return Edit{}, false, err
	}
	src := string(data)
	wDoc := docLines(src, w.Line)
	if len(wDoc) == 0 {
		return Edit{}, false, nil
	}
	_, nameEnd, err := ByteRange(src, w.Row)
	if err != nil {
		return Edit{}, false, nil
	}
	open := nameEnd
	if open < len(src) && src[open] == '[' {
		if _, at, err := scanTop(src, open+1, "]"); err == nil {
			open = at + 1
		}
	}
	list, has, err := argsAfter(src, open)
	if err != nil || !has {
		return Edit{}, false, nil
	}
	_, extEnd, err := ByteRange(src, w.Ext)
	if err != nil {
		return Edit{}, false, nil
	}
	body, ok := DefBodyStart(src, list.Close+1)
	if !ok || body > extEnd {
		return Edit{}, false, nil
	}
	var call *Row
	for i := range uses {
		cs, ce, err := ByteRange(src, uses[i])
		if err != nil || cs != skipBlank(src, body) {
			continue
		}
		if l, h, err := argsAfter(src, ce); err != nil || !h || strings.TrimSpace(src[l.Close+1:extEnd]) != "" {
			return Edit{}, false, nil
		}
		call = &uses[i]
	}
	if call == nil || call.Sym == w.Sym || removed[call.Sym] {
		return Edit{}, false, nil
	}
	t, project := defs[call.Sym]
	if !project {
		return Edit{}, false, nil
	}
	tdata, err := os.ReadFile(filepath.Join(root, t.File))
	if err != nil {
		return Edit{}, false, err
	}
	lines := strings.SplitAfter(string(tdata), "\n")
	// T の doc の塊（宣言の上の注記と doc の行のうち、`///` の続く所）。無ければ塊の頭に足す。
	top := t.Line
	for top > 1 && docOrAnn.MatchString(lines[top-2]) {
		top--
	}
	from, to := top-1, top-1 // 行の番号（0 から）[from, to)
	for i := top - 1; i < t.Line-1; i++ {
		if strings.HasPrefix(strings.TrimSpace(lines[i]), "///") {
			if to == from {
				from = i
			}
			to = i + 1
		} else if to > from {
			break
		}
	}
	if to > from {
		mention := regexp.MustCompile(`(^|[^A-Za-z0-9_])` + regexp.QuoteMeta(shortName(w.Sym)) + `([^A-Za-z0-9_]|$)`)
		if !mention.MatchString(strings.Join(lines[from:to], "")) {
			return Edit{}, false, nil
		}
	}
	// T の宣言の行の字下げで書き直す。
	first := lines[t.Line-1]
	indent := first[:len(first)-len(strings.TrimLeft(first, " \t"))]
	var text strings.Builder
	for _, l := range wDoc {
		text.WriteString(indent + strings.TrimLeft(l, " \t"))
	}
	start := 0
	for i := 0; i < from; i++ {
		start += len(lines[i])
	}
	end := start
	for i := from; i < to; i++ {
		end += len(lines[i])
	}
	repl := text.String()
	return Edit{File: t.File, Start: start, End: end, Site: t.Row,
		Make: func(string) (string, error) { return repl, nil }}, true, nil
}

// docLines は line（1 から）の行の上の `///` の行（注記の行は飛ばす。改行を含む）。
func docLines(src string, line int) []string {
	lines := strings.SplitAfter(src, "\n")
	var out []string
	for i := line - 2; i >= 0 && docOrAnn.MatchString(lines[i]); i-- {
		if strings.HasPrefix(strings.TrimSpace(lines[i]), "///") {
			out = append([]string{lines[i]}, out...)
		}
	}
	return out
}

// byteCol は行の中の列（1 から・UTF-16）のバイトの位置。
func byteCol(line string, col int) int {
	n, err := offset([]string{line}, 1, col)
	if err != nil {
		return len(line)
	}
	return n
}

func lineAfter(line string, col int) string { return line[byteCol(line, col):] }

var identPath = regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+`)

// mentionedOutsideFlix は git の知るファイルのうち .flix でない物（1 MB まで）に字で出る `Mod.name` → 最初に出たファイル。
func mentionedOutsideFlix(root, engine string) (map[string]string, error) {
	out := map[string]string{}
	scan(out, root, func(string) bool { return true })
	if engine != "" && engine != root {
		// engine の側は、ゲームの make が読む物だけ（Makefile・mk/）。
		scan(out, engine, func(f string) bool { return f == "Makefile" || strings.HasPrefix(f, "mk/") })
	}
	return out, nil
}

// scan は dir の git の知るファイル（.flix でない・1 MB まで・字の物）に出る `Mod.name` を out に足す。
func scan(out map[string]string, root string, want func(string) bool) {
	cmd := exec.Command("git", "ls-files", "-z")
	cmd.Dir = root
	list, err := cmd.Output()
	if err != nil {
		return // git の外: 字の候補は見ない（呼ぶ側の確かめに任せる）
	}
	for _, f := range strings.Split(string(list), "\x00") {
		if f == "" || strings.HasSuffix(f, ".flix") || !want(f) {
			continue
		}
		info, err := os.Stat(filepath.Join(root, f))
		if err != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, f))
		if err != nil || strings.IndexByte(string(data[:min(len(data), 8000)]), 0) >= 0 {
			continue
		}
		for _, m := range identPath.FindAllString(string(data), -1) {
			if _, seen := out[m]; !seen {
				out[m] = filepath.Join(filepath.Base(root), f)
			}
		}
	}
}

// modOf は def の名前の mod の部分（`World.moveTo` → `World`）。
func modOf(sym string) string {
	if i := strings.LastIndex(sym, "."); i >= 0 {
		return sym[:i]
	}
	return ""
}
