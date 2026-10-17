// engineuses — ゲームの .flix に、engine の名前を取り込む `use <mount>::{...}` を mod ごとに足す層。
//
// Flix 0.78 から、依存パッケージ（flix_game_engine）の名前は mount を通す use からしか届かない
// （`use flix_game_engine::{App, Color}`）。ワイルドカードは無く、use は mod ごとに効く
// （ファイル直下の use は `mod View { }` の中へ届かない）。そこで、mod ごとに「その中で
// 使っている engine の名前」を数え、その mod の頭に 1 行の use を置く。何度回しても同じ結果になる。
//
// engine の名前は依存の fpkg（lib/ に Flix が取ってきた zip）から、木の一番外の pub 宣言を読む。
// ゲーム自身が宣言・import している名前は取り込まない（ゲームの名前を engine の名前で隠さない）。
//
// WhyNot: コンパイラの「Undefined name」を読んで直す形にしないのは、check を何周も回すと
// 大きなゲームで数分かかるため。字句だけで決め、仕上げに一度 check を回して確かめる。
package engineuses

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Options は 1 回の実行の設定。
type Options struct {
	Root      string // ゲームのルート（flix.toml のある所）
	Package   string // 依存の repo 名（既定 flix_game_engine）
	Mount     string // 空なら flix.toml の mount、無ければ repo 名
	EngineSrc string // 空でなければ fpkg の代わりにこのフォルダの .flix から engine の名前を読む
	Check     bool   // 書き換えずに、足りない所があれば exit 1
}

// Run は道具の入口。
func Run(out, errOut *strings.Builder, opts Options) (int, error) {
	if opts.Package == "" {
		opts.Package = "flix_game_engine"
	}
	dep, err := readDependency(filepath.Join(opts.Root, "flix.toml"), opts.Package)
	if err != nil {
		return 2, err
	}
	mount := opts.Mount
	if mount == "" {
		mount = dep.mount
	}
	if mount == "" {
		mount = opts.Package
	}
	var engineNames map[string]bool
	if opts.EngineSrc != "" {
		engineNames, err = namesFromDir(opts.EngineSrc)
	} else {
		fpkg := filepath.Join(opts.Root, "lib", "github", dep.owner, opts.Package, dep.version,
			fmt.Sprintf("%s-%s.fpkg", opts.Package, dep.version))
		engineNames, err = namesFromFpkg(fpkg)
	}
	if err != nil {
		return 2, err
	}
	files, err := gameFiles(opts.Root)
	if err != nil {
		return 2, err
	}
	sources := map[string]string{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return 2, err
		}
		sources[f] = string(b)
	}
	declared := map[string]bool{}
	for _, src := range sources {
		for name := range declaredNames(src) {
			declared[name] = true
		}
	}
	changed := 0
	for _, f := range files {
		next := Rewrite(fixEngineUses(sources[f], mount, engineNames, declared), mount, engineNames, declared)
		if next == sources[f] {
			continue
		}
		changed++
		rel, _ := filepath.Rel(opts.Root, f)
		if opts.Check {
			fmt.Fprintf(out, "[engine-uses] use が足りない: %s\n", rel)
			continue
		}
		if err := os.WriteFile(f, []byte(next), 0o644); err != nil {
			return 2, err
		}
		fmt.Fprintf(out, "[engine-uses] %s\n", rel)
	}
	if opts.Check && changed > 0 {
		fmt.Fprintf(out, "[engine-uses] %d 本に use が足りません。bin/fge engine-uses で足せます\n", changed)
		return 1, nil
	}
	if opts.Check {
		fmt.Fprintf(out, "[engine-uses] use は足りています (mount: %s)\n", mount)
		return 0, nil
	}
	fmt.Fprintf(out, "[engine-uses] %d 本を直しました (mount: %s)\n", changed, mount)
	return 0, nil
}

// dependency は flix.toml の依存 1 行の中身。
type dependency struct {
	owner, version, mount string
}

var depLine = regexp.MustCompile(`^\s*"github:([^/"]+)/([^"]+)"\s*=\s*(.*)$`)
var depVersion = regexp.MustCompile(`version\s*=\s*"([^"]+)"`)
var depMount = regexp.MustCompile(`mount\s*=\s*"([^"]+)"`)
var depBare = regexp.MustCompile(`^"([^"]+)"`)

// readDependency は flix.toml から repo 名が pkg の依存を探す。
func readDependency(path, pkg string) (dependency, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return dependency{}, err
	}
	for _, line := range strings.Split(string(b), "\n") {
		m := depLine.FindStringSubmatch(line)
		if m == nil || m[2] != pkg {
			continue
		}
		d := dependency{owner: m[1]}
		if v := depVersion.FindStringSubmatch(m[3]); v != nil {
			d.version = v[1]
		} else if v := depBare.FindStringSubmatch(strings.TrimSpace(m[3])); v != nil {
			d.version = v[1]
		}
		if v := depMount.FindStringSubmatch(m[3]); v != nil {
			d.mount = v[1]
		}
		return d, nil
	}
	return dependency{}, fmt.Errorf("%s に %s への依存がありません", path, pkg)
}

// gameFiles は src/ と test/ の .flix を並べる（決まった順）。
func gameFiles(root string) ([]string, error) {
	var files []string
	for _, sub := range []string{"src", "test"} {
		dir := filepath.Join(root, sub)
		if _, err := os.Stat(dir); err != nil {
			continue
		}
		err := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !d.IsDir() && strings.HasSuffix(p, ".flix") {
				files = append(files, p)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Strings(files)
	return files, nil
}

// namesFromFpkg は fpkg（.flix の zip）から木の一番外の pub 名を集める。
func namesFromFpkg(path string) (map[string]bool, error) {
	r, err := zip.OpenReader(path)
	if err != nil {
		return nil, fmt.Errorf("engine の fpkg が読めません (%v)。先に make check を 1 回回して依存を取ってきてください", err)
	}
	defer r.Close()
	names := map[string]bool{}
	for _, f := range r.File {
		if !strings.HasSuffix(f.Name, ".flix") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, err
		}
		b, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, err
		}
		for n := range PublicTopNames(string(b)) {
			names[n] = true
		}
	}
	return names, nil
}

// namesFromDir はフォルダの下の .flix から木の一番外の pub 名を集める。
func namesFromDir(dir string) (map[string]bool, error) {
	names := map[string]bool{}
	err := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(p, ".flix") {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		for n := range PublicTopNames(string(b)) {
			names[n] = true
		}
		return nil
	})
	return names, err
}

// declKeywords は名前を宣言する語。
var declKeywords = map[string]bool{
	"mod": true, "enum": true, "struct": true, "trait": true, "eff": true, "alias": true,
}

// PublicTopNames は、ブレースの外（木の一番外）にある pub 宣言の名前を返す。
// `pub mod Render.Layer` は Render を返す。
func PublicTopNames(src string) map[string]bool {
	toks := tokenize(src)
	names := map[string]bool{}
	for i, t := range toks {
		if t.depth != 0 || t.kind != tokIdent || !declKeywords[t.text] {
			continue
		}
		if !precededByPub(toks, i) || i+1 >= len(toks) || toks[i+1].kind != tokIdent {
			continue
		}
		names[toks[i+1].text] = true
	}
	return names
}

// precededByPub は宣言の語の前（`type alias` の type や sealed などの修飾を飛ばして）に pub があるか。
func precededByPub(toks []token, i int) bool {
	for j := i - 1; j >= 0 && j >= i-3; j-- {
		switch toks[j].text {
		case "pub":
			return true
		case "type", "sealed", "lawful", "restrictable", "unlawful":
			continue
		default:
			return false
		}
	}
	return false
}

// declaredNames はゲームのソースが宣言・import・use している名前（大文字で始まる物）を集める。
func declaredNames(src string) map[string]bool {
	toks := tokenize(src)
	names := map[string]bool{}
	for i, t := range toks {
		if t.kind != tokIdent {
			continue
		}
		switch {
		case declKeywords[t.text]:
			// `mod A.B` は A と B を宣言する。
			for j := i + 1; j < len(toks) && toks[j].kind == tokIdent; j++ {
				names[toks[j].text] = true
				if j+1 >= len(toks) || toks[j+1].text != "." {
					break
				}
				j++
			}
		case t.text == "case":
			// enum の `case A, B(Int32), C`。match の `case Color.Red =>` は宣言ではない。
			parens := 0
			for j := i + 1; j < len(toks) && toks[j].line == t.line; j++ {
				switch toks[j].text {
				case "(", "[":
					parens++
				case ")", "]":
					parens--
				}
				prev := toks[j-1].text
				if parens == 0 && toks[j].kind == tokIdent && (prev == "case" || prev == ",") &&
					(j+1 >= len(toks) || toks[j+1].text != ".") {
					names[toks[j].text] = true
				}
			}
		case t.text == "import" || (t.text == "use" && !isMountUse(toks, i)):
			for _, n := range importedNames(toks, i) {
				names[n] = true
			}
		}
	}
	return names
}

// importedNames は toks[i] の use / import が持ち込む名前（道の先頭ではなく、取り込まれる側）。
// `use A.B.c` は c、`use A.{B, C => D}` は B と D、`import java.awt.Color as JColor` は JColor。
func importedNames(toks []token, i int) []string {
	line := toks[i].line
	var out []string
	last := ""
	inBraces := false
	for j := i + 1; j < len(toks) && (toks[j].line == line || inBraces); j++ {
		t := toks[j]
		switch {
		case t.text == "{":
			inBraces = true
		case t.text == "}":
			inBraces = false
		case t.text == ";":
			j = len(toks)
		case t.kind == tokIdent && t.text == "as" && j+1 < len(toks):
			last = toks[j+1].text
			j++
		case t.kind == tokIdent:
			if inBraces {
				// `C => D` は D を残す。
				if j+2 < len(toks) && toks[j+1].text == "=" && toks[j+2].text == ">" {
					continue
				}
				out = append(out, t.text)
			} else {
				last = t.text
			}
		}
	}
	if last != "" && len(out) == 0 {
		out = append(out, last)
	}
	return out
}

// fixEngineUses は、engine の名前で始まる素の use（`use Color.darken`）に mount を足す。
func fixEngineUses(src, mount string, engineNames, declared map[string]bool) string {
	toks := tokenize(src)
	lines := strings.Split(src, "\n")
	for i, t := range toks {
		if t.kind != tokIdent || t.text != "use" || i+1 >= len(toks) || isMountUse(toks, i) {
			continue
		}
		head := toks[i+1]
		if head.kind != tokIdent || head.line != t.line || !engineNames[head.text] || declared[head.text] {
			continue
		}
		l := lines[t.line]
		at := strings.Index(l, "use "+head.text)
		if at < 0 {
			continue
		}
		lines[t.line] = l[:at] + "use " + mount + "::" + l[at+len("use "):]
	}
	return strings.Join(lines, "\n")
}

// isManagedUse は toks[i] の use が、この道具の置く `use mount::{A, B}` / `use mount::A` の形か
// （`use mount::Color.darken` のような道の長い use は人の書いた物として残す）。
func isManagedUse(toks []token, i int, mount string) bool {
	if !isMountUse(toks, i) || toks[i+1].text != mount || i+3 >= len(toks) {
		return false
	}
	next := toks[i+3]
	if next.text == "{" {
		return true
	}
	return next.kind == tokIdent && (i+4 >= len(toks) || toks[i+4].line != next.line)
}

// isMountUse は toks[i] の use が `use x::` の形か。
func isMountUse(toks []token, i int) bool {
	return i+2 < len(toks) && toks[i+1].kind == tokIdent && toks[i+2].text == "::"
}

func isUpper(s string) bool {
	return s != "" && s[0] >= 'A' && s[0] <= 'Z'
}

// scope は 1 つの mod（またはファイルの一番外）。
type scope struct {
	headerLine int    // `mod X {` の行（ファイルの一番外なら -1）
	indent     string // その中の行の字下げ
	used       map[string]bool
	useLine    int // 既にある `use <mount>::` の行（無ければ -1）
	useEnd     int // その use が続く最後の行
}

// skipAfter は、この語の直後の名前を参照として数えない語。
var skipAfter = map[string]bool{
	"mod": true, "enum": true, "struct": true, "trait": true, "eff": true, "alias": true,
	"import": true, "use": true,
}

// Rewrite は src の mod ごとに use を足した（または足し直した）ソースを返す。
func Rewrite(src, mount string, engineNames, declared map[string]bool) string {
	toks := tokenize(src)
	lines := strings.Split(src, "\n")
	root := &scope{headerLine: -1, used: map[string]bool{}, useLine: -1}
	scopes := []*scope{root}
	type frame struct {
		sc    *scope
		isMod bool
	}
	stack := []frame{{root, true}}
	current := func() *scope {
		for k := len(stack) - 1; k >= 0; k-- {
			if stack[k].isMod {
				return stack[k].sc
			}
		}
		return root
	}
	pendingMod := -1 // `mod` を見てから `{` までの行
	skipLine := -1   // use / import の行（その行の名前は数えない）
	for i, t := range toks {
		switch {
		case t.kind == tokIdent && t.text == "mod":
			pendingMod = t.line
		case t.text == "{":
			if pendingMod >= 0 {
				sc := &scope{headerLine: t.line, indent: indentOf(lines[pendingMod]) + "    ",
					used: map[string]bool{}, useLine: -1}
				scopes = append(scopes, sc)
				stack = append(stack, frame{sc, true})
				pendingMod = -1
			} else {
				stack = append(stack, frame{nil, false})
			}
		case t.text == "}":
			if len(stack) > 1 {
				stack = stack[:len(stack)-1]
			}
		case t.kind == tokIdent && (t.text == "use" || t.text == "import"):
			skipLine = t.line
			if t.text == "use" && isManagedUse(toks, i, mount) {
				sc := current()
				sc.useLine = t.line
				sc.useEnd = useEndLine(toks, i)
			}
		case t.kind == tokIdent && isUpper(t.text):
			if t.line == skipLine || pendingMod >= 0 {
				continue
			}
			if i > 0 && (toks[i-1].text == "." || toks[i-1].text == "::" || toks[i-1].text == "@" ||
				(toks[i-1].kind == tokIdent && skipAfter[toks[i-1].text])) {
				continue
			}
			if engineNames[t.text] && !declared[t.text] {
				current().used[t.text] = true
			}
		}
	}
	// 下の行から直す（上の行番号がずれないように）。
	sort.Slice(scopes, func(a, b int) bool { return scopes[a].headerLine > scopes[b].headerLine })
	for _, sc := range scopes {
		if sc.useLine >= 0 {
			// 既にある行の名前も残す（字句で拾えない使い方を人が足していることがある）。
			for _, n := range namesInUse(strings.Join(lines[sc.useLine:sc.useEnd+1], "\n"), mount) {
				sc.used[n] = true
			}
		}
		if len(sc.used) == 0 {
			continue
		}
		indent := sc.indent
		if sc.useLine >= 0 {
			indent = indentOf(lines[sc.useLine])
		}
		block := formatUse(indent, mount, sc.used)
		if sc.useLine >= 0 {
			if strings.Join(lines[sc.useLine:sc.useEnd+1], "\n") == strings.Join(block, "\n") {
				continue
			}
			lines = splice(lines, sc.useLine, sc.useEnd+1, block)
			continue
		}
		at := sc.headerLine + 1
		if sc.headerLine < 0 {
			at = firstCodeLine(lines)
		} else if at < len(lines) && strings.TrimSpace(lines[at]) == "" {
			at++ // `mod X {` の直後の空行は残し、その後ろに置く
		}
		insert := append([]string{}, block...)
		if at < len(lines) {
			next := strings.TrimSpace(lines[at])
			if next != "" && !strings.HasPrefix(next, "use ") {
				insert = append(insert, "")
			}
		}
		lines = splice(lines, at, at, insert)
	}
	return strings.Join(lines, "\n")
}

// useEndLine は toks[i] から始まる use の最後の行（ブレースが閉じる行）。
func useEndLine(toks []token, i int) int {
	depth := 0
	for j := i; j < len(toks); j++ {
		switch toks[j].text {
		case "{":
			depth++
		case "}":
			depth--
			if depth == 0 {
				return toks[j].line
			}
		}
		if depth == 0 && j > i+2 && (j+1 >= len(toks) || toks[j+1].line != toks[j].line) {
			return toks[j].line
		}
	}
	return toks[i].line
}

var useNameRe = regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*`)

// namesInUse は `use mount::{A, B}` の A・B を返す。
func namesInUse(text, mount string) []string {
	idx := strings.Index(text, mount+"::")
	if idx < 0 {
		return nil
	}
	body := text[idx+len(mount)+2:]
	var out []string
	for _, n := range useNameRe.FindAllString(body, -1) {
		out = append(out, n)
	}
	return out
}

// formatUse は use の行（長ければ折り返した複数行）を作る。
func formatUse(indent, mount string, used map[string]bool) []string {
	var names []string
	for n := range used {
		names = append(names, n)
	}
	sort.Strings(names)
	if len(names) == 1 {
		return []string{indent + "use " + mount + "::" + names[0]}
	}
	one := indent + "use " + mount + "::{" + strings.Join(names, ", ") + "}"
	if len(one) <= 100 {
		return []string{one}
	}
	out := []string{indent + "use " + mount + "::{"}
	line := indent + "    "
	for k, n := range names {
		piece := n
		if k < len(names)-1 {
			piece += ","
		}
		if len(line)+len(piece)+1 > 100 && strings.TrimSpace(line) != "" {
			out = append(out, strings.TrimRight(line, " "))
			line = indent + "    "
		}
		line += piece + " "
	}
	out = append(out, strings.TrimRight(line, " "))
	out = append(out, indent+"}")
	return out
}

func splice(lines []string, from, to int, insert []string) []string {
	out := append([]string{}, lines[:from]...)
	out = append(out, insert...)
	return append(out, lines[to:]...)
}

func indentOf(line string) string {
	return line[:len(line)-len(strings.TrimLeft(line, " \t"))]
}

// firstCodeLine はファイルの頭の注釈と空行を飛ばした最初の行。
func firstCodeLine(lines []string) int {
	inBlock := false
	for k, l := range lines {
		s := strings.TrimSpace(l)
		switch {
		case inBlock:
			if strings.Contains(s, "*/") {
				inBlock = false
			}
		case s == "" || strings.HasPrefix(s, "//"):
		case strings.HasPrefix(s, "/*"):
			inBlock = !strings.Contains(s, "*/")
		default:
			return k
		}
	}
	return len(lines)
}
