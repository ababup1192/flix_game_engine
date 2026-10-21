package refactor

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// status は status の行の字（結末と diff・確かめの要約）。
func (o *Outcome) status() string {
	switch o.State {
	case StateDryRun:
		return fmt.Sprintf("dry-run（diff: %s・%d 行・%d ファイル）", rel(o.Diff), o.DiffLines, o.Files)
	case StateApplied:
		return fmt.Sprintf("applied（%s が %.0f s で通った・patch: %s）", o.Verify, o.VerifySecs, rel(o.Patch)) + o.dirtyNote()
	case StateReverted:
		s := fmt.Sprintf("reverted（%s が %.0f s で落ちたので patch を戻した・出力: %s）", o.Verify, o.VerifySecs, rel(o.VerifyLog))
		if o.FirstError != "" {
			s += "\n          最初の誤り: " + o.FirstError
		}
		if o.Reason != "" {
			s += "\n          戻し: " + o.Reason
		}
		return s + o.dirtyNote()
	case StateRevertFailed:
		s := fmt.Sprintf("revert-failed（%s が落ちたが、戻せないファイルが残った: %s）", o.Verify, strings.Join(o.Unrestored, "・"))
		if o.FirstError != "" {
			s += "\n          最初の誤り: " + o.FirstError
		}
		if o.Reason != "" {
			s += "\n          戻し: " + o.Reason
		}
		return s + o.dirtyNote()
	case StateRefused:
		return "refused（" + o.Reason + "）"
	case StateNothing:
		return "nothing（当てる所が無い）"
	}
	return o.State
}

func skipFlags(a args) string {
	var s []string
	for k := range a.skip {
		s = append(s, "--skip "+k)
	}
	return strings.Join(s, " ")
}

// nextOf は書き換える操作の next: dry-run なら --apply、戻したら直す所、断ったらその理由に合う手。
func nextOf(r *report, base string, a args, o *Outcome) {
	cmd := strings.TrimSpace(base + " " + skipFlags(a))
	switch o.State {
	case StateDryRun:
		r.Next, r.NextWhy = cmd+" --apply", "diff を読んでから"
	case StateRevertFailed:
		r.fixHint = "戻せなかったファイルを git diff で見て、" + rel(o.Patch) + " の分を手で戻す（git checkout -- <file> は書いた後の変更も消す）"
	case StateReverted:
		r.fixHint = "最初の誤りの所を --skip <file:line> で外すか、手で直してから --apply をやり直す"
		r.Next = cmd
		r.NextWhy = "--skip を足して dry-run から"
	case StateRefused:
		if strings.Contains(o.Reason, "索引が古い") {
			r.Next, r.NextWhy = "bin/fge refactor index --rebuild", "索引を作り直してからもう一度"
		} else {
			r.fixHint = "書き換える所の変更をコミットか stash してから --apply"
		}
	}
}

func expandReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	targets := matchTargets(idx.Rows)
	sym, err := Resolve(targets, a.target, map[string]bool{KindEnumDecl: true})
	if err != nil {
		return report{}, err
	}
	plan, err := PlanExpand(root, idx.Rows, sym, a.skip)
	if err != nil {
		return report{}, err
	}
	out := Change(root, plan.Edits, a.apply, cfg.Verify, o.Verify)
	r := report{Op: "expand-wildcard", Target: a.target, Sym: sym, code: CodeExpand, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = plan.Sites
	}
	sites := make([]Row, len(plan.Edits))
	for i, e := range plan.Edits {
		sites[i] = e.Site
		r.lines = append(r.lines, fmt.Sprintf("%-44s 書き出す  %s", e.Site.Where(), e.Site.Owner))
	}
	r.Sites = sites
	r.gotText = fmt.Sprintf("`_`・変数の腕を持つ match %d・書き出す %d・人へ回す %d", plan.Sites, len(plan.Edits), len(plan.Fix))
	r.wantText = fmt.Sprintf("%s への match に `case _` 0（書き出せない所は fix）", sym)
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%-44s fix  %s（%s）", f.Where(), f.Why, f.Owner))
	}
	nextOf(&r, "bin/fge refactor expand-wildcard --enum "+a.target, a, &out)
	return r, nil
}

func deadReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	plan, err := PlanDead(root, idx.Rows, DeadQuery{WithTests: a.withTests, Only: a.only, TestDirs: cfg.TestDirs, Skip: a.skip, Engine: engineDir(root), Def: a.def, Library: IsLibrary(root, cfg)})
	if err != nil {
		return report{}, err
	}
	out := Change(root, plan.Edits, a.apply, cfg.VerifyTests, o.Verify)
	r := report{Op: "remove-dead", code: CodeRemoveDead, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = plan.Sites
	}
	var sites []Fixed
	sites = append(append(sites, plan.Targets...), plan.Tests...)
	r.Sites = sites
	r.gotText = fmt.Sprintf("候補 %d（test-only %d・参照 0 %d）・消す def %d・一緒に消すテスト %d・人へ回す %d", plan.Sites, plan.TestOnly, plan.Sites-plan.TestOnly, len(plan.Targets), len(plan.Tests), len(plan.Fix))
	r.wantText = "テストからだけ・どこからも参照されない pub の def 0（決められない所は fix）"
	for _, t := range plan.Targets {
		r.lines = append(r.lines, fmt.Sprintf("%-44s 消す  %s（%s）", t.Where(), t.Sym, t.Why))
	}
	for _, t := range plan.Tests {
		r.lines = append(r.lines, fmt.Sprintf("%-44s 消す  %s（%s）", t.Where(), t.Sym, t.Why))
	}
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%-44s fix   %s（%s）", f.Where(), f.Sym, f.Why))
	}
	base := "bin/fge refactor remove-dead"
	if a.withTests {
		base += " --with-tests"
	}
	if a.only != "" {
		base += " --only " + a.only
	}
	if a.def != "" {
		base += " --def " + a.def
	}
	nextOf(&r, base, a, &out)
	if out.State == StateDryRun && !a.withTests && len(plan.Targets) == 0 && len(plan.Fix) > 0 {
		r.Next, r.NextWhy = base+" --with-tests", "テストが参照する def はテストごと消す"
	}
	return r, nil
}

// accessorReport は field-to-accessor の入口（ファイルを読み、型の字を比べ、計画を Change へ渡す）。
func accessorReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	defs := map[string]bool{KindDefDecl: true}
	alias := ""
	for _, r := range idx.Rows {
		if v := r.Attr("recv"); (r.Kind == KindLabelSelect || r.Kind == KindLabelUpdate) && r.Sym == a.label && nameMatches(v, a.receiver) {
			alias = v
			break
		}
	}
	// 口の名前を決め、索引に無い口は作る（名前の既定は alias の mod の <欄>Of・with<欄>）。
	var missing []string
	if alias != "" {
		if a.reader == "" {
			a.reader = DefaultGetter(modOf(alias), a.label)
		}
		if a.mapper == "" && a.setter == "" {
			a.setter = DefaultSetter(modOf(alias), a.label)
		}
	}
	q := AccessorQuery{Label: a.label, Receiver: a.receiver, Reader: a.reader, Mapper: a.mapper, Setter: a.setter, Outside: a.outside, Skip: a.skip}
	var readerRow Row
	for _, name := range []string{a.reader, a.mapper, a.setter} {
		if name == "" {
			continue
		}
		sym, err := Resolve(idx.Rows, name, defs)
		if err != nil && strings.Contains(err.Error(), "索引にありません") && name != a.mapper && alias != "" {
			missing = append(missing, name)
			continue
		}
		if err != nil {
			return report{}, fmt.Errorf("口 %s: %v", name, err)
		}
		q.OwnerSyms = append(q.OwnerSyms, sym)
		for _, r := range idx.Rows {
			if r.Kind == KindDefDecl && r.Sym == sym && name == a.reader {
				readerRow = r
			}
		}
	}
	srcs := map[string]string{}
	load := func(f string) error {
		if _, ok := srcs[f]; ok || f == "" {
			return nil
		}
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			return err
		}
		srcs[f] = string(b)
		return nil
	}
	for _, r := range idx.Rows {
		if (r.Kind == KindLabelSelect || r.Kind == KindLabelUpdate) && r.Sym == a.label {
			if err := load(r.File); err != nil {
				return report{}, err
			}
		}
	}
	if err := load(readerRow.File); err != nil {
		return report{}, err
	}
	typeNote := "型: 確かめられない（make check に任せる）"
	readerType, rok := "", false
	if ext := readerRow.Attr("ext"); ext != "" {
		if span, err := spanOf(readerRow.File, ext); err == nil {
			if text, err := SpanText(srcs[readerRow.File], span); err == nil {
				readerType, rok = DefReturnType(text)
			}
		}
	}
	fieldType, fok := aliasFieldTypeIn(root, cfg, alias, a.label)
	var stub *Edit
	stubNote := ""
	if len(missing) > 0 {
		if !fok {
			return report{}, fmt.Errorf("口 %s が無く、欄 %s の型が %s の宣言から読めないので作れない（口を手で書いて --getter・--setter で名指し）", strings.Join(missing, "・"), a.label, alias)
		}
		all, err := loadSources(root, cfg)
		if err != nil {
			return report{}, err
		}
		shape, err := FindAliasShape(all, alias)
		if err != nil {
			return report{}, err
		}
		place, err := FindStubPlace(idx.Rows, all, modOf(alias), shape)
		if err != nil {
			return report{}, err
		}
		getter, setter := "", ""
		for _, m := range missing {
			if m == a.reader {
				getter = m
			} else {
				setter = m
			}
		}
		if err := load(place.File); err != nil {
			return report{}, err
		}
		e := stubEdit(place, AccessorStubs(place.Indent, shortName(alias), a.label, fieldType, getter, setter))
		stub = &e
		stubNote = fmt.Sprintf("口を作る: %s（%s の後）", strings.Join(missing, "・"), place.At.Where())
		if getter != "" {
			readerType, rok = fieldType, true
		}
	}
	switch {
	case rok && fok && SameType(readerType, fieldType):
		typeNote = fmt.Sprintf("型: %s の戻り %s = 欄 %s の %s", a.reader, readerType, a.label, fieldType)
	case rok && fok:
		q.TypeWhy = fmt.Sprintf("口 %s の戻り %s と欄の型 %s が違う（読む側の組み替えは人）", a.reader, readerType, fieldType)
		typeNote = "型: " + q.TypeWhy
	case rok:
		typeNote = fmt.Sprintf("型: %s の戻り %s・欄の型は %s の宣言が見つからず確かめられない（make check に任せる）", a.reader, readerType, alias)
	}
	plan, err := PlanAccessor(srcs, idx.Rows, q)
	if err != nil {
		return report{}, err
	}
	if stub != nil && plan.Reads+plan.Writes > 0 {
		plan.Edits = append(plan.Edits, *stub)
	} else if stub != nil {
		stubNote = "口は作らない（替える読み書きが 0）"
	}
	out := Change(root, plan.Edits, a.apply, cfg.Verify, o.Verify)
	r := report{Op: "field-to-accessor", Target: a.receiver + "#" + a.label, Sym: alias, code: CodeAccessor, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = plan.Sites
	}
	r.Sites = plan.Rewrites
	r.gotText = fmt.Sprintf("直の読み書き %d・口へ替える %d（読み %d・書き %d。うち書きの lambda に畳む読み %d）・人へ回す %d",
		plan.Sites, plan.Reads+plan.Writes, plan.Reads, plan.Writes, plan.Folded, len(plan.Fix))
	if plan.Inside > 0 {
		r.extra = append(r.extra, fmt.Sprintf("口の def の中・--outside の mod の中の物 %d は替えない", plan.Inside))
	}
	r.extra = append(r.extra, typeNote)
	if stubNote != "" {
		r.extra = append(r.extra, stubNote)
	}
	r.wantText = fmt.Sprintf("%s の欄 %s の直の読み書き 0（口の中を除く。決められない所は fix）", a.receiver, a.label)
	for _, w := range plan.Rewrites {
		r.lines = append(r.lines, fmt.Sprintf("%-44s %s（%s）", w.Where(), w.Why, w.Owner))
	}
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%-44s fix  %s（%s）", f.Where(), f.Why, f.Owner))
	}
	base := fmt.Sprintf("bin/fge refactor field-to-accessor --label %s --receiver %s --reader %s", a.label, a.receiver, a.reader)
	if a.mapper != "" {
		base += " --mapper " + a.mapper
	}
	if a.setter != "" {
		base += " --setter " + a.setter
	}
	if a.outside != "" {
		base += " --outside " + a.outside
	}
	nextOf(&r, base, a, &out)
	if out.State == StateApplied {
		mod := a.outside
		if mod == "" {
			mod = a.receiver
		}
		r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor field-sites --label %s --receiver %s --outside %s --max 0", a.label, a.receiver, mod), "口の外が 0 になったか（索引は作り直しになる）"
	}
	return r, nil
}

// aliasFieldTypeIn は sources の .flix から `type alias <alias の最後>` を探し、欄 label の型の字を返す。
// 同じ名前の alias が 2 つ以上のファイルにあれば決めない（false）。
func aliasFieldTypeIn(root string, cfg Config, alias, label string) (string, bool) {
	if alias == "" || strings.Contains(alias, "|") {
		return "", false
	}
	short := alias[strings.LastIndex(alias, ".")+1:]
	files, err := flixFiles(root, (Builder{Root: root, Config: cfg}).sources())
	if err != nil {
		return "", false
	}
	found, n := "", 0
	for _, f := range files {
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil || !strings.Contains(string(b), "type alias "+short) {
			continue
		}
		if t, ok := AliasFieldType(string(b), short, label); ok {
			found = t
			n++
		}
	}
	return found, n == 1
}

// engineDir は engine の根（mk/game.mk を持つ所）。見つからなければ ""。
func engineDir(root string) string {
	dir, _ := status.FindEngineDir(root, "mk/game.mk")
	return abs(root, dir)
}

// dirtyNote は確かめが残した変更（書く前に無かった git の変更）の 1 行。
func (o *Outcome) dirtyNote() string {
	if len(o.LeftDirty) == 0 {
		return ""
	}
	return "\n          確かめが残した変更（refactor は戻していない。生成物なら git checkout か消す）: " + strings.Join(o.LeftDirty, "・")
}

func rel(p string) string {
	if i := strings.Index(p, "build"+string(filepath.Separator)+"refactor"); i >= 0 {
		return p[i:]
	}
	return p
}

// loadSources は索引に入れるフォルダの .flix を全部読む（根からの相対 → 中身）。
func loadSources(root string, cfg Config) (map[string]string, error) {
	files, err := flixFiles(root, (Builder{Root: root, Config: cfg}).sources())
	if err != nil {
		return nil, err
	}
	srcs := map[string]string{}
	for _, f := range files {
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			return nil, err
		}
		srcs[filepath.ToSlash(f)] = string(b)
	}
	return srcs, nil
}

// shapeOf は --receiver（record の alias）か --case（enum の case の record）が指す型。
func shapeOf(idx *Index, a args, srcs map[string]string) (Shape, error) {
	if a.caseName == "" {
		return FindAliasShape(srcs, a.receiver)
	}
	sym, err := Resolve(idx.Rows, a.caseName, map[string]bool{KindCaseDecl: true})
	if err != nil {
		return Shape{}, err
	}
	for _, r := range idx.Rows {
		if r.Kind == KindCaseDecl && r.Sym == sym {
			src, ok := srcs[r.File]
			if !ok {
				return Shape{}, fmt.Errorf("case %s の宣言のファイル %s が sources に無い", sym, r.File)
			}
			return FindCaseShape(src, r)
		}
	}
	return Shape{}, fmt.Errorf("case %s の宣言が索引に無い（パッケージの case は直せない）", sym)
}

func shapeFlag(a args) string {
	if a.caseName != "" {
		return "--case " + a.caseName
	}
	return "--receiver " + a.receiver
}

// constructionPlan は型 shape の組み立てを、欄の組 before から 1 欄変える計画（ほかに同じ欄の組の型があれば fix）。
func constructionPlan(idx *Index, a args, shape Shape, before []string, add bool, srcs map[string]string) (ConstructionPlan, error) {
	key := fieldKey(before)
	var others []string
	for _, at := range AllShapeKeys(srcs)[key] {
		if at != fmt.Sprintf("%s:%d", shape.File, shape.Brace) {
			others = append(others, at[:strings.LastIndex(at, ":")])
		}
	}
	var defs []Row
	for _, r := range idx.Rows {
		if r.Kind == KindDefDecl {
			defs = append(defs, r)
		}
	}
	return PlanConstruction(ConstructionQuery{Shape: shape, Label: a.label, Add: add, Value: a.value, Before: key, Others: others, Skip: a.skip, Defs: defs, Srcs: srcs})
}

func constructionLines(r *report, plan ConstructionPlan) {
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%-44s %s（%s）", s.Where(), s.Why, s.Owner))
	}
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%-44s fix  %s（%s）", f.Where(), f.Why, f.Owner))
	}
}

// fixConstructionReport は fix-construction の入口: 組み立て（record の式）の欄を型に合わせる。
// 型に欄があれば、無い組み立てへ --value の式で足す。型に欄が無ければ、ある組み立てから消す。
func fixConstructionReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	srcs, err := loadSources(root, cfg)
	if err != nil {
		return report{}, err
	}
	shape, err := shapeOf(idx, a, srcs)
	if err != nil {
		return report{}, err
	}
	add := shape.Has(a.label)
	var before []string
	switch {
	case add && a.value == "":
		return report{}, fmt.Errorf("型 %s に欄 %s がある: 組み立てへ足す値を --value <式> で渡す（型から消すなら remove-field）", shape.Name, a.label)
	case !add && a.value != "":
		return report{}, fmt.Errorf("型 %s に欄 %s が無い: 先に型へ欄を足す（1 行）。--value は足す時だけ", shape.Name, a.label)
	case add:
		for _, f := range shape.Fields {
			if f != a.label {
				before = append(before, f)
			}
		}
	default:
		before = append(append(before, shape.Fields...), a.label)
	}
	plan, err := constructionPlan(idx, a, shape, before, add, srcs)
	if err != nil {
		return report{}, err
	}
	out := Change(root, plan.Edits, a.apply, cfg.Verify, o.Verify)
	r := report{Op: "fix-construction", Target: shape.Name + "#" + a.label, code: CodeFixConstruction, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.Sites) + len(plan.Fix)
	}
	r.Sites = plan.Sites
	verb := "消す"
	if add {
		verb = "足す"
	}
	r.gotText = fmt.Sprintf("%s を組み立てる式のうち欄 %s を%s所 %d・人へ回す %d・もう型に合っている %d", shape.Name, a.label, verb, len(plan.Sites), len(plan.Fix), plan.Already)
	r.extra = append(r.extra, shapeNote(shape))
	r.wantText = fmt.Sprintf("%s の組み立ての欄の組が型と同じ（決められない所は fix）", shape.Name)
	constructionLines(&r, plan)
	base := fmt.Sprintf("bin/fge refactor fix-construction --label %s %s", a.label, shapeFlag(a))
	if add {
		base += " --value '" + a.value + "'"
	}
	nextOf(&r, base, a, &out)
	return r, nil
}

// removeFieldReport は remove-field の入口: 欄の直の読み書きが 0 件なら、型から欄を消し、組み立てからも消す。
func removeFieldReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	srcs, err := loadSources(root, cfg)
	if err != nil {
		return report{}, err
	}
	shape, err := shapeOf(idx, a, srcs)
	if err != nil {
		return report{}, err
	}
	if !shape.Has(a.label) {
		return report{}, fmt.Errorf("型 %s に欄 %s が無い（型から消した後の組み立ては fix-construction --label %s %s）", shape.Name, a.label, a.label, shapeFlag(a))
	}
	r := report{Op: "remove-field", Target: shape.Name + "#" + a.label, code: CodeRemoveField}
	// 欄の直の読み書き。case の record は受け手に alias が無い（recv=?）ので、受け手の型が決まらない物を全部数える。
	var left []FieldSite
	if a.caseName == "" {
		ans := FieldSites(idx.Rows, FieldQuery{Label: a.label, Receiver: a.receiver})
		left = append(ans.Sites, ans.Unsure...)
	} else {
		for _, s := range FieldSites(idx.Rows, FieldQuery{Label: a.label}).Sites {
			if s.Recv == "?" {
				left = append(left, s)
			}
		}
	}
	if len(left) > 0 {
		out := Outcome{State: StateRefused, Reason: fmt.Sprintf("欄 %s の直の読み書きが %d 件残っている（0 件の時だけ消す）", a.label, len(left))}
		r.Outcome, r.got, r.Sites = &out, len(left), left
		r.gotText = fmt.Sprintf("欄 %s の直の読み書き %d（%s）", a.label, len(left), split(func() []Row {
			rows := make([]Row, len(left))
			for i, s := range left {
				rows[i] = s.Row
			}
			return rows
		}()))
		if a.caseName != "" {
			r.extra = append(r.extra, "case の record は受け手の型が索引で決まらないので、同じ名前の欄で受け手の型が ? の物を全部数えた")
		}
		r.wantText = fmt.Sprintf("欄 %s の直の読み書き 0", a.label)
		for _, s := range left {
			rw := "読み"
			if s.Write {
				rw = "書き"
			}
			r.lines = append(r.lines, fmt.Sprintf("%-44s %s  %-20s %s", s.Where(), rw, s.Recv, s.Owner))
		}
		r.fixHint = "読み書きを口へ替える（field-to-accessor）か消してから。使われなくなった口の def は remove-dead --def で消す"
		if a.caseName == "" {
			r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor field-sites --label %s --receiver %s", a.label, a.receiver), "残っている所の一覧"
		}
		return r, nil
	}
	plan, err := constructionPlan(idx, a, shape, shape.Fields, false, srcs)
	if err != nil {
		return report{}, err
	}
	label := a.label
	typeRow := rowAt(shape.File, srcs[shape.File], shape.Brace, shape.Name)
	edits := append(append([]Edit{}, plan.Edits...), Edit{File: shape.File, Start: shape.Brace, End: shape.End, Site: typeRow,
		Make: func(cur string) (string, error) { return RemoveRecordField(cur, label) }})
	out := Change(root, edits, a.apply, cfg.Verify, o.Verify)
	r.Outcome, r.Fix = &out, plan.Fix
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.Sites) + len(plan.Fix) + 1
	}
	r.Sites = append([]Fixed{{typeRow, "型から欄 " + label + " を消す"}}, plan.Sites...)
	r.gotText = fmt.Sprintf("直の読み書き 0・型から消す 1（%s）・組み立てから消す %d・人へ回す %d", typeRow.Where(), len(plan.Sites), len(plan.Fix))
	r.extra = append(r.extra, shapeNote(shape))
	r.wantText = fmt.Sprintf("%s に欄 %s が無く、組み立ても型と同じ欄の組（決められない所は fix）", shape.Name, label)
	r.lines = append(r.lines, fmt.Sprintf("%-44s 型から欄 %s を消す", typeRow.Where(), label))
	constructionLines(&r, plan)
	nextOf(&r, fmt.Sprintf("bin/fge refactor remove-field --label %s %s", label, shapeFlag(a)), a, &out)
	return r, nil
}

// shapeNote は型の 1 行（欄が多ければ数と頭の数個だけ。全部は --json の外で読む）。
func shapeNote(s Shape) string {
	shown := s.Fields
	more := ""
	if len(shown) > 8 {
		shown, more = shown[:8], fmt.Sprintf("…ほか %d", len(s.Fields)-8)
	}
	return fmt.Sprintf("型: %s（%s）の欄 %d: %s%s", s.Name, s.File, len(s.Fields), strings.Join(shown, "・"), more)
}
