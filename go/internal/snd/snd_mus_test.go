package snd

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flixlint/go/checklevel"
)

// starBuild は台本を走らせ、書いた spec を全部 build する（WAV は書かない）。
func starBuild(t *testing.T, script string) ([]*buildResult, error) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.snd.star"), []byte(script), 0o644); err != nil {
		t.Fatal(err)
	}
	var errOut strings.Builder
	specs, _, ok := specsOf(&errOut, dir, []string{"a.snd.star"})
	if !ok {
		return nil, &starErr{errOut.String()}
	}
	var out []*buildResult
	for _, s := range specs {
		br, err := buildSpec(engineRoot, dir, s, buildOptions{NoWrite: true})
		if err != nil {
			return nil, err
		}
		out = append(out, br)
	}
	return out, nil
}

type starErr struct{ s string }

func (e *starErr) Error() string { return e.s }

func render(t *testing.T, js string) *rendered {
	t.Helper()
	s := mustSpec(t, js)
	res, err := newRenderer(&rctx{rate: float64(s.Rate), kindLUFS: -20, truePeak: -1}, s).render(nil)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// 左に振り切った声は右に出ない。mono は 1 本で、pan を見ない。
func TestPanAndMono(t *testing.T) {
	st := render(t, `{"target": "x.wav", "voices": [{"pan": -1, "ops": [{"pulse": {"hz": 440, "ms": 50}}]}]}`)
	if len(st.out) != 2 || peakOf(st.out[1]) != 0 || peakOf(st.out[0]) == 0 {
		t.Fatalf("左だけに出るはず: %d 本・左 %v・右 %v", len(st.out), peakOf(st.out[0]), peakOf(st.out[1]))
	}
	mono := render(t, `{"channels": "mono", "target": "x.wav", "voices": [{"pan": -1, "ops": [{"pulse": {"hz": 440, "ms": 50}}]}]}`)
	if len(mono.out) != 1 || peakOf(mono.out[0]) == 0 {
		t.Fatalf("mono は 1 本で鳴るはず: %d 本", len(mono.out))
	}
}

// normalize は統合ラウドネスを目標にそろえ、true peak の上限を超えるなら倍率を下げる。
func TestNormalize(t *testing.T) {
	quiet := render(t, `{"target": "x.wav", "voices": [{"ops": [{"pulse": {"hz": 220, "ms": 1500, "amp": 0.05}}]}],
		"post": [{"normalize": {"lufs": -16}}]}`)
	if l := LUFS(22050, quiet.out); math.Abs(l+16) > 0.05 {
		t.Fatalf("-16 LUFS のはず: %.2f", l)
	}
	loud := render(t, `{"target": "x.wav", "voices": [{"ops": [{"pulse": {"hz": 220, "ms": 1500, "amp": 0.05}}]}],
		"post": [{"normalize": {"lufs": -3, "peak_dbtp": -1}}]}`)
	if tp := dBFS(truePeakOf(loud.out...)); tp > -0.99 {
		t.Fatalf("true peak は -1 dBTP まで: %.2f", tp)
	}
}

// MML: 付点は 16 分の格子で 3+3+2 に並び、小節の長さが合わなければ止まる。q は CUT で離す。
func TestMML(t *testing.T) {
	steps, err := parseMML("o5 d8. g8. b8 a4 g8 r8", mmlState{octave: 5, length: 8, vol: -1, quantize: 8, ticks: 6})
	if err != nil {
		t.Fatal(err)
	}
	if steps[0] != "D-5" || steps[3] != "G-5" || steps[6] != "B-5" || steps[14] != "OFF" || len(steps) != 16 {
		t.Fatalf("付点の並びが違う: %q", steps)
	}
	if _, err := parseMML("c4 d4 e4 | f1", mmlState{octave: 5, length: 8, vol: -1, quantize: 8, ticks: 6}); err == nil || !strings.Contains(err.Error(), "1 小節目") {
		t.Fatalf("12 段の小節を止めるはず: %v", err)
	}
	cut, _ := parseMML("c4 ^4 r2", mmlState{octave: 5, length: 8, vol: -1, quantize: 4, ticks: 6})
	if cut[0] != "C-5 CUT 24" {
		t.Fatalf("^ でのばした 8 段の半分 = 24 tick で離すはず: %q", cut[0])
	}
}

const chipScript = `
P = mus.chords("C | G")
snd.write_chip("t.chip.json", {"bpm": 120, "groove": GROOVE, "gain": 0.5,
    "channels": [{"name": "lead", "part": "pulse", "pan": -0.5, "send": {"reverb": 0.3}}, {"name": "bass", "part": "triangle"}],
    "instruments": {"pl": {"duty": "25", "vol": "15 | 15 / 8 4 0"}},
    "fx": {"reverb": {"room": 0.5}},
    "body": {"lead": mus.mml("o5 c4 e4 g4 e4 | d2 b4 r4", inst = "pl"), "bass": mus.bass(P, "x---x---x---x---", ["1", "5"])}})
snd.write_spec("t.sndsrc.json", {"style": STYLE, "kind": "bgm", "target": "t.wav", "voices": [{"ops": [op.song(chip = "t.chip.json")]}],
    "post": [op.normalize(lufs = -16)]})
`

// 台本の write_chip → song → normalize がつながり、ループは整数小節（groove でも）・音量は輪の 1 周で -16 LUFS。
// 機種の外の手（reverb・pan）は neo なら報告だけ・gb なら gate。
func TestWriteChipAndBreaks(t *testing.T) {
	script := strings.NewReplacer("GROOVE", "[7, 5]", "STYLE", `"neo"`).Replace(chipScript)
	brs, err := starBuild(t, script)
	if err != nil {
		t.Fatal(err)
	}
	br := brs[0]
	if gateFailed(br.Findings) || br.LoopStart != 0 || br.Samples != 2*22050*2 || math.Abs(br.LUFS+16) > 0.05 {
		t.Fatalf("2 小節の輪・-16 LUFS・gate なしのはず: %+v", br)
	}
	if !contains(br.Breaks, "reverb") || !contains(br.Breaks, "pan") {
		t.Fatalf("破った所に reverb と pan: %v", br.Breaks)
	}
	gb, err := starBuild(t, strings.NewReplacer("GROOVE", "[6]", "STYLE", `"gb"`).Replace(chipScript))
	if err != nil {
		t.Fatal(err)
	}
	stopped := false
	for _, f := range gb[0].Findings {
		stopped = stopped || (f.Level == checklevel.Gate && f.Check == "style" && strings.Contains(f.Msg, "reverb"))
	}
	if !stopped {
		t.Fatalf("gb で reverb を止めるはず: %v", gb[0].Findings)
	}
}

// 小節の数がそろわない body は write_chip が止める（短い声を黙って休みで埋めない）。
func TestWriteChipRefusesRaggedSections(t *testing.T) {
	_, err := starBuild(t, `snd.write_chip("t.chip.json", {"bpm": 120, "body": {"pulse1": mus.mml("c1 | c1"), "triangle": mus.mml("c1")}})
snd.write_spec("t.sndsrc.json", {"target": "t.wav", "voices": [{"ops": [op.song(chip = "t.chip.json")]}]})`)
	if err == nil || !strings.Contains(err.Error(), "そろっていない") {
		t.Fatalf("止めるはず: %v", err)
	}
}

// 楽器の表の release: 離した後も尾が鳴る。release の無い楽器は離した所で止まる。DLY は頭を遅らせる。
func TestMacroReleaseAndDelay(t *testing.T) {
	in := instruments{byName: map[string]instrument{}, waves: map[string][]int{}}
	if err := addInstruments(&in, map[string]any{"instruments": map[string]any{
		"rel":  map[string]any{"vol": "15 | 15 / 12 9 6 3 0"},
		"hard": map[string]any{"vol": "15"},
	}}, "t"); err != nil {
		t.Fatal(err)
	}
	s := &song{bpm: 120, ticks: 6, rate: 22050}
	vols := func(inst, cmds string) []float64 {
		fs := controlFrames(s, in, partPulse, []step{parseStep("C-5 " + inst + cmds), parseStep("OFF"), {volume: -1}})
		out := make([]float64, len(fs))
		for i, f := range fs {
			out[i] = f.volume
		}
		return out
	}
	rel, hard := vols("rel", ""), vols("hard", "")
	if rel[7] == 0 || rel[6+5] != 0 || hard[6] != 0 {
		t.Fatalf("release の尾 %v・無い楽器 %v", rel, hard)
	}
	dly := vols("hard", " DLY 3")
	if dly[2] != 0 || dly[3] == 0 {
		t.Fatalf("DLY 3 は 3 tick 目から鳴る: %v", dly)
	}
}

// 4 倍の読み直しは標本の間の山を拾う（ナイキストの 1/4 のサインを 45 度ずらすと標本のピークは 0.707）。
func TestTruePeakSeesBetweenSamples(t *testing.T) {
	x := make([]float64, 400)
	for i := range x {
		x[i] = math.Sin(math.Pi/2*float64(i) + math.Pi/4)
	}
	if p, tp := peakOf(x), truePeakOf(x); p > 0.71 || tp < 0.95 {
		t.Fatalf("標本 %.3f・true peak %.3f", p, tp)
	}
}
