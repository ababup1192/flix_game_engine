package flixdecl

// flixdecl — Flix のソースから `pub` 宣言だけを抜き出す層。
//
// api-digest（ダイジェストの生成）と f32（pub 面の Float32 検査）が同じ抽出を使う。
//
// WhyNot: 正規表現 1 本で書き直さないのは、宣言が複数行にまたがり、括弧とブレースの
// 深さを数えないと本体の開始が決められないため（`==` `=>` を代入と読み違える）。
// 1 文字ずつ追う。

import (
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// Package は走査の対象（表示名とソース根）。並びはそのまま表示順に使う。
// WhyNot: render_gl を入れないのは、そこが GL の境界の内側で pub 面の決まりが違うため。
type Package struct {
	Name string
	Root string
}

// Packages はダイジェストに載せる 3 つ。
var Packages = []Package{
	{Name: "engine", Root: "engine/src"},
	{Name: "engine_world", Root: "engine_world/src"},
	{Name: "engine_tools", Root: "engine_tools/src"},
}

// Decl は 1 つの宣言。Doc は直前の `///` 1 行（無ければ空）、Text は 1 行にまとめた宣言。
type Decl struct {
	Doc  string
	Text string
}

// ModDecls は 1 つの mod に属する宣言。出現順のまま。
type ModDecls struct {
	Mod   string
	Decls []Decl
}

// FileDecls は .flix 1 本の走査結果。Rel はリポジトリのルートからの相対パス（posix）。
type FileDecls struct {
	Path string
	Rel  string
	Mods []ModDecls
}

// pySpace は空白とみなす字の集合（Unicode の空白すべて）。
// WhyNot: Go の `\s` を使わないのは ASCII だけしか見ないため（全角空白で切れ方が変わる）。
const pySpace = `[\t\n\v\f\r \x{1c}-\x{1f}\x{85}\p{Z}]`

var (
	modRe = regexp.MustCompile(`^(?:pub` + pySpace + `+)?mod` + pySpace + `+([A-Za-z][A-Za-z0-9_.]*)` + pySpace + `*\{`)
	effRe = regexp.MustCompile(`^pub` + pySpace + `+eff` + pySpace + `+([A-Za-z][A-Za-z0-9_]*)`)

	defNameRe   = regexp.MustCompile(`^pub` + pySpace + `+def` + pySpace + `+([A-Za-z][A-Za-z0-9_]*)`)
	typeNameRe  = regexp.MustCompile(`^pub` + pySpace + `+(?:enum|type` + pySpace + `+alias)` + pySpace + `+([A-Za-z][A-Za-z0-9_]*)`)
	effOpNameRe = regexp.MustCompile(`^pub` + pySpace + `+eff` + pySpace + `+([A-Za-z][A-Za-z0-9_]*)` + pySpace + `*\{` + pySpace + `*def` + pySpace + `+([A-Za-z][A-Za-z0-9_]*)`)
)

// IsSpace は空白とみなす字かを返す（pySpace と同じ範囲）。
func IsSpace(r rune) bool {
	if r >= 0x1c && r <= 0x1f {
		return true
	}
	return unicode.IsSpace(r)
}

// Strip は前後の空白を削る。
func Strip(s string) string { return strings.TrimFunc(s, IsSpace) }

// Collapse は続く空白を 1 個の空白に潰して前後を削る。
func Collapse(text string) string {
	var b strings.Builder
	pendingSpace := false
	for _, r := range text {
		if IsSpace(r) {
			pendingSpace = true
			continue
		}
		if pendingSpace && b.Len() > 0 {
			b.WriteByte(' ')
		}
		pendingSpace = false
		b.WriteRune(r)
	}
	return b.String()
}

// Truncate は先頭 n 文字を返す（バイトでなく文字で数える）。
func Truncate(s string, n int) string {
	count := 0
	for i := range s {
		if count == n {
			return s[:i]
		}
		count++
	}
	return s
}

// scannable は文字列リテラルの外にある `//` 以降（行コメント）を落とした行を返す。
// 括弧の深さ数えと `=` 判定が、コメント中の記号に惑わされないようにする下ごしらえ。
func scannable(line string) string {
	var out []byte
	inStr, skip := false, false
	for i := 0; i < len(line); i++ {
		c := line[i]
		if skip {
			skip = false
			out = append(out, c)
			continue
		}
		if inStr {
			out = append(out, c)
			if c == '\\' {
				skip = true
			} else if c == '"' {
				inStr = false
			}
			continue
		}
		if c == '"' {
			inStr = true
			out = append(out, c)
			continue
		}
		if c == '/' && i+1 < len(line) && line[i+1] == '/' {
			break
		}
		out = append(out, c)
	}
	return string(out)
}

func isOpen(c byte) bool  { return c == '(' || c == '[' || c == '{' }
func isClose(c byte) bool { return c == ')' || c == ']' || c == '}' }

// depthDelta は文字列リテラルの外にある括弧だけを数えた深さの増減を返す。
func depthDelta(raw string) int {
	delta := 0
	inStr, skip := false, false
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		if skip {
			skip = false
			continue
		}
		if inStr {
			if c == '\\' {
				skip = true
			} else if c == '"' {
				inStr = false
			}
			continue
		}
		if c == '"' {
			inStr = true
			continue
		}
		if isOpen(c) {
			delta++
		} else if isClose(c) {
			delta--
		}
	}
	return delta
}

// depthDeltaRaw は文字列リテラルの中の括弧も数えた深さの増減を返す。
// WhyNot: depthDelta と一本化しないのは、eff の範囲を測る所だけは文字列リテラルの
// 中も数えるため（一本化すると eff の終わりがずれる）。
func depthDeltaRaw(raw string) int {
	delta := 0
	for i := 0; i < len(raw); i++ {
		if isOpen(raw[i]) {
			delta++
		} else if isClose(raw[i]) {
			delta--
		}
	}
	return delta
}

// joinParts は空でない部分だけを空白でつないで 1 行に潰す。
func joinParts(parts []string) string {
	var kept []string
	for _, p := range parts {
		if s := Strip(p); s != "" {
			kept = append(kept, s)
		}
	}
	return Collapse(strings.Join(kept, " "))
}

// extractDefSignature は `pub def` の宣言を、本体開始の `=` 直前まで 1 行にまとめて返す。
func extractDefSignature(lines []string, startIdx int) (string, int) {
	depth := 0
	var parts []string
	i := startIdx
	limit := startIdx + 60
	if limit > len(lines) {
		limit = len(lines)
	}
	for i < limit {
		raw := scannable(lines[i])
		var buf []byte
		inStr, skip, stop := false, false, false
		n := len(raw)
		for k := 0; k < n; k++ {
			c := raw[k]
			if skip {
				skip = false
				buf = append(buf, c)
				continue
			}
			if inStr {
				buf = append(buf, c)
				if c == '\\' {
					skip = true
				} else if c == '"' {
					inStr = false
				}
				continue
			}
			if c == '"' {
				inStr = true
				buf = append(buf, c)
				continue
			}
			if isOpen(c) {
				depth++
				buf = append(buf, c)
				continue
			}
			if isClose(c) {
				depth--
				buf = append(buf, c)
				continue
			}
			if c == '=' && depth == 0 {
				// ==, !=, <=, >=, => は本体開始の代入ではないので飛ばす。
				prevIsOp := k > 0 && strings.IndexByte("=!<>~", raw[k-1]) >= 0
				nxtIsOp := k+1 < n && strings.IndexByte("=>", raw[k+1]) >= 0
				if !prevIsOp && !nxtIsOp {
					stop = true
					break
				}
			}
			buf = append(buf, c)
		}
		parts = append(parts, string(buf))
		if stop {
			break
		}
		i++
	}
	return joinParts(parts), i
}

// extractBlock は `pub enum` / `pub type alias` の宣言全体を、括弧の深さが 0 に戻るまで拾う。
// 関数と違い宣言そのものが型の形なので、case 行やフィールドの中身まで丸ごと 1 行にする。
func extractBlock(lines []string, startIdx int) (string, int) {
	depth := 0
	var parts []string
	i := startIdx
	limit := startIdx + 200
	if limit > len(lines) {
		limit = len(lines)
	}
	for i < limit {
		raw := scannable(lines[i])
		parts = append(parts, raw)
		depth += depthDelta(raw)
		i++
		if depth <= 0 {
			break
		}
	}
	return joinParts(parts), i
}

// effOp は eff の中の 1 つの op。
type effOp struct {
	Doc string
	Sig string
}

// extractEffBlock は `pub eff` を (eff 名, op の並び, 次の行番号) で返す。
// op には `pub` が付かないので、eff の中括弧の中だけを別に読む。op の終わりは
// 「次の `///` / `def` / 閉じ括弧が来た所」で決める（op には本体の `=` が無い）。
func extractEffBlock(lines []string, startIdx int) (string, []effOp, int) {
	name := "?"
	if m := effRe.FindStringSubmatch(Strip(lines[startIdx])); m != nil {
		name = m[1]
	}

	// 中括弧の深さで eff の範囲を測る。
	depth := 0
	end := startIdx
	limit := startIdx + 400
	if limit > len(lines) {
		limit = len(lines)
	}
	for i := startIdx; i < limit; i++ {
		depth += depthDeltaRaw(scannable(lines[i]))
		end = i
		if i > startIdx && depth <= 0 {
			break
		}
	}

	var ops []effOp
	pendingDoc, hasPending := "", false
	curDoc := ""
	var cur []string
	flush := func() {
		if len(cur) > 0 {
			ops = append(ops, effOp{Doc: curDoc, Sig: Collapse(strings.Join(cur, " "))})
		}
	}

	for i := startIdx + 1; i < end; i++ {
		// doc コメントの判定は生の行で行う（scannable は `//` から後ろを落とすので
		// `///` の行は空になる）。
		raw := Strip(lines[i])
		if strings.HasPrefix(raw, "///") {
			flush()
			curDoc, cur = "", nil
			if !hasPending {
				pendingDoc, hasPending = Strip(raw[3:]), true
			}
			continue
		}
		stripped := Strip(scannable(lines[i]))
		if stripped == "" {
			continue
		}
		if strings.HasPrefix(stripped, "def ") {
			flush()
			curDoc, cur = pendingDoc, []string{stripped}
			pendingDoc, hasPending = "", false
			continue
		}
		if strings.HasPrefix(stripped, "}") {
			flush()
			curDoc, cur = "", nil
			pendingDoc, hasPending = "", false
			continue
		}
		if len(cur) > 0 {
			cur = append(cur, stripped)
		} else {
			pendingDoc, hasPending = "", false
		}
	}
	flush()
	return name, ops, end + 1
}

// modOfLines は行番号ごとに、その行が属する mod の名前を返す（外なら空）。
func modOfLines(lines []string) []string {
	modOf := make([]string, len(lines))
	depth := 0
	type frame struct {
		name  string
		depth int
	}
	var stack []frame
	for idx, line := range lines {
		depth += depthDelta(scannable(line))
		for len(stack) > 0 && depth < stack[len(stack)-1].depth {
			stack = stack[:len(stack)-1]
		}
		if m := modRe.FindStringSubmatch(Strip(line)); m != nil {
			stack = append(stack, frame{name: m[1], depth: depth})
		}
		if len(stack) > 0 {
			modOf[idx] = stack[len(stack)-1].name
		}
	}
	return modOf
}

// ScanText はソース 1 本から mod ごとの宣言を出現順で返す。
func ScanText(text string) []ModDecls {
	lines := strings.Split(text, "\n")
	modOf := modOfLines(lines)

	var order []string
	buckets := map[string][]Decl{}
	add := func(mod string, d Decl) {
		if _, seen := buckets[mod]; !seen {
			order = append(order, mod)
		}
		buckets[mod] = append(buckets[mod], d)
	}

	pendingDoc, hasPending := "", false
	for i := 0; i < len(lines); i++ {
		stripped := Strip(lines[i])
		if strings.HasPrefix(stripped, "///") {
			if !hasPending {
				pendingDoc, hasPending = Strip(stripped[3:]), true
			}
			continue
		}
		switch {
		case strings.HasPrefix(stripped, "pub def "):
			sig, _ := extractDefSignature(lines, i)
			if mod := modOf[i]; mod != "" {
				add(mod, Decl{Doc: pendingDoc, Text: sig})
			}
		case strings.HasPrefix(stripped, "pub eff "):
			effName, ops, _ := extractEffBlock(lines, i)
			if mod := modOf[i]; mod != "" {
				add(mod, Decl{Doc: pendingDoc, Text: "pub eff " + effName})
				for _, op := range ops {
					add(mod, Decl{Doc: op.Doc, Text: "pub eff " + effName + " { " + op.Sig + " }"})
				}
			}
		case strings.HasPrefix(stripped, "pub enum "), strings.HasPrefix(stripped, "pub type alias "):
			decl, _ := extractBlock(lines, i)
			if mod := modOf[i]; mod != "" {
				add(mod, Decl{Doc: pendingDoc, Text: decl})
			}
		}
		pendingDoc, hasPending = "", false
	}

	out := make([]ModDecls, 0, len(order))
	for _, mod := range order {
		out = append(out, ModDecls{Mod: mod, Decls: buckets[mod]})
	}
	return out
}

// ScanFile は .flix 1 本を読んで走査する。
func ScanFile(path string) ([]ModDecls, error) {
	text, err := pxlib.ReadTextReplace(path)
	if err != nil {
		return nil, err
	}
	return ScanText(text), nil
}

// FlixFiles は pkgRoot 配下の *.flix をパスの名前順で返す。
func FlixFiles(root, pkgRoot string) []string {
	dir := filepath.Join(root, filepath.FromSlash(pkgRoot))
	if !pxlib.HasDir(dir) {
		return nil
	}
	files := pxlib.Rglob(dir, ".flix")
	sort.Strings(files)
	return files
}

// ScanPackage は 1 パッケージ分のファイルを名前順に走査する。
// 読めなかったファイルは飛ばす（壊れた字は置き換えて読むので、残るのは開けない物だけ）。
func ScanPackage(root string, pkg Package) []FileDecls {
	var out []FileDecls
	for _, path := range FlixFiles(root, pkg.Root) {
		mods, err := ScanFile(path)
		if err != nil {
			continue
		}
		out = append(out, FileDecls{Path: path, Rel: RelTo(root, path), Mods: mods})
	}
	return out
}

// RelTo は root から見た相対パスを posix の字面で返す。外に出るときはそのままの字面。
func RelTo(root, path string) string {
	rel, err := filepath.Rel(root, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		return pxlib.PosixPath(path)
	}
	return pxlib.PosixPath(rel)
}

// DeclName は宣言 1 行から名前を取る。eff の op は "Audio.setVolume" の形で返す。
func DeclName(decl string) string {
	if m := effOpNameRe.FindStringSubmatch(decl); m != nil {
		return m[1] + "." + m[2]
	}
	for _, re := range []*regexp.Regexp{defNameRe, typeNameRe, effRe} {
		if m := re.FindStringSubmatch(decl); m != nil {
			return m[1]
		}
	}
	return "?"
}
