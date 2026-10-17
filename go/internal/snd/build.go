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
)

// buildResult は spec 1 本の書き出しの結果。
type buildResult struct {
	Spec      string    `json:"spec"`
	Target    string    `json:"target"`
	Wrote     bool      `json:"wrote"`
	Rate      int       `json:"rate"`
	Samples   int       `json:"samples"`
	LoopStart int       `json:"loopStart"`
	Seconds   float64   `json:"seconds"`
	LUFS      float64   `json:"lufs"`
	PeakDBFS  float64   `json:"peakDbfs"`
	SHA256    string    `json:"sha256"`
	Findings  []finding `json:"findings"`
	Report    string    `json:"report"`
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
	r := newRenderer(workRoot, s)
	res, err := r.render(nil)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", s.Path, err)
	}
	wav := EncodeWAV(s.Rate, res.out, res.loopStart)
	sum := sha256.Sum256(wav)
	br := &buildResult{Spec: s.Path, Target: s.Target, Rate: s.Rate, Samples: len(res.out), LoopStart: res.loopStart,
		Seconds: float64(len(res.out)) / float64(s.Rate), LUFS: finite(LUFS(s.Rate, res.out)),
		PeakDBFS: finite(dBFS(peakOf(res.out))), SHA256: hex.EncodeToString(sum[:]), Findings: runChecks(r, res, st, rules)}
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
	data, _ := json.MarshalIndent(br, "", "  ")
	if err := os.WriteFile(filepath.Join(workRoot, filepath.FromSlash(br.Report)), append(data, '\n'), 0o644); err != nil {
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
	fmt.Fprintf(&sb, "%s → %s: %s（%.3f 秒・%d サンプル%s・%.1f LUFS・ピーク %.1f dBFS・sha256 %s）\n",
		b.Spec, b.Target, state, b.Seconds, b.Samples, loop, b.LUFS, b.PeakDBFS, b.SHA256[:12])
	for _, f := range b.Findings {
		sb.WriteString("  " + f.String() + "\n")
	}
	return sb.String()
}
