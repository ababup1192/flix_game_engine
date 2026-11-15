package yarn

// コマンドの引数を vocab.json（v2）の commands の表で見る。受ける・断るの判定は engine_world の
// YarnCommands.parse と同じ（見本は testdata/command-args.json を両方が読む）。違うのは ref と orNames の
// Doc の名前を照らす所だけ（実行時は Doc を持たないので照らさない）。

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/suggest"
)

// maxPositional は位置の引数の数の上限。
const maxPositional = 2

// CommandSpec はコマンド 1 つの引数の表（vocab.json の commands の 1 つ）。
type CommandSpec struct {
	Summary string      `json:"summary"`
	Params  []ParamSpec `json:"params"`
}

// ParamSpec は引数 1 つ。Pos = 位置で書ける順番（0 は key=value だけ）・OrWords = 型の外に受ける語・
// OrNames = 型に合わない値を名前として受ける時の Doc・List = , で並べる・OneOf = どれか 1 つは要る組の名前。
type ParamSpec struct {
	Name    string          `json:"name"`
	Pos     int             `json:"pos,omitempty"`
	Type    string          `json:"type"`
	Min     *float64        `json:"min,omitempty"`
	Max     *float64        `json:"max,omitempty"`
	Values  []string        `json:"values,omitempty"`
	Ref     json.RawMessage `json:"ref,omitempty"`
	Default *string         `json:"default,omitempty"`
	Req     bool            `json:"req,omitempty"`
	OrWords []string        `json:"orWords,omitempty"`
	OrNames json.RawMessage `json:"orNames,omitempty"`
	List    bool            `json:"list,omitempty"`
	OneOf   string          `json:"oneOf,omitempty"`
	// refNames と orNames は Doc から集めた名前。nil は照らさない（Doc を読めない・ref が無い）。
	refNames   map[string]bool
	orNameSet  map[string]bool
	refList    []string
	orNameList []string
}

var paramTypes = map[string]bool{"num": true, "time": true, "name": true, "choice": true, "flag": true, "ease": true}

// validate は表そのものの誤り（名前の重なり・位置の番号・知らない型）。
func (c *CommandSpec) validate(name string) error {
	seen := map[string]bool{}
	var positions []int
	for _, p := range c.Params {
		if p.Name == "" {
			return fmt.Errorf("語彙の commands の %s に名前の無い引数がある", name)
		}
		if seen[p.Name] {
			return fmt.Errorf("語彙の commands の %s に同じ名前の引数 %s が 2 つある", name, p.Name)
		}
		seen[p.Name] = true
		if !paramTypes[p.Type] {
			return fmt.Errorf("語彙の commands の %s の引数 %s の type %q を知らない（num・time・name・choice・flag・ease）", name, p.Name, p.Type)
		}
		if p.Type == "num" && (p.Min == nil || p.Max == nil) {
			return fmt.Errorf("語彙の commands の %s の引数 %s に min と max が要る", name, p.Name)
		}
		if (p.Type == "choice" || p.Type == "ease") && len(p.Values) == 0 {
			return fmt.Errorf("語彙の commands の %s の引数 %s（%s）に values が要る", name, p.Name, p.Type)
		}
		if p.Default != nil && len(p.OrNames) == 0 && !contains(p.OrWords, *p.Default) && !fitsArgType(&p, *p.Default) {
			return fmt.Errorf("語彙の commands の %s の引数 %s の既定の値 %s が型に合わない（%s）", name, p.Name, *p.Default, expectedArg(&p))
		}
		if p.Pos > 0 {
			positions = append(positions, p.Pos)
		}
	}
	sort.Ints(positions)
	for i, pos := range positions {
		if pos != i+1 || i >= maxPositional {
			return fmt.Errorf("語彙の commands の %s の位置の番号は 1 から順に %d つまで", name, maxPositional)
		}
	}
	return nil
}

// CheckArgs は引数を表で見て、誤りがあれば 1 行（無ければ ""）。
func CheckArgs(command string, spec *CommandSpec, args []string) string {
	type pair struct{ name, value string }
	var positional []string
	var keyed []pair
	for _, raw := range args {
		if strings.HasPrefix(raw, `"`) {
			v, ok := unquoteArg(raw)
			if !ok {
				return fmt.Sprintf("<<%s>> の \"…\" が閉じていないか、中に裸の \" がある（中の \" は \\\" と書く）: %s", command, raw)
			}
			positional = append(positional, v)
			continue
		}
		key, value, ok := keyOfArg(raw)
		if !ok {
			positional = append(positional, raw)
			continue
		}
		if strings.HasPrefix(value, `"`) {
			v, ok := unquoteArg(value)
			if !ok {
				return fmt.Sprintf("<<%s>> の \"…\" が閉じていないか、中に裸の \" がある（中の \" は \\\" と書く）: %s", command, value)
			}
			value = v
		}
		keyed = append(keyed, pair{key, value})
	}
	byName := map[string]*ParamSpec{}
	var names []string
	var slots []*ParamSpec
	for i := range spec.Params {
		p := &spec.Params[i]
		byName[p.Name] = p
		names = append(names, p.Name)
		if p.Pos > 0 {
			slots = append(slots, p)
		}
	}
	sort.Slice(slots, func(a, b int) bool { return slots[a].Pos < slots[b].Pos })
	if len(positional) > 0 && len(spec.Params) == 0 {
		return fmt.Sprintf("<<%s>> は引数を取らない", command)
	}
	if len(positional) > len(slots) {
		return fmt.Sprintf("<<%s>> の位置の引数は %d つまで（%d つ書いてある。ほかは key=value で書く）", command, len(slots), len(positional))
	}
	var pairs []pair
	for i, v := range positional {
		pairs = append(pairs, pair{slots[i].Name, v})
	}
	pairs = append(pairs, keyed...)
	for _, kv := range keyed {
		if byName[kv.name] == nil {
			return fmt.Sprintf("<<%s>> に知らない鍵 %s%s", command, kv.name, suggest.Hint(kv.name, names))
		}
	}
	given := map[string]bool{}
	for _, kv := range pairs {
		if given[kv.name] {
			return fmt.Sprintf("<<%s>> の %s を 2 回書いている", command, kv.name)
		}
		given[kv.name] = true
	}
	for _, kv := range pairs {
		if msg := checkArgValue(command, byName[kv.name], kv.value); msg != "" {
			return msg
		}
	}
	var groups []string
	filled := map[string]bool{}
	for _, p := range spec.Params {
		if p.Req && !given[p.Name] {
			return fmt.Sprintf("<<%s>> に %s が要る", command, p.Name)
		}
		if p.OneOf == "" {
			continue
		}
		if !contains(groups, p.OneOf) {
			groups = append(groups, p.OneOf)
		}
		if given[p.Name] {
			filled[p.OneOf] = true
		}
	}
	for _, g := range groups {
		if filled[g] {
			continue
		}
		var members []string
		for _, p := range spec.Params {
			if p.OneOf == g {
				members = append(members, p.Name)
			}
		}
		return fmt.Sprintf("<<%s>> は %s のどれかを書く", command, strings.Join(members, " か "))
	}
	return ""
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

// keyOfArg は key=value の key と value（= の前が英字か _ で始まる英数字と _ の時だけ）。
func keyOfArg(raw string) (string, string, bool) {
	i := strings.Index(raw, "=")
	if i <= 0 || !isASCIIIdentifier(raw[:i]) {
		return "", "", false
	}
	return raw[:i], raw[i+1:], true
}

func isASCIIIdentifier(s string) bool {
	for i, c := range s {
		start := c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if !start && (i == 0 || c < '0' || c > '9') {
			return false
		}
	}
	return s != ""
}

// unquoteArg は "…" の中身（\" と \\ を 1 字に戻す）。閉じていない・中に裸の " がある時は ok が false。
func unquoteArg(raw string) (string, bool) {
	rs := []rune(raw)
	if len(rs) < 2 || rs[0] != '"' || rs[len(rs)-1] != '"' {
		return "", false
	}
	var b strings.Builder
	inner := rs[1 : len(rs)-1]
	for i := 0; i < len(inner); i++ {
		switch inner[i] {
		case '\\':
			if i+1 >= len(inner) {
				return "", false
			}
			i++
			b.WriteRune(inner[i])
		case '"':
			return "", false
		default:
			b.WriteRune(inner[i])
		}
	}
	return b.String(), true
}

func checkArgValue(command string, p *ParamSpec, value string) string {
	if value == "" {
		return fmt.Sprintf("<<%s>> の %s に値が無い", command, p.Name)
	}
	if contains(p.OrWords, value) {
		return ""
	}
	parts := []string{value}
	if p.List {
		parts = strings.Split(value, ",")
	}
	for _, v := range parts {
		if msg := checkOneArg(command, p, v); msg != "" {
			return msg
		}
	}
	return ""
}

func checkOneArg(command string, p *ParamSpec, v string) string {
	_, isNum := argNumber(v)
	numeric := p.Type == "num" || p.Type == "time"
	if fitsArgType(p, v) {
		if p.Type == "name" && p.refNames != nil && !p.refNames[v] {
			return fmt.Sprintf("<<%s>> の %s の %s が Doc に無い%s", command, p.Name, v, suggest.Hint(v, p.refList))
		}
		return ""
	}
	if v != "" && len(p.OrNames) > 0 && !(numeric && isNum) {
		if p.orNameSet != nil && !p.orNameSet[v] {
			return fmt.Sprintf("<<%s>> の %s の %s が Doc に無い%s", command, p.Name, v, suggest.Hint(v, p.orNameList))
		}
		return ""
	}
	return fmt.Sprintf("<<%s>> の %s に %s は書けない（%s）", command, p.Name, v, expectedArg(p))
}

func fitsArgType(p *ParamSpec, v string) bool {
	switch p.Type {
	case "num":
		x, ok := argNumber(v)
		return ok && x >= *p.Min && x <= *p.Max
	case "time":
		x, ok := argNumber(v)
		return ok && x >= 0
	case "name":
		return v != ""
	case "choice", "ease":
		return contains(p.Values, v)
	case "flag":
		return v == "true" || v == "false"
	}
	return false
}

// argNumber は数の字（- と数字と、. の後の数字だけ。1e3・.5・+1 は受けない。YarnCommands.numberOf と同じ形）。
func argNumber(v string) (float64, bool) {
	body := strings.TrimPrefix(v, "-")
	whole, frac, hasDot := strings.Cut(body, ".")
	if !allDigits(whole) || (hasDot && !allDigits(frac)) {
		return 0, false
	}
	x, err := strconv.ParseFloat(v, 64)
	return x, err == nil
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func expectedArg(p *ParamSpec) string {
	var base string
	switch p.Type {
	case "num":
		base = fmt.Sprintf("%s〜%s の数", strconv.FormatFloat(*p.Min, 'f', -1, 64), strconv.FormatFloat(*p.Max, 'f', -1, 64))
	case "time":
		base = "0 以上の秒"
	case "name":
		base = "名前"
	case "choice":
		base = strings.Join(p.Values, " / ")
	case "flag":
		base = "true / false"
	case "ease":
		base = "ease の名前（linear・smoothstep・inOutCubic など）"
	}
	if p.List {
		base += "を , で並べる"
	}
	for _, w := range p.OrWords {
		base += " / " + w
	}
	return base
}
