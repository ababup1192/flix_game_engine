package migrate

import (
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// VideoHeight は横に並べる時にそろえる高さ（2 本の大きさが違っても並ぶように）。
const VideoHeight = 960

// errInput は入力が揃っていない誤り（終わりの番号 2）。
var errInput = errors.New("入力が無い")

type videoArgs struct {
	old, cur, out, tape string
}

func parseVideoArgs(args []string) (videoArgs, error) {
	var a videoArgs
	for i := 0; i < len(args); i++ {
		if i+1 >= len(args) {
			return a, fmt.Errorf("%s の後に値が要る", args[i])
		}
		switch args[i] {
		case "--old":
			a.old = args[i+1]
		case "--new":
			a.cur = args[i+1]
		case "--out":
			a.out = args[i+1]
		case "--tape":
			a.tape = args[i+1]
		default:
			return a, fmt.Errorf("知らない引数: %s", args[i])
		}
		i++
	}
	if a.old == "" || a.cur == "" || a.out == "" {
		return a, fmt.Errorf("--old・--new・--out が要る")
	}
	return a, nil
}

func runVideo(args []string, stdout, stderr io.Writer) int {
	a, err := parseVideoArgs(args)
	if err != nil {
		fmt.Fprintf(stderr, "migrate video: %v\n%s\n", err, usage)
		return 2
	}
	if err := SideBySide(a.old, a.cur, a.out, a.tape, ffmpegPath()); err != nil {
		fmt.Fprintln(stderr, "migrate video:", err)
		if errors.Is(err, errInput) {
			return 2
		}
		return 1
	}
	fmt.Fprintln(stdout, a.out)
	return 0
}

func ffmpegPath() string {
	if v := os.Getenv("FFMPEG"); v != "" {
		return v
	}
	return "ffmpeg"
}

// ffprobePath は ffmpeg と同じ所の ffprobe（PATH の名前ならそのまま ffprobe）。
func ffprobePath(ffmpeg string) string {
	dir, base := filepath.Split(ffmpeg)
	return dir + strings.Replace(base, "ffmpeg", "ffprobe", 1)
}

type clipInfo struct {
	seconds  float64
	hasAudio bool
}

func probeClip(ffprobe, path string) (clipInfo, error) {
	out, err := exec.Command(ffprobe, "-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "default=nw=1", path).Output()
	if err != nil {
		return clipInfo{}, fmt.Errorf("ffprobe が %s を読めない: %w", path, err)
	}
	var info clipInfo
	for _, line := range strings.Split(string(out), "\n") {
		switch {
		case line == "codec_type=audio":
			info.hasAudio = true
		case strings.HasPrefix(line, "duration="):
			info.seconds, _ = strconv.ParseFloat(strings.TrimPrefix(line, "duration="), 64)
		}
	}
	return info, nil
}

// SideBySide は old を左・cur を右に並べた mp4 を out に書く。音は前を左・新しいを右のチャンネルに分ける
// （2 本を混ぜると、どちらの音がずれたか聞き分けられない）。tapePath があれば台詞の字幕を絵に重ねる。
// WhyNot: 短い方で切らない（-shortest を使わない）— 移行で長さが替わった所こそ見たいので、短い方は最後のコマと無音で伸ばす。
func SideBySide(old, cur, out, tapePath, ffmpeg string) error {
	for _, p := range []string{old, cur} {
		if !fileExists(p) {
			return fmt.Errorf("%w: %s", errInput, p)
		}
	}
	absOut, err := filepath.Abs(out)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(absOut), 0o755); err != nil {
		return err
	}
	absOld, _ := filepath.Abs(old)
	absCur, _ := filepath.Abs(cur)
	ffprobe := ffprobePath(ffmpeg)
	infoOld, err := probeClip(ffprobe, absOld)
	if err != nil {
		return err
	}
	infoCur, err := probeClip(ffprobe, absCur)
	if err != nil {
		return err
	}
	total := math.Max(infoOld.seconds, infoCur.seconds)
	pad := func(in string, info clipInfo) string {
		return fmt.Sprintf("[%s:v]scale=-2:%d,setsar=1,tpad=stop_mode=clone:stop_duration=%.3f", in, VideoHeight, total-info.seconds)
	}
	video := pad("0", infoOld) + "[l];" + pad("1", infoCur) + "[r];[l][r]hstack=inputs=2"
	if tapePath != "" {
		srt := strings.TrimSuffix(absOut, filepath.Ext(absOut)) + ".srt"
		if err := writeSubtitles(tapePath, srt); err != nil {
			return err
		}
		// WhyNot: subtitles= に絶対パスを渡さない — フィルタの書き方で : と \ を逃がす決まりが OS ごとに違う。出力の隣に置いて名前だけ渡す。
		video += ",subtitles=" + filepath.Base(srt)
	}
	args := []string{"-y", "-loglevel", "error", "-i", absOld, "-i", absCur}
	audio := func(in int, info clipInfo) string {
		if info.hasAudio {
			return fmt.Sprintf("[%d:a]aformat=channel_layouts=stereo,apad[a%d]", in, in)
		}
		// WhyNot: 音の無い mp4 で [n:a] を引かない — ffmpeg が流れを見つけられずに止まる。無音で埋める。
		return fmt.Sprintf("anullsrc=r=44100:cl=stereo[a%d]", in)
	}
	filter := video + "[v];" + audio(0, infoOld) + ";" + audio(1, infoCur) + ";[a0][a1]amerge=inputs=2,pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c2+0.5*c3[a]"
	args = append(args, "-filter_complex", filter, "-map", "[v]", "-map", "[a]", "-t", fmt.Sprintf("%.3f", total),
		"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", absOut)
	cmd := exec.Command(ffmpeg, args...)
	cmd.Dir = filepath.Dir(absOut)
	if msg, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ffmpeg が失敗した: %v\n%s", err, msg)
	}
	return nil
}

// writeSubtitles は tape.json の台詞ごとに「ノード #番号  秒」の字幕を書く（台詞が出てから次の台詞まで）。
func writeSubtitles(tapePath, srt string) error {
	t, err := LoadTape(filepath.Dir(tapePath))
	if err != nil {
		return err
	}
	var lines []Event
	for _, e := range eventsOf(t) {
		if e.Kind == "line" {
			lines = append(lines, e)
		}
	}
	var b strings.Builder
	for i, e := range lines {
		end := t.Duration
		if i+1 < len(lines) {
			end = lines[i+1].T
		}
		if end <= e.T {
			end = e.T + 2
		}
		fmt.Fprintf(&b, "%d\n%s --> %s\n%s #%d  %.2fs\n\n", i+1, srtTime(e.T), srtTime(end), e.Node, e.Seq, e.T)
	}
	return os.WriteFile(srt, []byte(b.String()), 0o644)
}

func srtTime(sec float64) string {
	ms := int(sec*1000 + 0.5)
	return fmt.Sprintf("%02d:%02d:%02d,%03d", ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
}
