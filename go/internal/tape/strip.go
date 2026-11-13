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

// MakeStrip は動画から 0.5 秒ごとのコマを、長い辺 StripLong・動画の比のまま縮めて横 1 列に並べた jpg を書く。
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
	vf := fmt.Sprintf("fps=%d,scale='if(gte(iw,ih),%d,-2)':'if(gte(iw,ih),-2,%d)',tile=%dx1", StripPerSec, StripLong, StripLong, n)
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
	w, h := cfg.Width/n, cfg.Height
	if cfg.Width%n != 0 || max(w, h) != StripLong {
		return Strip{}, fmt.Errorf("%s の大きさが %dx%d（%d 枚で長い辺 %d のはず）", out, cfg.Width, cfg.Height, n, StripLong)
	}
	return Strip{File: StripFile, Count: n, W: w, H: h}, nil
}
