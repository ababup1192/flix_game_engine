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
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// specVersion は読める指定の版。
const specVersion = 2

// lightSpec は光（Doc に 1 か所だけ。op は引数で受けずここを読む）。
type lightSpec struct {
	Dir    [3]float64 // 光の来る向き（x 右・y 下が正。左上なら負）。3 つ目は高さ
	Gloss  pxlib.Key  // つやの色（色の参照 "gloss" が指す色キー）
	Ground colorRef   // 絵を置く地の色（色キーか #rrggbb。見本の地と地との明度差の検査に使う）
}

// specDoc は読んだ指定。
type specDoc struct {
	Path                                     string
	Version                                  int
	Title, Note, Target, Base, Palette, Gate string
	Indent                                   string // 書き出す字下げ（"" は base の字面に合わせる）
	Style                                    string // 機種の決まり（px.json の styles の名前か *.pxstyle.json）
	Light                                    lightSpec
	Ramps                                    map[string][]pxlib.Key
	Shapes                                   map[string]any
	Macros                                   map[string][]opCall
	Sprites                                  []*spriteSpec
}

// spriteSpec は 1 スプライトの指定。
type spriteSpec struct {
	Name     string
	Note     string
	Size     pxlib.Size
	Anchor   *pxlib.Pt
	Ramp     string
	RawParts []*pxlib.Obj // コマの patch を当てる前の部品（鍵の順を保つ）
	Post     []opCall
	Frames   []frameSpec
	Seeds    []int // variants.seeds（無ければ nil = 変種なし）
	Anim     *bool // anim の検査を回すか（省くと動きの op・pose・rotate があれば回す）
	animated bool  // 動きの op・pose・rotate を使っている
}

// frameSpec は 1 コマ: 部品 id → Merge Patch。
type frameSpec struct {
	Name  string
	Patch *pxlib.Obj
}

// part は 1 部品（コマの patch を当てた後）。
type part struct {
	ID       string
	On       string
	Clip     bool
	Shape    any
	Ramp     string
	At       pxlib.Pt // 描く位置のずらし（コマの patch と親のずれを足した後）
	BaseAt   pxlib.Pt // コマの patch を当てる前の at（親が動いた量 = At − BaseAt を子へ渡す）
	Ops      []opCall
	Where    string
	Rotate   float64     // 部品を回す角度（度。正で時計回り。rotsprite の考え方で色を足さない）
	Pivot    *[2]float64 // 回す中心の画素（.5 で画素の境目。省くと塊の上の真ん中 = 肩・股の付け根）
	Emissive bool        // 自分で光る（窓の灯り・炎）。光の向きの検査 light-dir の対象から外す
	Scroll   *scrollSpec // 形を周期で写して並べ、コマごとに speed ずつずらす（無ければ nil）
}

// scrollSpec は部品の scroll: 形を period おきに写して格子を埋め、コマ i で at に speed·i を足す。
// period の既定は speed × コマ数（コマを回すと模様がちょうど 1 周期ずれて、ループの継ぎ目が消える）。
type scrollSpec struct {
	Speed, Period pxlib.Pt
}

// isPoly は部品の形が poly か（shapes の名前で引いた物も）。
func (p *part) isPoly(shapes map[string]any) bool {
	sh := p.Shape
	for i := 0; i < 8; i++ { // 名前の引き直しは数段まで（輪は shapeOf が先に止める）
		switch v := sh.(type) {
		case string:
			sh = shapes[v]
			continue
		case map[string]any:
			if name, ok := v["ref"].(string); ok && len(v) == 1 {
				sh = shapes[name]
				continue
			}
			_, ok := v["poly"]
			return ok
		}
		return false
	}
	return false
}

// problem は指定の書き損じ 1 件。
type problem struct{ Where, Msg string }

func (p problem) Error() string {
	if p.Where == "" {
		return p.Msg
	}
	return p.Where + ": " + p.Msg
}

// problemList は Problem の並び（error として返す）。
type problemList []problem

func (l problemList) Error() string {
	lines := make([]string, len(l))
	for i, p := range l {
		lines[i] = p.Error()
	}
	return strings.Join(lines, "\n")
}

var (
	specKeys   = []string{"version", "title", "note", "target", "base", "palette", "gate", "indent", "style", "light", "ramps", "shapes", "macros", "sprites"}
	lightKeys  = []string{"dir", "gloss", "ground", "note"}
	spriteKeys = []string{"note", "size", "anchor", "ramp", "parts", "post", "frames", "variants", "roles", "anim"}
	partKeys   = []string{"id", "on", "clip", "shape", "ramp", "at", "ops", "note", "material", "rotate", "pivot", "emissive", "scroll"}
	idPattern  = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*$`)
)

type reader struct{ probs problemList }

func (r *reader) bad(where, format string, a ...any) {
	r.probs = append(r.probs, problem{where, fmt.Sprintf(format, a...)})
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

// ops は op の列を読む。post でなければ post にだけ書ける op を止める。
func (r *reader) ops(v any, where string, refs map[string]any, post bool) []opCall {
	arr, ok := v.([]any)
	if !ok {
		r.bad(where, "op の配列で書く")
		return nil
	}
	out := make([]opCall, 0, len(arr))
	for i, e := range arr {
		call, err := parseOpCall(pxlib.Plain(e), fmt.Sprintf("%s[%d]", where, i), refs)
		if err != nil {
			r.probs = append(r.probs, problem{Where: "", Msg: err.Error()})
			continue
		}
		if op, _ := lookupOp(call.Name); op.PostOnly && !post {
			r.bad(call.Where, "格子全体を動かす op なので、スプライトの post にだけ書ける")
			continue
		}
		out = append(out, call)
	}
	return out
}

// loadSpec は指定を読む。書き損じは全部 ProblemList で返す（1 件目で止めない）。
func loadSpec(path string) (*specDoc, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return loadSpecData(path, data)
}

// loadSpecData は読んだ中身から指定を作る（台本がメモリの中で書いた pxsrc も同じ道）。
func loadSpecData(path string, data []byte) (*specDoc, error) {
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

func parseSpec(r *reader, root *pxlib.Obj) *specDoc {
	s := &specDoc{Ramps: map[string][]pxlib.Key{}, Shapes: map[string]any{}, Macros: map[string][]opCall{}}
	r.keys(root, "(一番外)", specKeys)
	ver, _ := root.Get("version")
	if n, ok := ver.(json.Number); !ok || n.String() != fmt.Sprint(specVersion) {
		r.bad("version", "%d と書く（今読めるのは version %d の指定）", specVersion, specVersion)
	}
	s.Version = specVersion
	s.Title, s.Note = r.str(root, "title", ""), r.str(root, "note", "")
	s.Target, s.Base = r.str(root, "target", ""), r.str(root, "base", "")
	s.Palette, s.Gate = r.str(root, "palette", ""), r.str(root, "gate", "")
	if iv, ok := root.Get("indent"); ok {
		s.Indent = indentOf(r, iv)
	}
	s.Style = r.str(root, "style", "")
	if s.Target == "" {
		r.bad("target", "書き出す sprite.json（atelier/ の下）が無い")
	} else if isUnderAssets(s.Target) {
		r.bad("target", "assets/ を指している — 候補は atelier/ に書く（採用は swap）")
	}
	s.Light = lightSpec{Dir: [3]float64{-1, -1, 0}}
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
			s.Light.Gloss = pxlib.Key(r.str(lo, "gloss", "light"))
			s.Light.Ground = colorRef(r.str(lo, "ground", "light"))
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
					r.bad("ramps."+k, "色キーの配列（暗 → 明）で書く")
				}
				for _, key := range list {
					s.Ramps[k] = append(s.Ramps[k], pxlib.Key(key))
				}
			}
		}
	}
	if sv, ok := root.Get("shapes"); ok {
		if so, isObj := pxlib.Plain(sv).(map[string]any); isObj {
			s.Shapes = so
			for _, k := range keysOf(so) {
				if _, err := shapeOf(so[k], so, "shapes."+k); err != nil {
					r.probs = append(r.probs, problem{Msg: err.Error()})
				}
			}
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
				s.Macros[k] = r.ops(vals[i], "macros."+k, s.Shapes, false)
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

func parseSprite(r *reader, s *specDoc, name string, v any) *spriteSpec {
	where := "sprites." + name
	o, ok := v.(*pxlib.Obj)
	if !ok {
		r.bad(where, "オブジェクトで書く")
		return nil
	}
	r.keys(o, where, spriteKeys)
	sp := &spriteSpec{Name: name, Note: r.str(o, "note", where), Ramp: r.str(o, "ramp", where)}
	if sz, ok := o.Get("size"); ok {
		if p := r.ints(sz, 2, where+".size"); p != nil {
			if p[0] < 1 || p[1] < 1 || p[0] > 512 || p[1] > 512 {
				r.bad(where+".size", "1〜512 の [w, h] で書く")
			}
			sp.Size = pxlib.Size{W: p[0], H: p[1]}
		}
	} else {
		r.bad(where+".size", "[w, h] が無い")
	}
	if av, ok := o.Get("anchor"); ok {
		if p := r.ints(av, 2, where+".anchor"); p != nil {
			sp.Anchor = &pxlib.Pt{X: p[0], Y: p[1]}
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
		sp.Post = r.ops(ov, where+".post", s.Shapes, true)
		for _, call := range sp.Post {
			if animOps[call.Name] {
				sp.animated = true
			}
		}
	}
	fv, _ := o.Get("frames")
	frames, ok := fv.(*pxlib.Obj)
	if !ok || frames.Len() == 0 {
		r.bad(where+".frames", "コマ名 → 部品の patch のオブジェクトで書く（変えないコマは {}）")
		return sp
	}
	roles := map[string]string{}
	if rv, ok := o.Get("roles"); ok {
		ro, isObj := rv.(*pxlib.Obj)
		if !isObj {
			r.bad(where+".roles", "役の名前（legF・legB・armF・armB・body・head）→ 部品 id のオブジェクトで書く")
			ro = pxlib.NewObj()
		}
		keys, vals := ro.Items() // 書いた順に回す（誤りの並びを毎回同じにする）
		for i, k := range keys {
			id, isStr := vals[i].(string)
			if !isStr {
				r.bad(where+".roles."+k, "部品 id を文字列で書く（例 \"legR\"）")
				continue
			}
			if _, known := poseRoles[k]; !known {
				r.bad(where+".roles."+k, "知らない役（%s）", strings.Join(poseRoleNames(), " "))
			} else if !ids[id] {
				r.bad(where+".roles."+k, "parts に id %q が無い", id)
			}
			roles[k] = id
		}
	}
	if vv, ok := o.Get("variants"); ok {
		vo, isObj := vv.(*pxlib.Obj)
		var seeds []int
		if isObj {
			sv, _ := vo.Get("seeds")
			arr, _ := sv.([]any)
			for _, e := range arr {
				n, isNum := e.(json.Number)
				iv, err := n.Int64()
				if !isNum || err != nil || iv < 0 {
					seeds = nil
					break
				}
				seeds = append(seeds, int(iv))
			}
		}
		if len(seeds) == 0 {
			r.bad(where+".variants", "{\"seeds\": [1, 2, 3]} で書く（0 以上の整数。散らす op はこの seed だけで決まる）")
		}
		sp.Seeds = seeds
	}
	if av, ok := o.Get("anim"); ok {
		b, isBool := av.(bool)
		if !isBool {
			r.bad(where+".anim", "true か false で書く")
		}
		sp.Anim = &b
	}
	fnames, fvals := frames.Items()
	for i, fname := range fnames {
		patch, isObj := fvals[i].(*pxlib.Obj)
		fw := where + ".frames." + fname
		if !isObj {
			r.bad(fw, "部品 id → patch のオブジェクトで書く（変えないなら {}）")
			continue
		}
		if patch.Has("pose") {
			patch = poseToPatch(r, fw, patch, roles, ids, rawAt(sp.RawParts), rawOn(sp.RawParts))
			sp.animated = true
			if patch == nil {
				continue
			}
		}
		for _, id := range patch.Keys() {
			if !ids[id] {
				r.bad(fw+"."+id, "parts に id %q が無い（コマは今ある部品を直すだけ）", id)
			}
		}
		sp.Frames = append(sp.Frames, frameSpec{fname, patch})
	}
	// 各コマで部品が読めるかを先に確かめる（描く前に書き損じを全部出す）
	for _, f := range sp.Frames {
		sp.partsOf(r, s, f)
	}
	return sp
}

// rawAt は部品 id → patch を当てる前の at（pose のずらしはここに足す）。書き損じの at は読み飛ばす
// （誤りは部品を読む所で場所つきで出る）。
func rawAt(parts []*pxlib.Obj) map[string][2]int {
	out := map[string][2]int{}
	for _, raw := range parts {
		id, _ := raw.GetOr("id", "").(string)
		av, ok := raw.Get("at")
		arr, isArr := av.([]any)
		if !ok || !isArr || len(arr) != 2 {
			continue
		}
		xn, okX := arr[0].(json.Number)
		yn, okY := arr[1].(json.Number)
		x, errX := xn.Int64()
		y, errY := yn.Int64()
		if okX && okY && errX == nil && errY == nil {
			out[id] = [2]int{int(x), int(y)}
		}
	}
	return out
}

// rawOn は部品 id → 親の id（on）。
func rawOn(parts []*pxlib.Obj) map[string]string {
	out := map[string]string{}
	for _, raw := range parts {
		id, _ := raw.GetOr("id", "").(string)
		on, _ := raw.GetOr("on", "").(string)
		out[id] = on
	}
	return out
}

// partsOf はコマの patch を当てた部品の列。
func (sp *spriteSpec) partsOf(r *reader, s *specDoc, f frameSpec) []*part {
	var out []*part
	seen := map[string]bool{}
	byID := map[string]*part{}
	for i, raw := range sp.RawParts {
		id, _ := raw.GetOr("id", "").(string)
		obj := raw
		if pv, ok := f.Patch.Get(id); ok {
			if pv == nil {
				continue
			}
			obj = mergePatch(raw, pv).(*pxlib.Obj)
			// shape は鍵ごとに重ねず丸ごと替える（{"ref": …} に {"disk": …} を重ねると形が 2 つになる）
			if po, isObj := pv.(*pxlib.Obj); isObj {
				if sh, ok := po.Get("shape"); ok && sh != nil {
					obj.Set("shape", sh)
				}
			}
		}
		where := fmt.Sprintf("sprites.%s.parts[%d](%s)", sp.Name, i, id)
		if f.Patch.Has(id) {
			where = fmt.Sprintf("sprites.%s.frames.%s.%s", sp.Name, f.Name, id)
		}
		r.keys(obj, where, partKeys)
		p := &part{ID: id, On: r.str(obj, "on", where), Ramp: r.str(obj, "ramp", where), Where: where}
		if cv, ok := obj.Get("clip"); ok {
			b, isBool := cv.(bool)
			if !isBool {
				r.bad(where+".clip", "true か false で書く")
			}
			p.Clip = b
		}
		if ev, ok := obj.Get("emissive"); ok {
			b, isBool := ev.(bool)
			if !isBool {
				r.bad(where+".emissive", "true か false で書く")
			}
			p.Emissive = b
		}
		if p.Clip && p.On == "" {
			r.bad(where+".clip", "clip は on（親の部品 id）と組で書く")
		}
		if p.On != "" && !seen[p.On] {
			r.bad(where+".on", "親 %q はこの部品より前の列に置く（列の順が重ねる順）", p.On)
		}
		if sh, ok := obj.Get("shape"); ok {
			p.Shape = pxlib.Plain(sh)
			if _, err := shapeOf(p.Shape, s.Shapes, where+".shape"); err != nil {
				r.probs = append(r.probs, problem{Msg: err.Error()})
			}
		}
		if av, ok := obj.Get("at"); ok {
			if a := r.ints(av, 2, where+".at"); a != nil {
				p.At = pxlib.Pt{X: a[0], Y: a[1]}
			}
		}
		p.BaseAt = p.At
		if av, ok := raw.Get("at"); ok && obj != raw {
			if a := r.ints(av, 2, where+".at"); a != nil {
				p.BaseAt = pxlib.Pt{X: a[0], Y: a[1]}
			}
		} else if obj != raw {
			p.BaseAt = pxlib.Pt{}
		}
		if sv, ok := obj.Get("scroll"); ok {
			p.Scroll = r.scroll(sv, where+".scroll", sp)
			if p.Scroll != nil {
				fi := sp.frameIndex(f.Name)
				p.At.X += p.Scroll.Speed.X * fi
				p.At.Y += p.Scroll.Speed.Y * fi
				if p.Scroll.Speed != (pxlib.Pt{}) {
					sp.animated = true
				}
			}
		}
		// on の子は、親がコマで動いた量だけ一緒に動く（頭の上の目・口・髪が頭に付いていく）
		if parent := byID[p.On]; parent != nil {
			p.At.X += parent.At.X - parent.BaseAt.X
			p.At.Y += parent.At.Y - parent.BaseAt.Y
		}
		if rv, ok := obj.Get("rotate"); ok {
			n, isNum := rv.(json.Number)
			f, err := n.Float64()
			if !isNum || err != nil {
				r.bad(where+".rotate", "角度（度）の数で書く")
			}
			p.Rotate = f
			if f != 0 {
				sp.animated = true
			}
		}
		if pv, ok := obj.Get("pivot"); ok {
			arr, isArr := pv.([]any)
			var xy [2]float64
			ok := isArr && len(arr) == 2
			for i := 0; ok && i < 2; i++ {
				n, isNum := arr[i].(json.Number)
				f, err := n.Float64()
				ok = isNum && err == nil && f*2 == math.Trunc(f*2)
				xy[i] = f
			}
			if !ok {
				r.bad(where+".pivot", "[x, y] で書く（整数か .5。.5 は画素の境目）")
			} else {
				p.Pivot = &xy
			}
		}
		if p.Ramp == "" {
			p.Ramp = sp.Ramp
		} else if s.Ramps[p.Ramp] == nil {
			r.bad(where+".ramp", "ramps に %q が無い", p.Ramp)
		}
		if mv, ok := obj.Get("material"); ok {
			p.Ops = append(p.Ops, r.material(pxlib.Plain(mv), fmt.Sprintf("%s.material", id), s.Shapes)...)
		}
		if ov, ok := obj.Get("ops"); ok {
			p.Ops = append(p.Ops, r.ops(ov, fmt.Sprintf("%s.ops", id), s.Shapes, false)...)
		}
		for _, call := range p.Ops {
			if animOps[call.Name] {
				sp.animated = true
			}
		}
		seen[id] = true
		byID[id] = p
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

// indentOf は "indent" を字下げの字面にする: "tab" はタブ、1〜8 の整数はその数の空白。
func indentOf(r *reader, v any) string {
	if v == "tab" {
		return "\t"
	}
	if n, ok := v.(json.Number); ok {
		if i, err := n.Int64(); err == nil && i >= 1 && i <= 8 {
			return strings.Repeat(" ", int(i))
		}
	}
	r.bad("indent", "\"tab\" か 1〜8 の整数（空白の数）で書く")
	return ""
}

// isUnderAssets は path が（./ や ../ で回り道しても）ゲームの assets/ の下を指すか。
func isUnderAssets(path string) bool {
	clean := filepath.ToSlash(filepath.Clean(path))
	return clean == "assets" || strings.HasPrefix(clean, "assets/") || strings.Contains(clean, "/assets/") || strings.HasPrefix(clean, "../")
}

// specName は spec（か台本）のファイル名から種類の拡張子を外した物（見本の置き場と周の名前）。
func specName(specPath string) string {
	return strings.TrimSuffix(strings.TrimSuffix(filepath.Base(specPath), ".pxsrc.json"), ".px.star")
}

func dedupe(l problemList) problemList {
	seen := map[problem]bool{}
	var out problemList
	for _, p := range l {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}

// frameIndex はコマの並びの中の番号（無ければ 0）。
func (sp *spriteSpec) frameIndex(name string) int {
	for i, f := range sp.Frames {
		if f.Name == name {
			return i
		}
	}
	return 0
}

// scroll は部品の scroll {"speed": [dx, dy], "period": [px, py]} を読む。period を省くと speed × コマ数。
func (r *reader) scroll(v any, where string, sp *spriteSpec) *scrollSpec {
	o, ok := v.(*pxlib.Obj)
	if !ok {
		r.bad(where, "{\"speed\": [dx, dy], \"period\": [px, py]} で書く（period は省ける）")
		return nil
	}
	r.keys(o, where, []string{"speed", "period"})
	sv, ok := o.Get("speed")
	if !ok {
		r.bad(where+".speed", "1 コマにずらす画素 [dx, dy] を書く")
		return nil
	}
	a := r.ints(sv, 2, where+".speed")
	if a == nil {
		return nil
	}
	sc := &scrollSpec{Speed: pxlib.Pt{X: a[0], Y: a[1]}}
	n := len(sp.Frames)
	sc.Period = pxlib.Pt{X: abs(a[0]) * n, Y: abs(a[1]) * n}
	if pv, ok := o.Get("period"); ok {
		if b := r.ints(pv, 2, where+".period"); b != nil {
			if b[0] < 0 || b[1] < 0 {
				r.bad(where+".period", "0 以上で書く（0 はその向きに写さない）")
			}
			sc.Period = pxlib.Pt{X: b[0], Y: b[1]}
		}
	}
	return sc
}
