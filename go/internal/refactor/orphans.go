package refactor

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// 書き替え（rewrite・extract-function --all）で呼び手が 0 になる def の始末。
//
// 呼ぶ所を全部書き替えると、呼ばれなくなった pub でない def は Flix の「使わない def」の誤りになり、--apply の確かめで
// 全部戻る。そこで、書き替える範囲の中の参照（索引の def-use の行）を消えた物と見て、ほかに参照が無く、書いた字
// （--to の式・置く def・呼び出し）にも名前が出ない pub でない def を、同じ patch で消す。消し方は remove-dead の
// --def と同じ（前の `///` と注記ごと・その def だけが呼んでいた def の道連れ・転送するだけの包みの doc を転送先へ）。
// pub の def は外から呼ばれうるので消さず、数を知らせるだけ。
//
// WhyNot: 字（短い名前）で「書いた字に名前が出るか」を見るのは、書いた後の字の索引が無いため。同じ短い名前の別の def が
// 字に出れば残す側に倒れる（消しすぎない。残ったら確かめで止まり、全部戻る）。

// OrphanPlan は呼び手が 0 になる def の始末の計画。
type OrphanPlan struct {
	Removed []Fixed  // 一緒に消す def（呼び手が 0 になった物と、その道連れ）
	Pub     []string // 呼び手が 0 になる pub の def（消さない）
	Fix     []Fixed  // 消せない物（@Test・instance など）
	Docs    []Fixed  // doc を移す転送先
	DocRefs []Fixed  // 消す def を文書が名指す所
	Edits   []Edit
}

// planOrphans は書き替え edits（元の中身のバイトの範囲）と、書く字 texts から、呼び手が 0 になる def の始末を決める。
func planOrphans(root string, rows []Row, srcs *reshapeSources, edits []Edit, texts []string, q DeadQuery) (OrphanPlan, error) {
	var plan OrphanPlan
	byFile := map[string][]Edit{}
	for _, e := range edits {
		if e.Start < e.End {
			byFile[e.File] = append(byFile[e.File], e)
		}
	}
	lines := map[string]*lineIndex{}
	inEdit := func(r Row) bool {
		es := byFile[r.File]
		if len(es) == 0 {
			return false
		}
		li, ok := lines[r.File]
		if !ok {
			if src, err := srcs.get(r.File); err == nil {
				li = newLineIndex(src)
			}
			lines[r.File] = li
		}
		if li == nil {
			return false
		}
		p, ok := li.byteAt(r.Line, r.Col)
		if !ok {
			return false
		}
		for _, e := range es {
			if e.Start <= p && p < e.End {
				return true
			}
		}
		return false
	}
	defs, order := defTable(rows)
	gone := map[int]bool{} // rows の番号
	lost := map[string]bool{}
	for i, r := range rows {
		if r.Kind == KindDefUse && r.Owner != r.Sym && inEdit(r) {
			gone[i] = true
			lost[r.Sym] = true
		}
	}
	if len(lost) == 0 {
		return plan, nil
	}
	left := map[string]int{}
	var kept []Row
	for i, r := range rows {
		if gone[i] {
			continue
		}
		kept = append(kept, r)
		if r.Kind == KindDefUse && r.Owner != r.Sym {
			left[r.Sym]++
		}
	}
	joined := strings.Join(texts, "\n")
	var named []string
	for _, s := range order {
		d, ok := defs[s]
		if !lost[s] || !ok || left[s] > 0 || namedIn(joined, s) {
			continue
		}
		if d.Pub {
			plan.Pub = append(plan.Pub, displaySym(s))
			continue
		}
		named = append(named, s)
	}
	sort.Strings(plan.Pub)
	if len(named) == 0 {
		return plan, nil
	}
	q.Def = strings.Join(named, ",")
	// テストのフォルダの pub でない助けも、呼び手を失えば使わない def の誤りになるので消す（@Test は PlanDead が残す）。
	q.TestDirs = nil
	q.WithTests = false
	dead, err := PlanDead(root, kept, q)
	if err != nil {
		return plan, err
	}
	plan.Removed, plan.Fix, plan.Docs, plan.DocRefs, plan.Edits = dead.Targets, dead.Fix, dead.Docs, dead.DocRefs, dead.Edits
	for i := range plan.Removed {
		if plan.Removed[i].Why == "unreferenced" {
			plan.Removed[i].Why = "書き替えで呼び手が 0 になる"
		}
	}
	return plan, nil
}

// orphanQuery は呼び手が 0 になる def を消す時の remove-dead の問い（入口の名前・ライブラリの見方は remove-dead と同じ）。
func orphanQuery(root string, cfg Config) DeadQuery {
	return DeadQuery{Engine: engineDir(root), Library: IsLibrary(root, cfg), EntryTables: cfg.EntryTables}
}

// namedIn は字 text に def sym の名前が出るか。素の名前（同じ mod の中から呼ぶ形）か、sym の mod（かその終わり）で
// 修飾した名前の時だけ数える（Geometry.centerOf は ShieldFx.centerOf でない）。
func namedIn(text, sym string) bool {
	d := displaySym(sym)
	short, mod := shortName(d), modOf(d)
	if short == "" || text == "" {
		return false
	}
	re := regexp.MustCompile(`(^|[^A-Za-z0-9_$#.])((?:[A-Za-z_][A-Za-z0-9_]*\.)*)` + regexp.QuoteMeta(short) + `([^A-Za-z0-9_]|$)`)
	for _, m := range re.FindAllStringSubmatch(text, -1) {
		q := strings.TrimSuffix(m[2], ".")
		if q == "" || q == mod || strings.HasSuffix(mod, "."+q) {
			return true
		}
	}
	return false
}

// orphanLines は始末の計画を報告に足す（extra の行・消す def の行・文書の名指し）。applied は書いた後か。
func orphanLines(r *report, plan OrphanPlan, out *Outcome) {
	if len(plan.Removed) > 0 {
		var names []string
		for _, f := range plan.Removed {
			names = append(names, displaySym(f.Sym))
		}
		verb := "一緒に消す"
		if out.State == StateApplied {
			verb = "一緒に消した"
		}
		r.extra = append(r.extra, fmt.Sprintf("呼び手が 0 になった非公開の def %d を%s（%s）", len(plan.Removed), verb, strings.Join(names, "・")))
		for _, f := range plan.Removed {
			if out.State == StateApplied {
				break
			}
			r.lines = append(r.lines, fmt.Sprintf("%s\t消す\t%s（%s）", f.Where(), displaySym(f.Sym), f.Why))
		}
	}
	if len(plan.Pub) > 0 {
		r.extra = append(r.extra, fmt.Sprintf("呼び手が 0 になる pub の def %d（消さない。要らなければ bin/fge refactor remove-dead --def %s）", len(plan.Pub), strings.Join(plan.Pub, ",")))
	}
	if len(plan.Docs) > 0 {
		var moved []string
		for _, d := range plan.Docs {
			moved = append(moved, d.Sym+"（"+d.Why+"）")
		}
		r.extra = append(r.extra, "転送するだけの包みの doc を転送先へ: "+strings.Join(moved, "・"))
	}
	for _, f := range plan.Fix {
		r.extra = append(r.extra, fmt.Sprintf("呼び手が 0 になるが消さない def %s（%s。確かめで使わない def の誤りになれば手で）", displaySym(f.Sym), f.Why))
	}
	if len(plan.DocRefs) > 0 {
		docNext(r, plan.DocRefs, out)
	}
}
