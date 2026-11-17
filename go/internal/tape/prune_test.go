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

// oldBannerPage は前の形（上のバナー）の知らせが入った頁。
const oldBannerPage = `<html><body>` + videoGoneMarker +
	`<div style="position:fixed;top:0;left:0;right:0;z-index:99999;padding:6px 10px;background:#333;color:#fff;font:13px sans-serif;text-align:center">` +
	`この版の動画は古いので消した。 最新の版は <a href="https://x/tapes/new/" style="color:#9cf">こちら</a>。</div><main>頁</main></body></html>`

func TestVideoGoneNoticeReplacesOldBanner(t *testing.T) {
	page, err := AddVideoGoneNotice([]byte(oldBannerPage), "https://x/tapes/newer/")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(page), "古いので消した") || !strings.Contains(string(page), "<main>頁</main>") {
		t.Fatalf("前のバナーが残ったか、頁の中身まで消した: %s", page)
	}
}

func mustNotice(t *testing.T, page, latestURL string) string {
	t.Helper()
	out, err := AddVideoGoneNotice([]byte(page), latestURL)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func TestVideoGoneNoticeIsCenteredModalWithLink(t *testing.T) {
	s := mustNotice(t, `<html><body><main></main></body></html>`, "https://x/tapes/newer/")
	for _, want := range []string{`aria-modal="true"`, "align-items:center", "最新バージョンがあります。", `href="https://x/tapes/newer/"`, "inert", "disabled"} {
		if !strings.Contains(s, want) {
			t.Fatalf("真ん中の知らせに %q が無い: %s", want, s)
		}
	}
}

func TestVideoGoneNoticeIsStableOnRewrite(t *testing.T) {
	once := mustNotice(t, oldBannerPage, "https://x/tapes/newer/")
	if mustNotice(t, once, "https://x/tapes/newer/") != once {
		t.Fatal("同じ最新で書き直すと頁が変わった（publish のたびに差分が出る）")
	}
}

func TestPruneRewritesOldBannerOnAlreadyPrunedPage(t *testing.T) {
	// 動画を前の回に外し終えた古い頁（前の形のバナー）も、次の publish の掃除で真ん中の知らせに替わる。
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, IndexFile), []byte(oldBannerPage), 0o644); err != nil {
		t.Fatal(err)
	}
	p, err := pruneTapeVideos(dir, verA, "", "https://x/tapes/newer/")
	if err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(filepath.Join(dir, IndexFile))
	if err != nil {
		t.Fatal(err)
	}
	if !p.Renoticed || !strings.Contains(string(after), "最新バージョンがあります。") {
		t.Fatalf("古い頁のバナーが替わっていない（Renoticed=%v）: %s", p.Renoticed, after)
	}
}

func TestVideoGoneNoticeReplacesOldBannerWithoutLink(t *testing.T) {
	old := `<html><body>` + videoGoneMarker + `<div style="position:fixed">この版の動画は古いので消した。</div><main>頁</main></body></html>`
	if s := mustNotice(t, old, "https://x/tapes/newer/"); strings.Contains(s, "古いので消した") || !strings.Contains(s, "<main>頁</main>") {
		t.Fatalf("リンク無しの前の形が残ったか、頁の中身まで消した: %s", s)
	}
}

func TestVideoGoneNoticeWithoutLatestDoesNotClaimNewer(t *testing.T) {
	if s := mustNotice(t, `<html><body></body></html>`, ""); strings.Contains(s, "最新バージョン") {
		t.Fatalf("行き先が無いのに最新があると言った: %s", s)
	}
}

func TestLogPrunedShowsRenoticedPages(t *testing.T) {
	var b strings.Builder
	logPruned(&b, []PrunedVideo{{Name: verA, Renoticed: true}}, 0)
	if !strings.Contains(b.String(), "知らせを書き換える: "+verA) || !strings.Contains(b.String(), "動画を外す: 無し") {
		t.Fatalf("dry run の表示に書き換える頁が無い: %s", b.String())
	}
}

func TestParseKeepVideosRejectsZero(t *testing.T) {
	if _, err := parseKeepVideos("0"); err == nil {
		t.Fatal("0 を通した")
	}
}
