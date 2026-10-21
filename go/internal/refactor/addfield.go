package refactor

import (
	"fmt"
	"strings"
)

// add-field: record の型 alias（`type alias T = { … }`）に欄 x = U を足し、T を組み立てる式すべてに x = <式> を足す
// （設計 §10）。remove-field の逆で、型と組み立てを 1 つの patch にして確かめを 1 回流す（落ちれば全部戻す）。
//
// 組み立ての当て方は fix-construction と同じ（閉じた record の式の欄の組が、足す前の型の欄の組とちょうど同じ物。
// 型の別名を通した物も拾い、欄の組が同じ別の型があれば fix）。`{ … | e }` の更新は欄が要らないので触らない。
// 書く式は呼ぶ所の局所の名前を選ぶ部品（prefer.go）を通す。resolved の索引で足りる。

func addFieldReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	srcs, err := loadSources(root, cfg)
	if err != nil {
		return report{}, err
	}
	shape, err := FindAliasShape(srcs, a.receiver)
	if err != nil {
		return report{}, err
	}
	switch {
	case shape.Has(a.label):
		return report{}, fmt.Errorf("型 %s（%s）に欄 %s はもうある（組み立てだけ合わせるなら fix-construction --label %s --receiver %s --value <式>）", shape.Name, shape.File, a.label, a.label, a.receiver)
	case a.after != "" && !shape.Has(a.after):
		return report{}, fmt.Errorf("型 %s に --after の欄 %s が無い（欄: %s）", shape.Name, a.after, strings.Join(shape.Fields, "・"))
	}
	lp, pick := constructionPicker(root, idx.Rows, srcs, shape, a, a.typ)
	plan, err := constructionPlan(idx, a, shape, shape.Fields, true, srcs, pick)
	if err != nil {
		return report{}, err
	}
	label, typ, after := a.label, a.typ, a.after
	typeRow := rowAt(shape.File, srcs[shape.File], shape.Brace, shape.Name)
	edits := append([]Edit{{File: shape.File, Start: shape.Brace, End: shape.End, Site: typeRow,
		Make: func(cur string) (string, error) { return InsertRecordField(cur, label, typ, after) }}}, plan.Edits...)
	out := Change(root, edits, a.applyWith(cfg.Verify, o))
	r := report{Op: "add-field", Target: shape.Name + "#" + label, code: CodeAddField, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.Sites) + len(plan.Fix) + 1
	}
	r.Sites = append([]Fixed{{typeRow, "型に欄 " + label + " = " + typ + " を足す"}}, plan.Sites...)
	where := "最後"
	if after != "" {
		where = after + " の次"
	}
	r.gotText = fmt.Sprintf("型に足す 1（%s・%s）・組み立てに足す %d・人へ回す %d", typeRow.Where(), where, len(plan.Sites), len(plan.Fix))
	if plan.Already > 0 {
		r.gotText += fmt.Sprintf("・もう欄 %s のある組み立て %d", label, plan.Already)
	}
	r.extra = append(r.extra, shapeNote(shape))
	r.wantText = fmt.Sprintf("%s に欄 %s があり、組み立ても型と同じ欄の組（決められない所は fix）", shape.Name, label)
	r.lines = append(r.lines, fmt.Sprintf("%s\t型に欄 %s = %s を足す", typeRow.Where(), label, typ))
	constructionLines(&r, plan)
	base := fmt.Sprintf("bin/fge refactor add-field --receiver %s --label %s --type %s --value %s", a.receiver, label, shellQuote(typ), shellQuote(a.value))
	if after != "" {
		base += " --after " + after
	}
	base += preferFlag(a)
	nextOf(&r, base, a, &out)
	if out.State == StateApplied {
		r.Done = fmt.Sprintf("done: %d sites（型 1・組み立て %d）→ %d left · check ok", len(plan.Sites)+1, len(plan.Sites), len(plan.Fix))
		r.Next, r.NextWhy = "bin/fge refactor usages "+a.receiver+"#"+label, "足した欄の読み書き・組み立て（typed の索引）"
		r.lines = nil
	}
	localNotes(&r, lp)
	return r, nil
}
