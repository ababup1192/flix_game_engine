package refactor

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// remove-field・fix-construction: record の型（type alias の record・enum の case の record）の欄を 1 つ消す・足す時に、
// 型の宣言と、その record を組み立てている所（record の式 `{ a = …, x = …, … }`）を一緒に直す。
//
// 組み立てる所は欄の組で当てる: 閉じた record の式の欄の組が、型の欄の組（消す前・足す前の物）とちょうど同じ物。
// 型の別名（`type alias Model = World`）を通して組み立てる所も、欄の組は同じなので拾う。欄の組が同じ別の型が
// あれば、どちらを組み立てているか決められないので書き換えずに fix へ回す（設計 §5-1 の「閉じた row の一致」）。
//
// WhyNot: 組み立てる所を索引で引かないのは、flixlint の --spans（形の版 2）に record の式の行が無いため。
// 索引からは def の範囲（ext）と case の宣言の位置だけを使い、record の式は def の本体の中を字で読む。
// 当て外れ（欄の組が同じ無名の record）は確かめの口（make check）で止まって戻る。
//
// ここの関数は純粋（ファイルの中身は呼ぶ側が読んで渡す）。

// Shape は欄を直す record の型 1 つ（宣言の `{` から `}` まで）。
type Shape struct {
	Name   string   // 報告の名前（World・Panel.Open）
	File   string   // 宣言のあるファイル
	Brace  int      // 宣言の `{` の位置（File の中身のバイト）
	End    int      // `}` の次
	Fields []string // 宣言の欄の名前（書いた順）
}

// Has は欄 label が型にあるか。
func (s Shape) Has(label string) bool {
	for _, f := range s.Fields {
		if f == label {
			return true
		}
	}
	return false
}

func fieldKey(fields []string) string {
	c := append([]string{}, fields...)
	sort.Strings(c)
	return strings.Join(c, ",")
}

// shapeAt は src の pos（`{`）から閉じた record の型を読む。
func shapeAt(name, file, src string, pos int) (Shape, error) {
	u, closed, err := ParseRecord(src[pos:])
	if err != nil {
		return Shape{}, fmt.Errorf("%s の record の型が読めない: %v", name, err)
	}
	if !closed {
		return Shape{}, fmt.Errorf("%s は開いた record（`| r`）の型。欄の組で組み立てを当てられない", name)
	}
	s := Shape{Name: name, File: file, Brace: pos, End: pos + u.End}
	for _, f := range u.Fields {
		s.Fields = append(s.Fields, f.Name)
	}
	return s, nil
}

func aliasRe(short string) *regexp.Regexp {
	return regexp.MustCompile(`\btype\s+alias\s+` + regexp.QuoteMeta(short) + `(\[[^\]]*\])?\s*=\s*\{`)
}

// FindAliasShape は srcs の中から `type alias <alias の最後> = { … }` を 1 つ探す。同じ名前が 2 つ以上のファイルに
// あれば、alias の mod（`Rec.World` の Rec）を `mod Rec` で持つファイルに絞る。決まらなければ誤り。
func FindAliasShape(srcs map[string]string, alias string) (Shape, error) {
	short := alias[strings.LastIndex(alias, ".")+1:]
	re := aliasRe(short)
	var hits []Shape
	var files []string
	for f := range srcs {
		files = append(files, f)
	}
	sort.Strings(files)
	for _, f := range files {
		src := srcs[f]
		if !strings.Contains(src, "type alias "+short) {
			continue
		}
		for _, loc := range re.FindAllStringIndex(src, -1) {
			s, err := shapeAt(alias, f, src, loc[1]-1)
			if err != nil {
				return Shape{}, err
			}
			hits = append(hits, s)
		}
	}
	if len(hits) > 1 && strings.Contains(alias, ".") {
		mod := alias[:strings.LastIndex(alias, ".")]
		mod = mod[strings.LastIndex(mod, ".")+1:]
		var in []Shape
		for _, h := range hits {
			if regexp.MustCompile(`\bmod\s+` + regexp.QuoteMeta(mod) + `\b`).MatchString(srcs[h.File]) {
				in = append(in, h)
			}
		}
		hits = in
	}
	switch len(hits) {
	case 0:
		return Shape{}, fmt.Errorf("`type alias %s = { … }` が見つからない（record の alias の名前を --receiver に）", short)
	case 1:
		return hits[0], nil
	}
	var where []string
	for _, h := range hits {
		where = append(where, h.File)
	}
	return Shape{}, fmt.Errorf("`type alias %s` が %d か所にある（Mod.%s と mod を付けて）: %s", short, len(hits), short, strings.Join(where, "・"))
}

// FindCaseShape は case の宣言（索引の case-decl の行）の payload の record を読む。payload が record 1 つでなければ誤り。
func FindCaseShape(src string, row Row) (Shape, error) {
	_, e, err := ByteRange(src, row)
	if err != nil {
		return Shape{}, err
	}
	i := skipSpace(src, e)
	if i >= len(src) || src[i] != '(' {
		return Shape{}, fmt.Errorf("case %s に payload が無い", row.Sym)
	}
	j := skipBlank(src, i+1)
	if j >= len(src) || src[j] != '{' {
		return Shape{}, fmt.Errorf("case %s の payload が record でない（`case X({ … })` の形だけ）", row.Sym)
	}
	s, err := shapeAt(shortCase(row.Sym), row.File, src, j)
	if err != nil {
		return Shape{}, err
	}
	if k := skipBlank(src, s.End); k >= len(src) || src[k] != ')' {
		return Shape{}, fmt.Errorf("case %s の payload が record 1 つでない", row.Sym)
	}
	return s, nil
}

// shortCase は `Mod.Enum.Case` の `Enum.Case`。
func shortCase(sym string) string {
	p := strings.Split(sym, ".")
	if len(p) >= 2 {
		return p[len(p)-2] + "." + p[len(p)-1]
	}
	return sym
}

var caseRecordRe = regexp.MustCompile(`\bcase\s+[A-Z]\w*\s*\(\s*\{`)

// AllShapeKeys は srcs の閉じた record の型（record の alias と case の record の payload）の欄の組を数える
// （鍵 → 宣言の場所 file:byte）。欄の組が同じ別の型を見つけるため。
func AllShapeKeys(srcs map[string]string) map[string][]string {
	out := map[string][]string{}
	for f, src := range srcs {
		var starts []int
		for _, loc := range regexp.MustCompile(`\btype\s+alias\s+\w+(\[[^\]]*\])?\s*=\s*\{`).FindAllStringIndex(src, -1) {
			starts = append(starts, loc[1]-1)
		}
		for _, loc := range caseRecordRe.FindAllStringIndex(src, -1) {
			starts = append(starts, loc[1]-1)
		}
		for _, p := range starts {
			if s, err := shapeAt("", f, src, p); err == nil {
				k := fieldKey(s.Fields)
				out[k] = append(out[k], fmt.Sprintf("%s:%d", f, p))
			}
		}
	}
	return out
}

// Literal は def の本体の中の閉じた record の式 1 つ。
type Literal struct {
	Brace, End int
	Fields     []string
}

// ScanLiterals は src[from:to] の閉じた record の式を全部（入れ子の内側も）返す。文字列・字の字・コメントの中は読まない。
// 型の注記（`: { … }`）と集まりの式（`Set#{ … }`・`Map#{ … }`）の `{` は record の式に数えない。
func ScanLiterals(src string, from, to int) []Literal {
	var out []Literal
	for i := from; i < to; i++ {
		c := src[i]
		switch {
		case c == '"':
			j := i + 1
			for j < len(src) && src[j] != '"' {
				if src[j] == '\\' {
					j++
				}
				j++
			}
			i = j
		case c == '\'' && i+2 < len(src) && src[i+2] == '\'':
			i += 2
		case c == '\'' && i+3 < len(src) && src[i+1] == '\\' && src[i+3] == '\'':
			i += 3
		case c == '/' && i+1 < len(src) && src[i+1] == '/':
			for i < len(src) && src[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < len(src) && src[i+1] == '*':
			k := strings.Index(src[i+2:], "*/")
			if k < 0 {
				return out
			}
			i += k + 3
		case c == '{':
			p := i - 1
			for p >= from && (src[p] == ' ' || src[p] == '\t' || src[p] == '\n' || src[p] == '\r') {
				p--
			}
			if p >= from && src[p] == ':' {
				// 型の注記: 中も型なので閉じる所まで飛ばす。
				if _, at, err := scanTop(src, i+1, "}"); err == nil {
					i = at
				}
				continue
			}
			if p >= from && src[p] == '#' {
				continue
			}
			u, closed, err := ParseRecord(src[i:])
			if err != nil || !closed {
				continue
			}
			l := Literal{Brace: i, End: i + u.End}
			for _, f := range u.Fields {
				l.Fields = append(l.Fields, f.Name)
			}
			out = append(out, l)
		}
	}
	return out
}

// DefBodyStart は def の名前の終わり（nameEnd）から、本体の始まり（シグネチャの後の `=` の次）を探す。
func DefBodyStart(src string, nameEnd int) (int, bool) {
	stop, at, err := scanTop(src, nameEnd, "=")
	if err != nil || stop != '=' || at+1 >= len(src) || src[at+1] == '=' || src[at+1] == '>' {
		return 0, false
	}
	return at + 1, true
}

// codeEnd は欄 f の値の終わり（後ろの空白と、最後の行の `//` のコメントを除く）。
func codeEnd(text string, f Field) int {
	v := text[f.VStart:f.VEnd]
	for {
		t := strings.TrimRight(v, " \t\r\n")
		ls := strings.LastIndexByte(t, '\n') + 1
		if c := commentStart(t[ls:]); c >= 0 {
			v = t[:ls+c]
			continue
		}
		return f.VStart + len(t)
	}
}

// commentStart は 1 行の中の `//`（文字列の外）の位置。無ければ -1。
func commentStart(line string) int {
	in := false
	for i := 0; i+1 < len(line); i++ {
		switch {
		case line[i] == '\\' && in:
			i++
		case line[i] == '"':
			in = !in
		case !in && line[i] == '/' && line[i+1] == '/':
			return i
		}
	}
	return -1
}

func lineStart(text string, p int) int { return strings.LastIndexByte(text[:p], '\n') + 1 }

// RemoveRecordField は text（`{` で始まる record の式か型・更新）から欄 label を消した字を返す。
// 欄が自分の行にあれば、その行（と前に付いたコメントの行）ごと消す。最後の欄なら前の欄の `,` も消す。
func RemoveRecordField(text, label string) (string, error) {
	out, err := removeRecordField(text, label)
	if err != nil {
		return "", err
	}
	return noCommentFirst(text, out), nil
}

// noCommentFirst は、消した後の record が `{` の直後にコメントの行で始まる時（消す前は始まっていなかった時だけ）、
// そのコメントを次の欄の行の後ろへ移す。
// WhyNot: Flix 0.78 は record の型で `{` の直後のコメントを読めない（`{ // c` も同じ。「Expected ',' before '='」で止まる）。
// 最初の欄を消すと、次の欄の説明のコメントが先頭に来る。元から先頭にあるコメント（record の式の説明）は動かさない。
func noCommentFirst(before, after string) string {
	first := func(s string) int {
		i := strings.IndexByte(s, '{')
		if i < 0 {
			return -1
		}
		for j := i + 1; j < len(s); j++ {
			if c := s[j]; c != ' ' && c != '\t' && c != '\n' && c != '\r' {
				return j
			}
		}
		return -1
	}
	b, a := first(before), first(after)
	if a < 0 || !strings.HasPrefix(after[a:], "//") || (b >= 0 && strings.HasPrefix(before[b:], "//")) {
		return after
	}
	start := lineStart(after, a)
	if strings.TrimSpace(after[start:a]) != "" {
		start = a // `{ // c` の形: コメントだけを移す
	}
	var notes []string
	i := a
	for i < len(after) {
		end := strings.IndexByte(after[i:], '\n')
		if end < 0 {
			return after
		}
		line := strings.TrimSpace(after[i : i+end])
		if !strings.HasPrefix(line, "//") {
			break
		}
		notes = append(notes, line)
		i += end + 1
		for i < len(after) && (after[i] == ' ' || after[i] == '\t') {
			i++
		}
	}
	fieldLine := lineStart(after, i)
	end := strings.IndexByte(after[fieldLine:], '\n')
	if end < 0 {
		return after
	}
	end += fieldLine
	head := after[:start]
	if start == a {
		head = strings.TrimRight(head, " \t")
	}
	return head + after[fieldLine:end] + " " + strings.Join(notes, " ") + after[end:]
}

func removeRecordField(text, label string) (string, error) {
	u, _, err := ParseRecord(text)
	if err != nil {
		return "", err
	}
	k := u.Find(label)
	if k < 0 {
		return "", fmt.Errorf("欄 %s が無い", label)
	}
	if len(u.Fields) == 1 {
		return "", fmt.Errorf("欄が %s だけの record から消すと空になる（手で）", label)
	}
	f := u.Fields[k]
	last := k == len(u.Fields)-1
	ls := lineStart(text, f.Start)
	if strings.TrimSpace(text[ls:f.Start]) == "" && ls > 0 {
		start := ownLinesStart(text, u.Fields, k, ls)
		if !last {
			e := f.VEnd + 1
			// 行の残りが空か、この欄の後ろのコメントだけ: この行ごと消す（次の欄の前のコメントはその欄の物なので残す）。
			if nl := strings.IndexByte(text[e:], '\n'); nl >= 0 && (strings.TrimSpace(text[e:e+nl]) == "" || strings.HasPrefix(strings.TrimSpace(text[e:e+nl]), "//")) {
				return text[:start] + text[e+nl+1:], nil
			}
			// `x = 1, y = 2` で x が行の頭: 次の欄の頭まで消す。
			return text[:f.Start] + text[u.Fields[k+1].Start:], nil
		}
		ce := codeEnd(text, f)
		if nl := strings.IndexByte(text[ce:], '\n'); nl >= 0 && ce+nl < f.VEnd {
			// 閉じる `}`（か `|`）が下の行: この行を消し、前の欄の `,` も消す。
			prev := u.Fields[k-1]
			return text[:prev.VEnd] + text[prev.VEnd+1:start] + text[ce+nl+1:], nil
		}
	}
	if k == 0 {
		return text[:f.Start] + text[u.Fields[1].Start:], nil
	}
	return text[:codeEnd(text, u.Fields[k-1])] + text[codeEnd(text, f):], nil
}

// ownLinesStart は自分の行にある欄 k（行の頭 ls）を消す時に、一緒に消す行の頭。前に付いた `//` のコメントの行のうち、
// その欄だけの説明は含め、record 全体の説明（最初の欄の前）と、空行の後の見出し（下に続く欄の組にかかる物）は残す。
// 見出しの下の欄が k だけ（後ろが空行か閉じる `}`）なら k の説明と見て消し、前の空行も消す（空行が続かないように）。
// WhyNot: コメントの行を無条件に上へたどると、最初の欄を消した時に record の説明を、節の頭の欄を消した時に節の見出しを消していた。
func ownLinesStart(text string, fields []Field, k, ls int) int {
	start := ls
	for start > 0 {
		ps := lineStart(text, start-1)
		if t := strings.TrimSpace(text[ps : start-1]); strings.HasPrefix(t, "//") {
			start = ps
			continue
		}
		break
	}
	if start == ls {
		return ls
	}
	if k == 0 {
		return ls
	}
	above := lineStart(text, start-1)
	if strings.TrimSpace(text[above:start-1]) != "" {
		return start // 前の欄のすぐ下のコメントは k だけの説明
	}
	// 空行の後のコメント: k の後ろが空行か閉じる `}` なら節に k だけ。
	rest := text[codeEnd(text, fields[k]):]
	if nl := strings.IndexByte(rest, '\n'); nl >= 0 {
		next := rest[nl+1:]
		if e := strings.IndexByte(next, '\n'); e >= 0 {
			next = next[:e]
		}
		if t := strings.TrimSpace(next); t == "" || strings.HasPrefix(t, "}") || strings.HasPrefix(t, "|") {
			return above
		}
	}
	return ls
}

// AddRecordField は閉じた record の式 text の最後の欄の後に `label = value` を足した字を返す。
// 最後の欄が自分の行にあり、閉じる `}` が下の行なら、同じ字下げの新しい行に足す。
func AddRecordField(text, label, value string) (string, error) {
	u, closed, err := ParseRecord(text)
	if err != nil {
		return "", err
	}
	if !closed {
		return "", fmt.Errorf("閉じた record の式でない")
	}
	if u.Find(label) >= 0 {
		return "", fmt.Errorf("欄 %s はもうある", label)
	}
	l := u.Fields[len(u.Fields)-1]
	ce := codeEnd(text, l)
	ls := lineStart(text, l.Start)
	indent := text[ls:l.Start]
	if ls > 0 && strings.TrimSpace(indent) == "" && strings.Contains(text[ce:u.End], "\n") {
		return text[:ce] + ",\n" + indent + label + " = " + value + text[ce:], nil
	}
	return text[:ce] + ", " + label + " = " + value + text[ce:], nil
}

// InsertRecordField は閉じた record の式（か型）text の欄 after の次に `label = value` を足した字を返す。after が ""
// か最後の欄なら AddRecordField と同じ。欄が 1 つずつ自分の行にあれば、次の欄の行（前に付いたコメントの行も）の前に
// 同じ字下げの行を足し、そうでなければ同じ行に `, label = value` を足す。
func InsertRecordField(text, label, value, after string) (string, error) {
	u, closed, err := ParseRecord(text)
	if err != nil {
		return "", err
	}
	if !closed {
		return "", fmt.Errorf("閉じた record の式でない")
	}
	if u.Find(label) >= 0 {
		return "", fmt.Errorf("欄 %s はもうある", label)
	}
	if after == "" {
		return AddRecordField(text, label, value)
	}
	k := u.Find(after)
	if k < 0 {
		return "", fmt.Errorf("--after の欄 %s が無い", after)
	}
	if k == len(u.Fields)-1 {
		return AddRecordField(text, label, value)
	}
	next := u.Fields[k+1]
	ls := lineStart(text, next.Start)
	if indent := text[ls:next.Start]; ls > 0 && strings.TrimSpace(indent) == "" {
		start := ls
		for start > 0 {
			ps := lineStart(text, start-1)
			if t := strings.TrimSpace(text[ps : start-1]); strings.HasPrefix(t, "//") {
				start = ps
				continue
			}
			break
		}
		return text[:start] + indent + label + " = " + value + ",\n" + text[start:], nil
	}
	ce := codeEnd(text, u.Fields[k])
	return text[:ce] + ", " + label + " = " + value + text[ce:], nil
}

// ConstructionQuery は組み立てを直す問い。Add が空でなければ欄を足す（値は Value）、空なら Remove を消す。
type ConstructionQuery struct {
	Shape Shape
	Label string
	Add   bool
	Value string
	After string // 足す時: この欄の次に（"" は最後）
	// Pick は足す時、組み立ての所（def と record の式の `{` の位置）で Value の代わりに書く局所の名前（"" は Value のまま）。
	Pick   func(owner Row, at int) string
	Before string            // 直す前の組み立ての欄の組の鍵
	Others []string          // 欄の組が Before と同じ別の型の場所（あれば決めずに fix）
	Skip   map[string]bool   // file:line
	Defs   []Row             // 索引の def-decl（ext つき）
	Srcs   map[string]string // 根からの相対 → 中身
}

// ConstructionPlan は組み立てを直す計画。
type ConstructionPlan struct {
	Edits   []Edit
	Sites   []Fixed // 書き換える組み立て
	Fix     []Fixed
	Already int // もう直した後の欄の組の組み立て（数えるだけ）
}

// PlanConstruction は def の本体の中の、型 q.Shape を組み立てる record の式から欄を消す（足す）計画。
func PlanConstruction(q ConstructionQuery) (ConstructionPlan, error) {
	var p ConstructionPlan
	beforeFields := strings.Split(q.Before, ",")
	var afterFields []string
	if q.Add {
		afterFields = append(append(afterFields, beforeFields...), q.Label)
	} else {
		for _, f := range beforeFields {
			if f != q.Label {
				afterFields = append(afterFields, f)
			}
		}
	}
	afterKey := fieldKey(afterFields)
	err := eachLiteral(q.Defs, q.Srcs, func(d Row, src string, l Literal) {
		key := fieldKey(l.Fields)
		if key == afterKey {
			p.Already++
			return
		}
		if key != q.Before {
			return
		}
		row := rowAt(d.File, src, l.Brace, d.Sym)
		if q.Skip[fmt.Sprintf("%s:%d", d.File, row.Line)] {
			p.Fix = append(p.Fix, Fixed{row, "--skip で外した"})
			return
		}
		if len(q.Others) > 0 {
			p.Fix = append(p.Fix, Fixed{row, "欄の組が同じ別の型がある（" + strings.Join(q.Others, "・") + "）。どちらを組み立てているか決められない"})
			return
		}
		value := q.Value
		if q.Add && q.Pick != nil {
			if n := q.Pick(d, l.Brace); n != "" {
				value = n
			}
		}
		why := "組み立てから欄 " + q.Label + " を消す"
		if q.Add {
			why = "組み立てに欄 " + q.Label + " = " + value + " を足す"
		}
		p.Sites = append(p.Sites, Fixed{row, why})
		name := d.Sym[strings.LastIndex(d.Sym, ".")+1:]
		label, add, before, after := q.Label, q.Add, q.Before, q.After
		p.Edits = append(p.Edits, Edit{
			File: d.File, Start: l.Brace, End: l.End, Site: row,
			Check: []Want{{Span: d, Text: name}},
			Make: func(cur string) (string, error) {
				u, closed, err := ParseRecord(cur)
				if err != nil || !closed {
					return "", fmt.Errorf("組み立ての式が読めない: %v", err)
				}
				var names []string
				for _, f := range u.Fields {
					names = append(names, f.Name)
				}
				if fieldKey(names) != before {
					return "", fmt.Errorf("組み立ての欄の組が変わった（索引が古い）")
				}
				if add {
					return InsertRecordField(cur, label, value, after)
				}
				return RemoveRecordField(cur, label)
			},
		})
	})
	return p, err
}

// eachLiteral は rows の def-decl（ext つき）の本体の中の、閉じた record の式を def の位置の順に fn へ渡す。
// def の範囲が中身の外なら索引が古いので誤り。
func eachLiteral(rows []Row, srcs map[string]string, fn func(d Row, src string, l Literal)) error {
	var defs []Row
	for _, r := range rows {
		if r.Kind == KindDefDecl {
			defs = append(defs, r)
		}
	}
	sort.Slice(defs, func(i, j int) bool { return less(defs[i], defs[j]) })
	for _, d := range defs {
		src, ok := srcs[d.File]
		if !ok {
			continue
		}
		ext := d.Attr("ext")
		if ext == "" {
			continue
		}
		span, err := spanOf(d.File, ext)
		if err != nil {
			return err
		}
		_, extEnd, err := ByteRange(src, span)
		if err != nil {
			return fmt.Errorf("索引が古い: %s の def の範囲が中身の外（bin/fge refactor index --rebuild）", d.Where())
		}
		_, nameEnd, err := ByteRange(src, d)
		if err != nil {
			return fmt.Errorf("索引が古い: %s（bin/fge refactor index --rebuild）", d.Where())
		}
		body, ok := DefBodyStart(src, nameEnd)
		if !ok || body > extEnd {
			continue
		}
		for _, l := range ScanLiterals(src, body, extEnd) {
			fn(d, src, l)
		}
	}
	return nil
}

// rowAt は src の pos を報告の行（1 から・列は UTF-16）にする。
func rowAt(file, src string, pos int, owner string) Row {
	line := strings.Count(src[:pos], "\n") + 1
	ls := lineStart(src, pos)
	col := 1
	for _, r := range src[ls:pos] {
		col++
		if r > 0xFFFF {
			col++
		}
	}
	return Row{Kind: "record-literal", File: file, Line: line, Col: col, EndLine: line, EndCol: col + 1, Sym: "{", Owner: owner}
}
