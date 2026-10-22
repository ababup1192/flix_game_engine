package refactor

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// move-fields: World の欄を幾つかまとめて場面の payload（`case Deck(DeckUi)` の alias か `case Deck({ … })` の record）へ移す
// （設計 refactor-tool.md §7）。確かめ（make check）が毎回通るよう 2 段に分ける:
//
//	1. 写す（既定）: payload の型に欄を足し（型の字は World の alias の宣言から写す）、payload の組み立てにも値を足す。
//	   値は --value-of a=<式> か、World の組み立て（initialWith など）の同じ欄の式（全部が同じ字の時だけ）。World は触らない。
//	2. --finish: World の欄の直の読み書きが 0 なら（口の中身を payload を読む形に直すのは人。場面にいない時の値＝
//	   Option か既定値かは設計の判断）、World の型と組み立てから欄を消す。remove-field を幾つかの欄でまとめて 1 回の check。
//
// 組み立ての当て方は fix-construction と同じ（閉じた record の式の欄の組が型の欄の組とちょうど同じ物。欄の組が同じ別の型が
// あれば fix）。同じ組み立てに幾つかの欄を足す・消すのは 1 つの書き換えにまとめる（1 欄ずつだと欄の組の確かめがずれる）。

// payloadShape は --into-case の case の payload の record の型（inline の record か、payload の型 alias）と、その言い方。
func payloadShape(idx *Index, srcs map[string]string, caseName string) (Shape, string, error) {
	sym, err := Resolve(idx.Rows, caseName, map[string]bool{KindCaseDecl: true})
	if err != nil {
		return Shape{}, "", err
	}
	for _, r := range idx.Rows {
		if r.Kind != KindCaseDecl || r.Sym != sym {
			continue
		}
		src, ok := srcs[r.File]
		if !ok {
			return Shape{}, "", fmt.Errorf("case %s の宣言のファイル %s が sources に無い", sym, r.File)
		}
		if s, err := FindCaseShape(src, r); err == nil {
			return s, "case " + sym + " の record", nil
		}
		_, e, err := ByteRange(src, r)
		if err != nil {
			return Shape{}, "", err
		}
		i := skipSpace(src, e)
		if i >= len(src) || src[i] != '(' {
			return Shape{}, "", fmt.Errorf("case %s に payload が無い（先に change-case-shape で payload を作る）", sym)
		}
		_, at, err := scanTop(src, i+1, ")")
		if err != nil {
			return Shape{}, "", fmt.Errorf("case %s の payload が読めない", sym)
		}
		typ := strings.TrimSpace(src[i+1 : at])
		if !aliasName.MatchString(typ) {
			return Shape{}, "", fmt.Errorf("case %s の payload %s が record の alias 1 つでない（`case X(XUi)` か `case X({ … })` の形だけ）", sym, typ)
		}
		s, err := FindAliasShape(srcs, typ)
		if err != nil {
			return Shape{}, "", err
		}
		return s, "case " + sym + " の payload " + s.Name, nil
	}
	return Shape{}, "", fmt.Errorf("case %s の宣言が索引に無い（パッケージの case は直せない）", sym)
}

var aliasName = regexp.MustCompile(`^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$`)

// literalPlan は型 shape の組み立て（欄の組が shape と同じ閉じた record の式）に欄 labels をまとめて足す（消す）計画。
type literalPlan struct {
	edits   []Edit
	sites   []Fixed
	fix     []Fixed
	already int
}

// valueFor は組み立ての所（def）ごとの値（その mod で書ける形。消す時は nil）。
func planLiterals(idx *Index, srcs map[string]string, shape Shape, labels []string, add bool, valueFor func(d Row) map[string]string, skip map[string]bool) (literalPlan, error) {
	var p literalPlan
	before := fieldKey(shape.Fields)
	var afterFields []string
	if add {
		afterFields = append(append(afterFields, shape.Fields...), labels...)
	} else {
		for _, f := range shape.Fields {
			if indexOf(labels, f) < 0 {
				afterFields = append(afterFields, f)
			}
		}
	}
	after := fieldKey(afterFields)
	var others []string
	for _, at := range AllShapeKeys(srcs)[before] {
		if at != fmt.Sprintf("%s:%d", shape.File, shape.Brace) {
			others = append(others, at[:strings.LastIndex(at, ":")])
		}
	}
	err := eachLiteral(idx.Rows, srcs, func(d Row, src string, l Literal) {
		key := fieldKey(l.Fields)
		if key == after {
			p.already++
			return
		}
		if key != before {
			return
		}
		row := rowAt(d.File, src, l.Brace, d.Sym)
		switch {
		case skip[fmt.Sprintf("%s:%d", d.File, row.Line)]:
			p.fix = append(p.fix, Fixed{row, "--skip で外した"})
			return
		case len(others) > 0:
			p.fix = append(p.fix, Fixed{row, "欄の組が同じ別の型がある（" + strings.Join(others, "・") + "）。どちらを組み立てているか決められない"})
			return
		}
		why := "組み立てから欄 " + strings.Join(labels, "・") + " を消す"
		var values map[string]string
		if add {
			values = valueFor(d)
			var kv []string
			for _, lb := range labels {
				kv = append(kv, lb+" = "+values[lb])
			}
			why = "組み立てに " + strings.Join(kv, "・") + " を足す"
		}
		p.sites = append(p.sites, Fixed{row, why})
		name := d.Sym[strings.LastIndex(d.Sym, ".")+1:]
		p.edits = append(p.edits, Edit{File: d.File, Start: l.Brace, End: l.End, Site: row,
			Check: []Want{{Span: d, Text: name}},
			Make: func(cur string) (string, error) {
				u, closed, err := ParseRecord(cur)
				if err != nil || !closed {
					return "", fmt.Errorf("組み立ての式が読めない: %v", err)
				}
				var names []string
				for _, f := range u.Fields {
					names = append(names, f.Name)
				}
				if fieldKey(names) != before {
					return "", fmt.Errorf("組み立ての欄の組が変わった（索引が古い）")
				}
				return editFields(cur, labels, add, values)
			}})
	})
	return p, err
}

// editFields は record の字 text に欄 labels を順に足す（values の値・最後に）か消す。型の宣言にも使う（values は型の字）。
func editFields(text string, labels []string, add bool, values map[string]string) (string, error) {
	var err error
	for _, lb := range labels {
		if add {
			text, err = InsertRecordField(text, lb, values[lb], "")
		} else {
			text, err = RemoveRecordField(text, lb)
		}
		if err != nil {
			return "", err
		}
	}
	return text, nil
}

// literalValues は型 shape の組み立てに書いてある欄 labels の式（欄 → 出た字の一覧。重ねない）と、最初に出た所の mod。
func literalValues(idx *Index, srcs map[string]string, shape Shape, labels []string) (map[string][]string, map[string]string, error) {
	out, mods := map[string][]string{}, map[string]string{}
	key := fieldKey(shape.Fields)
	err := eachLiteral(idx.Rows, srcs, func(d Row, src string, l Literal) {
		if fieldKey(l.Fields) != key {
			return
		}
		text := src[l.Brace:l.End]
		u, closed, err := ParseRecord(text)
		if err != nil || !closed {
			return
		}
		for _, lb := range labels {
			if k := u.Find(lb); k >= 0 {
				v := strings.TrimSpace(text[u.Fields[k].VStart:codeEnd(text, u.Fields[k])])
				if indexOf(out[lb], v) < 0 {
					out[lb] = append(out[lb], v)
				}
				if _, ok := mods[lb]; !ok {
					mods[lb] = modOf(d.Sym)
				}
			}
		}
	})
	return out, mods, err
}

// moveFieldsReport は move-fields の入口。
func moveFieldsReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	srcs, err := loadSources(root, cfg)
	if err != nil {
		return report{}, err
	}
	var labels []string
	for _, l := range strings.Split(a.labels, ",") {
		if l = strings.TrimSpace(l); l != "" && indexOf(labels, l) < 0 {
			labels = append(labels, l)
		}
	}
	world, err := FindAliasShape(srcs, a.receiver)
	if err != nil {
		return report{}, err
	}
	payload, what, err := payloadShape(idx, srcs, a.intoCase)
	if err != nil {
		return report{}, err
	}
	for _, l := range labels {
		if !world.Has(l) {
			return report{}, fmt.Errorf("型 %s に欄 %s が無い（欄: %s）", world.Name, l, strings.Join(world.Fields, "・"))
		}
		if a.finish != payload.Has(l) {
			if a.finish {
				return report{}, fmt.Errorf("%s に欄 %s がまだ無い（先に --finish 無しで写す）", what, l)
			}
			return report{}, fmt.Errorf("%s に欄 %s がもうある（World から消すだけなら --finish）", what, l)
		}
	}
	base := fmt.Sprintf("bin/fge refactor move-fields --labels %s --receiver %s --into-case %s", strings.Join(labels, ","), a.receiver, a.intoCase)
	for _, v := range a.valueOf {
		base += " --value-of " + shellQuote(v)
	}
	if a.finish {
		return finishMoveReport(root, idx, a, cfg, o, srcs, labels, world, payload, base)
	}
	r := report{Op: "move-fields", Target: world.Name + "#" + strings.Join(labels, ",") + " → " + a.intoCase, code: CodeMoveFields}
	// 型の字は World の宣言から、値は --value-of か World の組み立てから。
	types, values, given := map[string]string{}, map[string]string{}, map[string]bool{}
	for _, v := range a.valueOf {
		k, e, ok := strings.Cut(v, "=")
		if !ok || indexOf(labels, strings.TrimSpace(k)) < 0 {
			return report{}, fmt.Errorf("--value-of %q は `欄=式`（欄は --labels の物）", v)
		}
		values[strings.TrimSpace(k)] = strings.TrimSpace(e)
		given[strings.TrimSpace(k)] = true
	}
	seen, fromMods, err := literalValues(idx, srcs, world, labels)
	if err != nil {
		return report{}, err
	}
	var missing []string
	for _, l := range labels {
		if types[l] = fieldTypeOf(srcs, world, l); types[l] == "" {
			return report{}, fmt.Errorf("型 %s の欄 %s の型の字が読めない", world.Name, l)
		}
		if _, ok := values[l]; ok {
			continue
		}
		if len(seen[l]) == 1 {
			values[l] = seen[l][0]
			r.extra = append(r.extra, fmt.Sprintf("欄 %s の値は %s の組み立ての式 %s を写す（場面に入る拍の値が違うなら --value-of %s=<式>）", l, world.Name, values[l], l))
			continue
		}
		missing = append(missing, fmt.Sprintf("%s（%s の組み立てに %d 通り: %s）", l, world.Name, len(seen[l]), strings.Join(seen[l], "・")))
	}
	if len(missing) > 0 {
		return report{}, fmt.Errorf("payload の組み立てに足す値が決まらない: %s。--value-of 欄=<式> で渡す", strings.Join(missing, "・"))
	}
	// World の組み立てから写した値と型の字は、書く所の mod で書ける形に（`FeedFocus.Hidden` → `World.FeedFocus.Hidden`）。
	ix := newSigIndex(idx.Rows)
	worldMod := modAt(idx.Rows, world.File, srcs[world.File], world.Brace)
	payloadMod := modAt(idx.Rows, payload.File, srcs[payload.File], payload.Brace)
	for _, l := range labels {
		types[l] = qualifyFrom(types[l], worldMod, payload.File, payloadMod, ix, idx.Rows)
	}
	valueFor := func(d Row) map[string]string {
		out := map[string]string{}
		for _, l := range labels {
			out[l] = values[l]
			if m, copied := fromMods[l]; copied && !given[l] {
				out[l] = qualifyFrom(values[l], m, d.File, modOf(d.Sym), ix, idx.Rows)
			}
		}
		return out
	}
	plan, err := planLiterals(idx, srcs, payload, labels, true, valueFor, a.skip)
	if err != nil {
		return report{}, err
	}
	typeRow := rowAt(payload.File, srcs[payload.File], payload.Brace, payload.Name)
	edits := append([]Edit{{File: payload.File, Start: payload.Brace, End: payload.End, Site: typeRow,
		Make: func(cur string) (string, error) { return editFields(cur, labels, true, types) }}}, plan.edits...)
	out := Change(root, edits, a.applyWith(cfg.Verify, o))
	r.Outcome, r.Fix = &out, plan.fix
	r.got = len(plan.fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.sites) + len(plan.fix) + 1
	}
	var kt []string
	for _, l := range labels {
		kt = append(kt, l+" = "+types[l])
	}
	r.Sites = append([]Fixed{{typeRow, "型に欄 " + strings.Join(kt, "・") + " を足す"}}, plan.sites...)
	r.gotText = fmt.Sprintf("%s に欄 %d を足す（%s）・組み立てに足す %d・人へ回す %d・World は触らない", what, len(labels), typeRow.Where(), len(plan.sites), len(plan.fix))
	if plan.already > 0 {
		r.gotText += fmt.Sprintf("・もう足してある組み立て %d", plan.already)
	}
	r.extra = append([]string{shapeNote(payload)}, r.extra...)
	r.wantText = fmt.Sprintf("%s に欄 %s があり、組み立ても型と同じ欄の組（決められない所は fix）", payload.Name, strings.Join(labels, "・"))
	r.lines = append(r.lines, fmt.Sprintf("%s\t型に欄 %s を足す", typeRow.Where(), strings.Join(kt, "・")))
	constructionLines(&r, ConstructionPlan{Sites: plan.sites, Fix: plan.fix})
	nextOf(&r, base, a, &out)
	if out.State == StateApplied {
		r.Done = fmt.Sprintf("done: %d sites（型 1・組み立て %d）→ %d left · check ok", len(plan.sites)+1, len(plan.sites), len(plan.fix))
		r.Next, r.NextWhy = base+" --finish", fmt.Sprintf("口の中身を payload を読む形に直し（field-sites --label <欄> --receiver %s が 0 になってから）、World から消す", a.receiver)
		r.lines = nil
	}
	return r, nil
}

// finishMoveReport は move-fields --finish: World の欄の直の読み書きが 0 なら、World の型と組み立てから欄をまとめて消す。
func finishMoveReport(root string, idx *Index, a args, cfg Config, o Options, srcs map[string]string, labels []string, world, payload Shape, base string) (report, error) {
	r := report{Op: "move-fields", Target: world.Name + "#" + strings.Join(labels, ",") + " → " + a.intoCase + "（--finish）", code: CodeMoveFields}
	var left []FieldSite
	for _, l := range labels {
		left = append(left, FieldSites(idx.Rows, FieldQuery{Label: l, Receiver: a.receiver, Op: "move-fields --finish"}).Sites...)
	}
	left, skipped := WithoutSkipped(left, a.skip)
	if skipped > 0 {
		r.extra = append(r.extra, fmt.Sprintf("--skip で外した読み書き %d（受け手が当たらないと人が決めた所。当たっていれば消した後の確かめで落ちて戻す）", skipped))
	}
	if len(left) > 0 {
		sort.SliceStable(left, func(i, j int) bool { return less(left[i].Row, left[j].Row) })
		out := Outcome{State: StateRefused, Reason: fmt.Sprintf("%s の欄 %s の直の読み書きが %d 件残っている（0 件の時だけ消す）", world.Name, strings.Join(labels, "・"), len(left))}
		r.Outcome, r.got, r.Sites = &out, len(left), left
		r.gotText = fmt.Sprintf("直の読み書き %d（%s）", len(left), splitSites(left))
		r.wantText = "移す欄の直の読み書き 0"
		for _, s := range left {
			rw := "読み"
			if s.Write {
				rw = "書き"
			}
			r.lines = append(r.lines, fmt.Sprintf("%s\t%s\t%s#%s\t%s", s.Where(), rw, s.OwnerText(), s.Sym, s.Owner))
		}
		r.fixHint = "読み書きを payload を読む口へ替えてから（場面にいない時の値＝Option か既定値かは人が決める）"
		return r, nil
	}
	plan, err := planLiterals(idx, srcs, world, labels, false, nil, a.skip)
	if err != nil {
		return report{}, err
	}
	typeRow := rowAt(world.File, srcs[world.File], world.Brace, world.Name)
	edits := append([]Edit{{File: world.File, Start: world.Brace, End: world.End, Site: typeRow,
		Make: func(cur string) (string, error) { return editFields(cur, labels, false, nil) }}}, plan.edits...)
	out := Change(root, edits, a.applyWith(cfg.Verify, o))
	r.Outcome, r.Fix = &out, plan.fix
	r.got = len(plan.fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.sites) + len(plan.fix) + 1
	}
	r.Sites = append([]Fixed{{typeRow, "型から欄 " + strings.Join(labels, "・") + " を消す"}}, plan.sites...)
	r.gotText = fmt.Sprintf("直の読み書き 0・%s の型から欄 %d を消す（%s）・組み立てから消す %d・人へ回す %d", world.Name, len(labels), typeRow.Where(), len(plan.sites), len(plan.fix))
	r.extra = append(r.extra, shapeNote(world), "移した先: "+shapeNote(payload))
	r.wantText = fmt.Sprintf("%s に欄 %s が無く、組み立ても型と同じ欄の組（決められない所は fix）", world.Name, strings.Join(labels, "・"))
	r.lines = append(r.lines, fmt.Sprintf("%s\t型から欄 %s を消す", typeRow.Where(), strings.Join(labels, "・")))
	constructionLines(&r, ConstructionPlan{Sites: plan.sites, Fix: plan.fix})
	nextOf(&r, base+" --finish", a, &out)
	if out.State == StateApplied {
		r.Done = fmt.Sprintf("done: %d sites（型 1・組み立て %d）→ %d left · check ok", len(plan.sites)+1, len(plan.sites), len(plan.fix))
		r.lines = nil
	}
	return r, nil
}

// splitSites は読み書きの所の内訳（src・test）。
func splitSites(sites []FieldSite) string {
	rows := make([]Row, len(sites))
	for i, s := range sites {
		rows[i] = s.Row
	}
	return split(rows)
}

// qualifiedHead は式の中の修飾した名前（`FeedFocus.Hidden`・`Clock.never()` の頭）。
var qualifiedHead = regexp.MustCompile(`[A-Z][A-Za-z0-9_]*\.[A-Za-z_]`)

// qualifyFrom は mod fromMod で書いた式（か型の字）e を、file の mod toMod で書ける形にする: fromMod の def を呼ぶ素の名前と、
// fromMod の中の型・enum から始まる名前（`FeedFocus.Hidden`）に `fromMod.` を付ける。toMod が同じ mod・名前を use か宣言で
// 引ける・プロジェクトの根の mod の名前は触らない。
func qualifyFrom(e, fromMod, file, toMod string, ix *sigIndex, rows []Row) string {
	if fromMod == "" || fromMod == toMod {
		return e
	}
	e = qualifyTemplates([]string{e}, fromMod, rows, nil)[0]
	locs := qualifiedHead.FindAllStringIndex(e, -1)
	for k := len(locs) - 1; k >= 0; k-- {
		at := locs[k][0]
		if at > 0 && (e[at-1] == '.' || e[at-1] == '#' || identByte(e[at-1])) {
			continue
		}
		root := e[at : strings.IndexByte(e[at:], '.')+at]
		if ix.roots[root] || ix.hasUse(file, root) {
			continue
		}
		inFrom, inTo := false, false
		for _, s := range ix.decls[root] {
			inFrom = inFrom || modOf(s) == fromMod
			inTo = inTo || modOf(s) == toMod
		}
		if inFrom && !inTo {
			e = e[:at] + fromMod + "." + e[at:]
		}
	}
	return e
}
