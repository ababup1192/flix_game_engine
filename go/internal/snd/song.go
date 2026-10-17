package snd

// song の op: トラッカーの譜面（*.chip.json。phrase 16 段 → chain → rows）を楽器で鳴らす。読む所はこのファイル、
// 鳴らす所は song_play.go。今の形（ゲームの ChipDoc・InstrumentDoc と同じ 5 本のチャンネル）はそのまま読める。
//
// 足した欄（書かなければ今までどおり）:
//   - channels: チャンネルを名前で持つ [{"name": "lead", "part": "pulse", "vol": 0.2, "pan": -0.3, "cents": 6,
//     "sub": 0.3, "duck": true, "send": {"reverb": 0.3, "delay": 0.2}}]。rows の鍵はこの名前。数は style の voices で縛る。
//   - groove: 段ごとの tick の並び（[7, 5] で跳ねる。平均が 1 段の tick・長さは 16 を割り切る数）。
//   - fx: 機種の外の厚み {"reverb": {…}, "delay": {"steps": 3, …}, "sidechain": {"key": ["kick"], "depth_db": 4, "release_ms": 160}}。
//   - instruments・waves: 楽器を譜面の中に書ける（instruments のファイルと同じ形。譜面の方が勝つ）。
//   - 段のコマンド: DLY n（頭を n tick 遅らせる）・CUT n（n tick で離す）・RTG n（n tick ごとに打ち直す）・
//     VSL n（1 tick に n/8 段ずつ音量を滑らせる）を 1 段に並べて書ける（SLD n は前の音から滑る）。
//   - 楽器の表（macro）: "vol"・"arp"・"pitch"・"duty" を別の長さで書き、"|" の後がループ・"/" の後が離した後（release）。

import (
	"encoding/json"
	"fmt"
	"math"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
)

func init() {
	register(&opDef{
		Name:    "song",
		Summary: "譜面（*.chip.json）を楽器（譜面の中か *.instrument.json）で鳴らす。左右に振って混ぜ、ループ点があれば頭 + 輪の 1 本と smpl のループの頭を作る",
		Machine: "譜面のチャンネル（今の形は pulse1・pulse2 = パルス・triangle = 三角・noise = 雑音・wave = 波形メモリ。channels を書けば名前と部品を選べる）。使った部品を機種の縛りで数え、reverb・delay・sidechain・sub・pan は style の breaks で見る",
		Example: `{"song": {"chip": "testdata/snd/tiny.chip.json", "instruments": "testdata/snd/tiny.instrument.json"}}`,
		Params: []opreg.Param{
			{Name: "chip", Type: opreg.String, Required: true, Summary: "譜面のパス（作業場の根から。台本の snd.write_chip が書いた物も読める）"},
			{Name: "instruments", Type: opreg.String, Summary: "楽器のパス（作業場の根から。省くと譜面の中の instruments だけ）"},
		},
		Gen: genSong,
	})
}

// ── 譜面の部品（ChipDoc） ──

type pitchKind int

const (
	pitchHold pitchKind = iota // 何もしない
	pitchOff                   // 音を離す（楽器に release があれば離した後の表へ・無ければ止める）
	pitchNote                  // 新しい音
)

type cmdKind int

const (
	cmdNone cmdKind = iota
	cmdArp
	cmdVib
	cmdSlide
	cmdJump
	cmdLoop
	cmdEnd
	cmdDelay    // DLY n: 段の頭を n tick 遅らせる
	cmdCut      // CUT n: n tick で離す
	cmdRetrig   // RTG n: n tick ごとに打ち直す
	cmdVolSlide // VSL n: 1 tick に n/8 段ずつ音量を滑らせる
)

// stepCmds は段のコマンドの説明（docs の譜面の節に出す）。
var stepCmds = []struct{ Word, Summary string }{
	{"ARP a b c", "1 tick ごとに半音 a・b・c… を回す（1 本で和音）"},
	{"VIB hz cents", "ビブラート"},
	{"SLD n", "前の音から n tick で滑って着く（次の音へ滑る）"},
	{"DLY n", "段の頭を n tick 遅らせる（段の長さ未満。前の音はその間鳴り続ける）"},
	{"CUT n", "鳴らしてから n tick で離す（段をまたいで数える。楽器に release があれば離した後の表へ）"},
	{"RTG n", "n tick ごとに同じ音を打ち直す"},
	{"VSL n", "1 tick に n/8 段ずつ音量を滑らせる（負は下げる。次の音で止まる）"},
}

var cmdWords = map[string]bool{"ARP": true, "VIB": true, "SLD": true, "JMP": true, "LOOP": true, "END": true,
	"DLY": true, "CUT": true, "RTG": true, "VSL": true}

type cmd struct {
	kind      cmdKind
	arp       []int
	hz, cents float64
	n, times  int // Slide・Delay・Cut・Retrig の tick・VolSlide の量・Jump / Loop の行・Loop の回数
}

type step struct {
	pitch      pitchKind
	note       int
	instrument string // "" = 前の段の楽器
	volume     int    // -1 = 書いていない
	cmds       []cmd
}

func (st step) arg(k cmdKind) (int, bool) {
	for _, c := range st.cmds {
		if c.kind == k {
			return c.n, true
		}
	}
	return 0, false
}

type chainEntry struct {
	phrase    string
	transpose int
}

// chanDef はチャンネル 1 本（名前・部品・音量・左右・デチューン・サブ・沈める・送り）。
type chanDef struct {
	name                  string
	part                  part
	vol, pan, cents, sub  float64
	duck                  bool
	sendReverb, sendDelay float64
}

// 今の形の 5 本（channels を書かない譜面）。
var legacyChannels = []chanDef{
	{name: "pulse1", part: partPulse, vol: 0.2},
	{name: "pulse2", part: partPulse, vol: 0.2},
	{name: "triangle", part: partTriangle, vol: 0.3},
	{name: "noise", part: partNoise, vol: 0.16},
	{name: "wave", part: partWave, vol: 0.22},
}

var partVol = map[part]float64{partPulse: 0.2, partTriangle: 0.3, partNoise: 0.16, partWave: 0.22}

type songFx struct {
	reverb     *reverbParam
	delay      *delayParam
	delaySteps float64
	duckKeys   []string
	duckDepth  float64 // 沈める深さ（倍率で引く量 0〜1）
	duckMs     float64
}

type song struct {
	bpm    float64
	ticks  int
	groove []int
	loop   int
	rate   int
	gain   float64
	chans  []chanDef
	phrase map[string][]step
	chains map[string][]chainEntry
	rows   []map[int]string // チャンネルの番号 → chain の名前
	fx     songFx
	inline map[string]any // 譜面の中の instruments・waves
}

const phraseSteps = 16

// ── 楽器（InstrumentDoc） ──

type waveKind int

const (
	waveDuty waveKind = iota
	waveShort
	waveLong
	waveTable
)

type waveSel struct {
	kind waveKind
	duty float64
	name string
}

type tableRow struct {
	volume, pitch, cents *int
	wave                 *waveSel
	cmd                  cmd
}

// macroSeq は楽器の表 1 本（値の並び・ループの頭・離した後の頭。無ければ -1）。
type macroSeq struct {
	vals          []int
	waves         []waveSel // duty の表の時
	loop, release int
}

func (m *macroSeq) size() int { return max(len(m.vals), len(m.waves)) }

// next は表の次の位置。離す前はループ（無ければ release の手前か終わりで止まる）・離した後は終わりまで進んで止まる。
func (m *macroSeq) next(pos int, released bool) int {
	end := m.size()
	if !released && m.release >= 0 {
		end = m.release
	}
	switch {
	case pos+1 < end:
		return pos + 1
	case m.loop >= 0 && m.loop < end && (!released || m.loop >= m.release):
		return m.loop
	}
	return min(pos, m.size()-1)
}

type macros struct {
	vol, arp, pitch, duty *macroSeq
	arpFixed              bool
	vibHz, vibCents       float64
	vibDelay              int
}

func (m *macros) hasRelease() bool {
	for _, s := range []*macroSeq{m.vol, m.arp, m.pitch, m.duty} {
		if s != nil && s.release >= 0 {
			return true
		}
	}
	return false
}

type instrument struct {
	speed int
	rows  []tableRow
	mac   *macros // 表の形（rows の代わり）
}

type instruments struct {
	byName map[string]instrument
	waves  map[string][]int
}

func ip(v int) *int { return &v }

func plainInstrument() instrument {
	return instrument{speed: 1, rows: []tableRow{{volume: ip(15), pitch: ip(0), cents: ip(0)}}}
}

func (in instruments) of(name string) instrument {
	if i, ok := in.byName[name]; ok {
		return i
	}
	return plainInstrument()
}

// ── 読む（今の形と既定は ChipDoc.fromRoot・InstrumentDoc.fromRoot と同じ） ──

func intOr(m map[string]any, k string, def int) int {
	if f, ok := m[k].(float64); ok && f == math.Trunc(f) {
		return int(f)
	}
	return def
}

func floatOr(m map[string]any, k string, def float64) float64 {
	if f, ok := m[k].(float64); ok {
		return f
	}
	return def
}

func stringsOf(v any) []string {
	arr, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, e := range arr {
		s, ok := e.(string)
		if !ok {
			return nil
		}
		out = append(out, s)
	}
	return out
}

func wordsOf(s string) []string {
	var out []string
	for _, w := range strings.Split(s, " ") {
		if w = strings.TrimSpace(w); w != "" {
			out = append(out, w)
		}
	}
	return out
}

func atoi(s string) (int, bool) {
	v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 32)
	return int(v), err == nil
}

func atof(s string) (float64, bool) {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return v, err == nil
}

func isVolumeWord(w string) bool {
	if !strings.HasPrefix(w, "v") {
		return false
	}
	_, ok := atoi(w[1:])
	return ok
}

func parseStep(text string) step {
	words := wordsOf(text)
	if len(words) == 0 {
		return step{volume: -1}
	}
	st := step{pitch: pitchHold, volume: -1}
	st.pitch, st.note = parsePitch(words[0])
	rest := words[1:]
	k := 0
	for k < len(rest) && !cmdWords[rest[k]] {
		k++
	}
	head := rest[:k]
	for _, w := range head {
		if isVolumeWord(w) {
			v, _ := atoi(w[1:])
			st.volume = max(0, min(15, v))
			break
		}
	}
	for _, w := range head {
		if !isVolumeWord(w) {
			st.instrument = w
			break
		}
	}
	// コマンドは語の頭で区切る（"DLY 2 VSL -1" は 2 つ）
	var cur []string
	flush := func() {
		if len(cur) > 0 {
			if c := parseCmd(strings.Join(cur, " ")); c.kind != cmdNone {
				st.cmds = append(st.cmds, c)
			}
		}
		cur = nil
	}
	for _, w := range rest[k:] {
		if cmdWords[w] {
			flush()
		}
		cur = append(cur, w)
	}
	flush()
	return st
}

func parsePitch(text string) (pitchKind, int) {
	if text == "OFF" {
		return pitchOff, 0
	}
	r := []rune(strings.ToUpper(text))
	if len(r) != 3 {
		return pitchHold, 0
	}
	base := map[rune]int{'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
	b, okB := base[r[0]]
	o, okO := atoi(string(r[2]))
	if !okB || !okO || (r[1] != '#' && r[1] != '-') {
		return pitchHold, 0
	}
	sharp := 0
	if r[1] == '#' {
		sharp = 1
	}
	return pitchNote, 12*(o+1) + b + sharp
}

func parseCmd(text string) cmd {
	w := wordsOf(text)
	if len(w) == 0 {
		return cmd{}
	}
	ints := func(ws []string) []int {
		var out []int
		for _, s := range ws {
			if v, ok := atoi(s); ok {
				out = append(out, v)
			}
		}
		return out
	}
	args := w[1:]
	first := func(lo int) (cmd, bool) {
		if is := ints(args); len(is) > 0 {
			return cmd{n: max(lo, is[0])}, true
		}
		return cmd{}, false
	}
	switch w[0] {
	case "ARP":
		return cmd{kind: cmdArp, arp: ints(args)}
	case "VIB":
		var fs []float64
		for _, s := range args {
			if v, ok := atof(s); ok {
				fs = append(fs, v)
			}
		}
		if len(fs) >= 2 {
			return cmd{kind: cmdVib, hz: fs[0], cents: fs[1]}
		}
		return cmd{kind: cmdVib}
	case "LOOP":
		switch is := ints(args); {
		case len(is) >= 2:
			return cmd{kind: cmdLoop, n: max(0, is[0]), times: max(0, is[1])}
		case len(is) == 1:
			return cmd{kind: cmdLoop, n: max(0, is[0])}
		}
	case "END":
		return cmd{kind: cmdEnd}
	case "VSL":
		if is := ints(args); len(is) > 0 {
			return cmd{kind: cmdVolSlide, n: is[0]}
		}
	}
	kinds := map[string]struct {
		k  cmdKind
		lo int
	}{"SLD": {cmdSlide, 1}, "JMP": {cmdJump, 0}, "DLY": {cmdDelay, 0}, "CUT": {cmdCut, 0}, "RTG": {cmdRetrig, 1}}
	if k, ok := kinds[w[0]]; ok {
		if c, ok := first(k.lo); ok {
			c.kind = k.k
			return c
		}
	}
	return cmd{}
}

func parseChainEntry(text string) (chainEntry, bool) {
	w := wordsOf(text)
	switch {
	case len(w) == 0:
		return chainEntry{}, false
	case len(w) == 1:
		return chainEntry{phrase: w[0]}, true
	}
	t, _ := atoi(strings.TrimPrefix(w[1], "+"))
	return chainEntry{phrase: w[0], transpose: t}, true
}

func readJSONObject(c *rctx, path string) (map[string]any, error) {
	data, err := c.readFile(path)
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("%s: JSON として壊れている: %w", path, err)
	}
	return m, nil
}

func objectOf(m map[string]any, k string) map[string]any {
	o, _ := m[k].(map[string]any)
	return o
}

var partNames = map[string]part{"pulse": partPulse, "triangle": partTriangle, "noise": partNoise, "wave": partWave}

func parseChannels(root map[string]any) ([]chanDef, error) {
	raw, ok := root["channels"].([]any)
	if !ok {
		if root["channels"] != nil {
			return nil, fmt.Errorf("channels は [{\"name\": …, \"part\": …}, …] の並びで書く")
		}
		out := append([]chanDef{}, legacyChannels...)
		for i := range out {
			if f, ok := objectOf(root, "mix")[out[i].name].(float64); ok {
				out[i].vol = float64(out[i].vol * math.Max(0, f))
			}
		}
		return out, nil
	}
	var out []chanDef
	seen := map[string]bool{}
	for i, r := range raw {
		m, ok := r.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("channels[%d] はオブジェクトで書く", i)
		}
		name, _ := m["name"].(string)
		pn, _ := m["part"].(string)
		p, okP := partNames[pn]
		switch {
		case name == "":
			return nil, fmt.Errorf("channels[%d]: name が無い", i)
		case seen[name]:
			return nil, fmt.Errorf("channels[%d]: name %q が重なっている", i, name)
		case !okP:
			return nil, fmt.Errorf("channels[%d](%s): part は pulse・triangle・noise・wave のどれか（got %q）", i, name, pn)
		}
		seen[name] = true
		for k := range m {
			if !map[string]bool{"name": true, "part": true, "vol": true, "pan": true, "cents": true, "sub": true, "duck": true, "send": true, "note": true}[k] {
				return nil, fmt.Errorf("channels[%d](%s): 知らない鍵 %q（name part vol pan cents sub duck send）", i, name, k)
			}
		}
		d := chanDef{name: name, part: p, vol: floatOr(m, "vol", partVol[p]), pan: floatOr(m, "pan", 0),
			cents: floatOr(m, "cents", 0), sub: floatOr(m, "sub", 0)}
		d.duck, _ = m["duck"].(bool)
		d.sendReverb = floatOr(objectOf(m, "send"), "reverb", 0)
		d.sendDelay = floatOr(objectOf(m, "send"), "delay", 0)
		if d.pan < -1 || d.pan > 1 || d.vol < 0 || d.sub < 0 {
			return nil, fmt.Errorf("channels[%d](%s): pan は -1〜1・vol と sub は 0 以上", i, name)
		}
		out = append(out, d)
	}
	return out, nil
}

func parseSongFx(m map[string]any, s *song) error {
	for k := range m {
		if k != "reverb" && k != "delay" && k != "sidechain" {
			return fmt.Errorf("fx の知らない鍵 %q（reverb delay sidechain）", k)
		}
	}
	if r := objectOf(m, "reverb"); r != nil {
		s.fx.reverb = &reverbParam{room: floatOr(r, "room", 0.5), damp: floatOr(r, "damp", 0.5), wet: floatOr(r, "wet", 1), predelay: floatOr(r, "predelay_ms", 0)}
	}
	if d := objectOf(m, "delay"); d != nil {
		pp, ok := d["pingpong"].(bool)
		if !ok {
			pp = true
		}
		s.fx.delay = &delayParam{feedback: math.Min(0.95, floatOr(d, "feedback", 0.35)), wet: floatOr(d, "wet", 1), lp: floatOr(d, "lowpass", 6000), pingpong: pp}
		s.fx.delaySteps = floatOr(d, "steps", 3)
	}
	if sc := objectOf(m, "sidechain"); sc != nil {
		s.fx.duckKeys = stringsOf(sc["key"])
		if len(s.fx.duckKeys) == 0 {
			return fmt.Errorf("fx.sidechain.key（沈める合図の楽器の名前の並び）が無い")
		}
		depth := floatOr(sc, "depth_db", 4)
		g, err := crmath.Pow(10, -depth/20)
		if err != nil {
			return err
		}
		s.fx.duckDepth = 1 - g
		s.fx.duckMs = math.Max(1, floatOr(sc, "release_ms", 160))
	}
	return nil
}

func loadSong(c *rctx, path string) (*song, error) {
	root, err := readJSONObject(c, path)
	if err != nil {
		return nil, err
	}
	s := &song{
		bpm:    math.Max(1, floatOr(root, "bpm", 120)),
		ticks:  max(1, intOr(root, "ticks", 6)),
		loop:   intOr(root, "loop", -1),
		rate:   max(8000, intOr(root, "rate", 44100)),
		gain:   math.Max(0, floatOr(root, "gain", 1)),
		phrase: map[string][]step{},
		chains: map[string][]chainEntry{},
		inline: root,
	}
	if s.chans, err = parseChannels(root); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	if g, ok := root["groove"].([]any); ok {
		for _, v := range g {
			f, ok := v.(float64)
			if !ok || f < 1 || f != math.Trunc(f) {
				return nil, fmt.Errorf("%s: groove は 1 以上の整数の並び", path)
			}
			s.groove = append(s.groove, int(f))
		}
		if len(s.groove) == 0 || phraseSteps%len(s.groove) != 0 {
			return nil, fmt.Errorf("%s: groove の長さは 16 を割り切る数（1・2・4・8・16）", path)
		}
	}
	if err := parseSongFx(objectOf(root, "fx"), s); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	for name, v := range objectOf(root, "phrases") {
		texts := stringsOf(v)
		steps := make([]step, phraseSteps)
		for i := range steps {
			steps[i] = step{volume: -1}
			if i < len(texts) {
				steps[i] = parseStep(texts[i])
			}
		}
		s.phrase[name] = steps
	}
	for name, v := range objectOf(root, "chains") {
		var es []chainEntry
		for _, t := range stringsOf(v) {
			if e, ok := parseChainEntry(t); ok {
				es = append(es, e)
			}
		}
		s.chains[name] = es
	}
	_, named := root["channels"]
	rows, _ := root["rows"].([]any)
	for _, r := range rows {
		obj, ok := r.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%s: rows の行はオブジェクトで書く", path)
		}
		row := map[int]string{}
		for k, v := range obj {
			idx := -1
			for i, cd := range s.chans {
				if cd.name == k {
					idx = i
				}
			}
			if idx < 0 {
				if named {
					return nil, fmt.Errorf("%s: rows の %q は channels に無い", path, k)
				}
				continue
			}
			if name, ok := v.(string); ok && strings.TrimSpace(name) != "" {
				row[idx] = strings.TrimSpace(name)
			}
		}
		s.rows = append(s.rows, row)
	}
	return s, nil
}

func parseWave(text string) waveSel {
	switch strings.TrimSpace(text) {
	case "12", "12.5":
		return waveSel{kind: waveDuty, duty: 0.125}
	case "25":
		return waveSel{kind: waveDuty, duty: 0.25}
	case "50":
		return waveSel{kind: waveDuty, duty: 0.5}
	case "75":
		return waveSel{kind: waveDuty, duty: 0.75}
	case "long":
		return waveSel{kind: waveLong}
	case "short":
		return waveSel{kind: waveShort}
	}
	return waveSel{kind: waveTable, name: strings.TrimSpace(text)}
}

// parseMacro は表 1 本: 並び（数か文字列）か、語の並びの文字列（"15 13 12 | 11 10 / 6 3 0"。| の後がループ・/ の後が離した後）。
func parseMacro(v any, waves bool) (*macroSeq, error) {
	m := &macroSeq{loop: -1, release: -1}
	var words []string
	switch x := v.(type) {
	case string:
		words = wordsOf(strings.NewReplacer("|", " | ", "/", " / ").Replace(x))
	case []any:
		for _, e := range x {
			switch y := e.(type) {
			case float64:
				words = append(words, strconv.FormatFloat(y, 'f', -1, 64))
			case string:
				words = append(words, y)
			default:
				return nil, fmt.Errorf("表の値は数か文字列")
			}
		}
	default:
		return nil, fmt.Errorf("表は並びか文字列で書く")
	}
	for _, w := range words {
		switch w {
		case "|":
			m.loop = m.size()
			continue
		case "/":
			m.release = m.size()
			continue
		}
		if waves {
			m.waves = append(m.waves, parseWave(w))
			continue
		}
		n, ok := atoi(w)
		if !ok {
			return nil, fmt.Errorf("表の値 %q は整数で書く", w)
		}
		m.vals = append(m.vals, n)
	}
	if m.size() == 0 {
		return nil, fmt.Errorf("表が空")
	}
	if m.loop >= m.size() {
		m.loop = -1
	}
	if m.release >= m.size() {
		m.release = -1
	}
	return m, nil
}

func parseInstrument(name string, obj map[string]any) (instrument, error) {
	ins := instrument{speed: max(1, intOr(obj, "speed", 1))}
	_, hasRows := obj["rows"]
	if !hasRows && (obj["vol"] != nil || obj["arp"] != nil || obj["pitch"] != nil || obj["duty"] != nil) {
		mac := &macros{}
		for _, k := range []string{"vol", "arp", "pitch", "duty"} {
			if obj[k] == nil {
				continue
			}
			seq, err := parseMacro(obj[k], k == "duty")
			if err != nil {
				return ins, fmt.Errorf("%s の %s: %v", name, k, err)
			}
			switch k {
			case "vol":
				for i, v := range seq.vals {
					seq.vals[i] = max(0, min(15, v))
				}
				mac.vol = seq
			case "arp":
				mac.arp = seq
			case "pitch":
				mac.pitch = seq
			case "duty":
				mac.duty = seq
			}
		}
		mac.arpFixed, _ = obj["arp_fixed"].(bool)
		if v, ok := obj["vib"].(string); ok {
			var fs []float64
			for _, w := range wordsOf(v) {
				if f, ok := atof(w); ok {
					fs = append(fs, f)
				}
			}
			if len(fs) < 2 {
				return ins, fmt.Errorf("%s の vib は \"hz cents [遅れの tick]\"", name)
			}
			mac.vibHz, mac.vibCents = fs[0], fs[1]
			if len(fs) > 2 {
				mac.vibDelay = int(fs[2])
			}
		}
		ins.mac = mac
		return ins, nil
	}
	rows, _ := obj["rows"].([]any)
	for _, r := range rows {
		ro, ok := r.(map[string]any)
		if !ok {
			return ins, fmt.Errorf("%s の rows の行はオブジェクトで書く", name)
		}
		row := tableRow{}
		if _, ok := ro["vol"].(float64); ok {
			row.volume = ip(max(0, min(15, intOr(ro, "vol", 0))))
		}
		if _, ok := ro["pitch"].(float64); ok {
			row.pitch = ip(intOr(ro, "pitch", 0))
		}
		if _, ok := ro["cents"].(float64); ok {
			row.cents = ip(intOr(ro, "cents", 0))
		}
		if w, ok := ro["wave"].(string); ok {
			ws := parseWave(w)
			row.wave = &ws
		}
		if c, ok := ro["cmd"].(string); ok {
			row.cmd = parseCmd(c)
		}
		ins.rows = append(ins.rows, row)
	}
	return ins, nil
}

// addInstruments は {"instruments": {…}, "waves": {…}} を in に足す（同じ名前は上書き）。
func addInstruments(in *instruments, root map[string]any, where string) error {
	for name, v := range objectOf(root, "instruments") {
		obj, ok := v.(map[string]any)
		if !ok {
			continue
		}
		ins, err := parseInstrument(name, obj)
		if err != nil {
			return fmt.Errorf("%s: %v", where, err)
		}
		in.byName[name] = ins
	}
	for name, v := range objectOf(root, "waves") {
		arr, ok := v.([]any)
		if !ok || len(arr) != 32 {
			continue
		}
		levels := make([]int, 32)
		good := true
		for i, e := range arr {
			f, ok := e.(float64)
			good = good && ok && f == math.Trunc(f)
			levels[i] = max(0, min(15, int(f)))
		}
		if good {
			in.waves[name] = levels
		}
	}
	return nil
}

func loadInstruments(c *rctx, path string, chip map[string]any) (instruments, error) {
	in := instruments{byName: map[string]instrument{}, waves: map[string][]int{}}
	if path != "" {
		root, err := readJSONObject(c, path)
		if err != nil {
			return in, err
		}
		if err := addInstruments(&in, root, path); err != nil {
			return in, err
		}
		if len(in.byName) == 0 && objectOf(root, "instruments") == nil {
			in.byName["plain"] = plainInstrument()
		}
	}
	if err := addInstruments(&in, chip, "譜面の instruments"); err != nil {
		return in, err
	}
	return in, nil
}

func genSong(c *rctx, a opreg.Args) (sourceOut, error) {
	sp, err := loadSong(c, filepath.Clean(a.Str("chip")))
	if err != nil {
		return sourceOut{}, err
	}
	instPath := ""
	if a.Has("instruments") {
		instPath = filepath.Clean(a.Str("instruments"))
	}
	in, err := loadInstruments(c, instPath, sp.inline)
	if err != nil {
		return sourceOut{}, err
	}
	sp.rate = int(c.rate) // 書き出しのレートにそろえる（WAV の頭に書く値と食い違うと速さが変わる）
	r := renderSong(sp, in)
	out := sourceOut{ch: r.chans, loopStart: r.loopStart, clamped: r.clamped, tempo: &tempo{BPM: sp.bpm, BeatsPerBar: 4},
		breaks: r.breaks, pans: r.pans}
	for _, ch := range r.used {
		out.parts = append(out.parts, sp.chans[ch].part)
	}
	return out, nil
}
