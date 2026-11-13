package tape

import (
	"fmt"
	"image"
	_ "image/jpeg"
	"math"
	"os"
	"os/exec"
)

// StripCount は duration 秒の動画から 0.5 秒ごとに取るコマの数（0 秒のコマを含む）。
func StripCount(duration float64) int {
	return int(math.Ceil(duration*StripPerSec - 1e-9))
}

// MakeStrip は動画から 0.5 秒ごとのコマを 54×96 に縮めて横 1 列に並べた jpg を書く。
func MakeStrip(ffmpeg, video, out string, duration float64) (Strip, error) {
	if ffmpeg == "" {
		ffmpeg = os.Getenv("FFMPEG")
	}
	if ffmpeg == "" {
		p, err := exec.LookPath("ffmpeg")
		if err != nil {
			return Strip{}, fmt.Errorf("ffmpeg が見つからない（PATH に置くか devbox の中で流す）: %w", err)
		}
		ffmpeg = p
	}
	n := StripCount(duration)
	if n < 1 {
		n = 1
	}
	vf := fmt.Sprintf("fps=%d,scale=%d:%d,tile=%dx1", StripPerSec, StripW, StripH, n)
	cmd := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", video,
		"-vf", vf, "-frames:v", "1", "-q:v", "4", out)
	if msg, err := cmd.CombinedOutput(); err != nil {
		return Strip{}, fmt.Errorf("strip.jpg を作れない（ffmpeg -vf %q）: %v\n%s", vf, err, msg)
	}
	f, err := os.Open(out)
	if err != nil {
		return Strip{}, err
	}
	defer f.Close()
	cfg, _, err := image.DecodeConfig(f)
	if err != nil {
		return Strip{}, fmt.Errorf("書いた %s を読めない: %w", out, err)
	}
	if cfg.Width != n*StripW || cfg.Height != StripH {
		return Strip{}, fmt.Errorf("%s の大きさが %dx%d（%d 枚なら %dx%d のはず）", out, cfg.Width, cfg.Height, n, n*StripW, StripH)
	}
	return Strip{File: StripFile, Count: n, W: StripW, H: StripH}, nil
}
