package yarn

// .yarn の読み手。公式の Yarn Spinner の文法のうち、会話を書くのに要る部分集合だけを読む:
// ノード（title: 〜 --- 〜 ===）・ヘッダ・行（話し手: 台詞）・タグ・-> の選択肢と字下げ・
// <<jump>>・<<stop>>・コマンド・コメント・エスケープ。
// それ以外の公式の構文（変数・<<if>>・関数・detour・{式}・マークアップ…）は、行番号つきで
// 「読まない・代わりにこう書く」と断る。読める物の意味は公式と同じにする（公式なら別の意味になる書き方も断る）。
//
// 字下げの扱いは公式の IndentAwareLexer を写している: 字下げに意味があるのは -> の行の直後だけで、
// -> の行より深い行が続けばその選択肢の中身になり、浅い行が来たら抜ける。
// -> の行（か中身を抜けた行）の直後の空行は、選択肢のまとまりを終える。

import (
	"fmt"
	"strings"
	"unicode"
)

// Problem は 1 件の知らせ（ファイル:行: 文）。Unsupported は公式にはあるが読まない構文。
type Problem struct {
	File        string
	Line        int
	Msg         string
	Unsupported bool
}

func (p Problem) String() string {
	return fmt.Sprintf("%s:%d: %s", p.File, p.Line, p.Msg)
}

type parser struct {
	file     string
	problems []Problem
}

func (p *parser) fail(line int, format string, args ...any) {
	p.problems = append(p.problems, Problem{File: p.file, Line: line, Msg: fmt.Sprintf(format, args...)})
}

func (p *parser) refuse(line int, what, instead string) {
	p.problems = append(p.problems, Problem{File: p.file, Line: line,
		Msg: fmt.Sprintf("読まない: %s — 代わりに: %s", what, instead), Unsupported: true})
}

// ParseFile は 1 つの .yarn を読む。file は知らせと木に書く名前（ゲームのルートからのパス）。
func ParseFile(file, text string) ([]*Node, []Problem) {
	p := &parser{file: file}
	lines := strings.Split(strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n"), "\n")
	var nodes []*Node
	i := 0
	for i < len(lines) {
		node, next := p.node(lines, i)
		if node != nil {
			nodes = append(nodes, node)
		}
		if next <= i {
			break
		}
		i = next
	}
	return nodes, p.problems
}

// node はヘッダから === までを読み、次に読む行の番号を返す（ノードが無ければ nil）。
func (p *parser) node(lines []string, start int) (*Node, int) {
	var node *Node
	headers := []Header{}
	first := 0
	i := start
	for ; i < len(lines); i++ {
		raw := lines[i]
		trimmed := strings.TrimSpace(stripHeaderComment(raw))
		lineNo := i + 1
		if trimmed == "" {
			continue
		}
		if first == 0 {
			first = lineNo
		}
		if trimmed == "---" {
			if node == nil {
				p.fail(lineNo, "title: の無いノード（--- の前に title: <名前> を書く）")
				node = &Node{File: p.file, Line: first}
			}
			node.Headers = headers
			body, next, closed := p.body(lines, i+1)
			node.Body = body
			if !closed {
				p.fail(lineNo, "ノード %s が === で閉じていない", node.Title)
			}
			return node, next
		}
		if trimmed == "===" {
			p.fail(lineNo, "--- の無いノード（ヘッダの後に --- を書いてから本文）")
			return node, i + 1
		}
		if strings.HasPrefix(trimmed, "#") && node == nil && len(headers) == 0 {
			p.refuse(lineNo, "ファイルの頭のタグ（#…）", "タグは行の後ろに書く")
			continue
		}
		key, value, ok := strings.Cut(trimmed, ":")
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if !ok || !isIdentifier(key) {
			p.fail(lineNo, "ヘッダは「名前: 値」の形で書く（読めない: %s）", trimmed)
			continue
		}
		switch key {
		case "title":
			if !isIdentifier(value) {
				p.fail(lineNo, "ノードの名前 %q は英数字と _ で書く（空白や記号は使えない）", value)
			}
			if node != nil {
				p.fail(lineNo, "title: が 2 つある（ノードは --- と === で区切る）")
			}
			node = &Node{Title: value, File: p.file, Line: lineNo}
		case "when":
			p.refuse(lineNo, "when: ヘッダ（ノードのグループ）", "どのノードを開くかはゲームのコードで決める")
		default:
			headers = append(headers, Header{Key: key, Value: value})
		}
	}
	if node != nil {
		p.fail(node.Line, "ノード %s に本文が無い（--- の後に本文を書き、=== で閉じる）", node.Title)
	} else if len(headers) > 0 {
		p.fail(first, "title: の無いヘッダ")
	}
	return node, i
}

// stripHeaderComment はヘッダの行の // から後ろを落とす。
func stripHeaderComment(s string) string {
	if k := strings.Index(s, "//"); k >= 0 {
		return s[:k]
	}
	return s
}

// ── 本文: 行を字下げのマーカーつきの並びにしてから、文法どおりに組む ──

type tokKind int

const (
	tLine tokKind = iota
	tIndent
	tDedent
	tBlankAfterOption
)

type bodyLine struct {
	no      int
	indent  int
	content string // 頭の空白を落とした行（コメントは残したまま）
	blank   bool   // 空か空白だけ（コメントだけの行は空行ではない）
	empty   bool   // 文が無い（空行かコメントだけ）
	arrow   bool
}

type tok struct {
	kind tokKind
	line bodyLine
}

// body は --- の次の行から === までを読む。closed は === で閉じたか。
func (p *parser) body(lines []string, start int) ([]*Stmt, int, bool) {
	var bl []bodyLine
	end := len(lines)
	closed := false
	for i := start; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "===" {
			end = i
			closed = true
			break
		}
		bl = append(bl, toBodyLine(i+1, lines[i]))
	}
	toks := indentTokens(bl)
	bp := &bodyParser{p: p, toks: toks}
	stmts := bp.statements(false)
	next := end
	if closed {
		next = end + 1
	}
	return stmts, next, closed
}

func toBodyLine(no int, raw string) bodyLine {
	indent := 0
	k := 0
	for k < len(raw) && (raw[k] == ' ' || raw[k] == '\t') {
		if raw[k] == '\t' {
			indent += 8
		} else {
			indent++
		}
		k++
	}
	content := raw[k:]
	stripped := strings.TrimSpace(stripComment(content))
	return bodyLine{
		no:      no,
		indent:  indent,
		content: content,
		blank:   strings.TrimSpace(content) == "",
		empty:   stripped == "",
		arrow:   strings.HasPrefix(content, "->"),
	}
}

// indentTokens は公式の IndentAwareLexer.HandleNewLineToken と同じ順で、行の間に字下げのマーカーを挟む。
func indentTokens(lines []bodyLine) []tok {
	var out []tok
	var stack []int
	lastIndent := 0
	lineHasArrow := false
	lastSeen := -1
	for i, l := range lines {
		prevBlank := i > 0 && lines[i-1].blank
		if lastSeen != -1 && prevBlank {
			if l.no-lastSeen == 1 {
				out = append(out, tok{kind: tBlankAfterOption, line: l})
			}
			lastSeen = -1
		}
		if lineHasArrow {
			if l.indent > lastIndent {
				stack = append(stack, l.indent)
				out = append(out, tok{kind: tIndent, line: l})
			}
			lineHasArrow = false
			lastSeen = l.no
		}
		for len(stack) > 0 && l.indent < stack[len(stack)-1] {
			out = append(out, tok{kind: tDedent, line: l})
			stack = stack[:len(stack)-1]
			if len(stack) == 0 {
				lastSeen = l.no
			}
		}
		lastIndent = l.indent
		if !l.empty {
			out = append(out, tok{kind: tLine, line: l})
		}
		if l.arrow {
			lineHasArrow = true
		}
	}
	for range stack {
		out = append(out, tok{kind: tDedent})
	}
	return out
}

type bodyParser struct {
	p    *parser
	toks []tok
	pos  int
}

func (b *bodyParser) peek() (tok, bool) {
	if b.pos < len(b.toks) {
		return b.toks[b.pos], true
	}
	return tok{}, false
}

// statements は文を並べて読む。inBlock なら対の Dedent で戻る。
func (b *bodyParser) statements(inBlock bool) []*Stmt {
	out := []*Stmt{}
	for {
		t, ok := b.peek()
		if !ok {
			return out
		}
		switch t.kind {
		case tDedent:
			b.pos++
			if inBlock {
				return out
			}
		case tIndent:
			b.pos++
			out = append(out, b.statements(true)...)
		case tBlankAfterOption:
			b.pos++
		case tLine:
			if t.line.arrow {
				out = append(out, b.optionGroup())
			} else {
				b.pos++
				if s := b.p.statement(t.line); s != nil {
					out = append(out, s)
				}
			}
		}
	}
}

// optionGroup は続く -> を 1 つのまとまりに読む（空行のマーカーか -> でない文で終わる）。
func (b *bodyParser) optionGroup() *Stmt {
	group := &Stmt{Kind: "options"}
	for {
		t, ok := b.peek()
		if !ok || t.kind != tLine || !t.line.arrow {
			break
		}
		b.pos++
		if group.Line == 0 {
			group.Line = t.line.no
		}
		opt := &Option{Line: t.line.no, Body: []*Stmt{}}
		l := b.p.lineContent(t.line.no, strings.TrimSpace(t.line.content[2:]))
		if l != nil {
			opt.Speaker, opt.Text, opt.Tags = l.Speaker, l.Text, l.Tags
		}
		if n, ok := b.peek(); ok && n.kind == tIndent {
			b.pos++
			opt.Body = b.statements(true)
			if len(opt.Body) == 0 {
				b.p.fail(t.line.no, "-> の後の字下げした行に文が無い（中身の無い選択肢は字下げした行を書かない）")
			}
		}
		group.Options = append(group.Options, opt)
		if n, ok := b.peek(); ok && n.kind == tBlankAfterOption {
			b.pos++
			break
		}
	}
	return group
}

// ── 1 行の文 ──

var refusedCommands = map[string][2]string{
	"if":      {"<<if>>（条件分岐）", "分岐はノードを分け、どのノードを開くかはゲームのコードで決める"},
	"elseif":  {"<<elseif>>（条件分岐）", "分岐はノードを分け、どのノードを開くかはゲームのコードで決める"},
	"else":    {"<<else>>（条件分岐）", "分岐はノードを分け、どのノードを開くかはゲームのコードで決める"},
	"endif":   {"<<endif>>（条件分岐）", "分岐はノードを分け、どのノードを開くかはゲームのコードで決める"},
	"set":     {"<<set>>（変数）", "状態はゲームの World に持ち、選んだ結果は #タグ でゲームへ渡す"},
	"declare": {"<<declare>>（変数）", "状態はゲームの World に持ち、選んだ結果は #タグ でゲームへ渡す"},
	"local":   {"<<local>>（変数）", "状態はゲームの World に持つ"},
	"enum":    {"<<enum>>（変数の型）", "取りうる値はゲームのコードの enum に書き、シナリオではタグの値で選ぶ"},
	"case":    {"<<case>>（変数の型）", "取りうる値はゲームのコードの enum に書き、シナリオではタグの値で選ぶ"},
	"endenum": {"<<endenum>>（変数の型）", "取りうる値はゲームのコードの enum に書き、シナリオではタグの値で選ぶ"},
	"call":    {"<<call>>（関数）", "計算はゲームのコードで行う"},
	"detour":  {"<<detour>>", "<<jump ノード名>> で続きのノードへ移る（戻り先は持たない）"},
	"return":  {"<<return>>（detour の戻り）", "<<stop>> で会話を終える"},
	"once":    {"<<once>>", "一度きりかどうかはゲームのコードで決め、開くノードを分ける"},
	"endonce": {"<<endonce>>", "一度きりかどうかはゲームのコードで決め、開くノードを分ける"},
}

func (p *parser) statement(l bodyLine) *Stmt {
	content := strings.TrimSpace(l.content)
	switch {
	case strings.HasPrefix(content, "=>"):
		p.refuse(l.no, "=> の行のグループ", "言い回しを変えたいならノードを分け、どれを開くかはゲームのコードで決める")
		return nil
	case strings.HasPrefix(content, "<<"):
		return p.command(l.no, content)
	}
	return p.lineContent(l.no, content)
}

func (p *parser) command(no int, content string) *Stmt {
	close := strings.Index(content, ">>")
	if close < 0 {
		p.fail(no, "<< を閉じる >> が無い（コマンドは 1 行で書く）")
		return nil
	}
	inner := strings.TrimSpace(content[2:close])
	tags, ok := p.trailingTags(no, content[close+2:])
	if !ok {
		return nil
	}
	if inner == "" {
		p.fail(no, "中身の無い <<>>")
		return nil
	}
	if strings.ContainsAny(inner, "{}") {
		p.refuse(no, "コマンドの中の {式}", "値をそのまま書く")
		return nil
	}
	fields := strings.Fields(inner)
	name, args := fields[0], fields[1:]
	if r, refused := refusedCommands[name]; refused {
		p.refuse(no, r[0], r[1])
		return nil
	}
	switch name {
	case "jump":
		if len(args) != 1 || !isIdentifier(args[0]) {
			p.fail(no, "<<jump>> はノード名を 1 つ書く（<<jump ノード名>>）")
			return nil
		}
		return &Stmt{Kind: "jump", Line: no, Node: args[0], Tags: tags}
	case "stop":
		if len(args) != 0 {
			p.fail(no, "<<stop>> は何も受け取らない")
			return nil
		}
		return &Stmt{Kind: "stop", Line: no, Tags: tags}
	}
	return &Stmt{Kind: "command", Line: no, Name: name, Args: args, Tags: tags}
}

// trailingTags は文の後ろ（>> の後）のタグとコメントを読む。それ以外の字があれば知らせて false。
func (p *parser) trailingTags(no int, rest string) ([]Tag, bool) {
	rest = strings.TrimSpace(stripComment(rest))
	if rest == "" {
		return nil, true
	}
	if !strings.HasPrefix(rest, "#") {
		if strings.HasPrefix(rest, "<<") {
			p.refuse(no, "1 行に 2 つの <<…>>", "コマンドは 1 行に 1 つ")
		} else {
			p.fail(no, ">> の後ろに文字は書かない（読めない: %s）", rest)
		}
		return nil, false
	}
	return p.tags(no, rest)
}

// tags は # で始まる残りを読む（区切りは空白か次の #。<< が来たら行の条件として断る）。
func (p *parser) tags(no int, rest string) ([]Tag, bool) {
	var out []Tag
	s := rest
	for {
		s = strings.TrimLeft(s, " \t")
		if s == "" {
			return out, true
		}
		if strings.HasPrefix(s, "<<") {
			p.refuse(no, "タグの後ろの <<…>>（行の条件）", "条件で出し分ける行はノードを分け、どれを開くかはゲームのコードで決める")
			return nil, false
		}
		if strings.HasPrefix(s, "//") {
			return out, true
		}
		if s[0] != '#' {
			p.fail(no, "タグの後ろに文字は書かない（読めない: %s）", s)
			return nil, false
		}
		s = s[1:]
		k := strings.IndexAny(s, " \t#$<")
		body := s
		if k >= 0 {
			body, s = s[:k], s[k:]
		} else {
			s = ""
		}
		if body == "" {
			p.fail(no, "# の後ろが空のタグ")
			return nil, false
		}
		key, value, _ := strings.Cut(body, ":")
		out = append(out, Tag{Key: key, Value: value})
	}
}

// lineContent は台詞の 1 行（-> の後ろも同じ）を読む: エスケープを解き、話し手とタグを分ける。
func (p *parser) lineContent(no int, content string) *Stmt {
	var text strings.Builder
	var colons []int // エスケープしていない : の位置（text の中の byte 位置）
	rs := []rune(content)
	var tags []Tag
	for i := 0; i < len(rs); i++ {
		c := rs[i]
		switch {
		case c == '\\':
			if i+1 >= len(rs) {
				p.fail(no, "行の終わりの \\（字そのものは \\\\ と書く）")
				return nil
			}
			n := rs[i+1]
			if !strings.ContainsRune(`\<>{}#/[]:`, n) {
				p.fail(no, "\\%c は書けない（\\ を前に置けるのは \\ < > { } # / [ ] : だけ）", n)
				return nil
			}
			text.WriteRune(n)
			i++
		case c == '/' && i+1 < len(rs) && rs[i+1] == '/':
			i = len(rs)
		case c == '#':
			t, ok := p.tags(no, string(rs[i:]))
			if !ok {
				return nil
			}
			tags = t
			i = len(rs)
		case c == '<' && i+1 < len(rs) && rs[i+1] == '<':
			p.refuse(no, "行の後ろの <<…>>（行の条件）", "条件で出し分ける行はノードを分け、どれを開くかはゲームのコードで決める（字の << は \\<\\< と書く）")
			return nil
		case c == '{':
			p.refuse(no, "行の中の {式}", "台詞は書いたとおりに出す（差し込む値はゲームが持つ）。字の { は \\{ と書く")
			return nil
		case c == '[':
			p.refuse(no, "[…] のマークアップ", "字の [ は \\[ と書く（色や揺れは描く側で付ける）")
			return nil
		case c == ':':
			colons = append(colons, text.Len())
			text.WriteRune(c)
		default:
			text.WriteRune(c)
		}
	}
	full := strings.TrimRightFunc(text.String(), unicode.IsSpace)
	speaker, body := "", full
	if len(colons) > 0 && colons[0] < len(full) {
		name := strings.TrimSpace(full[:colons[0]])
		if name != "" {
			speaker = name
			body = strings.TrimLeftFunc(full[colons[0]+1:], unicode.IsSpace)
		}
	}
	if body == "" {
		p.fail(no, "台詞の無い行（タグだけの行・字の無い -> は書けない）")
		return nil
	}
	return &Stmt{Kind: "line", Line: no, Speaker: speaker, Text: body, Tags: tags}
}

// stripComment はエスケープしていない // から後ろを落とす。
func stripComment(s string) string {
	rs := []rune(s)
	for i := 0; i < len(rs); i++ {
		if rs[i] == '\\' {
			i++
			continue
		}
		if rs[i] == '/' && i+1 < len(rs) && rs[i+1] == '/' {
			return string(rs[:i])
		}
	}
	return s
}

// isIdentifier は公式の ID（頭は字か _、続きは字・数字・_）か。
func isIdentifier(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		ok := r == '_' || unicode.IsLetter(r) || (i > 0 && unicode.IsDigit(r))
		if !ok {
			return false
		}
	}
	return true
}
