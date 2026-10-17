package px

// op の登録。op の説明（何をするか・どの技法か・仕上げに何を見るか・引数・例）は、この opDef の構造体だけに書く。
// `fge px ops`・`fge px ops --md`（docs/px-ops.md）・`fge px schema`（docs/pxsrc.schema.json）は全部ここから作る。

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// paramType は引数の型（スキーマと読み込みの検査に使う）。
type paramType string

const (
	tNumber   paramType = "number"   // 数
	tInt      paramType = "int"      // 整数
	tString   paramType = "string"   // 文字列
	tBool     paramType = "bool"     // 真偽
	tColor    paramType = "color"    // 色の参照（colorRef）
	tPoint    paramType = "point"    // 画素の位置 [x, y]（整数）
	tPoints   paramType = "points"   // 画素の位置の並び [[x, y], ...]（整数）
	tPair     paramType = "pair"     // 数 2 つ [a, b]
	tNums     paramType = "numbers"  // 数の並び（Len で長さを決める）
	tVecs     paramType = "vectors"  // 座標の並び [[x, y], ...]（小数可。Min 以上）
	tShape    paramType = "shape"    // 形（shape.go）
	tShapes   paramType = "shapes"   // 形の並び（Min〜Max）
	tRows     paramType = "rows"     // 文字の行
	tColorMap paramType = "colormap" // 文字 → 色の参照
	tAxis     paramType = "axis"     // "x"（左右）か "y"（上下）
)

// param は引数 1 つ。
type param struct {
	Name     string
	Type     paramType
	Required bool
	Default  any // 省いたときの値（JSON を読んだ形: 数は float64・配列は []any）
	Summary  string
	Len      int // tNums の長さ（丁度）
	Min, Max int // 配列の長さの範囲（0 は見ない）
}

// colorRef は色の参照: ink・shade・mid・light（部品のランプの 0〜3 段）・ramp[i]・gloss・色キー・""（透明）。
type colorRef string

// opDef は描く手順 1 つ。
type opDef struct {
	Name      string
	Summary   string     // 何をするか（1 行）
	Technique string     // どの技法か（技法カードの「技法」）
	Finish    string     // 仕上げに何を見るか（技法カードの「仕上げ・検査」）
	Example   string     // 書き方の例（{"名前": {…}} の 1 つ。テストで実際に描く）
	Params    []param    //
	Checks    []checkRef // この op の後に、その部品の範囲で走らせる検査
	Exempt    []checkRef // この op が描いた画素は、この検査の対象外（作法として置く形）
	Whole     bool       // 格子全体に描く（use の at・部品の at でずらせない）
	PostOnly  bool       // post にだけ書ける（部品の ops には書けない）
	Apply     func(c *ctx, a opArgs) error
}

var registry = map[string]*opDef{}

// register は op を登録する。名前の重複は作る側の誤りなので止める。
func register(op *opDef) {
	if _, dup := registry[op.Name]; dup {
		panic("px: op の名前が重複している: " + op.Name)
	}
	registry[op.Name] = op
}

// allOps は登録した op を名前の順で返す。
func allOps() []*opDef {
	out := make([]*opDef, 0, len(registry))
	for _, op := range registry {
		out = append(out, op)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// lookupOp は名前から op を引く。
func lookupOp(name string) (*opDef, bool) {
	op, ok := registry[name]
	return op, ok
}

// opArgs は検査済みの引数（省いた物は既定値で埋まっている）。
// Params に無い名前で引くと panic する（op の書き損じ。どの op もテストで例を描くので捕まる）。
type opArgs struct {
	op *opDef
	v  map[string]any
}

func (a opArgs) get(k string) any {
	for _, p := range a.op.Params {
		if p.Name == k {
			return a.v[k]
		}
	}
	panic(fmt.Sprintf("px: op %s の Params に無い引数 %q を引いた", a.op.Name, k))
}

func (a opArgs) num(k string) float64    { f, _ := a.get(k).(float64); return f }
func (a opArgs) int(k string) int        { return int(a.num(k)) }
func (a opArgs) str(k string) string     { s, _ := a.get(k).(string); return s }
func (a opArgs) bool(k string) bool      { b, _ := a.get(k).(bool); return b }
func (a opArgs) color(k string) colorRef { return colorRef(a.str(k)) }
func (a opArgs) has(k string) bool       { return a.get(k) != nil }
func (a opArgs) rows(k string) []string  { return strs(a.get(k)) }
func (a opArgs) shape(k string) any      { return a.get(k) }

func (a opArgs) point(k string) pxlib.Pt {
	p := nums(a.get(k))
	if len(p) != 2 {
		return pxlib.Pt{}
	}
	return pxlib.Pt{X: int(p[0]), Y: int(p[1])}
}

func (a opArgs) pair(k string) [2]float64 {
	p := nums(a.get(k))
	if len(p) != 2 {
		return [2]float64{}
	}
	return [2]float64{p[0], p[1]}
}

func (a opArgs) points(k string) []pxlib.Pt {
	var out []pxlib.Pt
	for _, v := range vecs(a.get(k)) {
		out = append(out, pxlib.Pt{X: int(v[0]), Y: int(v[1])})
	}
	return out
}

func (a opArgs) colorMap(k string) map[string]colorRef {
	m, _ := a.get(k).(map[string]any)
	out := map[string]colorRef{}
	for ch, v := range m {
		s, _ := v.(string)
		out[ch] = colorRef(s)
	}
	return out
}

// opCall は spec に書かれた op 1 つ（{"名前": {引数}}）。Where は spec の中の場所。
type opCall struct {
	Name  string
	Args  opArgs
	Where string
}

// parseOpCall は {"名前": {引数}} を読んで引数を検査する。形の引数は refs で解けるかまで見る。
func parseOpCall(v any, where string, refs map[string]any) (opCall, error) {
	m, ok := v.(map[string]any)
	if !ok || len(m) != 1 {
		return opCall{}, fmt.Errorf("%s: op は鍵 1 つのオブジェクトで書く（{\"fill\": {...}}）", where)
	}
	var name string
	var raw any
	for k, v := range m {
		name, raw = k, v
	}
	op, ok := registry[name]
	if !ok {
		return opCall{}, fmt.Errorf("%s: 知らない op %q（一覧は fge px ops）", where, name)
	}
	where = where + " " + name
	given, ok := raw.(map[string]any)
	if !ok {
		return opCall{}, fmt.Errorf("%s: 引数はオブジェクトで書く（無ければ {}）", where)
	}
	known := map[string]bool{}
	for _, p := range op.Params {
		known[p.Name] = true
	}
	for _, k := range keysOf(given) {
		if !known[k] {
			return opCall{}, fmt.Errorf("%s: 知らない引数 %q（書ける引数: %s）", where, k, paramNames(op))
		}
	}
	args := opArgs{op: op, v: map[string]any{}}
	for _, p := range op.Params {
		v, has := given[p.Name]
		if !has {
			if p.Required {
				return opCall{}, fmt.Errorf("%s: 引数 %s が無い（%s）", where, p.Name, p.Summary)
			}
			args.v[p.Name] = p.Default
			continue
		}
		if err := checkType(p, v); err != nil {
			return opCall{}, fmt.Errorf("%s: 引数 %s は %v", where, p.Name, err)
		}
		if p.Type == tShape {
			if _, err := shapeOf(v, refs, where+"."+p.Name); err != nil {
				return opCall{}, err
			}
		}
		args.v[p.Name] = v
	}
	return opCall{Name: name, Args: args, Where: where}, nil
}

func paramNames(op *opDef) string {
	if len(op.Params) == 0 {
		return "無し"
	}
	names := make([]string, len(op.Params))
	for i, p := range op.Params {
		names[i] = p.Name
	}
	return joinNames(names)
}

func joinNames(names []string) string { return strings.Join(names, " ") }

func isNum(v any) bool { _, ok := v.(float64); return ok }

func isInt(v any) bool { f, ok := v.(float64); return ok && f == math.Trunc(f) && math.Abs(f) < 1<<30 }

// isList は v が長さ n（-1 なら問わない）の配列で、要素がどれも ok か。
func isList(v any, n int, ok func(any) bool) bool {
	arr, isArr := v.([]any)
	if !isArr || (n >= 0 && len(arr) != n) {
		return false
	}
	for _, e := range arr {
		if !ok(e) {
			return false
		}
	}
	return true
}

func lenOK(v any, p param) bool {
	arr, _ := v.([]any)
	return (p.Min == 0 || len(arr) >= p.Min) && (p.Max == 0 || len(arr) <= p.Max)
}

// checkType は値が引数の型に合うかを見る。合わなければ「何で書くか」を返す。
func checkType(p param, v any) error {
	ok, want := false, ""
	switch p.Type {
	case tNumber:
		ok, want = isNum(v), "数"
	case tInt:
		ok, want = isInt(v), "整数"
	case tString, tColor:
		_, ok = v.(string)
		want = "文字列"
	case tBool:
		_, ok = v.(bool)
		want = "true か false"
	case tPoint:
		ok, want = isList(v, 2, isInt), "整数 2 つの配列 [x, y]"
	case tPoints:
		ok = isList(v, -1, func(e any) bool { return isList(e, 2, isInt) }) && lenOK(v, p)
		want = "整数の点の配列 [[x, y], ...]"
	case tPair:
		ok, want = isList(v, 2, isNum), "数 2 つの配列"
	case tNums:
		ok, want = isList(v, p.Len, isNum), fmt.Sprintf("数 %d つの配列", p.Len)
	case tVecs:
		ok = isList(v, -1, func(e any) bool { return isList(e, 2, isNum) }) && lenOK(v, p)
		want = fmt.Sprintf("点 %d つ以上の配列 [[x, y], ...]", p.Min)
	case tShape:
		_, ok = v.(map[string]any)
		want = "形のオブジェクト（{\"disk\": [cx, cy, r]} など）"
	case tShapes:
		ok = isList(v, -1, func(e any) bool { _, isObj := e.(map[string]any); return isObj }) && lenOK(v, p)
		want = "形の配列"
		if p.Min > 0 {
			want = fmt.Sprintf("形 %d つ以上の配列", p.Min)
		}
		if p.Max > 0 && p.Max == p.Min {
			want = fmt.Sprintf("形 %d つの配列", p.Min)
		}
	case tRows:
		ok = isList(v, -1, func(e any) bool { _, isStr := e.(string); return isStr }) && lenOK(v, p)
		want = "文字列の配列"
	case tColorMap:
		m, isMap := v.(map[string]any)
		ok = isMap
		for _, e := range m {
			_, isStr := e.(string)
			ok = ok && isStr
		}
		want = "文字 → 色の参照のオブジェクト"
	case tAxis:
		s, _ := v.(string)
		ok, want = s == "x" || s == "y", "\"x\"（左右）か \"y\"（上下）"
	}
	if !ok {
		return fmt.Errorf("%s で書く", want)
	}
	return nil
}
