package tape

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// writeBigTapeDir は crf 8 で大きく作った試験の動画を置いたテープのフォルダを作り、動画の大きさを返す。
// 頁の TAPE は Render と同じく "video":"video.mp4" の直後に videoBytes を持つ。
func writeBigTapeDir(t *testing.T, dir string) int64 {
	t.Helper()
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg が無い")
	}
	writeTapeDir(t, dir)
	video := filepath.Join(dir, VideoFile)
	out, err := exec.Command(ff, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
		"-i", "testsrc2=size=270x480:rate=30:duration=2", "-c:v", "libx264", "-crf", "8", "-pix_fmt", "yuv420p", video).CombinedOutput()
	if err != nil {
		t.Fatalf("試験の動画を作れない: %v\n%s", err, out)
	}
	info, err := os.Stat(video)
	if err != nil {
		t.Fatal(err)
	}
	page := fmt.Sprintf("<!doctype html>\n<html><head>\n<title>t</title></head><body><script>const TAPE = {\"game\":\"g\",\"commit\":\"abc1234\",\"video\":\"video.mp4\",\"videoBytes\":%d};</script></body></html>", info.Size())
	if err := os.WriteFile(filepath.Join(dir, IndexFile), []byte(page), 0o644); err != nil {
		t.Fatal(err)
	}
	return info.Size()
}

// placedSize は置き場の枝に置いた name/file の大きさ。
func placedSize(t *testing.T, bare, path string) int64 {
	t.Helper()
	n, err := strconv.ParseInt(git(t, bare, "cat-file", "-s", DefaultBranch+":"+docsTapes+"/"+path), 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func publishBig(t *testing.T, src, bare string, limit int64) (PublishResult, error) {
	t.Helper()
	return Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: bare, Now: publishNow, Yes: true, VideoLimit: limit})
}

func TestSetVideoBytesRewritesOnlyThatVideo(t *testing.T) {
	page := []byte(`{"video":"video.mp4","videoBytes":500,"views":{"phone":{"video":"video-phone.mp4","videoBytes":500}}}`)
	got, _ := setVideoBytes(page, PhoneVideoFile, 42)
	want := `{"video":"video.mp4","videoBytes":500,"views":{"phone":{"video":"video-phone.mp4","videoBytes":42}}}`
	if string(got) != want {
		t.Fatalf("got %s", got)
	}
}

func TestSetVideoBytesFindsMainVideoInBuiltPage(t *testing.T) {
	dir := t.TempDir()
	writeViews(t, dir, readFile(t, otherPath), nil)
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	if _, n := setVideoBytes(readFile(t, filepath.Join(dir, IndexFile)), VideoFile, 7); n != 1 {
		t.Fatalf("Build の頁で video.mp4 の videoBytes が %d 箇所（1 のはず）", n)
	}
}

func TestSetVideoBytesFindsPhoneVideoInBuiltPage(t *testing.T) {
	dir := t.TempDir()
	tape := readFile(t, otherPath)
	writeViews(t, dir, tape, phoneTape(t, tape, nil))
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	if _, n := setVideoBytes(readFile(t, filepath.Join(dir, IndexFile)), PhoneVideoFile, 7); n != 1 {
		t.Fatalf("Build の頁で video-phone.mp4 の videoBytes が %d 箇所（1 のはず）", n)
	}
}

func TestShrinkArgsMatchTapeMk(t *testing.T) {
	f, err := os.Open(filepath.Join("..", "..", "..", "mk", "tape.mk"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	vars := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		for _, k := range []string{"TAPE_X264", "TAPE_AAC"} {
			if v, ok := strings.CutPrefix(sc.Text(), k+" ?= "); ok {
				vars[k] = v
			}
		}
	}
	want := append(strings.Fields(vars["TAPE_X264"]+" "+vars["TAPE_AAC"]), "-movflags", "+faststart")
	if !reflect.DeepEqual(ShrinkVideoArgs, want) {
		t.Fatalf("ShrinkVideoArgs %v が mk/tape.mk の TAPE_X264・TAPE_AAC %v とずれている", ShrinkVideoArgs, want)
	}
}

func TestPublishDryRunReportsBigVideo(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	writeTapeDir(t, src)
	var log bytes.Buffer
	if _, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: seedBare(t), Now: publishNow, Log: &log, VideoLimit: 1}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(log.String(), "大きい: intro/video.mp4") {
		t.Fatalf("dry run が大きい動画を言わない:\n%s", log.String())
	}
}

func TestPublishDoesNotReportSmallVideo(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	writeTapeDir(t, src)
	var log bytes.Buffer
	if _, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: seedBare(t), Now: publishNow, Log: &log}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(log.String(), "大きい:") {
		t.Fatalf("上限に届かない動画を大きいと言った:\n%s", log.String())
	}
}

func TestPublishShrinksBigVideoBelowLimit(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	size := writeBigTapeDir(t, src)
	bare := seedBare(t)
	res, err := publishBig(t, src, bare, size-1)
	if err != nil {
		t.Fatal(err)
	}
	if n := placedSize(t, bare, res.Name+"/"+VideoFile); n >= size {
		t.Fatalf("置いた動画が縮んでいない: %d → %d", size, n)
	}
}

func TestPublishShrinkSetsPageVideoBytes(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	size := writeBigTapeDir(t, src)
	bare := seedBare(t)
	res, err := publishBig(t, src, bare, size-1)
	if err != nil {
		t.Fatal(err)
	}
	placed := placedSize(t, bare, res.Name+"/"+VideoFile)
	page := git(t, bare, "show", DefaultBranch+":"+docsTapes+"/"+res.Name+"/"+IndexFile)
	if !strings.Contains(page, fmt.Sprintf(`"videoBytes":%d}`, placed)) {
		t.Fatalf("頁の videoBytes が置いた動画の大きさ %d になっていない:\n%s", placed, page)
	}
}

func TestPublishShrinkLeavesSourceVideoAsIs(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	size := writeBigTapeDir(t, src)
	if _, err := publishBig(t, src, seedBare(t), size-1); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(filepath.Join(src, VideoFile)); err != nil || info.Size() != size {
		t.Fatalf("手元のテープの動画が書き換わった: %v %v", info, err)
	}
}

func TestPublishShrinkLeavesSmallTapeOfGroupAsIs(t *testing.T) {
	root := t.TempDir()
	big, small := filepath.Join(root, "a"), filepath.Join(root, "b")
	size := writeBigTapeDir(t, big)
	writeTapeDir(t, small)
	bare := seedBare(t)
	res, err := Publish(PublishOptions{Dirs: []string{big, small}, Repo: "owner/tapes", Remote: bare, Now: publishNow, Yes: true, VideoLimit: size - 1})
	if err != nil {
		t.Fatal(err)
	}
	if n := placedSize(t, bare, res.Name+"/b/"+VideoFile); n != int64(len("mp4")) {
		t.Fatalf("上限に届かない方の動画が書き換わった: %d バイト", n)
	}
}

func TestPublishShrinkStopsWhenStillTooBig(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	writeBigTapeDir(t, src)
	_, err := publishBig(t, src, seedBare(t), 1000)
	if err == nil || !strings.Contains(err.Error(), "縮めても") {
		t.Fatalf("縮めても上限を超えるのに止まらない: %v", err)
	}
}

func TestPublishShrinkStillTooBigDoesNotPush(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	writeBigTapeDir(t, src)
	bare := seedBare(t)
	before := git(t, bare, "rev-parse", DefaultBranch)
	publishBig(t, src, bare, 1000)
	if after := git(t, bare, "rev-parse", DefaultBranch); after != before {
		t.Fatal("止まったのに置き場の枝が動いた")
	}
}

func TestPublishStopsWhenTreeOverPushLimit(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	writeTapeDir(t, src)
	_, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: seedBare(t), Now: publishNow, Yes: true, PushLimit: 10})
	if err == nil || !strings.Contains(err.Error(), "push の上限") {
		t.Fatalf("木の全部が push の上限を超えるのに止まらない: %v", err)
	}
}

func TestPublishOverPushLimitDoesNotPush(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	writeTapeDir(t, src)
	bare := seedBare(t)
	before := git(t, bare, "rev-parse", DefaultBranch)
	Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: bare, Now: publishNow, Yes: true, PushLimit: 10})
	if after := git(t, bare, "rev-parse", DefaultBranch); after != before {
		t.Fatal("push の上限で止まったのに置き場の枝が動いた")
	}
}

func TestPublishDryRunReportsTreeOverPushLimit(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	writeTapeDir(t, src)
	var log bytes.Buffer
	if _, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: seedBare(t), Now: publishNow, Log: &log, PushLimit: 10}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(log.String(), "push の上限") {
		t.Fatalf("dry run が push の上限を言わない:\n%s", log.String())
	}
}
