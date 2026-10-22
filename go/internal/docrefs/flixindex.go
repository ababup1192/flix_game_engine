package docrefs

// Flix の宣言の名前の索引。文書の `Mod.name` が今のソースに在るかを引く。
//
// 2 段: flixlint の索引（bin/fge refactor が build/refactor/spans-resolved.tsv に書く・コンパイラの名前解決の物）が
// ソースより新しければ先にそれで引き、無い名前は字の索引（コメントと文字列を空白にしてから mod・def・enum・case…を
// 拾う）で引く。flixlint の索引は def・enum・case（と alias）しか持たず、mod・eff・trait・struct・record の欄は字の索引だけが持つ。
//
// WhyNot: 索引が在る時に字の索引を捨てないのは、索引の時刻が新しくても中身が古いこと（別の版から写した・
// 作り直しの途中で止まった）があり、その時に今在る名前を「無い」と止めないため。字の索引が拾い損ねた宣言を
// 索引が埋める向きにだけ効かせる。
//
// Flix の標準ライブラリ（Clock.runWithIO・List.map）は flix.jar の src/library/*.flix を同じ字の索引で読み、
// 頭のモジュールがこのリポの物と同じ名前（engine の Clock と標準の Clock）でも、標準に在る名前は「在る」と数える。
// jar は このリポ → ゲームのエンジン → git の主の作業場（git worktree の元）の順に flixJar の場所を探す。
//
// WhyNot: 標準ライブラリの名前の一覧をリポに写して持たないのは、Flix の版を上げるたびに写しが古びるため。
// jar は devbox.json の版の物が bin/flix.jar に置かれる（make status が置く）ので、それを毎回読む。
//
// WhyNot: lib の fpkg（エンジン）を読まないのは、ゲームの文書がエンジンの名前を指すのは普通で、
// それはエンジン側の検査（api-index・check-refs）の受け持ちだから。頭のモジュールがこのリポに無い名前は数えない。

import (
	"archive/zip"
	"bufio"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/stateshape"
)

// Index は宣言の名前の集まり。
type Index struct {
	Source string // "spans"（flixlint の索引も使った）か "text"（字だけ）
	Decls  int    // 宣言の数（名前の重なりを除く）

	full     map[string]bool     // 宣言の完全な名前（World.Phase.Clear）
	known    map[string]bool     // 宣言の名前と入れ物の名前の、後ろからの全部の切れ端（Phase.Clear・Clear も）
	heads    map[string]bool     // 入れ物（mod・enum・eff・trait・struct・type alias）の名前の 1 節
	children map[string][]string // 入れ物の完全な名前 → 中の名前の最後の節
	bySuffix map[string][]string // 入れ物の切れ端 → 完全な名前
	byLast   map[string][]string // 最後の節 → 完全な名前
	std      map[string]bool     // Flix の標準ライブラリの宣言の名前の 2 節以上の切れ端（Time.Clock.runWithIO → Clock.runWithIO も）
}

func newIndex() *Index {
	return &Index{full: map[string]bool{}, known: map[string]bool{}, heads: map[string]bool{},
		children: map[string][]string{}, bySuffix: map[string][]string{}, byLast: map[string][]string{}}
}

// add は宣言 1 つ（完全な名前）を足す。container は入れ物（中に名前を持てる物）か。
func (x *Index) add(name string, container bool) {
	if name == "" || x.full[name] && !container {
		return
	}
	segs := strings.Split(name, ".")
	if !x.full[name] {
		x.full[name] = true
		x.Decls++
		last := segs[len(segs)-1]
		x.byLast[last] = append(x.byLast[last], name)
		if len(segs) > 1 {
			parent := strings.Join(segs[:len(segs)-1], ".")
			x.children[parent] = append(x.children[parent], last)
		}
	}
	for i := range segs {
		x.known[strings.Join(segs[i:], ".")] = true
	}
	// 入れ物の名前（途中の節と、入れ物そのもの）の切れ端から完全な名前を引けるようにする（候補の兄弟を探す）。
	upto := len(segs) - 1
	if container {
		upto = len(segs)
	}
	for j := 1; j <= upto; j++ {
		prefix := strings.Join(segs[:j], ".")
		for i := 0; i < j; i++ {
			suf := strings.Join(segs[i:j], ".")
			if !contains(x.bySuffix[suf], prefix) {
				x.bySuffix[suf] = append(x.bySuffix[suf], prefix)
			}
		}
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// addHead は文書の名前の頭として数える名前（最上位のモジュールと、mod・enum・eff・trait・struct の名前）を足す。
//
// WhyNot: type alias の名前を頭にしないのは、ゲームの record の別名（PreRoll.Clock）がエンジンのモジュール
// （Clock.Time）と同じ名前になりやすく、エンジンの名前を「このリポの名前が無い」と読み違えるため。
func (x *Index) addHead(name string) {
	if name != "" {
		x.heads[name] = true
	}
}

// Owns は q の頭（最初の節）がこのリポの入れ物の名前か。違えば q はエンジンか外の物で、この検査は数えない。
func (x *Index) Owns(q string) bool {
	head, _, _ := strings.Cut(q, ".")
	return x.heads[head]
}

// Has は q（Mod.name・Enum.Case・Mod.Sub.name。途中から書いてもよい）が宣言か入れ物の名前として在るか。
func (x *Index) Has(q string) bool { return x.known[q] }

// Near は見つからない q に近い名前を 3 つまで: 同じ最後の節を持つ別の場所の名前（移った）→ 同じ入れ物の中の似た名前。
func (x *Index) Near(q string, near func(string, []string) []string) []string {
	segs := strings.Split(q, ".")
	last := segs[len(segs)-1]
	var out []string
	push := func(s string) {
		if len(out) < 3 && !contains(out, s) {
			out = append(out, s)
		}
	}
	moved := append([]string{}, x.byLast[last]...)
	sort.Strings(moved)
	for _, m := range moved {
		push(m)
	}
	parent := strings.Join(segs[:len(segs)-1], ".")
	for _, p := range x.bySuffix[parent] {
		for _, c := range near(last, x.children[p]) {
			push(p + "." + c)
		}
	}
	return out
}

// ------------------------------------------------------------ 字の索引

// declKind は字で拾った宣言の種類（入れ物か、flixlint の索引にも載る物か）。
type declKind int

const (
	kindMod declKind = iota
	kindEnum
	kindEff
	kindTrait
	kindStruct
	kindAlias
	kindDef  // def（flixlint の索引にも載る）
	kindCase // enum の case（flixlint の索引にも載る）
	kindField
	kindOp // eff の def・trait の def（flixlint の索引には載らない）
)

func (k declKind) container() bool { return k <= kindAlias }

// textDecl は字で拾った宣言 1 つ（Enum・Case は flixlint の索引の行の種類: enum-decl と case-decl）。
type textDecl struct {
	Name string
	Kind declKind
	Enum bool
	Case bool
}

type scope struct {
	name string
	kind declKind
	anon bool // def の本体・式の { } など（中の宣言は数えない）
	inst bool // instance（中の def は trait の物の実装で、名前を足さない）
}

func isIdentByte(c byte) bool {
	return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func skipSpaces(s string, i int) int {
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i++
	}
	return i
}

func readIdent(s string, i int) (string, int) {
	j := i
	for j < len(s) && isIdentByte(s[j]) {
		j++
	}
	return s[i:j], j
}

// readDotted は A.B.C の形を読む（mod の名前）。
func readDotted(s string, i int) (string, int) {
	name, j := readIdent(s, i)
	for j+1 < len(s) && s[j] == '.' && isIdentByte(s[j+1]) {
		var more string
		more, j = readIdent(s, j+1)
		name += "." + more
	}
	return name, j
}

// skipBalanced は s[i] の括弧（( [ {）と対になる位置の次。
func skipBalanced(s string, i int) int {
	open := s[i]
	close := map[byte]byte{'(': ')', '[': ']', '{': '}'}[open]
	depth := 0
	for j := i; j < len(s); j++ {
		switch s[j] {
		case open:
			depth++
		case close:
			depth--
			if depth == 0 {
				return j + 1
			}
		}
	}
	return len(s)
}

// labelsOf は record・struct の本体（{ } の中身）の欄の名前（深さ 0 の「名前:」・record の型の「名前 = 型」）。
func labelsOf(body string) []string {
	var out []string
	depth := 0
	start := 0
	flush := func(part string) {
		part = strings.TrimSpace(part)
		part = strings.TrimPrefix(part, "mut ")
		name, j := readIdent(part, 0)
		if name == "" || name[0] < 'a' || name[0] > 'z' {
			return
		}
		if j = skipSpaces(part, j); j < len(part) && (part[j] == ':' || part[j] == '=' && (j+1 == len(part) || part[j+1] != '>')) {
			out = append(out, name)
		}
	}
	for i := 0; i < len(body); i++ {
		switch body[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case ',', '|':
			if depth == 0 {
				flush(body[start:i])
				start = i + 1
			}
		}
	}
	flush(body[start:])
	return out
}

// ScanFlix は .flix 1 本の本文から宣言の完全な名前を拾う。
func ScanFlix(src string) []textDecl {
	code := stateshape.Blank(src)
	var out []textDecl
	var stack []scope
	var pending *scope
	recordable := func() (string, bool) {
		var names []string
		for _, s := range stack {
			if s.anon || s.inst {
				return "", false
			}
			names = append(names, s.name)
		}
		return strings.Join(names, "."), true
	}
	emit := func(name string, kind declKind) {
		prefix, ok := recordable()
		if !ok || name == "" {
			return
		}
		if prefix != "" {
			name = prefix + "." + name
		}
		out = append(out, textDecl{Name: name, Kind: kind})
	}
	top := func() *scope {
		if len(stack) == 0 {
			return nil
		}
		return &stack[len(stack)-1]
	}
	for i := 0; i < len(code); {
		c := code[i]
		switch {
		case c == '{':
			if pending != nil {
				stack = append(stack, *pending)
			} else {
				stack = append(stack, scope{anon: true})
			}
			pending = nil
			i++
			continue
		case c == '}':
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
			}
			pending = nil
			i++
			continue
		case c == '=' || c == ';':
			pending = nil
			i++
			continue
		case !isIdentByte(c) || (i > 0 && (isIdentByte(code[i-1]) || code[i-1] == '.' || code[i-1] == '#')):
			i++
			continue
		}
		word, j := readIdent(code, i)
		i = j
		k := skipSpaces(code, j)
		switch word {
		case "mod":
			name, e := readDotted(code, k)
			pending = &scope{name: name, kind: kindMod}
			emit(name, kindMod)
			i = e
		case "enum", "eff", "trait", "struct":
			name, e := readIdent(code, k)
			kind := map[string]declKind{"enum": kindEnum, "eff": kindEff, "trait": kindTrait, "struct": kindStruct}[word]
			emit(name, kind)
			pending = &scope{name: name, kind: kind}
			i = e
			e = skipSpaces(code, e)
			if e < len(code) && code[e] == '[' {
				e = skipSpaces(code, skipBalanced(code, e))
			}
			switch {
			case kind == kindEnum && e < len(code) && code[e] == '(':
				// enum Celsius(Int32) は 1 つの case を同じ名前で持つ。
				emit(name+"."+name, kindCase)
			case kind == kindStruct && e < len(code) && code[e] == '{':
				for _, l := range labelsOf(code[e+1 : skipBalanced(code, e)-1]) {
					emit(name+"."+l, kindField)
				}
			}
		case "instance":
			pending = &scope{inst: true}
		case "type":
			name, e := readIdent(code, k)
			if name != "alias" {
				continue
			}
			e = skipSpaces(code, e)
			name, e = readIdent(code, e)
			emit(name, kindAlias)
			i = e
			e = skipSpaces(code, e)
			if e < len(code) && code[e] == '[' {
				e = skipSpaces(code, skipBalanced(code, e))
			}
			if e < len(code) && code[e] == '=' {
				e = skipSpaces(code, e+1)
				if e < len(code) && code[e] == '{' {
					for _, l := range labelsOf(code[e+1 : skipBalanced(code, e)-1]) {
						emit(name+"."+l, kindField)
					}
				}
			}
		case "def":
			pending = nil
			name, e := readIdent(code, k)
			kind := kindDef
			if t := top(); t != nil && (t.kind == kindEff || t.kind == kindTrait) && !t.anon {
				kind = kindOp
			}
			emit(name, kind)
			i = e
		case "case":
			t := top()
			if t == nil || t.anon || t.kind != kindEnum {
				continue
			}
			e := k
			for {
				var name string
				name, e = readIdent(code, skipSpaces(code, e))
				if name == "case" { // case A, case B
					name, e = readIdent(code, skipSpaces(code, e))
				}
				if name == "" {
					break
				}
				emit(name, kindCase)
				e = skipSpaces(code, e)
				if e < len(code) && code[e] == '(' {
					e = skipSpaces(code, skipBalanced(code, e))
				}
				if e >= len(code) || code[e] != ',' {
					break
				}
				e++
			}
			i = e
		}
	}
	return out
}

// flixFiles は dirs の下の .flix（根からの相対）と一番新しい更新時刻。symlink の先も辿り、同じ実体は 1 度だけ。
func flixFiles(root string, dirs []string) ([]string, int64) {
	var out []string
	var newest int64
	seen := map[string]bool{}
	var walk func(dir string)
	walk = func(dir string) {
		real, err := filepath.EvalSymlinks(filepath.Join(root, dir))
		if err != nil || seen[real] {
			return
		}
		seen[real] = true
		entries, err := os.ReadDir(filepath.Join(root, dir))
		if err != nil {
			return
		}
		for _, e := range entries {
			rel := filepath.Join(dir, e.Name())
			info, err := os.Stat(filepath.Join(root, rel))
			if err != nil {
				continue
			}
			switch {
			case info.IsDir():
				walk(rel)
			case info.Mode().IsRegular() && strings.HasSuffix(e.Name(), ".flix"):
				realFile, err := filepath.EvalSymlinks(filepath.Join(root, rel))
				if err != nil || seen[realFile] {
					continue
				}
				seen[realFile] = true
				out = append(out, filepath.ToSlash(rel))
				newest = max(newest, info.ModTime().UnixNano())
			}
		}
	}
	for _, d := range dirs {
		walk(d)
	}
	sort.Strings(out)
	return out, newest
}

// readSpans は flixlint の索引から宣言（def・enum・case・alias）の名前を読む。頭の行が flixlint-spans で
// stage=resolved の物だけ（版は問わない: 9 欄の並びは版 1〜3 で同じ）。パッケージの物（$ で始まる）は外す。
func readSpans(path string) ([]textDecl, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	var names []textDecl
	first := true
	for sc.Scan() {
		line := sc.Text()
		if first {
			first = false
			h := strings.Fields(line)
			if len(h) < 4 || h[0] != "#" || h[1] != "flixlint-spans" || h[3] != "stage=resolved" {
				return nil, false
			}
			continue
		}
		c := strings.Split(line, "\t")
		if len(c) != 9 {
			continue
		}
		switch c[0] {
		case "def-decl", "case-decl":
			if !strings.HasPrefix(c[6], "$") {
				names = append(names, textDecl{Name: c[6], Kind: kindDef, Case: c[0] == "case-decl"})
			}
		case "enum-decl", "alias-decl":
			if !strings.HasPrefix(c[6], "$") {
				names = append(names, textDecl{Name: c[6], Kind: kindEnum, Enum: c[0] == "enum-decl"})
			}
		}
	}
	return names, sc.Err() == nil && !first
}

// BuildIndex は sources の .flix から索引を作る。spans が sources の .flix より新しければ、def・enum・case は索引の物を使う。
func BuildIndex(root string, sources []string, spans string) (*Index, []string) {
	files, newest := flixFiles(root, sources)
	x := newIndex()
	x.Source = "text"
	var spanNames []textDecl
	if spans != "" {
		p := filepath.Join(root, filepath.FromSlash(spans))
		if info, err := os.Stat(p); err == nil && info.ModTime().UnixNano() >= newest {
			if names, ok := readSpans(p); ok && len(names) > 0 {
				spanNames = names
				x.Source = "spans"
			}
		}
	}
	for _, rel := range files {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			continue
		}
		for _, d := range ScanFlix(string(body)) {
			segs := strings.Split(d.Name, ".")
			x.addHead(segs[0])
			switch d.Kind {
			case kindMod:
				for _, s := range segs {
					x.addHead(s)
				}
			case kindEnum, kindEff, kindTrait, kindStruct:
				x.addHead(segs[len(segs)-1])
			}
			x.add(d.Name, d.Kind.container())
		}
	}
	for _, d := range spanNames {
		segs := strings.Split(d.Name, ".")
		x.addHead(segs[0])
		if d.Kind == kindEnum && d.Enum {
			x.addHead(segs[len(segs)-1])
		}
		if d.Case && len(segs) >= 2 {
			x.addHead(segs[len(segs)-2])
		}
		x.add(d.Name, d.Kind.container())
	}
	return x, files
}

// findFlixJar は rel（bin/flix.jar）を このリポ → engine（ゲームから見たエンジン）→ git の主の作業場 の順に探す。
// 無ければ ""。
func findFlixJar(root, engine, rel string) string {
	dirs := []string{root}
	if engine != "" {
		dirs = append(dirs, engine)
	}
	if out, err := exec.Command("git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir").Output(); err == nil {
		dirs = append(dirs, filepath.Dir(strings.TrimSpace(string(out))))
	}
	for _, d := range dirs {
		p := filepath.Join(d, filepath.FromSlash(rel))
		if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() {
			return p
		}
	}
	return ""
}

// loadStd は jar の src/library の .flix から宣言の名前を拾う（jar が "" か読めなければ空）。
// 文書は use した後の短い名前（Time.Clock.runWithIO を Clock.runWithIO）で書くので、後ろからの 2 節以上の切れ端も持つ。
func loadStd(jar string) map[string]bool {
	std := map[string]bool{}
	if jar == "" {
		return std
	}
	zr, err := zip.OpenReader(jar)
	if err != nil {
		return std
	}
	defer zr.Close()
	for _, f := range zr.File {
		if !strings.HasPrefix(f.Name, "src/library/") || !strings.HasSuffix(f.Name, ".flix") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		body, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			continue
		}
		for _, d := range ScanFlix(string(body)) {
			segs := strings.Split(d.Name, ".")
			for i := 0; i+2 <= len(segs); i++ {
				std[strings.Join(segs[i:], ".")] = true
			}
		}
	}
	return std
}
