package px

// ドット絵の指定（<名前>.pxsrc.json・version 2）を読む。
//
//	{"version": 2, "title": "…", "note": "…",
//	 "target": "atelier/x.sprite.json", "base": "assets/x.sprite.json",
//	 "palette": "assets/x.palette.json", "gate": "art/x.colorgate.json",
//	 "light": {"dir": [-1, -1], "gloss": "tileGloss", "ground": "#ffffeb"},
//	 "ramps": {"slime": ["暗", "…", "明"]}, "shapes": {"blob": 形}, "macros": {"名前": [op, …]},
//	 "sprites": {"slime": {"size": [24, 24], "anchor": [12, 23], "ramp": "slime",
//	   "parts": [{"id": "body", "shape": 形, "ops": [op, …]}, {"id": "eye", "on": "body", "clip": true, …}],
//	   "post": [op, …],
//	   "frames": {"idle": {}, "squash": {"body": {"shape": 形}}, "blink": {"eye": null}}}}}
//
// 部品（parts）は平らな列で、列の順が重ねる順。親は "on" で名指しし、"clip" で親の塊の中だけに描く。
// コマ（frames）は部品 id を鍵にした JSON Merge Patch（RFC 7386）。null でその部品を外し、"at" でずらす。
// 書き損じは黙って読み飛ばさず、場所つきの Problem にして全部返す。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// SpecVersion は読める指定の版。
const SpecVersion = 2

// Light は光（Doc に 1 か所だけ。op は引数で受けずここを読む）。
type Light struct {
	Dir    [3]float64 // 光の来る向き（x 右・y 下が正。左上なら負）。3 つ目は高さ
	Gloss  string     // つやの色（色の名前 "gloss" が指す色キー）
	Ground string     // 絵を置く地の色（色キーか #rrggbb。見本の地と地との明度差の検査に使う）
}

// Spec は読んだ指定。
type Spec struct {
	Path                                     string
	Version                                  int
	Title, Note, Target, Base, Palette, Gate string
	Light                                    Light
	Ramps                                    map[string][]string
	Shapes                                   map[string]any
	Macros                                   map[string][]OpCall
	Sprites                                  []*SpriteSpec
}

// SpriteSpec は 1 スプライトの指定。
type SpriteSpec struct {
	Name     string
	Note     string
	Size     [2]int
	Anchor   *[2]int
	Ramp     string
	RawParts []*pxlib.Obj // コマの patch を当てる前の部品（鍵の順を保つ）
	Post     []OpCall
	Frames   []FrameSpec
}

// FrameSpec は 1 コマ: 部品 id → Merge Patch。
type FrameSpec struct {
	Name  string
	Patch *pxlib.Obj
}

// Part は 1 部品（コマの patch を当てた後）。
type Part struct {
	ID    string
	On    string
	Clip  bool
	Shape any
	Ramp  string
	At    [2]int
	Ops   []OpCall
	Where string
}

// Problem は指定の書き損じ 1 件。
type Problem struct{ Where, Msg string }

func (p Problem) Error() string {
	if p.Where == "" {
		return p.Msg
	}
	return p.Where + ": " + p.Msg
}

// ProblemList は Problem の並び（error として返す）。
type ProblemList []Problem

func (l ProblemList) Error() string {
	lines := make([]string, len(l))
	for i, p := range l {
		lines[i] = p.Error()
	}
	return strings.Join(lines, "\n")
}

var (
	specKeys   = []string{"version", "title", "note", "target", "base", "palette", "gate", "light", "ramps", "shapes", "macros", "sprites"}
	lightKeys  = []string{"dir", "gloss", "ground", "note"}
	spriteKeys = []string{"note", "size", "anchor", "ramp", "parts", "post", "frames"}
	partKeys   = []string{"id", "on", "clip", "shape", "ramp", "at", "ops", "note"}
	idPattern  = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*$`)
)

type reader struct{ probs ProblemList }

func (r *reader) bad(where, format string, a ...any) {
	r.probs = append(r.probs, Problem{where, fmt.Sprintf(format, a...)})
}

func (r *reader) keys(o *pxlib.Obj, where string, allowed []string) {
	ok := map[string]bool{}
	for _, k := range allowed {
		ok[k] = true
	}
	for _, k := range o.Keys() {
		if !ok[k] && !strings.HasPrefix(k, "//") {
			r.bad(where, "知らない鍵 %q（書ける鍵: %s）", k, strings.Join(allowed, " "))
		}
	}
}

func (r *reader) str(o *pxlib.Obj, k, where string) string {
	v, ok := o.Get(k)
	if !ok {
		return ""
	}
	s, isStr := v.(string)
	if !isStr {
		r.bad(where+"."+k, "文字列で書く")
	}
	return s
}

func (r *reader) ints(v any, n int, where string) []int {
	arr, ok := v.([]any)
	if !ok || len(arr) != n {
		r.bad(where, "整数 %d つの配列で書く", n)
		return nil
	}
	out := make([]int, n)
	for i, e := range arr {
		num, isNum := e.(json.Number)
		iv, err := num.Int64()
		if !isNum || err != nil {
			r.bad(where, "整数 %d つの配列で書く", n)
			return nil
		}
		out[i] = int(iv)
	}
	return out
}

func (r *reader) ops(v any, where string) []OpCall {
	arr, ok := v.([]any)
	if !ok {
		r.bad(where, "op の配列で書く")
		return nil
	}
	out := make([]OpCall, 0, len(arr))
	for i, e := range arr {
		call, err := parseOpCall(pxlib.Plain(e), fmt.Sprintf("%s[%d]", where, i))
		if err != nil {
			r.probs = append(r.probs, Problem{Where: "", Msg: err.Error()})
			continue
		}
		out = append(out, call)
	}
	return out
}

// Load は指定を読む。書き損じは全部 ProblemList で返す（1 件目で止めない）。
func Load(path string) (*Spec, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	v, err := pxlib.DecodeOrdered(data)
	if err != nil {
		return nil, fmt.Errorf("%s: JSON として読めない: %w", path, err)
	}
	root, ok := v.(*pxlib.Obj)
	if !ok {
		return nil, fmt.Errorf("%s: 一番外はオブジェクトで書く", path)
	}
	r := &reader{}
	s := parseSpec(r, root)
	s.Path = path
	if len(r.probs) > 0 {
		return nil, dedupe(r.probs)
	}
	return s, nil
}

func parseSpec(r *reader, root *pxlib.Obj) *Spec {
	s := &Spec{Ramps: map[string][]string{}, Shapes: map[string]any{}, Macros: map[string][]OpCall{}}
	r.keys(root, "(一番外)", specKeys)
	ver, _ := root.Get("version")
	if n, ok := ver.(json.Number); !ok || n.String() != fmt.Sprint(SpecVersion) {
		r.bad("version", "%d と書く（今読めるのは version %d の指定）", SpecVersion, SpecVersion)
	}
	s.Version = SpecVersion
	s.Title, s.Note = r.str(root, "title", ""), r.str(root, "note", "")
	s.Target, s.Base = r.str(root, "target", ""), r.str(root, "base", "")
	s.Palette, s.Gate = r.str(root, "palette", ""), r.str(root, "gate", "")
	if s.Target == "" {
		r.bad("target", "書き出す sprite.json（atelier/ の下）が無い")
	} else if isUnderAssets(s.Target) {
		r.bad("target", "assets/ を指している — 候補は atelier/ に書く（採用は swap）")
	}
	s.Light = Light{Dir: [3]float64{-1, -1, 0}}
	if lv, ok := root.Get("light"); ok {
		lo, isObj := lv.(*pxlib.Obj)
		if !isObj {
			r.bad("light", "オブジェクトで書く")
		} else {
			r.keys(lo, "light", lightKeys)
			if d, ok := lo.Get("dir"); ok {
				p := nums(pxlib.Plain(d))
				if len(p) != 2 && len(p) != 3 || (p[0] == 0 && p[1] == 0) {
					r.bad("light.dir", "[x, y] か [x, y, 高さ] で書く（左上からの光は [-1, -1]）")
				} else {
					s.Light.Dir = [3]float64{p[0], p[1], 0}
					if len(p) == 3 {
						s.Light.Dir[2] = p[2]
					}
				}
			}
			s.Light.Gloss = r.str(lo, "gloss", "light")
			s.Light.Ground = r.str(lo, "ground", "light")
		}
	}
	if s.Light.Dir[2] == 0 {
		// 高さを書かなければ、斜め上 30° 余りから当てる（[-0.55, -0.70, 0.55] と同じ仰角）
		s.Light.Dir[2] = 0.618 * hypot(s.Light.Dir[0], s.Light.Dir[1])
	}
	if rv, ok := root.Get("ramps"); ok {
		ro, isObj := rv.(*pxlib.Obj)
		if !isObj {
			r.bad("ramps", "名前 → 色の名前の配列（暗 → 明）で書く")
		} else {
			keys, vals := ro.Items()
			for i, k := range keys {
				list := strs(pxlib.Plain(vals[i]))
				if len(list) == 0 {
					r.bad("ramps."+k, "色の名前の配列（暗 → 明）で書く")
				}
				s.Ramps[k] = list
			}
		}
	}
	if sv, ok := root.Get("shapes"); ok {
		if so, isObj := pxlib.Plain(sv).(map[string]any); isObj {
			s.Shapes = so
		} else {
			r.bad("shapes", "名前 → 形のオブジェクトで書く")
		}
	}
	if mv, ok := root.Get("macros"); ok {
		mo, isObj := mv.(*pxlib.Obj)
		if !isObj {
			r.bad("macros", "名前 → op の配列で書く")
		} else {
			keys, vals := mo.Items()
			for i, k := range keys {
				s.Macros[k] = r.ops(vals[i], "macros."+k)
			}
		}
	}
	sv, _ := root.Get("sprites")
	so, ok := sv.(*pxlib.Obj)
	if !ok || so.Len() == 0 {
		r.bad("sprites", "名前 → スプライトの指定のオブジェクトで書く")
		return s
	}
	names, vals := so.Items()
	for i, name := range names {
		if sp := parseSprite(r, s, name, vals[i]); sp != nil {
			s.Sprites = append(s.Sprites, sp)
		}
	}
	return s
}

func parseSprite(r *reader, s *Spec, name string, v any) *SpriteSpec {
	where := "sprites." + name
	o, ok := v.(*pxlib.Obj)
	if !ok {
		r.bad(where, "オブジェクトで書く")
		return nil
	}
	r.keys(o, where, spriteKeys)
	sp := &SpriteSpec{Name: name, Note: r.str(o, "note", where), Ramp: r.str(o, "ramp", where)}
	if sz, ok := o.Get("size"); ok {
		if p := r.ints(sz, 2, where+".size"); p != nil {
			if p[0] < 1 || p[1] < 1 || p[0] > 512 || p[1] > 512 {
				r.bad(where+".size", "1〜512 の [w, h] で書く")
			}
			sp.Size = [2]int{p[0], p[1]}
		}
	} else {
		r.bad(where+".size", "[w, h] が無い")
	}
	if av, ok := o.Get("anchor"); ok {
		if p := r.ints(av, 2, where+".anchor"); p != nil {
			sp.Anchor = &[2]int{p[0], p[1]}
		}
	}
	if sp.Ramp != "" && s.Ramps[sp.Ramp] == nil {
		r.bad(where+".ramp", "ramps に %q が無い", sp.Ramp)
	}
	pv, _ := o.Get("parts")
	parts, ok := pv.([]any)
	if !ok || len(parts) == 0 {
		r.bad(where+".parts", "部品の配列で書く")
	}
	ids := map[string]bool{}
	for i, e := range parts {
		po, isObj := e.(*pxlib.Obj)
		pw := fmt.Sprintf("%s.parts[%d]", where, i)
		if !isObj {
			r.bad(pw, "部品はオブジェクトで書く")
			continue
		}
		id, _ := po.GetOr("id", "").(string)
		if !idPattern.MatchString(id) {
			r.bad(pw+".id", "英字で始まる英数字の id を書く（コマの patch と違反の場所で使う）")
		} else if ids[id] {
			r.bad(pw+".id", "id %q が重なっている", id)
		}
		ids[id] = true
		sp.RawParts = append(sp.RawParts, po)
	}
	if ov, ok := o.Get("post"); ok {
		sp.Post = r.ops(ov, where+".post")
	}
	fv, _ := o.Get("frames")
	frames, ok := fv.(*pxlib.Obj)
	if !ok || frames.Len() == 0 {
		r.bad(where+".frames", "コマ名 → 部品の patch のオブジェクトで書く（変えないコマは {}）")
		return sp
	}
	fnames, fvals := frames.Items()
	for i, fname := range fnames {
		patch, isObj := fvals[i].(*pxlib.Obj)
		fw := where + ".frames." + fname
		if !isObj {
			r.bad(fw, "部品 id → patch のオブジェクトで書く（変えないなら {}）")
			continue
		}
		for _, id := range patch.Keys() {
			if !ids[id] {
				r.bad(fw+"."+id, "parts に id %q が無い（コマは今ある部品を直すだけ）", id)
			}
		}
		sp.Frames = append(sp.Frames, FrameSpec{fname, patch})
	}
	// 各コマで部品が読めるかを先に確かめる（描く前に書き損じを全部出す）
	for _, f := range sp.Frames {
		sp.partsOf(r, s, f)
	}
	return sp
}

// partsOf はコマの patch を当てた部品の列。
func (sp *SpriteSpec) partsOf(r *reader, s *Spec, f FrameSpec) []*Part {
	var out []*Part
	seen := map[string]bool{}
	for i, raw := range sp.RawParts {
		id, _ := raw.GetOr("id", "").(string)
		obj := raw
		if pv, ok := f.Patch.Get(id); ok {
			if pv == nil {
				continue
			}
			obj = mergePatch(raw, pv).(*pxlib.Obj)
		}
		where := fmt.Sprintf("sprites.%s.parts[%d](%s)", sp.Name, i, id)
		if f.Patch.Has(id) {
			where = fmt.Sprintf("sprites.%s.frames.%s.%s", sp.Name, f.Name, id)
		}
		r.keys(obj, where, partKeys)
		p := &Part{ID: id, On: r.str(obj, "on", where), Ramp: r.str(obj, "ramp", where), Where: where}
		if cv, ok := obj.Get("clip"); ok {
			b, isBool := cv.(bool)
			if !isBool {
				r.bad(where+".clip", "true か false で書く")
			}
			p.Clip = b
		}
		if p.Clip && p.On == "" {
			r.bad(where+".clip", "clip は on（親の部品 id）と組で書く")
		}
		if p.On != "" && !seen[p.On] {
			r.bad(where+".on", "親 %q はこの部品より前の列に置く（列の順が重ねる順）", p.On)
		}
		if sh, ok := obj.Get("shape"); ok {
			p.Shape = pxlib.Plain(sh)
			if _, err := ShapeOf(p.Shape, s.Shapes); err != nil {
				r.bad(where+".shape", "%v", err)
			}
		}
		if av, ok := obj.Get("at"); ok {
			if a := r.ints(av, 2, where+".at"); a != nil {
				p.At = [2]int{a[0], a[1]}
			}
		}
		if p.Ramp == "" {
			p.Ramp = sp.Ramp
		} else if s.Ramps[p.Ramp] == nil {
			r.bad(where+".ramp", "ramps に %q が無い", p.Ramp)
		}
		if ov, ok := obj.Get("ops"); ok {
			p.Ops = r.ops(ov, fmt.Sprintf("%s.ops", id))
		}
		seen[id] = true
		out = append(out, p)
	}
	return out
}

// mergePatch は RFC 7386 の JSON Merge Patch。オブジェクトは鍵ごとに重ね、null は消し、ほかは置き換える。
func mergePatch(target, patch any) any {
	po, ok := patch.(*pxlib.Obj)
	if !ok {
		return patch
	}
	out := pxlib.NewObj()
	if to, isObj := target.(*pxlib.Obj); isObj {
		keys, vals := to.Items()
		for i, k := range keys {
			out.Set(k, vals[i])
		}
	}
	keys, vals := po.Items()
	for i, k := range keys {
		if vals[i] == nil {
			out.Delete(k)
			continue
		}
		cur, _ := out.Get(k)
		out.Set(k, mergePatch(cur, vals[i]))
	}
	return out
}

// isUnderAssets は path が（./ や ../ で回り道しても）ゲームの assets/ の下を指すか。
func isUnderAssets(path string) bool {
	clean := filepath.ToSlash(filepath.Clean(path))
	return clean == "assets" || strings.HasPrefix(clean, "assets/") || strings.Contains(clean, "/assets/") || strings.HasPrefix(clean, "../")
}

// specName は spec のファイル名から種類の拡張子を外した物（見本の置き場の名前）。
func specName(specPath string) string {
	return strings.TrimSuffix(filepath.Base(specPath), ".pxsrc.json")
}

func dedupe(l ProblemList) ProblemList {
	seen := map[Problem]bool{}
	var out ProblemList
	for _, p := range l {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}
