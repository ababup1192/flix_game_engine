package refactor

import (
	"sort"
	"strconv"
	"strings"
)

// 型の表の行を、Flix のソースに書ける字にする（extract-function の引数・戻り・効果、extract-type-alias の欄の組の比べ）。
//
// 名前は修飾つき（fpkg の頭は外す）: どのファイルに書いても同じ物を指す。書けない型（型の変数・Other・開いた row）は ok=false。
// WhyNot: TypeText（報告用の字）と分けるのは、TypeText が Tuple(2)[…]・Record[…] のように読む人向けの形で、
// そのままソースに置けないため。

// FlixType は型 t の Flix の字。閉じた record は、欄の組が同じ型 alias が 1 つだけならその名前で書く
// （推論の型では alias が開かれるため。List[World] が List[{ 欄 100 個 }] にならないように）。
func (a *Ast) FlixType(t int32) (string, bool) { return a.flixType(t, 0, true) }

// rawFlixType は record を alias へ戻さずに書いた字（欄の組の比べの鍵）。
func (a *Ast) rawFlixType(t int32) (string, bool) { return a.flixType(t, 0, false) }

type fxMemo struct {
	text string
	ok   bool
}

func (a *Ast) flixType(t int32, depth int, pretty bool) (string, bool) {
	if t < 0 || int(t) >= len(a.tForm) || depth > 64 {
		return "", false
	}
	memo := a.fxRaw
	if pretty {
		memo = a.fxPretty
	}
	if m, ok := memo[t]; ok {
		return m.text, m.ok
	}
	text, ok := a.flixTypeNew(t, depth, pretty)
	if pretty {
		if a.fxPretty == nil {
			a.fxPretty = map[int32]fxMemo{}
		}
		a.fxPretty[t] = fxMemo{text, ok}
	} else {
		if a.fxRaw == nil {
			a.fxRaw = map[int32]fxMemo{}
		}
		a.fxRaw[t] = fxMemo{text, ok}
	}
	return text, ok
}

func (a *Ast) flixTypeNew(t int32, depth int, pretty bool) (string, bool) {
	head, args := a.applied(t)
	name := ""
	if nm := a.tName[head]; nm >= 0 {
		name = a.strs[nm]
	}
	list := func(xs []int32) ([]string, bool) {
		out := make([]string, len(xs))
		for i, x := range xs {
			s, ok := a.flixType(x, depth+1, pretty)
			if !ok {
				return nil, false
			}
			out[i] = s
		}
		return out, true
	}
	withArgs := func(n string, xs []int32) (string, bool) {
		parts, ok := list(xs)
		if !ok {
			return "", false
		}
		if len(parts) == 0 {
			return n, true
		}
		return n + "[" + strings.Join(parts, ", ") + "]", true
	}
	switch Forms[a.tForm[head]] {
	case "Alias":
		if len(args) > 0 {
			return "", false
		}
		return withArgs(displaySym(name), a.tArgList(head))
	case "Cst":
		switch {
		case strings.HasPrefix(name, "Tuple("):
			parts, ok := list(args)
			if !ok || len(parts) < 2 {
				return "", false
			}
			return "(" + strings.Join(parts, ", ") + ")", true
		case name == "Str":
			return withArgs("String", args)
		case name == "Pure" || name == "Univ" || name == "RecordRowEmpty" || name == "" || strings.ContainsAny(name, "()"):
			return "", false
		}
		return withArgs(displaySym(name), args)
	case "Record":
		if pretty {
			if n := a.aliasNameFor(t); n != "" {
				return n, true
			}
		}
		fields, ok := a.RecordFields(t)
		if !ok {
			return "", false
		}
		parts := make([]string, len(fields))
		for i, f := range fields {
			s, ok := a.flixType(f.Type, depth+1, pretty)
			if !ok {
				return "", false
			}
			parts[i] = f.Label + " = " + s
		}
		return "{ " + strings.Join(parts, ", ") + " }", true
	case "Arrow":
		// Arrow(n) に効果・引数（n-1）・戻りの順で当てた物。
		n, err := strconv.Atoi(name)
		if err != nil || len(args) != n+1 || n < 2 {
			return "", false
		}
		paramIDs, retID, effID := append([]int32{}, args[1:n]...), args[n], args[0]
		// resolved の段は (A, B) -> C を、効果を書いていない Arrow2 の入れ子（A -> B -> C）で持つ。Flix の関数は
		// 同じ型なので、効果の無い（NoEffect の）矢の戻りが矢なら 1 つの並びにまとめる。
		for a.isNoEffect(effID) {
			h, xs := a.applied(retID)
			m, err := strconv.Atoi(a.nameOf(h))
			if Forms[a.tForm[h]] != "Arrow" || err != nil || len(xs) != m+1 || m < 2 {
				break
			}
			paramIDs = append(paramIDs, xs[1:m]...)
			retID, effID = xs[m], xs[0]
		}
		params, ok := list(paramIDs)
		if !ok {
			return "", false
		}
		ret, ok := a.flixType(retID, depth+1, pretty)
		if !ok {
			return "", false
		}
		p := params[0]
		if len(params) > 1 || !isAtomicText(p) || strings.HasPrefix(p, "(") {
			p = "(" + strings.Join(params, ", ") + ")"
		}
		eff, pure, ok := a.FlixEffect(effID)
		if !ok {
			return "", false
		}
		if pure {
			return p + " -> " + ret, true
		}
		return p + " -> " + ret + " \\ " + eff, true
	}
	return "", false
}

// isNoEffect は効果を書いていない印（resolved の段の矢）か。
func (a *Ast) isNoEffect(t int32) bool {
	return t >= 0 && int(t) < len(a.tForm) && Forms[a.tForm[t]] == "Other" && a.nameOf(t) == "NoEffect"
}

func (a *Ast) nameOf(t int32) string {
	if nm := a.tName[t]; nm >= 0 {
		return a.strs[nm]
	}
	return ""
}

// FlixEffect は効果の型の字（Pure なら pure=true）。型の変数・読めない形は ok=false。
func (a *Ast) FlixEffect(t int32) (text string, pure bool, ok bool) {
	var names []string
	var walk func(t int32, depth int) bool
	walk = func(t int32, depth int) bool {
		if t < 0 || int(t) >= len(a.tForm) || depth > 64 {
			return false
		}
		for Forms[a.tForm[t]] == "Alias" {
			t = a.tExpands[t]
			if t < 0 {
				return false
			}
		}
		head, args := a.applied(t)
		name := ""
		if nm := a.tName[head]; nm >= 0 {
			name = a.strs[nm]
		}
		switch Forms[a.tForm[head]] {
		case "Cst":
			return name == "Pure" && len(args) == 0
		case "Effect":
			names = append(names, displaySym(name))
			return len(args) == 0
		case "EffUnion":
			if name != "Union" {
				return false
			}
			for _, x := range args {
				if !walk(x, depth+1) {
					return false
				}
			}
			return true
		case "Other":
			return name == "NoEffect"
		}
		return false
	}
	if !walk(t, 0) {
		return "", false, false
	}
	if len(names) == 0 {
		return "", true, true
	}
	sort.Strings(names)
	names = uniqStrings(names)
	if len(names) == 1 {
		return names[0], false, true
	}
	return "{" + strings.Join(names, ", ") + "}", false, true
}

func uniqStrings(xs []string) []string {
	var out []string
	for i, x := range xs {
		if i == 0 || x != xs[i-1] {
			out = append(out, x)
		}
	}
	return out
}

// RecordField は閉じた record の欄 1 つ。
type RecordField struct {
	Label string
	Type  int32
}

// RecordFields は閉じた record の型 t（alias は開かない）の欄（書かれた順）。record でないか開いた row なら ok=false。
func (a *Ast) RecordFields(t int32) ([]RecordField, bool) {
	head, args := a.applied(t)
	if Forms[a.tForm[head]] != "Record" || len(args) != 1 {
		return nil, false
	}
	var out []RecordField
	row := args[0]
	for depth := 0; depth < 4096; depth++ {
		h, xs := a.applied(row)
		switch {
		case Forms[a.tForm[h]] == "RecordRow" && len(xs) == 2 && a.tName[h] >= 0:
			out = append(out, RecordField{a.strs[a.tName[h]], xs[0]})
			row = xs[1]
			continue
		case Forms[a.tForm[h]] == "Cst" && a.tName[h] >= 0 && a.strs[a.tName[h]] == "RecordRowEmpty":
			return out, true
		}
		return nil, false
	}
	return nil, false
}

// RecordKey は閉じた record の型の「欄 = 型」の組（欄の名前の順・型は FlixType）。書けない型があれば ok=false。
func (a *Ast) RecordKey(t int32) (string, []string, bool) {
	fields, ok := a.RecordFields(t)
	if !ok {
		return "", nil, false
	}
	parts := make([]string, len(fields))
	labels := make([]string, len(fields))
	for i, f := range fields {
		s, ok := a.rawFlixType(f.Type)
		if !ok {
			return "", nil, false
		}
		parts[i] = f.Label + " = " + s
		labels[i] = f.Label
	}
	sort.Strings(parts)
	sort.Strings(labels)
	return "{ " + strings.Join(parts, ", ") + " }", labels, true
}

// aliasNameFor は閉じた record の型 t と同じ欄の組の型 alias が 1 つだけならその名前（無いか 2 つ以上なら ""）。
// 推論の型では alias が開かれるので、戻りの型・引数の型を書く時に名前へ戻す。
func (a *Ast) aliasNameFor(t int32) string {
	key, _, ok := a.RecordKey(t)
	if !ok {
		return ""
	}
	if a.aliasByKey == nil {
		a.aliasByKey = map[string]map[string]bool{}
		for i, f := range a.tForm {
			if Forms[f] != "Alias" || a.tName[i] < 0 || a.tExpands[i] < 0 || len(a.tArgList(int32(i))) > 0 {
				continue
			}
			if k, _, ok := a.RecordKey(a.tExpands[i]); ok {
				if a.aliasByKey[k] == nil {
					a.aliasByKey[k] = map[string]bool{}
				}
				a.aliasByKey[k][displaySym(a.strs[a.tName[i]])] = true
			}
		}
	}
	names := a.aliasByKey[key]
	if len(names) != 1 {
		return ""
	}
	for n := range names {
		return n
	}
	return ""
}

// typeTextMatches は書かれた型の字 written が、修飾つきの型の字 full と同じ型を指すか（名前は終わりで当てる・空白は問わない）。
func typeTextMatches(written, full string) bool {
	w, f := typeTokens(written), typeTokens(full)
	if len(w) != len(f) {
		return false
	}
	for i := range w {
		if w[i] == f[i] {
			continue
		}
		if !isTypeIdent(w[i]) || !isTypeIdent(f[i]) || !strings.HasSuffix(f[i], "."+w[i]) {
			return false
		}
	}
	return true
}

func isTypeIdent(s string) bool { return s != "" && isIdentRune([]rune(s)[0]) }

func typeTokens(s string) []string {
	var out []string
	rs := []rune(s)
	for i := 0; i < len(rs); {
		c := rs[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i++
		case isIdentRune(c):
			j := i
			for j < len(rs) && (isIdentRune(rs[j]) || rs[j] == '.') {
				j++
			}
			out = append(out, string(rs[i:j]))
			i = j
		default:
			if c == '-' && i+1 < len(rs) && rs[i+1] == '>' {
				out = append(out, "->")
				i += 2
				continue
			}
			out = append(out, string(c))
			i++
		}
	}
	return out
}
