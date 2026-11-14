package tape

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var publishNow = time.Date(2026, 11, 13, 15, 0, 0, 0, time.Local)

// docsTapes は置き場の中でテープを置くフォルダ。
const docsTapes = DocsDir + "/" + TapesDir

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := gitOut(dir, args...)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func writeTapeDir(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		IndexFile: "<!doctype html>\n<html><head>\n<title>t</title></head><body><script>const TAPE={\"game\":\"g\",\"commit\":\"abc1234\"};</script></body></html>",
		VideoFile: "mp4",
		StripFile: "jpg",
		TapeFile:  `{"game":"g","title":"題","flow":"e2e/` + filepath.Base(dir) + `.flow"}`,
	}
	for n, c := range files {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// seedBare は置き場に見立てた bare リポジトリを作り、目印（.fge-tapes）と names のテープと README を 1 コミットで置く。
func seedBare(t *testing.T, names ...string) string {
	t.Helper()
	return seedRepo(t, true, "seed", names...)
}

// seedRepo は bare リポジトリに 1 コミットを置く。marker なら .fge-tapes も置く。msg = コミットの文。
func seedRepo(t *testing.T, marker bool, msg string, names ...string) string {
	t.Helper()
	root := t.TempDir()
	bare := filepath.Join(root, "tapes.git")
	git(t, "", "init", "--quiet", "--bare", "-b", DefaultBranch, bare)
	work := filepath.Join(root, "seed")
	if err := os.MkdirAll(work, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, n := range names {
		writeTapeDir(t, filepath.Join(work, TapesDir, n))
	}
	if err := os.WriteFile(filepath.Join(work, "README.md"), []byte("tapes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(work, ".nojekyll"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if marker {
		if err := os.WriteFile(filepath.Join(work, MarkerFile), []byte("tapes"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	git(t, work, "init", "--quiet", "-b", DefaultBranch)
	git(t, work, "add", "-A")
	git(t, work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", msg)
	git(t, work, "push", "--quiet", bare, "HEAD:refs/heads/"+DefaultBranch)
	return bare
}

func publishTo(t *testing.T, bare string, yes bool) PublishResult {
	t.Helper()
	src := filepath.Join(t.TempDir(), "debug", "tape", "intro")
	writeTapeDir(t, src)
	res, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: bare, Yes: yes, Now: publishNow})
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func treeOf(t *testing.T, bare string) []string {
	t.Helper()
	return strings.Split(git(t, bare, "ls-tree", "-r", "--name-only", DefaultBranch), "\n")
}

func hasPath(paths []string, p string) bool {
	for _, x := range paths {
		if x == p {
			return true
		}
	}
	return false
}

const (
	oldTape   = "20261001-0123456789abcdef" // 43 日前
	recent    = "20261020-fedcba9876543210" // 24 日前
	edgeTape  = "20261014-00000000000000aa" // ちょうど 30 日前
	pastLimit = "20261013-00000000000000bb" // 31 日前
)

func TestPublishPutsNewTapeUnderTapesDir(t *testing.T) {
	bare := seedBare(t)
	res := publishTo(t, bare, true)
	if !hasPath(treeOf(t, bare), docsTapes+"/"+res.Name+"/"+VideoFile) {
		t.Fatalf("tapes/%s/video.mp4 が置き場に無い: %v", res.Name, treeOf(t, bare))
	}
}

func TestPublishNewNameHasDateAndHex(t *testing.T) {
	res := publishTo(t, seedBare(t), true)
	if !strings.HasPrefix(res.Name, "20261113-") {
		t.Fatalf("名前が今日の日付で始まらない: %s", res.Name)
	}
}

func TestPublishRemovesExpiredTape(t *testing.T) {
	bare := seedBare(t, oldTape, recent)
	publishTo(t, bare, true)
	if hasPath(treeOf(t, bare), docsTapes+"/"+oldTape+"/"+IndexFile) {
		t.Fatal("30 日を過ぎたテープが残った")
	}
}

func TestPublishKeepsRecentTape(t *testing.T) {
	bare := seedBare(t, oldTape, recent)
	publishTo(t, bare, true)
	if !hasPath(treeOf(t, bare), docsTapes+"/"+recent+"/"+IndexFile) {
		t.Fatal("30 日以内のテープが消えた")
	}
}

func TestPublishKeepsFilesOutsideTapes(t *testing.T) {
	bare := seedBare(t)
	publishTo(t, bare, true)
	if !hasPath(treeOf(t, bare), "README.md") {
		t.Fatal("tapes/ の外の物が消えた")
	}
}

func TestPublishLeavesSingleRootCommit(t *testing.T) {
	bare := seedBare(t, recent)
	publishTo(t, bare, true)
	if got := git(t, bare, "rev-list", "--count", DefaultBranch); got != "1" {
		t.Fatalf("置き場の枝のコミットが %s 個（1 個で親が無いはず）", got)
	}
}

func TestPublishCreatesBranchOnEmptyRepo(t *testing.T) {
	bare := filepath.Join(t.TempDir(), "empty.git")
	git(t, "", "init", "--quiet", "--bare", "-b", DefaultBranch, bare)
	res := publishTo(t, bare, true)
	if !hasPath(treeOf(t, bare), docsTapes+"/"+res.Name+"/"+IndexFile) {
		t.Fatal("空の置き場に枝を作れなかった")
	}
}

func TestPublishAddsNoindex(t *testing.T) {
	bare := seedBare(t)
	res := publishTo(t, bare, true)
	page := git(t, bare, "show", DefaultBranch+":"+docsTapes+"/"+res.Name+"/"+IndexFile)
	if !strings.Contains(page, `<meta name="robots" content="noindex">`) {
		t.Fatal("置いた index.html に noindex が無い")
	}
}

func TestPublishDryRunDoesNotPush(t *testing.T) {
	bare := seedBare(t, oldTape)
	before := git(t, bare, "rev-parse", DefaultBranch)
	publishTo(t, bare, false)
	if after := git(t, bare, "rev-parse", DefaultBranch); after != before {
		t.Fatal("dry run なのに置き場の枝が動いた")
	}
}

func TestPublishDryRunReportsRemoval(t *testing.T) {
	res := publishTo(t, seedBare(t, oldTape, recent), false)
	if len(res.Removed) != 1 || res.Removed[0] != oldTape {
		t.Fatalf("外す物の一覧が違う: %v", res.Removed)
	}
}

func TestPublishDoesNotTouchGameRepo(t *testing.T) {
	bare := seedBare(t)
	game := t.TempDir()
	git(t, game, "init", "--quiet", "-b", "main")
	src := filepath.Join(game, "debug", "tape", "intro")
	writeTapeDir(t, src)
	git(t, game, "add", "-A")
	git(t, game, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "game")
	before := git(t, game, "for-each-ref") + git(t, game, "status", "--porcelain")
	if _, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: bare, Yes: true, Now: publishNow}); err != nil {
		t.Fatal(err)
	}
	if after := git(t, game, "for-each-ref") + git(t, game, "status", "--porcelain"); after != before {
		t.Fatalf("ゲームのリポジトリが変わった:\n前 %s\n後 %s", before, after)
	}
}

func TestPublishRefusesGameRepoAsTarget(t *testing.T) {
	game := t.TempDir()
	git(t, game, "init", "--quiet", "-b", "main")
	git(t, game, "remote", "add", "origin", "git@github.com:owner/game.git")
	src := filepath.Join(game, "debug", "tape", "intro")
	writeTapeDir(t, src)
	_, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/game", Remote: seedBare(t), Now: publishNow})
	if err == nil {
		t.Fatal("ゲームのリポジトリを置き場にしても止まらなかった")
	}
}

func TestPublishStopsWhenPagesDisabled(t *testing.T) {
	src := filepath.Join(t.TempDir(), "intro")
	writeTapeDir(t, src)
	_, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: seedBare(t), Now: publishNow,
		CheckPages: func(string) error { return os.ErrNotExist }})
	if err == nil {
		t.Fatal("Pages が無効でも止まらなかった")
	}
}

func TestNewNameMatchesShape(t *testing.T) {
	n, err := NewName(publishNow)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := ParseName(n); !ok {
		t.Fatalf("作った名前が形に合わない: %s", n)
	}
}

func TestNewNameIsRandom(t *testing.T) {
	a, _ := NewName(publishNow)
	b, _ := NewName(publishNow)
	if a == b {
		t.Fatal("2 回作った名前が同じ")
	}
}

func TestParseNameRejectsBadShapes(t *testing.T) {
	for _, n := range []string{
		"20261113-0123456789abcde",   // 15 桁
		"20261113-0123456789abcdef0", // 17 桁
		"20261113-0123456789ABCDEF",  // 大文字
		"2026111-0123456789abcdef",   // 日付が 7 桁
		"20261340-0123456789abcdef",  // 無い日付
		"index.html",
	} {
		if _, ok := ParseName(n); ok {
			t.Errorf("形の違う名前を通した: %s", n)
		}
	}
}

func TestIsExpiredKeepsExactly30Days(t *testing.T) {
	if IsExpired(edgeTape, publishNow) {
		t.Fatal("ちょうど 30 日前のテープを外した")
	}
}

func TestIsExpiredDrops31Days(t *testing.T) {
	if !IsExpired(pastLimit, publishNow) {
		t.Fatal("31 日前のテープを残した")
	}
}

func TestPagesURLShape(t *testing.T) {
	got := PagesURL("Owner/tapes", "20261113-0123456789abcdef")
	if got != "https://owner.github.io/tapes/tapes/20261113-0123456789abcdef/" {
		t.Fatalf("URL が違う: %s", got)
	}
}

func TestAddNoindexKeepsExistingRobots(t *testing.T) {
	page := []byte(`<head><meta name="robots" content="none"></head>`)
	got, err := AddNoindex(page)
	if err != nil || !bytes.Equal(got, page) {
		t.Fatalf("既にある robots を書き換えた: %s", got)
	}
}

func TestPublishHelpSaysDryRunIsDefault(t *testing.T) {
	var out, errOut bytes.Buffer
	code := Run([]string{"publish", "--help"}, &out, &errOut)
	if code != 0 || !strings.Contains(out.String(), "既定は dry run") {
		t.Fatalf("publish --help が分かる言葉で出ない（code %d）: %s", code, out.String())
	}
}

func TestPublishLogLineWritten(t *testing.T) {
	bare := seedBare(t)
	src := filepath.Join(t.TempDir(), "debug", "tape", "intro")
	writeTapeDir(t, src)
	opt := PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: bare, Yes: true, Now: publishNow}
	res, err := Publish(opt)
	if err != nil {
		t.Fatal(err)
	}
	if err := appendPublished(opt, res); err != nil {
		t.Fatal(err)
	}
	line := readFile(t, filepath.Join(filepath.Dir(src), PublishedLog))
	if !bytes.Contains(line, []byte(`"commit":"abc1234"`)) {
		t.Fatalf("published.jsonl に commit が無い: %s", line)
	}
}

func TestRunPublishWithoutYesSaysNothingPushed(t *testing.T) {
	bare := seedBare(t, oldTape, recent)
	src := filepath.Join(t.TempDir(), "debug", "tape", "intro")
	writeTapeDir(t, src)
	var out, errOut bytes.Buffer
	code := Run([]string{"publish", src, "--repo", "owner/tapes", "--remote", bare}, &out, &errOut)
	t.Log(out.String())
	if code != 0 || !strings.Contains(out.String(), "push していない") {
		t.Fatalf("dry run の知らせが出ない（code %d）: %s%s", code, out.String(), errOut.String())
	}
}

func publishWith(t *testing.T, bare string, opt PublishOptions) (PublishResult, error) {
	t.Helper()
	src := filepath.Join(t.TempDir(), "debug", "tape", "intro")
	writeTapeDir(t, src)
	opt.Dirs, opt.Repo, opt.Remote, opt.Now = []string{src}, "owner/tapes", bare, publishNow
	return Publish(opt)
}

func TestPublishRefusesBranchWithoutMarker(t *testing.T) {
	bare := seedRepo(t, false, "置き場を作る")
	if _, err := publishWith(t, bare, PublishOptions{Yes: true}); err == nil {
		t.Fatal("目印の無い枝に push した")
	}
	if got := git(t, bare, "log", "-1", "--format=%s", DefaultBranch); got != "置き場を作る" {
		t.Fatalf("止まったはずの枝が書き換わった: %s", got)
	}
}

func TestPublishInitAcceptsBranchWithoutMarker(t *testing.T) {
	bare := seedRepo(t, false, "置き場を作る")
	if _, err := publishWith(t, bare, PublishOptions{Yes: true, Init: true}); err != nil {
		t.Fatal(err)
	}
	if !hasPath(treeOf(t, bare), MarkerFile) {
		t.Fatalf("--init で置いた後に %s が無い: %v", MarkerFile, treeOf(t, bare))
	}
}

func TestPublishCommitStartsWithTapePrefix(t *testing.T) {
	bare := seedBare(t)
	publishTo(t, bare, true)
	if got := git(t, bare, "log", "-1", "--format=%s", DefaultBranch); !strings.HasPrefix(got, CommitPrefix) {
		t.Fatalf("publish のコミットの文が %q で始まらない: %s", CommitPrefix, got)
	}
}

func TestPublishAcceptsTapeCommitWithoutMarkerFile(t *testing.T) {
	bare := seedRepo(t, false, "tape: 前に置いた")
	if _, err := publishWith(t, bare, PublishOptions{Yes: true}); err != nil {
		t.Fatalf("文が tape: で始まる枝を止めた: %v", err)
	}
}

func TestPublishDryRunListsFilesOutsideDocs(t *testing.T) {
	// 根で残すのは目印だけ（README.md は作り直し、.nojekyll は docs/ へ移る）。
	res := publishTo(t, seedBare(t), false)
	if strings.Join(res.Outside, " ") != MarkerFile {
		t.Fatalf("根で残す物: %v", res.Outside)
	}
}

func TestHasRefMatchesWholeName(t *testing.T) {
	out := "0123\trefs/heads/x/main\n4567\trefs/heads/main-old"
	if hasRef(out, "refs/heads/main") {
		t.Fatal("refs/heads/x/main と refs/heads/main-old を refs/heads/main と取り違えた")
	}
	if !hasRef(out+"\n89ab\trefs/heads/main", "refs/heads/main") {
		t.Fatal("refs/heads/main を見落とした")
	}
}

// publishMany は light と dark の 2 つのフォルダを 1 回の publish で置く。
func publishMany(t *testing.T) (PublishResult, PublishOptions, string) {
	t.Helper()
	bare := seedBare(t)
	root := filepath.Join(t.TempDir(), "debug", "tape")
	a, b := filepath.Join(root, "light"), filepath.Join(root, "dark")
	writeTapeDir(t, a)
	writeTapeDir(t, b)
	opt := PublishOptions{Dirs: []string{a, b}, Repo: "owner/tapes", Remote: bare, Yes: true, Now: publishNow}
	res, err := Publish(opt)
	if err != nil {
		t.Fatal(err)
	}
	return res, opt, bare
}

func TestPublishManyPutsTheFirstUnderOneName(t *testing.T) {
	// 2 つ以上のフォルダは 1 つの乱数のフォルダの下にフォルダ名で並ぶ（1 つ目）。
	res, _, bare := publishMany(t)
	if !hasPath(treeOf(t, bare), docsTapes+"/"+res.Name+"/light/"+VideoFile) {
		t.Fatalf("tapes/%s/light/video.mp4 が置き場に無い", res.Name)
	}
}

func TestPublishManyPutsTheSecondUnderTheSameName(t *testing.T) {
	// 2 つ目も同じ乱数のフォルダの下に並ぶ。
	res, _, bare := publishMany(t)
	if !hasPath(treeOf(t, bare), docsTapes+"/"+res.Name+"/dark/"+VideoFile) {
		t.Fatalf("tapes/%s/dark/video.mp4 が置き場に無い", res.Name)
	}
}

func TestPublishManyGivesOneURLPerTape(t *testing.T) {
	// URL はフォルダごとに 1 つ、渡した並びで出る。
	res, _, _ := publishMany(t)
	want := PagesURL("owner/tapes", res.Name) + "light/ " + PagesURL("owner/tapes", res.Name) + "dark/"
	if got := strings.Join(res.URLs, " "); got != want {
		t.Fatalf("URL: %s（want %s）", got, want)
	}
}

func TestPublishManyStopsOnSameFolderName(t *testing.T) {
	// フォルダ名が同じ 2 つは並べて置けないので止める。
	a, b := filepath.Join(t.TempDir(), "intro"), filepath.Join(t.TempDir(), "intro")
	writeTapeDir(t, a)
	writeTapeDir(t, b)
	if _, err := Publish(PublishOptions{Dirs: []string{a, b}, Repo: "owner/tapes", Remote: seedBare(t), Now: publishNow}); err == nil {
		t.Fatal("同じフォルダ名を 2 つ並べて置こうとした")
	}
}

// publishedLines は publish を 2 本で流して published.jsonl に書いた行。
func publishedLines(t *testing.T) []string {
	t.Helper()
	res, opt, _ := publishMany(t)
	if err := appendPublished(opt, res); err != nil {
		t.Fatal(err)
	}
	raw := readFile(t, filepath.Join(filepath.Dir(opt.Dirs[0]), PublishedLog))
	return strings.Split(strings.TrimSpace(string(raw)), "\n")
}

func TestPublishedLogGetsOneLinePerTape(t *testing.T) {
	// published.jsonl にはテープごとに 1 行。
	if lines := publishedLines(t); len(lines) != 2 {
		t.Fatalf("published.jsonl: %v", lines)
	}
}

func TestPublishedLogLineCarriesThatTapesURL(t *testing.T) {
	// 2 行目は 2 つ目のテープの URL。
	if lines := publishedLines(t); !strings.Contains(lines[len(lines)-1], `/dark/"`) {
		t.Fatalf("published.jsonl: %v", lines)
	}
}

// publishLogWithRoute は、../dark/ への分岐の道を持つ light を、others と一緒に dry run で置いた時の言葉。
func publishLogWithRoute(t *testing.T, others ...string) string {
	t.Helper()
	root := t.TempDir()
	a := filepath.Join(root, "light")
	writeTapeDir(t, a)
	tp := parsed(t, forkTape(t, 0))
	branches := []Branch{{T: 3.2, Line: 10, Question: "q", Routes: []Route{{Label: "灯をともす", Note: "このテープ", Here: true},
		{Label: "眠る", Note: "dark のテープ", Href: "../dark/index.html#t=3.2"}}}}
	b, _ := json.Marshal(branches)
	tp.raw["branches"] = b
	page, err := Render(tp, "abc1234", sampleStrip)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(a, IndexFile), page, 0o644); err != nil {
		t.Fatal(err)
	}
	dirs := []string{a}
	for _, o := range others {
		d := filepath.Join(root, o)
		writeTapeDir(t, d)
		dirs = append(dirs, d)
	}
	var log bytes.Buffer
	if _, err := Publish(PublishOptions{Dirs: dirs, Repo: "owner/tapes", Remote: seedBare(t), Now: publishNow, Log: &log}); err != nil {
		t.Fatal(err)
	}
	return log.String()
}

func TestPublishWarnsWhenRouteTargetIsNotPlaced(t *testing.T) {
	// 分岐の道の先のフォルダを一緒に置かなければ 1 行言う。
	if log := publishLogWithRoute(t); !strings.Contains(log, "注意: light の分岐の道の先 dark") {
		t.Fatalf("言葉: %s", log)
	}
}

func TestPublishDoesNotWarnWhenRouteTargetIsPlaced(t *testing.T) {
	// 道の先のフォルダを一緒に置くなら言わない。
	if log := publishLogWithRoute(t, "dark"); strings.Contains(log, "注意:") {
		t.Fatalf("言葉: %s", log)
	}
}
