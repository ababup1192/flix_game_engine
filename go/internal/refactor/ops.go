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
		switch {
		case o.FixedAfter:
			return fmt.Sprintf("applied（%s は書く前は落ちていた（誤り %d）が、書いた後は %.0f s で通った・patch: %s）", o.Verify, o.ErrorsBefore, o.VerifySecs, rel(o.Patch)) + o.dirtyNote()
		case o.BrokenBefore:
			return fmt.Sprintf("applied（%s は書く前から落ちている。誤り 前 %d → 後 %d・新しい誤り 0・patch: %s）", o.Verify, o.ErrorsBefore, o.ErrorsAfter, rel(o.Patch)) + o.dirtyNote()
		}
		return fmt.Sprintf("applied（%s が %.0f s で通った・patch: %s）", o.Verify, o.VerifySecs, rel(o.Patch)) + o.dirtyNote()
	case StateReverted:
		s := fmt.Sprintf("reverted（%s が %.0f s で落ちたので書く前の中身へ戻した・出力: %s）", o.Verify, o.VerifySecs, rel(o.VerifyLog))
		if o.FirstError != "" {
			s += "\n          最初の誤り: " + o.FirstError
		}
		if o.Reason != "" {
			s += "\n          戻し: " + o.Reason
		}
		return s + o.dirtyNote()
	case StateRevertFailed:
		s := fmt.Sprintf("revert-failed（%s が落ちたが、戻さなかったファイルが残った: %s）", o.Verify, strings.Join(o.Unrestored, "・"))
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
		r.fixHint = "戻さなかったファイルを " + rel(o.Backup) + "/<パス>（書く前の中身）と見比べて手で直す（git checkout -- <file> は手の変更も消す）"
	case StateReverted:
		r.fixHint = "最初の誤りの所を --skip <file:line> で外すか、手で直してから --apply をやり直す"
		r.Next = cmd
		r.NextWhy = "--skip を足して dry-run から"
	case StateRefused:
		switch {
		case strings.Contains(o.Reason, "索引が古い"):
			r.Next, r.NextWhy = "bin/fge refactor index --rebuild", "索引を作り直してからもう一度"
		case strings.Contains(o.Reason, "外から変わった"):
			r.Next, r.NextWhy = cmd, "別の手の書き込みが止んでから dry-run から"
		case strings.Contains(o.Reason, "--require-clean"):
			r.fixHint = "書き換える所の変更をコミットしてから --apply（--require-clean を外せば、手の変更ごと控えて戻す）"
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
	out := Change(root, plan.Edits, a.applyWith(cfg.Verify, o))
	r := report{Op: "expand-wildcard", Target: a.target, Sym: sym, code: CodeExpand, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = plan.Sites
	}
	sites := make([]Row, len(plan.Edits))
	for i, e := range plan.Edits {
		sites[i] = e.Site
		r.lines = append(r.lines, fmt.Sprintf("%s\t書き出す\t%s", e.Site.Where(), e.Site.Owner))
	}
	r.Sites = sites
	r.gotText = fmt.Sprintf("`_`・変数の腕を持つ match %d・書き出す %d・人へ回す %d", plan.Sites, len(plan.Edits), len(plan.Fix))
	r.wantText = fmt.Sprintf("%s への match に `case _` 0（書き出せない所は fix）", sym)
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	nextOf(&r, "bin/fge refactor expand-wildcard --enum "+a.target, a, &out)
	return r, nil
}

func deadReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	plan, err := PlanDead(root, idx.Rows, DeadQuery{WithTests: a.withTests, Only: a.only, TestDirs: cfg.TestDirs, Skip: a.skip, Engine: engineDir(root), Def: a.def, Library: IsLibrary(root, cfg)})
	if err != nil {
		return report{}, err
	}
	out := Change(root, plan.Edits, a.applyWith(cfg.VerifyTests, o))
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
	if len(plan.Docs) > 0 {
		var moved []string
		for _, d := range plan.Docs {
			moved = append(moved, d.Sym+"（"+d.Why+"）")
		}
		r.extra = append(r.extra, "転送するだけの包みの doc を転送先へ: "+strings.Join(moved, "・"))
	}
	for _, t := range plan.Targets {
		r.lines = append(r.lines, fmt.Sprintf("%s\t消す\t%s（%s）", t.Where(), t.Sym, t.Why))
	}
	for _, t := range plan.Tests {
		r.lines = append(r.lines, fmt.Sprintf("%s\t消す\t%s（%s）", t.Where(), t.Sym, t.Why))
	}
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Sym, f.Why))
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
	if len(plan.DocRefs) > 0 {
		docNext(&r, plan.DocRefs, &out)
	}
	return r, nil
}

// docNext は消す def を文書が名指す時の注と next（消した後は bin/fge doc-refs がその文書で止める。文書を直す道）。
func docNext(r *report, refs []Fixed, out *Outcome) {
	var shown, files []string
	seen := map[string]bool{}
	for _, d := range refs {
		if len(shown) < 3 {
			shown = append(shown, d.Why+" "+d.Sym)
		}
		file := d.Why[:strings.LastIndex(d.Why, ":")]
		if !seen[file] {
			seen[file] = true
			files = append(files, file)
		}
	}
	more := ""
	if len(refs) > len(shown) {
		more = fmt.Sprintf("…ほか %d", len(refs)-len(shown))
	}
	r.extra = append(r.extra, fmt.Sprintf("文書が名指す def %d か所（消すと doc-refs が止める）: %s%s", len(refs), strings.Join(shown, "・"), more))
	cmd := "bin/fge doc-refs " + strings.Join(files, " ")
	switch out.State {
	case StateApplied:
		r.Next, r.NextWhy = cmd, "消した名前を指す文書を直す（名指しを消すか、消した記録なら ~~ ~~ で消し線）"
	case StateDryRun:
		r.NextWhy += "。書いた後は " + cmd + " が止める所を直す"
	}
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
func constructionPlan(idx *Index, a args, shape Shape, before []string, add bool, srcs map[string]string, pick func(Row, int) string) (ConstructionPlan, error) {
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
	return PlanConstruction(ConstructionQuery{Shape: shape, Label: a.label, Add: add, Value: a.value, After: a.after, Pick: pick, Before: key, Others: others, Skip: a.skip, Defs: defs, Srcs: srcs})
}

func constructionLines(r *report, plan ConstructionPlan) {
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", s.Where(), s.Why, s.Owner))
	}
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
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
	var lp *localPicker
	var pick func(Row, int) string
	if add {
		lp, pick = constructionPicker(root, idx.Rows, srcs, shape, a, fieldTypeOf(srcs, shape, a.label))
	}
	plan, err := constructionPlan(idx, a, shape, before, add, srcs, pick)
	if err != nil {
		return report{}, err
	}
	out := Change(root, plan.Edits, a.applyWith(cfg.Verify, o))
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
		base += " --value " + shellQuote(a.value) + preferFlag(a)
	}
	nextOf(&r, base, a, &out)
	localNotes(&r, lp)
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
			r.lines = append(r.lines, fmt.Sprintf("%s\t%s\t%s\t%s", s.Where(), rw, s.Recv, s.Owner))
		}
		r.fixHint = "読み書きを口へ替える（field-to-accessor）か消してから。使われなくなった口の def は remove-dead --def で消す"
		if a.caseName == "" {
			r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor field-sites --label %s --receiver %s", a.label, a.receiver), "残っている所の一覧"
		}
		return r, nil
	}
	plan, err := constructionPlan(idx, a, shape, shape.Fields, false, srcs, nil)
	if err != nil {
		return report{}, err
	}
	label := a.label
	typeRow := rowAt(shape.File, srcs[shape.File], shape.Brace, shape.Name)
	edits := append(append([]Edit{}, plan.Edits...), Edit{File: shape.File, Start: shape.Brace, End: shape.End, Site: typeRow,
		Make: func(cur string) (string, error) { return RemoveRecordField(cur, label) }})
	out := Change(root, edits, a.applyWith(cfg.Verify, o))
	r.Outcome, r.Fix = &out, plan.Fix
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.Sites) + len(plan.Fix) + 1
	}
	r.Sites = append([]Fixed{{typeRow, "型から欄 " + label + " を消す"}}, plan.Sites...)
	r.gotText = fmt.Sprintf("直の読み書き 0・型から消す 1（%s）・組み立てから消す %d・人へ回す %d", typeRow.Where(), len(plan.Sites), len(plan.Fix))
	r.extra = append(r.extra, shapeNote(shape))
	r.wantText = fmt.Sprintf("%s に欄 %s が無く、組み立ても型と同じ欄の組（決められない所は fix）", shape.Name, label)
	r.lines = append(r.lines, fmt.Sprintf("%s\t型から欄 %s を消す", typeRow.Where(), label))
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

// fieldTypeOf は型 shape の宣言の欄 label の型の字（無ければ ""）。
func fieldTypeOf(srcs map[string]string, shape Shape, label string) string {
	src := srcs[shape.File]
	if shape.End > len(src) {
		return ""
	}
	u, _, err := ParseRecord(src[shape.Brace:shape.End])
	if err != nil {
		return ""
	}
	if k := u.Find(label); k >= 0 {
		f := u.Fields[k]
		return strings.TrimSpace(src[shape.Brace+f.VStart : shape.Brace+codeEnd(src[shape.Brace:shape.End], f)])
	}
	return ""
}

// modAt は file の pos を囲む mod（pos より前で一番近い def・型 alias・enum の宣言の mod）。
func modAt(rows []Row, file, src string, pos int) string {
	best, mod := -1, ""
	for _, r := range rows {
		if r.File != file || (r.Kind != KindDefDecl && r.Kind != KindAliasDecl && r.Kind != KindEnumDecl) {
			continue
		}
		if b, _, err := ByteRange(src, r); err == nil && b <= pos && b > best {
			best, mod = b, modOf(r.Sym)
		}
	}
	return mod
}

// constructionPicker は組み立てに --value を書く所で、同じ値の局所の名前を選ぶ部品（設計 §9）。typ は欄の型の字。
func constructionPicker(root string, rows []Row, srcs map[string]string, shape Shape, a args, typ string) (*localPicker, func(Row, int) string) {
	rs := &reshapeSources{root: root, m: srcs}
	lp := newLocalPicker(rows, rs, a.preferLocal, nil)
	want := localWant{typ: typ, file: shape.File, mod: modAt(rows, shape.File, srcs[shape.File], shape.Brace)}
	value := a.value
	return lp, func(d Row, at int) string { return lp.pick(d.Sym, d.File, at, value, want) }
}
