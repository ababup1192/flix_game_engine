package snd

// spec（<名前>.sndsrc.json）: 音 1 本の指定。
//
//	{"version": 1, "style": "gb", "kind": "sfx", "rate": 22050, "target": "atelier/sfx/slash.wav",
//	 "voices": [{"id": "hiss", "at": 0, "ops": [{"noise": {...}}, {"steps": {...}}]}],
//	 "post": [{"gain": {"by": 0.5}}],
//	 "loop_start_ms": 0, "tempo": {"bpm": 175, "beats_per_bar": 4}}
//
// 声は at ミリ秒の所に置き、声の順に足す。post は足した後に順に掛ける。ループの頭は song の op が決めるか、
// loop_start_ms で書く（両方は書けない）。tempo を書くと（song は譜面の bpm から）輪の長さが整数小節かを見る。
// 書き出しは 16bit モノラルの WAV（ループがあれば smpl）。target は assets/ の外（AI が作る物は atelier/）。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
	"github.com/ababup1192/flix_game_engine/go/internal/starbox"
)

type tempo struct {
	BPM         float64 `json:"bpm"`
	BeatsPerBar int     `json:"beats_per_bar"`
}

type voice struct {
	ID  string
	At  float64
	Ops []opreg.Call
}

type spec struct {
	Path        string
	Style       string
	Kind        string
	Rate        int
	Target      string
	Voices      []voice
	Post        []opreg.Call
	LoopStartMs *float64
	Tempo       *tempo
}

var kinds = []string{"ui", "sfx", "bgm"}

var specKeys = map[string]bool{"version": true, "note": true, "style": true, "kind": true, "rate": true, "target": true,
	"voices": true, "post": true, "loop_start_ms": true, "tempo": true}

// parseSpec は JSON を読んで spec にする。op の引数は登録の型と範囲で確かめる。
func parseSpec(path string, data []byte) (*spec, error) {
	var root map[string]any
	if err := json.Unmarshal(data, &root); err != nil {
		return nil, fmt.Errorf("%s: JSON として壊れている: %v", path, err)
	}
	var probs []string
	bad := func(f string, a ...any) { probs = append(probs, fmt.Sprintf(f, a...)) }
	keys := make([]string, 0, len(root))
	for k := range root {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if !specKeys[k] {
			bad("知らない鍵 %q（書ける鍵: version note style kind rate target voices post loop_start_ms tempo）", k)
		}
	}
	s := &spec{Path: path, Style: "free", Kind: "sfx", Rate: 22050}
	if v, ok := root["style"].(string); ok {
		s.Style = v
	}
	if v, ok := root["kind"].(string); ok {
		s.Kind = v
	}
	if !contains(kinds, s.Kind) {
		bad("kind は %s のどれか（got %q）", strings.Join(kinds, "・"), s.Kind)
	}
	if v, ok := root["rate"].(float64); ok {
		s.Rate = int(v)
	}
	if s.Rate < 8000 || s.Rate > 96000 {
		bad("rate は 8000〜96000（got %d）", s.Rate)
	}
	s.Target, _ = root["target"].(string)
	switch {
	case s.Target == "":
		bad("target（書き出す WAV のパス）が無い")
	case !strings.HasSuffix(s.Target, ".wav"):
		bad("target は .wav で終わる名前にする（got %q）", s.Target)
	case starbox.IsUnderAssets(s.Target):
		bad("target %q は assets/ の下（AI が作る物は atelier/ へ。採用は swap）", s.Target)
	}
	if v, ok := root["loop_start_ms"].(float64); ok {
		s.LoopStartMs = &v
	} else if root["loop_start_ms"] != nil {
		bad("loop_start_ms は数で書く")
	}
	if t, ok := root["tempo"].(map[string]any); ok {
		tp := &tempo{BeatsPerBar: 4}
		tp.BPM, _ = t["bpm"].(float64)
		if b, ok := t["beats_per_bar"].(float64); ok {
			tp.BeatsPerBar = int(b)
		}
		if tp.BPM <= 0 || tp.BeatsPerBar <= 0 {
			bad("tempo は {\"bpm\": 正の数, \"beats_per_bar\": 正の整数}")
		}
		s.Tempo = tp
	}
	vs, _ := root["voices"].([]any)
	if len(vs) == 0 {
		bad("voices（声の並び）が無い")
	}
	ids := map[string]bool{}
	for i, v := range vs {
		where := fmt.Sprintf("voices[%d]", i)
		m, ok := v.(map[string]any)
		if !ok {
			bad("%s: 声は {\"id\": …, \"at\": ミリ秒, \"ops\": […]} で書く", where)
			continue
		}
		vo := voice{ID: fmt.Sprintf("v%d", i)}
		if id, ok := m["id"].(string); ok && id != "" {
			vo.ID = id
		}
		if ids[vo.ID] {
			bad("%s: id %q が重なっている", where, vo.ID)
		}
		ids[vo.ID] = true
		where = fmt.Sprintf("voices[%d](%s)", i, vo.ID)
		vo.At, _ = m["at"].(float64)
		for k := range m {
			if k != "id" && k != "at" && k != "ops" {
				bad("%s: 知らない鍵 %q（id at ops）", where, k)
			}
		}
		ops, _ := m["ops"].([]any)
		if len(ops) == 0 {
			bad("%s: ops が無い（音源の op 1 つから始める）", where)
		}
		for j, o := range ops {
			c, err := opreg.Parse(o, fmt.Sprintf("%s.ops[%d]", where, j), lookupParams)
			if err != nil {
				bad("%v", err)
				continue
			}
			if src := registry[c.Name].source(); src != (j == 0) {
				if j == 0 {
					bad("%s: 声の最初は音源の op（%s）", c.Where, strings.Join(sourceNames(), "・"))
				} else {
					bad("%s: 音源の op は声の最初にだけ書ける（重ねるなら声を分ける）", c.Where)
				}
			}
			vo.Ops = append(vo.Ops, c)
		}
		s.Voices = append(s.Voices, vo)
	}
	posts, _ := root["post"].([]any)
	for k, o := range posts {
		c, err := opreg.Parse(o, fmt.Sprintf("post[%d]", k), lookupParams)
		if err != nil {
			bad("%v", err)
			continue
		}
		if registry[c.Name].source() {
			bad("%s: post には効果の op だけ書ける", c.Where)
		}
		s.Post = append(s.Post, c)
	}
	if len(probs) > 0 {
		return nil, fmt.Errorf("%s: 指定の書き損じ\n  %s", path, strings.Join(probs, "\n  "))
	}
	return s, nil
}

func contains(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

func sourceNames() []string {
	var out []string
	for _, d := range allOps() {
		if d.source() {
			out = append(out, d.Name)
		}
	}
	return out
}

func loadSpec(workRoot, path string) (*spec, error) {
	full := path
	if !filepath.IsAbs(full) {
		full = filepath.Join(workRoot, path)
	}
	data, err := os.ReadFile(full)
	if err != nil {
		return nil, err
	}
	return parseSpec(filepath.ToSlash(starbox.Rel(workRoot, full)), data)
}

// ── 書き出し ──

// opRef は spec の中の op 1 つ（声 v の ops[j]、v = -1 は post[j]）。
type opRef struct{ v, j int }

func (s *spec) call(r opRef) opreg.Call {
	if r.v < 0 {
		return s.Post[r.j]
	}
	return s.Voices[r.v].Ops[r.j]
}

// refs は spec の op を書き出しの順（声の順に ops、最後に post）に並べる。
func (s *spec) refs() []opRef {
	var out []opRef
	for v, vo := range s.Voices {
		for j := range vo.Ops {
			out = append(out, opRef{v, j})
		}
	}
	for j := range s.Post {
		out = append(out, opRef{-1, j})
	}
	return out
}

// rendered は書き出した音（±1 に収める前の値）。
type rendered struct {
	out       []float64
	loopStart int
	tempo     *tempo
	clamped   int
	parts     [][]part // 声ごとの部品
	spans     [][2]int // 声ごとの [頭, 終わり)（サンプル）
}

// renderer は spec を鳴らす。音源の結果は覚えて、外した op を変えて何度も鳴らせる（原因の op を引くため）。
type renderer struct {
	s     *spec
	c     *rctx
	cache map[opRef]sourceOut
}

func newRenderer(workRoot string, s *spec) *renderer {
	return &renderer{s: s, c: &rctx{rate: float64(s.Rate), workRoot: workRoot}, cache: map[opRef]sourceOut{}}
}

// render は off の op を外して鳴らす（外した音源の声は鳴らない・外した効果は素通し）。
func (r *renderer) render(off map[opRef]bool) (*rendered, error) {
	s := r.s
	res := &rendered{loopStart: -1, tempo: s.Tempo}
	var voices [][]float64
	var offsets []int
	total := 0
	for v, vo := range s.Voices {
		res.parts = append(res.parts, nil)
		res.spans = append(res.spans, [2]int{})
		src := opRef{v, 0}
		if off[src] {
			voices = append(voices, nil)
			offsets = append(offsets, 0)
			continue
		}
		so, ok := r.cache[src]
		if !ok {
			var err error
			if so, err = registry[vo.Ops[0].Name].Gen(r.c, vo.Ops[0].Args); err != nil {
				return nil, fmt.Errorf("%s: %v", vo.Ops[0].Where, err)
			}
			r.cache[src] = so
		}
		x := so.s
		for j := 1; j < len(vo.Ops); j++ {
			if off[opRef{v, j}] {
				continue
			}
			var err error
			if x, err = registry[vo.Ops[j].Name].Fx(r.c, x, vo.Ops[j].Args); err != nil {
				return nil, fmt.Errorf("%s: %v", vo.Ops[j].Where, err)
			}
		}
		at := r.c.offset(vo.At)
		if so.loopStart >= 0 {
			res.loopStart = at + so.loopStart
		}
		if so.tempo != nil && res.tempo == nil {
			res.tempo = so.tempo
		}
		res.clamped += so.clamped
		res.parts[v] = so.parts
		res.spans[v] = [2]int{at, at + len(x)}
		voices = append(voices, x)
		offsets = append(offsets, at)
		total = max(total, at+len(x))
	}
	out := make([]float64, total)
	for k, x := range voices {
		for i, v := range x {
			out[offsets[k]+i] = out[offsets[k]+i] + v
		}
	}
	for j, c := range s.Post {
		if off[opRef{-1, j}] {
			continue
		}
		var err error
		if out, err = registry[c.Name].Fx(r.c, out, c.Args); err != nil {
			return nil, fmt.Errorf("%s: %v", c.Where, err)
		}
	}
	if s.LoopStartMs != nil && len(out) > 0 {
		res.loopStart = min(len(out)-1, r.c.offset(*s.LoopStartMs))
	}
	res.out = out
	return res, nil
}

// cause は「その op を外すと bad でなくなる」op を引く。効果の op を先に（書き出しの順で後ろの物）、
// 無ければ音源の op（外すと直る声が 2 つ以上なら全部を並べる）。外した声は鳴らない・外した効果は素通し。
func (r *renderer) cause(bad func(*rendered) bool) string {
	var fx, src []string
	for _, ref := range r.s.refs() {
		res, err := r.render(map[opRef]bool{ref: true})
		if err != nil || bad(res) {
			continue
		}
		if ref.j == 0 && ref.v >= 0 {
			src = append(src, r.s.call(ref).Where)
		} else {
			fx = append(fx, r.s.call(ref).Where)
		}
	}
	switch {
	case len(fx) > 0:
		return fx[len(fx)-1]
	case len(src) == 1:
		return src[0]
	case len(src) > 1:
		return strings.Join(src, " ＋ ") + "（どれか 1 つを外すと直る: 声どうしの重なりか長さ）"
	}
	return "（どの op を 1 つ外しても直らない: 声の数か post を見直す）"
}
