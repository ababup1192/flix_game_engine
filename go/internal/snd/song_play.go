package snd

// song を鳴らす（ゲームの ChipSynth と同じ 2 段）。
//   1. 制御の段（controlFrames）: 1 tick ごとに音程・音量・波形・ビブラートを決める。段の長さは groove（無ければ ticks）。
//   2. 発振の段（renderChannel）: tick の値のまま 1 サンプルずつ波を作る。
// 混ぜる段（renderSong）: チャンネルを左右に振って足し、送り（reverb・delay）とサイドチェインを掛ける。
// ループのある曲は「頭 + 本編 + 本編」を鳴らして 2 周目の本編を切り出す（1 周目の余韻と響きが継ぎ目に入る）。
// sin・pow・exp は正しく丸めた値（crmath）。同じ引数は覚えて引く（音程は tick の間ずっと同じなので）。

import (
	"math"
	"sync"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
)

// ── 並べる ──

func (s *song) chainLength(name string) int { return len(s.chains[name]) * phraseSteps }

func (s *song) rowLength(row map[int]string) int {
	n := 0
	for _, name := range row {
		n = max(n, s.chainLength(name))
	}
	if n <= 0 {
		return phraseSteps
	}
	return n
}

func (s *song) rowSteps(c int, row map[int]string) []step {
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

// stepTicks は段 i の tick の数（groove があれば段ごと）。
func (s *song) stepTicks(i int) int {
	if len(s.groove) > 0 {
		return s.groove[i%len(s.groove)]
	}
	return s.ticks
}

// ticksPerStep は 1 段の平均の tick（groove の平均。拍の速さはこれで決まる）。
func (s *song) ticksPerStep() float64 {
	if len(s.groove) == 0 {
		return float64(s.ticks)
	}
	sum := 0
	for _, g := range s.groove {
		sum += g
	}
	return float64(sum) / float64(len(s.groove))
}

// tickOfStep は段 n の頭の tick。
func (s *song) tickOfStep(n int) int {
	if len(s.groove) == 0 {
		return n * s.ticks
	}
	per := 0
	for _, g := range s.groove {
		per += g
	}
	t := (n / len(s.groove)) * per
	for i := 0; i < n%len(s.groove); i++ {
		t += s.groove[i]
	}
	return t
}

// sampleAt は tick の頭のサンプルの位置（端数は切り捨て。どの継ぎ目も同じ式なのでループの長さがずれない）。
func (s *song) sampleAt(tick int) int {
	perTick := float64(float64(s.rate)*60) / float64(float64(s.bpm*4)*s.ticksPerStep())
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
	inst            string // 鳴らし始めた楽器（サイドチェインの合図）
}

type voiceState struct {
	sounding                         bool
	note                             int
	inst                             instrument
	instName                         string
	stepVol, volSlide                float64
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
	mpos                             [4]int // 表（vol・arp・pitch・duty）の位置
	released                         bool
	age                              int // 鳴らしてからの tick
}

func defaultWave(p part) waveSel {
	switch p {
	case partNoise:
		return waveSel{kind: waveLong}
	case partWave:
		return waveSel{kind: waveTable, name: ""}
	}
	return waveSel{kind: waveDuty, duty: 0.5}
}

func silentVoice(p part) voiceState {
	return voiceState{note: 60, inst: plainInstrument(), stepVol: 15, loops: map[int]int{}, tableVolume: 15,
		wave: defaultWave(p), lastPitch: 60}
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
	case cmdVolSlide:
		v.volSlide = float64(c.n) / 8
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

// enterMacros は表の今の位置の値を声に入れる（表の形の楽器）。
func enterMacros(v voiceState) voiceState {
	m := v.inst.mac
	if m.vol != nil {
		v.tableVolume = m.vol.vals[v.mpos[0]]
	}
	v.tablePitch = 0
	if m.arp != nil {
		v.tablePitch = m.arp.vals[v.mpos[1]]
		if m.arpFixed {
			v.tablePitch -= v.note
		}
	}
	if m.pitch != nil {
		v.tableCt = m.pitch.vals[v.mpos[2]]
	}
	if m.duty != nil {
		v.wave = m.duty.waves[v.mpos[3]]
	}
	return v
}

func (m *macros) seqs() [4]*macroSeq { return [4]*macroSeq{m.vol, m.arp, m.pitch, m.duty} }

func advanceTable(v voiceState) voiceState {
	v.age++
	if m := v.inst.mac; m != nil {
		if m.vibCents != 0 && v.age == m.vibDelay {
			v.vibHz, v.vibCents = m.vibHz, m.vibCents
		}
		if v.rowAge+1 < v.inst.speed {
			v.rowAge++
			return v
		}
		v.rowAge = 0
		for k, seq := range m.seqs() {
			if seq != nil {
				v.mpos[k] = seq.next(v.mpos[k], v.released)
			}
		}
		return enterMacros(v)
	}
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

// release は音を離す: 表に release があれば離した後の表へ進めて鳴らし続け、無ければ止める。
func release(v voiceState) voiceState {
	m := v.inst.mac
	if m == nil || !m.hasRelease() || !v.sounding {
		v.sounding = false
		return v
	}
	if v.released {
		return v
	}
	v.released = true
	for k, seq := range m.seqs() {
		if seq != nil && seq.release >= 0 {
			v.mpos[k] = seq.release
		}
	}
	return enterMacros(v)
}

func applyStep(in instruments, p part, st step, v voiceState) (voiceState, bool) {
	inst, name := v.inst, v.instName
	if st.instrument != "" {
		inst, name = in.of(st.instrument), st.instrument
	}
	switch st.pitch {
	case pitchNote:
		slideOff, slideTicks := 0.0, 0
		for _, c := range st.cmds {
			if c.kind == cmdSlide && v.sounding {
				slideOff, slideTicks = v.lastPitch-float64(st.note), c.n
			}
		}
		vol := 15.0
		if st.volume >= 0 {
			vol = float64(st.volume)
		}
		fresh := voiceState{sounding: true, note: st.note, inst: inst, instName: name, stepVol: vol, loops: map[int]int{},
			tableVolume: 15, wave: defaultWave(p), slideOffset: slideOff, slideTicks: slideTicks, lastPitch: v.lastPitch}
		if inst.mac != nil {
			fresh = enterMacros(fresh)
		} else {
			fresh = enterRow(0, 0, fresh)
		}
		for _, c := range st.cmds {
			if c.kind != cmdSlide {
				fresh = applyCmd(c, fresh)
			}
		}
		return fresh, true
	case pitchOff:
		v.inst, v.instName = inst, name
		return release(v), false
	}
	if st.volume >= 0 {
		v.stepVol = float64(st.volume)
	}
	v.inst, v.instName = inst, name
	for _, c := range st.cmds {
		v = applyCmd(c, v)
	}
	return v, false
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
		vol = float64(float64(v.tableVolume)*v.stepVol) / 225
	}
	return frame{pitch: v.basePitch() + float64(arp) + slide, glide: sliding && v.slideAge > 0, volume: vol,
		wave: v.wave, vibHz: v.vibHz, vibCents: v.vibCents, retrigger: retrigger, inst: v.instName}
}

// controlFrames は段の並びを tick の並びにする。段 i は s.stepTicks(first+i) tick（first は並びの頭の段の番号）。
func controlFrames(s *song, in instruments, p part, steps []step) []frame {
	var out []frame
	v := silentVoice(p)
	var noteStep step
	cutLeft := -1 // CUT の残りの tick（段をまたいで数える）
	for i, st := range steps {
		n := s.stepTicks(i)
		dly, _ := st.arg(cmdDelay)
		dly = min(dly, n-1)
		cut, hasCut := st.arg(cmdCut)
		rtg, _ := st.arg(cmdRetrig)
		for t := 0; t < n; t++ {
			stepped, onset := v, false
			switch {
			case t == dly:
				stepped, onset = applyStep(in, p, st, v)
				if onset {
					noteStep, cutLeft = st, -1
					if hasCut {
						cutLeft = cut
					}
				}
			case rtg > 0 && t > dly && (t-dly)%rtg == 0 && v.sounding && noteStep.pitch == pitchNote:
				again := noteStep
				again.instrument, again.cmds = v.instName, nil
				again.volume = int(v.stepVol)
				stepped, onset = applyStep(in, p, again, v)
			}
			if cutLeft == 0 {
				stepped = release(stepped)
			}
			if cutLeft >= 0 {
				cutLeft--
			}
			adv := stepped
			if !onset && stepped.sounding {
				adv = advanceTable(stepped)
			}
			f := frameOf(adv, onset)
			out = append(out, f)
			adv.arpAge++
			adv.slideAge++
			adv.lastPitch = f.pitch
			if adv.volSlide != 0 {
				adv.stepVol = math.Max(0, math.Min(15, adv.stepVol+adv.volSlide))
			}
			v = adv
		}
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

// sineTable はサブベースのサイン（4096 点。crmath で作り、線形に補う）。
var sineTable = func() []float64 {
	t := make([]float64, 4097)
	for i := range t {
		t[i] = crmath.Sin(tau * float64(i) / 4096)
	}
	return t
}()

func sineAt(phase float64) float64 {
	x := phase * 4096
	k := int(x)
	f := x - float64(k)
	return sineTable[k] + float64((sineTable[k+1]-sineTable[k])*f)
}

func renderChannel(s *song, cd chanDef, gain float64, waves map[string][]int, frames []frame, n int) []float64 {
	out := make([]float64, n)
	rate := float64(s.rate)
	phase, subPhase, amp, lfsr := 0.0, 0.0, 0.0, 32767
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
	detune := cd.cents / 100
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
			freq := 440 * pow2.at((bent+vib+detune-69)/12)
			var value float64
			switch cd.part {
			case partNoise:
				value = lfsrStep(float64(freq*8)/rate, short, &phase, &lfsr)
			case partTriangle:
				p := advance(freq / rate)
				idx := min(31, int(p*32))
				level := idx - 16
				if idx < 16 {
					level = 15 - idx
				}
				value = float64(level)/7.5 - 1
			case partWave:
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
			if cd.sub > 0 { // 1 オクターブ下のサイン（機種の外の厚み）
				value = value + float64(cd.sub*sineAt(subPhase))
				next := subPhase + float64(freq/rate)*0.5
				subPhase = next - math.Floor(next)
			}
			out[i] = float64(value*amp) * gain
		}
	}
	return out
}

// songOut は鳴らした曲（左右・輪の頭・±1 に切った数・使ったチャンネル・機種の外の手・振った左右）。
type songOut struct {
	chans     [][]float64
	loopStart int
	clamped   int
	used      []int
	breaks    []string
	pans      []float64
}

// duckGains はサイドチェインの倍率（合図の楽器が鳴った所で 1 - depth へ沈み、release_ms で戻る）。
func duckGains(s *song, frames [][]frame, total int) []float64 {
	hit := make([]bool, total)
	for _, fs := range frames {
		for t, f := range fs {
			if f.retrigger && contains(s.fx.duckKeys, f.inst) {
				if at := s.sampleAt(t); at < total {
					hit[at] = true
				}
			}
		}
	}
	k, _ := crmath.Exp(-1 / float64(s.fx.duckMs*float64(s.rate)/1000))
	out := make([]float64, total)
	d := 0.0
	for i := range out {
		if hit[i] {
			d = s.fx.duckDepth
		}
		out[i] = 1 - d
		d = d * k
	}
	return out
}

// renderSong は曲を鳴らし、頭 + 輪の 1 本を返す（ChipSynth.render と同じ並べ方。混ぜる段は左右）。
func renderSong(s *song, in instruments) songOut {
	res := songOut{loopStart: -1}
	loop := s.loopRow()
	rows := s.rows
	sum := func(rs []map[int]string) int {
		n := 0
		for _, r := range rs {
			n += s.rowLength(r)
		}
		return n
	}
	introSteps, bodySteps := sum(rows), 0
	if loop >= 0 {
		introSteps, bodySteps = sum(rows[:loop]), sum(rows[loop:])
		rows = append(append([]map[int]string{}, rows...), rows[loop:]...)
	}
	tail := 0
	if bodySteps == 0 {
		stepSeconds := 60 / float64(s.bpm*4)
		tail = int(math.Ceil(2.0 / stepSeconds))
	}
	totalSteps := introSteps + 2*bodySteps + tail
	total := s.sampleAt(s.tickOfStep(totalSteps))
	chans := make([][]float64, len(s.chans))
	frames := make([][]frame, len(s.chans))
	var wg sync.WaitGroup
	for c := range s.chans {
		var steps []step
		sounds := false
		for _, r := range rows {
			if _, ok := r[c]; ok {
				sounds = true
			}
			steps = append(steps, s.rowSteps(c, r)...)
		}
		for k := 0; k < tail; k++ {
			steps = append(steps, step{volume: -1})
		}
		if sounds {
			res.used = append(res.used, c)
		}
		gain := float64(s.chans[c].vol) * s.gain
		wg.Add(1)
		go func() { // チャンネルは互いに独立。足すのは下でチャンネルの順に 1 本ずつ（足す順が同じなので結果も同じ）
			defer wg.Done()
			frames[c] = controlFrames(s, in, s.chans[c].part, steps)
			chans[c] = renderChannel(s, s.chans[c], gain, in.waves, frames[c], total)
		}()
	}
	wg.Wait()
	var duck []float64
	usedFx := map[string]bool{}
	for _, c := range res.used {
		cd := s.chans[c]
		usedFx["reverb"] = usedFx["reverb"] || (cd.sendReverb > 0 && s.fx.reverb != nil)
		usedFx["delay"] = usedFx["delay"] || (cd.sendDelay > 0 && s.fx.delay != nil)
		usedFx["sidechain"] = usedFx["sidechain"] || (cd.duck && len(s.fx.duckKeys) > 0)
		usedFx["sub"] = usedFx["sub"] || cd.sub > 0
		if cd.pan != 0 {
			res.pans = append(res.pans, cd.pan)
		}
	}
	for _, b := range []string{"reverb", "delay", "sidechain", "sub"} {
		if usedFx[b] {
			res.breaks = append(res.breaks, b)
		}
	}
	if usedFx["sidechain"] {
		duck = duckGains(s, frames, total)
	}
	left, right := make([]float64, total), make([]float64, total)
	var rev, dly []float64
	if usedFx["reverb"] {
		rev = make([]float64, total)
	}
	if usedFx["delay"] {
		dly = make([]float64, total)
	}
	for _, c := range res.used {
		cd := s.chans[c]
		gl, gr := balance(cd.pan)
		for i, v := range chans[c] {
			if cd.duck && duck != nil {
				v = v * duck[i]
			}
			left[i] = left[i] + float64(v*gl)
			right[i] = right[i] + float64(v*gr)
			if rev != nil {
				rev[i] = rev[i] + float64(v*cd.sendReverb)
			}
			if dly != nil {
				dly[i] = dly[i] + float64(v*cd.sendDelay)
			}
		}
	}
	addBack := func(l, r []float64, wet float64) {
		for i := range left {
			left[i] = left[i] + float64(l[i]*wet)
			right[i] = right[i] + float64(r[i]*wet)
		}
	}
	if rev != nil {
		l, r := reverbRun(float64(s.rate), rev, *s.fx.reverb)
		addBack(l, r, s.fx.reverb.wet)
	}
	if dly != nil {
		p := *s.fx.delay
		p.frames = int(float64(s.fx.delaySteps*float64(s.sampleAt(s.tickOfStep(phraseSteps)))) / phraseSteps)
		l, r := delayRun(float64(s.rate), dly, p)
		addBack(l, r, p.wet)
	}
	// 仕上げ: 直流を落とし（20Hz ほどの低域切り）、±1 に収める
	for _, out := range [][]float64{left, right} {
		prevIn, prevOut := 0.0, 0.0
		for i, x := range out {
			y := x - prevIn + float64(0.997*prevOut)
			if y > 1 || y < -1 {
				res.clamped++
			}
			out[i] = math.Max(-1, math.Min(1, y))
			prevIn, prevOut = x, y
		}
	}
	if bodySteps > 0 {
		introEnd := s.sampleAt(s.tickOfStep(introSteps))
		ls := s.sampleAt(s.tickOfStep(introSteps + bodySteps))
		cut := func(x []float64) []float64 { return append(x[:introEnd:introEnd], x[ls:]...) }
		res.chans, res.loopStart = [][]float64{cut(left), cut(right)}, introEnd
		return res
	}
	last := 0
	for i := total - 1; i >= 0; i-- {
		if math.Abs(left[i]) > 0.0005 || math.Abs(right[i]) > 0.0005 {
			last = i
			break
		}
	}
	end := min(total, last+1+64)
	res.chans = [][]float64{left[:end], right[:end]}
	return res
}
