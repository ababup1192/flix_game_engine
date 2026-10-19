package yarn

// .yarn の読み手。公式の Yarn Spinner の文法のうち、会話を書くのに要る部分集合だけを読む:
// ノード（title: 〜 --- 〜 ===）・ヘッダ・行（話し手: 台詞）・タグ・-> の選択肢と字下げ・
// <<jump>>・<<stop>>・コマンド・コメント・エスケープ・変数（<<declare>>・<<set>>）・
// <<if>>〜<<endif>>・選択肢の行末の <<if>>・行の中の {式}（式は expr.go）。
// それ以外の公式の構文（関数の自作・detour・<<once>>・マークアップ…）は、行番号つきで
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
	declared []*Variable // 読んでいるノードの <<declare>>
}

func (p *parser) fail(line int, format string, args ...any) {
	p.problems = append(p.problems, Problem{File: p.file, Line: line, Msg: fmt.Sprintf(format, args...)})
}

// failExpr は式の誤りを知らせる（読まない書き方なら「読まない」の印を付ける）。
func (p *parser) failExpr(line int, where string, err error) {
	p.problems = append(p.problems, Problem{File: p.file, Line: line, Msg: where + ": " + err.Error(), Unsupported: isRefusal(err)})
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
			node.declared, p.declared = p.declared, nil
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
		case "tracking":
			p.refuse(lineNo, "tracking: ヘッダ", "訪れた数はどのノードも数える（visited を使わなければ数えても何も変わらない）")
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
	stmts := bp.statements(false, false)
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

// statements は文を並べて読む。inBlock なら対の Dedent で戻る（Dedent は読む）。
// inIf なら <<elseif>>・<<else>>・<<endif>> の行か Dedent の手前で戻る（どちらも読まずに、外の読み手へ残す）。
func (b *bodyParser) statements(inBlock, inIf bool) []*Stmt {
	out := []*Stmt{}
	for {
		t, ok := b.peek()
		if !ok {
			return out
		}
		switch t.kind {
		case tDedent:
			if inIf {
				return out
			}
			b.pos++
			if inBlock {
				return out
			}
		case tIndent:
			b.pos++
			out = append(out, b.statements(true, false)...)
		case tBlankAfterOption:
			b.pos++
		case tLine:
			if t.line.arrow {
				out = append(out, b.optionGroup())
				continue
			}
			switch c := b.p.controlOf(t.line); c.name {
			case "if":
				b.take(t.line, c)
				out = append(out, b.ifBlock(t.line, c))
			case "elseif", "else", "endif":
				if inIf {
					return out
				}
				b.take(t.line, c)
				b.p.fail(t.line.no, "対の <<if>> が無い <<%s>>", c.name)
			default:
				b.pos++
				if s := b.p.statement(t.line); s != nil {
					out = append(out, s)
				}
			}
		}
	}
}

// control は <<if>>・<<elseif>>・<<else>>・<<endif>> の行（name が空ならそれ以外の行）。
type control struct {
	name string
	rest string // 名前の後ろ（<<if>> と <<elseif>> の式）
	tail string // >> の後ろのコメントでない字（あれば読んだ所で知らせる）
}

// commandName はコマンドの中身を名前と残りに分ける（区切りは最初の空白。タブも区切る）。
func commandName(inner string) (name, rest string) {
	k := strings.IndexFunc(inner, unicode.IsSpace)
	if k < 0 {
		return inner, ""
	}
	return inner[:k], strings.TrimSpace(inner[k:])
}

// take は control の行を読んだ印に、>> の後ろの字を知らせる（同じ行を先読みで 2 度見ても 1 度だけ言う）。
func (b *bodyParser) take(l bodyLine, c control) {
	b.pos++
	if c.tail != "" {
		b.p.fail(l.no, "<<%s>> の後ろに字やタグは書かない（読めない: %s）", c.name, c.tail)
	}
}

func (p *parser) controlOf(l bodyLine) control {
	content := strings.TrimSpace(l.content)
	if !strings.HasPrefix(content, "<<") {
		return control{}
	}
	end := commandEnd(content)
	if end < 0 {
		return control{}
	}
	name, rest := commandName(strings.TrimSpace(content[2:end]))
	switch name {
	case "if", "elseif", "else", "endif":
	default:
		return control{}
	}
	return control{name: name, rest: rest, tail: strings.TrimSpace(stripComment(content[end+2:]))}
}

// ifBlock は <<if>> から対の <<endif>> までを読む（<<if>> の行は読んである）。
func (b *bodyParser) ifBlock(start bodyLine, first control) *Stmt {
	s := &Stmt{Kind: "if", Line: start.no}
	clause := &Clause{Line: start.no, Condition: b.p.condition(start.no, "if", first.rest)}
	sawElse := false
	for {
		clause.Body = b.statements(false, true)
		s.Clauses = append(s.Clauses, clause)
		t, ok := b.peek()
		c := control{}
		if ok && t.kind == tLine && !t.line.arrow {
			c = b.p.controlOf(t.line)
		}
		switch c.name {
		case "elseif":
			b.take(t.line, c)
			if sawElse {
				b.p.fail(t.line.no, "<<else>> の後ろに <<elseif>> は書けない")
			}
			clause = &Clause{Line: t.line.no, Condition: b.p.condition(t.line.no, "elseif", c.rest)}
		case "else":
			b.take(t.line, c)
			switch {
			case sawElse:
				b.p.fail(t.line.no, "<<else>> が 2 つある")
			case strings.HasPrefix(c.rest, "if"):
				b.p.fail(t.line.no, "<<else if>> は <<elseif 式>> と書く")
			case c.rest != "":
				b.p.fail(t.line.no, "<<else>> は何も受け取らない")
			}
			sawElse = true
			clause = &Clause{Line: t.line.no}
		case "endif":
			b.take(t.line, c)
			if c.rest != "" {
				b.p.fail(t.line.no, "<<endif>> は何も受け取らない")
			}
			return s
		default:
			b.p.fail(start.no, "<<if>> が <<endif>> で閉じていない（選択肢の中で始めた <<if>> は、その選択肢の字下げの中で閉じる）")
			return s
		}
	}
}

// condition は <<if>>・<<elseif>> の式を読む（読めなければ知らせて、偽の式を返す）。
func (p *parser) condition(no int, name, src string) *Expr {
	x, err := ParseExpr(src)
	if err != nil {
		p.failExpr(no, "<<"+name+">> の式", err)
		return &Expr{Kind: "value", Value: &Value{Type: TypeBool}}
	}
	return x
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
		l, cond := b.p.lineContent(t.line.no, strings.TrimSpace(t.line.content[2:]), true)
		if l != nil {
			opt.Speaker, opt.Text, opt.Parts, opt.Tags, opt.Condition = l.Speaker, l.Text, l.Parts, l.Tags, cond
		}
		if n, ok := b.peek(); ok && n.kind == tIndent {
			b.pos++
			opt.Body = b.statements(true, false)
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
	"local":   {"<<local>>（ノードの中だけの変数）", "<<declare $名前 = 初めの値>>（変数はフォルダの中で 1 つ）"},
	"enum":    {"<<enum>>（変数の型）", "取りうる値はゲームのコードの enum に書き、シナリオではタグの値で選ぶ"},
	"case":    {"<<case>>（変数の型）", "取りうる値はゲームのコードの enum に書き、シナリオではタグの値で選ぶ"},
	"endenum": {"<<endenum>>（変数の型）", "取りうる値はゲームのコードの enum に書き、シナリオではタグの値で選ぶ"},
	"call":    {"<<call>>（関数）", "計算はゲームのコードで行い、結果を変数に入れて渡す"},
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
	s, _ := p.lineContent(l.no, content, false)
	return s
}

// commandEnd は << で始まる字の、対の >> の位置（式の文字列の中の >> は飛ばす。無ければ -1）。
func commandEnd(content string) int {
	inString := false
	for i := 2; i+1 < len(content); i++ {
		switch {
		case inString && content[i] == '\\':
			i++
		case content[i] == '"':
			inString = !inString
		case !inString && content[i] == '>' && content[i+1] == '>':
			return i
		}
	}
	return -1
}

func (p *parser) command(no int, content string) *Stmt {
	close := commandEnd(content)
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
	name, rest := commandName(inner)
	switch name {
	case "set", "declare":
		if len(tags) > 0 {
			p.fail(no, "<<%s>> にタグは付けない", name)
			return nil
		}
		if name == "set" {
			return p.set(no, rest)
		}
		p.declare(no, rest)
		return nil
	}
	if strings.ContainsAny(inner, "{}") {
		p.refuse(no, "コマンドの中の {式}", "値をそのまま書く")
		return nil
	}
	fields := strings.Fields(inner)
	args := fields[1:]
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

// assignment は <<set>>・<<declare>> の「$名前 to 式」を分ける（op は += などの + の字・= と to は空）。
func assignment(src string) (name, op, expr string, err error) {
	s := strings.TrimSpace(src)
	rs := []rune(s)
	j := 1
	for j < len(rs) && (rs[j] == '_' || unicode.IsLetter(rs[j]) || unicode.IsDigit(rs[j])) {
		j++
	}
	if len(rs) == 0 || rs[0] != '$' || !isIdentifier(string(rs[1:j])) {
		return "", "", "", fmt.Errorf("変数の名前（$ から書く）が無い")
	}
	name = string(rs[:j])
	after := strings.TrimSpace(string(rs[j:]))
	switch {
	case strings.HasPrefix(after, "to") && (len(after) == 2 || !isIdentifier(after[:3])):
		return name, "", after[2:], nil
	case len(after) >= 2 && after[1] == '=' && strings.ContainsRune("+-*/%", rune(after[0])):
		return name, after[:1], after[2:], nil
	case strings.HasPrefix(after, "=") && !strings.HasPrefix(after, "=="):
		return name, "", after[1:], nil
	}
	return "", "", "", fmt.Errorf("%s の後ろに to か = が無い", name)
}

// set は <<set $名前 to 式>>（+= -= *= /= %= は $名前 + 式 などに直して持つ）。
func (p *parser) set(no int, rest string) *Stmt {
	name, op, src, err := assignment(rest)
	if err != nil {
		p.fail(no, "<<set>> は <<set $名前 to 式>> と書く（%v）", err)
		return nil
	}
	x, err := ParseExpr(src)
	if err != nil {
		p.failExpr(no, "<<set>> の式", err)
		return nil
	}
	if op != "" {
		x = &Expr{Kind: op, Args: []*Expr{{Kind: "variable", Name: name}, x}}
	}
	return &Stmt{Kind: "set", Line: no, Name: name, Expr: x}
}

// declare は <<declare $名前 = 初めの値>> を読み、読んでいるノードの宣言に足す。
func (p *parser) declare(no int, rest string) {
	name, op, src, err := assignment(rest)
	if err == nil && op != "" {
		err = fmt.Errorf("%s= は <<set>> だけ", op)
	}
	if err != nil {
		p.fail(no, "<<declare>> は <<declare $名前 = 初めの値>> と書く（%v）", err)
		return
	}
	if toks, err := lexExpr(src); err == nil {
		for _, t := range toks {
			if t.kind == xName && t.text == "as" {
				p.refuse(no, "<<declare>> の as 型", "型は初めの値から決まる（as から後ろを消す）")
				return
			}
		}
	}
	x, err := ParseExpr(src)
	if err != nil {
		p.failExpr(no, "<<declare>> の値", err)
		return
	}
	v, ok := constantOf(x)
	if !ok {
		p.refuse(no, "<<declare>> の値に変数や計算（公式の smart variable）", "初めの値は数・真偽・文字列の字で書き、計算した値は <<set>> で入れる")
		return
	}
	p.declared = append(p.declared, &Variable{Name: name, Value: v, File: p.file, Line: no})
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
			p.fail(no, "タグの後ろに <<…>> は書かない（選択肢の条件はタグの前: -> 字 <<if 式>> #タグ）")
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

// lineContent は台詞の 1 行（-> の後ろも同じ）を読む: エスケープを解き、{式} を切り分け、話し手とタグを分ける。
// allowCondition なら行末の <<if 式>>（選択肢の条件）を読んで返す。
func (p *parser) lineContent(no int, content string, allowCondition bool) (*Stmt, *Expr) {
	var text strings.Builder // 書いたとおりの字（{式} はそのまま残す）
	var lit strings.Builder  // 今の字の切れ
	var parts []*Part
	var colons []int // エスケープしていない : の位置（text の中の byte 位置）
	firstExpr := -1  // 最初の {式} の位置（text の中の byte 位置）
	rs := []rune(content)
	var tags []Tag
	var cond *Expr
	flush := func() {
		if lit.Len() > 0 {
			parts = append(parts, &Part{Text: lit.String()})
			lit.Reset()
		}
	}
	write := func(r rune) {
		text.WriteRune(r)
		lit.WriteRune(r)
	}
	for i := 0; i < len(rs); i++ {
		c := rs[i]
		switch {
		case c == '\\':
			if i+1 >= len(rs) {
				p.fail(no, "行の終わりの \\（字そのものは \\\\ と書く）")
				return nil, nil
			}
			n := rs[i+1]
			if !strings.ContainsRune(`\<>{}#/[]:`, n) {
				p.fail(no, "\\%c は書けない（\\ を前に置けるのは \\ < > { } # / [ ] : だけ）", n)
				return nil, nil
			}
			write(n)
			i++
		case c == '/' && i+1 < len(rs) && rs[i+1] == '/':
			i = len(rs)
		case c == '#':
			t, ok := p.tags(no, string(rs[i:]))
			if !ok {
				return nil, nil
			}
			tags = t
			i = len(rs)
		case c == '<' && i+1 < len(rs) && rs[i+1] == '<':
			if !allowCondition {
				p.refuse(no, "台詞の行の後ろの <<…>>（行の条件）", "条件で出し分ける台詞は <<if 式>> 〜 <<endif>> で囲む（行末の <<if>> は選択肢 -> だけ。字の << は \\<\\< と書く）")
				return nil, nil
			}
			rest := string(rs[i:])
			end := commandEnd(rest)
			if end < 0 {
				p.fail(no, "<< を閉じる >> が無い")
				return nil, nil
			}
			inner := strings.TrimSpace(rest[2:end])
			name, src := commandName(inner)
			if name != "if" {
				p.refuse(no, "選択肢の後ろの <<"+name+">>", "選択肢の後ろに書けるのは <<if 式>> だけ")
				return nil, nil
			}
			cond = p.condition(no, "if", src)
			after := strings.TrimSpace(stripComment(rest[end+2:]))
			if after != "" {
				if !strings.HasPrefix(after, "#") {
					p.fail(no, "<<if>> の後ろに字は書かない（タグだけ。読めない: %s）", after)
					return nil, nil
				}
				t, ok := p.tags(no, after)
				if !ok {
					return nil, nil
				}
				tags = t
			}
			i = len(rs)
		case c == '{':
			close := exprEnd(rs, i+1)
			if close < 0 {
				p.fail(no, "{ を閉じる } が無い（字の { は \\{ と書く）")
				return nil, nil
			}
			src := string(rs[i+1 : close])
			x, err := ParseExpr(src)
			if err != nil {
				p.failExpr(no, "{"+src+"} の式", err)
				return nil, nil
			}
			if firstExpr < 0 {
				firstExpr = text.Len()
			}
			flush()
			parts = append(parts, &Part{Expr: x})
			text.WriteString("{" + src + "}")
			i = close
		case c == '}':
			p.fail(no, "対の { が無い }（字の } は \\} と書く）")
			return nil, nil
		case c == '[':
			p.refuse(no, "[…] のマークアップ", "字の [ は \\[ と書く（色や揺れは描く側で付ける）")
			return nil, nil
		case c == ':':
			colons = append(colons, text.Len())
			write(c)
		default:
			write(c)
		}
	}
	flush()
	full := strings.TrimRightFunc(text.String(), unicode.IsSpace)
	speaker, body := "", full
	speakerEnd := 0 // 話し手と : の分の byte の長さ
	if len(colons) > 0 && colons[0] < len(full) {
		name := strings.TrimSpace(full[:colons[0]])
		if name != "" {
			if firstExpr >= 0 && firstExpr < colons[0] {
				p.fail(no, "話し手の名前に {式} は書けない（字の : は \\: と書く）")
				return nil, nil
			}
			speaker = name
			body = strings.TrimLeftFunc(full[colons[0]+1:], unicode.IsSpace)
			speakerEnd = colons[0] + 1
		}
	}
	if body == "" {
		p.fail(no, "台詞の無い行（タグだけの行・字の無い -> は書けない）")
		return nil, nil
	}
	if firstExpr < 0 {
		parts = nil
	} else {
		parts = trimParts(parts, speakerEnd)
	}
	return &Stmt{Kind: "line", Line: no, Speaker: speaker, Text: body, Parts: parts, Tags: tags}, cond
}

// trimParts は切れの並びから話し手の分（頭の skip byte。最初の字の切れの中にある）を落とし、頭と尻の空白を落とす。
func trimParts(parts []*Part, skip int) []*Part {
	if len(parts) > 0 && parts[0].Expr == nil {
		parts[0].Text = strings.TrimLeftFunc(parts[0].Text[skip:], unicode.IsSpace)
	}
	if last := len(parts) - 1; last >= 0 && parts[last].Expr == nil {
		parts[last].Text = strings.TrimRightFunc(parts[last].Text, unicode.IsSpace)
	}
	var out []*Part
	for _, part := range parts {
		if part.Expr != nil || part.Text != "" {
			out = append(out, part)
		}
	}
	return out
}

// exprEnd は { の後ろ from から、対の } の位置（式の文字列の中は飛ばす。無ければ -1）。
func exprEnd(rs []rune, from int) int {
	inString := false
	for i := from; i < len(rs); i++ {
		switch {
		case inString && rs[i] == '\\':
			i++
		case rs[i] == '"':
			inString = !inString
		case !inString && rs[i] == '}':
			return i
		}
	}
	return -1
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
