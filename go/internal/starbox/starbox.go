package starbox

// starbox — 台本（Starlark）を走らせる箱。px（*.px.star）と snd（*.snd.star）が同じ箱を使う。
//
// 箱の決まり: ファイル・ネット・時刻には触れない。load は台本と同じフォルダと、隣の tools/ の .star だけ。
// 手数（Starlark の計算の歩数）に上限があり、超えたら止まる。書いた物は呼ぶ側がメモリに集めて検査を通す。
// 台本の中のパスは台本のフォルダが起点（"//" で始めると作業場の根から）。書き出し先は assets/ の外だけ（OutPath）。
// WhyNot: Python の台本をやめたのは、OS ごとの python と libm で結果が変わりうるのと、
// 外の物に何でも触れて、道具の検査を通らない書き出しが作れてしまうため。

import (
	"bytes"
	"fmt"
	"io"
	"math"
	"os"
	pathpkg "path"
	"path/filepath"
	"strconv"
	"strings"

	"go.starlark.net/starlark"
	"go.starlark.net/syntax"
)

const (
	DefaultMaxSteps = 500_000_000 // 1 本（load した物も 1 本ずつ）の手数の上限
	AdviceLines     = 600         // 台本 1 本の行数の目安
)

// Options は台本の走らせ方。
type Options struct {
	MaxSteps uint64    // 0 は既定（5 億手）
	Stderr   io.Writer // print の行き先（nil は捨てる）
}

type module struct {
	globals starlark.StringDict
	err     error
	loading bool
}

// Box は台本 1 本（と load した物）を走らせる箱。
type Box struct {
	WorkRoot  string
	ScriptDir string // 台本のフォルダ（WorkRoot からの相対。台本の中のパスの起点）
	Opt       Options
	Advice    []string // 文面の目安（行数・while・使われない関数）
	Steps     uint64   // 使った手数（load した物を含む）
	allowed   []string
	modules   map[string]*module
	predecl   starlark.StringDict
}

// Open は台本の場所を確かめて箱を作り、台本の絶対パスを返す。suffix は台本の拡張子（".px.star" など）。
func Open(workRoot, script, suffix string, opt Options) (*Box, string, error) {
	full := script
	if !filepath.IsAbs(full) {
		full = filepath.Join(workRoot, script)
	}
	full = filepath.Clean(full)
	if !strings.HasSuffix(full, suffix) {
		return nil, "", fmt.Errorf("%s: 台本の名前は <名前>%s", script, suffix)
	}
	if opt.MaxSteps == 0 {
		opt.MaxSteps = DefaultMaxSteps
	}
	dir := filepath.Dir(full)
	b := &Box{WorkRoot: workRoot, ScriptDir: filepath.ToSlash(rel(workRoot, dir)), Opt: opt,
		allowed: []string{dir, filepath.Join(filepath.Dir(dir), "tools")}, modules: map[string]*module{}}
	return b, full, nil
}

// Run は台本を predeclared（台本から呼べる名前）で走らせる。load の先も同じ名前で走る。
func (b *Box) Run(full string, predeclared starlark.StringDict) error {
	b.predecl = predeclared
	_, err := b.exec(full)
	return err
}

// exec は 1 本を走らせる（load の先も同じ道）。
func (b *Box) exec(path string) (starlark.StringDict, error) {
	if m, ok := b.modules[path]; ok {
		if m.loading {
			return nil, fmt.Errorf("load が輪になっている: %s", b.Rel(path))
		}
		return m.globals, m.err
	}
	m := &module{loading: true}
	b.modules[path] = m
	src, err := os.ReadFile(path)
	if err != nil {
		m.err = err
		m.loading = false
		return nil, err
	}
	b.Advice = append(b.Advice, SourceAdvice(b.Rel(path), src)...)
	if len(b.modules) == 1 {
		// 止めずに advice（試しに 1 つ外した時に gen が通らないと試しにくい）
		if msg := UnusedFuncs(path, src); msg != "" {
			b.Advice = append(b.Advice, fmt.Sprintf("%s: %s", b.Rel(path), msg))
		}
	}
	thread := &starlark.Thread{Name: b.Rel(path), Load: func(th *starlark.Thread, mod string) (starlark.StringDict, error) {
		target, err := b.resolveLoad(path, mod)
		if err != nil {
			return nil, err
		}
		return b.exec(target)
	}}
	thread.Print = func(_ *starlark.Thread, msg string) {
		if b.Opt.Stderr != nil {
			fmt.Fprintln(b.Opt.Stderr, msg)
		}
	}
	thread.SetMaxExecutionSteps(b.Opt.MaxSteps)
	thread.OnMaxSteps = func(th *starlark.Thread) {
		th.Cancel(fmt.Sprintf("手数の上限（%d 手）を超えた（ループが終わらないか、手打ちが多すぎる。op へ寄せる）", b.Opt.MaxSteps))
	}
	g, err := starlark.ExecFileOptions(FileOptions, thread, b.Rel(path), src, b.predecl)
	b.Steps += thread.ExecutionSteps()
	m.loading = false
	if err != nil {
		if ee, ok := err.(*starlark.EvalError); ok {
			err = fmt.Errorf("%s", ee.Backtrace())
		}
		if strings.Contains(err.Error(), "cannot reassign") {
			// Starlark の仕様: 一番外の名前は 1 度しか代入できない（一番外の for の変数を 2 つのループで使うのもこれ）
			err = fmt.Errorf("%v\n  → 一番外（def の外）では同じ名前に 2 度代入できない。ループや組み立てを def の中に入れて呼ぶ", err)
		}
		m.err = err
		return nil, err
	}
	m.globals = g
	return g, nil
}

// resolveLoad は load の先を決める。台本のフォルダか隣の tools/ の .star だけ。
func (b *Box) resolveLoad(from, mod string) (string, error) {
	if !strings.HasSuffix(mod, ".star") || filepath.IsAbs(mod) {
		return "", fmt.Errorf("load %q: 相対のパスで .star を指す", mod)
	}
	target := filepath.Clean(filepath.Join(filepath.Dir(from), filepath.FromSlash(mod)))
	real, err := filepath.EvalSymlinks(target)
	if err != nil {
		return "", fmt.Errorf("load %q: %v", mod, err)
	}
	for _, a := range b.allowed {
		ar, err := filepath.EvalSymlinks(a)
		if err != nil {
			continue
		}
		if filepath.Dir(real) == ar {
			return target, nil
		}
	}
	return "", fmt.Errorf("load %q: 台本と同じフォルダか隣の tools/ の .star だけ読める", mod)
}

// Rel は WorkRoot からの相対（/ 区切り）。
func (b *Box) Rel(p string) string { return filepath.ToSlash(rel(b.WorkRoot, p)) }

func rel(root, p string) string {
	if r, err := filepath.Rel(root, p); err == nil && !strings.HasPrefix(r, "..") {
		return r
	}
	return p
}

// ScriptPath は台本の中のパスを WorkRoot からのパスにする: "//" で始まれば作業場の根から、ほかは台本のフォルダから。
func (b *Box) ScriptPath(p string) string {
	if strings.HasPrefix(p, "//") {
		return p[2:]
	}
	if filepath.IsAbs(p) {
		return p // OutPath が断る
	}
	return pathpkg.Join(b.ScriptDir, p)
}

// OutPath は書き出し先を確かめる（WorkRoot の中・assets/ の外・決めた拡張子）。path は台本の中の書き方。
func (b *Box) OutPath(fn, path, suffix string) (string, error) {
	clean, err := b.inside(fn, path)
	if err != nil {
		return "", err
	}
	if IsUnderAssets(clean) {
		return "", fmt.Errorf("%s: %q は assets/ の下（AI が作る物は atelier/ か debug/ へ）", fn, path)
	}
	if !strings.HasSuffix(clean, suffix) {
		return "", fmt.Errorf("%s: %q は %s で終わる名前にする", fn, path, suffix)
	}
	return clean, nil
}

// ReadPath は読むだけの Doc の場所を確かめる（WorkRoot の中・.json だけ）。読めるのは作業場の Doc だけで、
// assets/ の下も読める（つまみや譜面の正は assets/ にある）。
func (b *Box) ReadPath(fn, path string) (string, error) {
	clean, err := b.inside(fn, path)
	if err != nil {
		return "", err
	}
	if !strings.HasSuffix(clean, ".json") {
		return "", fmt.Errorf("%s: %q は .json だけ読める", fn, path)
	}
	return clean, nil
}

func (b *Box) inside(fn, path string) (string, error) {
	full := b.ScriptPath(path)
	clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(full)))
	if filepath.IsAbs(full) || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("%s: %q は作業場の中の相対のパスで書く（台本のフォルダが起点・// で始めると作業場の根から）", fn, path)
	}
	return clean, nil
}

// IsUnderAssets は path が（./ や ../ で回り道しても）ゲームの assets/ の下を指すか。
func IsUnderAssets(path string) bool {
	clean := filepath.ToSlash(filepath.Clean(path))
	return clean == "assets" || strings.HasPrefix(clean, "assets/") || strings.Contains(clean, "/assets/") || strings.HasPrefix(clean, "../")
}

// FileOptions は台本の文法（while と一番外の if・for を許す）。
var FileOptions = &syntax.FileOptions{While: true, TopLevelControl: true}

// ---------------------------------------------------------------- 決まり（最初は advice）

// SourceAdvice は台本の文面の目安（行数・while）。
func SourceAdvice(name string, src []byte) []string {
	var out []string
	if n := bytes.Count(src, []byte("\n")) + 1; n > AdviceLines {
		out = append(out, fmt.Sprintf("%s: %d 行（%d 行まで）。繰り返しの型は op へ寄せる", name, n, AdviceLines))
	}
	f, err := FileOptions.Parse(name, src, 0)
	if err != nil {
		return out // 書き損じは走らせた時に行番号つきで止まる
	}
	whiles := 0
	var first syntax.Position
	syntax.Walk(f, func(n syntax.Node) bool {
		if w, ok := n.(*syntax.WhileStmt); ok {
			if whiles == 0 {
				first, _ = w.Span()
			}
			whiles++
		}
		return true
	})
	if whiles > 0 {
		out = append(out, fmt.Sprintf("%s:%d: while が %d か所（range に直す）", name, first.Line, whiles))
	}
	return out
}

// UnusedFuncs は台本の一番外の def で、どこからも呼ばれない物を挙げる（止める）。
func UnusedFuncs(path string, src []byte) string {
	f, err := FileOptions.Parse(path, src, 0)
	if err != nil {
		return ""
	}
	uses := map[string]int{}
	syntax.Walk(f, func(n syntax.Node) bool {
		if id, ok := n.(*syntax.Ident); ok {
			uses[id.Name]++
		}
		return true
	})
	var unused []string
	for _, s := range f.Stmts {
		if d, ok := s.(*syntax.DefStmt); ok && uses[d.Name.Name] <= 1 {
			pos, _ := d.Span()
			unused = append(unused, fmt.Sprintf("%s（%d 行）", d.Name.Name, pos.Line))
		}
	}
	if len(unused) == 0 {
		return ""
	}
	return "使われない関数がある: " + strings.Join(unused, "・") + "（使わないなら消す）"
}

// ---------------------------------------------------------------- JSON

// JSON は値を JSON にする（Python の json.dump(ensure_ascii=False) と同じ並び。indent < 0 は 1 行）。
func JSON(v starlark.Value, indent int) (string, error) {
	var b strings.Builder
	err := jsonTo(&b, v, indent, 0)
	return b.String(), err
}

func jsonTo(b *strings.Builder, v starlark.Value, indent, level int) error {
	open := func(c byte, n int, item func(i int) error, close byte) error {
		b.WriteByte(c)
		if n == 0 {
			b.WriteByte(close)
			return nil
		}
		sep := ", "
		pad := ""
		if indent >= 0 {
			sep = ","
			pad = "\n" + strings.Repeat(" ", indent*(level+1))
		}
		for i := 0; i < n; i++ {
			if i > 0 {
				b.WriteString(sep)
			}
			b.WriteString(pad)
			if err := item(i); err != nil {
				return err
			}
		}
		if indent >= 0 {
			b.WriteString("\n" + strings.Repeat(" ", indent*level))
		}
		b.WriteByte(close)
		return nil
	}
	switch x := v.(type) {
	case starlark.NoneType:
		b.WriteString("null")
	case starlark.Bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case starlark.Int:
		b.WriteString(x.String())
	case starlark.Float:
		s, err := PyFloatRepr(float64(x))
		if err != nil {
			return err
		}
		b.WriteString(s)
	case starlark.String:
		PyJSONString(b, string(x))
	case starlark.Indexable: // list・tuple
		return open('[', x.Len(), func(i int) error { return jsonTo(b, x.Index(i), indent, level+1) }, ']')
	case *starlark.Dict:
		items := x.Items()
		return open('{', len(items), func(i int) error {
			k, ok := items[i][0].(starlark.String)
			if !ok {
				return fmt.Errorf("dict の鍵は文字列（got %s）", items[i][0].Type())
			}
			PyJSONString(b, string(k))
			b.WriteString(": ")
			return jsonTo(b, items[i][1], indent, level+1)
		}, '}')
	default:
		return fmt.Errorf("JSON に書けない値（%s）", v.Type())
	}
	return nil
}

// PyFloatRepr は Python の repr(float)（最短の桁・整数なら .0・指数は 1e-05 の形）。
func PyFloatRepr(f float64) (string, error) {
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return "", fmt.Errorf("JSON に書けない数 %v", f)
	}
	sign := ""
	if math.Signbit(f) {
		sign = "-"
		f = -f
	}
	if f == 0 {
		return sign + "0.0", nil
	}
	e := strconv.FormatFloat(f, 'e', -1, 64) // d.ddde±XX
	mant, expStr, _ := strings.Cut(e, "e")
	exp, _ := strconv.Atoi(expStr)
	digits := strings.Replace(mant, ".", "", 1)
	decpt := exp + 1
	if decpt <= -4 || decpt > 16 {
		m := digits[:1]
		if len(digits) > 1 {
			m += "." + digits[1:]
		}
		es := "+"
		if exp < 0 {
			es = "-"
			exp = -exp
		}
		return fmt.Sprintf("%s%se%s%02d", sign, m, es, exp), nil
	}
	switch {
	case decpt <= 0:
		return sign + "0." + strings.Repeat("0", -decpt) + digits, nil
	case decpt >= len(digits):
		return sign + digits + strings.Repeat("0", decpt-len(digits)) + ".0", nil
	default:
		return sign + digits[:decpt] + "." + digits[decpt:], nil
	}
}

// PyJSONString は json.dumps(s, ensure_ascii=False) の文字列。
func PyJSONString(b *strings.Builder, s string) {
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
				fmt.Fprintf(b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}
