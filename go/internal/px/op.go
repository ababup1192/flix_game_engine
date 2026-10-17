package px

// op の登録。op の説明（何をするか・どの技法か・仕上げに何を見るか・引数）は、この Op の構造体だけに書く。
// `fge px ops`・`fge px ops --md`（docs/px-ops.md）・`fge px schema`（docs/pxsrc.schema.json）は全部ここから作る。

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

// ParamType は op の引数の型（スキーマと読み込みの検査に使う）。
type ParamType string

const (
	TNumber   ParamType = "number"   // 数
	TInt      ParamType = "int"      // 整数
	TString   ParamType = "string"   // 文字列
	TBool     ParamType = "bool"     // 真偽
	TColor    ParamType = "color"    // 色: ink・shade・mid・light・ramp[i]・gloss・色キー・""（透明）
	TPoint    ParamType = "point"    // [x, y]
	TPair     ParamType = "pair"     // [a, b]（数 2 つ）
	TPoints   ParamType = "points"   // [[x, y], ...]
	TShape    ParamType = "shape"    // 形（shape.go）
	TRows     ParamType = "rows"     // 文字の行
	TColorMap ParamType = "colormap" // 文字 → 色
	TAxis     ParamType = "axis"     // "x"（左右）か "y"（上下）
)

// Param は op の引数 1 つ。
type Param struct {
	Name     string
	Type     ParamType
	Required bool
	Default  any // 省いたときの値（Required なら nil）
	Summary  string
}

// Op は描く手順 1 つ。
type Op struct {
	Name      string
	Summary   string   // 何をするか（1 行）
	Technique string   // どの技法か（技法カードの「技法」）
	Finish    string   // 仕上げに何を見るか（技法カードの「仕上げ・検査」）
	Params    []Param  //
	Checks    []string // この op の後に、その部品の範囲で走らせる検査（check.go の名前）
	Whole     bool     // 格子全体に描く（use の at・部品の at でずらせない）
	Apply     func(c *Ctx, a Args) error
}

var registry = map[string]*Op{}

// Register は op を登録する。名前の重複は作る側の誤りなので止める。
func Register(op *Op) {
	if _, dup := registry[op.Name]; dup {
		panic("px: op の名前が重複している: " + op.Name)
	}
	registry[op.Name] = op
}

// Ops は登録した op を名前の順で返す。
func Ops() []*Op {
	out := make([]*Op, 0, len(registry))
	for _, op := range registry {
		out = append(out, op)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// LookupOp は名前から op を引く。
func LookupOp(name string) (*Op, bool) {
	op, ok := registry[name]
	return op, ok
}

// Args は検査済みの引数（省いた物は既定値で埋まっている）。
type Args map[string]any

// Num は数。
func (a Args) Num(k string) float64 { return num(a[k], 0) }

// Int は整数。
func (a Args) Int(k string) int { return int(num(a[k], 0)) }

// Str は文字列。
func (a Args) Str(k string) string { s, _ := a[k].(string); return s }

// Bool は真偽。
func (a Args) Bool(k string) bool { b, _ := a[k].(bool); return b }

// Has は書かれているか（既定値の無い任意の引数）。
func (a Args) Has(k string) bool { return a[k] != nil }

// Point は [x, y]。
func (a Args) Point(k string) [2]float64 {
	p := nums(a[k])
	if len(p) != 2 {
		return [2]float64{}
	}
	return [2]float64{p[0], p[1]}
}

// Points は [[x, y], ...]。
func (a Args) Points(k string) [][2]float64 { return points(a[k]) }

// Rows は文字の行。
func (a Args) Rows(k string) []string { return strs(a[k]) }

// ColorMap は文字 → 色の名前。
func (a Args) ColorMap(k string) map[string]string {
	m, _ := a[k].(map[string]any)
	out := map[string]string{}
	for ch, v := range m {
		s, _ := v.(string)
		out[ch] = s
	}
	return out
}

// OpCall は spec に書かれた op 1 つ（{"名前": {引数}}）。Where は spec の中の場所。
type OpCall struct {
	Name  string
	Args  Args
	Where string
}

// parseOpCall は {"名前": {引数}} を読んで引数を検査する。
func parseOpCall(v any, where string) (OpCall, error) {
	m, ok := v.(map[string]any)
	if !ok || len(m) != 1 {
		return OpCall{}, fmt.Errorf("%s: op は鍵 1 つのオブジェクトで書く（{\"fill\": {...}}）", where)
	}
	var name string
	var raw any
	for k, v := range m {
		name, raw = k, v
	}
	op, ok := registry[name]
	if !ok {
		return OpCall{}, fmt.Errorf("%s: 知らない op %q（一覧は fge px ops）", where, name)
	}
	where = where + " " + name
	given, ok := raw.(map[string]any)
	if !ok {
		return OpCall{}, fmt.Errorf("%s: 引数はオブジェクトで書く（無ければ {}）", where)
	}
	known := map[string]*Param{}
	for i := range op.Params {
		known[op.Params[i].Name] = &op.Params[i]
	}
	for _, k := range keysOf(given) {
		if known[k] == nil {
			return OpCall{}, fmt.Errorf("%s: 知らない引数 %q（書ける引数: %s）", where, k, paramNames(op))
		}
	}
	args := Args{}
	for _, p := range op.Params {
		v, has := given[p.Name]
		if !has {
			if p.Required {
				return OpCall{}, fmt.Errorf("%s: 引数 %s が無い（%s）", where, p.Name, p.Summary)
			}
			args[p.Name] = p.Default
			continue
		}
		if err := checkType(p.Type, v); err != nil {
			return OpCall{}, fmt.Errorf("%s: 引数 %s は %s", where, p.Name, err)
		}
		args[p.Name] = v
	}
	return OpCall{Name: name, Args: args, Where: where}, nil
}

func paramNames(op *Op) string {
	if len(op.Params) == 0 {
		return "無し"
	}
	names := make([]string, len(op.Params))
	for i, p := range op.Params {
		names[i] = p.Name
	}
	return strings.Join(names, " ")
}

func isNums(v any, n int) bool {
	arr, ok := v.([]any)
	if !ok || (n >= 0 && len(arr) != n) {
		return false
	}
	for _, e := range arr {
		if _, ok := e.(float64); !ok {
			return false
		}
	}
	return true
}

// checkType は値が型に合うかを見る。合わなければ「何で書くか」を返す。
func checkType(t ParamType, v any) error {
	ok := false
	want := ""
	switch t {
	case TNumber:
		_, ok = v.(float64)
		want = "数"
	case TInt:
		f, isNum := v.(float64)
		ok = isNum && f == math.Trunc(f)
		want = "整数"
	case TString, TColor:
		_, ok = v.(string)
		want = "文字列"
	case TBool:
		_, ok = v.(bool)
		want = "true か false"
	case TPoint, TPair:
		ok = isNums(v, 2)
		want = "数 2 つの配列"
	case TPoints:
		arr, isArr := v.([]any)
		ok = isArr
		for _, e := range arr {
			ok = ok && isNums(e, 2)
		}
		want = "[[x, y], ...]"
	case TShape:
		_, ok = v.(map[string]any)
		want = "形のオブジェクト（{\"disk\": [cx, cy, r]} など）"
	case TRows:
		arr, isArr := v.([]any)
		ok = isArr
		for _, e := range arr {
			_, isStr := e.(string)
			ok = ok && isStr
		}
		want = "文字列の配列"
	case TColorMap:
		m, isMap := v.(map[string]any)
		ok = isMap
		for _, e := range m {
			_, isStr := e.(string)
			ok = ok && isStr
		}
		want = "文字 → 色の名前のオブジェクト"
	case TAxis:
		s, _ := v.(string)
		ok = s == "x" || s == "y"
		want = "\"x\"（左右）か \"y\"（上下）"
	}
	if !ok {
		return fmt.Errorf("%s で書く", want)
	}
	return nil
}
