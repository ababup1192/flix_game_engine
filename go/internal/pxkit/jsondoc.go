package pxkit

// 入れた順を保つ JSON の読み書き。書き出しは Python の
// json.dump(doc, ensure_ascii=False, indent="\t") と同じ字面にする
// （今の生成台本が書いた sprite.json を、移した後もバイトで比べられるように）。

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
)

// Obj は鍵の順を保つオブジェクト。
type Obj struct {
	Keys []string
	Vals map[string]any
}

func newObj() *Obj { return &Obj{Vals: map[string]any{}} }

// Set は鍵を足す（ある鍵は場所を動かさず値だけ差し替える）。
func (o *Obj) Set(k string, v any) {
	if _, ok := o.Vals[k]; !ok {
		o.Keys = append(o.Keys, k)
	}
	o.Vals[k] = v
}

// Get は値を引く。
func (o *Obj) Get(k string) any { return o.Vals[k] }

func decodeOrdered(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	return decodeFrom(dec, tok)
}

func decodeFrom(dec *json.Decoder, tok json.Token) (any, error) {
	switch t := tok.(type) {
	case json.Delim:
		if t == '{' {
			o := newObj()
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				vt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				v, err := decodeFrom(dec, vt)
				if err != nil {
					return nil, err
				}
				o.Set(kt.(string), v)
			}
			_, err := dec.Token()
			return o, err
		}
		if t == '[' {
			arr := []any{}
			for dec.More() {
				vt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				v, err := decodeFrom(dec, vt)
				if err != nil {
					return nil, err
				}
				arr = append(arr, v)
			}
			_, err := dec.Token()
			return arr, err
		}
		return nil, io.ErrUnexpectedEOF
	default:
		return tok, nil
	}
}

// plain は Obj を map[string]any に、json.Number を float64 に戻す（op が読む形）。
func plain(v any) any {
	switch t := v.(type) {
	case *Obj:
		m := make(map[string]any, len(t.Keys))
		for _, k := range t.Keys {
			m[k] = plain(t.Vals[k])
		}
		return m
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = plain(e)
		}
		return out
	case json.Number:
		f, _ := t.Float64()
		return f
	}
	return v
}

// dumpPy は Python の json.dump(indent="\t", ensure_ascii=False) の字面。
func dumpPy(v any) string {
	var b strings.Builder
	writePy(&b, v, 0)
	b.WriteString("\n")
	return b.String()
}

func writePy(b *strings.Builder, v any, depth int) {
	ind := strings.Repeat("\t", depth+1)
	switch t := v.(type) {
	case *Obj:
		if len(t.Keys) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{")
		for i, k := range t.Keys {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString("\n" + ind + pyString(k) + ": ")
			writePy(b, t.Vals[k], depth+1)
		}
		b.WriteString("\n" + strings.Repeat("\t", depth) + "}")
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
			b.WriteString("\n" + ind)
			writePy(b, e, depth+1)
		}
		b.WriteString("\n" + strings.Repeat("\t", depth) + "]")
	case []string:
		arr := make([]any, len(t))
		for i, s := range t {
			arr[i] = s
		}
		writePy(b, arr, depth)
	case string:
		b.WriteString(pyString(t))
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

func pyString(s string) string {
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

func num(v any, def float64) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case json.Number:
		f, _ := t.Float64()
		return f
	}
	return def
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
