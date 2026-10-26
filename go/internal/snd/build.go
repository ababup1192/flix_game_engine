package snd

// build: spec を鳴らして検査し、gate を通れば target の WAV を書く。検査の結果は debug/snd/<名前>/report.json、
// 波形とスペクトログラムは debug/snd/<名前>/sheet.png（gate で止まった時も、聞く前に目で見られるように書く）。

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/waveform"
	"github.com/ababup1192/flixlint/go/checklevel"
	"github.com/ababup1192/flixlint/go/checkres"
)

// buildResult は spec 1 本の書き出しの結果。
type buildResult struct {
	Check     *checkres.Round `json:"check,omitempty"` // 新しい形の結果とまとめ（docs/check-results.md。AI が先に読むので頭に）
	Spec      string          `json:"spec"`
	Target    string          `json:"target"`
	Wrote     bool            `json:"wrote"`
	Rate      int             `json:"rate"`
	Samples   int             `json:"samples"`
	LoopStart int             `json:"loopStart"`
	Channels  int             `json:"channels"`
	Seconds   float64         `json:"seconds"`
	LUFS      float64         `json:"lufs"` // ループする音は輪の 1 周
	PeakDBFS  float64         `json:"peakDbfs"`
	TruePeak  float64         `json:"truePeakDbtp"`
	Breaks    []string        `json:"breaks"` // 破った所（使った機種の外の手）
	SHA256    string          `json:"sha256"`
	Findings  []finding       `json:"findings"`
	Report    string          `json:"report"`
}

type buildOptions struct {
	NoWrite bool // 検査だけ（WAV も report も書かない）
}

func specName(path string) string {
	b := filepath.Base(path)
	return strings.TrimSuffix(strings.TrimSuffix(b, ".sndsrc.json"), starSuffix)
}

func finite(f float64) float64 {
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return -999
	}
	return f
}

func buildSpec(engineRoot, workRoot string, s *spec, opt buildOptions) (*buildResult, error) {
	rules, err := loadRules(engineRoot)
	if err != nil {
		return nil, err
	}
	st, err := rules.style(workRoot, s.Style)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", s.Path, err)
	}
	kindLUFS := -20.0
	if lu, ok := rules.Loudness[s.Kind]; ok {
		kindLUFS = lu.Target
	}
	r := newRenderer(&rctx{rate: float64(s.Rate), workRoot: workRoot, files: s.Files, kindLUFS: kindLUFS, truePeak: rules.TruePeakDBTP}, s)
	res, err := r.render(nil)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", s.Path, err)
	}
	wav := EncodeWAV(s.Rate, res.out, res.loopStart)
	sum := sha256.Sum256(wav)
	br := &buildResult{Spec: s.Path, Target: s.Target, Rate: s.Rate, Samples: res.frames(), LoopStart: res.loopStart, Channels: len(res.out),
		Seconds: float64(res.frames()) / float64(s.Rate), LUFS: finite(LUFS(s.Rate, loopBody(res.out, res.loopStart))),
		PeakDBFS: finite(dBFS(peakOf(res.out...))), TruePeak: finite(dBFS(truePeakOf(res.out...))), Breaks: res.breaks,
		SHA256: hex.EncodeToString(sum[:]), Findings: runChecks(r, res, st, rules)}
	fmtRules, err := checkres.LoadRules(engineRoot)
	if err != nil {
		return nil, err
	}
	var prevKeys map[string]bool
	reportPath := filepath.Join(workRoot, "debug", "snd", specName(s.Path), "report.json")
	if prev := loadReport(reportPath); prev != nil && prev.Check != nil {
		prevKeys = map[string]bool{}
		for _, r := range prev.Check.Results {
			prevKeys[r.Key()] = true
		}
	}
	br.Check = roundOfFindings(br.Findings, fmtRules, prevKeys)
	br.Check.Summary.Applied = map[string]checklevel.Applied{specName(s.Path): checkres.AppliedOf(appliedOf(s, res, st, rules), prevApplied(reportPath, specName(s.Path)), false)}
	if opt.NoWrite {
		return br, nil
	}
	dir := filepath.Join(workRoot, "debug", "snd", specName(s.Path))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	last := filepath.Join(dir, "last.wav") // gate で止まっても目で見る用（target ではない）
	if err := os.WriteFile(last, wav, 0o644); err != nil {
		return nil, err
	}
	if err := waveform.WriteSheet([]string{last}, filepath.Join(dir, "sheet.png")); err != nil {
		return nil, err
	}
	if !gateFailed(br.Findings) {
		target := filepath.Join(workRoot, filepath.FromSlash(s.Target))
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return nil, err
		}
		if old, err := os.ReadFile(target); err != nil || string(old) != string(wav) {
			if err := os.WriteFile(target, wav, 0o644); err != nil {
				return nil, err
			}
		}
		br.Wrote = true
	}
	br.Report = filepath.ToSlash(filepath.Join("debug", "snd", specName(s.Path), "report.json"))
	if err := os.WriteFile(filepath.Join(workRoot, filepath.FromSlash(br.Report)), checkres.JSON(br), 0o644); err != nil {
		return nil, err
	}
	return br, nil
}

func (b *buildResult) summary() string {
	var sb strings.Builder
	state := "書いた"
	if !b.Wrote {
		state = "書かなかった"
	}
	if gateFailed(b.Findings) {
		state = "gate で止めた（WAV は書かない）"
	}
	loop := ""
	if b.LoopStart >= 0 {
		loop = fmt.Sprintf("・ループの頭 %d", b.LoopStart)
	}
	chans := "ステレオ"
	if b.Channels == 1 {
		chans = "モノラル"
	}
	fmt.Fprintf(&sb, "%s → %s: %s（%s・%.3f 秒・%d サンプル%s・%.1f LUFS・ピーク %.1f dBFS・true peak %.1f dBTP・sha256 %s）\n",
		b.Spec, b.Target, state, chans, b.Seconds, b.Samples, loop, b.LUFS, b.PeakDBFS, b.TruePeak, b.SHA256[:12])
	for _, f := range b.Findings {
		sb.WriteString("  " + f.String() + "\n")
	}
	if b.Check != nil {
		sb.WriteString("  検査: " + b.Check.Summary.Line() + "\n")
	}
	return sb.String()
}

// roundOfFindings は結果を新しい形の結果とまとめにする。
func roundOfFindings(fs []finding, rules *checkres.Rules, prevKeys map[string]bool) *checkres.Round {
	results := []checkres.Result{}
	for _, f := range fs {
		r := f.result(rules)
		r.Scope = checkres.ScopeFile
		results = append(results, r)
	}
	return &checkres.Round{Summary: checkres.Summarize(results, rules, prevKeys), Results: results}
}

// appliedOf は音 1 本に当てた検査の組（当てなかった物は理由つき）。
func appliedOf(s *spec, res *rendered, st *sndStyle, rules *sndRules) checklevel.AppliedFull {
	full := checklevel.AppliedFull{Style: s.Style, Checks: []string{"clip", "peak", "truepeak", "dc", "alias", "breaks"}}
	skip := func(code, why, by string) {
		full.Skipped = append(full.Skipped, checklevel.Skip{Code: code, Why: why, By: by})
	}
	if st.free() {
		skip("style", "縛りの無い機種（ops も voices も無い）", "style")
	} else {
		full.Checks = append(full.Checks, "style")
	}
	if rules.DroneSeconds > 0 {
		full.Checks = append(full.Checks, "drone")
	}
	if res.loopStart >= 0 {
		full.Checks = append(full.Checks, "seam")
		skip("head", "ループする音は頭の遅れを見ない", "loop")
		skip("tail", "ループする音は終わりを見ない（継ぎ目は seam）", "loop")
		if res.tempo != nil {
			full.Checks = append(full.Checks, "bars")
		} else {
			skip("bars", "tempo が無い", "spec")
		}
	} else {
		full.Checks = append(full.Checks, "head", "tail")
		skip("seam", "ループしない音", "loop")
		skip("bars", "ループしない音", "loop")
	}
	if _, ok := rules.Loudness[s.Kind]; ok {
		full.Checks = append(full.Checks, "loudness")
	} else {
		skip("loudness", "kind "+s.Kind+" に音量の目安が無い", "kind")
	}
	return full
}

// prevApplied は前の build の report.json の当てた検査の組の id。
func prevApplied(path, name string) string {
	if prev := loadReport(path); prev != nil && prev.Check != nil {
		return prev.Check.Summary.Applied[name].ID
	}
	return ""
}

// loadReport は前の build の report.json（無いか読めなければ nil）。
func loadReport(path string) *buildResult {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var b buildResult
	if json.Unmarshal(data, &b) != nil {
		return nil
	}
	return &b
}
