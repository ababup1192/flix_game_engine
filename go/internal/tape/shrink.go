package tape

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// VideoLimit は置き場へ置く動画 1 本の上限。超えた動画は publish が縮めてから置く。
// WhyNot: GitHub の上限（1 ファイル 100 MiB）ちょうどにしない — 縮めた後の大きさは揺れるので、届かない幅を空ける。
const VideoLimit int64 = 95 << 20

// PushLimit は 1 回の push の上限（GitHub は 2 GiB を超える push を「remote unpack failed」で断る）。
// SiteWarn は Pages が配るサイトの目安（1 GiB）。置き場は履歴を残さず木を丸ごと push するので、どちらも木の全部で数える。
const (
	PushLimit int64 = 2 << 30
	SiteWarn  int64 = 1 << 30
)

// ShrinkVideoArgs は大きすぎる動画を縮める ffmpeg の旗（入力と出力の間に置く）。
// engine の mk/tape.mk の TAPE_X264・TAPE_AAC と同じ値にそろえる（TestShrinkArgsMatchTapeMk が見張る）。
// WhyNot: -preset veryfast にしない — 同じ大きさなら背景の雨や粒がつぶれて汚い（字はどれも読める）。
var ShrinkVideoArgs = []string{
	"-c:v", "libx264", "-preset", "slow", "-crf", "32", "-tune", "animation", "-pix_fmt", "yuv420p",
	"-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
}

// videoFiles はテープのフォルダに置く動画（縦の分は撮った時だけある）。
var videoFiles = []string{VideoFile, PhoneVideoFile}

type bigVideo struct {
	src, file string
	size      int64
}

func mb(n int64) string { return fmt.Sprintf("%.1f MB", float64(n)/(1<<20)) }

// shortName は src/file を「テープのフォルダ名/ファイル名」で出す（手元のパスを長々と出さない）。
func shortName(path string) string {
	return filepath.Join(filepath.Base(filepath.Dir(path)), filepath.Base(path))
}

func findBigVideos(srcs []string, limit int64) ([]bigVideo, error) {
	var out []bigVideo
	for _, src := range srcs {
		for _, f := range videoFiles {
			info, err := os.Stat(filepath.Join(src, f))
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return nil, err
			}
			if info.Size() > limit {
				out = append(out, bigVideo{src: src, file: f, size: info.Size()})
			}
		}
	}
	return out, nil
}

func reportBigVideos(log io.Writer, big []bigVideo, limit int64, yes bool) {
	for _, b := range big {
		then := "置く時に縮める（--yes の時。dry run では縮めない）"
		if yes {
			then = "縮めてから置く"
		}
		fmt.Fprintf(log, "大きい: %s が %s（%s を超える・GitHub は 1 ファイル 100 MB まで）→ %s\n",
			shortName(filepath.Join(b.src, b.file)), mb(b.size), mb(limit), then)
	}
}

func shrinkVideo(ffmpeg, src, dst string) (int64, error) {
	args := append([]string{"-hide_banner", "-loglevel", "error", "-y", "-i", src}, ShrinkVideoArgs...)
	args = append(args, dst)
	if msg, err := exec.Command(ffmpeg, args...).CombinedOutput(); err != nil {
		return 0, fmt.Errorf("%s を縮められない（ffmpeg %s）: %v\n%s", shortName(src), strings.Join(ShrinkVideoArgs, " "), err, msg)
	}
	info, err := os.Stat(dst)
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

// setVideoBytes は頁の TAPE の中で file を指す videoBytes を n に書き換え、書き換えた数を返す
// （Render は "video":<file> の直後に "videoBytes" を書く）。
// WhyNot: TAPE を JSON で読み直して書き戻さない — 欄の並びが崩れ、同じ入力から同じ頁が出なくなる。
func setVideoBytes(page []byte, file string, n int64) ([]byte, int) {
	re := regexp.MustCompile(`("video":` + regexp.QuoteMeta(strconv.Quote(file)) + `,"videoBytes":)\d+`)
	count := len(re.FindAllIndex(page, -1))
	return re.ReplaceAll(page, []byte("${1}"+strconv.FormatInt(n, 10))), count
}

// videoShrink は publish の本番で上限を超えた動画を縮める指定。
type videoShrink struct {
	ffmpeg string
	limit  int64
	log    io.Writer
}

// copyVideo は src を dst へ写す。上限を超えていれば縮めて書き、shrunk と書いた大きさを返す。
// 縮めても上限を超えれば止める。
func (s videoShrink) copyVideo(src, dst string) (n int64, shrunk bool, err error) {
	info, err := os.Stat(src)
	if err != nil {
		return 0, false, err
	}
	if info.Size() <= s.limit {
		return info.Size(), false, copyTapeFile(src, dst)
	}
	fmt.Fprintf(s.log, "縮めている: %s %s（10 分の動画で数分かかる）\n", shortName(src), mb(info.Size()))
	if n, err = shrinkVideo(s.ffmpeg, src, dst); err != nil {
		return 0, false, err
	}
	if n > s.limit {
		return 0, false, fmt.Errorf("%s を縮めても %s で、置ける上限 %s を超える（元は %s）。動画が長すぎるか画面がよく動く。"+
			"flow を短く分けて撮り直す（分岐は 1 本ずつ別の flow に）", shortName(src), mb(n), mb(s.limit), mb(info.Size()))
	}
	fmt.Fprintf(s.log, "縮めた: %s %s → %s\n", shortName(src), mb(info.Size()), mb(n))
	return n, true, nil
}

// treeBytes は dir の下のファイルの大きさの合計（.git は数えない）。
func treeBytes(dir string) (int64, error) {
	var total int64
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && d.Name() == ".git" {
			return filepath.SkipDir
		}
		if d.Type().IsRegular() {
			info, err := d.Info()
			if err != nil {
				return err
			}
			total += info.Size()
		}
		return nil
	})
	return total, err
}

// checkTreeSize は置く木の全部の大きさを知らせ、push の上限を超えれば本番では止める（dry run は知らせて続ける）。
func checkTreeSize(site string, pushLimit int64, yes bool, log io.Writer) error {
	total, err := treeBytes(site)
	if err != nil {
		return err
	}
	fmt.Fprintf(log, "大きさ: 置く木の全部で %s\n", mb(total))
	if total > pushLimit {
		// WhyNot: 「何回かに分けて置く」を勧めない — 置き場は 30 日以内のテープを木ごと毎回 push するので、2 回目も同じ上限に当たる。
		msg := fmt.Sprintf("置く木の全部が %s で、GitHub の 1 回の push の上限 %s を超える。一度に置く本数を減らすか、flow を短く分けて撮り直すか、"+
			"前に置いた分が 30 日で外れるのを待つ（--keep-videos を 2 以上にしていれば 1 に戻す）", mb(total), mb(pushLimit))
		if yes {
			return fmt.Errorf("%s", msg)
		}
		fmt.Fprintf(log, "注意: %s（dry run なので続ける。--yes では止まる）\n", msg)
		return nil
	}
	if total > SiteWarn {
		fmt.Fprintf(log, "注意: 置く木の全部が %s で、Pages のサイトの目安 %s を超える（配られないことがある）\n", mb(total), mb(SiteWarn))
	}
	return nil
}
