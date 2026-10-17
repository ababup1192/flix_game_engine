package snd

// spec（<名前>.sndsrc.json）: 音 1 本の指定。
//
//	{"version": 1, "style": "gb", "kind": "sfx", "rate": 22050, "target": "atelier/sfx/slash.wav",
//	 "voices": [{"id": "hiss", "at": 0, "ops": [{"noise": {...}}, {"steps": {...}}]}],
//	 "post": [{"gain": {"by": 0.5}}],
//	 "loop_start_ms": 0, "tempo": {"bpm": 175, "beats_per_bar": 4}, "channels": "stereo"}
//
// 声は at ミリ秒の所に置き、pan（-1 = 左・0 = 真ん中・1 = 右）で左右に振って声の順に足す。post は足した後に順に掛ける。ループの頭は song の op が決めるか、
// loop_start_ms で書く（両方は書けない）。tempo を書くと（song は譜面の bpm から）輪の長さが整数小節かを見る。
// 書き出しは 16bit の WAV（channels: stereo が既定・mono で今までどおり 1 本。ループがあれば smpl）。target は assets/ の外（AI が作る物は atelier/）。

import (
	"encoding/json"
	"fmt"
	"math"
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
	Pan float64
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
	Channels    int               // 1 = mono・2 = stereo
	Files       map[string][]byte // 台本が書いた譜面（write_chip。JSON には書かない）
}

var kinds = []string{"ui", "sfx", "bgm"}

var specKeys = map[string]bool{"version": true, "note": true, "style": true, "kind": true, "rate": true, "target": true,
	"voices": true, "post": true, "loop_start_ms": true, "tempo": true, "channels": true}

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
			bad("知らない鍵 %q（書ける鍵: version note style kind rate target voices post loop_start_ms tempo channels）", k)
		}
	}
	s := &spec{Path: path, Style: "free", Kind: "sfx", Rate: 22050, Channels: 2}
	switch root["channels"] {
	case nil, "stereo":
	case "mono":
		s.Channels = 1
	default:
		bad("channels は \"stereo\"（既定）か \"mono\"")
	}
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
		if p, ok := m["pan"].(float64); ok {
			vo.Pan = p
			if p < -1 || p > 1 {
				bad("%s: pan は -1（左）〜 1（右）", where)
			}
		}
		for k := range m {
			if k != "id" && k != "at" && k != "ops" && k != "pan" {
				bad("%s: 知らない鍵 %q（id at pan ops）", where, k)
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

// rendered は書き出した音（±1 に収める前の値。out はチャンネルごと）。
type rendered struct {
	out       [][]float64
	loopStart int
	tempo     *tempo
	clamped   int
	parts     [][]part // 声ごとの部品
	spans     [][2]int // 声ごとの [頭, 終わり)（サンプル）
	breaks    []string // 使った機種の外の手（声の順・重ならない）
	pans      []float64
}

func (r *rendered) frames() int {
	if len(r.out) == 0 {
		return 0
	}
	return len(r.out[0])
}

func (r *rendered) addBreak(b string) {
	if b != "" && !contains(r.breaks, b) {
		r.breaks = append(r.breaks, b)
	}
}

// renderer は spec を鳴らす。音源の結果は覚えて、外した op を変えて何度も鳴らせる（原因の op を引くため）。
type renderer struct {
	s     *spec
	c     *rctx
	cache map[opRef]sourceOut
}

func newRenderer(c *rctx, s *spec) *renderer {
	return &renderer{s: s, c: c, cache: map[opRef]sourceOut{}}
}

// balance は pan（-1〜1）の左右の倍率（真ん中は両方 1・振り切ると片方 0）。
func balance(pan float64) (float64, float64) {
	return math.Min(1, 1-pan), math.Min(1, 1+pan)
}

// render は off の op を外して鳴らす（外した音源の声は鳴らない・外した効果は素通し）。
func (r *renderer) render(off map[opRef]bool) (*rendered, error) {
	s := r.s
	res := &rendered{loopStart: -1, tempo: s.Tempo}
	type placed struct {
		x  sig
		at int
	}
	var voices []placed
	total := 0
	for v, vo := range s.Voices {
		res.parts = append(res.parts, nil)
		res.spans = append(res.spans, [2]int{})
		src := opRef{v, 0}
		if off[src] {
			voices = append(voices, placed{})
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
		x := sig{ch: so.ch, loopStart: so.loopStart}
		for _, b := range so.breaks {
			res.addBreak(b)
		}
		if s.Channels == 2 {
			res.pans = append(res.pans, so.pans...)
		}
		for j := 1; j < len(vo.Ops); j++ {
			if off[opRef{v, j}] {
				continue
			}
			d := registry[vo.Ops[j].Name]
			var err error
			if x, err = applyFx(d, r.c, x, vo.Ops[j].Args); err != nil {
				return nil, fmt.Errorf("%s: %v", vo.Ops[j].Where, err)
			}
			res.addBreak(d.Break)
		}
		at := r.c.offset(vo.At)
		if x.loopStart >= 0 {
			res.loopStart = at + x.loopStart
		}
		if so.tempo != nil && res.tempo == nil {
			res.tempo = so.tempo
		}
		if s.Channels == 2 {
			res.pans = append(res.pans, vo.Pan)
		}
		res.clamped += so.clamped
		res.parts[v] = so.parts
		res.spans[v] = [2]int{at, at + x.frames()}
		voices = append(voices, placed{x, at})
		total = max(total, at+x.frames())
	}
	bus := sig{loopStart: res.loopStart}
	for k := 0; k < s.Channels; k++ {
		bus.ch = append(bus.ch, make([]float64, total))
	}
	for v, p := range voices {
		if p.x.ch == nil {
			continue
		}
		if s.Channels == 1 {
			for i := range p.x.ch[0] {
				m := p.x.ch[0][i]
				if len(p.x.ch) == 2 {
					m = float64(m+p.x.ch[1][i]) * 0.5
				}
				bus.ch[0][p.at+i] = bus.ch[0][p.at+i] + m
			}
			continue
		}
		gl, gr := balance(s.Voices[v].Pan)
		l, rr := p.x.ch[0], p.x.ch[0]
		if len(p.x.ch) == 2 {
			rr = p.x.ch[1]
		}
		for i := range l {
			bus.ch[0][p.at+i] = bus.ch[0][p.at+i] + float64(l[i]*gl)
			bus.ch[1][p.at+i] = bus.ch[1][p.at+i] + float64(rr[i]*gr)
		}
	}
	for j, c := range s.Post {
		if off[opRef{-1, j}] {
			continue
		}
		d := registry[c.Name]
		var err error
		if bus, err = applyFx(d, r.c, bus, c.Args); err != nil {
			return nil, fmt.Errorf("%s: %v", c.Where, err)
		}
		res.addBreak(d.Break)
	}
	for _, p := range res.pans {
		if p != 0 && p != 1 && p != -1 {
			res.addBreak("pan") // 振り切り（左・両方・右）より細かい左右は機種の外
			break
		}
	}
	res.loopStart = bus.loopStart
	if s.LoopStartMs != nil && bus.frames() > 0 {
		res.loopStart = min(bus.frames()-1, r.c.offset(*s.LoopStartMs))
	}
	res.out = bus.ch
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
