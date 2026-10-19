package yarn

// 式の読み手と型の検査。公式の Yarn Spinner の式のうち、数・真偽・文字列・$変数・
// + - * / % ・比較 == != < <= > >= ・and / or / not・括弧・visited("ノード")・visited_count("ノード") を読む。
// 公式の別の綴り（is・eq・&&・||・! など）と、他の関数は「代わりに」を付けて断る。
//
// 優先順位は公式の文法と同じ（強い順に 単項 - と not / * / % / + - / < <= > >= / == != / and or）。
// 公式は and と or を同じ強さで左から結ぶ（a or b and c が (a or b) and c になる）ので、
// 括弧なしで混ぜた式は読み違えのもとになるとして止める。

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode"

	"github.com/ababup1192/flix_game_engine/go/internal/suggest"
)

// ValueType は変数と式の型（公式と同じ 3 つ）。
type ValueType string

const (
	TypeNumber ValueType = "Number"
	TypeBool   ValueType = "Bool"
	TypeString ValueType = "String"
)

// Value は定数（<<declare>> の初めの値・式の中の字）。JSON では数・真偽・文字列そのものになる。
type Value struct {
	Type   ValueType
	Number float64
	Bool   bool
	String string
}

func (v Value) MarshalJSON() ([]byte, error) {
	switch v.Type {
	case TypeNumber:
		return json.Marshal(v.Number)
	case TypeBool:
		return json.Marshal(v.Bool)
	}
	return json.Marshal(v.String)
}

// Expr は式 1 つ。Kind で使う欄が決まる:
//
//	value          Value
//	variable       Name（$ から書く）
//	visited        Name（ノード名）
//	visited_count  Name（ノード名）
//	not  neg       Args[0]
//	+ - * / % == != < <= > >= and or   Args[0] と Args[1]
type Expr struct {
	Kind  string  `json:"kind"`
	Value *Value  `json:"value,omitempty"`
	Name  string  `json:"name,omitempty"`
	Args  []*Expr `json:"args,omitempty"`
	group bool    // 括弧で囲んで書いた（-(1) を数の -1 に畳まないため）
}

// refusal は公式にはあるが読まない書き方の誤り（知らせを「読まない」にする）。
type refusal struct{ msg string }

func (r refusal) Error() string { return r.msg }

func refused(format string, args ...any) error { return refusal{fmt.Sprintf(format, args...)} }

// isRefusal は err が読まない書き方の誤りか。
func isRefusal(err error) bool {
	_, ok := err.(refusal)
	return ok
}

// nearHint は近い名前があればその案（無ければ空。全部の名前を並べるほどの手がかりにならない）。
func nearHint(name string, known []string) string {
	if len(suggest.Near(name, known)) == 0 {
		return ""
	}
	return suggest.Hint(name, known)
}

// ── 字句 ──

type exprTokKind int

const (
	xEnd exprTokKind = iota
	xNumber
	xString
	xVariable
	xName
	xOp
)

type exprTok struct {
	kind exprTokKind
	text string // xString はエスケープを解いた中身
	num  float64
}

// refusedSpellings は公式にはあるが読まない綴り → 代わりの綴り。
var refusedSpellings = map[string]string{
	"is": "==", "eq": "==", "neq": "!=", "gt": ">", "lt": "<", "gte": ">=", "lte": "<=",
	"&&": "and", "||": "or", "!": "not", "xor": "（xor は読まない。and・or・not で書く）", "^": "（xor は読まない。and・or・not で書く）",
}

var exprOps = []string{"==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "+", "-", "*", "/", "%", "<", ">", "(", ")", ",", "=", "!", "^"}

func lexExpr(src string) ([]exprTok, error) {
	var out []exprTok
	rs := []rune(src)
	for i := 0; i < len(rs); {
		c := rs[i]
		switch {
		case unicode.IsSpace(c):
			i++
		case c == '"':
			var b strings.Builder
			j := i + 1
			closed := false
			for j < len(rs) {
				if rs[j] == '\\' {
					if j+1 >= len(rs) || (rs[j+1] != '"' && rs[j+1] != '\\') {
						return nil, fmt.Errorf("文字列の中で \\ の後ろに書けるのは \" と \\ だけ")
					}
					b.WriteRune(rs[j+1])
					j += 2
					continue
				}
				if rs[j] == '"' {
					closed = true
					break
				}
				b.WriteRune(rs[j])
				j++
			}
			if !closed {
				return nil, fmt.Errorf("文字列の \" が閉じていない")
			}
			out = append(out, exprTok{kind: xString, text: b.String()})
			i = j + 1
		case unicode.IsDigit(c) || (c == '.' && i+1 < len(rs) && unicode.IsDigit(rs[i+1])):
			j := i
			for j < len(rs) && (unicode.IsDigit(rs[j]) || rs[j] == '.') {
				j++
			}
			n, err := strconv.ParseFloat(string(rs[i:j]), 64)
			if err != nil {
				return nil, fmt.Errorf("数 %s を読めない", string(rs[i:j]))
			}
			out = append(out, exprTok{kind: xNumber, text: string(rs[i:j]), num: n})
			i = j
		case c == '$':
			j := i + 1
			for j < len(rs) && (rs[j] == '_' || unicode.IsLetter(rs[j]) || unicode.IsDigit(rs[j])) {
				j++
			}
			name := string(rs[i:j])
			if !isIdentifier(name[1:]) {
				return nil, fmt.Errorf("変数は $ の後ろに英字か _ から書く（読めない: %s）", name)
			}
			if j < len(rs) && rs[j] == '.' {
				return nil, refused("変数の名前に . は書けない（%s.…）", name)
			}
			out = append(out, exprTok{kind: xVariable, text: name})
			i = j
		case c == '_' || unicode.IsLetter(c):
			j := i
			for j < len(rs) && (rs[j] == '_' || unicode.IsLetter(rs[j]) || unicode.IsDigit(rs[j])) {
				j++
			}
			out = append(out, exprTok{kind: xName, text: string(rs[i:j])})
			i = j
		default:
			matched := ""
			for _, op := range exprOps {
				if strings.HasPrefix(string(rs[i:]), op) {
					matched = op
					break
				}
			}
			if matched == "" {
				return nil, fmt.Errorf("式に書けない字 %q", string(c))
			}
			out = append(out, exprTok{kind: xOp, text: matched})
			i += len([]rune(matched))
		}
	}
	return append(out, exprTok{kind: xEnd}), nil
}

// ── 構文 ──

type exprParser struct {
	toks []exprTok
	pos  int
}

func (e *exprParser) peek() exprTok { return e.toks[e.pos] }

func (e *exprParser) next() exprTok {
	t := e.toks[e.pos]
	if t.kind != xEnd {
		e.pos++
	}
	return t
}

func (e *exprParser) isOp(texts ...string) bool {
	t := e.peek()
	if t.kind != xOp && t.kind != xName {
		return false
	}
	for _, s := range texts {
		if t.text == s {
			return true
		}
	}
	return false
}

// ParseExpr は式の字（<<if>> の後ろ・{} の中など）を読む。
func ParseExpr(src string) (*Expr, error) {
	toks, err := lexExpr(src)
	if err != nil {
		return nil, err
	}
	if len(toks) == 1 {
		return nil, fmt.Errorf("式が無い")
	}
	e := &exprParser{toks: toks}
	x, err := e.logical()
	if err != nil {
		return nil, err
	}
	if t := e.peek(); t.kind != xEnd {
		return nil, unexpected(t)
	}
	return x, nil
}

func unexpected(t exprTok) error {
	if t.kind == xEnd {
		return fmt.Errorf("式が途中で終わっている")
	}
	if alt, ok := refusedSpellings[t.text]; ok && (t.kind == xOp || t.kind == xName) {
		if strings.HasPrefix(alt, "（") {
			return refused("%s は読まない%s", t.text, alt)
		}
		return refused("%s は読まない（%s と書く）", t.text, alt)
	}
	switch t.text {
	case "=", "+=", "-=", "*=", "/=", "%=":
		return refused("式の中の %s は読まない（入れるのは <<set>>・比べるなら ==）", t.text)
	}
	return fmt.Errorf("式の %s を読めない", t.text)
}

// logical は and と or（同じ強さで左から結ぶ。括弧なしで混ぜたら止める）。
func (e *exprParser) logical() (*Expr, error) {
	left, err := e.equality()
	if err != nil {
		return nil, err
	}
	first := ""
	for e.isOp("and", "or", "&&", "||", "xor", "^") {
		op := e.peek().text
		if op != "and" && op != "or" {
			return nil, unexpected(e.peek())
		}
		e.next()
		if first == "" {
			first = op
		} else if first != op {
			return nil, fmt.Errorf("and と or を括弧なしで混ぜない（公式は左から順に結ぶ。( ) で囲んで書く）")
		}
		right, err := e.equality()
		if err != nil {
			return nil, err
		}
		left = &Expr{Kind: op, Args: []*Expr{left, right}}
	}
	return left, nil
}

func (e *exprParser) binaryLevel(ops []string, lower func() (*Expr, error)) (*Expr, error) {
	left, err := lower()
	if err != nil {
		return nil, err
	}
	for e.isOp(ops...) && e.peek().kind == xOp {
		op := e.next().text
		right, err := lower()
		if err != nil {
			return nil, err
		}
		left = &Expr{Kind: op, Args: []*Expr{left, right}}
	}
	if t := e.peek(); t.kind == xName {
		if _, refused := refusedSpellings[t.text]; refused && t.text != "xor" {
			return nil, unexpected(t)
		}
	}
	return left, nil
}

func (e *exprParser) equality() (*Expr, error) {
	return e.binaryLevel([]string{"==", "!="}, e.relational)
}

func (e *exprParser) relational() (*Expr, error) {
	return e.binaryLevel([]string{"<", "<=", ">", ">="}, e.additive)
}

func (e *exprParser) additive() (*Expr, error) {
	return e.binaryLevel([]string{"+", "-"}, e.multiplicative)
}

func (e *exprParser) multiplicative() (*Expr, error) {
	return e.binaryLevel([]string{"*", "/", "%"}, e.unary)
}

func (e *exprParser) unary() (*Expr, error) {
	switch {
	case e.isOp("-") && e.peek().kind == xOp:
		e.next()
		x, err := e.unary()
		if err != nil {
			return nil, err
		}
		if x.Kind == "value" && x.Value.Type == TypeNumber && !x.group {
			return &Expr{Kind: "value", Value: &Value{Type: TypeNumber, Number: -x.Value.Number}}, nil
		}
		return &Expr{Kind: "neg", Args: []*Expr{x}}, nil
	case e.isOp("not") && e.peek().kind == xName:
		e.next()
		x, err := e.unary()
		if err != nil {
			return nil, err
		}
		return &Expr{Kind: "not", Args: []*Expr{x}}, nil
	}
	return e.primary()
}

func (e *exprParser) primary() (*Expr, error) {
	t := e.next()
	switch t.kind {
	case xNumber:
		return &Expr{Kind: "value", Value: &Value{Type: TypeNumber, Number: t.num}}, nil
	case xString:
		return &Expr{Kind: "value", Value: &Value{Type: TypeString, String: t.text}}, nil
	case xVariable:
		return &Expr{Kind: "variable", Name: t.text}, nil
	case xOp:
		if t.text == "(" {
			x, err := e.logical()
			if err != nil {
				return nil, err
			}
			if !e.isOp(")") {
				return nil, fmt.Errorf("( を閉じる ) が無い")
			}
			e.next()
			x.group = true
			return x, nil
		}
	case xName:
		switch t.text {
		case "true", "false":
			return &Expr{Kind: "value", Value: &Value{Type: TypeBool, Bool: t.text == "true"}}, nil
		case "visited", "visited_count":
			if !e.isOp("(") {
				return nil, fmt.Errorf("%s は %s(\"ノード名\") と書く", t.text, t.text)
			}
			e.next()
			arg := e.next()
			if arg.kind != xString || !e.isOp(")") {
				return nil, refused("%s の中はノード名の文字列を 1 つ（%s(\"ノード名\")。式で組んだ名前は読まない）", t.text, t.text)
			}
			e.next()
			return &Expr{Kind: t.text, Name: arg.text}, nil
		case "null":
			return nil, refused("null は読まない（変数は <<declare>> の値から始まる）")
		}
		if e.isOp("(") {
			return nil, refused("関数 %s は読まない（関数は visited と visited_count だけ。計算はゲームのコードで行い、変数に入れて渡す）", t.text)
		}
		if _, refused := refusedSpellings[t.text]; refused {
			return nil, unexpected(t)
		}
		return nil, fmt.Errorf("%s を読めない（変数は $%s と書く・文字列は \"%s\"）", t.text, t.text, t.text)
	}
	return nil, unexpected(t)
}

// ── 型 ──

// Variable は <<declare>> 1 つ。値の型が変数の型になる。
type Variable struct {
	Name  string `json:"name"`
	Value Value  `json:"value"`
	File  string `json:"file"`
	Line  int    `json:"line"`
}

// typeEnv は型の検査に使う名前の一覧。
type typeEnv struct {
	vars   map[string]*Variable
	nodes  map[string]bool
	names  []string // 案を出すための変数名
	titles []string
}

// typeOf は式の型を返す（誤りは 1 つ目で止める）。
func (env *typeEnv) typeOf(x *Expr) (ValueType, error) {
	switch x.Kind {
	case "value":
		return x.Value.Type, nil
	case "variable":
		v, ok := env.vars[x.Name]
		if !ok {
			return "", fmt.Errorf("宣言していない変数 %s%s（<<declare %s = 初めの値>> を書く）", x.Name, nearHint(x.Name, env.names), x.Name)
		}
		return v.Value.Type, nil
	case "visited", "visited_count":
		if !env.nodes[x.Name] {
			return "", fmt.Errorf("%s(\"%s\") のノード %s が無い%s", x.Kind, x.Name, x.Name, suggest.Hint(x.Name, env.titles))
		}
		if x.Kind == "visited" {
			return TypeBool, nil
		}
		return TypeNumber, nil
	case "not", "neg":
		t, err := env.typeOf(x.Args[0])
		if err != nil {
			return "", err
		}
		want := TypeBool
		if x.Kind == "neg" {
			want = TypeNumber
		}
		if t != want {
			return "", fmt.Errorf("%s の後ろは %s（%s が来ている）", map[string]string{"not": "not", "neg": "-"}[x.Kind], want, t)
		}
		return want, nil
	}
	l, err := env.typeOf(x.Args[0])
	if err != nil {
		return "", err
	}
	r, err := env.typeOf(x.Args[1])
	if err != nil {
		return "", err
	}
	mismatch := func(want string) error {
		return fmt.Errorf("%s の両側は%s（%s %s %s になっている）", x.Kind, want, l, x.Kind, r)
	}
	switch x.Kind {
	case "+":
		if l == r && (l == TypeNumber || l == TypeString) {
			return l, nil
		}
		return "", mismatch("数どうしか文字列どうし")
	case "-", "*", "/", "%":
		if l == TypeNumber && r == TypeNumber {
			return TypeNumber, nil
		}
		return "", mismatch("数")
	case "<", "<=", ">", ">=":
		if l == TypeNumber && r == TypeNumber {
			return TypeBool, nil
		}
		return "", mismatch("数")
	case "==", "!=":
		if l == r {
			return TypeBool, nil
		}
		return "", mismatch("同じ型")
	case "and", "or":
		if l == TypeBool && r == TypeBool {
			return TypeBool, nil
		}
		return "", mismatch("真偽")
	}
	return "", fmt.Errorf("知らない式の種類 %s", x.Kind)
}

// constantOf は <<declare>> の値（数・真偽・文字列の字そのもの）。変数や計算は読まない。
func constantOf(x *Expr) (Value, bool) {
	if x.Kind == "value" {
		return *x.Value, true
	}
	return Value{}, false
}
