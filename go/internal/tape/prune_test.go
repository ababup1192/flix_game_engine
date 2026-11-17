package tape

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// publishAt は flowName の flow を name で置く（同じ置き場へ何度も置いて版を重ねる）。
func publishAt(t *testing.T, bare, flowName, name string, at time.Time, opt PublishOptions) PublishResult {
	t.Helper()
	src := filepath.Join(t.TempDir(), "debug", "tape", flowName)
	writeTapeDir(t, src)
	if err := os.WriteFile(filepath.Join(src, PhoneVideoFile), []byte("phone"), 0o644); err != nil {
		t.Fatal(err)
	}
	opt.Dirs, opt.Repo, opt.Remote, opt.Now, opt.Name, opt.Yes = []string{src}, "owner/tapes", bare, at, name, true
	res, err := Publish(opt)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

const (
	verA = "20261110-aaaaaaaaaaaaaaaa"
	verB = "20261111-bbbbbbbbbbbbbbbb"
	verC = "20261112-cccccccccccccccc"
)

func day(d int) time.Time { return time.Date(2026, 11, d, 12, 0, 0, 0, time.Local) }

func threeVersions(t *testing.T, opt PublishOptions) (string, []string) {
	bare := seedBare(t)
	publishAt(t, bare, "intro", verA, day(10), opt)
	publishAt(t, bare, "intro", verB, day(11), opt)
	publishAt(t, bare, "intro", verC, day(12), opt)
	return bare, treeOf(t, bare)
}

func TestPublishKeepsOnlyLatestVideoByDefault(t *testing.T) {
	_, tree := threeVersions(t, PublishOptions{})
	if hasPath(tree, docsTapes+"/"+verA+"/"+VideoFile) || hasPath(tree, docsTapes+"/"+verB+"/"+VideoFile) {
		t.Fatalf("古い版の動画が残った: %v", tree)
	}
	if !hasPath(tree, docsTapes+"/"+verC+"/"+VideoFile) || !hasPath(tree, docsTapes+"/"+verC+"/"+PhoneVideoFile) {
		t.Fatalf("最新の版の動画が無い: %v", tree)
	}
}

func TestPublishPruneDropsPhoneVideoToo(t *testing.T) {
	_, tree := threeVersions(t, PublishOptions{})
	if hasPath(tree, docsTapes+"/"+verA+"/"+PhoneVideoFile) {
		t.Fatalf("古い版の縦の動画が残った: %v", tree)
	}
}

func TestPublishPruneKeepsPageAndStrip(t *testing.T) {
	_, tree := threeVersions(t, PublishOptions{})
	for _, f := range []string{IndexFile, StripFile} {
		if !hasPath(tree, docsTapes+"/"+verA+"/"+f) {
			t.Fatalf("古い版の %s が消えた: %v", f, tree)
		}
	}
}

func TestPublishPruneNoticePointsToLatest(t *testing.T) {
	bare, _ := threeVersions(t, PublishOptions{})
	page := git(t, bare, "show", DefaultBranch+":"+docsTapes+"/"+verA+"/"+IndexFile)
	if !strings.Contains(page, videoGoneMarker) || !strings.Contains(page, verC) {
		t.Fatalf("知らせか最新へのリンクが無い: %s", page)
	}
}

func TestPublishKeepVideosTwoKeepsNewestTwo(t *testing.T) {
	_, tree := threeVersions(t, PublishOptions{KeepVideos: 2})
	if hasPath(tree, docsTapes+"/"+verA+"/"+VideoFile) || !hasPath(tree, docsTapes+"/"+verB+"/"+VideoFile) {
		t.Fatalf("2 版だけ残るはず: %v", tree)
	}
}

func TestPublishKeepAllVideosKeepsEverything(t *testing.T) {
	_, tree := threeVersions(t, PublishOptions{KeepVideos: KeepAllVideos})
	if !hasPath(tree, docsTapes+"/"+verA+"/"+VideoFile) {
		t.Fatalf("all なのに消えた: %v", tree)
	}
}

func TestPublishPruneLeavesOtherFlowAlone(t *testing.T) {
	bare := seedBare(t)
	publishAt(t, bare, "intro", verA, day(10), PublishOptions{})
	publishAt(t, bare, "ending", verB, day(11), PublishOptions{})
	if !hasPath(treeOf(t, bare), docsTapes+"/"+verA+"/"+VideoFile) {
		t.Fatal("別の flow の動画を消した")
	}
}

func TestPublishPruneIsIdempotent(t *testing.T) {
	bare, _ := threeVersions(t, PublishOptions{})
	publishAt(t, bare, "intro", "20261113-dddddddddddddddd", day(13), PublishOptions{})
	after := git(t, bare, "show", DefaultBranch+":"+docsTapes+"/"+verA+"/"+IndexFile)
	if strings.Count(after, videoGoneMarker) != 1 {
		t.Fatalf("知らせが重なった: %s", after)
	}
}

func TestPublishDryRunDoesNotPrune(t *testing.T) {
	bare := seedBare(t)
	publishAt(t, bare, "intro", verA, day(10), PublishOptions{})
	src := filepath.Join(t.TempDir(), "debug", "tape", "intro")
	writeTapeDir(t, src)
	res, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: bare, Now: day(11), Name: verB})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Pruned) != 1 || !hasPath(treeOf(t, bare), docsTapes+"/"+verA+"/"+VideoFile) {
		t.Fatalf("dry run は外す物を出すだけ: %+v", res.Pruned)
	}
}

func TestParseKeepVideosRejectsZero(t *testing.T) {
	if _, err := parseKeepVideos("0"); err == nil {
		t.Fatal("0 を通した")
	}
}
