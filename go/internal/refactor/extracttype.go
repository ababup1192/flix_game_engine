package refactor

import (
	"fmt"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// extract-type-alias: 閉じた record の型（`{ a = A, b = B }`）に名前を付けて `type alias` を置き、同じ欄の組の型を書いた所を
// すべてその名前へ置き換える（設計 §13）。
//
// 当たりは汎用の AST（resolved で足りる）の、型を書く欄（引数・戻り・enum の case・type alias。lint の record-type-twice と
// 同じ所）の型の中の閉じた record を「欄 = 型」の組（欄の順は問わない・型は修飾つきの名前）で比べて決める。書き替える字は、
// その宣言の型の所（def の本体とコメントの外）の `{ … }` を欄の組で探して当てる（AST の型は位置を持たないため）。
// ゲーム・ファイルの名前は持たない。

// TypeAliasQuery は extract-type-alias の問い。
type TypeAliasQuery struct {
	Name string          // Mod.Name
	From string          // `{ a = A, b = B }`（無ければ At）
	At   string          // file:line
	Doc  string          // 置く alias の /// の 1 行（無ければ書かない）
	Skip map[string]bool // file:line
}

// TypeAliasPlan は extract-type-alias の計画。
type TypeAliasPlan struct {
	Key      string // 目当ての欄の組（修飾つき）
	Decl     string // 置く宣言（もうある alias を使う時は ""）
	DeclRow  Row
	Pub      bool
	Reused   bool
	Edits    []Edit
	Sites    []Fixed
	Fix      []Fixed
	Excluded int // 同じ欄の名前の組で、型が違う record（数えるだけ）
}

// writtenRecord はソースに書かれた閉じた record の型 1 つ。
type writtenRecord struct {
	row        Row
	start, end int
	root       int32
	key        string
	labels     []string // 書かれた順
	fields     map[string]string
	aliasBody  string // 宣言の右がちょうどこの record の type alias の名前（無ければ ""）
	ownerMod   string
}

// astRecord は宣言の型の中の閉じた record（汎用の AST から）。
type astRecord struct {
	key    string
	sorted []string          // 欄の名前（名前の順）
	fields map[string]string // 欄 → 修飾つきの型の字
	order  []string          // 欄の書かれた順
}

// typePlaces は型を書く欄（record-type-twice と同じ所）: 節の種類と型の葉。
var typePlaces = []struct{ kind, attr string }{{"FormalParam", "tpe"}, {"Spec", "tpe"}, {"Case", "tpes"}, {"TypeAlias", "tpe"}}

// astRecordsByRoot は宣言ごとの、型を書く欄の型の中の閉じた record（欄 2 つ以上）。
func astRecordsByRoot(a *Ast) map[int32][]astRecord {
	out := map[int32][]astRecord{}
	for _, p := range typePlaces {
		for _, n := range a.OfKind(p.kind) {
			if s, _ := a.Attr(n, "src"); s == "Inferred" {
				continue
			}
			for _, t := range a.AttrTypes(n, p.attr) {
				for _, r := range a.recordsIn(t, 0) {
					out[a.Root[n]] = append(out[a.Root[n]], r)
				}
			}
		}
	}
	return out
}

// recordsIn は型 t の中に書かれた閉じた record（alias の開いた先には入らない）。
func (a *Ast) recordsIn(t int32, depth int) []astRecord {
	if t < 0 || int(t) >= len(a.tForm) || depth > 64 {
		return nil
	}
	var out []astRecord
	head, args := a.applied(t)
	if Forms[a.tForm[head]] == "Record" {
		if fields, ok := a.RecordFields(t); ok && len(fields) >= 2 {
			if key, sorted, ok := a.RecordKey(t); ok {
				r := astRecord{key: key, sorted: sorted, fields: map[string]string{}}
				for _, f := range fields {
					s, _ := a.rawFlixType(f.Type)
					r.fields[f.Label] = s
					r.order = append(r.order, f.Label)
				}
				out = append(out, r)
			}
			for _, f := range fields {
				out = append(out, a.recordsIn(f.Type, depth+1)...)
			}
		}
		return out
	}
	kids := args
	if Forms[a.tForm[head]] == "Alias" {
		kids = a.tArgList(head)
	}
	for _, x := range kids {
		out = append(out, a.recordsIn(x, depth+1)...)
	}
	return out
}

var recordLabelRe = regexp.MustCompile(`^[a-z_][A-Za-z0-9_]*$`)

// parseRecordType は `{ a = A, b = B }` の中身を欄の並びと型の字にする（閉じた record の型でなければ ok=false）。
func parseRecordType(text string) (labels []string, types map[string]string, ok bool) {
	text = strings.TrimSpace(text)
	if !strings.HasPrefix(text, "{") || !strings.HasSuffix(text, "}") {
		return nil, nil, false
	}
	inner := strings.TrimSpace(text[1 : len(text)-1])
	if inner == "" {
		return nil, nil, false
	}
	types = map[string]string{}
	for _, part := range splitTopLevel(inner, ',') {
		if strings.ContainsRune(stripNested(part), '|') {
			return nil, nil, false
		}
		l, t, found := strings.Cut(part, "=")
		l, t = strings.TrimSpace(l), strings.TrimSpace(t)
		if !found || !recordLabelRe.MatchString(l) || t == "" || strings.HasPrefix(t, ">") {
			return nil, nil, false
		}
		if _, dup := types[l]; dup {
			return nil, nil, false
		}
		labels = append(labels, l)
		types[l] = t
	}
	return labels, types, true
}

// stripNested は括弧の中を消した字（深さ 0 の字だけ）。
func stripNested(s string) string {
	var b strings.Builder
	depth := 0
	for _, c := range s {
		switch c {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		default:
			if depth == 0 {
				b.WriteRune(c)
			}
		}
	}
	return b.String()
}

// sameLabels は 2 つの欄の並びが（順を問わず）同じか。
func sameLabels(written []string, sorted []string) bool {
	if len(written) != len(sorted) {
		return false
	}
	w := append([]string{}, written...)
	sort.Strings(w)
	for i := range w {
		if w[i] != sorted[i] {
			return false
		}
	}
	return true
}

// matchRecord は書かれた欄の組が AST の record r と同じ型か。
func matchRecord(labels []string, types map[string]string, r astRecord) bool {
	if !sameLabels(labels, r.sorted) {
		return false
	}
	for _, l := range labels {
		if !typeTextMatches(types[l], r.fields[l]) {
			return false
		}
	}
	return true
}

// declTypeRegion は宣言 root の型を書く所のバイトの範囲（def は本体の前まで）。
func declTypeRegion(a *Ast, src string, root int32) (int, int, bool) {
	s, e, err := ByteRange(src, a.SpanOf(root))
	if err != nil || s >= e {
		return 0, 0, false
	}
	if a.KindOf(root) == "Def" {
		if body := a.Child(root, "exp"); body >= 0 {
			if bs, _, err := ByteRange(src, a.SpanOf(body)); err == nil && bs > s && bs <= e {
				e = bs
			}
		}
	}
	return s, e, true
}

// writtenRecords はソースに書かれた閉じた record の型（宣言の型の所だけ）を、AST の record と突き合わせて集める。
func writtenRecords(a *Ast, srcs *reshapeSources) []writtenRecord {
	byRoot := astRecordsByRoot(a)
	roots := make([]int32, 0, len(byRoot))
	for r := range byRoot {
		roots = append(roots, r)
	}
	sort.Slice(roots, func(i, j int) bool { return roots[i] < roots[j] })
	var out []writtenRecord
	seen := map[string]bool{}
	for _, root := range roots {
		file := a.File(root)
		src, err := srcs.get(file)
		if err != nil {
			continue
		}
		s, e, ok := declTypeRegion(a, src, root)
		if !ok {
			continue
		}
		owner := a.RootName(root)
		for _, br := range bracePairs(src, s, e) {
			text := src[br[0]:br[1]]
			labels, types, ok := parseRecordType(text)
			if !ok || len(labels) < 2 {
				continue
			}
			var hit *astRecord
			for i := range byRoot[root] {
				if matchRecord(labels, types, byRoot[root][i]) {
					hit = &byRoot[root][i]
					break
				}
			}
			id := fmt.Sprintf("%s:%d", file, br[0])
			if hit == nil || seen[id] {
				continue
			}
			seen[id] = true
			w := writtenRecord{row: rowAt(file, src, br[0], owner), start: br[0], end: br[1], root: root, key: hit.key,
				labels: labels, fields: hit.fields, ownerMod: modOf(owner)}
			w.row.Kind = "record-type"
			if a.KindOf(root) == "TypeAlias" {
				if _, rhs, found := strings.Cut(src[s:e], "="); found && strings.TrimSpace(rhs) == text {
					w.aliasBody = displaySym(owner)
				}
			}
			out = append(out, w)
		}
	}
	sort.Slice(out, func(i, j int) bool { return less(out[i].row, out[j].row) })
	return out
}

// bracePairs は src[s:e] の中の `{ … }` の組（文字列・コメントの外。入れ子も 1 つずつ）。
func bracePairs(src string, s, e int) [][2]int {
	var out [][2]int
	for i := s; i < e; i++ {
		c := src[i]
		switch {
		case c == '"':
			j := i + 1
			for j < e && src[j] != '"' {
				if src[j] == '\\' {
					j++
				}
				j++
			}
			i = j
		case c == '/' && i+1 < e && src[i+1] == '/':
			for i < e && src[i] != '\n' {
				i++
			}
		case c == '{':
			if _, close, err := scanTop(src[:e], i+1, "}"); err == nil {
				out = append(out, [2]int{i, close + 1})
			}
		}
	}
	return out
}

// PlanTypeAlias は extract-type-alias の計画を作る。
func PlanTypeAlias(a *Ast, srcs *reshapeSources, q TypeAliasQuery) (*TypeAliasPlan, error) {
	mod, short := modOf(q.Name), shortName(q.Name)
	if mod == "" || short == "" || !unicodeUpper(short) {
		return nil, fmt.Errorf("--name は Mod.Name の形（名前は大文字で始める）: %q", q.Name)
	}
	written := writtenRecords(a, srcs)
	key, err := targetKey(a, written, q)
	if err != nil {
		return nil, err
	}
	plan := &TypeAliasPlan{Key: key}
	// もうある alias（同じ名前）: 同じ組なら使い、違えば止める。
	for _, n := range a.OfKind("TypeAlias") {
		if displaySym(a.RootName(n)) != q.Name {
			continue
		}
		var k string
		for _, t := range a.AttrTypes(n, "tpe") {
			k, _, _ = a.RecordKey(t)
		}
		if k != key {
			return nil, fmt.Errorf("型 alias %s はもうあり、欄の組が違う（%s）。別の名前を --name に", q.Name, orDash(k))
		}
		plan.Reused = true
	}
	for _, kind := range []string{"Enum", "Def"} {
		for _, n := range a.OfKind(kind) {
			if a.Parent[n] < 0 && displaySym(a.RootName(n)) == q.Name {
				return nil, fmt.Errorf("%s はもう %s の名前（別の名前を --name に）", q.Name, strings.ToLower(kind))
			}
		}
	}
	var first *writtenRecord
	for i := range written {
		w := &written[i]
		if w.key != key {
			continue
		}
		if q.Skip[fmt.Sprintf("%s:%d", w.row.File, w.row.Line)] {
			continue
		}
		if w.aliasBody != "" {
			switch {
			case w.aliasBody == q.Name:
				continue // 名前の alias そのもの
			case !plan.Reused:
				// 新しい名前を足すと同じ組の名前が 2 つになる。もうある名前を使うかは人（--name にその名前）。
				plan.Fix = append(plan.Fix, Fixed{w.row, fmt.Sprintf("本体がちょうどこの組の alias %s がある（--name %s で使う）", w.aliasBody, w.aliasBody)})
				continue
			}
			// もうある名前を使う時は、同じ組の別の alias の本体も名前にする（alias の alias。使う所はそのまま通る）。
		}
		if first == nil {
			first = w
		}
		ref := q.Name
		if w.ownerMod == mod {
			ref = short
		} else {
			plan.Pub = true
		}
		if isPubDecl(a, w.root) {
			plan.Pub = true // pub の宣言の型に書く名前は pub に（mod の外から呼ぶ所が型を書けるように）
		}
		src, _ := srcs.get(w.row.File)
		before := src[w.start:w.end]
		r := ref
		plan.Edits = append(plan.Edits, Edit{File: w.row.File, Start: w.start, End: w.end, Site: w.row,
			Make: func(string) (string, error) { return r, nil }})
		plan.Sites = append(plan.Sites, Fixed{w.row, clip(normSpace(before), 50) + " → " + ref})
	}
	for _, w := range written {
		if w.key != key && sameLabelsKey(w.labels, key) {
			plan.Excluded++
		}
	}
	if plan.Reused || first == nil {
		return plan, nil
	}
	// 置く所: mod の最初の宣言の前（/// ごと。宣言の範囲は /// から始まる）。
	file, pos, err := firstDeclOf(a, srcs, mod)
	if err != nil {
		return nil, err
	}
	src, _ := srcs.get(file)
	indent := lineIndent(src, pos)
	ls := lineStart(src, pos)
	var fields []string
	for _, l := range first.labels {
		fields = append(fields, l+" = "+shortenIn(first.fields[l], mod))
	}
	var b strings.Builder
	if q.Doc != "" {
		b.WriteString(indent + "/// " + q.Doc + "\n")
	}
	if plan.Pub {
		b.WriteString(indent + "pub ")
	} else {
		b.WriteString(indent)
	}
	b.WriteString("type alias " + short + " = { " + strings.Join(fields, ", ") + " }\n\n")
	decl := b.String()
	plan.Decl = strings.TrimSpace(decl)
	plan.DeclRow = rowAt(file, src, ls, q.Name)
	plan.DeclRow.Kind = "alias-decl"
	plan.Edits = append(plan.Edits, Edit{File: file, Start: ls, End: ls, Site: plan.DeclRow,
		Make: func(string) (string, error) { return decl, nil }})
	return plan, nil
}

// isPubDecl は宣言 root が pub か（def は Spec の、enum・type alias は自分の Modifiers）。
func isPubDecl(a *Ast, root int32) bool {
	for _, c := range a.Children(root) {
		switch a.KindOf(c) {
		case "Modifiers":
			if m, _ := a.Attr(c, "mod"); strings.Contains(m, "Public") {
				return true
			}
		case "Spec":
			if isPubDecl(a, c) {
				return true
			}
		}
	}
	return false
}

func sortedCopy(xs []string) []string {
	out := append([]string{}, xs...)
	sort.Strings(out)
	return out
}

// sameLabelsKey は欄の並びが key（`{ a = A, b = B }`）の欄と同じか。
func sameLabelsKey(labels []string, key string) bool {
	l, _, ok := parseRecordType(key)
	return ok && sameLabels(labels, sortedCopy(l))
}

func orDash(s string) string {
	if s == "" {
		return "record でない"
	}
	return s
}

func unicodeUpper(s string) bool { return s != "" && s[0] >= 'A' && s[0] <= 'Z' }

// shortenIn は修飾つきの型の字の中の、mod の中の名前（mod.X）を素の名前にする。
func shortenIn(text, mod string) string {
	return regexp.MustCompile(`\b`+regexp.QuoteMeta(mod)+`\.([A-Z][A-Za-z0-9_]*)\b`).ReplaceAllStringFunc(text, func(m string) string {
		rest := m[len(mod)+1:]
		if strings.Contains(rest, ".") {
			return m
		}
		return rest
	})
}

// targetKey は --from（型の字）か file:line（その行の閉じた record）から、目当ての欄の組を 1 つに決める。
func targetKey(a *Ast, written []writtenRecord, q TypeAliasQuery) (string, error) {
	keys := map[string]bool{}
	switch {
	case q.From != "":
		labels, types, ok := parseRecordType(q.From)
		if !ok {
			return "", fmt.Errorf("--from は閉じた record の型の字（`{ a = A, b = B }`）: %q", q.From)
		}
		for _, rs := range astRecordsByRoot(a) {
			for _, r := range rs {
				if matchRecord(labels, types, r) {
					keys[r.key] = true
				}
			}
		}
		if len(keys) == 0 {
			return "", fmt.Errorf("--from の組 %s を型に書いた所が無い（引数・戻り・enum の case・type alias の型を見る）", normSpace(q.From))
		}
	case q.At != "":
		file, lineText, ok := strings.Cut(q.At, ":")
		line, err := strconv.Atoi(lineText)
		if !ok || err != nil {
			return "", fmt.Errorf("位置は <file>:<行>: %q", q.At)
		}
		for _, w := range written {
			if w.row.File == file && w.row.Line == line {
				keys[w.key] = true
			}
		}
		// 宣言の始まりの行（/// の行。lint の行）なら、その宣言の型の record。
		if len(keys) == 0 {
			for _, w := range written {
				if w.row.File == file && int(a.Line[w.root]) == line {
					keys[w.key] = true
				}
			}
		}
		if len(keys) == 0 {
			return "", fmt.Errorf("%s に閉じた record の型（欄 2 つ以上・宣言の型の所）が無い", q.At)
		}
	default:
		return "", fmt.Errorf("--from '<型の字>' か <file>:<行> が要ります")
	}
	if len(keys) > 1 {
		var ks []string
		for k := range keys {
			ks = append(ks, k)
		}
		sort.Strings(ks)
		return "", fmt.Errorf("2 つ以上の組に当たる（%s）。--from に型を修飾つきで書くか、<file>:<行> で 1 つに", strings.Join(ks, "・"))
	}
	for k := range keys {
		return k, nil
	}
	return "", nil
}

// firstDeclOf は mod の最初の宣言の始まり（ファイルとバイトの位置。宣言の範囲は /// から始まる）。
// ファイルは `mod Mod {` を書いたファイル（2 つ以上なら名前が mod の終わりと同じ物）。
func firstDeclOf(a *Ast, srcs *reshapeSources, mod string) (string, int, error) {
	byFile := map[string]Row{}
	for i := range a.Kind {
		n := int32(i)
		if a.Parent[n] >= 0 || modOf(displaySym(a.RootName(n))) != mod {
			continue
		}
		r := a.SpanOf(n)
		if r.File == "" {
			continue
		}
		if old, ok := byFile[r.File]; !ok || less(r, old) {
			byFile[r.File] = r
		}
	}
	var files []string
	for f := range byFile {
		if src, err := srcs.get(f); err == nil && modOpenRe(mod).MatchString(src) {
			files = append(files, f)
		}
	}
	sort.Strings(files)
	if len(files) == 0 {
		return "", 0, fmt.Errorf("mod %s を書いたファイル（mod %s { と宣言）が無い（--name の mod を確かめる）", mod, mod)
	}
	file := files[0]
	for _, f := range files {
		if strings.TrimSuffix(path.Base(f), ".flix") == shortName(mod) {
			file = f
		}
	}
	src, _ := srcs.get(file)
	s, _, err := ByteRange(src, byFile[file])
	if err != nil {
		return "", 0, err
	}
	return file, s, nil
}

// extractTypeAliasReport は extract-type-alias の入口。
func extractTypeAliasReport(root string, idx *Index, a args, cfg Config, o Options, b Builder) (report, *Index, error) {
	ast, idx, err := loadGenericAst(b, idx, idx.Stage)
	if err != nil {
		return report{}, idx, err
	}
	srcs := &reshapeSources{root: root, m: map[string]string{}}
	q := TypeAliasQuery{Name: a.name, From: a.from, At: a.target, Doc: a.doc, Skip: a.skip}
	plan, err := PlanTypeAlias(ast, srcs, q)
	if err != nil {
		return report{}, idx, err
	}
	out := Change(root, plan.Edits, a.applyWith(cfg.Verify, o))
	r := report{Op: "extract-type-alias", Target: a.name + " = " + plan.Key, code: CodeExtractTypeAlias, Outcome: &out, Fix: sortedFixed(plan.Fix)}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(plan.Sites) + len(plan.Fix)
	}
	sites := append([]Fixed{}, plan.Sites...)
	if plan.Decl != "" {
		sites = append([]Fixed{{plan.DeclRow, plan.Decl}}, sites...)
	}
	r.Sites = sites
	rows := make([]Row, len(plan.Sites))
	for i, s := range plan.Sites {
		rows[i] = s.Row
	}
	decl := "置く 1（" + plan.DeclRow.Where() + "）"
	switch {
	case plan.Reused:
		decl = "もうある alias を使う"
	case plan.Decl == "":
		decl = "置かない（替える所が無い）"
	}
	r.gotText = fmt.Sprintf("名前に替える所 %d（%s）・%s・人へ回す %d", len(plan.Sites), split(rows), decl, len(plan.Fix))
	if plan.Excluded > 0 {
		r.extra = append(r.extra, fmt.Sprintf("同じ欄の名前で型の違う record %d（替えない）", plan.Excluded))
	}
	r.wantText = "欄の組 " + plan.Key + " を型に書いた所が全部 " + a.name + " になる（書けない所は fix）"
	for _, f := range r.Fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s\tfix\t%s（%s）", f.Where(), f.Why, f.Owner))
	}
	if plan.Decl != "" {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s", plan.DeclRow.Where(), plan.Decl))
	}
	for _, s := range plan.Sites {
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s\t%s", s.Where(), s.Why, s.Owner))
	}
	nextOf(&r, extractTypeAliasCommand(a), a, &out)
	switch {
	case len(plan.Sites) == 0 && len(plan.Fix) == 0:
		r.extra = append(r.extra, "替える所が無い")
	case out.State == StateApplied:
		r.Done = fmt.Sprintf("done: %d sites → %s · %d left to a person · check ok", len(plan.Sites), a.name, len(plan.Fix))
		r.Next, r.NextWhy = "bin/fge refactor usages "+a.name, "名前で書いた所（索引は作り直しになる）"
		r.lines = nil
	}
	return r, idx, nil
}

func extractTypeAliasCommand(a args) string {
	cmd := "bin/fge refactor extract-type-alias --name " + a.name
	if a.from != "" {
		cmd += " --from " + shellQuote(a.from)
	} else {
		cmd += " " + a.target
	}
	if a.doc != "" {
		cmd += " --doc " + shellQuote(a.doc)
	}
	return cmd
}
