package snd

// song の op: トラッカーの譜面（*.chip.json。phrase 16 段 → chain → rows）を、共有の楽器（*.instrument.json。
// 楽器 = table）で鳴らす。読み方と鳴らし方はゲームの ChipDoc・InstrumentDoc・ChipSynth と同じ（形を変えない）。
//   1. 制御の段（controlFrames）: 1 tick ごとに音程・音量・波形・ビブラートを決める。
//   2. 発振の段（renderChannel）: tick の値のまま 1 サンプルずつ波を作り、チャンネルの順に足す。
// ループのある曲は「頭 + 本編 + 本編」を鳴らして 2 周目の本編を切り出す（1 周目の余韻が継ぎ目に入る）。
// sin・pow は正しく丸めた値（crmath）。同じ引数は覚えて引く（音程は tick の間ずっと同じなので）。

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
)

func init() {
	register(&opDef{
		Name:    "song",
		Summary: "譜面（*.chip.json）を楽器（*.instrument.json）で鳴らす。ループ点があれば頭 + 輪の 1 本と smpl のループの頭を作る",
		Machine: "譜面のチャンネル: pulse1・pulse2 = パルス・triangle = 三角・noise = 雑音・wave = 波形メモリ（使ったチャンネルを機種の縛りで数える）",
		Example: `{"song": {"chip": "testdata/snd/tiny.chip.json", "instruments": "testdata/snd/tiny.instrument.json"}}`,
		Params: []opreg.Param{
			{Name: "chip", Type: opreg.String, Required: true, Summary: "譜面のパス（作業場の根から）"},
			{Name: "instruments", Type: opreg.String, Required: true, Summary: "楽器のパス（作業場の根から）"},
		},
		Gen: genSong,
	})
}

// ── 譜面の部品（ChipDoc） ──

type pitchKind int

const (
	pitchHold pitchKind = iota // 何もしない
	pitchOff                   // 音を止める
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
)

type cmd struct {
	kind      cmdKind
	arp       []int
	hz, cents float64
	n, times  int // Slide の tick・Jump / Loop の行・Loop の回数
}

type step struct {
	pitch      pitchKind
	note       int
	instrument string // "" = 前の段の楽器
	volume     int    // -1 = 書いていない
	cmd        cmd
}

type chainEntry struct {
	phrase    string
	transpose int
}

type channel int

const (
	chPulse1 channel = iota
	chPulse2
	chTriangle
	chNoise
	chWave
)

var channelKeys = []string{"pulse1", "pulse2", "triangle", "noise", "wave"}
var channelGain = []float64{0.2, 0.2, 0.3, 0.16, 0.22}
var channelPart = []part{partPulse, partPulse, partTriangle, partNoise, partWave}

type song struct {
	bpm    float64
	ticks  int
	loop   int
	rate   int
	gain   float64
	mix    map[channel]float64
	phrase map[string][]step
	chains map[string][]chainEntry
	rows   []map[channel]string
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

type instrument struct {
	speed int
	rows  []tableRow
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

// ── 読む（形と既定は ChipDoc.fromRoot・InstrumentDoc.fromRoot と同じ） ──

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

var cmdWords = map[string]bool{"ARP": true, "VIB": true, "SLD": true, "JMP": true, "LOOP": true, "END": true}

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
	st.cmd = parseCmd(strings.Join(rest[k:], " "))
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
	case "SLD":
		if is := ints(args); len(is) > 0 {
			return cmd{kind: cmdSlide, n: max(1, is[0])}
		}
	case "JMP":
		if is := ints(args); len(is) > 0 {
			return cmd{kind: cmdJump, n: max(0, is[0])}
		}
	case "LOOP":
		switch is := ints(args); {
		case len(is) >= 2:
			return cmd{kind: cmdLoop, n: max(0, is[0]), times: max(0, is[1])}
		case len(is) == 1:
			return cmd{kind: cmdLoop, n: max(0, is[0])}
		}
	case "END":
		return cmd{kind: cmdEnd}
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

func readJSONObject(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
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

func loadSong(path string) (*song, error) {
	root, err := readJSONObject(path)
	if err != nil {
		return nil, err
	}
	s := &song{
		bpm:    math.Max(1, floatOr(root, "bpm", 120)),
		ticks:  max(1, intOr(root, "ticks", 6)),
		loop:   intOr(root, "loop", -1),
		rate:   max(8000, intOr(root, "rate", 44100)),
		gain:   math.Max(0, floatOr(root, "gain", 1)),
		mix:    map[channel]float64{},
		phrase: map[string][]step{},
		chains: map[string][]chainEntry{},
	}
	for c, k := range channelKeys {
		if f, ok := objectOf(root, "mix")[k].(float64); ok {
			s.mix[channel(c)] = math.Max(0, f)
		}
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
	rows, _ := root["rows"].([]any)
	for _, r := range rows {
		obj, ok := r.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%s: rows の行はオブジェクトで書く", path)
		}
		row := map[channel]string{}
		for c, k := range channelKeys {
			if name, ok := obj[k].(string); ok && strings.TrimSpace(name) != "" {
				row[channel(c)] = strings.TrimSpace(name)
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

func loadInstruments(path string) (instruments, error) {
	root, err := readJSONObject(path)
	if err != nil {
		return instruments{}, err
	}
	in := instruments{byName: map[string]instrument{}, waves: map[string][]int{}}
	for name, v := range objectOf(root, "instruments") {
		obj, ok := v.(map[string]any)
		if !ok {
			continue
		}
		ins := instrument{speed: max(1, intOr(obj, "speed", 1))}
		rows, _ := obj["rows"].([]any)
		for _, r := range rows {
			ro, ok := r.(map[string]any)
			if !ok {
				return in, fmt.Errorf("%s: %s の rows の行はオブジェクトで書く", path, name)
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
	if len(in.byName) == 0 && objectOf(root, "instruments") == nil {
		in.byName["plain"] = plainInstrument()
	}
	return in, nil
}

// ── 並べる ──

func (s *song) chainLength(name string) int { return len(s.chains[name]) * phraseSteps }

func (s *song) rowLength(row map[channel]string) int {
	n := 0
	for _, name := range row {
		n = max(n, s.chainLength(name))
	}
	if n <= 0 {
		return phraseSteps
	}
	return n
}

func (s *song) rowSteps(c channel, row map[channel]string) []step {
	var out []step
	if name, ok := row[c]; ok {
		for _, e := range s.chains[name] {
			ph, ok := s.phrase[e.phrase]
			for i := 0; i < phraseSteps; i++ {
				st := step{volume: -1}
				if ok {
					st = ph[i]
				}
				if st.pitch == pitchNote {
					st.note += e.transpose
				}
				out = append(out, st)
			}
		}
	}
	for len(out) < s.rowLength(row) {
		out = append(out, step{volume: -1})
	}
	return out
}

// loopRow はループの頭の行（範囲外は -1）。
func (s *song) loopRow() int {
	if s.loop >= 0 && s.loop < len(s.rows) {
		return s.loop
	}
	return -1
}

// sampleAt は tick の頭のサンプルの位置（端数は切り捨て。どの継ぎ目も同じ式なのでループの長さがずれない）。
func (s *song) sampleAt(tick int) int {
	perTick := float64(float64(s.rate)*60) / float64(float64(s.bpm*4)*float64(s.ticks))
	return int(math.Floor(float64(float64(tick)*perTick) + 0.000001))
}

// ── 制御の段 ──

type frame struct {
	pitch           float64
	glide           bool
	volume          float64
	wave            waveSel
	vibHz, vibCents float64
	retrigger       bool
}

type voiceState struct {
	sounding                         bool
	note                             int
	inst                             instrument
	stepVolume                       int
	row, rowAge                      int
	loops                            map[int]int
	tableVolume, tablePitch, tableCt int
	wave                             waveSel
	arp                              []int
	arpAge                           int
	vibHz, vibCents                  float64
	slideOffset                      float64
	slideTicks, slideAge             int
	lastPitch                        float64
}

func defaultWave(c channel) waveSel {
	switch c {
	case chNoise:
		return waveSel{kind: waveLong}
	case chWave:
		return waveSel{kind: waveTable, name: ""}
	}
	return waveSel{kind: waveDuty, duty: 0.5}
}

func silentVoice(c channel) voiceState {
	return voiceState{note: 60, inst: plainInstrument(), stepVolume: 15, loops: map[int]int{}, tableVolume: 15,
		wave: defaultWave(c), lastPitch: 60}
}

func (v voiceState) basePitch() float64 {
	return float64(v.note+v.tablePitch) + float64(v.tableCt)/100
}

func (v voiceState) withLoops(row, n int) voiceState {
	m := make(map[int]int, len(v.loops)+1)
	for k, x := range v.loops {
		m[k] = x
	}
	m[row] = n
	v.loops = m
	return v
}

func applyCmd(c cmd, v voiceState) voiceState {
	switch c.kind {
	case cmdArp:
		v.arp, v.arpAge = c.arp, 0
	case cmdVib:
		v.vibHz, v.vibCents = c.hz, c.cents
	case cmdSlide:
		v.slideOffset, v.slideTicks, v.slideAge = v.lastPitch-v.basePitch(), c.n, 0
	case cmdEnd:
		v.sounding = false
	}
	return v
}

func enterRow(row, depth int, v voiceState) voiceState {
	if row < 0 || row >= len(v.inst.rows) {
		return v
	}
	tr := v.inst.rows[row]
	v.row = row
	if tr.volume != nil {
		v.tableVolume = *tr.volume
	}
	if tr.pitch != nil {
		v.tablePitch = *tr.pitch
	}
	if tr.cents != nil {
		v.tableCt = *tr.cents
	}
	if tr.wave != nil {
		v.wave = *tr.wave
	}
	switch {
	case tr.cmd.kind == cmdJump && depth < 8:
		return enterRow(tr.cmd.n, depth+1, v)
	case tr.cmd.kind == cmdLoop && depth < 8:
		count := v.loops[row]
		if tr.cmd.times == 0 || count < tr.cmd.times {
			return enterRow(tr.cmd.n, depth+1, v.withLoops(row, count+1))
		}
		return v.withLoops(row, 0)
	}
	return applyCmd(tr.cmd, v)
}

func advanceTable(v voiceState) voiceState {
	switch {
	case v.rowAge+1 < v.inst.speed:
		v.rowAge++
		return v
	case v.row+1 >= len(v.inst.rows):
		v.rowAge = 0
		return v
	}
	v.rowAge = 0
	return enterRow(v.row+1, 0, v)
}

func applyStep(in instruments, c channel, st step, v voiceState) (voiceState, bool) {
	inst := v.inst
	if st.instrument != "" {
		inst = in.of(st.instrument)
	}
	switch st.pitch {
	case pitchNote:
		slideOff, slideTicks := 0.0, 0
		if st.cmd.kind == cmdSlide && v.sounding {
			slideOff, slideTicks = v.lastPitch-float64(st.note), st.cmd.n
		}
		vol := 15
		if st.volume >= 0 {
			vol = st.volume
		}
		fresh := voiceState{sounding: true, note: st.note, inst: inst, stepVolume: vol, loops: map[int]int{},
			tableVolume: 15, wave: defaultWave(c), slideOffset: slideOff, slideTicks: slideTicks, lastPitch: v.lastPitch}
		fresh = enterRow(0, 0, fresh)
		if st.cmd.kind != cmdSlide {
			fresh = applyCmd(st.cmd, fresh)
		}
		return fresh, true
	case pitchOff:
		v.sounding, v.inst = false, inst
		return v, false
	}
	if st.volume >= 0 {
		v.stepVolume = st.volume
	}
	v.inst = inst
	return applyCmd(st.cmd, v), false
}

func frameOf(v voiceState, retrigger bool) frame {
	arp := 0
	if len(v.arp) > 0 {
		arp = v.arp[((v.arpAge%len(v.arp))+len(v.arp))%len(v.arp)]
	}
	sliding := v.slideTicks > 0 && v.slideAge < v.slideTicks
	slide := 0.0
	if sliding {
		slide = v.slideOffset * (1 - float64(v.slideAge)/float64(v.slideTicks))
	}
	vol := 0.0
	if v.sounding {
		vol = float64(v.tableVolume*v.stepVolume) / 225
	}
	return frame{pitch: v.basePitch() + float64(arp) + slide, glide: sliding && v.slideAge > 0, volume: vol,
		wave: v.wave, vibHz: v.vibHz, vibCents: v.vibCents, retrigger: retrigger}
}

func controlFrames(ticksPerStep int, in instruments, c channel, steps []step) []frame {
	total := len(steps) * ticksPerStep
	out := make([]frame, 0, total)
	v := silentVoice(c)
	for tick := 0; tick < total; tick++ {
		stepped, retrigger := v, false
		if tick%ticksPerStep == 0 {
			stepped, retrigger = applyStep(in, c, steps[tick/ticksPerStep], v)
		}
		adv := stepped
		if !retrigger && stepped.sounding {
			adv = advanceTable(stepped)
		}
		f := frameOf(adv, retrigger)
		out = append(out, f)
		adv.arpAge++
		adv.slideAge++
		adv.lastPitch = f.pitch
		v = adv
	}
	return out
}

// ── 発振の段 ──

var fallbackWave = []int{8, 9, 11, 12, 13, 14, 15, 15, 15, 15, 14, 13, 12, 11, 9, 8,
	7, 6, 4, 3, 2, 1, 0, 0, 0, 0, 1, 2, 3, 4, 6, 7}

// memoFn は 1 本のチャンネルの中で同じ引数の答えを覚える（答えは引数だけで決まる）。
type memoFn struct {
	m  map[uint64]float64
	fn func(float64) (float64, error)
}

func (m *memoFn) at(x float64) float64 {
	k := math.Float64bits(x)
	if r, ok := m.m[k]; ok {
		return r
	}
	r, err := m.fn(x)
	if err != nil {
		r = math.NaN()
	}
	if len(m.m) < 1<<20 {
		m.m[k] = r
	}
	return r
}

func renderChannel(s *song, c channel, gain float64, waves map[string][]int, frames []frame, n int) []float64 {
	out := make([]float64, n)
	rate := float64(s.rate)
	phase, amp, lfsr := 0.0, 0.0, 32767
	e, _ := crmath.Exp(-1 / float64(0.001*rate))
	follow := 1 - e
	sin := &memoFn{m: map[uint64]float64{}, fn: func(x float64) (float64, error) { return crmath.Sin(x), nil }}
	pow2 := &memoFn{m: map[uint64]float64{}, fn: func(x float64) (float64, error) { return crmath.Pow(2, x) }}
	advance := func(step float64) float64 {
		p := phase
		next := p + step
		phase = next - math.Floor(next)
		return p
	}
	for tick, f := range frames {
		start := s.sampleAt(tick)
		stop := min(n, s.sampleAt(tick+1))
		prevPitch := f.pitch
		if tick > 0 {
			prevPitch = frames[tick-1].pitch
		}
		if f.retrigger {
			lfsr = 32767
		}
		table := fallbackWave
		if f.wave.kind == waveTable {
			if t, ok := waves[f.wave.name]; ok {
				table = t
			}
		}
		duty := 0.5
		if f.wave.kind == waveDuty {
			duty = f.wave.duty
		}
		short := f.wave.kind == waveShort
		span := float64(max(1, stop-start))
		for i := start; i < stop; i++ {
			along := float64(i-start) / span
			bent := f.pitch
			if f.glide {
				bent = prevPitch + float64((f.pitch-prevPitch)*along)
			}
			vib := 0.0
			if f.vibCents != 0 {
				vib = float64(f.vibCents/100) * sin.at(float64(float64(tau*f.vibHz)*float64(i))/rate)
			}
			freq := 440 * pow2.at((bent+vib-69)/12)
			var value float64
			switch c {
			case chNoise:
				value = lfsrStep(float64(freq*8)/rate, short, &phase, &lfsr)
			case chTriangle:
				p := advance(freq / rate)
				idx := min(31, int(p*32))
				level := idx - 16
				if idx < 16 {
					level = 15 - idx
				}
				value = float64(level)/7.5 - 1
			case chWave:
				p := advance(freq / rate)
				idx := min(31, int(p*32))
				value = float64(table[idx])/7.5 - 1
			default:
				if advance(freq/rate) < duty {
					value = 1
				} else {
					value = -1
				}
			}
			amp = amp + float64((f.volume-amp)*follow)
			out[i] = float64(value*amp) * gain
		}
	}
	return out
}

// renderSong は曲を鳴らし、頭 + 輪の 1 本・輪の頭・±1 に切った数を返す（ChipSynth.render と同じ）。
func renderSong(s *song, in instruments) (samples []float64, loopStart, clamped int, used []channel) {
	loop := s.loopRow()
	rows := s.rows
	sum := func(rs []map[channel]string) int {
		n := 0
		for _, r := range rs {
			n += s.rowLength(r)
		}
		return n
	}
	introSteps, bodySteps := sum(rows), 0
	if loop >= 0 {
		introSteps, bodySteps = sum(rows[:loop]), sum(rows[loop:])
		rows = append(append([]map[channel]string{}, rows...), rows[loop:]...)
	}
	tail := 0
	if bodySteps == 0 {
		stepSeconds := 60 / float64(s.bpm*4)
		tail = int(math.Ceil(2.0 / stepSeconds))
	}
	totalSteps := introSteps + 2*bodySteps + tail
	total := s.sampleAt(totalSteps * s.ticks)
	chans := make([][]float64, len(channelKeys))
	var wg sync.WaitGroup
	for c := range channelKeys {
		ch := channel(c)
		var steps []step
		sounds := false
		for _, r := range rows {
			if _, ok := r[ch]; ok {
				sounds = true
			}
			steps = append(steps, s.rowSteps(ch, r)...)
		}
		for k := 0; k < tail; k++ {
			steps = append(steps, step{volume: -1})
		}
		if sounds {
			used = append(used, ch)
		}
		mix, ok := s.mix[ch]
		if !ok {
			mix = 1
		}
		gain := float64(channelGain[c]*mix) * s.gain
		wg.Add(1)
		go func() { // チャンネルは互いに独立。足すのは下でチャンネルの順に 1 本ずつ（足す順が同じなので結果も同じ）
			defer wg.Done()
			chans[c] = renderChannel(s, ch, gain, in.waves, controlFrames(s.ticks, in, ch, steps), total)
		}()
	}
	wg.Wait()
	out := make([]float64, total)
	for _, ch := range chans {
		for i, v := range ch {
			out[i] = out[i] + v
		}
	}
	// 仕上げ: 直流を落とし（20Hz ほどの低域切り）、±1 に収める
	prevIn, prevOut := 0.0, 0.0
	for i, x := range out {
		y := x - prevIn + float64(0.997*prevOut)
		if y > 1 || y < -1 {
			clamped++
		}
		out[i] = math.Max(-1, math.Min(1, y))
		prevIn, prevOut = x, y
	}
	if bodySteps > 0 {
		introEnd := s.sampleAt(introSteps * s.ticks)
		ls := s.sampleAt((introSteps + bodySteps) * s.ticks)
		return append(out[:introEnd:introEnd], out[ls:]...), introEnd, clamped, used
	}
	last := 0
	for i := len(out) - 1; i >= 0; i-- {
		if math.Abs(out[i]) > 0.0005 {
			last = i
			break
		}
	}
	return out[:min(len(out), last+1+64)], -1, clamped, used
}

func genSong(c *rctx, a opreg.Args) (sourceOut, error) {
	sp, err := loadSong(filepath.Join(c.workRoot, a.Str("chip")))
	if err != nil {
		return sourceOut{}, err
	}
	in, err := loadInstruments(filepath.Join(c.workRoot, a.Str("instruments")))
	if err != nil {
		return sourceOut{}, err
	}
	sp.rate = int(c.rate) // 書き出しのレートにそろえる（WAV の頭に書く値と食い違うと速さが変わる）
	samples, ls, clamped, used := renderSong(sp, in)
	out := sourceOut{s: samples, loopStart: ls, clamped: clamped, tempo: &tempo{BPM: sp.bpm, BeatsPerBar: 4}}
	for _, ch := range used {
		out.parts = append(out.parts, channelPart[ch])
	}
	return out, nil
}
