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

// maxStripSide は strip.jpg の 1 辺の画素の上限。
// WhyNot: jpeg の上限（65535）まで横に並べない — ブラウザは GPU のテクスチャの上限（8192〜16384）を超えた背景の絵を描かず、
// 長いテープのサムネと映像の帯が真っ黒になった。スマホの GPU にも収まる 8192 より少し下に、縦横どちらも収める
// （PC の Chrome で確かめた。上限が 4096 のスマホの実機は確かめていない）。
const maxStripSide = 8000

// stripGrid は n 枚のコマを、縦横とも maxStripSide に収まる格子（1 コマの幅と高さ・列と行の数）に並べる形。
// 1 行は maxStripSide に収まるだけ並べ、行を重ねる。行を重ねても収まらない長さのテープだけ、コマを細くする。
// WhyNot: 間隔（StripPerSec）は頁の全部のテープで共通の欄なので、長いテープだけ間隔を変えずにコマを細くする。
func stripGrid(n int) (w, h, cols, rows int) {
	// WhyNot: 奇数の辺は ffmpeg の jpeg（4:2:0）が偶数へ丸めてしまい、書いた大きさの確かめと合わなくなる。
	for w = StripW; ; w -= 2 {
		h = int(math.Round(float64(w)*StripH/StripW)) &^ 1
		cols = min(n, maxStripSide/w)
		rows = (n + cols - 1) / cols
		if rows*h <= maxStripSide || w <= 2 {
			return w, h, cols, rows
		}
	}
}

// resolveFFmpeg は ffmpeg（空なら環境変数 FFMPEG、それも無ければ PATH の ffmpeg）の道を返す。
func resolveFFmpeg(ffmpeg string) (string, error) {
	if ffmpeg == "" {
		ffmpeg = os.Getenv("FFMPEG")
	}
	if ffmpeg == "" {
		ffmpeg = "ffmpeg"
	}
	p, err := exec.LookPath(ffmpeg)
	if err != nil {
		return "", fmt.Errorf("ffmpeg が見つからない（%s・PATH に置くか devbox の中で流す）: %w", ffmpeg, err)
	}
	return p, nil
}

// MakeStrip は動画から 0.5 秒ごとのコマを StripW×StripH に縮めて（比が違えば真ん中から切り抜いて）、左上から行ごとに格子に並べた jpg を書く。
// 最後の行の余りは黒。
func MakeStrip(ffmpeg, video, out string, duration float64) (Strip, error) {
	ffmpeg, err := resolveFFmpeg(ffmpeg)
	if err != nil {
		return Strip{}, err
	}
	n := StripCount(duration)
	if n < 1 {
		n = 1
	}
	w, h, cols, rows := stripGrid(n)
	vf := fmt.Sprintf("fps=%d,scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,tile=%dx%d", StripPerSec, w, h, w, h, cols, rows)
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
	if cfg.Width != cols*w || cfg.Height != rows*h {
		return Strip{}, fmt.Errorf("%s の大きさが %dx%d（%d 枚を %d 列 %d 行なら %dx%d のはず）", out, cfg.Width, cfg.Height, n, cols, rows, cols*w, rows*h)
	}
	return Strip{File: filepath.Base(out), Count: n, W: w, H: h, Cols: cols, Rows: rows}, nil
}

// cellOrigin はコマ i の左上の画素。Cols がゼロ値の Strip は横 1 列。
func (s Strip) cellOrigin(i int) (x, y int) {
	cols := s.Cols
	if cols <= 0 {
		cols = s.Count
	}
	return (i % cols) * s.W, (i / cols) * s.H
}
