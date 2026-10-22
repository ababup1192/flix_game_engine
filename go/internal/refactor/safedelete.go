package refactor

import (
	"fmt"
	"sort"
)

// safe-delete: 名指した def を、消してよい時だけ消す（refactor-tool-design §8.4 の safe-delete・段 E）。消してよいかの決めは
// usages --unused と同じ（UnusedDefs）: 参照 0 は remove-dead で消し、テストからだけ使う物はそのテストごと消す
// （remove-dead --with-tests）。同じ mod の中から使う物と外の mod から使う物は消さずに止め、使い手を並べる（同じ mod の
// 中だけなら pub を外すのは make-private）。消す所と確かめ（make check）は remove-dead そのもの。
func safeDeleteReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	sym, err := Resolve(idx.Rows, a.def, map[string]bool{KindDefDecl: true})
	if err != nil {
		return report{}, err
	}
	// 参照を、テストのフォルダから・同じ mod の中から・外の mod からに数え分ける（usages --unused の test-only は同じ mod の
	// 中から使う物も入れるので、その決めのままでは消せない物まで「消す」と言ってしまう）。
	fromTest, fromOwn, fromOther := 0, 0, 0
	for _, r := range refsBySym(idx.Rows)[sym] {
		switch {
		case inDirs(r.File, cfg.TestDirs):
			fromTest++
		case modOf(r.Owner) == modOf(sym):
			fromOwn++
		default:
			fromOther++
		}
	}
	var found *Unused
	for _, u := range UnusedDefs(idx.Rows, cfg.TestDirs) {
		if u.Sym == sym {
			u := u
			found = &u
		}
	}
	if found != nil && fromOwn == 0 && fromOther == 0 {
		d := a
		d.op, d.def, d.withTests = "remove-dead", sym, fromTest > 0
		r, err := deadReport(root, idx, d, cfg, o)
		r.Op = "safe-delete"
		what := "参照 0 なので remove-dead に回す"
		if fromTest > 0 {
			what = fmt.Sprintf("テストからだけ（%d か所）使うので、使うテストごと remove-dead に回す（そのテストがほかの口も試していれば remove-dead が止める）", fromTest)
		}
		r.extra = append([]string{sym + " は " + what}, r.extra...)
		return r, err
	}
	// 消さない: 使い手を並べて止める。
	defs, _ := defTable(idx.Rows)
	d, ok := defs[sym]
	if !ok {
		return report{}, fmt.Errorf("def %s の宣言が索引に無い", sym)
	}
	var users []Fixed
	for _, r := range refsBySym(idx.Rows)[sym] {
		users = append(users, Fixed{r, "使う所（" + r.Owner + "）"})
	}
	sort.SliceStable(users, func(i, j int) bool { return users[i].Where() < users[j].Where() })
	why := fmt.Sprintf("外の mod から %d・同じ mod の中から %d・テストから %d 使われる", fromOther, fromOwn, fromTest)
	next, nextWhy := "bin/fge refactor usages "+sym+" --callers", "使う def ごとに見て、先に使う所を直す"
	switch {
	case fromOther == 0 && fromTest == 0 && fromOwn > 0:
		why = fmt.Sprintf("同じ mod の中から %d 使われる。消すと名前が解けない", fromOwn)
		next, nextWhy = "bin/fge refactor make-private --def "+sym, "外から使わないだけなら pub を外す"
	case !d.Pub || d.Inst || d.Test:
		why = "pub でない def・instance の def・@Test は扱わない（使わない非 pub の def は Flix のコンパイラが止める）"
		next, nextWhy = "", ""
	}
	out := Outcome{State: StateNothing}
	if a.apply {
		out.State, out.Reason = StateRefused, why
	}
	r := report{Op: "safe-delete", Target: sym, code: CodeSafeDelete, Outcome: &out, Fix: append([]Fixed{{d.Row, why}}, users...)}
	r.got = len(r.Fix)
	r.gotText = "消さない: " + why
	r.wantText = "参照 0 かテストからだけ使う def を消す（同じ mod の中から・外から使う def は消さずに使い手を並べる）"
	for _, u := range users {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\t使う所\t%s", u.Where(), u.Owner))
	}
	if next != "" {
		r.Next, r.NextWhy = next, nextWhy
	}
	return r, nil
}
