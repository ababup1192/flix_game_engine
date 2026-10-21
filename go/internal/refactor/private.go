package refactor

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// make-private: 外の mod から使われない pub の def から `pub` を外す（usages --unused の「同じ mod の中だけ」・lint の
// 呼び手のいない pub の直し）。外の使い手は、外の mod の def の中の呼び出し・参照（名前で渡すのも）と、外の mod の
// `use Mod.{f}`（呼ばなくても use だけで外すと名前が解けない）。テストのフォルダの中の物も外に数える。
//
// 人へ回す所（fix）: 外の使い手がいる・どこからも参照されない（非 pub にすると Flix が使わない def の誤りにする。
// 消すのは remove-dead）・名前が入口のファイル（Makefile・json・flow など文章でない物）に字で出る（名前で呼ばれるかもしれない。
// 文書が名指すだけなら pub を外しても名前は残るので見ない: mentions.go）・
// ライブラリ（fpkg で配る。使い手は索引の外）・instance の def と @Test。--def を省くと「同じ mod の中だけ」の def を全部。

// PrivateQuery は make-private の問い。
type PrivateQuery struct {
	Defs     []string // 索引の def の名前（解決済み）。空なら同じ mod の中だけの def を全部
	TestDirs []string
	Outside  map[string]string // 入口のファイルに字で出る名前 → そのファイル（Mentions.Entry）
	Library  bool
}

// PrivatePlan は make-private の計画。
type PrivatePlan struct {
	Edits   []Edit
	Targets []Fixed // pub を外す def（Why は「同じ mod の中だけ N か所」）
	Fix     []Fixed
}

// pubToken は宣言の行の `pub`（その後ろの空白まで。消すのはここ）。
var pubToken = regexp.MustCompile(`\bpub\s+`)

// PlanPrivate は q の def から `pub` を外す計画。
func PlanPrivate(root string, rows []Row, q PrivateQuery) (PrivatePlan, error) {
	var p PrivatePlan
	defs, order := defTable(rows)
	refs := refsBySym(rows)
	usedBy := map[string][]Row{} // def → 外の mod の use の行
	for _, r := range rows {
		if r.Kind == KindUse && r.Attr("what") == "def" {
			usedBy[r.Sym] = append(usedBy[r.Sym], r)
		}
	}
	want := q.Defs
	auto := len(want) == 0
	if auto {
		want = order
	}
	for _, s := range want {
		d, ok := defs[s]
		if !ok {
			return p, fmt.Errorf("def %s の宣言が索引に無い", s)
		}
		fix := func(why string) { p.Fix = append(p.Fix, Fixed{d.Row, why}) }
		if !d.Pub {
			if !auto {
				fix("もう pub でない")
			}
			continue
		}
		if d.Inst || d.Test || inDirs(d.File, q.TestDirs) || strings.HasSuffix(s, ".main") || s == "main" {
			if !auto {
				fix("instance の def・@Test・main・テストのフォルダの def は扱わない")
			}
			continue
		}
		var outside []string
		own := 0
		for _, r := range refs[s] {
			if modOf(r.Owner) == modOf(s) && !inDirs(r.File, q.TestDirs) {
				own++
			} else {
				outside = append(outside, r.Where())
			}
		}
		for _, u := range usedBy[s] {
			if modOf(u.Owner) != modOf(s) {
				outside = append(outside, u.Where()+"（use）")
			}
		}
		switch {
		case len(outside) > 0:
			if !auto {
				fix(fmt.Sprintf("外の使い手 %d（最初: %s）", len(outside), outside[0]))
			}
			continue
		case own == 0:
			if !auto {
				fix("どこからも参照されない（非 pub にすると使わない def の誤りになる。消すのは bin/fge refactor remove-dead --def " + s + "）")
			}
			continue
		case q.Library:
			fix("ライブラリ（fpkg で配る）: pub の def の使い手は索引の外にもいる")
			continue
		case q.Outside[s] != "":
			fix("名前が入口のファイルに字で出る（" + q.Outside[s] + "。名前で呼ぶなら pub のまま）")
			continue
		}
		e, err := privateEdit(root, d)
		if err != nil {
			fix(err.Error())
			continue
		}
		p.Edits = append(p.Edits, e)
		p.Targets = append(p.Targets, Fixed{d.Row, fmt.Sprintf("同じ mod の中だけ %d か所", own)})
	}
	sort.SliceStable(p.Fix, func(i, j int) bool { return p.Fix[i].Where() < p.Fix[j].Where() })
	return p, nil
}

// privateEdit は def の宣言の `pub` を消す書き換え（宣言の頭〜名前の間の最後の `pub`）。
func privateEdit(root string, d defInfo) (Edit, error) {
	data, err := os.ReadFile(filepath.Join(root, d.File))
	if err != nil {
		return Edit{}, err
	}
	src := string(data)
	start, _, err := ByteRange(src, d.Ext)
	if err != nil {
		return Edit{}, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", d.Row.Where())
	}
	nameStart, _, err := ByteRange(src, d.Row)
	if err != nil || nameStart < start {
		return Edit{}, fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", d.Row.Where())
	}
	head := src[start:nameStart]
	locs := pubToken.FindAllStringIndex(head, -1)
	if len(locs) == 0 {
		return Edit{}, fmt.Errorf("宣言に pub が見つからない")
	}
	at := locs[len(locs)-1]
	if !strings.HasPrefix(strings.TrimSpace(head[at[1]:]), "def") {
		return Edit{}, fmt.Errorf("pub の後ろが def でない（読めない宣言）")
	}
	name := d.Sym[strings.LastIndex(d.Sym, ".")+1:]
	return Edit{File: d.File, Start: start + at[0], End: start + at[1], Site: d.Row,
		Check: []Want{{Span: d.Row, Text: name}},
		Make:  func(string) (string, error) { return "", nil }}, nil
}

// privateReport は make-private の入口。
func privateReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	q := PrivateQuery{TestDirs: cfg.TestDirs, Library: IsLibrary(root, cfg)}
	if a.def != "" {
		for _, d := range strings.Split(a.def, ",") {
			sym, err := Resolve(idx.Rows, strings.TrimSpace(d), map[string]bool{KindDefDecl: true})
			if err != nil {
				return report{}, err
			}
			q.Defs = append(q.Defs, sym)
		}
	}
	q.Outside = loadMentions(root, engineDir(root)).Entry
	plan, err := PlanPrivate(root, idx.Rows, q)
	if err != nil {
		return report{}, err
	}
	out := Change(root, plan.Edits, a.applyWith(cfg.Verify, o))
	target := a.def
	if target == "" {
		target = "（同じ mod の中だけの pub の def を全部）"
	}
	r := report{Op: "make-private", Target: target, code: CodePrivate, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.Targets)
	}
	r.Sites = plan.Targets
	r.gotText = fmt.Sprintf("pub を外す def %d・人へ回す %d", len(plan.Targets), len(plan.Fix))
	r.wantText = "外の mod から使われない pub の def から pub を外す（外の使い手がいる・どこからも参照されない・名前が入口のファイルに出る物は fix）"
	for _, t := range plan.Targets {
		r.lines = append(r.lines, fmt.Sprintf("%s\tpub を外す\t%s（%s）", t.Where(), t.Sym, t.Why))
	}
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Sym, f.Why))
	}
	base := "bin/fge refactor make-private"
	if a.def != "" {
		base += " --def " + a.def
	}
	nextOf(&r, base, a, &out)
	switch {
	case out.State == StateNothing && len(plan.Fix) > 0:
		r.fixHint = "fix の理由の通り（外の使い手がいれば pub のまま・参照 0 は remove-dead）"
	case out.State == StateApplied:
		r.Done = fmt.Sprintf("done: %d defs → pub を外した · check ok", len(plan.Targets))
		r.Next, r.NextWhy = "bin/fge refactor usages --unused", "残りの外から使われない pub（索引は作り直しになる）"
		r.lines = nil
	}
	return r, nil
}
