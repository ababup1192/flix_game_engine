package px

// 台本（<名前>.px.star）: 繰り返しや変化が要る絵の指定を、道具を関数として呼ぶ Starlark で書く。
//
//	fge px gen <名前>.px.star     台本を走らせ、台本が書いた pxsrc・JSON をファイルへ書く
//	fge px build <名前>.px.star   同じことをメモリの中でして、書いた pxsrc を全部 build する（pxsrc は書かない）
//
// 台本から呼べる物は px（write_spec・write_json・rng・hash01・noise1・round）と math（star_math.go。正しく丸めた値）だけ。
// ファイル・ネット・時刻には触れない。load は台本と同じフォルダと、隣の tools/ の .star だけ。
// 手数（Starlark の計算の歩数）に上限があり、超えたら止まる。
// WhyNot: Python の台本をやめたのは、OS ごとの python と libm で結果が変わりうるのと、
// 外の物に何でも触れて、道具の検査（spec・門）を通らない書き出しが作れてしまうため。

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"go.starlark.net/starlark"
	"go.starlark.net/starlarkstruct"
	"go.starlark.net/syntax"
)

const (
	starDefaultMaxSteps = 500_000_000 // 1 本（load した物も 1 本ずつ）の手数の上限
	starAdviceLines     = 600         // 台本 1 本の行数の目安
	starAdviceSpecBytes = 500 * 1024  // 書き出す pxsrc 1 本の大きさの目安
	starAdvicePuts      = 200         // 1 つの部品の put の画素の目安
)

// starOptions は台本の走らせ方。
type starOptions struct {
	MaxSteps uint64    // 0 は既定（5 億手）
	Stderr   io.Writer // print の行き先（nil は捨てる）
}

// starFile は台本が書いた 1 本。
type starFile struct {
	Path string // workRoot からの相対
	Data []byte
	Spec bool // px.write_spec で書いた（build の対象）
}

// starResult は台本を走らせた結果。
type starResult struct {
	Files  []starFile
	Advice []string
	Steps  uint64
}

// runStar は台本を走らせ、書いた物をメモリに集める（ファイルへは書かない）。
func runStar(workRoot, script string, opt starOptions) (*starResult, error) {
	full := script
	if !filepath.IsAbs(full) {
		full = filepath.Join(workRoot, script)
	}
	full = filepath.Clean(full)
	if !strings.HasSuffix(full, ".px.star") {
		return nil, fmt.Errorf("%s: 台本の名前は <名前>.px.star", script)
	}
	if opt.MaxSteps == 0 {
		opt.MaxSteps = starDefaultMaxSteps
	}
	dir := filepath.Dir(full)
	allowed := []string{dir, filepath.Join(filepath.Dir(dir), "tools")}
	st := &starState{workRoot: workRoot, opt: opt, allowed: allowed, modules: map[string]*starModule{}, written: map[string]int{}, noise: map[string][]float64{}, math: newStarMath()}
	if _, err := st.exec(full); err != nil {
		return nil, err
	}
	res := &starResult{Files: st.files, Steps: st.steps}
	res.Advice = append(st.advice, starOutputAdvice(st.files)...)
	return res, nil
}

type starModule struct {
	globals starlark.StringDict
	err     error
	loading bool
}

type starState struct {
	workRoot string
	opt      starOptions
	allowed  []string
	modules  map[string]*starModule
	files    []starFile
	written  map[string]int // パス → files の番号（同じパスへ 2 度書いたら後の物）
	advice   []string
	steps    uint64
	noise    map[string][]float64
	math     *starlarkstruct.Module
}

var starFileOptions = &syntax.FileOptions{While: true, TopLevelControl: true}

// exec は 1 本を走らせる（load の先も同じ道）。
func (st *starState) exec(path string) (starlark.StringDict, error) {
	if m, ok := st.modules[path]; ok {
		if m.loading {
			return nil, fmt.Errorf("load が輪になっている: %s", st.rel(path))
		}
		return m.globals, m.err
	}
	m := &starModule{loading: true}
	st.modules[path] = m
	src, err := os.ReadFile(path)
	if err != nil {
		m.err = err
		m.loading = false
		return nil, err
	}
	st.advice = append(st.advice, starSourceAdvice(st.rel(path), src)...)
	if len(st.modules) == 1 {
		if msg := starUnusedFuncs(path, src); msg != "" {
			m.loading = false
			m.err = fmt.Errorf("%s: %s", st.rel(path), msg)
			return nil, m.err
		}
	}
	thread := &starlark.Thread{Name: st.rel(path), Load: func(th *starlark.Thread, module string) (starlark.StringDict, error) {
		target, err := st.resolveLoad(path, module)
		if err != nil {
			return nil, err
		}
		return st.exec(target)
	}}
	thread.Print = func(_ *starlark.Thread, msg string) {
		if st.opt.Stderr != nil {
			fmt.Fprintln(st.opt.Stderr, msg)
		}
	}
	thread.SetMaxExecutionSteps(st.opt.MaxSteps)
	thread.OnMaxSteps = func(th *starlark.Thread) {
		th.Cancel(fmt.Sprintf("手数の上限（%d 手）を超えた（ループが終わらないか、画素ごとの手打ちが多すぎる。op へ寄せる）", st.opt.MaxSteps))
	}
	predeclared := starlark.StringDict{"px": st.pxModule(), "math": st.math}
	g, err := starlark.ExecFileOptions(starFileOptions, thread, st.rel(path), src, predeclared)
	st.steps += thread.ExecutionSteps()
	m.loading = false
	if err != nil {
		if ee, ok := err.(*starlark.EvalError); ok {
			err = fmt.Errorf("%s", ee.Backtrace())
		}
		m.err = err
		return nil, err
	}
	m.globals = g
	return g, nil
}

// resolveLoad は load の先を決める。台本のフォルダか隣の tools/ の .star だけ。
func (st *starState) resolveLoad(from, module string) (string, error) {
	if !strings.HasSuffix(module, ".star") || filepath.IsAbs(module) {
		return "", fmt.Errorf("load %q: 相対のパスで .star を指す", module)
	}
	target := filepath.Clean(filepath.Join(filepath.Dir(from), filepath.FromSlash(module)))
	real, err := filepath.EvalSymlinks(target)
	if err != nil {
		return "", fmt.Errorf("load %q: %v", module, err)
	}
	for _, a := range st.allowed {
		ar, err := filepath.EvalSymlinks(a)
		if err != nil {
			continue
		}
		if filepath.Dir(real) == ar {
			return target, nil
		}
	}
	return "", fmt.Errorf("load %q: 台本と同じフォルダか隣の tools/ の .star だけ読める", module)
}

func (st *starState) rel(p string) string { return filepath.ToSlash(rel(st.workRoot, p)) }

// ---------------------------------------------------------------- px の関数

func (st *starState) pxModule() *starlarkstruct.Module {
	return &starlarkstruct.Module{Name: "px", Members: starlark.StringDict{
		"write_spec": starlark.NewBuiltin("px.write_spec", st.writeSpec),
		"write_json": starlark.NewBuiltin("px.write_json", st.writeJSON),
		"rng":        starlark.NewBuiltin("px.rng", starRng),
		"hash01":     starlark.NewBuiltin("px.hash01", starHash01),
		"noise1":     starlark.NewBuiltin("px.noise1", st.starNoise1),
		"round":      starlark.NewBuiltin("px.round", starRound),
	}}
}

// outPath は書き出し先を確かめる（workRoot の中・assets/ の外・決めた拡張子）。
func (st *starState) outPath(fn, path, suffix string) (string, error) {
	clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(path)))
	if filepath.IsAbs(path) || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("%s: %q は作業場の中の相対のパスで書く", fn, path)
	}
	if isUnderAssets(clean) {
		return "", fmt.Errorf("%s: %q は assets/ の下（AI が作る物は atelier/ か debug/ へ）", fn, path)
	}
	if !strings.HasSuffix(clean, suffix) {
		return "", fmt.Errorf("%s: %q は %s で終わる名前にする", fn, path, suffix)
	}
	return clean, nil
}

func (st *starState) put(path string, data []byte, spec bool) {
	if i, ok := st.written[path]; ok {
		st.files[i] = starFile{Path: path, Data: data, Spec: spec}
		return
	}
	st.written[path] = len(st.files)
	st.files = append(st.files, starFile{Path: path, Data: data, Spec: spec})
}

// jsonArgs は write_spec・write_json に共通の引数（path・value・style・indent）。
func jsonArgs(b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (string, starlark.Value, []byte, error) {
	var path, style string
	var value, indent starlark.Value = nil, starlark.None
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path, "value", &value, "style?", &style, "indent?", &indent); err != nil {
		return "", nil, nil, err
	}
	ind := -1
	if indent != starlark.None {
		n, err := starlark.AsInt32(indent)
		if err != nil || n < 0 {
			return "", nil, nil, fmt.Errorf("%s: indent は 0 以上の整数か None", b.Name())
		}
		ind = n
	}
	var out []byte
	switch style {
	case "python": // json.dump(value, ensure_ascii=False, indent=indent) と同じバイト（写しの間だけ）
		s, err := starJSON(value, ind)
		if err != nil {
			return "", nil, nil, fmt.Errorf("%s: %v", b.Name(), err)
		}
		out = []byte(s)
	case "":
		if ind < 0 {
			ind = 1
		}
		s, err := starJSON(value, ind)
		if err != nil {
			return "", nil, nil, fmt.Errorf("%s: %v", b.Name(), err)
		}
		out = []byte(s + "\n")
	default:
		return "", nil, nil, fmt.Errorf("%s: style は \"python\" か省く", b.Name())
	}
	return path, value, out, nil
}

func (st *starState) writeSpec(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	path, value, data, err := jsonArgs(b, args, kwargs)
	if err != nil {
		return nil, err
	}
	if _, ok := value.(*starlark.Dict); !ok {
		return nil, fmt.Errorf("%s: 値は dict（got %s）", b.Name(), value.Type())
	}
	clean, err := st.outPath(b.Name(), path, ".pxsrc.json")
	if err != nil {
		return nil, err
	}
	v, err := pxlib.DecodeOrdered(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	r := &reader{}
	parseSpec(r, v.(*pxlib.Obj))
	if len(r.probs) > 0 {
		return nil, fmt.Errorf("%s(%q): 指定の書き損じ\n%v", b.Name(), path, dedupe(r.probs))
	}
	st.put(clean, data, true)
	return starlark.None, nil
}

func (st *starState) writeJSON(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	path, _, data, err := jsonArgs(b, args, kwargs)
	if err != nil {
		return nil, err
	}
	clean, err := st.outPath(b.Name(), path, ".json")
	if err != nil {
		return nil, err
	}
	if strings.HasSuffix(clean, ".pxsrc.json") {
		return nil, fmt.Errorf("%s: pxsrc は px.write_spec で書く（spec の検査を通す）", b.Name())
	}
	st.put(clean, data, false)
	return starlark.None, nil
}

func starInt(name string, v starlark.Value) (*big.Int, error) {
	i, ok := v.(starlark.Int)
	if !ok {
		return nil, fmt.Errorf("%s: 整数を渡す（got %s）", name, v.Type())
	}
	return i.BigInt(), nil
}

// starHash01 は px.hash01(x, y, seed=0): 整数 3 つから 0..1 の値（pxlib.py の hash01 と同じ式）。
func starHash01(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var x, y starlark.Value
	var seed starlark.Value = starlark.MakeInt(0)
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "x", &x, "y", &y, "seed?", &seed); err != nil {
		return nil, err
	}
	var w [3]uint64
	for i, v := range []starlark.Value{x, y, seed} {
		n, err := starInt(b.Name(), v)
		if err != nil {
			return nil, err
		}
		// 2^32 で割った余り（負の数も Python の & 0xffffffff と同じ）
		w[i] = new(big.Int).And(n, big.NewInt(0xffffffff)).Uint64()
	}
	return starlark.Float(pyHash01(w[0], w[1], w[2])), nil
}

func pyHash01(x, y, seed uint64) float64 {
	h := (x*374761393 + y*668265263 + seed*2246822519) & 0xffffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0xffffffff
	return float64((h^(h>>16))&0xffff) / 65535.0
}

// starNoise1 は px.noise1(x, seed=0): 1 次元のなめらかな揺らぎ 0..1（pxlib.py の noise1 と同じ。種ごとに 64 点）。
func (st *starState) starNoise1(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var xv starlark.Value
	var seed starlark.Value = starlark.MakeInt(0)
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "x", &xv, "seed?", &seed); err != nil {
		return nil, err
	}
	x, ok := starlark.AsFloat(xv)
	if !ok {
		return nil, fmt.Errorf("%s: x は数（got %s）", b.Name(), xv.Type())
	}
	s, err := starInt(b.Name(), seed)
	if err != nil {
		return nil, err
	}
	pts, ok := st.noise[s.String()]
	if !ok {
		r := newPyRandom(s)
		pts = make([]float64, 64)
		for i := range pts {
			pts[i] = r.random()
		}
		st.noise[s.String()] = pts
	}
	fl := math.Floor(x)
	i := int(math.Mod(fl, 63))
	if i < 0 {
		i += 63
	}
	// float64(…) で包んで a*b+c を FMA にまとめさせない（arm64 だけ答えが変わる）
	f := x - fl
	f = float64(f*f) * (3 - float64(2*f))
	return starlark.Float(pts[i] + float64((pts[i+1]-pts[i])*f)), nil
}

// starRound は px.round(x, nd=None): Python の round（ちょうど半分は偶数へ）。nd を省くと整数を返す。
func starRound(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var xv starlark.Value
	var nd starlark.Value = starlark.None
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "x", &xv, "nd?", &nd); err != nil {
		return nil, err
	}
	if i, ok := xv.(starlark.Int); ok {
		return i, nil
	}
	x, ok := xv.(starlark.Float)
	if !ok {
		return nil, fmt.Errorf("%s: x は数（got %s）", b.Name(), xv.Type())
	}
	if nd == starlark.None {
		return starlark.NumberToInt(starlark.Float(pyRoundHalfEven(float64(x))))
	}
	n, err := starlark.AsInt32(nd)
	if err != nil || n < 0 {
		return nil, fmt.Errorf("%s: nd は 0 以上の整数", b.Name())
	}
	return starlark.Float(pyRoundDigits(float64(x), n)), nil
}

// starRngValue は px.rng(seed) が返す乱数（random()・uniform(a, b)・randint(a, b)）。
type starRngValue struct {
	r      *pyRandom
	frozen bool
}

func starRng(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var seed starlark.Value
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "seed", &seed); err != nil {
		return nil, err
	}
	s, err := starInt(b.Name(), seed)
	if err != nil {
		return nil, err
	}
	return &starRngValue{r: newPyRandom(s)}, nil
}

func (v *starRngValue) String() string       { return "<px.rng>" }
func (v *starRngValue) Type() string         { return "px.rng" }
func (v *starRngValue) Freeze()              { v.frozen = true }
func (v *starRngValue) Truth() starlark.Bool { return true }
func (v *starRngValue) Hash() (uint32, error) {
	return 0, fmt.Errorf("px.rng は dict の鍵にできない")
}
func (v *starRngValue) AttrNames() []string { return []string{"randint", "random", "uniform"} }

func (v *starRngValue) Attr(name string) (starlark.Value, error) {
	use := func() error {
		if v.frozen {
			return fmt.Errorf("px.rng: 読み込みの済んだ台本の乱数は進められない（関数の中で px.rng を作る）")
		}
		return nil
	}
	switch name {
	case "random":
		return starlark.NewBuiltin("random", func(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			if err := starlark.UnpackArgs(b.Name(), args, kwargs); err != nil {
				return nil, err
			}
			if err := use(); err != nil {
				return nil, err
			}
			return starlark.Float(v.r.random()), nil
		}), nil
	case "uniform":
		return starlark.NewBuiltin("uniform", func(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var a, c starlark.Value
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "a", &a, "b", &c); err != nil {
				return nil, err
			}
			fa, ok1 := starlark.AsFloat(a)
			fc, ok2 := starlark.AsFloat(c)
			if !ok1 || !ok2 {
				return nil, fmt.Errorf("uniform: a と b は数")
			}
			if err := use(); err != nil {
				return nil, err
			}
			return starlark.Float(fa + float64((fc-fa)*v.r.random())), nil // FMA にまとめさせない
		}), nil
	case "randint":
		return starlark.NewBuiltin("randint", func(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var a, c int
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "a", &a, "b", &c); err != nil {
				return nil, err
			}
			width := int64(c) - int64(a) + 1
			if width <= 0 || width > 1<<32 {
				return nil, fmt.Errorf("randint: a ≤ b で、幅は 2^32 まで（got %d, %d）", a, c)
			}
			if err := use(); err != nil {
				return nil, err
			}
			return starlark.MakeInt64(int64(a) + v.r.below(width)), nil
		}), nil
	}
	return nil, nil
}

// ---------------------------------------------------------------- JSON

// starJSON は値を JSON にする（Python の json.dump(ensure_ascii=False) と同じ並び。indent < 0 は 1 行）。
func starJSON(v starlark.Value, indent int) (string, error) {
	var b strings.Builder
	err := starJSONTo(&b, v, indent, 0)
	return b.String(), err
}

func starJSONTo(b *strings.Builder, v starlark.Value, indent, level int) error {
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
		s, err := pyFloatRepr(float64(x))
		if err != nil {
			return err
		}
		b.WriteString(s)
	case starlark.String:
		pyJSONString(b, string(x))
	case starlark.Indexable: // list・tuple
		return open('[', x.Len(), func(i int) error { return starJSONTo(b, x.Index(i), indent, level+1) }, ']')
	case *starlark.Dict:
		items := x.Items()
		return open('{', len(items), func(i int) error {
			k, ok := items[i][0].(starlark.String)
			if !ok {
				return fmt.Errorf("dict の鍵は文字列（got %s）", items[i][0].Type())
			}
			pyJSONString(b, string(k))
			b.WriteString(": ")
			return starJSONTo(b, items[i][1], indent, level+1)
		}, '}')
	default:
		return fmt.Errorf("JSON に書けない値（%s）", v.Type())
	}
	return nil
}

// ---------------------------------------------------------------- 決まり（最初は advice）

// starSourceAdvice は台本の文面の目安（行数・while）。
func starSourceAdvice(name string, src []byte) []string {
	var out []string
	if n := bytes.Count(src, []byte("\n")) + 1; n > starAdviceLines {
		out = append(out, fmt.Sprintf("%s: %d 行（%d 行まで）。繰り返しの型は op へ寄せる", name, n, starAdviceLines))
	}
	f, err := starFileOptions.Parse(name, src, 0)
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

// starUnusedFuncs は台本の一番外の def で、どこからも呼ばれない物を挙げる（止める）。
func starUnusedFuncs(path string, src []byte) string {
	f, err := starFileOptions.Parse(path, src, 0)
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
	return "使われない関数がある: " + strings.Join(unused, "・") + "（消す）"
}

// starOutputAdvice は書き出した pxsrc の目安（大きさ・put の多用・大きな stamp）。
func starOutputAdvice(files []starFile) []string {
	var out []string
	for _, f := range files {
		if !f.Spec {
			continue
		}
		if len(f.Data) > starAdviceSpecBytes {
			out = append(out, fmt.Sprintf("%s: %d KB（%d KB まで）。画素を JSON に吐いている（glow などの op へ寄せる）", f.Path, len(f.Data)/1024, starAdviceSpecBytes/1024))
		}
		var doc struct {
			Sprites map[string]struct {
				Size   []int            `json:"size"`
				Parts  []map[string]any `json:"parts"`
				Frames map[string]map[string]struct {
					Ops []any `json:"ops"`
				} `json:"frames"`
			} `json:"sprites"`
		}
		if json.Unmarshal(f.Data, &doc) != nil {
			continue
		}
		names := make([]string, 0, len(doc.Sprites))
		for n := range doc.Sprites {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, sn := range names {
			sp := doc.Sprites[sn]
			half := 0
			if len(sp.Size) == 2 {
				half = sp.Size[1] / 2
			}
			puts, stamps := map[string]int{}, map[string]int{}
			count := func(id string, ops []any) {
				p, s := 0, 0
				for _, op := range ops {
					m, _ := op.(map[string]any)
					if put, ok := m["put"].(map[string]any); ok {
						cells, _ := put["cells"].([]any)
						p += len(cells)
					}
					if stamp, ok := m["stamp"].(map[string]any); ok {
						rows, _ := stamp["rows"].([]any)
						s = max(s, len(rows))
					}
				}
				puts[id] = max(puts[id], p)
				stamps[id] = max(stamps[id], s)
			}
			for _, p := range sp.Parts {
				id, _ := p["id"].(string)
				ops, _ := p["ops"].([]any)
				count(id, ops)
			}
			for _, fr := range sp.Frames {
				for id, patch := range fr {
					count(id, patch.Ops)
				}
			}
			ids := make([]string, 0, len(puts))
			for id := range puts {
				ids = append(ids, id)
			}
			sort.Strings(ids)
			for _, id := range ids {
				if puts[id] > starAdvicePuts {
					out = append(out, fmt.Sprintf("%s: %s.%s の put が %d 画素（%d まで）。op にある型を手で打っている", f.Path, sn, id, puts[id], starAdvicePuts))
				}
				if half > 0 && stamps[id] > half {
					out = append(out, fmt.Sprintf("%s: %s.%s の stamp が %d 行（格子の半分 %d 行まで）。画素を手で打っている", f.Path, sn, id, stamps[id], half))
				}
			}
		}
	}
	return out
}

// starMarkdown は docs/px-ops.md の「台本」の節（‵ は ` に置き換える）。
func starMarkdown() string {
	t := fmt.Sprintf(`
## 台本（‵<名前>.px.star‵）

単純な指定は JSON（pxsrc）、繰り返しや変化が要る所は Starlark（Python とほぼ同じ書き方）の台本で、道具を関数として呼ぶ。
‵bin/fge px gen <名前>.px.star‵ で台本が書く pxsrc・JSON を書き出し、‵bin/fge px build <名前>.px.star‵ は書き出さずにメモリの中で build する。

| 呼べる物 | 何をするか |
|---|---|
| ‵px.write_spec(path, value)‵ | pxsrc を書く（spec の検査を当ててから。assets/ の下と作業場の外には書けない） |
| ‵px.write_json(path, value)‵ | 色票などの JSON を書く（‵style="python", indent=…‵ は Python の json.dump と同じ並び。写しの間だけ） |
| ‵px.hash01(x, y, seed)‵・‵px.noise1(x, seed)‵・‵px.rng(seed)‵ | 種つきのゆらぎ・乱数（rng は CPython の random.Random と同じ列。写しの間だけ） |
| ‵px.round(x, nd)‵ | Python の round（ちょうど半分は偶数へ） |
| ‵math.*‵ | sin・cos・tan・atan2・hypot・exp・log・pow・sqrt・floor・ceil・radians・pi。答えは正しく丸めた値で、OS・CPU で変わらない |

- 囲い: load は台本と同じフォルダと隣の ‵tools/‵ の ‵.star‵ だけ。ファイル・ネット・時刻には触れない。手数は 1 本 %d 手まで。
- Starlark に無い物: class（dict と関数で書く）・‵**‵（‵math.pow‵ か ‵x * x‵）・set・連なった比較（‵a <= x < b‵）・bool の足し算。
- 決まり（今は advice）: 台本 1 本 %d 行・pxsrc 1 本 %d KB・1 部品の put %d 画素・格子の半分を超える stamp・while。使われない関数は止める。
`, starDefaultMaxSteps, starAdviceLines, starAdviceSpecBytes/1024, starAdvicePuts)
	return strings.ReplaceAll(t, "‵", "`")
}

// ---------------------------------------------------------------- コマンド

// cmdGen は fge px gen: 台本を走らせて、書いた物をファイルへ書く（中身が同じ物は触らない）。
func cmdGen(out, errOut *strings.Builder, workRoot, script string) int {
	t0 := time.Now()
	res, err := runStar(workRoot, script, starOptions{Stderr: errOut})
	if err != nil {
		fmt.Fprintf(errOut, "px gen: %v\n", err)
		return 1
	}
	changed := 0
	for _, f := range res.Files {
		path := filepath.Join(workRoot, filepath.FromSlash(f.Path))
		if cur, err := os.ReadFile(path); err == nil && bytes.Equal(cur, f.Data) {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			fmt.Fprintf(errOut, "px gen: %v\n", err)
			return 1
		}
		if err := os.WriteFile(path, f.Data, 0o644); err != nil {
			fmt.Fprintf(errOut, "px gen: %v\n", err)
			return 1
		}
		changed++
	}
	fmt.Fprintf(out, "px gen: %d 本（変わった %d・同じ %d）← %s（%d ms・%d 手）\n",
		len(res.Files), changed, len(res.Files)-changed, script, time.Since(t0).Milliseconds(), res.Steps)
	for _, a := range res.Advice {
		fmt.Fprintf(out, "  advice: %s\n", a)
	}
	return 0
}

// cmdBuildStar は fge px build <台本>: 台本をメモリの中で走らせ、書いた pxsrc を順に build する。
func cmdBuildStar(out, errOut *strings.Builder, engineRoot, workRoot, script string, opt buildOptions, timing, asJSON bool) int {
	res, err := runStar(workRoot, script, starOptions{Stderr: errOut})
	if err != nil {
		fmt.Fprintf(errOut, "px build: %v\n", err)
		return 1
	}
	opt.Overlay = map[string][]byte{}
	for _, f := range res.Files {
		opt.Overlay[filepath.Join(workRoot, filepath.FromSlash(f.Path))] = f.Data
	}
	code, n := 0, 0
	for _, f := range res.Files {
		if !f.Spec {
			continue
		}
		n++
		if !asJSON {
			fmt.Fprintf(out, "%s:\n", f.Path)
		}
		code = max(code, cmdBuild(out, errOut, engineRoot, workRoot, f.Path, opt, timing, asJSON))
	}
	if n == 0 {
		fmt.Fprintf(errOut, "px build: %s は px.write_spec を呼んでいない\n", script)
		return 1
	}
	for _, a := range res.Advice {
		fmt.Fprintf(errOut, "  advice: %s\n", a)
	}
	return code
}
