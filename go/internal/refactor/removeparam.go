package refactor

import (
	"fmt"
	"strings"
)

// remove-param: def の使っていない引数を、宣言と呼ぶ所の両方から消す（change-signature の「残す引数の並び」の形）。
// --param を省くと、本体が使わない引数を全部消す（_ で始まる引数は使わない印なので残す）。本体が使う引数を --param で
// 名指ししたら消さずに fix。
//
// 型検査が通らない途中のソースでも使える: 索引は resolved の段（名前解決まで）で足り、--apply の確かめは書く前にも流し、
// 前から落ちていれば、書いた後の誤りが書く前の誤りに収まる（新しい誤りが 0）時に通す（Apply.Baseline）。
// 使わない引数は Flix では誤り（Unused formal parameter）なので、消すと誤りが減る。
//
// 呼ぶ所の、消す引数に渡していた式が名前・字の値でなければ「捨てる式」として数える（副作用があれば手で）。

// paramsOf は def の宣言の引数の名前と、本体の字（本体の始まり〜def の終わり）。
func paramsOf(rows []Row, srcs *reshapeSources, sym string) (names []string, body string, decl Row, err error) {
	var d *Row
	for i := range rows {
		if rows[i].Kind == KindDefDecl && rows[i].Sym == sym {
			d = &rows[i]
			break
		}
	}
	if d == nil {
		return nil, "", Row{}, fmt.Errorf("def %s の宣言が索引に無い（パッケージの def は直せない）", sym)
	}
	src, err := srcs.get(d.File)
	if err != nil {
		return nil, "", *d, err
	}
	_, nameEnd, err := ByteRange(src, *d)
	if err != nil {
		return nil, "", *d, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", d.Where())
	}
	open := nameEnd
	if open < len(src) && src[open] == '[' {
		if _, at, e := scanTop(src, open+1, "]"); e == nil {
			open = at + 1
		}
	}
	list, has, err := argsAfter(src, open)
	if err != nil || !has {
		return nil, "", *d, fmt.Errorf("%s: def %s の引数の並びが読めない", d.Where(), sym)
	}
	var params []string
	for _, a := range list.Args {
		params = append(params, src[a[0]:a[1]])
	}
	if names, err = paramNames(params); err != nil {
		return nil, "", *d, fmt.Errorf("%s: %v", d.Where(), err)
	}
	span, err := spanOf(d.File, d.Attr("ext"))
	if err != nil {
		return nil, "", *d, err
	}
	_, extEnd, err := ByteRange(src, span)
	if err != nil {
		return nil, "", *d, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", d.Where())
	}
	start, ok := DefBodyStart(src, list.Close+1)
	if !ok || start > extEnd {
		return nil, "", *d, fmt.Errorf("%s: def %s の本体の始まりが読めない", d.Where(), sym)
	}
	return names, src[start:extEnd], *d, nil
}

// removeParamReport は remove-param の入口。
func removeParamReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	if !idx.hasAdds(KindArg) {
		return report{}, fmt.Errorf("索引に arg の行が無い（flixlint %s 以上が要る。--flixlint か FGE_FLIXLINT で名指しして bin/fge refactor index --rebuild）", MinFlixlintArgs)
	}
	var named []string
	if a.param != "" {
		for _, n := range strings.Split(a.param, ",") {
			named = append(named, strings.TrimSpace(n))
		}
	}
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	var edits []Edit
	var fix []Fixed
	var sites []Fixed
	var removedAll []string
	calls, files, dropped := 0, map[string]bool{}, 0
	for _, d := range strings.Split(a.def, ",") {
		sym, err := Resolve(idx.Rows, strings.TrimSpace(d), map[string]bool{KindDefDecl: true})
		if err != nil {
			return report{}, err
		}
		names, body, decl, err := paramsOf(idx.Rows, srcs, sym)
		if err != nil {
			return report{}, err
		}
		var drop, keep []string
		for _, n := range names {
			used := len(identUses(body, map[string]bool{n: true})) > 0
			switch {
			case named == nil && !used && !strings.HasPrefix(n, "_"), indexOf(named, n) >= 0 && !used:
				drop = append(drop, n)
			case indexOf(named, n) >= 0:
				fix = append(fix, Fixed{decl, fmt.Sprintf("本体が引数 %s を使う（消すと名前が解けない。使う所を直すか change-signature で別の値を渡す）", n)})
			default:
				keep = append(keep, n)
			}
		}
		for _, n := range named {
			if indexOf(names, n) < 0 {
				return report{}, fmt.Errorf("def %s に引数 %s が無い（引数は %s）", sym, n, strings.Join(names, ", "))
			}
		}
		switch {
		case len(drop) == 0:
			continue
		case len(keep) == 0:
			fix = append(fix, Fixed{decl, "引数を全部消す形は扱わない（値を返すだけの def になる。手で）"})
			continue
		}
		plan, err := PlanSignature(idx.Rows, srcs, SignatureQuery{Defs: []string{sym}, Params: strings.Join(keep, ", "), Templates: keep})
		if err != nil {
			return report{}, err
		}
		edits = append(edits, plan.Edits...)
		fix = append(fix, plan.Fix...)
		sites = append(sites, plan.Sites...)
		calls += plan.Calls
		dropped += plan.Dropped
		for f := range plan.CallFiles {
			files[f] = true
		}
		for _, n := range drop {
			removedAll = append(removedAll, shortName(sym)+"."+n)
		}
	}
	how := Apply{On: a.apply && len(fix) == 0, RequireClean: a.requireClean, Verify: cfg.Verify, Run: o.Verify, Baseline: true}
	out := Change(root, edits, how)
	if a.apply && len(fix) > 0 {
		out.State, out.Reason = StateRefused, fmt.Sprintf("人へ回す所 %d（直してから --apply）", len(fix))
	}
	r := report{Op: "remove-param", Target: a.def, code: CodeRemoveParam, Outcome: &out, Fix: sortedFixed(fix), Sites: sites}
	r.got = len(fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = calls
	}
	r.gotText = fmt.Sprintf("消す引数 %d（%s）・呼ぶ所 %d（%d ファイル）・人へ回す %d", len(removedAll), strings.Join(removedAll, "・"), calls, len(files), len(fix))
	if dropped > 0 {
		r.extra = append(r.extra, fmt.Sprintf("捨てる引数の式のうち名前・字の値でない物 %d（副作用があれば手で）", dropped))
	}
	if named == nil {
		r.extra = append(r.extra, "--param を省いたので、本体が使わない引数を全部消す")
	}
	r.wantText = "使っていない引数が宣言と呼ぶ所から消える（本体が使う引数は fix。fix があれば書かない）"
	for _, f := range r.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	for _, s := range sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s（%s）", s.Where(), s.Why, s.Owner))
	}
	base := "bin/fge refactor remove-param --def " + a.def
	if a.param != "" {
		base += " --param " + a.param
	}
	nextOf(&r, base, a, &out)
	switch {
	case out.State == StateNothing && len(fix) == 0:
		r.extra = append(r.extra, "消す引数が無い（どの引数も本体が使う）")
	case len(fix) > 0:
		r.fixHint = "fix の理由の通りに直してから"
	case out.State == StateApplied:
		r.Done = fmt.Sprintf("done: %d params（呼ぶ所 %d）→ 0 left · check %s", len(removedAll), calls, map[bool]string{true: "は前から落ちている（新しい誤り 0）", false: "ok"}[out.BrokenBefore && !out.FixedAfter])
		r.Next, r.NextWhy = "bin/fge refactor usages "+strings.Split(a.def, ",")[0]+" --callers", "消した後の呼び手（索引は作り直しになる）"
		r.lines = nil
	}
	return r, nil
}
