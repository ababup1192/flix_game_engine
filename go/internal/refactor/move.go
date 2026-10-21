package refactor

import (
	"fmt"
	"path"
	"regexp"
	"sort"
	"strings"
	"unicode/utf16"
)

// move（IDE の Move）: def と型 alias を別の mod へ移し、呼ぶ所の修飾名と use を直す。
//
//	bin/fge refactor move --def Mod.f[,Mod.T] --to Mod2 [--with Mod.h] [--apply]
//
// 移す物: 宣言（前の `///` と注記の行ごと）を元のファイルから切り、移し先の mod の終わりへ書く（移し先の mod が
// どのファイルにも無ければ src/<Mod2 の . を / に>.flix を作る）。移し先に同じ名前があれば止める。
// 本体の中の名前（索引の def-use・type-use・case の行で owner が移す物）は、移した後も同じ物を指すように書き直す:
//   - 元の mod の中の物を素の名前で書いた所は `Mod.x` に（移す物どうしは素の名前のまま・修飾は外す）。
//   - 元の mod の use で入れた名前は、その use を移し先の mod へ写す（元の mod でもう誰も使わなければ元の use は消す）。
//
// 呼ぶ所（索引の def-use・type-use・use の行で sym が移す物）:
//   - 修飾名 `Mod.f`（use の別名の mod で書いた物も）は `Mod2.f` に。移し先の mod の中では素の `f` に。
//   - 元の mod の中の素の `f` は `Mod2.f` に（元の側の呼び出しを修飾つきに）。
//   - `use Mod.f` は `use Mod2.f` に、`use Mod.{f, g}` は f を外して `use Mod2.{f}` を足す（足す所の並べ方は
//     change-signature の use と同じ部品 insertUses）。別名 `use Mod.{f => g}` も字のまま移す。移し先の mod の中の use は消す。
//
// 人へ回す所（fix。1 つでもあれば書かない）: 移す物が元の mod の非 pub の物を使う（--with で一緒に移すか pub にするかは人）・
// 移す非 pub の物を移す物の外が使う・--def の非 pub の物を元の mod の中だけで使う（移す意味が無い）・読めない use の形。
// .flix の外（Makefile など）に字で出る名前は注に並べる（書き換えない）。

// MoveQuery は move の問い。
type MoveQuery struct {
	Defs []string          // --def の sym（解決済み）
	With []string          // --with の sym（一緒に移す。元の mod の中だけで使う物）
	To   string            // 移し先の mod
	All  map[string]string // 索引に入れたフォルダの .flix（根からの相対 → 中身。移し先の mod を探す）
	Dir  string            // 移し先の mod が無い時に作るファイルのフォルダ（既定 src）
}

// MovePlan は move の計画。
type MovePlan struct {
	Edits       []Edit
	Fix         []Fixed
	Moved       []Fixed // 移す宣言
	Sites       []Fixed // 書き換える呼ぶ所と use
	Calls       int     // 書き換える呼ぶ所（修飾名と素の名前）
	Uses        int     // 書き換える use
	Inner       int     // 移す本体の中で書き直した名前（修飾を足した・外した）
	CallFiles   map[string]int
	Target      string // 移し先のファイル
	Created     bool   // 移し先のファイルを作る
	UsesAdded   []string
	UsesDropped []string // 元の mod で使わなくなって消す use
	Deps        []string // 移す物が使う元の mod の非 pub の物（--with の候補）
	PubNeeded   []string // 移すと外から使えなくなる非 pub の物（pub にするかは人）
	Olds        []string // 元の名前（Mod.f）
}

type moveItem struct {
	sym, kind string // kind は def か alias
	from      string // 元の mod
	row       Row
	pub, with bool
	cut, text [2]int
}

var moveRefKinds = map[string]bool{KindDefUse: true, KindTypeUse: true, KindCaseConstruct: true, KindCasePattern: true}

// PlanMove は q の物を q.To へ移す計画。
func PlanMove(rows []Row, srcs *reshapeSources, q MoveQuery) (MovePlan, error) {
	p := MovePlan{CallFiles: map[string]int{}}
	ix := newSigIndex(rows)
	defs, _ := defTable(rows)
	decls := map[string]Row{} // alias・enum の宣言
	for _, r := range rows {
		if r.Kind == KindAliasDecl || r.Kind == KindEnumDecl {
			decls[r.Sym] = r
		}
	}
	// ── 移す物 ──
	moved := map[string]*moveItem{}
	var items []*moveItem
	shorts := map[string]string{}
	add := func(sym string, with bool) error {
		if _, dup := moved[sym]; dup {
			return nil
		}
		it := &moveItem{sym: sym, from: modOf(sym), with: with}
		var ext Row
		if d, ok := defs[sym]; ok {
			if d.Inst {
				return fmt.Errorf("%s は instance の def（移せない）", sym)
			}
			if d.Ext.Line == 0 {
				return fmt.Errorf("%s: 索引に宣言の範囲（ext）が無い", d.Where())
			}
			it.kind, it.row, it.pub, ext = "def", d.Row, d.Pub, d.Ext
		} else if a, ok := decls[sym]; ok && a.Kind == KindAliasDecl {
			src, err := srcs.get(a.File)
			if err != nil {
				return err
			}
			if ext, err = aliasExt(src, a); err != nil {
				return err
			}
			it.kind, it.row, it.pub = "alias", a, declIsPub(src, a)
		} else {
			return fmt.Errorf("%s は def か型 alias でない（enum は移せない）", sym)
		}
		if it.from == q.To {
			return fmt.Errorf("%s はもう %s にある", sym, q.To)
		}
		short := shortName(sym)
		if o, ok := shorts[short]; ok {
			return fmt.Errorf("移す物に同じ名前が 2 つ: %s と %s（移し先で同じ名前になる）", o, sym)
		}
		shorts[short] = sym
		clash := q.To + "." + short
		if d, ok := defs[clash]; ok {
			return fmt.Errorf("移し先に同じ名前がある: %s（%s）", clash, d.Where())
		}
		if d, ok := decls[clash]; ok {
			return fmt.Errorf("移し先に同じ名前がある: %s（%s）", clash, d.Where())
		}
		src, err := srcs.get(it.row.File)
		if err != nil {
			return err
		}
		if it.cut, it.text, err = declLines(src, ext, it.row); err != nil {
			return err
		}
		moved[sym] = it
		items = append(items, it)
		return nil
	}
	for _, s := range q.Defs {
		if err := add(s, false); err != nil {
			return p, err
		}
	}
	for _, s := range q.With {
		if err := add(s, true); err != nil {
			return p, err
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return less(items[i].row, items[j].row) })
	for _, it := range items {
		p.Olds = append(p.Olds, it.sym)
	}
	text := func(r Row) (string, error) {
		src, err := srcs.get(r.File)
		if err != nil {
			return "", err
		}
		s, e, err := ByteRange(src, r)
		if err != nil {
			return "", fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", r.Where())
		}
		return src[s:e], nil
	}
	pubOf := func(sym string) (bool, bool) { // (pub か, 元の mod で宣言された物か)
		if d, ok := defs[sym]; ok {
			return d.Pub, true
		}
		if d, ok := decls[sym]; ok {
			src, err := srcs.get(d.File)
			return err == nil && declIsPub(src, d), true
		}
		return true, false
	}
	// ── 非 pub の物の行き先（4 と 3 の後半）──
	for _, it := range items {
		if it.pub {
			continue
		}
		var outside []string
		inside := 0
		for _, r := range rows {
			if r.Sym != it.sym || r.Owner == it.sym || !(moveRefKinds[r.Kind] || r.Kind == KindUse) {
				continue
			}
			if _, in := moved[r.Owner]; in {
				inside++
			} else if indexOf(outside, r.Owner) < 0 {
				outside = append(outside, r.Owner)
			}
		}
		if len(outside) > 0 {
			p.PubNeeded = append(p.PubNeeded, it.sym)
		}
		switch {
		case len(outside) > 0 && !it.with:
			p.Fix = append(p.Fix, Fixed{it.row, fmt.Sprintf("非 pub の %s は元の mod の中だけで使う物（%s）で、移す意味が無い。使う def と一緒に移すか、pub にしてから移す", it.sym, strings.Join(outside, "・"))})
		case len(outside) > 0:
			p.Fix = append(p.Fix, Fixed{it.row, fmt.Sprintf("--with の非 pub の %s を移す物の外（%s）も使う。pub にしてから移すか、使う def も一緒に移す", it.sym, strings.Join(outside, "・"))})
		case inside == 0 && !it.with:
			p.Fix = append(p.Fix, Fixed{it.row, fmt.Sprintf("非 pub の %s はどこからも使わない（移す意味が無い。消すなら bin/fge refactor remove-dead）", it.sym)})
		}
	}
	// ── 移す本体の中の名前 ──
	inner := map[string][]Edit{} // 移す物 → 本体の中の書き換え（ファイルの位置）
	targetUses := map[useWant]bool{}
	var targetUseOrder []useWant
	usedByMoved := map[string]bool{} // 元の mod の use の行（file:line:col）のうち、移す本体が使う物
	for _, r := range rows {
		it, in := moved[r.Owner]
		if !in || !moveRefKinds[r.Kind] {
			continue
		}
		w, err := text(r)
		if err != nil {
			return p, err
		}
		if isSugar(r) {
			// use の別名で呼ぶ所（`use M.{f => g}` の g）: 名前の字は use が持つので use を写す。構文が指す物（`a :: b`）は何もしない。
			if u, ok := useFor(ix, r.File, it.from, w); ok && r.Kind == KindDefUse {
				if err := wantUse(srcs, u, targetUses, &targetUseOrder, usedByMoved); err != nil {
					p.Fix = append(p.Fix, Fixed{r, err.Error()})
				}
			}
			continue
		}
		edit := func(repl string) error {
			e, err := replaceEdit(srcs, r, w, repl)
			if err == nil {
				inner[it.sym] = append(inner[it.sym], e)
				p.Inner++
			}
			return err
		}
		vis := r.Sym
		if r.Kind == KindCaseConstruct || r.Kind == KindCasePattern {
			vis = modOf(r.Sym) // case は enum の pub で見る
		}
		if _, also := moved[r.Sym]; also {
			if short := shortName(r.Sym); w != short {
				if err := edit(short); err != nil {
					return p, err
				}
			}
			continue
		}
		if pub, here := pubOf(vis); here && !pub && modOf(vis) == it.from {
			if _, also := moved[vis]; !also {
				p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("元の mod の非 pub の %s を使う。--with %s で一緒に移すか、%s を pub にする", vis, vis, vis)})
				if indexOf(p.Deps, vis) < 0 {
					p.Deps = append(p.Deps, vis)
				}
				continue
			}
		}
		head, _, _ := strings.Cut(w, ".")
		if u, ok := useFor(ix, r.File, it.from, head); ok {
			switch {
			case u.Sym == q.To && w != head:
				// 移し先の mod そのものを use で入れて書いていた（`G.origin`）: 移した後は同じ mod の中なので素の名前に
				usedByMoved[u.Where()] = true
				if err := edit(strings.TrimPrefix(w, head+".")); err != nil {
					return p, err
				}
			case modOf(u.Sym) == q.To:
				usedByMoved[u.Where()] = true // 移し先の物は移し先の中では素の名前で引ける
			default:
				if err := wantUse(srcs, u, targetUses, &targetUseOrder, usedByMoved); err != nil {
					p.Fix = append(p.Fix, Fixed{r, err.Error()})
				}
			}
			continue
		}
		switch {
		case r.Sym == it.from+"."+w:
			// 元の mod の中の物を素の名前（か mod の中の相対の名前）で書いていた: 移し先からは修飾名で引く
			if err := edit(it.from + "." + w); err != nil {
				return p, err
			}
		case strings.HasPrefix(r.Sym, q.To+".") && w == r.Sym:
			// 移し先の物を修飾名で書いていた: 移した後は同じ mod の中
			if err := edit(r.Sym[len(q.To)+1:]); err != nil {
				return p, err
			}
		}
	}
	// ── 呼ぶ所 ──
	var edits []Edit
	type stmtKey struct {
		file  string
		start int
	}
	type stmtDrop struct {
		st    useStmt
		drop  map[int]bool
		site  Row
		owner string
	}
	drops := map[stmtKey]*stmtDrop{}
	var dropOrder []stmtKey
	dropItem := func(r Row, mod string) (useStmt, int, error) {
		src, err := srcs.get(r.File)
		if err != nil {
			return useStmt{}, -1, err
		}
		st, k, ok := useStmtAt(src, mod, r)
		if !ok {
			return st, -1, fmt.Errorf("use の文が読めない")
		}
		key := stmtKey{r.File, st.start}
		d, seen := drops[key]
		if !seen {
			d = &stmtDrop{st: st, drop: map[int]bool{}, site: r, owner: mod}
			drops[key] = d
			dropOrder = append(dropOrder, key)
		}
		d.drop[k] = true
		return st, k, nil
	}
	callerWants := map[[2]string][]useWant{} // (file, mod) → 足す use
	var callerOrder [][2]string
	for _, r := range rows {
		it, isMoved := moved[r.Sym]
		if !isMoved {
			continue
		}
		if _, in := moved[r.Owner]; in {
			continue
		}
		short := shortName(r.Sym)
		switch {
		case r.Kind == KindUse:
			mod := r.Owner
			src, err := srcs.get(r.File)
			if err != nil {
				return p, err
			}
			st, k, ok := useStmtAt(src, mod, r)
			w, err := text(r)
			if err != nil {
				return p, err
			}
			switch {
			case !ok:
				p.Fix = append(p.Fix, Fixed{r, "use の文が読めない（手で）"})
				continue
			case !st.braces && mod == q.To:
				if _, _, err := dropItem(r, mod); err != nil {
					return p, err
				}
			case !st.braces:
				if !strings.HasPrefix(w, it.from+".") {
					p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("use の書き方 `%s` が元の mod の名前で始まらない（手で）", w)})
					continue
				}
				e, err := replaceEdit(srcs, r, w, q.To+w[len(it.from):])
				if err != nil {
					return p, err
				}
				edits = append(edits, e)
			case st.parent != it.from+".":
				p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("use の親の書き方 `%s` が元の mod `%s.` でない（手で）", st.parent, it.from)})
				continue
			default:
				if _, _, err := dropItem(r, mod); err != nil {
					return p, err
				}
				if mod != q.To {
					key := [2]string{r.File, mod}
					if _, seen := callerWants[key]; !seen {
						callerOrder = append(callerOrder, key)
					}
					callerWants[key] = append(callerWants[key], useWant{st.itemsText[k], q.To + "."})
				}
			}
			p.Uses++
			p.Sites = append(p.Sites, Fixed{r, "use"})
		case r.Kind == KindDefUse || r.Kind == KindTypeUse:
			if isSugar(r) {
				continue // use の別名で書いた所（名前の字は use が持つ）・構文が指す物
			}
			w, err := text(r)
			if err != nil {
				return p, err
			}
			mod := modOf(r.Owner)
			var repl string
			switch {
			case strings.Contains(w, ".") && mod == q.To:
				repl = short
			case strings.Contains(w, "."):
				repl = q.To + "." + short
			default:
				if u, ok := useFor(ix, r.File, mod, w); ok && u.Sym == r.Sym {
					continue // use が入れた名前（use の方を直す）
				}
				if mod != it.from {
					p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("素の名前 `%s` がどこから引かれたか分からない（手で）", w)})
					continue
				}
				repl = q.To + "." + short
			}
			e, err := replaceEdit(srcs, r, w, repl)
			if err != nil {
				return p, err
			}
			edits = append(edits, e)
			p.Calls++
			p.CallFiles[r.File]++
			p.Sites = append(p.Sites, Fixed{r, "呼ぶ所"})
		}
	}
	// ── 元の mod の use のうち、移す本体だけが使っていた物を消す ──
	for _, r := range rows {
		if r.Kind != KindUse || !usedByMoved[r.Where()] {
			continue
		}
		if w := r.Attr("what"); w != "def" && w != "alias" && w != "enum" {
			continue // mod・効果・trait の use は使う所が索引に無い物もあるので残す（残っても誤りにならない）
		}
		alias := r.Attr("alias")
		still := false
		for _, o := range rows {
			if o.File != r.File || !moveRefKinds[o.Kind] {
				continue
			}
			if _, in := moved[o.Owner]; in || modOf(o.Owner) != r.Owner {
				continue
			}
			w, err := text(o)
			if err != nil {
				return p, err
			}
			if head, _, _ := strings.Cut(w, "."); head == alias {
				still = true
				break
			}
		}
		if still {
			continue
		}
		if _, _, err := dropItem(r, r.Owner); err != nil {
			return p, err
		}
		w, _ := text(r)
		p.UsesDropped = append(p.UsesDropped, w+"（"+r.File+"）")
	}
	gone := map[string]map[int]bool{}
	target, created := moveTarget(rows, q)
	for _, key := range dropOrder {
		d := drops[key]
		src, _ := srcs.get(key.file)
		inserting := len(callerWants[[2]string{key.file, d.owner}]) > 0 || (key.file == target && d.owner == q.To && len(targetUseOrder) > 0)
		ed, all := dropEdit(src, key.file, d.st, d.drop, d.site, !inserting)
		edits = append(edits, ed)
		if all {
			if gone[key.file] == nil {
				gone[key.file] = map[int]bool{}
			}
			gone[key.file][d.st.start] = true
		}
	}
	for _, key := range callerOrder {
		src, _ := srcs.get(key[0])
		ue, notes := insertUses(srcs, key[0], key[1], len(src), callerWants[key], Row{File: key[0], Line: 1, Col: 1}, gone[key[0]])
		edits = append(edits, ue...)
		for _, n := range notes {
			p.UsesAdded = append(p.UsesAdded, n+" → "+key[0])
		}
	}
	// ── 宣言を切って移し先へ ──
	var cuts []Edit
	var bodies []string
	for _, it := range items {
		src, _ := srcs.get(it.row.File)
		body, err := ApplyEdits(src[it.text[0]:it.text[1]], shiftEdits(inner[it.sym], it.row.File, it.text[0], it.text[1]))
		if err != nil {
			return p, err
		}
		bodies = append(bodies, body)
		cuts = append(cuts, Edit{File: it.row.File, Start: it.cut[0], End: it.cut[1], Site: it.row,
			Check: []Want{{Span: it.row, Text: shortName(it.sym)}}, Make: func(string) (string, error) { return "", nil }})
		p.Moved = append(p.Moved, Fixed{it.row, it.kind})
	}
	edits = append(edits, mergeCuts(cuts)...)
	file := target
	p.Target, p.Created = file, created
	var wants []useWant
	for _, w := range targetUseOrder {
		wants = append(wants, w)
	}
	imports := copiedImports(srcs, items, bodies)
	if created {
		edits = append(edits, Edit{File: file, Create: true, Site: Row{File: file, Line: 1, Col: 1},
			Make: func(string) (string, error) { return newModText(q.To, wants, imports, items, bodies, srcs), nil }})
		for _, w := range wants {
			p.UsesAdded = append(p.UsesAdded, w.name+"（"+w.parent+"） → "+file)
		}
	} else {
		src, err := srcs.get(file)
		if err != nil {
			return p, err
		}
		blk, ok := modBlock(src, q.To)
		if !ok {
			return p, fmt.Errorf("%s の mod %s の括弧が読めない（`mod %s {` の行と、閉じる `}` だけの行が要る）", file, q.To, shortName(q.To))
		}
		indent := blk.indent + "    "
		var b strings.Builder
		if prev := strings.TrimSpace(src[lineStart(src, max(blk.closeLine-1, 0)):blk.closeLine]); blk.closeLine > blk.openEnd && prev != "" {
			b.WriteString("\n")
		}
		for i, it := range items {
			if i > 0 {
				b.WriteString("\n")
			}
			b.WriteString(reindent(bodies[i], lineIndent(src0(srcs, it.row.File), it.text[0]), indent))
		}
		at, text := blk.closeLine, b.String()
		edits = append(edits, Edit{File: file, Start: at, End: at, Site: Row{File: file, Line: 1, Col: 1}, Make: func(string) (string, error) { return text, nil }})
		ue, notes := insertUses(srcs, file, q.To, blk.closeLine, wants, Row{File: file, Line: 1, Col: 1}, gone[file])
		edits = append(edits, ue...)
		for _, n := range notes {
			p.UsesAdded = append(p.UsesAdded, n+" → "+file)
		}
		var missing []string
		for _, im := range imports {
			if !strings.Contains(src[blk.openEnd:blk.closeLine], strings.TrimSpace(im)) {
				missing = append(missing, indent+strings.TrimSpace(im)+"\n")
			}
		}
		if len(missing) > 0 {
			imp := strings.Join(missing, "")
			edits = append(edits, Edit{File: file, Start: blk.openEnd, End: blk.openEnd, Site: Row{File: file, Line: 1, Col: 1}, Make: func(string) (string, error) { return imp, nil }})
		}
	}
	p.Edits = edits
	p.Fix = sortedFixed(p.Fix)
	return p, nil
}

func src0(srcs *reshapeSources, f string) string {
	s, _ := srcs.get(f)
	return s
}

// replaceEdit は索引の範囲 r の字 w を repl に替える書き換え（当てる前に字が w かを確かめる）。
func replaceEdit(srcs *reshapeSources, r Row, w, repl string) (Edit, error) {
	src, err := srcs.get(r.File)
	if err != nil {
		return Edit{}, err
	}
	s, e, err := ByteRange(src, r)
	if err != nil {
		return Edit{}, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", r.Where())
	}
	return Edit{File: r.File, Start: s, End: e, Site: r, Check: []Want{{Span: r, Text: w}},
		Make: func(string) (string, error) { return repl, nil }}, nil
}

// isSugar は索引の行が書いた名前でない物（use の別名で書いた所・`a :: b` のような構文）か。
func isSugar(r Row) bool { return strings.Contains(" "+r.Extra+" ", " sugar ") }

// useFor は file の mod の中で、名前 alias を入れる use の行。
func useFor(ix *sigIndex, file, mod, alias string) (useRow, bool) {
	for _, u := range ix.uses[file] {
		if u.Owner == mod && u.alias == alias {
			return u, true
		}
	}
	return useRow{}, false
}

// wantUse は元の mod の use u を移し先にも足す物として覚える（同じ物は 1 度）。
func wantUse(srcs *reshapeSources, u useRow, set map[useWant]bool, order *[]useWant, used map[string]bool) error {
	used[u.Where()] = true
	src, err := srcs.get(u.File)
	if err != nil {
		return err
	}
	st, k, ok := useStmtAt(src, u.Owner, u.Row)
	if !ok {
		return fmt.Errorf("元の mod の use（%s）の文が読めない（手で移し先へ写す）", u.Where())
	}
	w := useWant{st.itemsText[k], st.parent} // 波括弧の無い `use A.b` も、親 `A.` と名前 `b` に分けてある
	if !set[w] {
		set[w] = true
		*order = append(*order, w)
	}
	return nil
}

// useStmtAt は file の mod の中で、索引の use の行 r を含む use の文と、波括弧の中の何番目か（波括弧が無ければ 0）。
func useStmtAt(src, mod string, r Row) (useStmt, int, bool) {
	s, e, err := ByteRange(src, r)
	if err != nil {
		return useStmt{}, -1, false
	}
	stmts, _, _, ok := moduleUses(src, mod, s)
	if !ok {
		return useStmt{}, -1, false
	}
	for _, st := range stmts {
		if s < st.start || e > st.end {
			continue
		}
		if !st.braces {
			return st, 0, len(st.itemsText) == 1
		}
		for k, it := range st.items {
			if it[0] <= s && e <= it[1] {
				return st, k, true
			}
		}
	}
	return useStmt{}, -1, false
}

// dropEdit は use の文 st から drop の番号の名前を外す書き換え。全部外れれば行ごと消す（all）。tidy の時、消す行が
// mod の行のすぐ下の最後の use なら（前が `{` の行・後ろが空行）、後ろの空行も消す（mod の頭に空行を残さない。
// 同じ mod へ use を足す時は足す所が残るように tidy にしない）。
func dropEdit(src, file string, st useStmt, drop map[int]bool, site Row, tidy bool) (Edit, bool) {
	var kept []string
	for k, t := range st.itemsText {
		if !drop[k] {
			kept = append(kept, t)
		}
	}
	if !st.braces || len(kept) == 0 {
		end := st.lineEnd
		if tidy && st.start > 0 && strings.HasSuffix(strings.TrimSpace(src[lineStart(src, st.start-1):st.start]), "{") {
			if nl := strings.IndexByte(src[end:], '\n'); nl >= 0 && strings.TrimSpace(src[end:end+nl]) == "" {
				end += nl + 1
			}
		}
		return Edit{File: file, Start: st.start, End: end, Site: site, Make: func(string) (string, error) { return "", nil }}, true
	}
	sep := ", "
	if len(st.items) > 1 {
		if between := src[st.items[0][1]:st.items[1][0]]; strings.Contains(between, "\n") {
			sep = between
		}
	}
	text := strings.Join(kept, sep)
	return Edit{File: file, Start: st.items[0][0], End: st.items[len(st.items)-1][1], Site: site,
		Make: func(string) (string, error) { return text, nil }}, false
}

// mergeCuts は同じファイルで重なる・接する切り取り（空行の始末が隣の宣言と同じ行を取る時）を 1 つにまとめる。
func mergeCuts(cuts []Edit) []Edit {
	sort.SliceStable(cuts, func(i, j int) bool {
		if cuts[i].File != cuts[j].File {
			return cuts[i].File < cuts[j].File
		}
		return cuts[i].Start < cuts[j].Start
	})
	var out []Edit
	for _, c := range cuts {
		if n := len(out); n > 0 && out[n-1].File == c.File && c.Start <= out[n-1].End {
			if c.End > out[n-1].End {
				out[n-1].End = c.End
			}
			out[n-1].Check = append(out[n-1].Check, c.Check...)
			continue
		}
		out = append(out, c)
	}
	return out
}

// moveTarget は移し先の mod のファイル（宣言・use の行か、`mod To {` の字から）。無ければ作るファイル。
func moveTarget(rows []Row, q MoveQuery) (string, bool) {
	for _, r := range rows {
		switch r.Kind {
		case KindDefDecl, KindAliasDecl, KindEnumDecl:
			if modOf(r.Sym) == q.To {
				return r.File, false
			}
		case KindUse:
			if r.Owner == q.To {
				return r.File, false
			}
		}
	}
	re := modOpenRe(q.To)
	files := make([]string, 0, len(q.All))
	for f := range q.All {
		files = append(files, f)
	}
	sort.Strings(files)
	for _, f := range files {
		if re.MatchString(q.All[f]) {
			return f, false
		}
	}
	dir := q.Dir
	if dir == "" {
		dir = "src"
	}
	return path.Join(dir, strings.ReplaceAll(q.To, ".", "/")+".flix"), true
}

func modOpenRe(mod string) *regexp.Regexp {
	return regexp.MustCompile(`(?m)^([ \t]*)(?:pub\s+)?mod\s+(?:` + regexp.QuoteMeta(mod) + `|` + regexp.QuoteMeta(shortName(mod)) + `)\s*\{[ \t]*\r?\n`)
}

// modSpan は mod の括弧: 開きの行の次の行の頭・閉じる `}` の行の頭・mod の行の字下げ。
type modSpan struct {
	openEnd, closeLine int
	indent             string
}

// modBlock は src の mod の括弧（`mod To {` の行から、対になる `}` だけの行まで）。
func modBlock(src, mod string) (modSpan, bool) {
	m := modOpenRe(mod).FindStringSubmatchIndex(src)
	if m == nil {
		return modSpan{}, false
	}
	brace := strings.LastIndexByte(src[:m[1]], '{')
	_, close, err := scanTop(src, brace+1, "}")
	if err != nil {
		return modSpan{}, false
	}
	ls := lineStart(src, close)
	if strings.TrimSpace(src[ls:close]) != "" {
		return modSpan{}, false
	}
	return modSpan{openEnd: m[1], closeLine: ls, indent: src[m[2]:m[3]]}, true
}

// lineIndent は pos の行の字下げ。
func lineIndent(src string, pos int) string {
	ls := lineStart(src, pos)
	i := ls
	for i < len(src) && (src[i] == ' ' || src[i] == '\t') {
		i++
	}
	return src[ls:i]
}

// reindent は text の各行の頭の from を to に替える（空の行は空のまま）。
func reindent(text, from, to string) string {
	lines := strings.SplitAfter(text, "\n")
	var b strings.Builder
	for _, l := range lines {
		switch {
		case strings.TrimSpace(l) == "":
			if strings.HasSuffix(l, "\n") {
				b.WriteString("\n")
			}
		case strings.HasPrefix(l, from):
			b.WriteString(to + l[len(from):])
		default:
			b.WriteString(l)
		}
	}
	return b.String()
}

// newModText は移し先の mod を作る時のファイルの中身（use・import・移す宣言）。
func newModText(to string, wants []useWant, imports []string, items []*moveItem, bodies []string, srcs *reshapeSources) string {
	var b strings.Builder
	b.WriteString("mod " + to + " {\n")
	byParent := map[string][]string{}
	var parents []string
	for _, w := range wants {
		if _, ok := byParent[w.parent]; !ok {
			parents = append(parents, w.parent)
		}
		byParent[w.parent] = append(byParent[w.parent], w.name)
	}
	sort.SliceStable(parents, func(i, j int) bool {
		pi, pj := strings.Contains(parents[i], "::"), strings.Contains(parents[j], "::")
		if pi != pj {
			return pi // パッケージの use（::）を先に
		}
		return parents[i] < parents[j]
	})
	for _, p := range parents {
		ns := byParent[p]
		sort.Strings(ns)
		b.WriteString("    use " + p + "{" + strings.Join(ns, ", ") + "}\n")
	}
	for _, im := range imports {
		b.WriteString("    " + strings.TrimSpace(im) + "\n")
	}
	if len(parents)+len(imports) > 0 {
		b.WriteString("\n")
	}
	for i, it := range items {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(reindent(bodies[i], lineIndent(src0(srcs, it.row.File), it.text[0]), "    "))
	}
	b.WriteString("}\n")
	return b.String()
}

var importLine = regexp.MustCompile(`(?m)^[ \t]*import[ \t]+([^\n]+)$`)

// copiedImports は移す物の元の mod の import（Java の型）のうち、移す本体が名前を使う物（同じ物は 1 度）。
// Java の名前は索引に無いので字で見る（`import java.lang.Math` の Math・`import java.util.{List => JList}` の JList）。
func copiedImports(srcs *reshapeSources, items []*moveItem, bodies []string) []string {
	var out []string
	for i, it := range items {
		src := src0(srcs, it.row.File)
		blk, ok := modBlock(src, it.from)
		if !ok {
			continue
		}
		for _, m := range importLine.FindAllStringSubmatch(src[blk.openEnd:blk.closeLine], -1) {
			line := "import " + strings.TrimSpace(m[1])
			names := map[string]bool{}
			spec := strings.TrimSpace(m[1])
			if b := strings.IndexByte(spec, '{'); b >= 0 {
				for _, part := range strings.Split(strings.Trim(spec[b:], "{} "), ",") {
					part = strings.TrimSpace(part)
					if _, as, ok := strings.Cut(part, "=>"); ok {
						part = strings.TrimSpace(as)
					}
					names[part] = true
				}
			} else {
				if _, as, ok := strings.Cut(spec, "=>"); ok {
					spec = strings.TrimSpace(as)
				}
				names[spec[strings.LastIndexByte(spec, '.')+1:]] = true
			}
			if len(identUses(bodies[i], names)) > 0 && indexOf(out, line) < 0 {
				out = append(out, line)
			}
		}
	}
	return out
}

// aliasExt は型 alias の宣言の範囲（名前の行の字の頭 〜 型の式の終わり。式は深さ 0 の改行まで）。
func aliasExt(src string, r Row) (Row, error) {
	s, e, err := ByteRange(src, r)
	if err != nil {
		return Row{}, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", r.Where())
	}
	_, eq, err := scanTop(src, e, "=")
	if err != nil {
		return Row{}, fmt.Errorf("%s: 型 alias の `=` が読めない", r.Where())
	}
	j := skipSpace(src, eq+1)
	end := len(src)
	if _, at, err := scanTop(src, j, "\n"); err == nil {
		end = at
	}
	for end > j && (src[end-1] == ' ' || src[end-1] == '\t' || src[end-1] == '\r') {
		end--
	}
	ls := lineStart(src, s)
	start := ls + len(lineIndent(src, s))
	sl, sc := lineCol(src, start)
	el, ec := lineCol(src, end)
	return Row{File: r.File, Line: sl, Col: sc, EndLine: el, EndCol: ec}, nil
}

// lineCol はバイトの位置 pos の行と列（1 から・列は UTF-16 で数える。索引と同じ数え方）。
func lineCol(src string, pos int) (int, int) {
	line := strings.Count(src[:pos], "\n") + 1
	ls := lineStart(src, pos)
	return line, len(utf16.Encode([]rune(src[ls:pos]))) + 1
}

var pubWord = regexp.MustCompile(`(^|\s)pub\s`)

// declIsPub は宣言の行の名前の前に `pub` があるか（alias・enum の宣言の行は索引に pub を持たない）。
func declIsPub(src string, r Row) bool {
	lines := strings.SplitAfter(src, "\n")
	if r.Line < 1 || r.Line > len(lines) {
		return false
	}
	l := lines[r.Line-1]
	return pubWord.MatchString(l[:byteCol(l, r.Col)])
}

// moveReport は move の入口。
func moveReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	if !idx.hasAdds(KindUse) {
		return report{}, fmt.Errorf("索引に use の行が無い（flixlint %s 以上が要る。--flixlint か FGE_FLIXLINT で名指しして bin/fge refactor index --rebuild）", MinFlixlintUsages)
	}
	all, err := loadSources(root, cfg)
	if err != nil {
		return report{}, err
	}
	q := MoveQuery{To: strings.TrimSpace(a.to), All: all, Dir: firstSourceDir(root, cfg)}
	kinds := map[string]bool{KindDefDecl: true, KindAliasDecl: true}
	for _, list := range []struct {
		text string
		dst  *[]string
	}{{a.def, &q.Defs}, {a.with, &q.With}} {
		if list.text == "" {
			continue
		}
		for _, d := range strings.Split(list.text, ",") {
			sym, err := Resolve(idx.Rows, strings.TrimSpace(d), kinds)
			if err != nil {
				return report{}, err
			}
			*list.dst = append(*list.dst, sym)
		}
	}
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	for f, s := range all {
		srcs.m[f] = s
	}
	plan, err := PlanMove(idx.Rows, srcs, q)
	if err != nil {
		return report{}, err
	}
	how := a.applyWith(cfg.Verify, o)
	if len(plan.Fix) > 0 {
		how.On = false
	}
	out := Change(root, plan.Edits, how)
	if a.apply && len(plan.Fix) > 0 {
		out.State, out.Reason = StateRefused, fmt.Sprintf("人へ回す所 %d（書くと名前が引けない。直してから --apply）", len(plan.Fix))
	}
	target := a.def
	if a.with != "" {
		target += "（--with " + a.with + "）"
	}
	r := report{Op: "move", Target: target + " → " + q.To, code: CodeMove, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	total := len(plan.Moved) + plan.Calls + plan.Uses
	if out.State == StateReverted || out.State == StateRefused {
		r.got = total
	}
	r.Sites = append(append([]Fixed{}, plan.Moved...), plan.Sites...)
	where := plan.Target
	if plan.Created {
		where += " を作る"
	}
	r.gotText = fmt.Sprintf("移す宣言 %d（→ %s）・呼ぶ所 %d（%d ファイル）・use %d・本体の中の名前 %d・人へ回す %d", len(plan.Moved), where, plan.Calls, len(plan.CallFiles), plan.Uses, plan.Inner, len(plan.Fix))
	if len(plan.UsesAdded) > 0 {
		r.extra = append(r.extra, "use を足す: "+foldUses(plan.UsesAdded, 3))
	}
	if len(plan.UsesDropped) > 0 {
		r.extra = append(r.extra, "元の mod で使わなくなった use を消す: "+strings.Join(plan.UsesDropped, "・"))
	}
	if mentions, err := mentionedOutsideFlix(root, engineDir(root)); err == nil {
		var outside []string
		for _, s := range plan.Olds {
			if f, ok := mentions[s]; ok {
				outside = append(outside, s+"（"+f+"）")
			}
		}
		if len(outside) > 0 {
			r.extra = append(r.extra, ".flix の外に字で出る（書き換えない・手で）: "+strings.Join(outside, "・"))
		}
	}
	r.wantText = "移した名前を指す所が全部新しい mod を指す（決められない所は fix。fix があれば書かない）"
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	for _, s := range plan.Moved {
		r.lines = append(r.lines, fmt.Sprintf("%s\t移す %s\t%s", s.Where(), s.Why, s.Sym))
	}
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s\t%s", s.Where(), s.Why, s.Owner))
	}
	base := fmt.Sprintf("bin/fge refactor move --def %s --to %s", a.def, q.To)
	if a.with != "" {
		base += " --with " + a.with
	}
	nextOf(&r, base, a, &out)
	switch {
	case len(plan.Fix) > 0:
		r.fixHint = "fix の所を手で直す（非 pub の物は --with で一緒に移すか pub に）か、移す物を選び直してから"
		r.Next, r.NextWhy = base, "fix の所を直してから dry-run から（fix が 0 になれば --apply）"
		switch {
		case len(plan.PubNeeded) > 0:
			// --with を足しても解けない（移す物の外も使う）。pub にするかは人が決める。
			r.Next, r.NextWhy = "", "pub にするかを決める: "+strings.Join(plan.PubNeeded, "・")+"（移す物の外も使う。pub を足したら --with から外して同じコマンド。足さないなら移す物を選び直す）"
		case len(plan.Deps) > 0:
			with := plan.Deps
			if a.with != "" {
				with = append(strings.Split(a.with, ","), with...)
			}
			r.Next = fmt.Sprintf("bin/fge refactor move --def %s --to %s --with %s", a.def, q.To, strings.Join(with, ","))
			r.NextWhy = "使う非 pub の物も一緒に移す（pub にして残すなら、pub を足してから元のコマンド）"
		}
	case out.State == StateApplied:
		left := leftMentions(root, cfg, plan.Olds)
		r.Done = fmt.Sprintf("done: %d sites（移した宣言 %d・呼ぶ所 %d・use %d）→ 0 left · check ok", total, len(plan.Moved), plan.Calls, plan.Uses)
		if len(left) > 0 {
			r.extra = append(r.extra, fmt.Sprintf("元の名前が字で残る所 %d（コメント・文字列。書き換えていない）: %s", len(left), strings.Join(left[:min(len(left), 3)], "・")))
		}
		r.Next, r.NextWhy = "bin/fge refactor usages "+q.To+"."+shortName(plan.Olds[0])+" --callers", "移した後の呼び手（索引は作り直しになる）"
		r.lines = nil
	}
	return r, nil
}

// foldUses は「名前（親） → ファイル」の並びを、ファイルと親ごとに `親{名前, …} → ファイル` へ畳む（keep 組まで・残りは数）。
func foldUses(notes []string, keep int) string {
	type group struct {
		file, parent string
		names        []string
	}
	var groups []*group
	at := map[[2]string]*group{}
	for _, n := range notes {
		head, file, _ := strings.Cut(n, " → ")
		name, parent, _ := strings.Cut(strings.TrimSuffix(head, "）"), "（")
		k := [2]string{file, parent}
		g, ok := at[k]
		if !ok {
			g = &group{file: file, parent: parent}
			at[k] = g
			groups = append(groups, g)
		}
		g.names = append(g.names, name)
	}
	var parts []string
	for i, g := range groups {
		if i == keep {
			parts = append(parts, fmt.Sprintf("ほか %d ファイル", len(groups)-keep))
			break
		}
		sort.Strings(g.names)
		parts = append(parts, g.parent+"{"+strings.Join(g.names, ", ")+"} → "+g.file)
	}
	return fmt.Sprintf("%d（", len(notes)) + strings.Join(parts, "・") + "）"
}

// leftMentions は書いた後のソースに元の名前（Mod.f）が字で残る所（file:line）。
func leftMentions(root string, cfg Config, olds []string) []string {
	all, err := loadSources(root, cfg)
	if err != nil {
		return nil
	}
	var out []string
	for _, f := range sortedKeys(all) {
		for _, o := range olds {
			re := regexp.MustCompile(`(^|[^\w.])` + regexp.QuoteMeta(o) + `\b`)
			for _, m := range re.FindAllStringIndex(all[f], -1) {
				out = append(out, fmt.Sprintf("%s:%d", f, strings.Count(all[f][:m[0]], "\n")+1))
			}
		}
	}
	return out
}

// firstSourceDir は新しい mod のファイルを置くフォルダ（索引に入れるフォルダの最初・既定 src）。
func firstSourceDir(root string, cfg Config) string {
	for _, s := range (Builder{Root: root, Config: cfg}).sources() {
		if !inDirs(strings.TrimSuffix(s, "/")+"/x.flix", cfg.TestDirs) {
			return strings.TrimSuffix(s, "/")
		}
	}
	return "src"
}
