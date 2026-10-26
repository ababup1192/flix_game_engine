package refactor

// search と outline: 宣言の行（show と同じ decl.tsv）から引く、読むだけの問い（cymbal の search・outline に当たる）。
//
//	search <名前の一部> [--kind def|enum|case|alias] [--all]   宣言の名前に当たる物を 1 行ずつ（本文は無し。読むのは show）
//	outline <file>[,<file>…]                                   そのファイルの宣言を行の順に、頭の行（シグネチャ）つきで
//
// search は使っている所を拾わない（grep -rn との違い）。当たりの並びは、名前がそのまま → 頭が同じ → 途中に含む、
// 語の頭（camelCase の大文字）から当たる → 途中に含む、同じ内なら src → test、名前の短い順。
// 索引を作った後に直したファイルは、索引の行の代わりに今のファイルの字から宣言を拾う（mod の直下の def・enum・
// type alias とその case）。作り直さずに答え、拾い方が違う事は行の末尾の「字」で言う。
//
// WhyNot: 直したファイルで作り直しを待たない。search と outline が返すのは名前と行だけで、字で拾っても
// ほぼ同じ答えになる。本文の範囲が要る show だけが作り直す。

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Found は search・outline の 1 件（--json の 1 件）。
type Found struct {
	Sym  string `json:"sym"`
	Kind string `json:"kind"` // def・enum・case・alias
	File string `json:"file"`
	Line int    `json:"line"`
	Pub  bool   `json:"pub"`
	Sig  string `json:"sig,omitempty"`  // outline: 宣言の頭の行
	Text bool   `json:"text,omitempty"` // 直したファイルを字で拾った
}

func (f Found) name() string { return lastName(f.Sym) }

// currentDecls は今のソースに合わせた宣言の行: 直していないファイルは索引の行、直したファイルは字で拾った行。
func (ds *declSet) currentDecls(src *srcCache) []Found {
	var out []Found
	for _, r := range ds.rows {
		if ds.changed[r.File] {
			continue
		}
		k := declKindName[r.Kind]
		pub := strings.Contains(" "+r.Extra+" ", " pub ")
		if r.Kind == KindCaseDecl || r.Kind == KindEnumDecl || r.Kind == KindAliasDecl {
			pub = declLineIsPub(src, r)
		}
		out = append(out, Found{Sym: r.Sym, Kind: k, File: r.File, Line: r.Line, Pub: pub})
	}
	files := make([]string, 0, len(ds.changed))
	for f := range ds.changed {
		files = append(files, f)
	}
	sort.Strings(files)
	for _, f := range files {
		out = append(out, textDecls(f, src.get(f))...)
	}
	return out
}

// declLineIsPub は enum・型 alias・case の宣言の行が pub か（索引の extra に pub を書くのは def だけ）。case は持つ enum の行を見る。
func declLineIsPub(src *srcCache, r Row) bool {
	lines := strings.Split(src.get(r.File), "\n")
	if r.Line < 1 || r.Line > len(lines) {
		return false
	}
	if r.Kind == KindCaseDecl {
		for i := r.Line - 1; i >= 0; i-- {
			if m := textDeclLine.FindStringSubmatch(lines[i]); m != nil && m[3] == "enum" {
				return m[2] != ""
			}
		}
		return false
	}
	return strings.Contains(lines[r.Line-1], "pub ")
}

var (
	textModLine  = regexp.MustCompile(`^mod\s+([A-Za-z0-9_.]+)`)
	textDeclLine = regexp.MustCompile(`^(    )(pub\s+)?(def|enum|type alias)\s+([A-Za-z_][A-Za-z0-9_]*)`)
	textCaseLine = regexp.MustCompile(`^        case\s+([A-Z][A-Za-z0-9_]*)`)
)

// textDecls はファイルの今の字から mod の直下の宣言を拾う（1 ファイル 1 mod・字下げ 4 の def・enum・type alias と、
// enum の中の字下げ 8 の case）。def の中の局所の def（字下げが深い）は拾わない。
func textDecls(file, text string) []Found {
	var out []Found
	mod := strings.TrimSuffix(filepath.Base(file), ".flix")
	enum := ""
	for i, l := range strings.Split(text, "\n") {
		if m := textModLine.FindStringSubmatch(l); m != nil {
			mod = m[1]
			continue
		}
		if m := textDeclLine.FindStringSubmatch(l); m != nil {
			kind := map[string]string{"def": "def", "enum": "enum", "type alias": "alias"}[m[3]]
			out = append(out, Found{Sym: mod + "." + m[4], Kind: kind, File: file, Line: i + 1, Pub: m[2] != "", Text: true})
			enum = ""
			if kind == "enum" {
				enum = mod + "." + m[4]
			}
			continue
		}
		if enum != "" {
			if m := textCaseLine.FindStringSubmatch(l); m != nil {
				out = append(out, Found{Sym: enum + "." + m[1], Kind: "case", File: file, Line: i + 1, Pub: true, Text: true})
			} else if strings.HasPrefix(l, "    }") {
				enum = ""
			}
		}
	}
	return out
}

// Search は q に名前が当たる宣言を当たりの良い順に。q に `.` があれば mod つきの名前の終わりと比べる。大文字小文字は見ない。
func Search(all []Found, q, kind string) []Found {
	lq := strings.ToLower(q)
	type hit struct {
		f    Found
		rank int
	}
	var hits []hit
	for _, f := range all {
		if kind != "" && f.Kind != kind {
			continue
		}
		name := strings.ToLower(f.name())
		if strings.Contains(q, ".") {
			name = strings.ToLower(f.Sym)
		}
		rank := -1
		switch {
		case name == lq || strings.HasSuffix(name, "."+lq):
			rank = 0
		case strings.HasPrefix(name, lq) || strings.Contains(name, "."+lq):
			rank = 1
		case camelHit(f.name(), q):
			rank = 2
		case strings.Contains(name, lq):
			rank = 3
		}
		if rank >= 0 {
			hits = append(hits, hit{f, rank})
		}
	}
	sort.SliceStable(hits, func(i, j int) bool {
		a, b := hits[i], hits[j]
		if a.rank != b.rank {
			return a.rank < b.rank
		}
		if ta, tb := strings.HasPrefix(a.f.File, "test/"), strings.HasPrefix(b.f.File, "test/"); ta != tb {
			return tb
		}
		if la, lb := len(a.f.name()), len(b.f.name()); la != lb {
			return la < lb
		}
		return a.f.Sym < b.f.Sym
	})
	out := make([]Found, len(hits))
	for i, h := range hits {
		out[i] = h.f
	}
	return out
}

// camelHit は q が name の語の頭（大文字の所）から当たるか（`enter` は pickEnterOf に当たり、center には当たらない）。
func camelHit(name, q string) bool {
	ln, lq := strings.ToLower(name), strings.ToLower(q)
	for i := 1; i < len(name); i++ {
		if name[i] >= 'A' && name[i] <= 'Z' && strings.HasPrefix(ln[i:], lq) {
			return true
		}
	}
	return false
}

// Outline は file の宣言を行の順に、頭の行（字下げを落として 120 字まで）つきで。
func Outline(all []Found, file string, src *srcCache) []Found {
	lines := strings.Split(src.get(file), "\n")
	var out []Found
	enumAt := map[int]bool{}
	for _, f := range all {
		if f.File == file && f.Kind == "enum" {
			enumAt[f.Line] = true
		}
	}
	for _, f := range all {
		if f.File != file || f.Kind == "case" && enumAt[f.Line] {
			continue // 1 行の enum（enum Battle(BattleRec)）の case は enum の行と同じなので出さない
		}
		if f.Line >= 1 && f.Line <= len(lines) {
			f.Sig = clipRunes(strings.TrimSpace(lines[f.Line-1]), 120)
		}
		out = append(out, f)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Line < out[j].Line })
	return out
}

func clipRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// searchLimit は --all でない時に search が見せる数の上限。
const searchLimit = 30

// listRun は search・outline の答えを書く。終了コード: 0 当たりあり・1 当たりなし・2 呼び方か索引の誤り。
func listRun(out, errOut *strings.Builder, b Builder, s Stage, a args) int {
	ds, err := b.LoadDecls(s)
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		return 2
	}
	src := &srcCache{root: b.Root}
	all := ds.currentDecls(src)
	var found []Found
	if a.op == "search" {
		found = Search(all, a.target, a.kind)
	} else {
		for _, f := range strings.Split(a.target, ",") {
			f = filepath.ToSlash(filepath.Clean(f))
			if src.get(f) == "" {
				fmt.Fprintf(errOut, "refactor outline: %s が読めません（根からの相対パスで。例 src/World.flix）\n", f)
				return 2
			}
			found = append(found, Outline(all, f, src)...)
		}
	}
	code := 0
	if len(found) == 0 {
		code = 1
	}
	if a.asJSON {
		js, _ := json.Marshal(map[string]any{"op": a.op, "target": a.target, "found": found, "stale": len(ds.changed), "exit": code})
		out.Write(js)
		out.WriteString("\n")
		return code
	}
	shown := found
	if a.op == "search" && !a.all && len(shown) > searchLimit {
		shown = shown[:searchLimit]
	}
	switch a.op {
	case "search":
		fmt.Fprintf(out, "search %s: %d 件\n", a.target, len(found))
		for _, f := range shown {
			fmt.Fprintf(out, "  %s:%d  %s %s%s\n", f.File, f.Line, f.Kind, f.Sym, foundMarks(f))
		}
		if len(shown) < len(found) {
			fmt.Fprintf(out, "  …ほか %d 件（--all で全部・--kind def|enum|case|alias で絞る）\n", len(found)-len(shown))
		}
	default:
		file := ""
		for _, f := range shown {
			if f.File != file {
				file = f.File
				fmt.Fprintf(out, "outline %s\n", file)
			}
			indent := "  "
			if f.Kind == "case" {
				indent = "      "
			}
			fmt.Fprintf(out, "%s%d  %s%s\n", indent, f.Line, f.Sig, foundMarks(Found{Text: f.Text}))
		}
	}
	if len(ds.changed) > 0 {
		fmt.Fprintf(out, "（索引の後に直したファイル %d は今の字から拾った: 行の末尾の「字」）\n", len(ds.changed))
	}
	return code
}

func foundMarks(f Found) string {
	m := ""
	if f.Pub && f.Kind != "case" {
		m += "  pub"
	}
	if f.Text {
		m += "  字"
	}
	return m
}
