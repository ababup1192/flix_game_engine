package refactor

// .flix の外で def の名前が出る所。2 つに分けて見る:
//   - 入口: 名前で呼ばれうるファイル（Makefile・mk・json・flow・sh など、文章でない git の知るファイル）に字で出る
//     `Mod.name`（JSON は字の値がまるごと名前の物だけ。note の文の中の名前は数えない）。消す・pub を外すと呼ぶ側が壊れるかもしれないので、remove-dead・make-private は人へ回す。
//   - 文書の名指し: bin/fge doc-refs が見る文書（.md と .flix のコメント）が、doc-refs と同じ決まり（` ` の中・表の行の
//     Mod.name。予定の印・消し線・引用は数えない）で指す名前。消しても壊れる物は無く、doc-refs が止めるだけなので、
//     消した後の next で文書を直す道を示す。pub を外すだけなら名前は残るので見ない。
//
// WhyNot: 文章（.md・.txt・.diff など）を入口として数えない。NOTES.md・計画の diff・記録には短い名前（foe・one）が
// いつも字で出て、それだけで道具が断ると人へ回る物ばかりになる（Mac mini の lintgap で多くが手に回った）。
// 文章が名前を指すかは doc-refs の決まりに任せ、決まりの外の文章（doc-refs が見ない記録）は数えない。

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/docrefs"
)

// proseExts は文章のファイルの末尾（入口として数えない）。
var proseExts = map[string]bool{".md": true, ".markdown": true, ".txt": true, ".diff": true, ".patch": true,
	".html": true, ".htm": true, ".rst": true, ".adoc": true, ".org": true}

// Mentions は .flix の外で名前が出る所。
type Mentions struct {
	Entry map[string]string // Mod.name → 最初に出た入口のファイル
	docs  []docMention
	// DocRules は文書を見た規約の置き場（無ければ ""。その時は文書を見ていない）。
	DocRules string
}

// docMention は文書が名指す名前 1 つ（key は索引で引く形・file:line で場所）。
type docMention struct {
	key, file string
	line      int
}

// loadMentions は根 root（と engine の Makefile・mk/）の入口と、doc-refs の規約（根の物、無ければ engine の物）で
// 文書の名指しを拾う。
func loadMentions(root, engine string) Mentions {
	m := Mentions{Entry: map[string]string{}}
	scan(m.Entry, root, func(f string) bool { return !proseExts[strings.ToLower(filepath.Ext(f))] })
	if engine != "" && engine != root {
		// engine の側は、ゲームの make が読む物だけ（Makefile・mk/）。
		scan(m.Entry, engine, func(f string) bool { return f == "Makefile" || strings.HasPrefix(f, "mk/") })
	}
	rules, err := docrefs.LoadRules(root)
	m.DocRules = root
	if err != nil && engine != "" {
		rules, err = docrefs.LoadRules(engine)
		m.DocRules = engine
	}
	if err != nil {
		m.DocRules = ""
		return m
	}
	for _, f := range append(rules.Docs(root), rules.FlixDocs(root)...) {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(f)))
		if err != nil {
			continue
		}
		for _, r := range rules.Refs(f, string(body)) {
			if r.Kind == docrefs.RefName && !r.Planned && !r.Engine {
				m.docs = append(m.docs, docMention{key: r.Key(), file: f, line: r.Line})
			}
		}
	}
	return m
}

// DocsNaming は文書が sym を名指す所（file:line）。書き方は doc-refs と同じく後ろから当てる（`Side.foe` は
// Battle.Side.foe）。skip（file と行）が真の所は数えない（一緒に消える宣言の中のコメント）。
func (m Mentions) DocsNaming(sym string, skip func(file string, line int) bool) []string {
	var out []string
	seen := map[string]bool{}
	for _, d := range m.docs {
		if d.key != sym && !strings.HasSuffix(sym, "."+d.key) {
			continue
		}
		if skip != nil && skip(d.file, d.line) {
			continue
		}
		at := d.file + ":" + strconv.Itoa(d.line)
		if !seen[at] {
			seen[at] = true
			out = append(out, at)
		}
	}
	return out
}

// withEntryDefs は入口の表（EntryTables の名前の def。常駐の jobs() など）の中から使う def と、入口のファイルに Mod.x が
// 字で出る時の Mod.xJob（常駐の入口の決まり: 入口の名前 Mod.x の中身は xJob）を、入口として Entry に足す。
// WhyNot: 字（Makefile・json）だけを見ると、常駐の表は .flix の中で同じ mod から呼ぶので外の使い手が 0 に見え、
// make-private が pub を外し、remove-dead が消せる物に数える（入口は名前で呼ばれる）。
func (m Mentions) withEntryDefs(rows []Row, tables []string) Mentions {
	isTable := map[string]bool{}
	for _, t := range tables {
		isTable[t] = true
	}
	for _, r := range rows {
		if r.Kind != KindDefUse || !isTable[shortName(r.Owner)] || r.Sym == r.Owner {
			continue
		}
		if _, ok := m.Entry[r.Sym]; !ok {
			m.Entry[r.Sym] = "入口の表 " + r.Owner + "()"
		}
	}
	for _, r := range rows {
		if r.Kind != KindDefDecl || !strings.HasSuffix(r.Sym, "Job") || len(shortName(r.Sym)) <= 3 {
			continue
		}
		if f, ok := m.Entry[strings.TrimSuffix(r.Sym, "Job")]; ok {
			if _, has := m.Entry[r.Sym]; !has {
				m.Entry[r.Sym] = f + "（入口 " + strings.TrimSuffix(r.Sym, "Job") + " の中身）"
			}
		}
	}
	return m
}
