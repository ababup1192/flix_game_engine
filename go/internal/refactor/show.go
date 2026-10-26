package refactor

// show: 名前で宣言の本文だけを読む（cymbal の show に当たる、読むだけの問い）。
//
//	show <Mod.f | Enum | Enum.Case | Alias>[,<名前>…]   宣言の頭の /// と注記から本文の終わりまで
//
// grep で宣言の行を探し、Read の offset/limit で範囲を当て推量する 2 手を 1 手にする。
// 名前はコンパイラが解決した symbol で当てる（usages と同じ ResolveTarget。2 つ以上に当たれば候補を並べて止まる）。
// def の範囲は索引の ext=（shim が書く宣言の範囲。/// から本文の終わりまで）。enum と型 alias は索引に範囲が無いので、
// 宣言の名前の所から括弧を数えて終わりを決め、上へ /// と @ の行を足す。case はそれを持つ enum を見せる。
//
// WhyNot: 行番号を頭に付けない。読んだ字をそのまま Edit に渡せるようにし、行は頭の 1 行の範囲（file:始め-終わり）で言う。

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Shown は show が見せる宣言 1 つ（--json の 1 件）。
type Shown struct {
	Name  string `json:"name"` // 書かれた名前
	Sym   string `json:"sym"`
	Kind  string `json:"kind"` // def・enum・alias（case は enum を見せ、via に case を書く）
	Via   string `json:"via,omitempty"`
	File  string `json:"file"`
	Start int    `json:"start"`
	End   int    `json:"end"`
	Text  string `json:"text"`
}

// ShowDecl は q の宣言の本文を返す。
func ShowDecl(rows []Row, q string, src *srcCache) (Shown, error) {
	t, err := ResolveTarget(rows, q)
	if err != nil {
		return Shown{}, err
	}
	s := Shown{Name: q, Sym: t.Sym, Kind: t.Kind}
	sym := t.Sym
	if t.Kind == "case" {
		sym = parentSym(t.Sym)
		s.Kind, s.Via, s.Sym = "enum", t.Sym, sym
	}
	want := map[string]string{"def": KindDefDecl, "enum": KindEnumDecl, "alias": KindAliasDecl}[s.Kind]
	var decl *Row
	for i := range rows {
		if rows[i].Kind == want && rows[i].Sym == sym {
			decl = &rows[i]
			break
		}
	}
	if decl == nil {
		return Shown{}, fmt.Errorf("%s（%s）の宣言は索引の外（パッケージの物）。engine の物は make api Q=%s", q, s.Kind, lastName(sym))
	}
	text := src.get(decl.File)
	if text == "" {
		return Shown{}, fmt.Errorf("%s が読めません", decl.File)
	}
	lines := strings.Split(text, "\n")
	start, end := declRange(*decl, lines)
	if start < 1 || end > len(lines) || start > end {
		return Shown{}, fmt.Errorf("%s の範囲 %d-%d がファイルの外（索引が古い。bin/fge refactor index --rebuild）", q, start, end)
	}
	s.File, s.Start, s.End = decl.File, start, end
	s.Text = strings.Join(lines[start-1:end], "\n")
	return s, nil
}

func parentSym(sym string) string {
	if i := strings.LastIndex(sym, "."); i > 0 {
		return sym[:i]
	}
	return sym
}

func lastName(sym string) string { return sym[strings.LastIndex(sym, ".")+1:] }

// declRange は宣言の行の範囲（1 から・両端を含む）。
func declRange(r Row, lines []string) (int, int) {
	if ext := r.Attr("ext"); ext != "" {
		if p := strings.Split(ext, ":"); len(p) == 4 {
			s, e1 := strconv.Atoi(p[0])
			e, e2 := strconv.Atoi(p[2])
			if e1 == nil && e2 == nil {
				return withLeadingDoc(s, lines), e
			}
		}
	}
	return withLeadingDoc(r.Line, lines), bodyEnd(r, lines)
}

// withLeadingDoc は start の上に続く ///・@ の行を範囲に入れる（ext= は /// から始まるので、足す物が無ければそのまま）。
func withLeadingDoc(start int, lines []string) int {
	for start > 1 {
		t := strings.TrimSpace(lines[start-2])
		if !strings.HasPrefix(t, "///") && !strings.HasPrefix(t, "@") {
			break
		}
		start--
	}
	return start
}

// bodyEnd は宣言の名前の所から括弧（{ [ (）を数え、深さ 0 で改行に来た行を終わりにする。
// enum は `{` を開いてから、型 alias は `=` を過ぎてから数え始める（`enum E[a]` の [ や、本文の無い enum で止まらないように）。
// 字の列とコメントの中の括弧は数えない。
func bodyEnd(r Row, lines []string) int {
	depth, started, opened := 0, false, false
	for i := r.Line - 1; i < len(lines); i++ {
		line := lines[i]
		from := 0
		if i == r.Line-1 {
			from = utf16Col(line, r.Col)
		}
		inStr := false
		for j := from; j < len(line); j++ {
			c := line[j]
			if inStr {
				if c == '\\' {
					j++
				} else if c == '"' {
					inStr = false
				}
				continue
			}
			switch {
			case c == '"':
				inStr = true
			case c == '/' && j+1 < len(line) && line[j+1] == '/':
				j = len(line)
			case c == '=' && !started:
				started = true
			case c == '{' || c == '[' || c == '(':
				if c == '{' {
					started = true
				}
				if started {
					depth++
					opened = true
				}
			case c == '}' || c == ']' || c == ')':
				if started {
					depth--
				}
			}
		}
		if started && depth <= 0 && (opened || strings.Contains(line[from:], "=")) {
			if !opened && i+1 < len(lines) && continues(lines[i+1]) {
				continue
			}
			return i + 1
		}
	}
	return len(lines)
}

// continues は次の行が前の行の続き（`|` や `->` で始まる型の続き）か。
func continues(next string) bool {
	t := strings.TrimSpace(next)
	return strings.HasPrefix(t, "|") || strings.HasPrefix(t, "->") || strings.HasPrefix(t, "+") || strings.HasPrefix(t, "&")
}

// utf16Col は 1 から数えた UTF-16 の列を、その行のバイトの位置に直す。
func utf16Col(line string, col int) int {
	n := 1
	for i, r := range line {
		if n >= col {
			return i
		}
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return len(line)
}

// showRun は show の答えを書く。終了コード: 0 全部見せた・2 1 つでも見せられない（見せられた物は書く）。
func showRun(out, errOut *strings.Builder, root string, idx *Index, a args) int {
	src := &srcCache{root: root}
	var shown []Shown
	code := 0
	for _, q := range strings.Split(a.target, ",") {
		q = strings.TrimSpace(q)
		if q == "" {
			continue
		}
		s, err := ShowDecl(idx.Rows, q, src)
		if err != nil {
			fmt.Fprintf(errOut, "refactor show: %v\n", err)
			code = 2
			continue
		}
		shown = append(shown, s)
	}
	if a.asJSON {
		b, _ := json.Marshal(map[string]any{"op": "show", "shown": shown, "exit": code})
		out.Write(b)
		out.WriteString("\n")
		return code
	}
	for i, s := range shown {
		if i > 0 {
			out.WriteString("\n")
		}
		kind := s.Kind
		if s.Via != "" {
			kind += "・" + s.Via + " を持つ"
		}
		fmt.Fprintf(out, "── %s:%d-%d  %s（%s）\n%s\n", s.File, s.Start, s.End, s.Sym, kind, s.Text)
	}
	return code
}
