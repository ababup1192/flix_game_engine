package refactor

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// rename: def の名前を替える（refactor-tool-design §8.4 の rename・段 E）。宣言（def-decl）と、名前を書いた所全部
// （def-use: 呼び出し・名前で渡す所・`Mod.f` の形も `f` だけの形も）と、`use Mod.f`・`use Mod.{f, g}` の中の名前の、
// 書いた名前の最後の区切りだけを替える。`use Mod.{f => h}` の別名 h と、それを書いた所は替えない（別名は元の名前と
// 関わらない）。
//
// 人へ回す所（fix）: 書いた字が索引の名前で終わらない所（読めない書き方）・名前が文字列やコメント・入口のファイル
// （Makefile・json・flow）に字で出る所（名前で呼ばれるかもしれない。mentions.go）・ライブラリ（fpkg で配る。使い手は
// 索引の外）。同じ mod に新しい名前がもう在れば書かない（止める）。

// RenamePlan は rename の計画。
type RenamePlan struct {
	Edits []Edit
	Sites []Fixed // 替える所（宣言・使う所・use）
	Fix   []Fixed
	// Words は .flix のソースに元の名前が字で残る所（コメント・文字列。索引の外なので替えない。知らせるだけ）。
	Words []string
}

// identRe は Flix の def の名前（小文字か _ で始まる）。
var identRe = regexp.MustCompile(`^[a-z_][A-Za-z0-9_]*[!?']*$`)

// PlanRename は def s を to へ名前替えする計画。
func PlanRename(root string, rows []Row, s, to string, outside map[string]string, library bool) (RenamePlan, error) {
	var p RenamePlan
	if !identRe.MatchString(to) {
		return p, fmt.Errorf("--to %s は def の名前の形でない（小文字か _ で始まる）", to)
	}
	old := s[strings.LastIndex(s, ".")+1:]
	if old == to {
		return p, fmt.Errorf("--to が今の名前と同じ（%s）", to)
	}
	mod := modOf(s)
	newSym := to
	if mod != "" {
		newSym = mod + "." + to
	}
	var decl *Row
	for i, r := range rows {
		if r.Kind == KindDefDecl && r.Sym == newSym {
			return p, fmt.Errorf("%s がもう在る（%s）。別の名前にするか、先にそちらを替える", newSym, r.Where())
		}
		if r.Kind == KindDefDecl && r.Sym == s {
			decl = &rows[i]
		}
	}
	if decl == nil {
		return p, fmt.Errorf("def %s の宣言が索引に無い", s)
	}
	if library {
		p.Fix = append(p.Fix, Fixed{*decl, "ライブラリ（fpkg で配る）: pub の def の使い手は索引の外にもいる"})
	}
	if f := outside[s]; f != "" {
		p.Fix = append(p.Fix, Fixed{*decl, "名前が入口のファイルに字で出る（" + f + "）。そこは手で替える"})
	}
	files := map[string]string{}
	read := func(file string) (string, error) {
		if src, ok := files[file]; ok {
			return src, nil
		}
		b, err := os.ReadFile(filepath.Join(root, file))
		if err != nil {
			return "", err
		}
		files[file] = string(b)
		return files[file], nil
	}
	seen := map[string]bool{}
	add := func(r Row, why string, edit func(text string) (string, bool)) {
		key := fmt.Sprintf("%s:%d:%d:%d:%d", r.File, r.Line, r.Col, r.EndLine, r.EndCol)
		if seen[key] {
			return
		}
		seen[key] = true
		src, err := read(r.File)
		if err != nil {
			p.Fix = append(p.Fix, Fixed{r, err.Error()})
			return
		}
		start, end, err := ByteRange(src, r)
		if err != nil {
			p.Fix = append(p.Fix, Fixed{r, "索引が古い（bin/fge refactor index --rebuild）"})
			return
		}
		text := src[start:end]
		repl, ok := edit(text)
		if !ok {
			p.Fix = append(p.Fix, Fixed{r, fmt.Sprintf("書いた字 %q が %s で終わらない（読めない書き方）", text, old)})
			return
		}
		if repl == text {
			return
		}
		p.Edits = append(p.Edits, Edit{File: r.File, Start: start, End: end, Site: r,
			Check: []Want{{Span: r, Text: text}},
			Make:  func(string) (string, error) { return repl, nil }})
		p.Sites = append(p.Sites, Fixed{r, why})
	}
	lastPart := func(text string) (string, bool) {
		switch {
		case text == old:
			return to, true
		case strings.HasSuffix(text, "."+old):
			return strings.TrimSuffix(text, old) + to, true
		}
		return "", false
	}
	add(*decl, "宣言", lastPart)
	for _, r := range rows {
		switch {
		case r.Kind == KindDefUse && r.Sym == s:
			add(r, "使う所", func(text string) (string, bool) {
				if repl, ok := lastPart(text); ok {
					return repl, true
				}
				// use で別名を付けて取り込んだ名前を書いた所（`h`）: 別名はそのまま
				if !strings.Contains(text, ".") && identRe.MatchString(text) {
					return text, true
				}
				return "", false
			})
		case r.Kind == KindUse && r.Sym == s:
			add(r, "use", func(text string) (string, bool) { return renameInUse(text, old, to) })
		}
	}
	p.Words = wordsLeft(root, rows, old, seen)
	sort.SliceStable(p.Sites, func(i, j int) bool { return p.Sites[i].Where() < p.Sites[j].Where() })
	sort.SliceStable(p.Fix, func(i, j int) bool { return p.Fix[i].Where() < p.Fix[j].Where() })
	return p, nil
}

// renameInUse は use の書いた字の中の元の名前を替える: `Mod.f`・`Mod.{f, g}`・`Mod.{f => h}`（=> の前の f だけ）。
func renameInUse(text, old, to string) (string, bool) {
	if strings.HasSuffix(text, "."+old) || text == old {
		return strings.TrimSuffix(text, old) + to, true
	}
	open := strings.Index(text, "{")
	if open < 0 || !strings.HasSuffix(strings.TrimSpace(text), "}") {
		return "", false
	}
	inner := text[open+1 : strings.LastIndex(text, "}")]
	parts := strings.Split(inner, ",")
	hit := false
	for i, part := range parts {
		name, rest, _ := strings.Cut(strings.TrimSpace(part), "=>")
		if strings.TrimSpace(name) != old {
			continue
		}
		lead := part[:len(part)-len(strings.TrimLeft(part, " \t\n"))]
		repl := lead + to
		if rest != "" {
			repl += " =>" + rest
		}
		parts[i] = repl
		hit = true
	}
	if !hit {
		return "", false
	}
	return text[:open+1] + strings.Join(parts, ",") + text[strings.LastIndex(text, "}"):], true
}

// renameReport は rename の入口。
func renameReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	sym, err := Resolve(idx.Rows, a.def, map[string]bool{KindDefDecl: true})
	if err != nil {
		return report{}, err
	}
	outside := loadMentions(root, engineDir(root)).withEntryDefs(idx.Rows, cfg.EntryTables).Entry
	plan, err := PlanRename(root, idx.Rows, sym, a.to, outside, IsLibrary(root, cfg))
	if err != nil {
		return report{}, err
	}
	how := a.applyWith(cfg.Verify, o)
	var out Outcome
	if len(plan.Fix) > 0 {
		out = Outcome{State: StateNothing}
		if a.apply {
			out.State, out.Reason = StateRefused, "人へ回す所があるので書かない（fix の理由を片付けてから）"
		}
	} else {
		out = Change(root, plan.Edits, how)
	}
	r := report{Op: "rename", Target: sym + " → " + a.to, code: CodeRename, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	r.Sites = plan.Sites
	r.gotText = fmt.Sprintf("替える所 %d・人へ回す %d", len(plan.Sites), len(plan.Fix))
	r.wantText = "def の宣言・使う所・use の名前を替える（入口のファイルに字で出る・ライブラリ・読めない書き方は fix。fix があれば書かない）"
	for _, t := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s\t%s", t.Where(), t.Why, t.Sym))
	}
	if n := len(plan.Words); n > 0 {
		show := plan.Words
		if len(show) > 5 {
			show = show[:5]
		}
		r.extra = append(r.extra, fmt.Sprintf("元の名前が .flix のコメント・文字列に字で残る %d か所（替えない。要れば手で）: %s", n, strings.Join(show, "・")))
	}
	for _, f := range plan.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Sym, f.Why))
	}
	nextOf(&r, "bin/fge refactor rename --def "+a.def+" --to "+a.to, a, &out)
	if out.State == StateApplied {
		r.Done = fmt.Sprintf("done: %s → %s を %d か所 · check ok", sym, a.to, len(plan.Sites))
		r.Next, r.NextWhy = "bin/fge refactor usages "+modOf(sym)+"."+a.to, "替えた後の使われ所（参照の数が前と同じか）"
		r.lines = nil
	}
	return r, nil
}

// wordsLeft は、索引の行の在るファイル（.flix）で、元の名前が語として出るのに替える所（done の範囲）でない行の場所。
func wordsLeft(root string, rows []Row, old string, done map[string]bool) []string {
	word := regexp.MustCompile(`\b` + regexp.QuoteMeta(old) + `\b`)
	doneLines := map[string]bool{}
	for k := range done {
		parts := strings.SplitN(k, ":", 3)
		doneLines[parts[0]+":"+parts[1]] = true
	}
	files := map[string]bool{}
	for _, r := range rows {
		if strings.HasSuffix(r.File, ".flix") {
			files[r.File] = true
		}
	}
	names := make([]string, 0, len(files))
	for f := range files {
		names = append(names, f)
	}
	sort.Strings(names)
	var out []string
	for _, f := range names {
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			continue
		}
		for i, line := range strings.Split(string(b), "\n") {
			at := fmt.Sprintf("%s:%d", f, i+1)
			if word.MatchString(line) && !doneLines[at] {
				out = append(out, at)
			}
		}
	}
	return out
}
