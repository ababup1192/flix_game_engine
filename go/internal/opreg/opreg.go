package opreg

// opreg — 道具の op の引数の決まり（型・範囲・既定値）と、それを読む・確かめる・docs と schema に書く部品。
// snd の op がこれで登録する。op の説明は op の構造体 1 か所に書き、`ops`・`ops --md`・`schema` は全部そこから作る。
// WhyNot: px の op は形・色の参照など px だけの型を持つので、まだ px 独自の param を使う（移すのは次の段）。

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// Type は引数の型。
type Type string

const (
	Number  Type = "number"  // 数
	Int     Type = "int"     // 整数
	String  Type = "string"  // 文字列
	Bool    Type = "bool"    // 真偽
	Numbers Type = "numbers" // 数の並び
	Choice  Type = "choice"  // 決まった文字列のどれか（Choices）
)

// Param は引数 1 つ。
type Param struct {
	Name     string
	Type     Type
	Required bool
	Default  any // 省いたときの値（JSON を読んだ形: 数は float64・配列は []any）
	Summary  string
	Lo, Hi   *float64 // 数の範囲（nil は見ない。両端を含む）
	Choices  []string // Choice の選べる値
	Min, Max int      // Numbers の長さの範囲（0 は見ない）
}

// Bound は Param の Lo・Hi に書く値。
func Bound(v float64) *float64 { return &v }

// RangeText は数の範囲の文（「0〜1」「0 以上」）。範囲が無ければ ""。
func RangeText(p Param) string {
	f := func(v float64) string { return strconv.FormatFloat(v, 'g', -1, 64) }
	switch {
	case p.Lo != nil && p.Hi != nil:
		return f(*p.Lo) + "〜" + f(*p.Hi)
	case p.Lo != nil:
		return f(*p.Lo) + " 以上"
	case p.Hi != nil:
		return f(*p.Hi) + " 以下"
	}
	return ""
}

func isNum(v any) bool { f, ok := v.(float64); return ok && !math.IsNaN(f) && !math.IsInf(f, 0) }

func isInt(v any) bool { f, ok := v.(float64); return ok && f == math.Trunc(f) && math.Abs(f) < 1<<30 }

// CheckType は値が引数の型と範囲に合うかを見る。合わなければ「何で書くか」を返す。
func CheckType(p Param, v any) error {
	ok, want := false, ""
	switch p.Type {
	case Number:
		ok, want = isNum(v), "数"
	case Int:
		ok, want = isInt(v), "整数"
	case String:
		_, ok = v.(string)
		want = "文字列"
	case Bool:
		_, ok = v.(bool)
		want = "true か false"
	case Choice:
		s, _ := v.(string)
		for _, c := range p.Choices {
			ok = ok || s == c
		}
		want = strings.Join(quoteAll(p.Choices), "・") + " のどれか"
	case Numbers:
		arr, isArr := v.([]any)
		ok = isArr && (p.Min == 0 || len(arr) >= p.Min) && (p.Max == 0 || len(arr) <= p.Max)
		for _, e := range arr {
			ok = ok && isNum(e)
		}
		want = "数の配列"
		if p.Min > 0 && p.Min == p.Max {
			want = fmt.Sprintf("数 %d つの配列", p.Min)
		}
	}
	if !ok {
		return fmt.Errorf("%s で書く", want)
	}
	if f, isF := v.(float64); isF && (p.Type == Number || p.Type == Int) {
		if p.Lo != nil && f < *p.Lo || p.Hi != nil && f > *p.Hi {
			return fmt.Errorf("%s の数で書く（%v は範囲の外）", RangeText(p), f)
		}
	}
	return nil
}

func quoteAll(ss []string) []string {
	out := make([]string, len(ss))
	for i, s := range ss {
		out[i] = strconv.Quote(s)
	}
	return out
}

// Args は確かめた引数（省いた物は既定値で埋まっている）。
type Args map[string]any

func (a Args) Num(k string) float64 { f, _ := a[k].(float64); return f }
func (a Args) Int(k string) int     { return int(a.Num(k)) }
func (a Args) Str(k string) string  { s, _ := a[k].(string); return s }
func (a Args) Bool(k string) bool   { b, _ := a[k].(bool); return b }
func (a Args) Has(k string) bool    { return a[k] != nil }

func (a Args) Nums(k string) []float64 {
	arr, _ := a[k].([]any)
	out := make([]float64, len(arr))
	for i, e := range arr {
		out[i], _ = e.(float64)
	}
	return out
}

// Call は {"名前": {引数}} を 1 つ読んだ物。Where は spec の中の場所（"voices[0].ops[1]"）。
type Call struct {
	Name  string
	Args  Args
	Where string
}

// Parse は {"名前": {引数}} を読んで、params の型・範囲で確かめる。lookup は名前から引数の決まりを引く。
func Parse(v any, where string, lookup func(string) ([]Param, bool)) (Call, error) {
	m, ok := v.(map[string]any)
	if !ok || len(m) != 1 {
		return Call{}, fmt.Errorf("%s: op は鍵 1 つのオブジェクトで書く（{\"pulse\": {...}}）", where)
	}
	var name string
	var raw any
	for k, v := range m {
		name, raw = k, v
	}
	params, ok := lookup(name)
	if !ok {
		return Call{}, fmt.Errorf("%s: 知らない op %q（一覧は ops）", where, name)
	}
	given, ok := raw.(map[string]any)
	if !ok {
		return Call{}, fmt.Errorf("%s %s: 引数はオブジェクトで書く（無ければ {}）", where, name)
	}
	known := map[string]Param{}
	for _, p := range params {
		known[p.Name] = p
	}
	keys := make([]string, 0, len(given))
	for k := range given {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if _, ok := known[k]; !ok {
			return Call{}, fmt.Errorf("%s %s: 知らない引数 %q（書ける引数: %s）", where, name, k, Names(params))
		}
	}
	args := Args{}
	for _, p := range params {
		v, has := given[p.Name]
		if has && v == nil {
			has = false // null は省いたのと同じ（台本の None）
		}
		if !has {
			if p.Required {
				return Call{}, fmt.Errorf("%s %s: 引数 %s が無い（%s）", where, name, p.Name, p.Summary)
			}
			args[p.Name] = p.Default
			continue
		}
		if err := CheckType(p, v); err != nil {
			return Call{}, fmt.Errorf("%s %s: 引数 %s は %v", where, name, p.Name, err)
		}
		args[p.Name] = v
	}
	return Call{Name: name, Args: args, Where: where + " " + name}, nil
}

// Names は引数の名前を空白で並べる。
func Names(params []Param) string {
	if len(params) == 0 {
		return "無し"
	}
	names := make([]string, len(params))
	for i, p := range params {
		names[i] = p.Name
	}
	return strings.Join(names, " ")
}

// MarkdownParams は引数の表（docs の op の節）。
func MarkdownParams(params []Param) string {
	if len(params) == 0 {
		return "引数なし。\n"
	}
	var b strings.Builder
	b.WriteString("| 引数 | 型 | 既定 | 説明 |\n|---|---|---|---|\n")
	for _, p := range params {
		def := "（必須）"
		if !p.Required {
			js, _ := json.Marshal(p.Default)
			def = "`" + string(js) + "`"
		}
		typ := string(p.Type)
		if p.Type == Choice {
			typ = strings.Join(p.Choices, " / ")
		}
		if r := RangeText(p); r != "" {
			typ += "（" + r + "）"
		}
		fmt.Fprintf(&b, "| `%s` | %s | %s | %s |\n", p.Name, typ, def, p.Summary)
	}
	return b.String()
}

// SchemaOf は引数の JSON Schema（op の引数オブジェクト）。
func SchemaOf(params []Param) map[string]any {
	props := map[string]any{}
	var req []string
	for _, p := range params {
		s := map[string]any{"description": p.Summary}
		switch p.Type {
		case Number:
			s["type"] = "number"
		case Int:
			s["type"] = "integer"
		case String:
			s["type"] = "string"
		case Bool:
			s["type"] = "boolean"
		case Choice:
			s["enum"] = p.Choices
		case Numbers:
			s["type"] = "array"
			s["items"] = map[string]any{"type": "number"}
			if p.Min > 0 {
				s["minItems"] = p.Min
			}
			if p.Max > 0 {
				s["maxItems"] = p.Max
			}
		}
		if p.Lo != nil {
			s["minimum"] = *p.Lo
		}
		if p.Hi != nil {
			s["maximum"] = *p.Hi
		}
		if !p.Required && p.Default != nil {
			s["default"] = p.Default
		}
		if p.Required {
			req = append(req, p.Name)
		}
		props[p.Name] = s
	}
	out := map[string]any{"type": "object", "additionalProperties": false, "properties": props}
	if len(req) > 0 {
		out["required"] = req
	}
	return out
}
