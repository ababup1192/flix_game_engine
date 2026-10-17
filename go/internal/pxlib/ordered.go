package pxlib

// 鍵の順を保つ JSON の読み書き。
//
// 書き出しは Python の json.dumps(v, ensure_ascii=False, indent=…) と同じ字面にする
// （生成台本が書いた sprite.json を、Go へ移した後もバイトで比べられるように）。
//
// WhyNot: encoding/json の map[string]any で読まないのは、Go の map が鍵の順を落とすため。
// sprite.json は書いた順がそのまま Studio の並びになり、carve は入れた順で同点を決める。

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

// OMap は入れた順に回る Map。上書きは場所を動かさない。
type OMap[K comparable, V any] struct {
	idx  map[K]int
	keys []K
	vals []V
	live []bool
	n    int
}

// NewOMap は空の OMap を作る。
func NewOMap[K comparable, V any]() *OMap[K, V] {
	return &OMap[K, V]{idx: map[K]int{}}
}

// Set は入れる。既にある鍵は値だけ差し替える (並びは変わらない)。
func (m *OMap[K, V]) Set(k K, v V) {
	if i, ok := m.idx[k]; ok && m.live[i] {
		m.vals[i] = v
		return
	}
	m.idx[k] = len(m.keys)
	m.keys = append(m.keys, k)
	m.vals = append(m.vals, v)
	m.live = append(m.live, true)
	m.n++
}

// Get は値を引く。
func (m *OMap[K, V]) Get(k K) (V, bool) {
	if i, ok := m.idx[k]; ok && m.live[i] {
		return m.vals[i], true
	}
	var zero V
	return zero, false
}

// GetOr は無いときに既定値を返す。
func (m *OMap[K, V]) GetOr(k K, def V) V {
	if v, ok := m.Get(k); ok {
		return v
	}
	return def
}

// Has は鍵があるか。
func (m *OMap[K, V]) Has(k K) bool {
	i, ok := m.idx[k]
	return ok && m.live[i]
}

// Delete は消す。残りの並びは変わらない。
func (m *OMap[K, V]) Delete(k K) {
	if i, ok := m.idx[k]; ok && m.live[i] {
		m.live[i] = false
		delete(m.idx, k)
		m.n--
	}
}

// Len は要素数。
func (m *OMap[K, V]) Len() int { return m.n }

// Keys は入れた順の鍵。
func (m *OMap[K, V]) Keys() []K {
	out := make([]K, 0, m.n)
	for i, k := range m.keys {
		if m.live[i] {
			out = append(out, k)
		}
	}
	return out
}

// Items は入れた順の鍵と値。
func (m *OMap[K, V]) Items() ([]K, []V) {
	keys := make([]K, 0, m.n)
	vals := make([]V, 0, m.n)
	for i, k := range m.keys {
		if m.live[i] {
			keys = append(keys, k)
			vals = append(vals, m.vals[i])
		}
	}
	return keys, vals
}

// Obj は JSON のオブジェクト（鍵の順を保つ）。
type Obj = OMap[string, any]

// NewObj は空のオブジェクトを作る。
func NewObj() *Obj { return NewOMap[string, any]() }

// DecodeOrdered は JSON を読む。オブジェクトは *Obj、数は json.Number、配列は []any になる。
func DecodeOrdered(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := decodeNext(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("JSON の後ろに余計な物がある")
	}
	return v, nil
}

// LoadOrdered はファイルを読み、一番外がオブジェクトであることを確かめる。
func LoadOrdered(path string) (*Obj, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	v, err := DecodeOrdered(data)
	if err != nil {
		return nil, fmt.Errorf("%s: JSON として読めない: %w", path, err)
	}
	o, ok := v.(*Obj)
	if !ok {
		return nil, fmt.Errorf("%s: 一番外はオブジェクトで書く", path)
	}
	return o, nil
}

func decodeNext(dec *json.Decoder) (any, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			o := NewObj()
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				key, _ := kt.(string)
				v, err := decodeNext(dec)
				if err != nil {
					return nil, err
				}
				o.Set(key, v)
			}
			_, err := dec.Token()
			return o, err
		case '[':
			arr := []any{}
			for dec.More() {
				v, err := decodeNext(dec)
				if err != nil {
					return nil, err
				}
				arr = append(arr, v)
			}
			_, err := dec.Token()
			return arr, err
		}
		return nil, io.ErrUnexpectedEOF
	}
	return tok, nil
}

// Plain は *Obj を map[string]any に、json.Number を float64 に戻す（順の要らない読み手へ渡す形）。
func Plain(v any) any {
	switch t := v.(type) {
	case *Obj:
		keys, vals := t.Items()
		m := make(map[string]any, len(keys))
		for i, k := range keys {
			m[k] = Plain(vals[i])
		}
		return m
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = Plain(e)
		}
		return out
	case json.Number:
		f, _ := t.Float64()
		return f
	}
	return v
}

// DetectIndent は JSON の字面から字下げの 1 段を読む（最初に字下げされた行の頭の空白）。見つからなければ "\t"。
func DetectIndent(data []byte) string {
	for _, line := range strings.Split(string(data), "\n") {
		body := strings.TrimLeft(line, " \t")
		if body != "" && len(body) < len(line) {
			return line[:len(line)-len(body)]
		}
	}
	return "\t"
}

// ToJSON は Python の json.dumps(v, ensure_ascii=False, indent=indent) の字面に改行 1 つを足した物。
// 受ける値: *Obj・[]any・[]string・string・json.Number・float64・int・bool・nil。
func ToJSON(v any, indent string) string {
	var b strings.Builder
	writePy(&b, v, indent, 0)
	b.WriteString("\n")
	return b.String()
}

func writePy(b *strings.Builder, v any, indent string, depth int) {
	inner := strings.Repeat(indent, depth+1)
	outer := strings.Repeat(indent, depth)
	switch t := v.(type) {
	case *Obj:
		keys, vals := t.Items()
		if len(keys) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{")
		for i, k := range keys {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString("\n" + inner + JSONString(k) + ": ")
			writePy(b, vals[i], indent, depth+1)
		}
		b.WriteString("\n" + outer + "}")
	case []any:
		if len(t) == 0 {
			b.WriteString("[]")
			return
		}
		b.WriteString("[")
		for i, e := range t {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString("\n" + inner)
			writePy(b, e, indent, depth+1)
		}
		b.WriteString("\n" + outer + "]")
	case []string:
		arr := make([]any, len(t))
		for i, s := range t {
			arr[i] = s
		}
		writePy(b, arr, indent, depth)
	case string:
		b.WriteString(JSONString(t))
	case json.Number:
		b.WriteString(t.String())
	case float64:
		b.WriteString(pyFloat(t))
	case int:
		fmt.Fprintf(b, "%d", t)
	case bool:
		if t {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case nil:
		b.WriteString("null")
	default:
		panic(fmt.Sprintf("ToJSON: 書けない値の型 %T", v))
	}
}

// pyFloat は Python の repr(float)。整数値でも ".0" を付ける。
func pyFloat(f float64) string {
	s := fmt.Sprintf("%v", f)
	if !strings.ContainsAny(s, ".eE") {
		s += ".0"
	}
	return s
}

// JSONString は文字列を JSON の字面にする。非 ASCII は逃がさずそのまま出す（ensure_ascii=False）。
func JSONString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&b, `\u%04x`, r)
				continue
			}
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}
