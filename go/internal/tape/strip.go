package tape

import (
	"fmt"
	"image"
	_ "image/jpeg"
	"math"
	"os"
	"os/exec"
	"path/filepath"
)

// StripCount は duration 秒の動画から 0.5 秒ごとに取るコマの数（0 秒のコマを含む）。
func StripCount(duration float64) int {
	return int(math.Ceil(duration*StripPerSec - 1e-9))
}

// maxJpegSide は jpeg が書ける 1 辺の画素の上限（65535）に余裕を見た数。
const maxJpegSide = 65000

// stripCellSize は n 枚を横 1 列に並べても幅が jpeg の上限に収まる 1 コマの大きさ。
// WhyNot: 間隔（StripPerSec）は頁の全部のテープで共通の欄なので、長いテープだけ間隔を変えずにコマを細くする。
func stripCellSize(n int) (int, int) {
	if n*StripW <= maxJpegSide {
		return StripW, StripH
	}
	// WhyNot: 奇数の辺は ffmpeg の jpeg（4:2:0）が偶数へ丸めてしまい、書いた大きさの確かめと合わなくなる。
	w := (maxJpegSide / n) &^ 1
	if w < 2 {
		w = 2
	}
	return w, int(math.Round(float64(w)*StripH/StripW)) &^ 1
}

// MakeStrip は動画から 0.5 秒ごとのコマを StripW×StripH に縮めて（比が違えば真ん中から切り抜いて）横 1 列に並べた jpg を書く。
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
	w, h := stripCellSize(n)
	vf := fmt.Sprintf("fps=%d,scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,tile=%dx1", StripPerSec, w, h, w, h, n)
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
	if cfg.Width != n*w || cfg.Height != h {
		return Strip{}, fmt.Errorf("%s の大きさが %dx%d（%d 枚なら %dx%d のはず）", out, cfg.Width, cfg.Height, n, n*w, h)
	}
	return Strip{File: filepath.Base(out), Count: n, W: w, H: h}, nil
}
