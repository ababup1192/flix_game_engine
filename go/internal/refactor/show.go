package refactor

// show: 名前で宣言の本文だけを読む（cymbal の show に当たる、読むだけの問い）。
//
//	show <Mod.f | Enum | Enum.Case | Alias>[,<名前>…]   宣言の頭の /// と注記から本文の終わりまで
//
// grep で宣言の行を探し、Read の offset/limit で範囲を当て推量する 2 手を 1 手にする。
// 名前はコンパイラが解決した symbol で当てる（usages と同じ ResolveTarget。2 つ以上に当たれば候補を並べて止まる）。
// def の範囲は索引の ext=（shim が書く宣言の範囲。/// から本文の終わりまで）。enum と型 alias は索引に範囲が無いので、
// 宣言の名前の所から括弧を数えて終わりを決め、上へ /// と @ の行を足す。case はそれを持つ enum を見せる。
//
// WhyNot: 行番号を頭に付けない。読んだ字をそのまま Edit に渡せるようにし、行は頭の 1 行の範囲（file:始め-終わり）で言う。

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Shown は show が見せる宣言 1 つ（--json の 1 件）。
type Shown struct {
	Name  string `json:"name"` // 書かれた名前
	Sym   string `json:"sym"`
	Kind  string `json:"kind"` // def・enum・alias（case は enum を見せ、via に case を書く）
	Via   string `json:"via,omitempty"`
	File  string `json:"file"`
	Start int    `json:"start"`
	End   int    `json:"end"`
	Text  string `json:"text"`
	Note  string `json:"note,omitempty"` // 古い索引で答えた・字で探した時の 1 言
}

// ShowDecl は q の宣言の本文を返す。
func ShowDecl(rows []Row, q string, src *srcCache) (Shown, error) {
	t, err := ResolveTarget(rows, q)
	if err != nil {
		return Shown{}, err
	}
	s := Shown{Name: q, Sym: t.Sym, Kind: t.Kind}
	sym := t.Sym
	if t.Kind == "case" {
		sym = parentSym(t.Sym)
		s.Kind, s.Via, s.Sym = "enum", t.Sym, sym
	}
	want := map[string]string{"def": KindDefDecl, "enum": KindEnumDecl, "alias": KindAliasDecl}[s.Kind]
	var decl *Row
	for i := range rows {
		if rows[i].Kind == want && rows[i].Sym == sym {
			decl = &rows[i]
			break
		}
	}
	if decl == nil {
		return Shown{}, fmt.Errorf("%s（%s）の宣言は索引の外（パッケージの物）。engine の物は make api Q=%s", q, s.Kind, lastName(sym))
	}
	text := src.get(decl.File)
	if text == "" {
		return Shown{}, fmt.Errorf("%s が読めません", decl.File)
	}
	lines := strings.Split(text, "\n")
	start, end := declRange(*decl, lines)
	if start < 1 || end > len(lines) || start > end {
		return Shown{}, fmt.Errorf("%s の範囲 %d-%d がファイルの外（索引が古い。bin/fge refactor index --rebuild）", q, start, end)
	}
	s.File, s.Start, s.End = decl.File, start, end
	s.Text = strings.Join(lines[start-1:end], "\n")
	return s, nil
}

func parentSym(sym string) string {
	if i := strings.LastIndex(sym, "."); i > 0 {
		return sym[:i]
	}
	return sym
}

func lastName(sym string) string { return sym[strings.LastIndex(sym, ".")+1:] }

// declRange は宣言の行の範囲（1 から・両端を含む）。
func declRange(r Row, lines []string) (int, int) {
	if ext := r.Attr("ext"); ext != "" {
		if p := strings.Split(ext, ":"); len(p) == 4 {
			s, e1 := strconv.Atoi(p[0])
			e, e2 := strconv.Atoi(p[2])
			if e1 == nil && e2 == nil {
				return withLeadingDoc(s, lines), e
			}
		}
	}
	return withLeadingDoc(r.Line, lines), bodyEnd(r, lines)
}

// withLeadingDoc は start の上に続く ///・@ の行を範囲に入れる（ext= は /// から始まるので、足す物が無ければそのまま）。
func withLeadingDoc(start int, lines []string) int {
	for start > 1 {
		t := strings.TrimSpace(lines[start-2])
		if !strings.HasPrefix(t, "///") && !strings.HasPrefix(t, "@") {
			break
		}
		start--
	}
	return start
}

// bodyEnd は宣言の名前の所から括弧（{ [ (）を数え、深さ 0 で改行に来た行を終わりにする。
// enum は `{` を開いてから、型 alias は `=` を過ぎてから数え始める（`enum E[a]` の [ や、本文の無い enum で止まらないように）。
// 字の列とコメントの中の括弧は数えない。
func bodyEnd(r Row, lines []string) int {
	depth, started, opened := 0, false, false
	for i := r.Line - 1; i < len(lines); i++ {
		line := lines[i]
		from := 0
		if i == r.Line-1 {
			from = utf16Col(line, r.Col)
		}
		inStr := false
		for j := from; j < len(line); j++ {
			c := line[j]
			if inStr {
				if c == '\\' {
					j++
				} else if c == '"' {
					inStr = false
				}
				continue
			}
			switch {
			case c == '"':
				inStr = true
			case c == '/' && j+1 < len(line) && line[j+1] == '/':
				j = len(line)
			case c == '=' && !started:
				started = true
			case c == '{' || c == '[' || c == '(':
				if c == '{' {
					started = true
				}
				if started {
					depth++
					opened = true
				}
			case c == '}' || c == ']' || c == ')':
				if started {
					depth--
				}
			}
		}
		if started && depth <= 0 && (opened || strings.Contains(line[from:], "=")) {
			if !opened && i+1 < len(lines) && continues(lines[i+1]) {
				continue
			}
			return i + 1
		}
	}
	return len(lines)
}

// continues は次の行が前の行の続き（`|` や `->` で始まる型の続き）か。
func continues(next string) bool {
	t := strings.TrimSpace(next)
	return strings.HasPrefix(t, "|") || strings.HasPrefix(t, "->") || strings.HasPrefix(t, "+") || strings.HasPrefix(t, "&")
}

// utf16Col は 1 から数えた UTF-16 の列を、その行のバイトの位置に直す。
func utf16Col(line string, col int) int {
	n := 1
	for i, r := range line {
		if n >= col {
			return i
		}
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return len(line)
}

// showRun は show の答えを書く。終了コード: 0 全部見せた・2 1 つでも見せられない（見せられた物は書く）。
func showRun(out, errOut *strings.Builder, b Builder, s Stage, a args) int {
	ds, err := b.LoadDecls(s)
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		return 2
	}
	src := &srcCache{root: b.Root}
	var shown []Shown
	code := 0
	for _, q := range strings.Split(a.target, ",") {
		q = strings.TrimSpace(q)
		if q == "" {
			continue
		}
		sh, err := ds.show(q, src)
		if err != nil {
			fmt.Fprintf(errOut, "refactor show: %v\n", err)
			code = 2
			continue
		}
		shown = append(shown, sh)
	}
	if a.asJSON {
		js, _ := json.Marshal(map[string]any{"op": "show", "shown": shown, "exit": code})
		out.Write(js)
		out.WriteString("\n")
		return code
	}
	for i, sh := range shown {
		if i > 0 {
			out.WriteString("\n")
		}
		kind := sh.Kind
		if sh.Via != "" {
			kind += "・" + sh.Via + " を持つ"
		}
		if sh.Note != "" {
			kind += "・" + sh.Note
		}
		fmt.Fprintf(out, "── %s:%d-%d  %s（%s）\n%s\n", sh.File, sh.Start, sh.End, sh.Sym, kind, sh.Text)
	}
	return code
}

// declSet は show が引く宣言の行（spans-<段>.decl.tsv）。索引を作った後に .flix を直していれば stale で、
// 直したファイル（changed）の行だけが信用できない。
//
// WhyNot: 古いと分かった時にすぐ作り直さない。作り直しは 9 秒ほど（コンパイル 2 秒・228 ファイルの事実を書く 5.5 秒）で、
// 直している間の問いの多くは直していないファイルの宣言を指す。そのファイルの行は索引を作った時と同じなので、古い索引のままで正しい。
// 直したファイルの宣言を聞かれた時だけ作り直し、型が通らず作れなければ、そのファイルを字で探す（書きかけの間も答える）。
type declSet struct {
	b       Builder
	stage   Stage
	rows    []Row
	stale   bool
	changed map[string]bool
	tried   bool // 作り直しを試した（1 回の show で 2 度は試さない）
	failed  error
	src     string // 宣言の索引を作った時のソースの鍵（参照の索引 refs.tsv と合わせる）
}

// declHeader は decl.tsv の頭の行の印。2 行目からは `#file <パス> <中身のハッシュ>`、その後に宣言の行（索引と同じ 9 列）。
const declHeader = "# fge-refactor-decls 1"

// LoadDecls は宣言の行だけの索引を読む。ソースの鍵が合えば新しい、道具の鍵だけ合えば古い（直したファイルを覚える）、
// どちらも合わないか無ければ全体の索引を Load して（要れば作り直して）書き直す。
// WhyNot: 全体の索引（20 万行・読むのに 0.3 秒）を読まない。show が要るのは宣言の数千行だけ。
func (b Builder) LoadDecls(s Stage) (*declSet, error) {
	hashes, err := b.fileHashes()
	if err != nil {
		return nil, err
	}
	src, err := b.sourceKey(s)
	if err != nil {
		return nil, err
	}
	env := b.envKey()
	if !b.Rebuild {
		if d, ok := readDecls(b.declPath(s)); ok && d.env == env {
			ds := &declSet{b: b, stage: s, rows: d.rows, src: d.src}
			if d.src != src {
				ds.stale, ds.changed = true, changedFiles(d.hashes, hashes)
			}
			return ds, nil
		}
	}
	return b.rebuildDecls(s, hashes, src, env)
}

func (b Builder) declPath(s Stage) string {
	return filepath.Join(b.Dir(), "spans-"+string(s)+".decl.tsv")
}

// rebuildDecls は全体の索引を Load して宣言の行だけを書き出す。hashes・src は Load の前に取った物（作っている間に直されたら、
// 次の回に古いと分かる）。
func (b Builder) rebuildDecls(s Stage, hashes map[string]string, src, env string) (*declSet, error) {
	idx, err := b.Load(s)
	if err != nil {
		return nil, err
	}
	var keep []Row
	var sb strings.Builder
	fmt.Fprintf(&sb, "%s src=%s env=%s\n", declHeader, src, env)
	files := make([]string, 0, len(hashes))
	for f := range hashes {
		files = append(files, f)
	}
	sort.Strings(files)
	for _, f := range files {
		fmt.Fprintf(&sb, "#file %s %s\n", f, hashes[f])
	}
	for _, r := range idx.Rows {
		if !declKindsForShow[r.Kind] {
			continue
		}
		keep = append(keep, r)
		fmt.Fprintf(&sb, "%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n", r.Kind, r.File, r.Line, r.Col, r.EndLine, r.EndCol, r.Sym, r.Owner, r.Extra)
	}
	tmp := b.declPath(s) + ".tmp"
	if os.WriteFile(tmp, []byte(sb.String()), 0o644) == nil {
		os.Rename(tmp, b.declPath(s))
	}
	writeRefs(b.refsPath(s), src, idx.Rows)
	return &declSet{b: b, stage: s, rows: keep, src: src}, nil
}

var declKindsForShow = map[string]bool{KindDefDecl: true, KindEnumDecl: true, KindCaseDecl: true, KindAliasDecl: true}

type declFile struct {
	src, env string
	hashes   map[string]string
	rows     []Row
}

// readDecls は decl.tsv を読む（形が違えば ok=false）。
func readDecls(path string) (declFile, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return declFile{}, false
	}
	lines := strings.Split(string(data), "\n")
	if !strings.HasPrefix(lines[0], declHeader+" ") {
		return declFile{}, false
	}
	d := declFile{hashes: map[string]string{}}
	for _, f := range strings.Fields(lines[0]) {
		if v, ok := strings.CutPrefix(f, "src="); ok {
			d.src = v
		} else if v, ok := strings.CutPrefix(f, "env="); ok {
			d.env = v
		}
	}
	for _, line := range lines[1:] {
		if rest, ok := strings.CutPrefix(line, "#file "); ok {
			if f, h, ok := strings.Cut(rest, " "); ok {
				d.hashes[f] = h
			}
			continue
		}
		c := strings.Split(line, "\t")
		if len(c) != 9 {
			continue
		}
		var n [4]int
		for i := range n {
			n[i], _ = strconv.Atoi(c[2+i])
		}
		d.rows = append(d.rows, Row{Kind: c[0], File: c[1], Line: n[0], Col: n[1], EndLine: n[2], EndCol: n[3], Sym: c[6], Owner: c[7], Extra: c[8]})
	}
	return d, d.src != "" && d.env != ""
}

// fileHashes は索引に入れる .flix の中身のハッシュ（根からの相対パス → 16 字）。
func (b Builder) fileHashes() (map[string]string, error) {
	files, err := flixFiles(b.Root, b.sources())
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(files))
	for _, rel := range files {
		data, err := os.ReadFile(filepath.Join(b.Root, rel))
		if err != nil {
			return nil, err
		}
		h := sha256.Sum256(data)
		out[filepath.ToSlash(rel)] = hex.EncodeToString(h[:8])
	}
	return out, nil
}

// changedFiles は索引を作った後に中身が替わった・足された・消えたファイル。
func changedFiles(old, now map[string]string) map[string]bool {
	out := map[string]bool{}
	for f, h := range now {
		if old[f] != h {
			out[f] = true
		}
	}
	for f := range old {
		if _, ok := now[f]; !ok {
			out[f] = true
		}
	}
	return out
}

// show は q を見せる。古い索引で、当たらないか当たった宣言のファイルを直していれば、作り直してから引き直す。
// 作り直せない（型が通らない）時は、古い索引が指したファイルを字で探す。
func (ds *declSet) show(q string, src *srcCache) (Shown, error) {
	sh, err := ShowDecl(ds.rows, q, src)
	if !ds.stale || (err == nil && !ds.changed[sh.File]) {
		if err == nil && ds.stale {
			sh.Note = fmt.Sprintf("索引は古い（直したファイル %d）が、このファイルは直していない", len(ds.changed))
		}
		return sh, err
	}
	old := sh
	if !ds.tried {
		ds.tried = true
		fresh, ferr := ds.b.rebuildDecls(ds.stage, mustHashes(ds.b), mustKey(ds.b, ds.stage), ds.b.envKey())
		if ferr == nil {
			ds.rows, ds.stale, ds.changed, ds.src = fresh.rows, false, nil, fresh.src
			return ShowDecl(ds.rows, q, src)
		}
		ds.failed = ferr
	}
	if err != nil {
		return Shown{}, fmt.Errorf("%v（索引を作り直せない: %v）", err, firstLine(ds.failed))
	}
	return showByText(old, src, ds.failed)
}

func mustHashes(b Builder) map[string]string {
	h, _ := b.fileHashes()
	return h
}

func mustKey(b Builder, s Stage) string {
	k, _ := b.sourceKey(s)
	return k
}

func firstLine(err error) string {
	if err == nil {
		return ""
	}
	l, _, _ := strings.Cut(err.Error(), "\n")
	return l
}

// showByText は、索引を作れない時に、古い索引が指したファイルの今の字から宣言を探す（古い行に一番近い所）。
// 範囲は括弧を数えて決める（ext= は古いので使わない）。
func showByText(old Shown, src *srcCache, why error) (Shown, error) {
	text := src.get(old.File)
	lines := strings.Split(text, "\n")
	name := lastName(old.Sym)
	word := map[string]string{"def": "def", "enum": "enum", "alias": "type alias"}[old.Kind]
	re := regexp.MustCompile(`\b` + word + `\s+(` + regexp.QuoteMeta(name) + `)\b`)
	best, bestCol := -1, 0
	for i, l := range lines {
		if m := re.FindStringSubmatchIndex(l); m != nil {
			if best < 0 || absInt(i+1-old.Start) < absInt(best-old.Start) {
				best, bestCol = i+1, utf16ColOf(l, m[2])
			}
		}
	}
	if best < 0 {
		return Shown{}, fmt.Errorf("%s は %s から消えたらしい（索引を作り直せない: %s）", old.Sym, old.File, firstLine(why))
	}
	start, end := withLeadingDoc(best, lines), bodyEnd(Row{Line: best, Col: bestCol}, lines)
	old.Start, old.End = start, end
	old.Text = strings.Join(lines[start-1:end], "\n")
	old.Note = "型が通らず索引を作り直せないので、今のファイルを字で探した"
	return old, nil
}

func absInt(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

// utf16ColOf はバイトの位置を 1 から数えた UTF-16 の列に直す。
func utf16ColOf(line string, byteAt int) int {
	n := 1
	for _, r := range line[:byteAt] {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}

// warmDecls は宣言の索引を今のソースに合わせる（index --decls）。hook-flix-touch が .flix を直すたびに裏で流すので、
// 同じ根で流れている間は何もしない（decls.lock）。作っている間に直されたら、合うまで最大 3 回作り直す。
// WhyNot: 直すたびに待たずに作り直す。show が古い索引で答えられないのは直したファイルの宣言だけだが、その時の作り直しの
// 9 秒ほどを、次に探すまでの間に済ませておけば待たずに済む。
func warmDecls(out, errOut *strings.Builder, b Builder, s Stage) int {
	if err := os.MkdirAll(b.Dir(), 0o755); err != nil {
		fmt.Fprintf(errOut, "refactor index --decls: %v\n", err)
		return 2
	}
	lock := filepath.Join(b.Dir(), "decls.lock")
	f, err := os.OpenFile(lock, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		if info, serr := os.Stat(lock); serr == nil && time.Since(info.ModTime()) < declsLockTTL {
			fmt.Fprintln(out, "index --decls: もう流れている（decls.lock）")
			return 0
		}
		os.Remove(lock) // 落ちた走行の残り
		if f, err = os.OpenFile(lock, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644); err != nil {
			fmt.Fprintln(out, "index --decls: もう流れている（decls.lock）")
			return 0
		}
	}
	fmt.Fprintf(f, "%d\n", os.Getpid())
	f.Close()
	defer os.Remove(lock)
	for i := 0; i < 3; i++ {
		ds, err := b.LoadDecls(s)
		if err != nil {
			fmt.Fprintf(errOut, "refactor index --decls: %v\n", firstLine(err))
			return 2
		}
		if !ds.stale {
			fmt.Fprintf(out, "index --decls: %d 行（%s）\n", len(ds.rows), rel(b.declPath(s)))
			return 0
		}
		hashes, src := mustHashes(b), mustKey(b, s)
		if _, err := b.rebuildDecls(s, hashes, src, b.envKey()); err != nil {
			fmt.Fprintf(errOut, "refactor index --decls: %v\n", firstLine(err))
			return 2
		}
		os.Chtimes(lock, time.Now(), time.Now())
	}
	return 0
}

// declsLockTTL より古い decls.lock は落ちた走行の残りとみなす（作り直し 1 回は 10 秒ほど・3 回と JVM の冷えを見込む）。
const declsLockTTL = 3 * time.Minute
