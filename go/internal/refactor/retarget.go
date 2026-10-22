package refactor

import (
	"fmt"
	"sort"
	"strings"
)

// retarget-field: def の本体の欄の読み `w#x` を、同じ def の別の引数の同じ名前の欄 `res#x` へ読み替える（設計
// semantic-index-design §2.6.1。ゲームの c7a02a01 で tutorial の w#tutorialDoc 20 か所を手で替えた所）。
//
//	retarget-field --label tutorialDoc[,a,b] --from w --to res [--in Mod | --def Mod.f[,Mod.g]] [--drop-from] [--apply]
//
// 当てる読み: label-select のうち受け手が引数 --from そのもの（索引の rparam=。typed の段）の物だけ。別の引数（prev#x）・
// 式（nextWorld(w)#x）・局所の名前の読みは rparam が無いか違うので書かずに並べる。受け手は rparam で決まっているので owner は見ない。
// 書く前の確かめ: --to の引数の型に欄 x があり、欄の型が --from の型の x と同じ（正規の形の字。型の変数を含む物は比べず人へ）。
// 人へ回す物: 書き込み（{ x = v | w }）・--to を持たない def（並べるだけ）・欄が無い／型が違う def（fix）。
// 読み替えると --from を読む所が 0 になる def は、既定では fix（Flix は使わない引数を誤りにする）。--drop-from は
// remove-param と同じ並びの書き換え（w を外し、呼ぶ所の w を捨てる）と読み替えを 1 つの計画にし、確かめは 1 回。
//
// WhyNot: w#x と res#x が同じ値かは道具には分からない（同じ名前・同じ型なだけ）。人が欄を名指しした時だけ当て、
// 全部の欄を自動で替える形にはしない（設計 §2.11 の 6）。

// retargetPlan は読み替えの計画。
type retargetPlan struct {
	Edits []Edit
	Freed map[paramRef]int // 読み替えで減る --from の読み（def → 数）
	Sites []Fixed          // 書く所
	Skips []Fixed          // 書かない所（人が見る。書き換えは止めない）
	Fix   []Fixed          // 人へ回す所（書き換えを止める）
	Count map[string]int   // def → 書く数
}

// retargetTarget は def ごとの読み替え先: 引数の名前と、その型の欄（欄 → 正規の形の型）。why が空でなければその def は人へ。
type retargetTarget struct {
	name   string
	fields map[string]string
	why    string
	skip   bool // --to を持たない def（並べるだけで fix にしない）
}

// planRetarget は defs の def の本体で、受け手が引数 from そのものの labels の読みを target(def) へ読み替える計画（typed の行）。
// noName は、本体に読み替え先の名前が字で出る def を人へ回すか（--propagate --retarget: 足す引数はまだ無いので、出れば局所の名前）。
// named は defs が --def で名指しした def か（名指しした def に引数 from が無ければ、黙って飛ばさずに fix。--in・全部は飛ばす）。
func planRetarget(typed []Row, srcs *reshapeSources, defs []string, labels []string, from string, pix paramIndex, tix *typeIndex,
	target func(def string) retargetTarget, noName, named bool) (retargetPlan, error) {
	rp := retargetPlan{Freed: map[paramRef]int{}, Count: map[string]int{}}
	want := map[string]bool{}
	for _, l := range labels {
		want[strings.TrimSpace(l)] = true
	}
	byDef := map[string][]Row{}
	for _, r := range typed {
		if (r.Kind == KindLabelSelect || r.Kind == KindLabelUpdate) && want[r.Sym] {
			byDef[r.Owner] = append(byDef[r.Owner], r)
		}
	}
	decls := map[string]Row{}
	for _, r := range typed {
		if r.Kind == KindDefDecl {
			if _, ok := decls[r.Sym]; !ok {
				decls[r.Sym] = r
			}
		}
	}
	for _, def := range defs {
		fp, ok := pix.named(def, from)
		if !ok {
			if named {
				rp.Fix = append(rp.Fix, Fixed{decls[def], fmt.Sprintf("--def で名指しした %s に引数 %s が無い（--from の名前を確かめる）", def, from)})
			}
			continue
		}
		rows := byDef[def]
		var reads []Row
		for _, r := range rows {
			switch {
			case r.Kind == KindLabelUpdate && r.Attr("rparam") == fmt.Sprint(fp.I):
				rp.Skips = append(rp.Skips, Fixed{r, "書かない（書き込み。読み替えるかは人）"})
			case r.Kind == KindLabelSelect && r.Attr("rparam") == fmt.Sprint(fp.I):
				reads = append(reads, r)
			// --from と同じ型の別の引数（prev#x）・--from を使う式（nextWorld(w)#x）の読みは、人が「替わるはず」と思いうるので並べる。
			case r.Kind == KindLabelSelect && (sameTypeParam(pix, tix, def, r.Attr("rparam"), fp) || len(identUses(recvText(srcs, r), map[string]bool{from: true})) > 0):
				rp.Skips = append(rp.Skips, Fixed{r, fmt.Sprintf("書かない（受け手が引数 %s そのものでない）", from)})
			}
		}
		if len(reads) == 0 {
			continue
		}
		t := target(def)
		if t.skip {
			for _, r := range reads {
				rp.Skips = append(rp.Skips, Fixed{r, "書かない（" + t.why + "）"})
			}
			continue
		}
		decl := decls[def]
		if t.why != "" {
			rp.Fix = append(rp.Fix, Fixed{decl, t.why})
			continue
		}
		bad := ""
		for _, l := range sortedKeys(want) {
			if !hasLabelRead(reads, l) {
				continue
			}
			ft, tt := fp.Fields[l], t.fields[l]
			switch {
			case tt == "":
				bad = fmt.Sprintf("%s の型に欄 %s が無い（読み替えられない）", t.name, l)
			case !tix.same(ft, tt):
				bad = fmt.Sprintf("欄 %s の型が違う（%s#%s は %s・%s#%s は %s。型の変数を含む物は比べない）", l, from, l, orUnknown(ft), t.name, l, tt)
			}
		}
		if bad != "" {
			rp.Fix = append(rp.Fix, Fixed{decl, bad})
			continue
		}
		if noName {
			if ext, err := defText(srcs, decl); err == nil && len(identUses(ext, map[string]bool{t.name: true})) > 0 {
				rp.Fix = append(rp.Fix, Fixed{decl, fmt.Sprintf("本体に名前 %s がある（局所の %s があると、読み替えた %s#… が局所を読む。読み替えずに人へ。名前の影は段 3 の binder で見る）", t.name, t.name, t.name)})
				continue
			}
		}
		// 同じ受け手の範囲は 1 つにまとめる（同じ範囲の 2 つは ApplyEdits が計画ごと落とす。レビュー 3 の L1）。
		seen := map[string]bool{}
		sort.Slice(reads, func(i, j int) bool { return less(reads[i], reads[j]) })
		for _, r := range reads {
			sp, err := spanOf(r.File, r.Attr("rspan"))
			if err != nil {
				return rp, fmt.Errorf("%s: 索引の rspan が読めない（%v）", r.Where(), err)
			}
			k := fmt.Sprintf("%s %d:%d", sp.File, sp.Line, sp.Col)
			if seen[k] {
				continue
			}
			seen[k] = true
			src, err := srcs.get(r.File)
			if err != nil {
				return rp, err
			}
			s, e, err := ByteRange(src, sp)
			if err != nil {
				return rp, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", r.Where())
			}
			to := t.name
			rp.Edits = append(rp.Edits, Edit{File: r.File, Start: s, End: e, Site: r,
				Check:  []Want{{Span: sp, Text: from}},
				Writes: map[string]int{to: 1},
				Make: func(cur string) (string, error) {
					if cur != from {
						return "", fmt.Errorf("受け手の字が %q（%s のはず。索引が古い）", cur, from)
					}
					return to, nil
				}})
			rp.Sites = append(rp.Sites, Fixed{r, fmt.Sprintf("%s#%s → %s#%s", from, r.Sym, to, r.Sym)})
			rp.Freed[paramRef{def, fp.I}]++
			rp.Count[def]++
		}
	}
	return rp, nil
}

// sameTypeParam は rparam（受け手が def の何番目の引数か）が from と別の、同じ型の引数を指すか。
func sameTypeParam(pix paramIndex, tix *typeIndex, def, rparam string, from paramInfo) bool {
	if rparam == "" || rparam == fmt.Sprint(from.I) {
		return false
	}
	for _, p := range pix[def] {
		if fmt.Sprint(p.I) == rparam {
			return tix.same(p.Type, from.Type)
		}
	}
	return false
}

func hasLabelRead(rows []Row, label string) bool {
	for _, r := range rows {
		if r.Sym == label {
			return true
		}
	}
	return false
}

// recvText は label-* の受け手の字（rspan。読めなければ ""）。
func recvText(srcs *reshapeSources, r Row) string {
	sp, err := spanOf(r.File, r.Attr("rspan"))
	if err != nil {
		return ""
	}
	src, err := srcs.get(r.File)
	if err != nil {
		return ""
	}
	t, err := SpanText(src, sp)
	if err != nil {
		return ""
	}
	return t
}

// defText は def の宣言の全体の字（ext）。
func defText(srcs *reshapeSources, decl Row) (string, error) {
	sp, err := spanOf(decl.File, decl.Attr("ext"))
	if err != nil {
		return "", err
	}
	src, err := srcs.get(decl.File)
	if err != nil {
		return "", err
	}
	return SpanText(src, sp)
}

// retargetReport は retarget-field の入口（typed の段）。
func retargetReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	pix, tix := newParamIndex(idx.Rows), newTypeIndex(idx.Rows)
	defs, err := retargetDefs(idx.Rows, a)
	if err != nil {
		return report{}, err
	}
	labels := strings.Split(a.label, ",")
	target := func(def string) retargetTarget {
		tp, ok := pix.named(def, a.to)
		if !ok {
			return retargetTarget{skip: true, why: fmt.Sprintf("引数 %s を持たない def", a.to)}
		}
		f := tp.Fields
		if len(f) == 0 {
			return retargetTarget{name: a.to, why: fmt.Sprintf("引数 %s の型 %s が record でない（欄が無い）", a.to, tp.Type)}
		}
		return retargetTarget{name: a.to, fields: f}
	}
	rp, err := planRetarget(idx.Rows, srcs, defs, labels, a.from, pix, tix, target, false, a.def != "")
	if err != nil {
		return report{}, err
	}
	edits := rp.Edits
	fix := append([]Fixed{}, rp.Fix...)
	sites := append([]Fixed{}, rp.Sites...)
	var dropped []string
	if a.dropFrom {
		// 読み替えで --from が空く def ごとに、w を外す並びの問い（呼ぶ所の w も捨てる）。読み替えは内側の書き換え。
		var qs []SignatureQuery
		for _, def := range sortedKeys(rp.Count) {
			fp, _ := pix.named(def, a.from)
			if fp.Hidden || rp.Count[def] < fp.Reads {
				continue
			}
			var keep []string
			for _, p := range pix[def] {
				if p.Name != a.from {
					keep = append(keep, p.Name)
				}
			}
			if len(keep) == 0 {
				fix = append(fix, Fixed{fp.Row, fmt.Sprintf("引数が %s だけの def（外すと引数が無くなる。人へ）", a.from)})
				continue
			}
			qs = append(qs, SignatureQuery{Defs: []string{def}, Params: strings.Join(keep, ", "), Templates: keep})
			dropped = append(dropped, def)
		}
		if len(qs) > 0 {
			plan, err := PlanSignaturesWith(idx.Rows, srcs, qs, rp.Edits, rp.Freed)
			if err != nil {
				return report{}, err
			}
			edits = plan.Edits
			fix = append(fix, plan.Fix...)
			sites = append(sites, plan.Sites...)
		} else {
			fix = append(fix, freedFixes(idx.Rows, nil, nil, rp.Freed)...)
		}
	} else {
		fix = append(fix, freedFixes(idx.Rows, nil, nil, rp.Freed)...)
	}
	fix = sortedFixed(fix)
	how := a.applyWith(cfg.Verify, o)
	if len(fix) > 0 {
		how.On = false
	}
	out := Change(root, edits, how)
	if a.apply && len(fix) > 0 {
		out.State, out.Reason = StateRefused, fmt.Sprintf("人へ回す所 %d（書くと型が合わない・決められない。直してから --apply）", len(fix))
	}
	n := len(rp.Edits)
	r := report{Op: "retarget-field", Target: fmt.Sprintf("%s#%s → %s#%s", a.from, a.label, a.to, a.label), code: CodeSignature, Outcome: &out, Fix: fix}
	r.got = len(fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = n
	}
	r.Sites = sites
	r.gotText = fmt.Sprintf("読み替え %d（def %d）・%s を外す def %d・書かない所 %d・人へ回す %d", n, len(rp.Count), a.from, len(dropped), len(rp.Skips), len(fix))
	r.wantText = "受け手が引数 " + a.from + " そのものの読みが " + a.to + " の同じ欄（決められない所は fix。fix があれば書かない）"
	for _, f := range fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	for _, s := range sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", s.Where(), s.Why, s.Owner))
	}
	for _, s := range sortedFixed(rp.Skips) {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", s.Where(), s.Why, s.Owner))
	}
	base := fmt.Sprintf("bin/fge refactor retarget-field --label %s --from %s --to %s", a.label, a.from, a.to)
	if a.def != "" {
		base += " --def " + a.def
	}
	if a.in != "" {
		base += " --in " + a.in
	}
	if a.dropFrom {
		base += " --drop-from"
	}
	nextOf(&r, base, a, &out)
	switch {
	case len(fix) > 0:
		r.fixHint = "fix の def を手で直すか、--drop-from（w が空く def）・--def で外してから"
		r.Next, r.NextWhy = base, "fix を直してから dry-run から（fix が 0 になれば --apply）"
	case out.State == StateApplied:
		r.Done = fmt.Sprintf("done: %d sites（読み替え %d）→ 0 left · check ok", n, n)
		// 書いた所は消し、書かなかった所（人が見る）だけ残す。
		r.lines = nil
		for _, s := range sortedFixed(rp.Skips) {
			r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", s.Where(), s.Why, s.Owner))
		}
	}
	return r, nil
}

// retargetDefs は retarget-field の def の範囲（--def の名前・--in の mod の def・どちらも無ければ全部）。
func retargetDefs(rows []Row, a args) ([]string, error) {
	var out []string
	if a.def != "" {
		for _, d := range strings.Split(a.def, ",") {
			sym, err := Resolve(rows, strings.TrimSpace(d), map[string]bool{KindDefDecl: true})
			if err != nil {
				return nil, err
			}
			out = append(out, sym)
		}
		return out, nil
	}
	seen := map[string]bool{}
	for _, r := range rows {
		if r.Kind != KindDefDecl || seen[r.Sym] {
			continue
		}
		if a.in != "" && modOf(r.Sym) != a.in && !strings.HasPrefix(r.Sym, a.in+".") {
			continue
		}
		seen[r.Sym] = true
		out = append(out, r.Sym)
	}
	sort.Strings(out)
	return out, nil
}

// retargetEdits は change-signature --retarget の読み替え（葉の def だけ。レビュー 3 の L4）: 足す引数 to（--params の @名前）の
// 型を葉のファイルで引いた alias の欄（alias-decl の fields=）を読み替え先にする。
func retargetEdits(resolved, typed []Row, srcs *reshapeSources, leaf SignatureQuery, part *sigPart, labels []string, from string) (retargetPlan, error) {
	if len(part.locals) != 1 {
		return retargetPlan{}, fmt.Errorf("--retarget は --args の @名前 が 1 つの時だけ（読み替え先の引数が決まらない。今は %d 個）", len(part.locals))
	}
	to := part.locals[0]
	first := part.defs[leaf.Defs[0]]
	// `@名前=式` の式が --from を読むと、読み替え（内側の書き換え）が先に本体の式の中の from#… を替え、本体の式を名前へ
	// 替える規則に当たらずに意味が変わる（`Res.make(w#doc)` → `Res.make(res#doc)`。レビュー 2a の中-2）。読み替えずに断る。
	for i, e := range part.fallback {
		if len(identUses(e, map[string]bool{from: true})) > 0 {
			return retargetPlan{Fix: []Fixed{{first.row, fmt.Sprintf("--args の @%s=式 の式が --from の %s を読む（`%s`。--retarget の読み替えが先に本体の式の中の %s#… を替え、本体の式を %s に替えられずに意味が変わる）。--retarget を外して流すか、式を %s を読まない形にする",
				strings.TrimPrefix(part.q.Templates[i], "@"), from, oneLine(e), from, to, from)}}}, nil
		}
	}
	tixR := newTypeIndex(resolved)
	typ := ""
	for i, n := range part.news {
		if n == to {
			typ = first.types[part.news[i]]
		}
	}
	sym, err := tixR.resolveIn(typ, first.row.File, modOf(leaf.Defs[0]))
	if err != nil {
		return retargetPlan{}, fmt.Errorf("--retarget: %s の型: %v", to, err)
	}
	fields := tixR.fieldsOf(sym)
	if len(fields) == 0 {
		return retargetPlan{}, fmt.Errorf("--retarget: %s の型 %s が record の alias でない（欄が引けない）", to, sym)
	}
	target := func(string) retargetTarget { return retargetTarget{name: to, fields: fields} }
	return planRetarget(typed, srcs, leaf.Defs, labels, from, newParamIndex(typed), newTypeIndex(typed), target, true, true)
}
