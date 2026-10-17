package snd

// 台本（<名前>.snd.star）: 繰り返しや変化が要る音の指定を、道具を関数として呼ぶ Starlark で書く。
//
//	fge snd gen <名前>.snd.star     台本を走らせ、台本が書いた sndsrc をファイルへ書く
//	fge snd build <名前>.snd.star   sndsrc はメモリの中だけに書き、書いた sndsrc を全部 build する（target の WAV は書く）
//
// 箱の決まり（ファイル・ネット・時刻に触れない・load の範囲・手数の上限）は starbox。台本から呼べる物は
// snd（write_spec・read_json）・op（op の registry から作る dict の組み立て）・math（crmath。正しく丸めた値）だけ。
// read_json は作業場の .json を読むだけ（つまみ・譜面の正は assets/ の Doc。台本に数を写さない）。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
	"github.com/ababup1192/flix_game_engine/go/internal/starbox"
	"go.starlark.net/starlark"
	"go.starlark.net/starlarkstruct"
)

const starSuffix = ".snd.star"

type starFile struct {
	Path string
	Data []byte
}

type starResult struct {
	Files  []starFile
	Advice []string
	Steps  uint64
}

type starState struct {
	*starbox.Box
	files   []starFile
	written map[string]int
}

func runStar(workRoot, script string, opt starbox.Options) (*starResult, error) {
	box, full, err := starbox.Open(workRoot, script, starSuffix, opt)
	if err != nil {
		return nil, err
	}
	st := &starState{Box: box, written: map[string]int{}}
	sndMod := &starlarkstruct.Module{Name: "snd", Members: starlark.StringDict{
		"write_spec": starlark.NewBuiltin("snd.write_spec", st.writeSpec),
		"read_json":  starlark.NewBuiltin("snd.read_json", st.readJSON),
	}}
	if err := box.Run(full, starlark.StringDict{"snd": sndMod, "op": starOpModule(), "math": crmath.StarModule()}); err != nil {
		return nil, err
	}
	return &starResult{Files: st.files, Advice: box.Advice, Steps: box.Steps}, nil
}

// rootPaths は spec の中でファイルを指す値（target・.json の style・song の chip と instruments）を作業場の根からに直す。
func (st *starState) rootPaths(v any) {
	m, ok := v.(map[string]any)
	if !ok {
		return
	}
	fix := func(m map[string]any, k string) {
		if s, ok := m[k].(string); ok {
			m[k] = filepath.ToSlash(filepath.Clean(filepath.FromSlash(st.ScriptPath(s))))
		}
	}
	fix(m, "target")
	if s, ok := m["style"].(string); ok && strings.HasSuffix(s, ".json") {
		fix(m, "style")
	}
	vs, _ := m["voices"].([]any)
	for _, vo := range vs {
		vm, _ := vo.(map[string]any)
		ops, _ := vm["ops"].([]any)
		for _, o := range ops {
			om, _ := o.(map[string]any)
			if song, ok := om["song"].(map[string]any); ok {
				fix(song, "chip")
				fix(song, "instruments")
			}
		}
	}
}

func (st *starState) writeSpec(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var path string
	var value starlark.Value
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path, "value", &value); err != nil {
		return nil, err
	}
	if _, ok := value.(*starlark.Dict); !ok {
		return nil, fmt.Errorf("%s: 値は dict（got %s）", b.Name(), value.Type())
	}
	clean, err := st.OutPath(b.Name(), path, ".sndsrc.json")
	if err != nil {
		return nil, err
	}
	js, err := starbox.JSON(value, -1)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	var v any
	if err := json.Unmarshal([]byte(js), &v); err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	st.rootPaths(v)
	data, err := json.MarshalIndent(v, "", " ")
	if err != nil {
		return nil, err
	}
	data = append(data, '\n')
	if _, err := parseSpec(clean, data); err != nil {
		return nil, fmt.Errorf("%s(%q): %v", b.Name(), path, err)
	}
	if i, ok := st.written[clean]; ok {
		st.files[i] = starFile{clean, data}
	} else {
		st.written[clean] = len(st.files)
		st.files = append(st.files, starFile{clean, data})
	}
	return starlark.None, nil
}

func (st *starState) readJSON(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var path string
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path); err != nil {
		return nil, err
	}
	clean, err := st.ReadPath(b.Name(), path)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(st.WorkRoot, filepath.FromSlash(clean)))
	if err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	var v any
	if err := json.Unmarshal(data, &v); err != nil {
		return nil, fmt.Errorf("%s(%q): JSON として壊れている: %v", b.Name(), path, err)
	}
	return toStar(v), nil
}

// toStar は JSON の値を Starlark の値にする（整数の数は int、ほかは float）。
func toStar(v any) starlark.Value {
	switch x := v.(type) {
	case nil:
		return starlark.None
	case bool:
		return starlark.Bool(x)
	case float64:
		if x == float64(int64(x)) && x > -1<<53 && x < 1<<53 {
			return starlark.MakeInt64(int64(x))
		}
		return starlark.Float(x)
	case string:
		return starlark.String(x)
	case []any:
		l := make([]starlark.Value, len(x))
		for i, e := range x {
			l[i] = toStar(e)
		}
		return starlark.NewList(l)
	case map[string]any:
		d := starlark.NewDict(len(x))
		for _, k := range sortedKeys(x) {
			_ = d.SetKey(starlark.String(k), toStar(x[k]))
		}
		return d
	}
	return starlark.None
}

func sortedKeys(m map[string]any) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	return sortedStrings(ks)
}

// starOpModule は op.<名前>(**引数): {名前: {引数}} の dict を作る（引数は登録の型と範囲で、呼んだ行で確かめる）。
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
		params := map[string]opreg.Param{}
		for _, p := range def.Params {
			params[p.Name] = p
		}
		a := starlark.NewDict(len(kwargs))
		for _, kv := range kwargs {
			name := string(kv[0].(starlark.String))
			if kv[1] == starlark.None {
				continue
			}
			p, ok := params[name]
			if !ok {
				return nil, fmt.Errorf("%s: 知らない引数 %q（書ける引数: %s）", b.Name(), name, opreg.Names(def.Params))
			}
			js, err := starbox.JSON(kv[1], -1)
			if err != nil {
				return nil, fmt.Errorf("%s: 引数 %s: %v", b.Name(), name, err)
			}
			var v any
			if err := json.Unmarshal([]byte(js), &v); err != nil {
				return nil, fmt.Errorf("%s: 引数 %s: %v", b.Name(), name, err)
			}
			if err := opreg.CheckType(p, v); err != nil {
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
