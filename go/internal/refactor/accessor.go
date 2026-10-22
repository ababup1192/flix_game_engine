package refactor

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// field-to-accessor（段 2）: record の欄の直の読み `e#x` を読みの口 `R(e)` へ、書き `{ x = v | e }` を
// 書きの口（`--setter S` なら `S(v, e)`・`--mapper M` なら `M(x -> v', e)` か `M(_ -> v, e)`）へ替える。
// ほかの欄と一緒の書き `{ x = v, y = u | e }` は `{ y = u | S(v, e) }` にする（u は元の e を読むままなので意味は同じ）。
//
// 欄の当て方は索引（typed の label-select・label-update と受け手の alias）で、同じ名前の別の record の欄は当てない。
// 索引が指すのは欄の名前の字だけなので、受け手の式（`#` の前）と更新の中身（`{` から `}`）は字で読む。
// 読めない物（文字列を挟む括弧・受け手の型が決まらない物）は書き換えずに fix へ回す。
//
// ここの関数は純粋（ファイルの中身は呼ぶ側が読んで渡す）。

// AccessorName は口の名前を「置く mod」と「def の名前」に分けて持つ（`World.pointerShownOf` → World と pointerShownOf）。
// 書き換える所ごとに、その所の mod と use から書く形を決める（spellAt）。--getter 等に修飾つき・なしの
// どちらが来ても、ここへ来る前に 1 つの形に揃える（ops.go の accessorNameOf）。
type AccessorName struct {
	Mod  string // 口の def を置く mod（一番上なら ""）
	Name string // def の名前（修飾なし）
}

// Sym は索引の名前（`World.pointerShownOf`）。
func (n AccessorName) Sym() string {
	if n.Mod == "" {
		return n.Name
	}
	return n.Mod + "." + n.Name
}

// IsZero は口を渡していないか。
func (n AccessorName) IsZero() bool { return n.Name == "" }

// splitSym は索引の名前を AccessorName にする。
func splitSym(sym string) AccessorName { return AccessorName{Mod: modOf(sym), Name: shortName(sym)} }

// imports は use で取り込んだ名前（use を書いた mod か def と、取り込んだ物の名前 → その所で書く名前）。
// typed の段の索引に use の行が無ければ空で、外の所はいつも修飾つきになる（それでも通る）。
type imports map[[2]string]string

func importsOf(rows []Row) imports {
	im := imports{}
	for _, r := range rows {
		if r.Kind != KindUse {
			continue
		}
		as := r.Attr("alias")
		if as == "" {
			as = shortName(r.Sym)
		}
		im[[2]string{r.Owner, r.Sym}] = as
	}
	return im
}

// spellAt は def owner の中で口 n を呼ぶ時の字: 同じ mod なら素の名前、use で取り込んでいればその名前、
// ほかは mod の修飾つき（Flix は親の mod の名前も子の mod へは見せないので、mod は同じ時だけ素にする）。
func (im imports) spellAt(n AccessorName, owner string) string {
	if modOf(owner) == n.Mod {
		return n.Name
	}
	for _, scope := range []string{owner, modOf(owner)} {
		if as, ok := im[[2]string{scope, n.Sym()}]; ok {
			return as
		}
	}
	return n.Sym()
}

// AccessorQuery は field-to-accessor の問い。Reader・Mapper・Setter は口の名前（書く字は所ごとに spellAt で決める）、
// OwnerSyms は索引の名前（その def の中の直の読み書き＝口そのものは替えない）。
type AccessorQuery struct {
	Label     string
	Receiver  string
	Reader    AccessorName
	Mapper    AccessorName
	Setter    AccessorName
	OwnerSyms []string // 口の def（中の物は替えず数えない）
	Outside   string   // 空でなければ、この mod の中の物を替えない（数えない）
	Home      string   // 口の外を数える mod（Left の基準。空なら数えない）
	Skip      map[string]bool
	TypeWhy   string // 空でなければ口と欄の型が合わない訳（読みを全部 fix へ）
}

// AccessorPlan は field-to-accessor の計画。
type AccessorPlan struct {
	Edits    []Edit
	Fix      []Fixed
	Sites    int // 受け手が当たった直の読み書き（口の中・--outside の物を除く）
	Reads    int // 読みの口へ替える読み
	Writes   int // 書きの口へ替える書き
	Folded   int // 書きの lambda の引数に畳んだ読み（Reads に入る）
	Inside   int // 口の中・--outside の mod の中の物（替えない）
	Left     int // 当てた後も Home の外に残る直の読み書き（替えられず fix へ回した物）
	Unsure   int // 受け手の型が決まらない物（数えず fix へ。Left には入れない）
	Rewrites []Fixed
}

// keywords は受け手の式の名前として読まない語（`if(c)#x` の if は呼び出しではない）。
var keywords = map[string]bool{"if": true, "else": true, "not": true, "and": true, "or": true, "match": true, "case": true, "let": true, "then": true, "def": true, "yield": true, "forM": true, "foreach": true}

func identByte(c byte) bool {
	return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// receiverStart は読み s（`e#x`）の受け手の式 e の始まりのバイト。範囲は索引の rspan（コンパイラの位置）で、括弧で
// 包んだ式（`(f(x))#y`）の位置は括弧を含まないので、終わりが `#`（位置 hash）に届くまで外側の括弧を広げる。
func receiverStart(src string, s FieldSite, hash int) (int, bool) {
	if s.RSpan == "" {
		return 0, false
	}
	sp, err := spanOf(s.File, s.RSpan)
	if err != nil {
		return 0, false
	}
	st, en, err := ByteRange(src, sp)
	if err != nil {
		return 0, false
	}
	for en < hash && st > 0 && src[st-1] == '(' && src[en] == ')' {
		st, en = st-1, en+1
	}
	return st, en == hash
}

// Field は更新の 1 欄（位置は渡した字の中のバイト）。
type Field struct {
	Name         string
	Start        int // 名前の始まり
	VStart, VEnd int // 値（前後の空白を含む）
}

// Update は `{ a = v, b = u | e }` を読んだ物。
type Update struct {
	Fields       []Field
	EStart, EEnd int // e（前後の空白を含む）
	End          int // `}` の次
}

// Find は欄 label の番号（無ければ -1）。
func (u Update) Find(label string) int {
	for i, f := range u.Fields {
		if f.Name == label {
			return i
		}
	}
	return -1
}

// ParseUpdate は text（`{` で始まる）を `{ a = v, b = u | e }` として読む。受け手の無い record の式・`+a`（欄を足す）・
// 読めない字は誤り（訳つき）。値と e の中の括弧・文字列・字の字・行のコメントは飛ばす。`|>`・`||` は区切りに取らない。
func ParseUpdate(text string) (Update, error) {
	u, closed, err := ParseRecord(text)
	if err == nil && closed {
		return u, fmt.Errorf("受け手の無い record の式")
	}
	return u, err
}

// ParseRecord は text（`{` で始まる）を欄の並び `{ a = v, b = u }`（closed）か `{ a = v | e }` として読む。
// record の式・record の型（`{ a = Int32 }`）のどちらも同じ形で読める。欄の前のコメントは飛ばす。
// closed の時の EStart・EEnd は -1。
func ParseRecord(text string) (Update, bool, error) {
	var u Update
	if !strings.HasPrefix(text, "{") {
		return u, false, fmt.Errorf("`{` で始まらない")
	}
	i := skipBlank(text, 1)
	for {
		j := i
		for j < len(text) && identByte(text[j]) {
			j++
		}
		if j == i {
			return u, false, fmt.Errorf("欄の名前が読めない（`+a`・`-a` の更新か record の式でない）")
		}
		f := Field{Name: text[i:j], Start: i}
		i = skipSpace(text, j)
		if i >= len(text) || text[i] != '=' || (i+1 < len(text) && (text[i+1] == '=' || text[i+1] == '>')) {
			return u, false, fmt.Errorf("欄 %s の後に = が無い", f.Name)
		}
		f.VStart = i + 1
		stop, at, err := scanTop(text, f.VStart, ",|}")
		if err != nil {
			return u, false, err
		}
		f.VEnd = at
		u.Fields = append(u.Fields, f)
		if stop == '}' {
			u.EStart, u.EEnd, u.End = -1, -1, at+1
			return u, true, nil
		}
		if stop == '|' {
			u.EStart = at + 1
			break
		}
		i = skipBlank(text, at+1)
	}
	_, at, err := scanTop(text, u.EStart, "}")
	if err != nil {
		return u, false, err
	}
	u.EEnd, u.End = at, at+1
	return u, false, nil
}

// skipBlank は空白と行のコメント（`// …`）・塊のコメント（`/* … */`）を飛ばす。
func skipBlank(s string, i int) int {
	for {
		i = skipSpace(s, i)
		switch {
		case strings.HasPrefix(s[i:], "//"):
			for i < len(s) && s[i] != '\n' {
				i++
			}
		case strings.HasPrefix(s[i:], "/*"):
			k := strings.Index(s[i+2:], "*/")
			if k < 0 {
				return len(s)
			}
			i += k + 4
		default:
			return i
		}
	}
}

// RewriteUpdate は cur（`{ … | e }`）から欄 label を外し、受け手 e を wrap(v, e) で包んだ字を返す（v は外した欄の値）。
// 欄が label だけなら wrap(v, e) そのもの。ほかの欄の値は元の e を読むままなので、意味は変わらない。
func RewriteUpdate(cur, label string, wrap func(v, e string) string) (string, error) {
	u, err := ParseUpdate(cur)
	if err != nil {
		return "", err
	}
	k := u.Find(label)
	if k < 0 {
		return "", fmt.Errorf("更新に欄 %s が無い", label)
	}
	f := u.Fields[k]
	eRaw := cur[u.EStart:u.EEnd]
	w := wrap(strings.TrimSpace(cur[f.VStart:f.VEnd]), strings.TrimSpace(eRaw))
	if len(u.Fields) == 1 {
		return w, nil
	}
	lead := len(eRaw) - len(strings.TrimLeft(eRaw, " \t\r\n"))
	trail := len(eRaw) - len(strings.TrimRight(eRaw, " \t\r\n"))
	out := cur[:u.EStart] + eRaw[:lead] + w + eRaw[len(eRaw)-trail:] + cur[u.EEnd:]
	valueEnd := func(g Field) int { return g.VStart + len(strings.TrimRight(cur[g.VStart:g.VEnd], " \t\r\n")) }
	if k == 0 {
		return out[:f.Start] + out[u.Fields[1].Start:], nil
	}
	return out[:valueEnd(u.Fields[k-1])] + out[valueEnd(f):], nil
}

// enclosingOpen は pos を囲む一番内側の開き括弧の位置（`{` でなければ・文字列を挟めば false）。
func enclosingOpen(src string, pos int) (int, bool) {
	depth := 0
	for i := pos - 1; i >= 0; i-- {
		switch src[i] {
		case ')', ']', '}':
			depth++
		case '(', '[', '{':
			if depth == 0 {
				return i, src[i] == '{'
			}
			depth--
		case '"', '\'':
			return 0, false
		}
	}
	return 0, false
}

func skipSpace(s string, i int) int {
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i++
	}
	return i
}

// scanTop は text[i:] を括弧の深さ 0 の stops のどれかまで読む（止まった字と位置）。
func scanTop(text string, i int, stops string) (byte, int, error) {
	closer := map[byte]byte{'(': ')', '[': ']', '{': '}'}
	var stack []byte
	for i < len(text) {
		c := text[i]
		switch {
		case c == '"':
			j := i + 1
			for j < len(text) && text[j] != '"' {
				if text[j] == '\\' {
					j++
				}
				j++
			}
			if j >= len(text) {
				return 0, 0, fmt.Errorf("閉じない文字列")
			}
			i = j + 1
			continue
		case c == '\'' && i+2 < len(text) && text[i+2] == '\'':
			i += 3
			continue
		case c == '\'' && i+3 < len(text) && text[i+1] == '\\' && text[i+3] == '\'':
			i += 4
			continue
		case c == '/' && i+1 < len(text) && text[i+1] == '/':
			for i < len(text) && text[i] != '\n' {
				i++
			}
			continue
		case len(stack) == 0 && strings.IndexByte(stops, c) >= 0:
			if c == '|' && i+1 < len(text) && (text[i+1] == '>' || text[i+1] == '|') {
				i += 2
				continue
			}
			return c, i, nil
		case c == '(' || c == '[' || c == '{':
			stack = append(stack, closer[c])
		case c == ')' || c == ']' || c == '}':
			if len(stack) == 0 || stack[len(stack)-1] != c {
				return 0, 0, fmt.Errorf("括弧が合わない")
			}
			stack = stack[:len(stack)-1]
		}
		i++
	}
	return 0, 0, fmt.Errorf("終わりの %q が見つからない", stops)
}

var binders = regexp.MustCompile(`->|\blet\b|\bmatch\b|\bcase\b|\bdef\b|\bforM\b|\bforeach\b`)

// usesName は text が name を、選択（`#name`）・修飾（`.name`）の外の名前として使うか。
func usesName(text, name string) bool {
	re := regexp.MustCompile(`(^|[^#.\w])` + regexp.QuoteMeta(name) + `\b`)
	return re.MatchString(text)
}

type readSite struct {
	row        Row
	start, end int // 受け手の始まり〜欄の名前の終わり
	recv       string
}

type updateSite struct {
	row        Row
	brace, end int
	field      Field // 替える欄（位置は brace から）
	multi      bool  // ほかの欄と一緒の更新
	recv       string
	folded     []int // 畳む読み（reads の番号）
}

// PlanAccessor は欄 q.Label の直の読み書きを口へ替える計画。srcs は索引の欄の行があるファイルの中身。
func PlanAccessor(srcs map[string]string, rows []Row, q AccessorQuery) (AccessorPlan, error) {
	var p AccessorPlan
	owners := map[string]bool{}
	for _, o := range q.OwnerSyms {
		owners[o] = true
	}
	ans := FieldSites(rows, FieldQuery{Label: q.Label, Receiver: q.Receiver, Outside: q.Outside, Op: "field-to-accessor"})
	p.Inside = ans.Inside
	p.Unsure = len(ans.Unsure)
	for _, s := range ans.Unsure {
		p.Fix = append(p.Fix, Fixed{s.Row, fmt.Sprintf("受け手が証明できない（owner=%s why=%s）", s.OwnerText(), s.Why)})
	}
	im := importsOf(rows)
	// leave は替えられずに残す所（Home の外なら Left に数える）。
	leave := func(r Row, why string) {
		p.Fix = append(p.Fix, Fixed{r, why})
		if q.Home == "" || !inMod(r.Owner, q.Home) {
			p.Left++
		}
	}
	var reads []readSite
	var updates []updateSite
	for _, s := range ans.Sites {
		if owners[s.Owner] {
			p.Inside++
			continue
		}
		p.Sites++
		src, ok := srcs[s.File]
		if !ok {
			return p, fmt.Errorf("%s の中身が渡されていない", s.File)
		}
		if q.Skip[s.File+":"+fmt.Sprint(s.Line)] {
			leave(s.Row, "--skip で外した")
			continue
		}
		ls, le, err := ByteRange(src, s.Row)
		if err != nil || src[ls:le] != q.Label {
			return p, fmt.Errorf("索引が古い: %s の字が %s でない。bin/fge refactor index --stage typed --rebuild の後にやり直す", s.Where(), q.Label)
		}
		if !s.Write {
			if ls == 0 || src[ls-1] != '#' {
				leave(s.Row, "欄の前が # でない（読めない書き方）")
				continue
			}
			if q.TypeWhy != "" {
				leave(s.Row, q.TypeWhy)
				continue
			}
			st, ok := receiverStart(src, s, ls-1)
			if !ok {
				leave(s.Row, "受け手の式の範囲が # の前と合わない（索引の rspan）")
				continue
			}
			reads = append(reads, readSite{row: s.Row, start: st, end: le, recv: src[st : ls-1]})
			continue
		}
		if q.Mapper.IsZero() && q.Setter.IsZero() {
			leave(s.Row, "書きの口が無い（--setter か --mapper を渡す）")
			continue
		}
		b, ok := enclosingOpen(src, ls)
		if !ok {
			leave(s.Row, "更新の `{` が読めない（前の欄の値に文字列がある・括弧が合わない）")
			continue
		}
		u, err := ParseUpdate(src[b:])
		if err != nil {
			leave(s.Row, err.Error())
			continue
		}
		k := u.Find(q.Label)
		if k < 0 || b+u.Fields[k].Start != ls {
			leave(s.Row, "更新の欄の位置が索引と合わない")
			continue
		}
		updates = append(updates, updateSite{row: s.Row, brace: b, end: b + u.End, field: u.Fields[k], multi: len(u.Fields) > 1,
			recv: strings.TrimSpace(src[b+u.EStart : b+u.EEnd])})
	}
	// 書きの v が同じ受け手（名前）の欄を読むなら、mapper の lambda の引数に畳む（v が名前を束ねず、欄の名前を別に使わない時だけ）。
	folded := map[int]bool{}
	for k := range updates {
		up := &updates[k]
		if q.Mapper.IsZero() || !isIdent(up.recv) {
			continue
		}
		src := srcs[up.row.File]
		vs, ve := up.brace+up.field.VStart, up.brace+up.field.VEnd
		v := src[vs:ve]
		var mine []int
		for i, r := range reads {
			if r.row.File == up.row.File && r.start >= vs && r.end <= ve && r.recv == up.recv {
				mine = append(mine, i)
			}
		}
		if len(mine) == 0 || binders.MatchString(v) {
			continue
		}
		rest := v
		for j := len(mine) - 1; j >= 0; j-- {
			r := reads[mine[j]]
			rest = rest[:r.start-vs] + rest[r.end-vs:]
		}
		if usesName(rest, q.Label) {
			continue
		}
		up.folded = mine
		for _, i := range mine {
			folded[i] = true
		}
	}
	for i, r := range reads {
		r := r
		label, reader := q.Label, im.spellAt(q.Reader, r.row.Owner)
		into := reader + "(…)"
		if folded[i] {
			into = label + "（書きの lambda の引数）"
			p.Folded++
		}
		p.Reads++
		p.Rewrites = append(p.Rewrites, Fixed{r.row, "読み → " + into})
		fold := folded[i]
		p.Edits = append(p.Edits, Edit{
			File: r.row.File, Start: r.start, End: r.end, Site: r.row,
			Check: []Want{{Span: r.row, Text: label}},
			Make: func(cur string) (string, error) {
				if !strings.HasSuffix(cur, "#"+label) {
					return "", fmt.Errorf("読みの終わりが #%s でない", label)
				}
				if fold {
					return label, nil
				}
				return reader + "(" + cur[:len(cur)-len(label)-1] + ")", nil
			},
		})
	}
	for _, up := range updates {
		up := up
		label := q.Label
		setter, mapper := "", ""
		if !q.Setter.IsZero() {
			setter = im.spellAt(q.Setter, up.row.Owner)
		}
		if !q.Mapper.IsZero() {
			mapper = im.spellAt(q.Mapper, up.row.Owner)
		}
		var form string
		switch {
		case len(up.folded) > 0:
			form = mapper + "(" + label + " -> …, e)"
		case setter != "":
			form = setter + "(v, e)"
		default:
			form = mapper + "(_ -> v, e)"
		}
		if up.multi {
			form = "{ ほかの欄 | " + form + " }"
		}
		p.Writes++
		p.Rewrites = append(p.Rewrites, Fixed{up.row, "書き → " + form})
		fold := len(up.folded) > 0
		p.Edits = append(p.Edits, Edit{
			File: up.row.File, Start: up.brace, End: up.end, Site: up.row,
			Check: []Want{{Span: up.row, Text: label}},
			Make: func(cur string) (string, error) {
				return RewriteUpdate(cur, label, func(v, e string) string {
					switch {
					case fold:
						return mapper + "(" + label + " -> " + v + ", " + e + ")"
					case setter != "":
						return setter + "(" + v + ", " + e + ")"
					}
					return mapper + "(_ -> " + v + ", " + e + ")"
				})
			},
		})
	}
	sort.Slice(p.Fix, func(i, j int) bool { return less(p.Fix[i].Row, p.Fix[j].Row) })
	sort.Slice(p.Rewrites, func(i, j int) bool { return less(p.Rewrites[i].Row, p.Rewrites[j].Row) })
	return p, nil
}

func isIdent(s string) bool {
	if s == "" || keywords[s] || !(s[0] == '_' || s[0] >= 'a' && s[0] <= 'z' || s[0] >= 'A' && s[0] <= 'Z') {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !identByte(s[i]) {
			return false
		}
	}
	return true
}

// AliasFieldType は src の `type alias <alias> = { … }` の欄 label の型の字（空白を 1 つに）。無ければ false。
func AliasFieldType(src, alias, label string) (string, bool) {
	re := regexp.MustCompile(`type\s+alias\s+` + regexp.QuoteMeta(alias) + `\s*=\s*\{`)
	loc := re.FindStringIndex(src)
	if loc == nil {
		return "", false
	}
	body := src[loc[1]-1:]
	_, end, err := scanTop(body, 1, "}")
	if err != nil {
		return "", false
	}
	inner := stripLineComments(body[1:end])
	for {
		stop, at, err := scanTop(inner+",", 0, ",")
		if err != nil || stop != ',' {
			return "", false
		}
		field := inner[:min(at, len(inner))]
		if name, typ, ok := strings.Cut(field, "="); ok && strings.TrimSpace(name) == label {
			return normType(typ), true
		}
		if at >= len(inner) {
			return "", false
		}
		inner = inner[at+1:]
	}
}

// DefReturnType は def の全文（`///`・注記を含んでよい）の戻りの型の字（effect の `\ …` は除く・空白を 1 つに）。
func DefReturnType(def string) (string, bool) {
	i := strings.Index(def, "def ")
	if i < 0 {
		return "", false
	}
	open := strings.IndexByte(def[i:], '(')
	if open < 0 {
		return "", false
	}
	open += i
	stop, at, err := scanTop(def, open+1, ")")
	if err != nil || stop != ')' {
		return "", false
	}
	j := skipSpace(def, at+1)
	if j >= len(def) || def[j] != ':' {
		return "", false
	}
	_, end, err := scanTop(def, j+1, `=\`)
	if err != nil {
		return "", false
	}
	return normType(def[j+1 : end]), true
}

func stripLineComments(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		if k := strings.Index(l, "//"); k >= 0 {
			lines[i] = l[:k]
		}
	}
	return strings.Join(lines, "\n")
}

func normType(s string) string { return strings.Join(strings.Fields(s), " ") }

var qualifiers = regexp.MustCompile(`\b[A-Z]\w*\.`)

// SameType は 2 つの型の字が同じか（mod の修飾 `World.Phase` と素の `Phase` は同じと見る）。
func SameType(a, b string) bool {
	return a == b || qualifiers.ReplaceAllString(a, "") == qualifiers.ReplaceAllString(b, "")
}
