package snd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/starbox"
	"github.com/ababup1192/flixlint/go/checklevel"
)

// engineRoot はテストから見たリポジトリのルート（bin/lint-rules/ がある所）。
const engineRoot = "../../.."

func mustSpec(t *testing.T, js string) *spec {
	t.Helper()
	s, err := parseSpec("t.sndsrc.json", []byte(js))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func check(t *testing.T, js string) *buildResult {
	t.Helper()
	br, err := buildSpec(engineRoot, ".", mustSpec(t, js), buildOptions{NoWrite: true})
	if err != nil {
		t.Fatal(err)
	}
	return br
}

func gateOf(br *buildResult, name string) *finding {
	for i, f := range br.Findings {
		if f.Level == checklevel.Gate && f.Check == name {
			return &br.Findings[i]
		}
	}
	return nil
}

// どの op の例も読めて鳴る（docs に載せる例が壊れていない）。
func TestOpExamplesRender(t *testing.T) {
	for _, d := range allOps() {
		voice := `{"ops": [` + d.Example + `]}`
		if !d.source() {
			voice = `{"ops": [{"pulse": {"hz": 440, "ms": 50}}, ` + d.Example + `]}`
		}
		br := check(t, `{"target": "debug/x.wav", "voices": [`+voice+`]}`)
		if br.Samples == 0 {
			t.Errorf("%s: 例が無音の 0 サンプル", d.Name)
		}
	}
}

// 同じ spec は何度鳴らしても同じバイト（WAV の sha256）。
func TestBuildIsDeterministic(t *testing.T) {
	js := `{"target": "debug/x.wav", "voices": [
		{"ops": [{"song": {"chip": "testdata/snd/tiny.chip.json", "instruments": "testdata/snd/tiny.instrument.json"}}]}]}`
	a, b := check(t, js), check(t, js)
	if a.SHA256 != b.SHA256 {
		t.Fatalf("2 回の書き出しが違う: %s / %s", a.SHA256, b.SHA256)
	}
}

// 譜面のループ点から smpl のループの頭が決まり、輪は整数小節（tempo は譜面の bpm）。
func TestSongLoopIsWholeBars(t *testing.T) {
	br := check(t, `{"style": "gb", "kind": "bgm", "target": "debug/x.wav", "voices": [
		{"ops": [{"song": {"chip": "testdata/snd/tiny.chip.json", "instruments": "testdata/snd/tiny.instrument.json"}}]}]}`)
	perBar := 22050 * 60 * 4 / 120 // 120 BPM の 1 小節
	if br.LoopStart != perBar || br.Samples != perBar*3 {
		t.Fatalf("頭 1 小節 + 輪 2 小節のはず: loop %d・%d サンプル", br.LoopStart, br.Samples)
	}
	if gateFailed(br.Findings) {
		t.Fatalf("gate で止まった: %v", br.Findings)
	}
}

// わざと壊した入力を gate が原因の op つきで止める。
func TestGateStopsWithCause(t *testing.T) {
	bar := "1371.4285714285713" // 175 BPM の 1 小節（ミリ秒）
	cases := []struct{ name, js, check, cause string }{
		{"割れ（post の gain）", `{"target": "debug/x.wav", "voices": [{"ops": [{"pulse": {"hz": 440, "ms": 50, "amp": 0.5}}]}],
			"post": [{"gain": {"by": 4}}]}`, "clip", "post[0] gain"},
		{"割れ（譜面）", `{"target": "debug/x.wav", "voices": [{"ops": [{"song": {"chip": "testdata/snd/tiny.chip.json", "instruments": "testdata/snd/tiny.instrument.json"}}]}],
			"post": [{"gain": {"by": 8}}]}`, "clip", "post[0] gain"},
		{"継ぎ目（輪の終わりの fade）", `{"kind": "bgm", "target": "debug/x.wav", "loop_start_ms": 0, "tempo": {"bpm": 175},
			"voices": [{"id": "bass", "ops": [{"pulse": {"hz": 110, "ms": ` + bar + `, "amp": 0.3}}, {"fade": {}}]}]}`, "seam", "voices[0](bass).ops[1] fade"},
		{"継ぎ目（1 サンプルの段差）", `{"kind": "bgm", "target": "debug/x.wav", "loop_start_ms": 0, "tempo": {"bpm": 175},
			"voices": [{"id": "bass", "ops": [{"pulse": {"hz": 97, "ms": ` + bar + `, "amp": 0.3}}, {"lowpass": {"hz": 200, "stages": 2}}]}]}`, "seam", "voices[0](bass).ops[1] lowpass"},
		{"機種の外（gb でパルス 3 本）", `{"style": "gb", "target": "debug/x.wav", "voices": [
			{"id": "a", "ops": [{"pulse": {"hz": 440, "ms": 100, "amp": 0.2}}]},
			{"id": "b", "ops": [{"pulse": {"hz": 554, "ms": 100, "amp": 0.2}}]},
			{"id": "c", "at": 50, "ops": [{"pulse": {"hz": 659, "ms": 100, "amp": 0.2}}]}]}`, "style", "voices[2](c).ops[0] pulse"},
		{"機種の外（gb でフィルタ）", `{"style": "gb", "target": "debug/x.wav", "voices": [
			{"ops": [{"noise": {"kind": "lfsr15", "ms": 100, "amp": 0.2}}, {"svf": {"hz": 3000}}]}]}`, "style", "voices[0](v0).ops[1] svf"},
		{"小節のずれ（半拍）", `{"kind": "bgm", "target": "debug/x.wav", "loop_start_ms": 0, "tempo": {"bpm": 175},
			"voices": [{"id": "bass", "ops": [{"pulse": {"hz": 110, "ms": 2914.2857142857138, "amp": 0.3}}]}]}`, "bars", "voices[0](bass).ops[0] pulse"},
	}
	for _, c := range cases {
		br := check(t, c.js)
		f := gateOf(br, c.check)
		if f == nil {
			t.Errorf("%s: gate %s で止まらない: %v", c.name, c.check, br.Findings)
			continue
		}
		if !strings.Contains(f.Cause, c.cause) {
			t.Errorf("%s: 原因が %q（%q のはず）", c.name, f.Cause, c.cause)
		}
	}
}

// gate を通る音は止めない（試作の形の音で誤って止めない）。
func TestGatePassesCleanSounds(t *testing.T) {
	bars := "2742.8571428571427" // 175 BPM の 2 小節
	for _, js := range []string{
		`{"target": "debug/x.wav", "voices": [{"ops": [{"pulse": {"hz": 784, "ms": 40, "amp": 0.16}}, {"fade": {}}]}]}`,
		`{"style": "gb", "target": "debug/x.wav", "voices": [{"ops": [{"noise": {"kind": "lfsr15", "hz": 131072, "to_hz": 4096, "ms": 210, "amp": 0.2}}, {"steps": {"level": 15, "every_ms": 14}}]}]}`,
		`{"kind": "bgm", "target": "debug/x.wav", "loop_start_ms": 0, "tempo": {"bpm": 175}, "voices": [{"ops": [{"pulse": {"hz": 175, "ms": ` + bars + `, "amp": 0.3}}]}]}`,
	} {
		if br := check(t, js); gateFailed(br.Findings) {
			t.Errorf("止めない音を止めた: %v\n%s", br.Findings, js)
		}
	}
}

// WAV の smpl のループの頭は読み直しても同じ（鳴らす側が読む値）。
func TestWAVLoopRoundTrip(t *testing.T) {
	c, err := DecodeWAV(EncodeWAV(22050, [][]float64{{0, 0.5, -0.5, 1, -1}}, 2))
	if err != nil {
		t.Fatal(err)
	}
	if c.LoopStart != 2 || c.LoopEnd != 4 || len(c.Ints) != 5 || c.Ints[3] != 32767 {
		t.Fatalf("loop %d〜%d・%v", c.LoopStart, c.LoopEnd, c.Ints)
	}
}

// 台本: write_spec は assets/ の下へ書けない・read_json で Doc を読める・書いた spec は検査を通る。
func TestStarWritesSpecsAndRefusesAssets(t *testing.T) {
	dir := t.TempDir()
	write := func(p, s string) {
		full := filepath.Join(dir, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("assets/tune.json", `{"decide": {"volume": 0.5}}`)
	write("atelier/sfx/a.snd.star", `
tune = snd.read_json("//assets/tune.json")["decide"]
def build():
    for i in range(3):
        snd.write_spec("a%d.sndsrc.json" % i, {"target": "a%d.wav" % i, "voices": [{"ops": [op.pulse(hz = 440 * (i + 1), ms = 30, amp = tune["volume"])]}]})
build()
`)
	res, err := runStar(dir, "atelier/sfx/a.snd.star", starbox.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Files) != 3 || !strings.Contains(string(res.Files[2].Data), `"atelier/sfx/a2.wav"`) {
		t.Fatalf("3 本・target は作業場の根から: %v", res.Files)
	}
	write("atelier/sfx/b.snd.star", `snd.write_spec("//assets/b.sndsrc.json", {"target": "b.wav", "voices": [{"ops": [op.rest(ms = 1)]}]})`)
	if _, err := runStar(dir, "atelier/sfx/b.snd.star", starbox.Options{}); err == nil || !strings.Contains(err.Error(), "assets/") {
		t.Fatalf("assets/ の下へ書けてしまう: %v", err)
	}
}

// docs/snd-ops.md は op の登録と同じ（op を足したら fge snd schema --write）。
func TestDocsAreInSync(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(engineRoot, "docs", "snd-ops.md"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != opsMarkdown() {
		t.Fatal("docs/snd-ops.md が古い（bin/fge snd schema --write で書き直す）")
	}
}
