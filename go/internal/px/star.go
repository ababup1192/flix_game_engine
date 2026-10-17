package px

// 台本（<名前>.px.star）: 繰り返しや変化が要る絵の指定を、道具を関数として呼ぶ Starlark で書く。
//
//	fge px gen <名前>.px.star     台本を走らせ、台本が書いた pxsrc・JSON をファイルへ書く
//	fge px build <名前>.px.star   pxsrc・JSON はメモリの中だけに書き、書いた pxsrc を全部 build する（target の sprite.json は書く）
//	fge px snap <名前>.px.star    gen してから撮る（周の history に台本を積む。rounds.go）
//
// 台本から呼べる物は px（write_spec・write_json・palette・rng・hash01・noise1・round・frames）・op（op の registry から作る
// dict の組み立て）・math（star_math.go。正しく丸めた値）だけ。
// 台本の中のパスは台本のフォルダが起点（"//" で始めると作業場の根から）。pxsrc の target などは根からのパスに直して書く。
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
	pathpkg "path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
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
	st := &starState{workRoot: workRoot, scriptDir: filepath.ToSlash(rel(workRoot, dir)), opt: opt, allowed: allowed, modules: map[string]*starModule{}, written: map[string]int{}, noise: map[string][]float64{}, math: newStarMath()}
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
	workRoot  string
	scriptDir string // 台本のフォルダ（workRoot からの相対。台本の中のパスの起点）
	opt       starOptions
	allowed   []string
	modules   map[string]*starModule
	files     []starFile
	written   map[string]int // パス → files の番号（同じパスへ 2 度書いたら後の物）
	advice    []string
	steps     uint64
	noise     map[string][]float64
	math      *starlarkstruct.Module
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
		// 止めずに advice（試しに 1 つ外した時に gen が通らないと試しにくい）
		if msg := starUnusedFuncs(path, src); msg != "" {
			st.advice = append(st.advice, fmt.Sprintf("%s: %s", st.rel(path), msg))
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
	predeclared := starlark.StringDict{"px": st.pxModule(), "op": starOpModule(), "math": st.math}
	g, err := starlark.ExecFileOptions(starFileOptions, thread, st.rel(path), src, predeclared)
	st.steps += thread.ExecutionSteps()
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
		"palette":    starlark.NewBuiltin("px.palette", st.writePalette),
		"rng":        starlark.NewBuiltin("px.rng", starRng),
		"hash01":     starlark.NewBuiltin("px.hash01", starHash01),
		"noise1":     starlark.NewBuiltin("px.noise1", st.starNoise1),
		"round":      starlark.NewBuiltin("px.round", starRound),
		"frames":     starlark.NewBuiltin("px.frames", starFrames),
		"cycle":      starlark.NewBuiltin("px.cycle", starCycle),
	}}
}

// scriptPath は台本の中のパスを workRoot からのパスにする: "//" で始まれば作業場の根から、ほかは台本のフォルダから。
func (st *starState) scriptPath(p string) string {
	if strings.HasPrefix(p, "//") {
		return p[2:]
	}
	if filepath.IsAbs(p) {
		return p // outPath が断る
	}
	return pathpkg.Join(st.scriptDir, p)
}

// outPath は書き出し先を確かめる（workRoot の中・assets/ の外・決めた拡張子）。path は台本の中の書き方。
func (st *starState) outPath(fn, path, suffix string) (string, error) {
	full := st.scriptPath(path)
	clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(full)))
	if filepath.IsAbs(full) || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("%s: %q は作業場の中の相対のパスで書く（台本のフォルダが起点・// で始めると作業場の根から）", fn, path)
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
func jsonArgs(b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (path string, value starlark.Value, encode func(starlark.Value) ([]byte, error), err error) {
	var style string
	var indent starlark.Value = starlark.None
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
	switch style {
	case "python": // json.dump(value, ensure_ascii=False, indent=indent) と同じバイト（写しの間だけ）
		encode = func(v starlark.Value) ([]byte, error) {
			s, err := starJSON(v, ind)
			if err != nil {
				return nil, fmt.Errorf("%s: %v", b.Name(), err)
			}
			return []byte(s), nil
		}
	case "":
		if ind < 0 {
			ind = 1
		}
		encode = func(v starlark.Value) ([]byte, error) {
			s, err := starJSON(v, ind)
			if err != nil {
				return nil, fmt.Errorf("%s: %v", b.Name(), err)
			}
			return []byte(s + "\n"), nil
		}
	default:
		return "", nil, nil, fmt.Errorf("%s: style は \"python\" か省く", b.Name())
	}
	return path, value, encode, nil
}

// specPathKeys は pxsrc の中でファイルを指す鍵（台本では台本のフォルダが起点・pxsrc には作業場の根からで書く）。
var specPathKeys = map[string]bool{"target": true, "base": true, "palette": true, "gate": true, "style": true}

// rootedSpec は spec の dict の写しを作り、ファイルを指す鍵を作業場の根からのパスに直す（鍵の順は保つ）。
// style は .json で終わる物だけ（px.json の styles の名前はそのまま）。
func (st *starState) rootedSpec(d *starlark.Dict) (*starlark.Dict, error) {
	out := starlark.NewDict(d.Len())
	for _, kv := range d.Items() {
		v := kv[1]
		if k, ok := kv[0].(starlark.String); ok && specPathKeys[string(k)] {
			if s, ok := v.(starlark.String); ok && (k != "style" || strings.HasSuffix(string(s), ".json")) {
				v = starlark.String(filepath.ToSlash(filepath.Clean(filepath.FromSlash(st.scriptPath(string(s))))))
			}
		}
		if err := out.SetKey(kv[0], v); err != nil {
			return nil, err
		}
	}
	return out, nil
}

func (st *starState) writeSpec(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	path, value, encode, err := jsonArgs(b, args, kwargs)
	if err != nil {
		return nil, err
	}
	d, ok := value.(*starlark.Dict)
	if !ok {
		return nil, fmt.Errorf("%s: 値は dict（got %s）", b.Name(), value.Type())
	}
	clean, err := st.outPath(b.Name(), path, ".pxsrc.json")
	if err != nil {
		return nil, err
	}
	if d, err = st.rootedSpec(d); err != nil {
		return nil, err
	}
	data, err := encode(d)
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
	path, value, encode, err := jsonArgs(b, args, kwargs)
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
	data, err := encode(value)
	if err != nil {
		return nil, err
	}
	st.put(clean, data, false)
	return starlark.None, nil
}

// writePalette は px.palette(path, colors, note=""): 名前 → "#rrggbb" か "#rrggbb" の列から色票の JSON を書き、
// ランプ（列で書いた物）を 名前 → 色キーの列 で返す。列の色キーは <名前><段の番号>（暗 → 明に 0, 1, …）。
// 1 色で書いた物は名前がそのまま色キー（返り値には入らない）。
func (st *starState) writePalette(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var path, note string
	var colors *starlark.Dict
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path, "colors", &colors, "note?", &note); err != nil {
		return nil, err
	}
	clean, err := st.outPath(b.Name(), path, ".palette.json")
	if err != nil {
		return nil, err
	}
	doc := starlark.NewDict(colors.Len() + 2)
	_ = doc.SetKey(starlark.String("version"), starlark.MakeInt(1))
	if note != "" {
		_ = doc.SetKey(starlark.String("note"), starlark.String(note))
	}
	ramps := starlark.NewDict(colors.Len())
	add := func(key string, v starlark.Value) error {
		s, ok := v.(starlark.String)
		hex := strings.ToLower(strings.TrimPrefix(string(s), "#"))
		if !ok || len(hex) != 6 || strings.Trim(hex, "0123456789abcdef") != "" {
			return fmt.Errorf("%s: %s の色は \"#rrggbb\" で書く（got %s）", b.Name(), key, v.String())
		}
		if _, found, _ := doc.Get(starlark.String(key)); found {
			return fmt.Errorf("%s: 色キー %s が重なっている（ランプの名前と 1 色の名前を変える）", b.Name(), key)
		}
		return doc.SetKey(starlark.String(key), starlark.String("#"+hex))
	}
	for _, kv := range colors.Items() {
		name, ok := kv[0].(starlark.String)
		if !ok {
			return nil, fmt.Errorf("%s: 鍵は色の名前の文字列", b.Name())
		}
		if list, ok := kv[1].(starlark.Indexable); ok && kv[1].Type() != "string" {
			keys := make([]starlark.Value, list.Len())
			for i := 0; i < list.Len(); i++ {
				k := fmt.Sprintf("%s%d", string(name), i)
				if err := add(k, list.Index(i)); err != nil {
					return nil, err
				}
				keys[i] = starlark.String(k)
			}
			if err := ramps.SetKey(name, starlark.NewList(keys)); err != nil {
				return nil, err
			}
			continue
		}
		if err := add(string(name), kv[1]); err != nil {
			return nil, err
		}
	}
	s, err := starJSON(doc, 1)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	st.put(clean, []byte(s+"\n"), false)
	return ramps, nil
}

// starOpModule は op.<名前>(**引数): {名前: {引数}} の dict を作る（引数は op の registry の型と範囲で、呼んだ行で確かめる）。
// Starlark の予約語と同じ名前の引数（from など）は末尾に _ を付けて渡す（from_=1 → "from": 1）。
// （registry は init で埋まるので、包みの変数の初期化ではなく初めて使う時に作る）
var starOpModule = sync.OnceValue(func() *starlarkstruct.Module {
	m := &starlarkstruct.Module{Name: "op", Members: starlark.StringDict{}}
	for _, def := range allOps() {
		m.Members[def.Name] = starlark.NewBuiltin("op."+def.Name, starOpCall(def))
	}
	return m
})

func starOpCall(def *opDef) func(*starlark.Thread, *starlark.Builtin, starlark.Tuple, []starlark.Tuple) (starlark.Value, error) {
	return func(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
		if len(args) > 0 {
			return nil, fmt.Errorf("%s: 引数は名前つきで書く（例 %s）", b.Name(), def.Example)
		}
		params := map[string]param{}
		for _, p := range def.Params {
			params[p.Name] = p
		}
		a := starlark.NewDict(len(kwargs))
		for _, kv := range kwargs {
			name := string(kv[0].(starlark.String))
			if kv[1] == starlark.None {
				continue // None は省いたのと同じ（op.fill(shape = None, …) は部品の塊を塗る）
			}
			if _, ok := params[name]; !ok && strings.HasSuffix(name, "_") {
				if _, ok := params[strings.TrimSuffix(name, "_")]; ok {
					name = strings.TrimSuffix(name, "_")
				}
			}
			p, ok := params[name]
			if !ok {
				return nil, fmt.Errorf("%s: 知らない引数 %q（書ける引数: %s）", b.Name(), name, paramNames(def))
			}
			if _, dup, _ := a.Get(starlark.String(name)); dup {
				return nil, fmt.Errorf("%s: 引数 %s を 2 度書いた", b.Name(), name)
			}
			js, err := starJSON(kv[1], -1)
			if err != nil {
				return nil, fmt.Errorf("%s: 引数 %s: %v", b.Name(), name, err)
			}
			var v any
			if err := json.Unmarshal([]byte(js), &v); err != nil {
				return nil, fmt.Errorf("%s: 引数 %s: %v", b.Name(), name, err)
			}
			if err := checkType(p, v); err != nil {
				return nil, fmt.Errorf("%s: 引数 %s は %v", b.Name(), name, err)
			}
			if err := a.SetKey(starlark.String(name), kv[1]); err != nil {
				return nil, err
			}
		}
		for _, p := range def.Params {
			if _, has, _ := a.Get(starlark.String(p.Name)); p.Required && !has {
				return nil, fmt.Errorf("%s: 引数 %s が無い（%s）", b.Name(), p.Name, p.Summary)
			}
		}
		out := starlark.NewDict(1)
		if err := out.SetKey(starlark.String(def.Name), a); err != nil {
			return nil, err
		}
		return out, nil
	}
}

// starCycle は px.cycle(values, phase=0, axis=None): コマの表。コマ i に values[(i + phase) % len] を返す関数を作る
// （px.frames の鍵の値に置く。昇格ループ 4〜7 周目: 息・揺れの at・頭を下げる・点滅の色・足踏みの型・旗の手の差分）。
// axis が "x" なら [v, 0]・"y" なら [0, v]（部品の at に置く上下・左右の揺れ）。
func starCycle(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var seq starlark.Indexable
	phase := 0
	axis := ""
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "values", &seq, "phase?", &phase, "axis?", &axis); err != nil {
		return nil, err
	}
	if _, isStr := seq.(starlark.String); isStr || seq.Len() == 0 {
		return nil, fmt.Errorf("%s: values は 1 つ以上の値の列（コマ i → values[(i + phase) %% len]）", b.Name())
	}
	if axis != "" && axis != "x" && axis != "y" {
		return nil, fmt.Errorf("%s: axis は \"x\"・\"y\" か省く（got %q）", b.Name(), axis)
	}
	vals := make([]starlark.Value, seq.Len())
	for i := range vals {
		v := seq.Index(i)
		if axis != "" {
			if _, ok := v.(starlark.Int); !ok {
				if _, ok := v.(starlark.Float); !ok {
					return nil, fmt.Errorf("%s: axis を書く時の values は数の列（values[%d] は %s）", b.Name(), i, v.Type())
				}
			}
			if axis == "x" {
				v = starlark.NewList([]starlark.Value{v, starlark.MakeInt(0)})
			} else {
				v = starlark.NewList([]starlark.Value{starlark.MakeInt(0), v})
			}
		}
		vals[i] = v
	}
	n := len(vals)
	return starlark.NewBuiltin("px.cycle.at", func(_ *starlark.Thread, fb *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
		var i int
		if err := starlark.UnpackPositionalArgs(fb.Name(), args, kwargs, 1, &i); err != nil {
			return nil, err
		}
		return vals[((i+phase)%n+n)%n], nil
	}), nil
}

// starFrames は px.frames(names, parts): 部品の鍵の値に関数（コマの番号 i → 値）を書くと、
// 部品にはコマ 0 の値を入れ、コマごとの差し替え（frames）を作る。(部品の列, frames) を返す。
// names はコマ名の列か数（数 n なら "f0"〜"f{n-1}"）。関数を書いていない部品はそのまま。
// parts に関数（コマの番号 i → 部品の列）を渡すと、場面をコマごとに作り、コマ 0 と違う鍵だけを patch にする（starFramesOf）。
func starFrames(th *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var namesV starlark.Value
	var partsV starlark.Value
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "names", &namesV, "parts", &partsV); err != nil {
		return nil, err
	}
	var names []string
	if n, ok := namesV.(starlark.Int); ok {
		k, ok := n.Int64()
		if !ok || k < 1 || k > 1000 {
			return nil, fmt.Errorf("%s: コマの数は 1〜1000", b.Name())
		}
		for i := int64(0); i < k; i++ {
			names = append(names, fmt.Sprintf("f%d", i))
		}
	} else if it, ok := namesV.(starlark.Indexable); ok && namesV.Type() != "string" {
		for i := 0; i < it.Len(); i++ {
			s, ok := it.Index(i).(starlark.String)
			if !ok {
				return nil, fmt.Errorf("%s: names はコマ名の文字列の列か数", b.Name())
			}
			names = append(names, string(s))
		}
	} else {
		return nil, fmt.Errorf("%s: names はコマ名の文字列の列か数（got %s）", b.Name(), namesV.Type())
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("%s: コマが 1 つも無い", b.Name())
	}
	if fn, ok := partsV.(starlark.Callable); ok {
		return starFramesOf(th, b, names, fn)
	}
	parts, ok := partsV.(*starlark.List)
	if !ok {
		return nil, fmt.Errorf("%s: parts は部品の列か、コマの番号 i → 部品の列の関数（got %s）", b.Name(), partsV.Type())
	}
	frames := make([]*starlark.Dict, len(names))
	for i := range frames {
		frames[i] = starlark.NewDict(0)
	}
	out := make([]starlark.Value, parts.Len())
	for pi := 0; pi < parts.Len(); pi++ {
		d, ok := parts.Index(pi).(*starlark.Dict)
		if !ok {
			return nil, fmt.Errorf("%s: parts[%d] は dict（got %s）", b.Name(), pi, parts.Index(pi).Type())
		}
		hasFn := false
		for _, kv := range d.Items() {
			if _, ok := kv[1].(starlark.Callable); ok {
				hasFn = true
			}
		}
		if !hasFn {
			out[pi] = d
			continue
		}
		id, _, _ := d.Get(starlark.String("id"))
		if _, ok := id.(starlark.String); !ok {
			return nil, fmt.Errorf("%s: parts[%d] に関数を書くなら id が要る", b.Name(), pi)
		}
		nd := starlark.NewDict(d.Len())
		patches := make([]*starlark.Dict, len(names))
		for i := range patches {
			patches[i] = starlark.NewDict(1)
		}
		for _, kv := range d.Items() {
			fn, ok := kv[1].(starlark.Callable)
			if !ok {
				_ = nd.SetKey(kv[0], kv[1])
				continue
			}
			for i := range names {
				v, err := starlark.Call(th, fn, starlark.Tuple{starlark.MakeInt(i)}, nil)
				if err != nil {
					return nil, err
				}
				if i == 0 {
					_ = nd.SetKey(kv[0], v)
				}
				_ = patches[i].SetKey(kv[0], v)
			}
		}
		for i := range names {
			_ = frames[i].SetKey(id, patches[i])
		}
		out[pi] = nd
	}
	fd := starlark.NewDict(len(names))
	for i, n := range names {
		_ = fd.SetKey(starlark.String(n), frames[i])
	}
	return starlark.Tuple{starlark.NewList(out), fd}, nil
}

// starFramesOf は px.frames(names, scene): scene(i) でコマ i の部品の列を作り、コマ 0 の列を部品に、
// コマ 0 と値が違う鍵だけを id ごとの patch にする（落ち物パズルの盤・城下町の旗の綱のように、場面ごとコマで描き分ける時）。
// どのコマも部品の数と id の並びはコマ 0 と同じにする（部品を外すなら patch を手で書く）。
func starFramesOf(th *starlark.Thread, b *starlark.Builtin, names []string, scene starlark.Callable) (starlark.Value, error) {
	per := make([]*starlark.List, len(names))
	for i := range names {
		v, err := starlark.Call(th, scene, starlark.Tuple{starlark.MakeInt(i)}, nil)
		if err != nil {
			return nil, err
		}
		l, ok := v.(*starlark.List)
		if !ok {
			return nil, fmt.Errorf("%s: scene(%d) は部品の列を返す（got %s）", b.Name(), i, v.Type())
		}
		per[i] = l
	}
	base := per[0]
	fd := starlark.NewDict(len(names))
	for i, name := range names {
		if per[i].Len() != base.Len() {
			return nil, fmt.Errorf("%s: コマ %s の部品が %d 個でコマ 0（%d 個）と違う（部品を外すなら patch を手で書く）", b.Name(), name, per[i].Len(), base.Len())
		}
		patch := starlark.NewDict(0)
		for k := 0; k < base.Len(); k++ {
			a, okA := base.Index(k).(*starlark.Dict)
			p, okB := per[i].Index(k).(*starlark.Dict)
			if !okA || !okB {
				return nil, fmt.Errorf("%s: コマ %s の部品 [%d] は dict で書く", b.Name(), name, k)
			}
			idA, _, _ := a.Get(starlark.String("id"))
			idB, _, _ := p.Get(starlark.String("id"))
			if _, ok := idB.(starlark.String); !ok || idA != idB {
				return nil, fmt.Errorf("%s: コマ %s の部品 [%d] の id %v がコマ 0 の %v と違う（並びをそろえる）", b.Name(), name, k, idB, idA)
			}
			d := starlark.NewDict(0)
			for _, kv := range p.Items() {
				old, found, _ := a.Get(kv[0])
				same := false
				if found {
					eq, err := starlark.Equal(old, kv[1])
					if err != nil {
						return nil, err
					}
					same = eq
				}
				if !same {
					_ = d.SetKey(kv[0], kv[1])
				}
			}
			for _, kv := range a.Items() {
				if _, found, _ := p.Get(kv[0]); !found {
					return nil, fmt.Errorf("%s: コマ %s で部品 %v の鍵 %v が無い（コマ 0 にある鍵はどのコマにも書く）", b.Name(), name, idA, kv[0])
				}
			}
			if d.Len() > 0 {
				_ = patch.SetKey(idB, d)
			}
		}
		_ = fd.SetKey(starlark.String(name), patch)
	}
	return starlark.Tuple{base, fd}, nil
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
	return "使われない関数がある: " + strings.Join(unused, "・") + "（使わないなら消す）"
}

// starOutputAdvice は書き出した pxsrc の目安（大きさ・put の多用・大きな stamp）。
func starOutputAdvice(files []starFile) []string {
	var out []string
	for _, f := range files {
		if strings.HasSuffix(f.Path, ".palette.json") {
			var pal map[string]any
			if json.Unmarshal(f.Data, &pal) == nil {
				for _, k := range []string{"ink", "shade", "mid", "light", "gloss"} {
					if _, ok := pal[k]; ok {
						out = append(out, fmt.Sprintf("%s: 色キー %q は色の参照の名前（ink・shade・mid・light はランプの段・gloss はつや）と重なる。ランプのある部品では色キーを指さない（名前を変える）", f.Path, k))
					}
				}
			}
		}
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

// starExample は最小の台本（docs/px-ops.md に載せ、テストで実際に gen と build を通す）。
const starExample = `# debug/px-scenes/lamp/lamp.px.star（bin/fge px gen debug/px-scenes/lamp/lamp.px.star）
ramps = px.palette("lamp.palette.json", {
    "iron": ["#181820", "#383848", "#686878", "#a0a0b0"],  # 暗 → 明（色キーは iron0〜iron3）
    "glow": ["#a05820", "#e09838", "#f8d070"],
})

px.write_spec("lamp.pxsrc.json", {
    "version": 2,
    "target": "//atelier/lamp.sprite.json",  # // は作業場の根から。採用の候補は atelier/
    "palette": "lamp.palette.json",           # ほかのパスは台本のフォルダが起点
    "ramps": ramps,
    "sprites": {"lamp": {
        "size": [16, 24],
        "ramp": "iron",
        "parts": [
            {"id": "pole", "shape": {"rect": [7, 8, 2, 16]}, "ops": [op.directional(), op.sel_out()]},
            {"id": "light", "shape": {"disk": [8, 5, 3]}, "ramp": "glow", "emissive": True,
             "ops": [op.gradient_fill(field = "y", invert = True)]},
        ],
        "frames": {"on": {}, "off": {"light": {"ramp": "iron"}}},
    }},
})
`

// starMarkdown は docs/px-ops.md の「台本」の節（‵ は ` に置き換える）。
func starMarkdown() string {
	t := fmt.Sprintf(`
## 台本（‵<名前>.px.star‵）

単純な指定は JSON（pxsrc）、繰り返しや変化が要る所は Starlark（Python とほぼ同じ書き方）の台本で、道具を関数として呼ぶ。

- ‵bin/fge px gen <名前>.px.star‵: 台本が書く pxsrc・色票・JSON をファイルへ書く（中身が同じ物は触らない）。
- ‵bin/fge px build <名前>.px.star‵: pxsrc・JSON はメモリの中だけに書いて build する（target の sprite.json と debug/px/ の見本は書く）。
- ‵bin/fge px snap <名前>.px.star‵: gen してから撮り、周の history に台本を積む（pxsrc を撮ると、台本の変更が入っていない時に警告）。

| 呼べる物 | 何をするか |
|---|---|
| ‵px.write_spec(path, value)‵ | pxsrc を書く（spec の検査を当ててから。assets/ の下と作業場の外には書けない） |
| ‵px.palette(path, colors, note="")‵ | 色票（‵<名前>.palette.json‵）を書き、ランプ（名前 → 色キーの列）を返す。‵colors‵ は 名前 → ‵"#rrggbb"‵ の列（暗 → 明。色キーは ‵<名前>0‵…）か 1 色 |
| ‵op.<名前>(引数=…)‵ | ‵{名前: {引数}}‵ の dict を作る（引数の型・範囲をその行で確かめる）。予約語と同じ名前の引数は末尾に ‵_‵（‵op.directional(from_=1)‵ → ‵"from": 1‵） |
| ‵px.write_json(path, value)‵ | JSON を書く（‵style="python", indent=…‵ は Python の json.dump と同じ並び。写しの間だけ） |
| ‵px.hash01(x, y, seed)‵・‵px.noise1(x, seed)‵・‵px.rng(seed)‵ | 種つきのゆらぎ・乱数（rng は CPython の random.Random と同じ列。写しの間だけ） |
| ‵px.round(x, nd)‵ | Python の round（ちょうど半分は偶数へ） |
| ‵px.frames(names, parts)‵ | 部品の鍵の値に関数（コマの番号 ‵i‵ → 値）を書くと、‵(部品の列, frames)‵ を返す。部品にはコマ 0 の値が入る（‵"ops": lambda i: smoke(i)‵）。‵names‵ はコマ名の列か数 |
| ‵px.frames(names, scene)‵ | ‵scene(i)‵ がコマ i の部品の列を返す関数なら、コマ 0 の列を部品に、コマ 0 と違う鍵だけを patch にする（場面ごとコマで描き分ける時。部品の数と id の並びはどのコマも同じ） |
| ‵px.cycle(values, phase=0, axis=None)‵ | コマの表: コマ i に ‵values[(i + phase) %% len]‵ を返す関数（px.frames の鍵の値に置く。‵"at": px.cycle([0, 1, 3, 1], axis="y")‵ で上下・‵"ops": px.cycle([[op.text(…, color=c)] for c in COLS])‵ で点滅）。axis は "x" で ‵[v, 0]‵・"y" で ‵[0, v]‵ |
| ‵math.*‵ | sin・cos・tan・atan2・hypot・exp・log・pow・sqrt・floor・ceil・radians・pi。答えは正しく丸めた値で、OS・CPU で変わらない |

最小の台本（version・target・palette・ramps・sprites・parts・frames）:

‵‵‵python
%s‵‵‵

色票の書式（px.palette が書く物。手で書いても同じ）: 名前 → ‵"#rrggbb"‵ の平らな JSON。‵{"rgb": [0〜1, 0〜1, 0〜1]}‵ も読める。

‵‵‵json
{"version": 1, "iron0": "#181820", "iron1": "#383848", "glow0": "#a05820"}
‵‵‵

- パス: 台本の中のパス（write_spec・palette・write_json の path と、pxsrc の target・base・palette・gate・style の .json）は台本のフォルダが起点。‵//‵ で始めると作業場の根から。書き出す pxsrc には根からのパスで入る。
- 置き場: 採用の候補の sprite.json（target）は ‵atelier/‵（assets/ には書けない）。採用しない試し（‵debug/px-scenes/‵ など）は target ごと ‵debug/‵ に置いてよい。見本・report・PNG は build が ‵debug/px/<名前>/‵ に書く。
- 一番外（def の外）では同じ名前に 2 度代入できない（Starlark の決まり。一番外の for の変数を 2 つのループで使うのも当たる）。ループや組み立ては def の中に入れて呼ぶ。
- 囲い: load は台本と同じフォルダと隣の ‵tools/‵ の ‵.star‵ だけ。ファイル・ネット・時刻には触れない。手数は 1 本 %d 手まで。
- Starlark に無い物: class（dict と関数で書く）・‵**‵（‵math.pow‵ か ‵x * x‵）・‵round‵（‵px.round‵）・set・連なった比較（‵a <= x < b‵）・bool の足し算・文字列の for（‵s.elems()‵）・‵%%‵ の幅と桁（‵"%%02x"‵ は ‵"%%x%%x" %% (v // 16, v %% 16)‵）。一番外の for は書けるが、ループの変数も 1 度しか代入できない（2 本目のループは別の名前か def の中）。
- 決まり（どれも advice）: 台本 1 本 %d 行・pxsrc 1 本 %d KB・1 部品の put %d 画素・格子の半分を超える stamp・while・使われない関数・色票の色キーが ink などの名前と重なる。
- ‵None‵ を渡した引数は省いたのと同じ（‵op.fill(shape = None, color = …)‵ は部品の塊を塗る）。
- px.frames に渡す lambda は、ループの変数を作った時でなく呼ばれた時に引く（Python と同じ）。ループの中で作る lambda は値を引数で閉じ込める関数から返す（‵def down(speed): return lambda i: [0, i * speed]‵）。そのまま書くと全部の部品が最後の値になる。コマの値を先に並べられるなら ‵px.cycle([f(i) for i in range(N)])‵ でも閉じ込められる。
`, starExample, starDefaultMaxSteps, starAdviceLines, starAdviceSpecBytes/1024, starAdvicePuts)
	return strings.ReplaceAll(t, "‵", "`")
}

// ---------------------------------------------------------------- コマンド

// writeStarFiles は台本が書いた物をファイルへ書き、書き替えた数を返す（中身が同じ物は触らない）。
func writeStarFiles(workRoot string, files []starFile) (int, error) {
	changed := 0
	for _, f := range files {
		path := filepath.Join(workRoot, filepath.FromSlash(f.Path))
		if cur, err := os.ReadFile(path); err == nil && bytes.Equal(cur, f.Data) {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return changed, err
		}
		if err := os.WriteFile(path, f.Data, 0o644); err != nil {
			return changed, err
		}
		changed++
	}
	return changed, nil
}

// cmdGen は fge px gen: 台本を走らせて、書いた物をファイルへ書く（中身が同じ物は触らない）。
func cmdGen(out, errOut *strings.Builder, workRoot, script string) int {
	t0 := time.Now()
	res, err := runStar(workRoot, script, starOptions{Stderr: errOut})
	if err != nil {
		fmt.Fprintf(errOut, "px gen: %v\n", err)
		return 1
	}
	changed, err := writeStarFiles(workRoot, res.Files)
	if err != nil {
		fmt.Fprintf(errOut, "px gen: %v\n", err)
		return 1
	}
	fmt.Fprintf(out, "px gen: %d 本（変わった %d・同じ %d）← %s（%d ms・%d 手）\n",
		len(res.Files), changed, len(res.Files)-changed, script, time.Since(t0).Milliseconds(), res.Steps)
	for _, a := range res.Advice {
		fmt.Fprintf(out, "  advice: %s\n", a)
	}
	return 0
}

// cmdBuildStar は fge px build <台本>: 台本をメモリの中で走らせ、書いた pxsrc を順に build する
// （pxsrc・色票はファイルに書かない。build なので target の sprite.json は書く）。
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

// staleStar は pxsrc を描く前に、同じフォルダの台本（名前が pxsrc の名前の頭と同じ .px.star）の方が新しく、
// 走らせると違う pxsrc を書く時の警告を返す（無ければ ""）。台本の変更を gen し忘れて古い絵を撮らないため。
func staleStar(workRoot, spec string) string {
	full := specPath(workRoot, spec)
	info, err := os.Stat(full)
	if err != nil || !strings.HasSuffix(full, ".pxsrc.json") {
		return ""
	}
	stars, _ := filepath.Glob(filepath.Join(filepath.Dir(full), "*.px.star"))
	sort.Strings(stars)
	for _, star := range stars {
		st, err := os.Stat(star)
		if err != nil || !st.ModTime().After(info.ModTime()) || !strings.HasPrefix(specName(full), specName(star)) {
			continue
		}
		res, err := runStar(workRoot, star, starOptions{})
		if err != nil {
			return fmt.Sprintf("px: 警告: %s の方が新しいが走らない（%v）", rel(workRoot, star), err)
		}
		want := filepath.ToSlash(rel(workRoot, full))
		for _, f := range res.Files {
			if f.Path == want {
				if cur, err := os.ReadFile(full); err == nil && !bytes.Equal(cur, f.Data) {
					return fmt.Sprintf("px: 警告: %s が台本 %s より古い（台本の変更が入っていない）。bin/fge px snap %s で gen してから撮る",
						rel(workRoot, full), rel(workRoot, star), rel(workRoot, star))
				}
			}
		}
	}
	return ""
}
