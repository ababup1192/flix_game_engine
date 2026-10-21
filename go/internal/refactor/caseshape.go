package refactor

import (
	"fmt"
	"strings"
)

// change-case-shape: enum の case の欄（payload）の形を変え、宣言・作る所（`E.C(a, b)`）・当てる所（`case E.C(x, _)`）を
// 一緒に直す。欄は位置で数える（0 から。コンパイラの case の型の並びと同じ）。
//
//	--add T [--at N] --value V   N 番目（既定は最後）に型 T の欄を足す。作る所は V、当てる所は `_`。
//	                             中身の無い case（`case Fight`）には `(T)` が付き、record の payload を持たせるのも
//	                             `--add '{ a = A }' --value '{ a = x }'` の 1 回
//	--remove N                   N 番目の欄を消す。最後の 1 つなら中身の無い case になる（`case Fight`）。
//	                             当てる所の欄が `_`・使わない変数でなければ fix
//	--label x --type T --value V payload の record（`case C({ … })`）に欄 x を足す。作る所は record の式に x = V。
//	                             当てる所は record を丸ごと束ねる形（`C(m)`）ならそのまま
//
// 人へ回す所（fix）: case を関数として渡す所（`List.map(E.C, xs)`。lambda で包むかは人）・引数の数が宣言と違う・
// 消す欄を本体が使う・record の式でない payload に欄を足す。fix が 1 つでもあれば書かない（書くと型が合わない）。
// 欄を消す時、作る所の式は捨てる（式が名前・字の値でなければ数を注に出す。副作用のある式なら手で）。

// CaseShapeQuery は change-case-shape の問い。
type CaseShapeQuery struct {
	Cases  []string // 索引の case の名前（解決済み）
	Mode   string   // add・remove・label
	At     int      // add: 足す位置（-1 は最後）・remove: 消す位置
	Type   string   // add・label: 欄の型
	Value  string   // add・label: 作る所に入れる式
	Label  string   // label: 足す欄の名前
	Arity  map[string]int
	Shapes map[string]string // case → 今の欄の並び（報告用）
}

// CaseShapePlan は change-case-shape の計画。
type CaseShapePlan struct {
	Edits                      []Edit
	Sites                      []Fixed
	Fix                        []Fixed
	Decls, Constructs, Matches int
	Kept                       int // label: 替えずに済む当てる所（record を丸ごと束ねる）
	Dropped                    int // remove: 捨てた作る所の式のうち、名前・字の値でない物
}

// PlanCaseShape は q.Cases の欄の形を変える計画。
func PlanCaseShape(rows []Row, srcs *reshapeSources, q CaseShapeQuery) (CaseShapePlan, error) {
	var p CaseShapePlan
	args := argRowsAt(rows)
	var arms []Row
	for _, r := range rows {
		if r.Kind == "match-arm" {
			arms = append(arms, r)
		}
	}
	for _, sym := range q.Cases {
		var decl *Row
		for i := range rows {
			if rows[i].Kind == KindCaseDecl && rows[i].Sym == sym {
				decl = &rows[i]
				break
			}
		}
		if decl == nil {
			return p, fmt.Errorf("case %s の宣言が索引に無い（パッケージの case は直せない）", sym)
		}
		src, err := srcs.get(decl.File)
		if err != nil {
			return p, err
		}
		_, nameEnd, err := ByteRange(src, *decl)
		if err != nil {
			return p, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", decl.Where())
		}
		list, has, err := argsAfter(src, nameEnd)
		if err != nil {
			return p, fmt.Errorf("%s: case %s の宣言の %v", decl.Where(), sym, err)
		}
		arity := len(list.Args)
		if arity != decl.AttrInt("arity") {
			return p, fmt.Errorf("索引が古い: %s の欄の数が %d（索引では %s）", decl.Where(), arity, decl.Attr("arity"))
		}
		q.Arity[sym] = arity
		var types []string
		for _, a := range list.Args {
			types = append(types, src[a[0]:a[1]])
		}
		q.Shapes[sym] = "(" + strings.Join(types, ", ") + ")"
		if arity == 0 {
			q.Shapes[sym] = "（中身なし）"
		}
		at := q.At
		switch q.Mode {
		case "add":
			if at < 0 || at > arity {
				if at > arity {
					return p, fmt.Errorf("case %s の欄は %d 個: --at は 0〜%d", sym, arity, arity)
				}
				at = arity
			}
		case "remove":
			if at >= arity {
				if arity == 0 {
					return p, fmt.Errorf("case %s に欄が無い（消す物が無い）", sym)
				}
				return p, fmt.Errorf("case %s の欄は %d 個: --remove は 0〜%d", sym, arity, arity-1)
			}
		case "label":
			if arity != 1 || !strings.HasPrefix(src[list.Args[0][0]:list.Args[0][1]], "{") {
				return p, fmt.Errorf("case %s の payload が record 1 つでない（`case C({ … })` の形だけ。位置の欄は --add）", sym)
			}
		}
		short := sym[strings.LastIndex(sym, ".")+1:]
		check := func(r Row, s string) []Want {
			t, _ := SpanText(s, r)
			return []Want{{Span: r, Text: t}}
		}
		add := func(r Row, s string, l ArgList, has bool, text, why string) {
			_, ne, _ := ByteRange(s, r)
			st, en, repl, err := listEdit(s, ne, l, has, q.Mode == "add", at, text)
			if err != nil {
				p.Fix = append(p.Fix, Fixed{r, err.Error()})
				return
			}
			p.Edits = append(p.Edits, Edit{File: r.File, Start: st, End: en, Site: r, Check: check(r, s),
				Make: func(string) (string, error) { return repl, nil }})
			p.Sites = append(p.Sites, Fixed{r, why})
			if r.Kind == KindCasePattern {
				end := ne
				if has {
					end = l.Close + 1
				}
				if gap := alignGap(s, end, len(repl)-(en-st)); gap != nil {
					gap.File, gap.Site = r.File, r
					p.Edits = append(p.Edits, *gap)
				}
			}
		}
		// 宣言
		switch q.Mode {
		case "label":
			a := list.Args[0]
			label, typ := q.Label, q.Type
			if u, closed, err := ParseRecord(src[a[0]:a[1]]); err != nil || !closed {
				return p, fmt.Errorf("case %s の payload の record の型が読めない（開いた record は扱わない）", sym)
			} else if u.Find(label) >= 0 {
				return p, fmt.Errorf("case %s の record に欄 %s はもうある", sym, label)
			}
			p.Edits = append(p.Edits, Edit{File: decl.File, Start: a[0], End: a[1], Site: *decl, Check: check(*decl, src),
				Make: func(cur string) (string, error) { return AddRecordField(cur, label, typ) }})
			p.Sites = append(p.Sites, Fixed{*decl, "宣言に欄 " + label + " = " + typ})
		case "add":
			add(*decl, src, list, has, q.Type, "宣言に欄 "+q.Type)
		default:
			add(*decl, src, list, has, "", "宣言から欄 "+types[at])
		}
		p.Decls++
		for _, r := range rows {
			if r.Sym != sym || (r.Kind != KindCaseConstruct && r.Kind != KindCasePattern) || strings.Contains(r.Extra, "sugar") {
				continue
			}
			s, err := srcs.get(r.File)
			if err != nil {
				return p, err
			}
			name, err := SpanText(s, r)
			if err != nil || !strings.HasSuffix(name, short) {
				return p, fmt.Errorf("索引が古い: %s の字が %q（bin/fge refactor index --rebuild）", r.Where(), name)
			}
			_, ne, _ := ByteRange(s, r)
			l, h, err := argsAfter(s, ne)
			info := args[argKey(r.Kind, r)]
			n := len(l.Args)
			switch {
			case err != nil:
				p.Fix = append(p.Fix, Fixed{r, err.Error()})
				continue
			case info.Synth || (arity > 0 && !h):
				p.Fix = append(p.Fix, Fixed{r, "case を関数として渡している（欄を変えると型が変わる。lambda で包むかは人）"})
				continue
			case n != arity || info.N != n:
				p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("引数の数 %d が宣言の %d と違う（索引では %d）", n, arity, info.N)})
				continue
			}
			if r.Kind == KindCaseConstruct {
				p.Constructs++
				switch q.Mode {
				case "add":
					add(r, s, l, h, q.Value, "作る所に "+q.Value)
				case "remove":
					if !isSimple(s[l.Args[at][0]:l.Args[at][1]]) {
						p.Dropped++
					}
					add(r, s, l, h, "", "作る所から "+oneLine(s[l.Args[at][0]:l.Args[at][1]]))
				case "label":
					a := l.Args[0]
					if u, closed, err := ParseRecord(s[a[0]:a[1]]); err != nil || !closed || u.End != a[1]-a[0] {
						p.Fix = append(p.Fix, Fixed{r, "payload が閉じた record の式でない（`{ " + q.Label + " = … | e }` で足すかは人）"})
						continue
					}
					label, value := q.Label, q.Value
					p.Edits = append(p.Edits, Edit{File: r.File, Start: a[0], End: a[1], Site: r, Check: check(r, s),
						Make: func(cur string) (string, error) { return AddRecordField(cur, label, value) }})
					p.Sites = append(p.Sites, Fixed{r, "作る所に " + label + " = " + value})
				}
				continue
			}
			p.Matches++
			switch q.Mode {
			case "add":
				add(r, s, l, h, "_", "当てる所に _")
			case "remove":
				sub := s[l.Args[at][0]:l.Args[at][1]]
				if why := unusedField(s, r, l, sub, arms); why != "" {
					p.Fix = append(p.Fix, Fixed{r, why})
					continue
				}
				add(r, s, l, h, "", "当てる所から "+sub)
			case "label":
				if strings.HasPrefix(s[l.Args[0][0]:l.Args[0][1]], "{") {
					p.Fix = append(p.Fix, Fixed{r, "record の形で当てている（`" + q.Label + " = _` を足すかは人）"})
					continue
				}
				p.Kept++
			}
		}
	}
	p.Fix = sortedFixed(p.Fix)
	return p, nil
}

// alignGap は当てる所の後ろの、腕の `=>` を縦にそろえる空白（2 つ以上）を、型の字が delta 伸びた（縮んだ）分だけ
// 詰める（広げる）書き換え。そろえていなければ nil。
func alignGap(src string, end, delta int) *Edit {
	j := end
	for j < len(src) && src[j] == ' ' {
		j++
	}
	n := j - end
	if n < 2 || !strings.HasPrefix(src[j:], "=>") || delta == 0 {
		return nil
	}
	want := n - delta
	if want < 1 {
		want = 1
	}
	pad := strings.Repeat(" ", want)
	// WhyNot: 字そのものでなく「末尾の空白を pad に」で作る。中身の無い case に `(_)` を足す書き換えは同じ位置の
	// 幅 0 なので、この書き換えの内側として先に当たり、cur の頭に入ってくる。
	return &Edit{Start: end, End: j, Make: func(cur string) (string, error) { return strings.TrimRight(cur, " ") + pad, nil }}
}

// unusedField は当てる所の欄 sub を消してよいか（`_`・`_x`・本体が使わない変数）。消せなければ訳。
func unusedField(src string, pat Row, l ArgList, sub string, arms []Row) string {
	switch {
	case sub == "_" || (strings.HasPrefix(sub, "_") && isIdent(sub)):
		return ""
	case !isIdent(sub) || !(sub[0] >= 'a' && sub[0] <= 'z'):
		return "消す欄を `" + oneLine(sub) + "` で当てている（`_`・変数でない。消すと当て方が変わる）"
	}
	var arm *Row
	for i := range arms {
		a := arms[i]
		if a.contains(pat) && (arm == nil || arm.contains(a)) {
			arm = &arms[i]
		}
	}
	if arm == nil {
		return "消す欄の変数 " + sub + " が match の腕の外（let・lambda の型）。使っていないかは人"
	}
	_, armEnd, err := ByteRange(src, *arm)
	if err != nil || armEnd < l.Close {
		return "match の腕の範囲が読めない"
	}
	if len(identUses(src[l.Close:armEnd], map[string]bool{sub: true})) > 0 {
		return "消す欄の変数 " + sub + " を腕の本体が使う"
	}
	return ""
}

// oneLine は報告に出す式の 1 行（改行を詰め、長ければ切る）。
func oneLine(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 40 {
		s = string(r[:40]) + "…"
	}
	return s
}

// caseShapeReport は change-case-shape の入口。
func caseShapeReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	if !idx.hasAdds(KindArg) {
		return report{}, fmt.Errorf("索引に arg の行が無い（flixlint %s 以上が要る。--flixlint か FGE_FLIXLINT で名指しして bin/fge refactor index --rebuild）", MinFlixlintArgs)
	}
	q := CaseShapeQuery{At: a.at, Type: a.typ, Value: a.value, Label: a.label, Arity: map[string]int{}, Shapes: map[string]string{}}
	switch {
	case a.add != "":
		q.Mode, q.Type = "add", a.add
	case a.remove >= 0:
		q.Mode, q.At = "remove", a.remove
	default:
		q.Mode = "label"
	}
	for _, c := range strings.Split(a.caseName, ",") {
		sym, err := Resolve(idx.Rows, strings.TrimSpace(c), map[string]bool{KindCaseDecl: true})
		if err != nil {
			return report{}, err
		}
		q.Cases = append(q.Cases, sym)
	}
	plan, err := PlanCaseShape(idx.Rows, &reshapeSources{root: root, m: map[string]string{}}, q)
	if err != nil {
		return report{}, err
	}
	how := a.applyWith(cfg.Verify, o)
	if len(plan.Fix) > 0 {
		how.On = false
	}
	out := Change(root, plan.Edits, how)
	if a.apply && len(plan.Fix) > 0 {
		out.State, out.Reason = StateRefused, fmt.Sprintf("人へ回す所 %d（書くと型が合わない。直してから --apply）", len(plan.Fix))
	}
	what := map[string]string{"add": "欄 " + q.Type + " を足す", "remove": fmt.Sprintf("%d 番目の欄を消す", q.At), "label": "record に欄 " + q.Label + " = " + q.Type + " を足す"}[q.Mode]
	if q.Mode == "add" && q.At >= 0 {
		what = fmt.Sprintf("%d 番目に欄 %s を足す", q.At, q.Type)
	}
	r := report{Op: "change-case-shape", Target: a.caseName + "（" + what + "）", code: CodeCaseShape, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	sites := plan.Decls + plan.Constructs + plan.Matches
	if out.State == StateReverted || out.State == StateRefused {
		r.got = sites
	}
	r.Sites = plan.Sites
	rewrites := len(plan.Sites)
	r.gotText = fmt.Sprintf("宣言 %d・作る所 %d・当てる所 %d・書き換える %d・人へ回す %d", plan.Decls, plan.Constructs, plan.Matches, rewrites, len(plan.Fix))
	for _, c := range q.Cases {
		r.extra = append(r.extra, fmt.Sprintf("今の形: %s%s", shortCase(c), q.Shapes[c]))
	}
	if plan.Kept > 0 {
		r.extra = append(r.extra, fmt.Sprintf("record を丸ごと束ねて当てる所 %d はそのまま", plan.Kept))
	}
	if plan.Dropped > 0 {
		r.extra = append(r.extra, fmt.Sprintf("捨てる作る所の式のうち名前・字の値でない物 %d（副作用があれば手で）", plan.Dropped))
	}
	r.wantText = "作る所・当てる所の欄の数が宣言と同じ（決められない所は fix。fix があれば書かない）"
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", s.Where(), s.Why, s.Owner))
	}
	base := "bin/fge refactor change-case-shape --case " + a.caseName
	switch q.Mode {
	case "add":
		base += " --add " + shellQuote(q.Type)
		if a.at >= 0 {
			base += fmt.Sprintf(" --at %d", a.at)
		}
		base += " --value " + shellQuote(q.Value)
	case "remove":
		base += fmt.Sprintf(" --remove %d", q.At)
	case "label":
		base += " --label " + q.Label + " --type " + shellQuote(q.Type) + " --value " + shellQuote(q.Value)
	}
	nextOf(&r, base, a, &out)
	switch {
	case len(plan.Fix) > 0:
		r.fixHint = "fix の所を手で直す（case を関数として渡す所は lambda で包む・消す欄を使う本体を直す）か、索引に合う形にしてから"
		r.Next, r.NextWhy = base, "fix の所を直してから dry-run から（fix が 0 になれば --apply）"
	case out.State == StateApplied:
		kept := ""
		if plan.Kept > 0 {
			kept = fmt.Sprintf("・当てる所のうちそのまま %d", plan.Kept)
		}
		r.Done = fmt.Sprintf("done: %d sites（宣言 %d・作る所 %d・当てる所 %d%s）→ 0 left · check ok", rewrites, plan.Decls, plan.Constructs, plan.Matches-plan.Kept, kept)
		r.Next, r.NextWhy = "bin/fge refactor usages "+strings.Split(a.caseName, ",")[0], "替えた後の作る所・当てる所（索引は作り直しになる）"
		r.lines = nil
	}
	return r, nil
}

// shellQuote は next の行に写す引数（空白や記号があれば ' で包む）。
func shellQuote(s string) string {
	if s != "" && isSimple(s) && !strings.ContainsAny(s, "\"'#") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
