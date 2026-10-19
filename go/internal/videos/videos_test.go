package videos

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, root, rel, text string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func byName(vs []Video) map[string]Video {
	m := map[string]Video{}
	for _, v := range vs {
		m[v.Name] = v
	}
	return m
}

func TestRunningWithDeadPidIsStuck(t *testing.T) {
	root := t.TempDir()
	write(t, root, "debug/video/talk.video.json", `{"state":"running","make":"talk-video","pid":42}`)
	got := byName(List(root, func(int) bool { return false }))["talk"]
	if got.State != "stuck" || !got.IsBroken() {
		t.Fatalf("state = %q", got.State)
	}
}

func TestRunningWithLivePidIsRunning(t *testing.T) {
	root := t.TempDir()
	write(t, root, "debug/video/talk.video.json", `{"state":"running","make":"talk-video","pid":42}`)
	got := byName(List(root, func(int) bool { return true }))["talk"]
	if got.State != "running" || got.IsBroken() {
		t.Fatalf("state = %q", got.State)
	}
}

func TestMp4WithoutRecordIsNotBroken(t *testing.T) {
	root := t.TempDir()
	write(t, root, "debug/video/old.mp4", "x")
	got := byName(List(root, func(int) bool { return false }))["old"]
	if got.State != "norecord" || got.IsBroken() || got.Mp4 != "debug/video/old.mp4" {
		t.Fatalf("got %+v", got)
	}
}

func TestSuffixedNameFindsFramesFolderAndLastFrame(t *testing.T) {
	root := t.TempDir()
	write(t, root, "debug/video/transition/f0001.png", "a")
	write(t, root, "debug/video/transition/f0002.png", "b")
	write(t, root, "debug/video/transition/sfx.txt", "1 hit\n")
	write(t, root, "debug/video/transition_sfx.video.json", `{"state":"failed","stage":"frames","pid":1}`)
	got := byName(List(root, func(int) bool { return false }))["transition_sfx"]
	if got.LastFrame != "debug/video/transition/f0002.png" || got.Sfx != "debug/video/transition/sfx.txt" {
		t.Fatalf("got %+v", got)
	}
}

func TestFlowHeadCommentBecomesTitleAndDesc(t *testing.T) {
	root := t.TempDir()
	write(t, root, "e2e/clock.flow", "# 時計の分岐\n# 選んで結末まで\nstart talk\n")
	write(t, root, "debug/video/clock.video.json", `{"state":"ok","flow":"e2e/clock.flow","frames":3,"fps":30}`)
	got := byName(List(root, func(int) bool { return false }))["clock"]
	if got.Title != "時計の分岐" || got.Desc != "選んで結末まで" {
		t.Fatalf("got %q / %q", got.Title, got.Desc)
	}
}

func TestCompareReportMarksDiff(t *testing.T) {
	root := t.TempDir()
	write(t, root, "debug/video/entry.mp4", "x")
	write(t, root, "debug/compare/report.tsv", "kind\tname\tstate\tdetail\tpair\tvideo\nvideo\tentry.mp4\tdiff\t3 / 90 コマ\t\t\n")
	got := byName(List(root, func(int) bool { return false }))["entry"]
	if got.Compare != "diff" {
		t.Fatalf("got %+v", got)
	}
}

func TestDiffSfxNamesWhatChanged(t *testing.T) {
	base := []Sound{{10, "hit"}, {30, "swish"}}
	cur := []Sound{{10, "hit"}, {10, "hit"}, {31, "swish"}}
	if got := DiffSfx(base, cur); got != "音 -swish@30 +hit@10 +swish@31" {
		t.Fatalf("got %q", got)
	}
}

func TestDiffSfxSameIsEmpty(t *testing.T) {
	s := []Sound{{1, "a"}}
	if got := DiffSfx(s, s); got != "" {
		t.Fatalf("got %q", got)
	}
}
