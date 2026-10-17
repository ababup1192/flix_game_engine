package main

// waveform — WAV を目視できる 1 枚の PNG（コンタクトシート）にする口。読み口と描き方は internal/waveform。

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/waveform"
)

type soundClip = waveform.Clip

var (
	decodeWAV          = waveform.DecodeWAV
	decodeWAVChannels  = waveform.DecodeWAVChannels
	loadClip           = waveform.LoadClip
	collectWAVs        = waveform.CollectWAVs
	buildWaveformSheet = waveform.BuildSheet
)

// waveformSound は --json 用の 1 音ぶん。
type waveformSound struct {
	Name       string  `json:"name"`
	DurationMS int     `json:"durationMs"`
	SampleRate int     `json:"sampleRate"`
	Peak       float64 `json:"peak"`
	Channels   int     `json:"channels"`
	PeakLeft   float64 `json:"peakLeft"`
	PeakRight  float64 `json:"peakRight"`
	SideToMid  float64 `json:"sideToMid"`
}

// waveformResult は --json 用のまとめ。
type waveformResult struct {
	Out    string          `json:"out"`
	Sounds []waveformSound `json:"sounds"`
	Count  int             `json:"count"`
	Exit   int             `json:"exit"`
}

func runWaveform(out, errOut *strings.Builder, paths []string, outPath string, asJSON bool) int {
	if outPath == "" {
		fmt.Fprintln(errOut, "使い方: fge waveform <wavファイル|フォルダ...> --out <PNGのパス>")
		return 2
	}
	files, err := collectWAVs(paths)
	if err != nil {
		fmt.Fprintf(errOut, "fge-go: %v\n", err)
		return 1
	}
	if len(files) == 0 {
		fmt.Fprintln(errOut, "fge-go: WAV が 1 つも見つかりません (白紙の PNG は作りません)")
		return 1
	}

	var clips []soundClip
	for _, f := range files {
		clip, err := loadClip(f)
		if err != nil {
			fmt.Fprintf(errOut, "fge-go: %v\n", err)
			return 1
		}
		clips = append(clips, clip)
	}
	loudest := 0.0
	for _, clip := range clips {
		if p := clip.Peak(); p > loudest {
			loudest = p
		}
	}
	if loudest <= 0 {
		fmt.Fprintf(errOut,
			"fge-go: %d 個とも全部無音 (ピーク 0) です。書き出し側を疑ってください\n", len(clips))
		return 1
	}

	w, h, grid := buildWaveformSheet(clips)
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fmt.Fprintf(errOut, "fge-go: %v\n", err)
		return 1
	}
	if err := os.WriteFile(outPath, encodePNG(w, h, grid), 0o644); err != nil {
		fmt.Fprintf(errOut, "fge-go: %v\n", err)
		return 1
	}

	sounds := make([]waveformSound, 0, len(clips))
	for _, clip := range clips {
		l, r := clip.SidePeaks()
		sounds = append(sounds, waveformSound{
			clip.Name, clip.DurationMS(), clip.SampleRate, clip.Peak(),
			max(1, len(clip.Channels)), l, r, clip.SideToMid()})
	}
	if asJSON {
		emitJSON(out, waveformResult{outPath, sounds, len(sounds), 0})
		return 0
	}
	for _, s := range sounds {
		if s.Channels == 2 {
			fmt.Fprintf(out, "  %-12s %5dms %6dHz stereo L %.3f R %.3f side %.2f\n",
				s.Name, s.DurationMS, s.SampleRate, s.PeakLeft, s.PeakRight, s.SideToMid)
			continue
		}
		fmt.Fprintf(out, "  %-12s %5dms %6dHz peak %.3f\n",
			s.Name, s.DurationMS, s.SampleRate, s.Peak)
	}
	fmt.Fprintf(out, "%d 音を %s に描き出した (%dx%d)\n", len(sounds), outPath, w, h)
	return 0
}
