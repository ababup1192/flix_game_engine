package refactor

import (
	"fmt"
	"strings"
	"unicode"
)

// 書き替えの型紙（rewrite の --from）: Flix の式の形で書き、穴（$x）を持つ。
//
//	$x != None                                         Eq.neq の呼び出しで、片方が Option.None（== も同じ。左右は問わない）
//	$b#outcome != None                                 欄の読みの比べ
//	match $x { case Some(_) => $a case None => $b }    Some(_) と None だけの 2 腕の match（腕の順は問わない）
//	Option.isSome($x)  Foo.Bar($x, _)  not $c  $a and $b  if ($c) $a else $b  true  1  "s"
//
// 穴は式 1 つに当たり、同じ名前の穴が 2 度出れば字が同じ時だけ当たる。`_` は何にでも当たり、束ねない。
// 名前は修飾つきでも短くてもよい（短い名前は索引の名前の終わりで当て、2 つ以上なら止める。None・Some は Option の物）。
// 型紙が当てるのは書かれた形でなくコンパイラの木: `!=` は Eq.neq・`<` は Order.less の呼び出し、`and` `or` `not` は演算。
//
// WhyNot: 字（正規表現）で当てない。`x != None` の x が `f(a, b)` のような式でも、木の上では引数 1 つなので
// 括弧を数えずに済み、`None` が別の enum の case か、x の型が何か（--where）も索引が答える。

type tmplKind int

const (
	tHole   tmplKind = iota // $x
	tAny                    // _
	tCall                   // f(a, b)・演算子（Eq.neq など）
	tTag                    // None・Some(a)
	tSelect                 // e#label
	tBinary                 // a and b・a or b
	tUnary                  // not a
	tLit                    // true・1・"s"
	tMatch                  // match e { case p => b … }
	tIf                     // if (c) a else b
)

// Tmpl は型紙の式の木。
type Tmpl struct {
	Kind  tmplKind
	Name  string // 穴・呼ぶ名前・case の名前・欄・演算子（And・Or・Not）
	Lit   string // tLit の字（Expr.Cst の cst.lit の形）
	Args  []*Tmpl
	Rules []TmplRule // tMatch
	Comm  bool       // 左右を入れ替えても同じ（Eq.eq・Eq.neq）
	Op    string     // 書いた演算子（`!=` など。報告用）
}

// TmplRule は match の腕 1 つ。
type TmplRule struct {
	Pat  *TmplPat
	Body *Tmpl
}

// TmplPat は腕のパターン（_・case・case(…)）。
type TmplPat struct {
	Wild bool
	Name string
	Args []*TmplPat
}

// Holes は型紙の穴の名前（出た順・重ねない）。
func (t *Tmpl) Holes() []string {
	var out []string
	seen := map[string]bool{}
	var walk func(x *Tmpl)
	walk = func(x *Tmpl) {
		if x == nil {
			return
		}
		if x.Kind == tHole && !seen[x.Name] {
			seen[x.Name] = true
			out = append(out, x.Name)
		}
		for _, a := range x.Args {
			walk(a)
		}
		for _, r := range x.Rules {
			walk(r.Body)
		}
	}
	walk(t)
	return out
}

// 演算子 → コンパイラが呼ぶ trait の sig（左右を入れ替えてよい物は comm）。
var tmplOps = map[string]struct {
	sym  string
	comm bool
}{
	"==": {"Eq.eq", true}, "!=": {"Eq.neq", true},
	"<": {"Order.less", false}, "<=": {"Order.lessEqual", false},
	">": {"Order.greater", false}, ">=": {"Order.greaterEqual", false},
}

type tmplTok struct {
	kind string // id・hole・num・str・sym・eof
	text string
	pos  int
}

func lexTmpl(s string) ([]tmplTok, error) {
	var out []tmplTok
	rs := []rune(s)
	for i := 0; i < len(rs); {
		c := rs[i]
		switch {
		case unicode.IsSpace(c):
			i++
		case c == '$':
			j := i + 1
			for j < len(rs) && (unicode.IsLetter(rs[j]) || unicode.IsDigit(rs[j]) || rs[j] == '_') {
				j++
			}
			if j == i+1 {
				return nil, fmt.Errorf("%d 字目: $ の後に穴の名前が無い", i+1)
			}
			out = append(out, tmplTok{"hole", string(rs[i+1 : j]), i})
			i = j
		case unicode.IsLetter(c) || c == '_':
			j := i
			for j < len(rs) && (unicode.IsLetter(rs[j]) || unicode.IsDigit(rs[j]) || rs[j] == '_' ||
				(rs[j] == '.' && j+1 < len(rs) && (unicode.IsLetter(rs[j+1]) || rs[j+1] == '_'))) {
				j++
			}
			out = append(out, tmplTok{"id", string(rs[i:j]), i})
			i = j
		case unicode.IsDigit(c):
			j := i
			for j < len(rs) && (unicode.IsDigit(rs[j]) || rs[j] == '.' || unicode.IsLetter(rs[j])) {
				j++
			}
			out = append(out, tmplTok{"num", string(rs[i:j]), i})
			i = j
		case c == '"':
			j := i + 1
			var b strings.Builder
			for j < len(rs) && rs[j] != '"' {
				if rs[j] == '\\' && j+1 < len(rs) {
					j++
				}
				b.WriteRune(rs[j])
				j++
			}
			if j >= len(rs) {
				return nil, fmt.Errorf("%d 字目: 字の値が閉じていない", i+1)
			}
			out = append(out, tmplTok{"str", b.String(), i})
			i = j + 1
		default:
			two := ""
			if i+1 < len(rs) {
				two = string(rs[i : i+2])
			}
			switch two {
			case "==", "!=", "<=", ">=", "=>":
				out = append(out, tmplTok{"sym", two, i})
				i += 2
				continue
			}
			if strings.ContainsRune("(){},#<>", c) {
				out = append(out, tmplTok{"sym", string(c), i})
				i++
				continue
			}
			return nil, fmt.Errorf("%d 字目: 型紙に書けない字 %q（式・穴 $x・_・match・if・and/or/not・比べの演算子だけ）", i+1, string(c))
		}
	}
	return append(out, tmplTok{"eof", "", len(rs)}), nil
}

type tmplParser struct {
	toks []tmplTok
	i    int
}

// ParseTmpl は型紙を読む。
func ParseTmpl(s string) (*Tmpl, error) {
	toks, err := lexTmpl(s)
	if err != nil {
		return nil, err
	}
	p := &tmplParser{toks: toks}
	t, err := p.expr()
	if err != nil {
		return nil, err
	}
	if p.peek().kind != "eof" {
		return nil, fmt.Errorf("%d 字目: 式の後に %q が残る", p.peek().pos+1, p.peek().text)
	}
	if t.Kind == tHole || t.Kind == tAny {
		return nil, fmt.Errorf("型紙が穴か _ だけ（どの式にも当たる）。形を書いてください")
	}
	return t, nil
}

func (p *tmplParser) peek() tmplTok { return p.toks[p.i] }
func (p *tmplParser) next() tmplTok { t := p.toks[p.i]; p.i++; return t }
func (p *tmplParser) is(kind, text string) bool {
	t := p.peek()
	return t.kind == kind && t.text == text
}
func (p *tmplParser) want(text string) error {
	if !p.is("sym", text) {
		t := p.peek()
		return fmt.Errorf("%d 字目: %q が要る所に %q", t.pos+1, text, t.text)
	}
	p.i++
	return nil
}

func (p *tmplParser) expr() (*Tmpl, error) { return p.binary("or") }

func (p *tmplParser) binary(op string) (*Tmpl, error) {
	sub := p.cmp
	if op == "or" {
		sub = func() (*Tmpl, error) { return p.binary("and") }
	}
	left, err := sub()
	if err != nil {
		return nil, err
	}
	for p.is("id", op) {
		p.i++
		right, err := sub()
		if err != nil {
			return nil, err
		}
		name := "Or"
		if op == "and" {
			name = "And"
		}
		left = &Tmpl{Kind: tBinary, Name: name, Args: []*Tmpl{left, right}, Op: op}
	}
	return left, nil
}

func (p *tmplParser) cmp() (*Tmpl, error) {
	left, err := p.unary()
	if err != nil {
		return nil, err
	}
	if t := p.peek(); t.kind == "sym" {
		if op, ok := tmplOps[t.text]; ok {
			p.i++
			right, err := p.unary()
			if err != nil {
				return nil, err
			}
			return &Tmpl{Kind: tCall, Name: op.sym, Args: []*Tmpl{left, right}, Comm: op.comm, Op: t.text}, nil
		}
	}
	return left, nil
}

func (p *tmplParser) unary() (*Tmpl, error) {
	if p.is("id", "not") {
		p.i++
		x, err := p.unary()
		if err != nil {
			return nil, err
		}
		return &Tmpl{Kind: tUnary, Name: "Not", Args: []*Tmpl{x}, Op: "not"}, nil
	}
	return p.postfix()
}

func (p *tmplParser) postfix() (*Tmpl, error) {
	x, err := p.primary()
	if err != nil {
		return nil, err
	}
	for p.is("sym", "#") {
		p.i++
		t := p.next()
		if t.kind != "id" || strings.Contains(t.text, ".") {
			return nil, fmt.Errorf("%d 字目: # の後に欄の名前が要る", t.pos+1)
		}
		x = &Tmpl{Kind: tSelect, Name: t.text, Args: []*Tmpl{x}}
	}
	return x, nil
}

func (p *tmplParser) primary() (*Tmpl, error) {
	t := p.next()
	switch t.kind {
	case "hole":
		return &Tmpl{Kind: tHole, Name: t.text}, nil
	case "num":
		return &Tmpl{Kind: tLit, Lit: t.text}, nil
	case "str":
		return &Tmpl{Kind: tLit, Lit: t.text, Name: "Str"}, nil
	case "sym":
		if t.text == "(" {
			x, err := p.expr()
			if err != nil {
				return nil, err
			}
			return x, p.want(")")
		}
	case "id":
		switch t.text {
		case "_":
			return &Tmpl{Kind: tAny}, nil
		case "true", "false":
			return &Tmpl{Kind: tLit, Lit: t.text, Name: "Bool"}, nil
		case "match":
			return p.match()
		case "if":
			return p.ifThen()
		}
		last := t.text[strings.LastIndex(t.text, ".")+1:]
		upper := unicode.IsUpper([]rune(last)[0])
		var args []*Tmpl
		called := p.is("sym", "(")
		if called {
			p.i++
			for !p.is("sym", ")") {
				a, err := p.expr()
				if err != nil {
					return nil, err
				}
				args = append(args, a)
				if !p.is("sym", ",") {
					break
				}
				p.i++
			}
			if err := p.want(")"); err != nil {
				return nil, err
			}
		}
		switch {
		case upper:
			return &Tmpl{Kind: tTag, Name: t.text, Args: args}, nil
		case called:
			if len(args) == 0 {
				args = []*Tmpl{{Kind: tLit, Lit: "", Name: "Unit"}}
			}
			return &Tmpl{Kind: tCall, Name: t.text, Args: args}, nil
		}
		return nil, fmt.Errorf("%d 字目: %s は局所の名前か引数の無い def（局所の名前は穴 $%s で書く）", t.pos+1, t.text, t.text)
	}
	return nil, fmt.Errorf("%d 字目: 式が要る所に %q", t.pos+1, t.text)
}

func (p *tmplParser) match() (*Tmpl, error) {
	scrut, err := p.expr()
	if err != nil {
		return nil, err
	}
	if err := p.want("{"); err != nil {
		return nil, err
	}
	m := &Tmpl{Kind: tMatch, Args: []*Tmpl{scrut}}
	for p.is("id", "case") {
		p.i++
		pat, err := p.pattern()
		if err != nil {
			return nil, err
		}
		if p.is("id", "if") {
			return nil, fmt.Errorf("%d 字目: ガードつきの腕は型紙に書けない（ガードのある match は当てない）", p.peek().pos+1)
		}
		if err := p.want("=>"); err != nil {
			return nil, err
		}
		body, err := p.expr()
		if err != nil {
			return nil, err
		}
		m.Rules = append(m.Rules, TmplRule{Pat: pat, Body: body})
	}
	if len(m.Rules) == 0 {
		return nil, fmt.Errorf("%d 字目: match に腕（case p => e）が無い", p.peek().pos+1)
	}
	return m, p.want("}")
}

func (p *tmplParser) pattern() (*TmplPat, error) {
	t := p.next()
	if t.kind != "id" {
		return nil, fmt.Errorf("%d 字目: パターンが要る所に %q", t.pos+1, t.text)
	}
	if t.text == "_" {
		return &TmplPat{Wild: true}, nil
	}
	last := t.text[strings.LastIndex(t.text, ".")+1:]
	if !unicode.IsUpper([]rune(last)[0]) {
		return nil, fmt.Errorf("%d 字目: パターンは _ か case（None・Some(_)）だけ（変数で受ける腕は本体が値を使うので型紙の外）", t.pos+1)
	}
	pat := &TmplPat{Name: t.text}
	if p.is("sym", "(") {
		p.i++
		for !p.is("sym", ")") {
			a, err := p.pattern()
			if err != nil {
				return nil, err
			}
			pat.Args = append(pat.Args, a)
			if !p.is("sym", ",") {
				break
			}
			p.i++
		}
		if err := p.want(")"); err != nil {
			return nil, err
		}
	}
	return pat, nil
}

func (p *tmplParser) ifThen() (*Tmpl, error) {
	if err := p.want("("); err != nil {
		return nil, err
	}
	c, err := p.expr()
	if err != nil {
		return nil, err
	}
	if err := p.want(")"); err != nil {
		return nil, err
	}
	a, err := p.expr()
	if err != nil {
		return nil, err
	}
	if !p.is("id", "else") {
		return nil, fmt.Errorf("%d 字目: if に else が要る", p.peek().pos+1)
	}
	p.i++
	b, err := p.expr()
	if err != nil {
		return nil, err
	}
	return &Tmpl{Kind: tIf, Args: []*Tmpl{c, a, b}}, nil
}

// Where は --where の 1 つ（穴 $x の型の頭が T）。
type Where struct {
	Hole, Type string
}

// ParseWhere は `$x: Option, $b: Battle.BattleRec` を読む。
func ParseWhere(s string) ([]Where, error) {
	var out []Where
	if strings.TrimSpace(s) == "" {
		return nil, nil
	}
	for _, part := range splitTopLevel(s, ',') {
		h, t, ok := strings.Cut(part, ":")
		h, t = strings.TrimSpace(h), strings.TrimSpace(t)
		if !ok || !strings.HasPrefix(h, "$") || len(h) < 2 || t == "" {
			return nil, fmt.Errorf("--where は `$x: 型` を , で並べる: %q", part)
		}
		out = append(out, Where{Hole: h[1:], Type: t})
	}
	return out, nil
}

// splitTopLevel は括弧の外の sep で切る。
func splitTopLevel(s string, sep rune) []string {
	var out []string
	depth, start := 0, 0
	for i, c := range s {
		switch c {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case sep:
			if depth == 0 {
				out = append(out, s[start:i])
				start = i + 1
			}
		}
	}
	return append(out, s[start:])
}

// toHoles は --to に出る穴の名前（$x）。
func toHoles(to string) []string {
	var out []string
	rs := []rune(to)
	inStr := false
	for i := 0; i < len(rs); i++ {
		switch {
		case rs[i] == '"' && (i == 0 || rs[i-1] != '\\'):
			inStr = !inStr
		case rs[i] == '$' && !inStr:
			j := i + 1
			for j < len(rs) && (unicode.IsLetter(rs[j]) || unicode.IsDigit(rs[j]) || rs[j] == '_') {
				j++
			}
			if j > i+1 {
				out = append(out, string(rs[i+1:j]))
			}
		}
	}
	return out
}
