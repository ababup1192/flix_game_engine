package refactor

// field-to-accessor の入口: 欄ごとに口の名前を決め（無い口は作る）、直の読み書きを口へ替える計画を作り、
// 全部の欄の書き換えを 1 つの patch にして Change へ渡す（確かめは最後に 1 回・落ちれば全部戻す）。
//
// 口の名前は「置く mod」と「def の名前」に分けて持つ（AccessorName）。--getter 等に修飾つき（`World.xOf`）・
// なし（`xOf`）のどちらが来ても accessorNameOf で同じ形に揃え、書く字は所ごとに spellAt が決める。

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// accessorLabel は 1 欄ぶんの計画。
type accessorLabel struct {
	label                  string
	alias                  string
	reader, mapper, setter AccessorName
	plan                   AccessorPlan
	stub                   *StubPlace // 口を作る所（作らなければ nil）
	stubText               string
	made                   []string // 作る口の名前（索引の名前）
	typeNote               string
	typeOK                 bool // 口の戻りの型と欄の型が同じと確かめた
}

// labelsOf は --label a,b,c と --labels-file（1 行 1 欄・# から後は注）の欄を、重ねずに書いた順で返す。
func labelsOf(root string, a args) ([]string, error) {
	var raw []string
	raw = append(raw, strings.Split(a.label, ",")...)
	if a.labelsFile != "" {
		path := a.labelsFile
		if !filepath.IsAbs(path) {
			path = filepath.Join(root, path)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("--labels-file: %v", err)
		}
		for _, l := range strings.Split(string(b), "\n") {
			if i := strings.IndexByte(l, '#'); i >= 0 {
				l = l[:i]
			}
			raw = append(raw, strings.Split(l, ",")...)
		}
	}
	var out []string
	seen := map[string]bool{}
	for _, l := range raw {
		l = strings.TrimSpace(l)
		if l == "" || seen[l] {
			continue
		}
		if !isIdent(l) {
			return nil, fmt.Errorf("欄の名前でない: %q", l)
		}
		seen[l] = true
		out = append(out, l)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("欄がありません（--label a,b,c か --labels-file）")
	}
	return out, nil
}

// accessorNameOf は渡された口の名前（`World.xOf` か `xOf`）を AccessorName にする。修飾なしの名前は alias の mod の
// 中の物（`xOf` は `World.xOf` と同じ。別の mod の同じ名前の def は当てない）。索引に在る def ならそれ、無ければ
// alias の mod に作る物（canMake の時だけ。mod を書いたなら alias の mod と同じ時だけ）。exists は索引に在ったか。
func accessorNameOf(rows []Row, given, aliasMod string, canMake bool) (AccessorName, bool, error) {
	if given == "" {
		return AccessorName{}, false, nil
	}
	if !strings.Contains(given, ".") && aliasMod != "" {
		given = aliasMod + "." + given
	}
	if hasDef(rows, given) {
		return splitSym(given), true, nil
	}
	sym, err := Resolve(rows, given, map[string]bool{KindDefDecl: true})
	if err == nil {
		return splitSym(sym), true, nil
	}
	if !canMake || !strings.Contains(err.Error(), "索引にありません") {
		return AccessorName{}, false, err
	}
	if m := modOf(given); m != "" && !nameMatches(aliasMod, m) {
		return AccessorName{}, false, fmt.Errorf("口 %s が無い。無い口は受け手の alias の mod（%s）にだけ作る（%s の中に置くなら手で書いて名指し）", given, aliasMod, m)
	}
	return AccessorName{Mod: aliasMod, Name: shortName(given)}, false, nil
}

func hasDef(rows []Row, sym string) bool {
	for _, r := range rows {
		if r.Kind == KindDefDecl && r.Sym == sym {
			return true
		}
	}
	return false
}

// accessorSources は計画に要るファイルの中身（読んだ物は使い回す）。
type accessorSources struct {
	root string
	cfg  Config
	srcs map[string]string
	all  map[string]string // 索引に入れるフォルダの全部（口を作る時だけ読む）
}

func (s *accessorSources) load(f string) error {
	if _, ok := s.srcs[f]; ok || f == "" {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(s.root, f))
	if err != nil {
		return err
	}
	s.srcs[f] = string(b)
	return nil
}

func (s *accessorSources) everything() (map[string]string, error) {
	if s.all == nil {
		all, err := loadSources(s.root, s.cfg)
		if err != nil {
			return nil, err
		}
		s.all = all
	}
	return s.all, nil
}

// planAccessorLabel は 1 欄の計画（口の名前を決め、無い口を作る所と字、型の確かめ、書き換え）。
func planAccessorLabel(idx *Index, a args, label string, src *accessorSources) (accessorLabel, error) {
	j := accessorLabel{label: label}
	// 口を置く alias: --receiver を alias の sym（別名は鎖の終わり）に決め、その欄の読み書きが 1 つでも証明できていれば使う。
	t := AliasTarget(idx.Rows, a.receiver)
	for _, r := range idx.Rows {
		if (r.Kind == KindLabelSelect || r.Kind == KindLabelUpdate) && r.Sym == label && fieldSiteOf(r).Class(t) == ClassHit {
			j.alias = strings.TrimPrefix(fieldSiteOf(r).Recv, "alias:")
			break
		}
	}
	aliasMod := modOf(j.alias)
	canMake := j.alias != ""
	getter, setter := a.reader, a.setter
	if canMake && getter == "" {
		getter = DefaultGetter(label)
	}
	if canMake && a.mapper == "" && setter == "" {
		setter = DefaultSetter(label)
	}
	var missing []AccessorName
	q := AccessorQuery{Label: label, Receiver: a.receiver, Outside: a.outside, Skip: a.skip, Home: a.outside}
	if q.Home == "" {
		q.Home = aliasMod
	}
	var readerRow Row
	for _, slot := range []struct {
		given string
		into  *AccessorName
		make  bool
	}{{getter, &j.reader, true}, {a.mapper, &j.mapper, false}, {setter, &j.setter, true}} {
		n, exists, err := accessorNameOf(idx.Rows, slot.given, aliasMod, canMake && slot.make)
		if err != nil {
			return j, fmt.Errorf("口 %s: %v", slot.given, err)
		}
		*slot.into = n
		if n.IsZero() {
			continue
		}
		if !exists {
			missing = append(missing, n)
			continue
		}
		q.OwnerSyms = append(q.OwnerSyms, n.Sym())
		if slot.into == &j.reader {
			for _, r := range idx.Rows {
				if r.Kind == KindDefDecl && r.Sym == n.Sym() {
					readerRow = r
				}
			}
		}
	}
	q.Reader, q.Mapper, q.Setter = j.reader, j.mapper, j.setter
	for _, r := range idx.Rows {
		if (r.Kind == KindLabelSelect || r.Kind == KindLabelUpdate) && r.Sym == label {
			if err := src.load(r.File); err != nil {
				return j, err
			}
		}
	}
	if err := src.load(readerRow.File); err != nil {
		return j, err
	}
	readerType, rok := "", false
	if ext := readerRow.Attr("ext"); ext != "" {
		if span, err := spanOf(readerRow.File, ext); err == nil {
			if text, err := SpanText(src.srcs[readerRow.File], span); err == nil {
				readerType, rok = DefReturnType(text)
			}
		}
	}
	fieldType, fok := aliasFieldTypeIn(src.root, src.cfg, j.alias, label)
	if len(missing) > 0 {
		var names []string
		for _, m := range missing {
			names = append(names, m.Sym())
		}
		if !fok {
			return j, fmt.Errorf("口 %s が無く、欄 %s の型が %s の宣言から読めないので作れない（口を手で書いて --getter・--setter で名指し）", strings.Join(names, "・"), label, j.alias)
		}
		all, err := src.everything()
		if err != nil {
			return j, err
		}
		shape, err := FindAliasShape(all, j.alias)
		if err != nil {
			return j, err
		}
		place, err := FindStubPlace(idx.Rows, all, aliasMod, shape)
		if err != nil {
			return j, err
		}
		g, s := "", ""
		for _, m := range missing {
			if m == j.reader {
				g = m.Name
			} else {
				s = m.Name
			}
		}
		if err := src.load(place.File); err != nil {
			return j, err
		}
		j.stub, j.stubText, j.made = &place, AccessorStubs(place.Indent, shortName(j.alias), label, fieldType, g, s), names
		if g != "" {
			readerType, rok = fieldType, true
		}
	}
	reader := j.reader.Sym()
	switch {
	case rok && fok && SameType(readerType, fieldType):
		j.typeOK = true
		j.typeNote = fmt.Sprintf("型: %s の戻り %s = 欄 %s の %s", reader, readerType, label, fieldType)
	case rok && fok:
		q.TypeWhy = fmt.Sprintf("口 %s の戻り %s と欄の型 %s が違う（読む側の組み替えは人）", reader, readerType, fieldType)
		j.typeNote = "型: " + q.TypeWhy
	case rok:
		j.typeNote = fmt.Sprintf("型: %s の戻り %s・欄の型は %s の宣言が見つからず確かめられない（make check に任せる）", reader, readerType, j.alias)
	default:
		j.typeNote = "型: 確かめられない（make check に任せる）"
	}
	plan, err := PlanAccessor(src.srcs, idx.Rows, q)
	if err != nil {
		return j, err
	}
	if plan.Reads+plan.Writes == 0 {
		j.stub, j.made = nil, nil
	}
	j.plan = plan
	return j, nil
}

// mergeAccessorEdits は欄ごとの書き換えを 1 つにまとめる。同じ範囲の書き換え（2 つの欄を一緒に書く
// `{ a = 1, b = 2 | w }`）は順に重ねて 1 つにし、同じ所に足す口は字をつなげて 1 つにする。
func mergeAccessorEdits(jobs []accessorLabel) []Edit {
	type key struct {
		file       string
		start, end int
	}
	var order []key
	by := map[key][]Edit{}
	stubs := map[key]string{}
	stubAt := map[key]Row{}
	for _, j := range jobs {
		for _, e := range j.plan.Edits {
			k := key{e.File, e.Start, e.End}
			if len(by[k]) == 0 {
				order = append(order, k)
			}
			by[k] = append(by[k], e)
		}
		if j.stub != nil {
			k := key{j.stub.File, j.stub.Pos, j.stub.Pos}
			if _, ok := stubs[k]; !ok {
				order = append(order, k)
				stubAt[k] = j.stub.At
			}
			stubs[k] += j.stubText
		}
	}
	var out []Edit
	for _, k := range order {
		if text, ok := stubs[k]; ok {
			if len(by[k]) > 0 {
				// 長さ 0 の書き換えは口だけ（欄の書き換えはいつも欄の字を含む）なので、ここへは来ない。
				panic("口を足す所に欄の書き換えが重なった")
			}
			out = append(out, stubEdit(StubPlace{File: k.file, Pos: k.start, At: stubAt[k]}, text))
			continue
		}
		es := by[k]
		if len(es) == 1 {
			out = append(out, es[0])
			continue
		}
		merged := es[0]
		makes := make([]func(string) (string, error), len(es))
		for i, e := range es {
			makes[i] = e.Make
			if i > 0 {
				merged.Check = append(append([]Want{}, merged.Check...), e.Check...)
			}
		}
		merged.Make = func(cur string) (string, error) {
			for _, m := range makes {
				var err error
				if cur, err = m(cur); err != nil {
					return "", err
				}
			}
			return cur, nil
		}
		out = append(out, merged)
	}
	return out
}

// accessorReport は field-to-accessor の入口。
func accessorReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	labels, err := labelsOf(root, a)
	if err != nil {
		return report{}, err
	}
	if len(labels) > 1 && (a.reader != "" || a.mapper != "" || a.setter != "") {
		return report{}, fmt.Errorf("欄が 2 つ以上の時は口の名前を渡せない（欄ごとに既定の <欄>Of・with<欄> を使い、無ければ作る）")
	}
	src := &accessorSources{root: root, cfg: cfg, srcs: map[string]string{}}
	var jobs []accessorLabel
	for _, l := range labels {
		j, err := planAccessorLabel(idx, a, l, src)
		if err != nil {
			if len(labels) > 1 {
				return report{}, fmt.Errorf("欄 %s: %v", l, err)
			}
			return report{}, err
		}
		jobs = append(jobs, j)
	}
	out := Change(root, mergeAccessorEdits(jobs), a.applyWith(cfg.Verify, o))
	alias := jobs[0].alias
	home := a.outside
	if home == "" {
		home = modOf(alias)
	}
	if home == "" {
		home = a.receiver
	}
	r := report{Op: "field-to-accessor", Target: a.receiver + "#" + strings.Join(labels, ","), Sym: alias, code: CodeAccessor, Outcome: &out}
	var t AccessorPlan // 全部の欄の和
	var made, mismatch []string
	var stubAt string
	var rewrites []Fixed
	for _, j := range jobs {
		p := j.plan
		t.Sites, t.Reads, t.Writes, t.Folded, t.Inside, t.Left, t.Unsure = t.Sites+p.Sites, t.Reads+p.Reads, t.Writes+p.Writes, t.Folded+p.Folded, t.Inside+p.Inside, t.Left+p.Left, t.Unsure+p.Unsure
		t.Fix = append(t.Fix, p.Fix...)
		rewrites = append(rewrites, p.Rewrites...)
		made = append(made, j.made...)
		if j.stub != nil && stubAt == "" {
			stubAt = j.stub.At.Where()
		}
		if !j.typeOK && len(jobs) > 1 {
			mismatch = append(mismatch, j.label+": "+j.typeNote)
		}
	}
	sort.Slice(t.Fix, func(i, j int) bool { return less(t.Fix[i].Row, t.Fix[j].Row) })
	r.Fix = t.Fix
	r.got = len(t.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = t.Sites
	}
	r.Sites = rewrites
	count := func(p AccessorPlan) string {
		return fmt.Sprintf("直の読み書き %d・口へ替える %d（読み %d・書き %d。うち書きの lambda に畳む読み %d）・人へ回す %d",
			p.Sites, p.Reads+p.Writes, p.Reads, p.Writes, p.Folded, len(p.Fix))
	}
	r.gotText = count(t)
	if len(jobs) > 1 {
		r.gotText = fmt.Sprintf("欄 %d・", len(jobs)) + r.gotText
		for _, j := range jobs {
			r.gotText += fmt.Sprintf("\n  %s: 直 %d → 口 %d（読み %d・書き %d）・人へ %d", j.label, j.plan.Sites, j.plan.Reads+j.plan.Writes, j.plan.Reads, j.plan.Writes, len(j.plan.Fix))
		}
	}
	if t.Inside > 0 {
		r.extra = append(r.extra, fmt.Sprintf("口の def の中・--outside の mod の中の物 %d は替えない", t.Inside))
	}
	if len(jobs) == 1 {
		r.extra = append(r.extra, jobs[0].typeNote)
	} else if len(mismatch) > 0 {
		r.extra = append(r.extra, mismatch...)
	}
	switch {
	case len(made) > 0:
		r.extra = append(r.extra, fmt.Sprintf("口を作る: %s（%s の後）", strings.Join(made, "・"), stubAt))
	case len(jobs) == 1 && jobs[0].plan.Reads+jobs[0].plan.Writes == 0 && t.Sites > 0:
		r.extra = append(r.extra, "口は作らない（替える読み書きが 0）")
	}
	r.wantText = fmt.Sprintf("%s の欄 %s の直の読み書き 0（口の中を除く。決められない所は fix）", a.receiver, strings.Join(labels, ","))
	for _, f := range t.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	base := fmt.Sprintf("bin/fge refactor field-to-accessor --label %s --receiver %s", strings.Join(labels, ","), a.receiver)
	if len(jobs) == 1 {
		j := jobs[0]
		base += " --getter " + j.reader.Sym()
		if !j.mapper.IsZero() {
			base += " --mapper " + j.mapper.Sym()
		}
		if !j.setter.IsZero() {
			base += " --setter " + j.setter.Sym()
		}
	}
	if a.outside != "" {
		base += " --outside " + a.outside
	}
	nextOf(&r, base, a, &out)
	if out.State != StateApplied {
		for _, w := range rewrites {
			r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", w.Where(), w.Why, w.Owner))
		}
		return r, nil
	}
	// 当てた後は、口の外に残った物だけを並べ（替えた所は patch にある）、最後の行で言い切る。
	r.Done = fmt.Sprintf("done: %d sites → %d left outside %s · check ok", t.Sites, t.Left, home)
	if t.Unsure > 0 {
		r.Done += fmt.Sprintf(" · 受け手の型が決まらない %d は数えていない（fix に並べた）", t.Unsure)
	}
	r.Next, r.NextWhy = "", ""
	for _, j := range jobs {
		if j.plan.Left > 0 {
			r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor field-sites --label %s --receiver %s --outside %s", j.label, a.receiver, home), "残った所を直してから。索引は作り直しになる"
			break
		}
	}
	return r, nil
}
