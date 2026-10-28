package recordwrap

// World の形の 2 規則。
//
//	world-resource  World.World の欄に Doc や描く元 (resourceTypes に当たる型) がある
//	world-fields    World.World の一番上の欄が maxTopFields を超える
//
// どちらも root の型を、パッケージ内の型エイリアスと 1 case の enum をたどって record に着いてから見る
// (World そのものを enum で包んでも同じに見る)。world-resource は欄の型を、型エイリアスと
// パッケージ内の enum の payload (何 case でも) までたどる。
// WhyNot: List・Option・Map などの型引数の中へは降りない。遊びの状態の List[Enemy] の中に
// Doc の Rec が入っているのは「ゲームが持つ敵の値」で、World の外へ出す物ではないため。
// WhyNot: 画面の enum の case の数で見るかどうかを変えない。1 case なら止まり、case を 1 つ足すと
// 通る、では画面を足しただけで Doc が World に戻れてしまう。
// エンジンの型はソースが見えないので中を見ない。

import (
	"regexp"
	"sort"
	"strings"
)

var (
	enumRe     = regexp.MustCompile(`\benum\s+([A-Z][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?`)
	headNameRe = regexp.MustCompile(`^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*`)
)

// Enum はパッケージ内の enum。Payloads は case ごとの payload (payload の無い case は数えない)。
type Enum struct {
	Path     string
	Mod      string
	Name     string
	Text     string
	Cases    int
	Payloads []Payload
}

// Payload は case の payload 1 つ。Offset は payload の先頭のファイル内の位置。
type Payload struct {
	Type   string
	Offset int
}

func (e Enum) key() string { return e.Mod + "." + e.Name }

// matchClose は code[open] の括弧に対応する閉じ括弧の位置。見つからなければ -1。
func matchClose(code string, open int) int {
	depth := 0
	for i := open; i < len(code); i++ {
		switch code[i] {
		case '{', '[', '(':
			depth++
		case '}', ']', ')':
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// ParseEnums は 1 ファイルの enum を拾う。`enum X(T)` と `enum X { case A(T), B, case C(U) }` の両方を読む。
func ParseEnums(rel, text string) []Enum {
	code := stripComments(text)
	mods := modRe.FindAllStringSubmatchIndex(code, -1)
	var out []Enum
	for _, m := range enumRe.FindAllStringSubmatchIndex(code, -1) {
		mod := ""
		for _, md := range mods {
			if md[0] < m[0] {
				mod = lastSegment(code[md[2]:md[3]])
			}
		}
		e := Enum{Path: rel, Mod: mod, Name: code[m[2]:m[3]], Text: text}
		rest := strings.TrimLeft(code[m[1]:], " \t")
		at := len(code) - len(rest)
		if strings.HasPrefix(rest, "(") {
			if end := matchClose(code, at); end > 0 {
				e.Cases = 1
				e.Payloads = []Payload{trimPayload(code, at+1, end)}
			}
		} else if open := strings.Index(rest, "{"); open >= 0 {
			if end := matchClose(code, at+open); end > 0 {
				e.Cases, e.Payloads = casePayloads(code, at+open+1, end)
			}
		}
		out = append(out, e)
	}
	return out
}

// trimPayload は code[from:to] の前後の空白を除いた payload。
func trimPayload(code string, from, to int) Payload {
	body := code[from:to]
	lead := len(body) - len(strings.TrimLeft(body, " \t\r\n"))
	return Payload{Type: strings.TrimSpace(body), Offset: from + lead}
}

// casePayloads は enum の本体 code[from:to] の case の数と payload。case の名前は
// 括弧の外の大文字で始まる名前 (直後の ( が payload)。
func casePayloads(code string, from, to int) (int, []Payload) {
	cases := 0
	var out []Payload
	depth := 0
	for i := from; i < to; i++ {
		switch c := code[i]; {
		case c == '{' || c == '[' || c == '(':
			depth++
		case c == '}' || c == ']' || c == ')':
			depth--
		case depth == 0 && c >= 'A' && c <= 'Z' && (i == from || !isIdent(code[i-1])):
			name := headNameRe.FindString(code[i:to])
			cases++
			j := i + len(name)
			for j < to && (code[j] == ' ' || code[j] == '\t') {
				j++
			}
			if j < to && code[j] == '(' {
				if end := matchClose(code, j); end > 0 && end < to {
					out = append(out, trimPayload(code, j+1, end))
					i = end
					continue
				}
			}
			i = j - 1
		}
	}
	return cases, out
}

func isIdent(c byte) bool {
	return c == '_' || c == '.' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// splitTop は括弧の外の , で分ける。
func splitTop(s string) []string {
	var out []string
	depth, from := 0, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '{', '[', '(':
			depth++
		case '}', ']', ')':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, s[from:i])
				from = i + 1
			}
		}
	}
	return append(out, s[from:])
}

// shape は World の形の規則が型をたどるのに使う、パッケージの型の表。
type shape struct {
	aliases map[string]Alias
	enums   map[string]Enum
	res     []*regexp.Regexp
}

// candidates は型の名前 (書かれたまま) を規約の正規表現に当てる形にする。
// 修飾の無い名前はいる mod で修飾し、長い修飾は最後の 2 つも当てる。
func candidates(mod, name string) []string {
	parts := strings.Split(name, ".")
	if len(parts) == 1 {
		if mod == "" {
			return []string{name}
		}
		return []string{mod + "." + name, name}
	}
	out := []string{name}
	if len(parts) > 2 {
		out = append(out, strings.Join(parts[len(parts)-2:], "."))
	}
	return out
}

// resources は型の式 t (モジュール mod の中で書かれた物) の中の、規約に当たる型の名前。
func (s shape) resources(mod, t string, stack, sources map[string]bool) []string {
	t = strings.TrimSpace(t)
	if fields := Fields(t); fields != nil {
		var out []string
		for _, f := range fields {
			out = append(out, s.resources(mod, f.Type, stack, sources)...)
		}
		return out
	}
	if strings.HasPrefix(t, "(") && matchClose(t, 0) == len(t)-1 {
		var out []string
		for _, part := range splitTop(t[1 : len(t)-1]) {
			out = append(out, s.resources(mod, part, stack, sources)...)
		}
		return out
	}
	name := headNameRe.FindString(t)
	if name == "" {
		return nil
	}
	cands := candidates(mod, name)
	for _, re := range s.res {
		for _, c := range cands {
			if re.MatchString(c) {
				return []string{cands[0]}
			}
		}
	}
	parts := strings.Split(name, ".")
	owner := mod
	if len(parts) > 1 {
		owner = parts[len(parts)-2]
	}
	key := owner + "." + parts[len(parts)-1]
	if stack[key] {
		return nil
	}
	if a, ok := s.aliases[key]; ok {
		stack[key] = true
		sources[a.Path] = true
		defer delete(stack, key)
		return s.resources(a.Mod, a.Body, stack, sources)
	}
	if e, ok := s.enums[key]; ok {
		stack[key] = true
		sources[e.Path] = true
		defer delete(stack, key)
		var out []string
		for _, p := range e.Payloads {
			out = append(out, s.resources(e.Mod, p.Type, stack, sources)...)
		}
		return out
	}
	return nil
}

// record は root がたどり着く record。型エイリアスと 1 case の enum をたどる。
type record struct {
	Path string
	Mod  string
	Text string
	Body string
	// Open は Body の { のファイル内の位置。
	Open int
}

// lookup は mod の中で書かれた型の名前 t を、パッケージ内の宣言の鍵にする。
func lookup(mod, t string) string {
	name := headNameRe.FindString(strings.TrimSpace(t))
	parts := strings.Split(name, ".")
	if len(parts) == 1 {
		return mod + "." + name
	}
	return parts[len(parts)-2] + "." + parts[len(parts)-1]
}

// rootRecord は root の型からたどり着く record と、たどった宣言のあるファイル。
func (s shape) rootRecord(root string, stack, sources map[string]bool) (record, bool) {
	key := root
	for !stack[key] {
		stack[key] = true
		if a, ok := s.aliases[key]; ok {
			sources[a.Path] = true
			if strings.HasPrefix(a.Body, "{") {
				return record{Path: a.Path, Mod: a.Mod, Text: a.Text, Body: a.Body, Open: a.Offset}, true
			}
			key = lookup(a.Mod, a.Body)
			continue
		}
		e, ok := s.enums[key]
		if !ok || e.Cases != 1 || len(e.Payloads) != 1 {
			return record{}, false
		}
		sources[e.Path] = true
		p := e.Payloads[0]
		if strings.HasPrefix(p.Type, "{") {
			return record{Path: e.Path, Mod: e.Mod, Text: e.Text, Body: p.Type, Open: p.Offset}, true
		}
		key = lookup(e.Mod, p.Type)
	}
	return record{}, false
}

// WorldHits は roots の型について World の形の 2 規則の当たりを返す。
func WorldHits(aliases []Alias, enums []Enum, roots []string, res []*regexp.Regexp, maxTopFields int) []Hit {
	s := shape{aliases: map[string]Alias{}, enums: map[string]Enum{}, res: res}
	for _, a := range aliases {
		s.aliases[a.key()] = a
	}
	for _, e := range enums {
		s.enums[e.key()] = e
	}
	var hits []Hit
	for _, root := range roots {
		stack, rootSources := map[string]bool{}, map[string]bool{}
		r, ok := s.rootRecord(root, stack, rootSources)
		if !ok {
			continue
		}
		fields := Fields(r.Body)
		for _, f := range fields {
			sources := map[string]bool{}
			for p := range rootSources {
				sources[p] = true
			}
			found := s.resources(r.Mod, f.Type, stack, sources)
			if len(found) == 0 {
				continue
			}
			sort.Strings(found)
			line := 1 + strings.Count(r.Text[:r.Open+f.At], "\n")
			hits = append(hits, Hit{Path: r.Path, Line: line, Root: root, Field: f.Name, Type: f.Type,
				Rule: RuleWorldResource, Found: dedup(found), Sources: sources})
		}
		if len(fields) > maxTopFields {
			line := 1 + strings.Count(r.Text[:r.Open], "\n")
			hits = append(hits, Hit{Path: r.Path, Line: line, Root: root, Size: len(fields),
				Rule: RuleWorldFields, Sources: rootSources})
		}
	}
	return hits
}

func dedup(xs []string) []string {
	var out []string
	for i, x := range xs {
		if i == 0 || xs[i-1] != x {
			out = append(out, x)
		}
	}
	return out
}
