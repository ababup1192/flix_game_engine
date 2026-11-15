package migrate

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// VideoHeight は横に並べる時にそろえる高さ（2 本の大きさが違っても並ぶように）。
const VideoHeight = 960

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

// SideBySide は old を左・cur を右に並べた mp4 を out に書く。音は前を左・新しいを右のチャンネルに分ける
// （2 本を混ぜると、どちらの音がずれたか聞き分けられない）。tapePath があれば台詞の字幕を絵に重ねる。
func SideBySide(old, cur, out, tapePath, ffmpeg string) error {
	for _, p := range []string{old, cur} {
		if !fileExists(p) {
			return fmt.Errorf("%s が無い", p)
		}
	}
	absOut, err := filepath.Abs(out)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(absOut), 0o755); err != nil {
		return err
	}
	video := fmt.Sprintf("[0:v]scale=-2:%d,setsar=1[l];[1:v]scale=-2:%d,setsar=1[r];[l][r]hstack=inputs=2", VideoHeight, VideoHeight)
	srt := ""
	if tapePath != "" {
		srt = strings.TrimSuffix(absOut, filepath.Ext(absOut)) + ".srt"
		if err := writeSubtitles(tapePath, srt); err != nil {
			return err
		}
		// WhyNot: subtitles= に絶対パスを渡さない — フィルタの書き方で : と \ を逃がす決まりが OS ごとに違う。出力の隣に置いて名前だけ渡す。
		video += ",subtitles=" + filepath.Base(srt)
	}
	filter := video + "[v];[0:a][1:a]amerge=inputs=2,pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c2+0.5*c3[a]"
	absOld, _ := filepath.Abs(old)
	absCur, _ := filepath.Abs(cur)
	cmd := exec.Command(ffmpeg, "-y", "-loglevel", "error", "-i", absOld, "-i", absCur,
		"-filter_complex", filter, "-map", "[v]", "-map", "[a]",
		"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", absOut)
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
		fmt.Fprintf(&b, "%d\n%s --> %s\n%s #%d  %.2fs\n\n", i+1, srtTime(e.T), srtTime(end), e.Node, e.Seq, e.T)
	}
	return os.WriteFile(srt, []byte(b.String()), 0o644)
}

func srtTime(sec float64) string {
	ms := int(sec*1000 + 0.5)
	return fmt.Sprintf("%02d:%02d:%02d,%03d", ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
}
