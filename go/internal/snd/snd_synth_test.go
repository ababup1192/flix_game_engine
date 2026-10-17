package snd

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
)

// renderChip は譜面 1 つを song で鳴らす（譜面はメモリの中に置く）。
func renderChip(t *testing.T, chip string) *rendered {
	t.Helper()
	s := mustSpec(t, `{"target": "x.wav", "rate": 22050, "voices": [{"ops": [{"song": {"chip": "t.chip.json"}}]}]}`)
	c := &rctx{rate: float64(s.Rate), kindLUFS: -20, truePeak: -1, files: map[string][]byte{"t.chip.json": []byte(chip)}}
	res, err := newRenderer(c, s).render(nil)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// chipOne は 1 本のチャンネルで C-4 を 2 小節のばす譜面（ch はチャンネルの JSON）。
func chipOne(ch string) string {
	return `{"bpm": 120, "channels": [` + ch + `], "instruments": {"held": {"vol": "15"}},
		"phrases": {"p": ["C-4 held", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""]},
		"chains": {"a": ["p", "p", "p", "p", "p", "p", "p", "p"]}, "rows": [{"x": "a"}]}`
}

// hiRatio は [a, b) の高い成分の割合（隣のサンプルの差の RMS ÷ RMS）。
func hiRatio(x []float64, a, b int) float64 {
	var d, e float64
	for i := a + 1; i < b; i++ {
		d += (x[i] - x[i-1]) * (x[i] - x[i-1])
		e += x[i] * x[i]
	}
	return math.Sqrt(d / e)
}

const synthScript = `
snd.write_chip("t.chip.json", {"bpm": 120,
    "channels": [{"name": "pad", "part": "saw", "unison": {"voices": 3, "cents": 15}, "filter": {"hz": 1200, "env": 2}},
                 {"name": "kick", "part": "sine", "pitchenv": {"semis": 24, "ms": 30}}],
    "instruments": {"pl": {"vol": "15 | 15 / 8 4 0"}},
    "body": {"pad": mus.mml("o4 c1", inst = "pl"), "kick": mus.mml("o2 c4 c4 c4 c4", inst = "pl")}})
snd.write_spec("t.sndsrc.json", {"style": STYLE, "kind": "bgm", "target": "t.wav", "voices": [{"ops": [op.song(chip = "t.chip.json")]}]})
`

// 機種の外の音色（saw・sine・unison・filter・pitchenv）は neo なら報告だけ・gb なら gate。
func TestSynthBreaksNeoAndGb(t *testing.T) {
	neo, err := starBuild(t, strings.ReplaceAll(synthScript, "STYLE", `"neo"`))
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range neo[0].Findings {
		if f.Level == checklevel.Gate && f.Check == "style" {
			t.Fatalf("neo は機種の縛りを通るはず: %v", f)
		}
	}
	for _, b := range []string{"saw", "sine", "unison", "filter", "pitchenv"} {
		if !contains(neo[0].Breaks, b) {
			t.Fatalf("破った所に %s: %v", b, neo[0].Breaks)
		}
	}
	gb, err := starBuild(t, strings.ReplaceAll(synthScript, "STYLE", `"gb"`))
	if err != nil {
		t.Fatal(err)
	}
	stopped := false
	for _, f := range gb[0].Findings {
		stopped = stopped || (f.Level == checklevel.Gate && f.Check == "style" && strings.Contains(f.Msg, "unison"))
	}
	if !stopped {
		t.Fatalf("gb で unison を止めるはず: %v", gb[0].Findings)
	}
}

// 重ねは左右を別の音にする（重ねの無い真ん中のチャンネルは左右が同じ）。
func TestUnisonWidens(t *testing.T) {
	plain := renderChip(t, chipOne(`{"name": "x", "part": "saw"}`))
	wide := renderChip(t, chipOne(`{"name": "x", "part": "saw", "unison": {"voices": 4, "cents": 20, "width": 1}}`))
	diff := func(r *rendered) float64 {
		d := 0.0
		for i := range r.out[0] {
			d = math.Max(d, math.Abs(r.out[0][i]-r.out[1][i]))
		}
		return d
	}
	if diff(plain) != 0 || diff(wide) < 0.01 {
		t.Fatalf("左右の差: 重ねなし %.4f・重ね %.4f", diff(plain), diff(wide))
	}
}

// sweep は小節で切る所を動かす（2 小節で 200Hz → 8000Hz なら終わりの方が明るい）。env は鳴らした頭だけ明るい。
func TestFilterSweepAndEnv(t *testing.T) {
	r := renderChip(t, chipOne(`{"name": "x", "part": "saw", "filter": {"hz": 200, "sweep": [[0, 200], [2, 8000]]}}`))
	x, bar := r.out[0], 22050*2
	if lo, hi := hiRatio(x, 2000, 6000), hiRatio(x, 2*bar-6000, 2*bar-2000); hi < 2*lo {
		t.Fatalf("開いた終わりが明るいはず: 頭 %.4f・終わり %.4f", lo, hi)
	}
	e := renderChip(t, chipOne(`{"name": "x", "part": "saw", "filter": {"hz": 300, "env": 4, "env_ms": 40}}`))
	if lo, hi := hiRatio(e.out[0], 22050, 22050+4000), hiRatio(e.out[0], 100, 1000); hi < 1.5*lo {
		t.Fatalf("鳴らした頭が明るいはず: 頭 %.4f・後 %.4f", hi, lo)
	}
}

// pitchenv は頭の音程を上げて落とす（頭の 5ms は着いた後より零点を多く横切る）。
func TestPitchEnvFalls(t *testing.T) {
	r := renderChip(t, chipOne(`{"name": "x", "part": "sine", "pitchenv": {"semis": 36, "ms": 30}}`))
	cross := func(a, b int) int {
		n := 0
		for i := a + 1; i < b; i++ {
			if (r.out[0][i-1] < 0) != (r.out[0][i] < 0) {
				n++
			}
		}
		return n
	}
	w := 110 // 5ms
	if head, late := cross(30, 30+w), cross(11025, 11025+w); head < 3*late+2 {
		t.Fatalf("頭が高いはず: 頭 %d・後 %d", head, late)
	}
}

// 書き損じは止める（雑音に重ね・知らない mode）。
func TestSynthRefusesBadKeys(t *testing.T) {
	for _, ch := range []string{`{"name": "x", "part": "noise", "unison": {"voices": 3}}`, `{"name": "x", "part": "saw", "filter": {"mode": "notch"}}`} {
		if _, err := parseChannels(map[string]any{"channels": []any{mustJSON(t, ch)}}); err == nil {
			t.Fatalf("止めるはず: %s", ch)
		}
	}
}

func mustJSON(t *testing.T, js string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(js), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// bars は小節ごとに測る: 2 小節目だけ大きい曲なら 2 小節目に「一番大きい」、左右が同じなら幅は -99。
func TestBarsMarksLoudest(t *testing.T) {
	rate, bar := 8000, 8000*2 // 120 BPM の 4 拍 = 2 秒
	x := make([]float64, 3*bar)
	for i := range x {
		a := 0.05
		if i >= bar && i < 2*bar {
			a = 0.4
		}
		x[i] = a * math.Sin(2*math.Pi*440*float64(i)/float64(rate))
	}
	bs := measureBars(Clip{Rate: rate, Chans: [][]float64{x, x}, LoopStart: bar}, 120, 4)
	if len(bs) != 3 || bs[1].Loudness < bs[0].Loudness+15 || !bs[1].LoopHead || bs[0].Width != -99 {
		t.Fatalf("2 小節目が大きく、ループの頭・幅 -99: %+v", bs)
	}
}

// 休みの小節は前の音を離す。離し忘れて鳴り続ける音は drone の gate がチャンネルと小節を付けて止める。
func TestRestReleasesAndDroneGate(t *testing.T) {
	const script = `
INST = {"held": {"vol": "15 | 15 / 8 0"}}
LONG = mus.mml("o5 a1", inst = "held")
snd.write_chip("t.chip.json", {"bpm": 120, "instruments": INST,
    "channels": [{"name": "pad", "part": "pulse"}],
    "body": {"pad": LONG + REST}})
snd.write_spec("t.sndsrc.json", {"kind": "bgm", "target": "t.wav", "voices": [{"ops": [op.song(chip = "t.chip.json")]}]})
`
	gateOf := func(rest string) *finding {
		brs, err := starBuild(t, strings.ReplaceAll(script, "REST", rest))
		if err != nil {
			t.Fatal(err)
		}
		for i, f := range brs[0].Findings {
			if f.Check == "drone" && f.Level == checklevel.Gate {
				return &brs[0].Findings[i]
			}
		}
		return nil
	}
	if f := gateOf("mus.rest(5)"); f != nil {
		t.Fatalf("mus.rest は離すので鳴り続けないはず: %v", f)
	}
	f := gateOf(`[""] * 80`) // 空の段だけ（離さない）: 6 小節 = 12 秒 a5 が鳴り続ける
	if f == nil || !strings.Contains(f.Msg, "pad") || !strings.Contains(f.Msg, "880") {
		t.Fatalf("pad の 880 Hz を drone で止めるはず: %v", f)
	}
}

// ループの頭が空の段なら write_chip が OFF を置く（1 周目の最後の音が 2 周目の頭の休みに残らない）。
// "---"（明示ののばし）で継ぎ目をまたいで伸ばしたサインも、輪の終わりを 1 周目の終わりへ寄せるので seam の gate を通る。
func TestLoopHeadReleasesAndSeamKeepsPhase(t *testing.T) {
	const script = `
INST = {"held": {"vol": "15 | 15 / 8 0"}}
snd.write_chip("t.chip.json", {"bpm": 120, "instruments": INST,
    "channels": [{"name": "pad", "part": "pulse"}],
    "body": {"pad": [""] * 80 + mus.mml("o5 a1", inst = "held")}})
snd.write_spec("t.sndsrc.json", {"kind": "bgm", "target": "t.wav", "voices": [{"ops": [op.song(chip = "t.chip.json")]}]})
`
	const tied = `
INST = {"held": {"vol": "15 | 15 / 8 0"}}
snd.write_chip("t.chip.json", {"bpm": 120, "instruments": INST, "channels": [{"name": "bass", "part": "sine"}],
    "body": {"bass": ["---"] + [""] * 15 + mus.mml("o3 c1 ^1 ^1 c1 ^1", inst = "held")}})
snd.write_spec("t.sndsrc.json", {"kind": "bgm", "target": "t.wav", "voices": [{"ops": [op.song(chip = "t.chip.json")]}]})
`
	checkNoGate(t, script, "drone")
	checkNoGate(t, tied, "")
}

// checkNoGate は gate（only が空でなければその検査だけ）が無いことを見る。
func checkNoGate(t *testing.T, script, only string) {
	t.Helper()
	brs, err := starBuild(t, script)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range brs[0].Findings {
		if f.Level == checklevel.Gate && (only == "" || f.Check == only) {
			t.Fatalf("gate なしのはず（頭で離す・継ぎ目をそろえる）: %v", f)
		}
	}
}
