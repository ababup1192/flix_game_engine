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
	// Def は候補をこの def だけに絞る（Mod.name。終わりで当てる。a,b で複数）。
	Def string
	// Library は fpkg で配るライブラリか（pub の def は使う側がこの索引の外にいるので、消さずに fix へ回す）。
	Library bool
	// EntryTables は入口の表の def の短い名前（設定の entryTables。Mentions.withEntryDefs）。
	EntryTables []string
}

// DeadPlan は remove-dead の計画。
type DeadPlan struct {
	Targets []Fixed // 消す def（why は test-only・unreferenced・道連れ）
	Tests   []Fixed // 一緒に消すテスト
	Fix     []Fixed // 消さずに人へ回す物
	Edits   []Edit
	Docs    []Fixed // doc を移す転送先（消す包みの doc を受ける def）
	// DocRefs は消す def を文書が名指す所（file:line と名前。doc-refs の決まりで拾った物。消した後に doc-refs が止める）。
	DocRefs  []Fixed
	Sites    int // 候補の数（--skip・fix を含む）
	TestOnly int // test-only の数（flixlint の test-only-api と同じ決め方。同じ mod の中で使う物も含む）
	// Others・OthersTestOnly は --def の時、名指していない呼び手 0・テストからだけの pub の def の数（触らず、数えて知らせるだけ）。
	Others, OthersTestOnly int
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
// 参照が 0 の物（unreferenced）。自分の中の参照（再帰）は数えない。--def で名指せば候補は名指しの def だけ
// （消すのは名指しと、その道連れだけ。ほかの呼び手 0 の def は Others に数える）。
//   - テストから参照される候補は --with-tests の時だけ消す。参照する def が全部 @Test で、その @Test が src の def を
//     候補（と道連れ）のほかに使わない時だけ、テストごと消す。それ以外は fix。
//   - 消す def だけが使っていた def は道連れで消す（pub でない助けは残すとコンパイラが使われない def で止まる。pub の
//     下請けも、use・入口の名前・ライブラリでなければ一緒に消す）。
//   - 名前が入口（Makefile・json・flow など、文章でない git の知るファイル）に字で出る候補は fix（名前で呼ばれるかもしれない）。
//     文書（doc-refs が見る .md と .flix のコメント）が名指す候補は消し、その所を DocRefs に並べる（mentions.go）。
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
	// 名指し（--def）は索引の名前に 1 つずつ決める（当たらない・2 つ以上に当たる名前は止める）。名指しがある時は、
	// 名指しの def と、それを消して初めて呼び手が 0 になる物（道連れ）だけを消す。ほかの呼び手 0 の def は数えるだけ。
	named, err := resolveDefs(rows, q.Def)
	if err != nil {
		return plan, err
	}
	var cands []cand
	var notCand []Fixed // 名指したが候補にならない def と理由（候補の数には入れない）
	for _, s := range order {
		d := defs[s]
		if d.Inst || d.Test || inDirs(d.File, q.TestDirs) || strings.HasSuffix(s, ".main") || s == "main" {
			if named[s] {
				notCand = append(notCand, Fixed{d.Row, "instance の def・@Test・main・テストのフォルダの def は消さない"})
			}
			continue
		}
		if !d.Pub {
			switch {
			case !named[s]:
			case len(refs[s]) == 0 && q.Only != "test-only":
				cands = append(cands, cand{d, "unreferenced"})
			default:
				notCand = append(notCand, Fixed{d.Row, fmt.Sprintf("pub でない・呼び手 %d（呼び手を消せば道連れで消える。呼び手を --def に）", len(refs[s]))})
			}
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
		if len(named) > 0 && !named[s] {
			switch {
			case len(rs) == 0:
				plan.Others++
			case fromTest > 0 && fromOtherSrc == 0:
				plan.OthersTestOnly++
			}
			continue
		}
		// 名指しの def が候補にならない時は、黙って 0 件にせず理由を fix に並べる（名指しを外して流し直させない）。
		because := func(why string) {
			if named[s] {
				notCand = append(notCand, Fixed{d.Row, why})
			}
		}
		switch {
		case len(rs) == 0 && q.Only != "test-only":
			cands = append(cands, cand{d, "unreferenced"})
		case len(rs) == 0:
			because("参照 0（--only test-only に当たらない）")
		case fromOtherSrc > 0:
			because(fmt.Sprintf("ほかの mod の src から %d か所呼ばれる（消せない）", fromOtherSrc))
		case fromTest == 0:
			because(fmt.Sprintf("同じ mod の中で %d か所使う（消せない。pub を外すのは make-private）", fromOwnMod))
		case q.Only == "unreferenced":
			because("テストからだけ（--only unreferenced に当たらない）")
		default:
			// test-only は flixlint の規則 test-only-api と同じ決め方（テストから呼ばれ、ほかの mod の src からは呼ばれない）。
			// 同じ mod の中で使われる物は消せない（pub を外すかは人が決める）ので fix。
			plan.TestOnly++
			if fromOwnMod > 0 {
				plan.Fix = append(plan.Fix, Fixed{d.Row, fmt.Sprintf("test-only・同じ mod の中で %d か所使う（消せない。pub を外すかテストを直すのは人）", fromOwnMod)})
				continue
			}
			cands = append(cands, cand{d, "test-only"})
		}
	}
	plan.Sites = len(cands) + len(plan.Fix)
	plan.Fix = append(plan.Fix, notCand...)
	mentions := loadMentions(root, q.Engine).withEntryDefs(rows, q.EntryTables)
	removed := map[string]bool{}
	var targets []cand
	for _, c := range cands {
		switch {
		case q.Skip[c.d.File+":"+fmt.Sprint(c.d.Line)]:
			plan.Fix = append(plan.Fix, Fixed{c.d.Row, "--skip で外した"})
		case q.Library:
			plan.Fix = append(plan.Fix, Fixed{c.d.Row, c.why + "・ライブラリ（fpkg で配る）の pub は使う側が索引の外にいる（使う側を確かめて手で消す）"})
		case mentions.Entry[c.d.Sym] != "":
			plan.Fix = append(plan.Fix, Fixed{c.d.Row, c.why + "・名前が入口のファイル " + mentions.Entry[c.d.Sym] + " に字で出る（名前で呼ばれるかもしれない。確かめて手で消す）"})
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
	// 道連れ: 消す def だけが使っていた def（何度か回して、道連れの道連れも）。呼び手が 1 つ以上あって全部消える物だけ
	// なので、もとから呼び手 0 の def は入らない。pub の物は、use で名前を入れる所・入口のファイルの名前・ライブラリ・
	// --skip の物を残す（候補と同じ決まり）。
	// WhyNot: pub を道連れにしないと、名指しで消した後に残る下請けを消すために名指し無しで流し直し、名指していない
	// 呼び手 0 の pub（依頼主の判断待ちで残している物）まで消す差分になる。
	imported := map[string]bool{}
	for _, r := range rows {
		if r.Kind == KindUse && r.Attr("what") == "def" {
			imported[r.Sym] = true
		}
	}
	var along []string
	for changed := true; changed; {
		changed = false
		for _, s := range order {
			d := defs[s]
			if removed[s] || d.Inst || d.Test || len(refs[s]) == 0 || inDirs(d.File, q.TestDirs) || strings.HasSuffix(s, ".main") {
				continue
			}
			if d.Pub && (imported[s] || q.Library || mentions.Entry[s] != "" || q.Skip[d.File+":"+fmt.Sprint(d.Line)]) {
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
		why := "道連れ（消す def だけが使っていた）"
		if defs[s].Pub {
			why = "道連れ（消す def だけが呼んでいた pub）"
		}
		plan.Targets = append(plan.Targets, Fixed{defs[s].Row, why})
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
	plan.Edits = mergeDeletes(plan.Edits)
	// 転送するだけの包み（本体が別の def を呼ぶだけ）を消す時は、その doc を転送先へ移す（転送先に doc が無いか、
	// 転送先の doc が消える包みの名前を指す時。指さない doc は人が書いた物なので残す）。同じ転送先へ移す包みが
	// 2 つ以上なら、書き換えを 1 つにまとめて doc を並べる（転送先の doc の同じ所を 2 回書き換えない）。
	byTarget := map[string][]wrapDoc{}
	var targetOrder []string
	for _, f := range plan.Targets {
		t, doc, ok, err := forwardTarget(root, defs, usesOf[f.Sym], defs[f.Sym], removed)
		if err != nil {
			return plan, err
		}
		if !ok {
			continue
		}
		if _, seen := byTarget[t]; !seen {
			targetOrder = append(targetOrder, t)
		}
		byTarget[t] = append(byTarget[t], wrapDoc{f.Sym, doc})
	}
	for _, t := range targetOrder {
		e, ok, err := moveDocEdit(root, defs[t], byTarget[t])
		if err != nil {
			return plan, err
		}
		if ok {
			var from []string
			for _, w := range byTarget[t] {
				from = append(from, w.sym)
			}
			plan.Edits = append(plan.Edits, e)
			plan.Docs = append(plan.Docs, Fixed{e.Site, "doc を " + strings.Join(from, "・") + " から移す"})
		}
	}
	// 文書の名指し: 一緒に消える宣言（doc と注記の行も）の中のコメントは数えない。
	gone := map[string][][2]int{}
	for _, group := range [][]Fixed{plan.Targets, plan.Tests} {
		for _, f := range group {
			top, end := declLineRange(root, defs[f.Sym])
			gone[defs[f.Sym].File] = append(gone[defs[f.Sym].File], [2]int{top, end})
		}
	}
	inGone := func(file string, line int) bool {
		for _, r := range gone[file] {
			if line >= r[0] && line <= r[1] {
				return true
			}
		}
		return false
	}
	for _, group := range [][]Fixed{plan.Targets, plan.Tests} {
		for _, f := range group {
			for _, at := range mentions.DocsNaming(f.Sym, inGone) {
				plan.DocRefs = append(plan.DocRefs, Fixed{f.Row, at})
			}
		}
	}
	sort.Slice(plan.Fix, func(i, j int) bool { return less(plan.Fix[i].Row, plan.Fix[j].Row) })
	return plan, nil
}

// declLineRange は宣言の行の範囲（上の `///` と注記の行から ext の終わりまで・1 から）。読めなければ ext の範囲。
func declLineRange(root string, d defInfo) (int, int) {
	top, end := d.Ext.Line, d.Ext.EndLine
	data, err := os.ReadFile(filepath.Join(root, d.File))
	if err != nil {
		return top, end
	}
	lines := strings.SplitAfter(string(data), "\n")
	for top > 1 && top-2 < len(lines) && docOrAnn.MatchString(lines[top-2]) {
		top--
	}
	return top, end
}

// resolveDefs は --def（Mod.f。a,b で複数）を索引の def の名前の組に決める。空なら空の組（名指し無し）。
// 当たらない・2 つ以上に当たる名前は誤り（終わりで当てて黙って広がらないように）。
func resolveDefs(rows []Row, want string) (map[string]bool, error) {
	named := map[string]bool{}
	for _, w := range strings.Split(want, ",") {
		if w = strings.TrimSpace(w); w == "" {
			continue
		}
		s, err := Resolve(rows, w, map[string]bool{KindDefDecl: true})
		if err != nil {
			return nil, err
		}
		named[s] = true
	}
	if len(named) == 0 && strings.TrimSpace(want) != "" {
		return nil, fmt.Errorf("--def %q に名前がありません（Mod.name を a,b で）", want)
	}
	return named, nil
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
	cut, _, err := declLines(string(data), d.Ext, d.Row)
	if err != nil {
		return Edit{}, err
	}
	name := d.Sym[strings.LastIndex(d.Sym, ".")+1:]
	return Edit{File: d.File, Start: cut[0], End: cut[1], Site: d.Row,
		Check: []Want{{Span: d.Row, Text: name}},
		Make:  func(string) (string, error) { return "", nil }}, nil
}

// mergeDeletes は同じファイルの中で交わる消す書き換えを 1 つにまとめる（並んだ 2 つの def を消す時、間の空行を
// 両方が自分の空行の始末に取ると、片方がもう片方を含まない重なりになって Plan が断る）。交わらない物はそのまま。
func mergeDeletes(edits []Edit) []Edit {
	sorted := append([]Edit(nil), edits...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if sorted[i].File != sorted[j].File {
			return sorted[i].File < sorted[j].File
		}
		return sorted[i].Start < sorted[j].Start
	})
	var out []Edit
	for _, e := range sorted {
		if n := len(out); n > 0 && out[n-1].File == e.File && e.Start < out[n-1].End {
			last := &out[n-1]
			last.End = max(last.End, e.End)
			last.Check = append(append([]Want(nil), last.Check...), e.Check...)
			continue
		}
		out = append(out, e)
	}
	return out
}

// isCommentOrBlank は行が空か、行のコメントだけ（`//`・`///`）か。
func isCommentOrBlank(line string) bool {
	t := strings.TrimSpace(line)
	return t == "" || strings.HasPrefix(t, "//")
}

// declLines は宣言（範囲 ext・名前の行 row）を、前の `///` と注記（@Test など）の行ごと行単位で切り出す所。
// text は宣言そのものの行（doc・注記・本体）、cut はそれに空行の始末を足した消す所（前後が空行なら片方の空行も・
// 閉じ括弧の前に空行を残さない）。どちらもバイトの [始まり, 終わり)。
func declLines(src string, ext, row Row) (cut, text [2]int, err error) {
	lines := strings.SplitAfter(src, "\n")
	first, last := ext.Line, ext.EndLine // 1 から
	if first < 1 || last > len(lines) || first > last {
		return cut, text, fmt.Errorf("%s: 宣言の範囲が中身の外（索引が古い。bin/fge refactor index --rebuild）", row.Where())
	}
	for first > 1 && docOrAnn.MatchString(lines[first-2]) {
		first--
	}
	// コンパイラの範囲は、宣言の後ろに続く行のコメント（次の節の見出し `// ── … ──` など）と空行まで含む事がある
	// （ゲームの Broadcast.scaled の ext が次の節の見出しの行で終わっていた）。宣言の物でないので外す。
	trimmed := false
	for last > row.Line && isCommentOrBlank(lines[last-1]) {
		last--
		trimmed = true
	}
	if !trimmed && strings.TrimSpace(lineAfter(lines[last-1], ext.EndCol)) != "" {
		return cut, text, fmt.Errorf("%s: 宣言の後ろの同じ行に別の物がある（行ごと切り出せない）", row.Where())
	}
	// 定義の始まりの行で、始まりより前に字がある（`mod X { pub def …` のような 1 行）なら行ごとは切り出せない。
	// 見るのは ext の始まりの行だけ（上の `///` や注記の行の字下げは関係ない）。
	startLine := lines[ext.Line-1]
	if prefix := startLine[:byteCol(startLine, ext.Col)]; strings.TrimSpace(prefix) != "" {
		return cut, text, fmt.Errorf("%s: 宣言の前の同じ行に別の物がある（行ごと切り出せない）", row.Where())
	}
	offsetOf := func(line int) int { // line（1 から）の行の頭
		n := 0
		for i := 0; i < line-1 && i < len(lines); i++ {
			n += len(lines[i])
		}
		return n
	}
	text = [2]int{offsetOf(first), offsetOf(last + 1)}
	blank := func(i int) bool { return i >= 1 && i <= len(lines) && strings.TrimSpace(lines[i-1]) == "" }
	switch {
	case blank(first-1) && blank(last+1):
		last++
	case blank(first-1) && last+1 <= len(lines) && strings.HasPrefix(strings.TrimSpace(lines[last]), "}"):
		first-- // 閉じ括弧の前に空行を残さない
	}
	cut = [2]int{offsetOf(first), offsetOf(last + 1)}
	return cut, text, nil
}

// wrapDoc は転送するだけの包み 1 つ（名前と、その上の `///` の行）。
type wrapDoc struct {
	sym string
	doc []string
}

// forwardTarget は消す def w が転送するだけの包み（本体がプロジェクトの別の def T の呼び出し 1 つ: `T(…)`。引数の中の
// 呼び出しは問わない）で、w に doc がある時、T の名前と w の doc の行。T も消す・包みでない・doc が無い時は ok=false。
func forwardTarget(root string, defs map[string]defInfo, uses []Row, w defInfo, removed map[string]bool) (string, []string, bool, error) {
	data, err := os.ReadFile(filepath.Join(root, w.File))
	if err != nil {
		return "", nil, false, err
	}
	src := string(data)
	wDoc := docLines(src, w.Line)
	if len(wDoc) == 0 {
		return "", nil, false, nil
	}
	_, nameEnd, err := ByteRange(src, w.Row)
	if err != nil {
		return "", nil, false, nil
	}
	open := nameEnd
	if open < len(src) && src[open] == '[' {
		if _, at, err := scanTop(src, open+1, "]"); err == nil {
			open = at + 1
		}
	}
	list, has, err := argsAfter(src, open)
	if err != nil || !has {
		return "", nil, false, nil
	}
	_, extEnd, err := ByteRange(src, w.Ext)
	if err != nil {
		return "", nil, false, nil
	}
	body, ok := DefBodyStart(src, list.Close+1)
	if !ok || body > extEnd {
		return "", nil, false, nil
	}
	var call *Row
	for i := range uses {
		cs, ce, err := ByteRange(src, uses[i])
		if err != nil || cs != skipBlank(src, body) {
			continue
		}
		if l, h, err := argsAfter(src, ce); err != nil || !h || strings.TrimSpace(src[l.Close+1:extEnd]) != "" {
			return "", nil, false, nil
		}
		call = &uses[i]
	}
	if call == nil || call.Sym == w.Sym || removed[call.Sym] {
		return "", nil, false, nil
	}
	if _, project := defs[call.Sym]; !project {
		return "", nil, false, nil
	}
	return call.Sym, wDoc, true, nil
}

// moveDocEdit は包み ws の doc を転送先 t の前へ書く書き換え（包みが 2 つ以上なら doc を並べ、中身の同じ doc は
// 1 度だけ）。t に doc が無ければ足し、t の doc が包みのどれかの名前を指していれば置き換える。t の doc がどの包みも
// 指さない（人が書いた doc）なら ok=false。
func moveDocEdit(root string, t defInfo, ws []wrapDoc) (Edit, bool, error) {
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
		tDoc := strings.Join(lines[from:to], "")
		named := false
		for _, w := range ws {
			mention := regexp.MustCompile(`(^|[^A-Za-z0-9_])` + regexp.QuoteMeta(shortName(w.sym)) + `([^A-Za-z0-9_]|$)`)
			named = named || mention.MatchString(tDoc)
		}
		if !named {
			return Edit{}, false, nil
		}
	}
	// T の宣言の行の字下げで書き直す。
	first := lines[t.Line-1]
	indent := first[:len(first)-len(strings.TrimLeft(first, " \t"))]
	var text strings.Builder
	written := map[string]bool{}
	for _, w := range ws {
		var doc strings.Builder
		for _, l := range w.doc {
			doc.WriteString(indent + strings.TrimLeft(l, " \t"))
		}
		if !written[doc.String()] {
			written[doc.String()] = true
			text.WriteString(doc.String())
		}
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

// jsonName は JSON の字のうち、まるごと Mod.name の物（"entry": "E2e.play"）。
// WhyNot: JSON の中の文（note・reason・お題の文）に出る名前は数えない。名前で呼ぶ設定は値そのものが名前で、文の中の
// 名前は人への説明（ゲームの lint/limits/*.json の note が def の名前を挙げていて、消せる def が人へ回っていた）。
var jsonName = regexp.MustCompile(`"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)"`)

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
		found := identPath.FindAllString(string(data), -1)
		if strings.HasSuffix(f, ".json") {
			found = nil
			for _, m := range jsonName.FindAllStringSubmatch(string(data), -1) {
				found = append(found, m[1])
			}
		}
		for _, m := range found {
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
