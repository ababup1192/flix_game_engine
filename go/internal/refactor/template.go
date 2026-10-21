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
//	Option.isSome($x)  Foo.Bar($x, _)  not $c  $a and $b  if ($c) $a else $b  true  1  -1  "s"
//	$x :: $xs  $a ::: $b  $xs |> List.map($f)  $s ++ $t  $a + $b * 2  $a <=> $b  $a `f` $b  -$x
//	$p -> $p + 1  (x, y) -> x + y  { a = $v | $r }  { +a = $v | $r }  { -a | $r }  List#{$a, $b}  Set#{$a}  Vector#{$a}
//
// 穴は式 1 つに当たり、同じ名前の穴が 2 度出れば字が同じ時だけ当たる。`_` は何にでも当たり、束ねない。
// 名前は修飾つきでも短くてもよい（短い名前は索引の名前の終わりで当て、2 つ以上なら止める。None・Some は Option の物）。
//
// 型紙が当てるのは書かれた形でなくコンパイラの木（汎用の AST）なので、演算子と中置の形はコンパイラが作る形で読む:
//
//	== != < <= > >= <=> + - * /    Eq.eq・Eq.neq・Order.less … Order.compare・Add.add・Sub.sub・Mul.mul・Div.div の呼び出し
//	:: ・ :::                     List.Cons の case（右結合）・List.append の呼び出し
//	|> ++ など記号だけの演算子      その名前の def の呼び出し（|> も ++ も標準の頭の def）。`f` は f の呼び出し
//	and or not                    Expr.Binary・Expr.Unary（sop が And・Or・Not）
//	-$x ・ -1                     Neg.neg の呼び出し・負の数の字の値
//	x -> e                        Expr.Lambda（(x, y) -> e は入れ子）。引数は穴 $p か名前か _ で、本体の中のその名前は引数を指す
//	{ a = e | r }                 欄の書き替え（RecordExtend(a, e, RecordRestrict(a, r))）。+a = e は足す・-a は外す
//	List#{…}・Set#{…}             Vector.toList・Vector.toSet（空の Set#{} は Set.empty）の呼び出し。Vector#{…} は Expr.VectorLit
//	f(a)（引数が足りない呼び出し） コンパイラが作るラムダ（x -> f(a, x)）のまま当てる（$xs |> List.map($f) の右）
//
// 演算子の強さと結合はコンパイラ（Parser2 の Op.precedence）と同じ: or < and < 比べ（== != <=>）< 大小 < :: :::（右）
// < + - < * / < `f` < 記号の演算子（|> ++）< 前置の - < not。読めない形（<+>・instanceof・Map#{…}・型の注釈など）は
// 「N 字目の 〜 が読めない」と 1 行で止める。
//
// WhyNot: 字（正規表現）で当てない。`x != None` の x が `f(a, b)` のような式でも、木の上では引数 1 つなので
// 括弧を数えずに済み、`None` が別の enum の case か、x の型が何か（--where）も索引が答える。

type tmplKind int

const (
	tHole        tmplKind = iota // $x
	tAny                         // _
	tCall                        // f(a, b)・演算子（Eq.neq・Add.add・List.append・|> など）
	tTag                         // None・Some(a)・a :: b（List.Cons）
	tSelect                      // e#label
	tBinary                      // a and b・a or b
	tUnary                       // not a
	tLit                         // true・1・"s"
	tMatch                       // match e { case p => b … }
	tIf                          // if (c) a else b
	tLambda                      // p -> e（Params は 1 つ。(x, y) -> e は入れ子）
	tLocal                       // ラムダの引数の名前（本体の中の x）
	tRecExtend                   // { +label = e | r }（Args は値と残り）
	tRecRestrict                 // { -label | r }（Args は残り）
	tVector                      // Vector#{…}（Expr.VectorLit）
)

// Tmpl は型紙の式の木。
type Tmpl struct {
	Kind   tmplKind
	Name   string // 穴・呼ぶ名前・case の名前・欄・演算子（And・Or・Not）・局所の名前
	Lit    string // tLit の字（Expr.Cst の cst.lit の形）
	Args   []*Tmpl
	Rules  []TmplRule // tMatch
	Params []TmplParam
	Comm   bool   // 左右を入れ替えても同じ（Eq.eq・Eq.neq）
	Op     string // 書いた演算子（`!=` など。報告用）
}

// TmplParam はラムダの引数 1 つ（穴 $p・名前 x・_ のどれか）。
type TmplParam struct {
	Hole string // $p（--to に写せる）
	Name string // x（本体の中の x はこの引数）
}

// localKey は名前で書いたラムダの引数を束ねる鍵（穴の名前と重ならない）。
func localKey(name string) string { return "·" + name }

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
	add := func(name string) {
		if !seen[name] {
			seen[name] = true
			out = append(out, name)
		}
	}
	var walk func(x *Tmpl)
	walk = func(x *Tmpl) {
		if x == nil {
			return
		}
		if x.Kind == tHole {
			add(x.Name)
		}
		for _, p := range x.Params {
			if p.Hole != "" {
				add(p.Hole)
			}
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

// tmplBinOp は中置の演算子 1 つ（強さと結合はコンパイラの Parser2 の Op.precedence・isRightAssoc と同じ）。
type tmplBinOp struct {
	prec  int
	right bool
	build func(op string, l, r *Tmpl) *Tmpl
}

func callOp(sym string, comm bool) func(string, *Tmpl, *Tmpl) *Tmpl {
	return func(op string, l, r *Tmpl) *Tmpl {
		return &Tmpl{Kind: tCall, Name: sym, Args: []*Tmpl{l, r}, Comm: comm, Op: op}
	}
}

func boolOp(name string) func(string, *Tmpl, *Tmpl) *Tmpl {
	return func(op string, l, r *Tmpl) *Tmpl {
		return &Tmpl{Kind: tBinary, Name: name, Args: []*Tmpl{l, r}, Op: op}
	}
}

// tmplOps は名前の決まった中置の演算子（記号の並びで表に無い物は、その名前の def を呼ぶ演算子: |> ++ など）。
var tmplOps = map[string]tmplBinOp{
	"or":  {1, false, boolOp("Or")},
	"and": {2, false, boolOp("And")},
	"==":  {3, false, callOp("Eq.eq", true)}, "!=": {3, false, callOp("Eq.neq", true)}, "<=>": {3, false, callOp("Order.compare", false)},
	"<": {4, false, callOp("Order.less", false)}, "<=": {4, false, callOp("Order.lessEqual", false)},
	">": {4, false, callOp("Order.greater", false)}, ">=": {4, false, callOp("Order.greaterEqual", false)},
	"::": {5, true, func(op string, l, r *Tmpl) *Tmpl {
		return &Tmpl{Kind: tTag, Name: "List.Cons", Args: []*Tmpl{l, r}, Op: op}
	}},
	":::": {5, true, callOp("List.append", false)},
	"+":   {6, false, callOp("Add.add", false)}, "-": {6, false, callOp("Sub.sub", false)},
	"*": {7, false, callOp("Mul.mul", false)}, "/": {7, false, callOp("Div.div", false)},
}

const (
	precInfix   = 10 // `f`
	precUserOp  = 11 // |> ++ など記号だけの演算子
	precUnaryOp = 13 // 前置の -（not は 14。どちらも中置のどれより強い）
)

// tmplNotOps は記号の並びでも中置の演算子でない物（record・match・ラムダ・型の字）と、木の形を持たない演算子。
var tmplNotOps = map[string]string{
	"=": "", "|": "", "=>": "", "->": "", ":": "",
	"<+>": "Datalog の <+>（FixpointMerge）は型紙に書けない",
}

const tmplForms = "書ける形: 呼び出し・case・穴 $x・_・e#欄・and/or/not・比べ・算術・:: ::: |> ++ など中置の演算子・match・if・ラムダ x -> e・{ a = e | r }・List#{…}・Set#{…}・Vector#{…}"

// unreadable は型紙の pos（0 から）の形 what が読めない、の 1 行。
func unreadable(pos int, what string, why string) error {
	if why == "" {
		why = tmplForms
	}
	return fmt.Errorf("%d 字目の %s が読めない（%s）", pos+1, what, why)
}

type tmplTok struct {
	kind string // id・hole・num・str・sym・op・infix・eof
	text string
	pos  int
}

// tmplOpRunes は記号の演算子を作る字（$ は穴・# は欄・. は名前の中なので入れない）。
const tmplOpRunes = "+-*/<>=!&|^~%:?@"

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
		case c == '`':
			j := i + 1
			for j < len(rs) && rs[j] != '`' {
				j++
			}
			name := strings.TrimSpace(string(rs[i+1 : min(j, len(rs))]))
			if j >= len(rs) || name == "" {
				return nil, unreadable(i, "`", "中置の呼び出しは `f` の形で閉じる")
			}
			out = append(out, tmplTok{"infix", name, i})
			i = j + 1
		case strings.ContainsRune("(){},#", c):
			out = append(out, tmplTok{"sym", string(c), i})
			i++
		case strings.ContainsRune(tmplOpRunes, c):
			j := i
			for j < len(rs) && strings.ContainsRune(tmplOpRunes, rs[j]) {
				j++
			}
			out = append(out, tmplTok{"op", string(rs[i:j]), i})
			i = j
		default:
			return nil, unreadable(i, fmt.Sprintf("%q", string(c)), "")
		}
	}
	return append(out, tmplTok{"eof", "", len(rs)}), nil
}

type tmplParser struct {
	toks   []tmplTok
	i      int
	locals []map[string]bool // ラムダの引数の名前（内側が後ろ）
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
func (p *tmplParser) peekAt(k int) tmplTok {
	if p.i+k < len(p.toks) {
		return p.toks[p.i+k]
	}
	return p.toks[len(p.toks)-1]
}
func (p *tmplParser) next() tmplTok { t := p.toks[p.i]; p.i++; return t }
func (p *tmplParser) is(kind, text string) bool {
	t := p.peek()
	return t.kind == kind && t.text == text
}
func (p *tmplParser) want(text string) error {
	t := p.peek()
	if (t.kind != "sym" && t.kind != "op") || t.text != text {
		return fmt.Errorf("%d 字目: %q が要る所に %q", t.pos+1, text, t.text)
	}
	p.i++
	return nil
}

func (p *tmplParser) expr() (*Tmpl, error) { return p.binary(0) }

// binOp は今の字が中置の演算子ならその決まり（違えば ok=false。読めない演算子は err）。
func (p *tmplParser) binOp() (tmplBinOp, bool, error) {
	t := p.peek()
	switch t.kind {
	case "id":
		if t.text == "instanceof" {
			return tmplBinOp{}, false, unreadable(t.pos, "instanceof", "Java の型の問いは型紙に書けない")
		}
		op, ok := tmplOps[t.text]
		return op, ok, nil
	case "infix":
		name := t.text
		return tmplBinOp{precInfix, false, func(_ string, l, r *Tmpl) *Tmpl {
			return &Tmpl{Kind: tCall, Name: name, Args: []*Tmpl{l, r}, Op: "`" + name + "`"}
		}}, true, nil
	case "op":
		if why, ok := tmplNotOps[t.text]; ok {
			if why != "" {
				return tmplBinOp{}, false, unreadable(t.pos, t.text, why)
			}
			return tmplBinOp{}, false, nil
		}
		if op, ok := tmplOps[t.text]; ok {
			return op, true, nil
		}
		return tmplBinOp{precUserOp, false, callOp(t.text, false)}, true, nil
	}
	return tmplBinOp{}, false, nil
}

// binary は強さ min 以上の中置の演算子を読む（強さで登る形。左結合は右を 1 強く、右結合は同じ強さで読む）。
func (p *tmplParser) binary(min int) (*Tmpl, error) {
	left, err := p.unary()
	if err != nil {
		return nil, err
	}
	for {
		op, ok, err := p.binOp()
		if err != nil {
			return nil, err
		}
		if !ok || op.prec < min {
			return left, nil
		}
		text := p.next().text
		nextMin := op.prec + 1
		if op.right {
			nextMin = op.prec
		}
		right, err := p.binary(nextMin)
		if err != nil {
			return nil, err
		}
		left = op.build(text, left, right)
	}
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
	if t := p.peek(); t.kind == "op" && t.text == "-" {
		p.i++
		if n := p.peek(); n.kind == "num" && n.pos == t.pos+1 {
			p.i++
			return &Tmpl{Kind: tLit, Lit: "-" + n.text}, nil
		}
		x, err := p.binary(precUnaryOp)
		if err != nil {
			return nil, err
		}
		return &Tmpl{Kind: tCall, Name: "Neg.neg", Args: []*Tmpl{x}, Op: "-"}, nil
	}
	if t := p.peek(); t.kind == "op" && t.text != "-" {
		return nil, unreadable(t.pos, "前置の "+t.text, "")
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

// isLocal は name が囲むラムダの引数の名前か。
func (p *tmplParser) isLocal(name string) bool {
	for _, s := range p.locals {
		if s[name] {
			return true
		}
	}
	return false
}

func (p *tmplParser) primary() (*Tmpl, error) {
	if params, ok := p.lambdaHead(); ok {
		return p.lambda(params)
	}
	t := p.next()
	switch t.kind {
	case "hole":
		return &Tmpl{Kind: tHole, Name: t.text}, nil
	case "num":
		return &Tmpl{Kind: tLit, Lit: t.text}, nil
	case "str":
		return &Tmpl{Kind: tLit, Lit: t.text, Name: "Str"}, nil
	case "sym":
		switch t.text {
		case "(":
			if p.is("sym", ")") {
				return nil, unreadable(t.pos, "()", "Unit の字の値は型紙に書けない")
			}
			x, err := p.expr()
			if err != nil {
				return nil, err
			}
			if p.is("sym", ",") {
				return nil, unreadable(p.peek().pos, "タプル (a, b)", "")
			}
			if p.is("op", ":") {
				return nil, unreadable(p.peek().pos, "型の注釈 :", "")
			}
			return x, p.want(")")
		case "{":
			return p.record(t)
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
		case "let", "def", "region", "try", "forM", "foreach", "use", "import", "unsafe", "run", "spawn", "par", "select", "lazy", "force", "discard", "throw", "typematch", "ematch", "query", "solve", "inject", "project", "checked_cast", "unchecked_cast", "new":
			return nil, unreadable(t.pos, t.text, "")
		}
		if p.isLocal(t.text) {
			return &Tmpl{Kind: tLocal, Name: t.text}, nil
		}
		if p.is("sym", "#") && p.peekAt(1).kind == "sym" && p.peekAt(1).text == "{" {
			return p.collection(t)
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
	case "op":
		return nil, unreadable(t.pos, t.text, "")
	case "infix":
		return nil, unreadable(t.pos, "`"+t.text+"`", "中置の呼び出しの左に式が要る")
	}
	if t.kind == "eof" {
		return nil, fmt.Errorf("%d 字目: 式が要る所で型紙が終わる", t.pos+1)
	}
	return nil, fmt.Errorf("%d 字目: 式が要る所に %q", t.pos+1, t.text)
}

// lambdaHead は今の字からラムダの引数（x -> ・$p -> ・_ -> ・(x, y) ->）を読む。ラムダでなければ字を進めない。
func (p *tmplParser) lambdaHead() ([]TmplParam, bool) {
	param := func(t tmplTok) (TmplParam, bool) {
		switch {
		case t.kind == "hole":
			return TmplParam{Hole: t.text}, true
		case t.kind == "id" && t.text == "_":
			return TmplParam{}, true
		case t.kind == "id" && !strings.Contains(t.text, ".") && unicode.IsLower([]rune(t.text)[0]):
			return TmplParam{Name: t.text}, true
		}
		return TmplParam{}, false
	}
	isArrow := func(t tmplTok) bool { return t.kind == "op" && t.text == "->" }
	if x, ok := param(p.peek()); ok && isArrow(p.peekAt(1)) {
		p.i += 2
		return []TmplParam{x}, true
	}
	if !p.is("sym", "(") {
		return nil, false
	}
	var params []TmplParam
	for k := 1; ; k += 2 {
		x, ok := param(p.peekAt(k))
		if !ok {
			return nil, false
		}
		params = append(params, x)
		sep := p.peekAt(k + 1)
		if sep.kind == "sym" && sep.text == "," {
			continue
		}
		if sep.kind == "sym" && sep.text == ")" && isArrow(p.peekAt(k+2)) {
			p.i += k + 3
			return params, true
		}
		return nil, false
	}
}

// lambda は引数の後の本体を読む（本体は右へできるだけ伸びる。(x, y) -> e は x -> (y -> e) の入れ子）。
func (p *tmplParser) lambda(params []TmplParam) (*Tmpl, error) {
	scope := map[string]bool{}
	for _, x := range params {
		if x.Name != "" {
			scope[x.Name] = true
		}
	}
	p.locals = append(p.locals, scope)
	body, err := p.expr()
	p.locals = p.locals[:len(p.locals)-1]
	if err != nil {
		return nil, err
	}
	for i := len(params) - 1; i >= 0; i-- {
		body = &Tmpl{Kind: tLambda, Params: []TmplParam{params[i]}, Args: []*Tmpl{body}, Op: "->"}
	}
	return body, nil
}

// record は { 欄の操作, … | 残り } を読む（コンパイラと同じく、先の操作が外側: foldRight）。
func (p *tmplParser) record(open tmplTok) (*Tmpl, error) {
	type recOp struct {
		sign  string // + は足す・- は外す・"" は書き替え
		label string
		value *Tmpl
	}
	var ops []recOp
	for {
		var op recOp
		if t := p.peek(); t.kind == "op" && (t.text == "+" || t.text == "-") {
			op.sign = t.text
			p.i++
		}
		t := p.next()
		if t.kind != "id" || strings.Contains(t.text, ".") {
			return nil, unreadable(open.pos, "record の字の値 { … }", "書けるのは欄の操作と残りの { a = e | r }・{ +a = e | r }・{ -a | r } だけ")
		}
		op.label = t.text
		if op.sign != "-" {
			if err := p.want("="); err != nil {
				return nil, err
			}
			v, err := p.expr()
			if err != nil {
				return nil, err
			}
			op.value = v
		}
		ops = append(ops, op)
		if p.is("sym", ",") {
			p.i++
			continue
		}
		break
	}
	if !p.is("op", "|") {
		return nil, unreadable(open.pos, "record の字の値 { … }", "書けるのは欄の操作と残りの { a = e | r }・{ +a = e | r }・{ -a | r } だけ")
	}
	p.i++
	rest, err := p.expr()
	if err != nil {
		return nil, err
	}
	if err := p.want("}"); err != nil {
		return nil, err
	}
	for i := len(ops) - 1; i >= 0; i-- {
		op := ops[i]
		switch op.sign {
		case "+":
			rest = &Tmpl{Kind: tRecExtend, Name: op.label, Args: []*Tmpl{op.value, rest}}
		case "-":
			rest = &Tmpl{Kind: tRecRestrict, Name: op.label, Args: []*Tmpl{rest}}
		default:
			rest = &Tmpl{Kind: tRecExtend, Name: op.label, Args: []*Tmpl{op.value, {Kind: tRecRestrict, Name: op.label, Args: []*Tmpl{rest}}}}
		}
	}
	return rest, nil
}

// collection は List#{…}・Set#{…}・Vector#{…} を、コンパイラが作る呼び出しの形で読む。
func (p *tmplParser) collection(head tmplTok) (*Tmpl, error) {
	if head.text != "List" && head.text != "Set" && head.text != "Vector" {
		return nil, unreadable(head.pos, head.text+"#{…}", "書ける集まりの字の値は List#{…}・Set#{…}・Vector#{…}")
	}
	p.i += 2 // # {
	var elems []*Tmpl
	for !p.is("sym", "}") {
		a, err := p.expr()
		if err != nil {
			return nil, err
		}
		elems = append(elems, a)
		if !p.is("sym", ",") {
			break
		}
		p.i++
	}
	if err := p.want("}"); err != nil {
		return nil, err
	}
	vec := &Tmpl{Kind: tVector, Args: elems, Op: head.text + "#{}"}
	switch head.text {
	case "List":
		return &Tmpl{Kind: tCall, Name: "Vector.toList", Args: []*Tmpl{vec}, Op: "List#{}"}, nil
	case "Set":
		if len(elems) == 0 {
			return &Tmpl{Kind: tCall, Name: "Set.empty", Args: []*Tmpl{{Kind: tLit, Name: "Unit"}}, Op: "Set#{}"}, nil
		}
		return &Tmpl{Kind: tCall, Name: "Vector.toSet", Args: []*Tmpl{vec}, Op: "Set#{}"}, nil
	}
	return vec, nil
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
