package tape

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// seedWith は目印つきの置き場の bare リポジトリを作り、fill が作業の木に書いた物を 1 コミットで置く。
func seedWith(t *testing.T, fill func(work string)) string {
	t.Helper()
	root := t.TempDir()
	bare := filepath.Join(root, "tapes.git")
	git(t, "", "init", "--quiet", "--bare", "-b", DefaultBranch, bare)
	work := filepath.Join(root, "seed")
	if err := os.MkdirAll(work, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(work, MarkerFile), []byte("tapes"), 0o644); err != nil {
		t.Fatal(err)
	}
	fill(work)
	git(t, work, "init", "--quiet", "-b", DefaultBranch)
	git(t, work, "add", "-A")
	git(t, work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "seed")
	git(t, work, "push", "--quiet", bare, "HEAD:refs/heads/"+DefaultBranch)
	return bare
}

func writeFile(t *testing.T, p, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeIndex(t *testing.T, work string, es ...IndexEntry) {
	t.Helper()
	raw, _ := json.Marshal(indexFile{Entries: es})
	writeFile(t, filepath.Join(work, IndexJSON), string(raw))
}

func indexOf(t *testing.T, bare string) []IndexEntry {
	t.Helper()
	var f indexFile
	if err := json.Unmarshal([]byte(git(t, bare, "show", DefaultBranch+":"+IndexJSON)), &f); err != nil {
		t.Fatal(err)
	}
	return f.Entries
}

func entryNames(es []IndexEntry) []string {
	var out []string
	for _, e := range es {
		out = append(out, e.Name)
	}
	sort.Strings(out)
	return out
}

func findEntry(es []IndexEntry, name string) (IndexEntry, bool) {
	for _, e := range es {
		if e.Name == name {
			return e, true
		}
	}
	return IndexEntry{}, false
}

func publishLog(t *testing.T, bare string, opt PublishOptions) string {
	t.Helper()
	var log bytes.Buffer
	opt.Log = &log
	if _, err := publishWith(t, bare, opt); err != nil {
		t.Fatal(err)
	}
	return log.String()
}

// --- 移し替え ---

func TestPublishMovesOldTapesIntoDocs(t *testing.T) {
	// 根の古い tapes/ のテープは docs/tapes/ へ移る。
	bare := seedBare(t, recent)
	publishTo(t, bare, true)
	if !hasPath(treeOf(t, bare), docsTapes+"/"+recent+"/"+IndexFile) {
		t.Fatalf("docs/tapes/%s が無い: %v", recent, treeOf(t, bare))
	}
}

func TestPublishLeavesNoTapesAtRoot(t *testing.T) {
	// 移した後の根に tapes/ は残らない。
	bare := seedBare(t, recent)
	publishTo(t, bare, true)
	for _, p := range treeOf(t, bare) {
		if strings.HasPrefix(p, TapesDir+"/") {
			t.Fatalf("根に %s が残った", p)
		}
	}
}

func TestPublishMovesNojekyllIntoDocs(t *testing.T) {
	// .nojekyll は docs/ の中に置く。
	bare := seedBare(t)
	publishTo(t, bare, true)
	if !hasPath(treeOf(t, bare), DocsDir+"/"+NojekyllFile) {
		t.Fatalf("docs/.nojekyll が無い: %v", treeOf(t, bare))
	}
}

func TestPublishDropsRootNojekyll(t *testing.T) {
	// 根の古い .nojekyll は残らない。
	bare := seedBare(t)
	publishTo(t, bare, true)
	if hasPath(treeOf(t, bare), NojekyllFile) {
		t.Fatal("根に .nojekyll が残った")
	}
}

func TestPublishExpiresMovedTape(t *testing.T) {
	// 移したテープも 30 日を過ぎていれば外す。
	bare := seedBare(t, oldTape)
	publishTo(t, bare, true)
	if hasPath(treeOf(t, bare), docsTapes+"/"+oldTape+"/"+IndexFile) {
		t.Fatal("移した 30 日過ぎのテープが残った")
	}
}

func TestPublishDryRunSaysMove(t *testing.T) {
	// dry run の言葉に移す物が出る。
	log := publishLog(t, seedBare(t, recent), PublishOptions{})
	if !strings.Contains(log, "移す:   tapes/"+recent+"/ → docs/tapes/"+recent+"/") {
		t.Fatalf("言葉: %s", log)
	}
}

func TestPublishKeepsTapeAlreadyInDocs(t *testing.T) {
	// 既に docs/tapes/ にあるテープはそのまま残る。
	bare := seedWith(t, func(w string) { writeTapeDir(t, filepath.Join(w, DocsDir, TapesDir, recent)) })
	publishTo(t, bare, true)
	if !hasPath(treeOf(t, bare), docsTapes+"/"+recent+"/"+IndexFile) {
		t.Fatal("docs/tapes/ のテープが消えた")
	}
}

func TestPublishURLHasNoDocs(t *testing.T) {
	// 公開の URL は docs/ を含まない（Pages は /docs を根として出す）。
	res := publishTo(t, seedBare(t), false)
	if strings.Contains(res.URLs[0], "/docs/") {
		t.Fatalf("URL: %s", res.URLs[0])
	}
}

// --- tapes.json ---

func TestPublishAddsEntryToIndex(t *testing.T) {
	// 置いたテープの件が tapes.json に入る。
	bare := seedBare(t)
	res := publishTo(t, bare, true)
	if _, ok := findEntry(indexOf(t, bare), res.Name); !ok {
		t.Fatalf("tapes.json に %s が無い", res.Name)
	}
}

func TestPublishIndexEntryCarriesFlow(t *testing.T) {
	// 件のテープには tape.json の flow が入る。
	bare := seedBare(t)
	res := publishTo(t, bare, true)
	e, _ := findEntry(indexOf(t, bare), res.Name)
	if e.Tapes[0].Flow != "e2e/intro.flow" {
		t.Fatalf("flow: %+v", e.Tapes)
	}
}

func TestPublishIndexEntryCarriesTitle(t *testing.T) {
	// 件の題名は tape.json の title。
	bare := seedBare(t)
	res := publishTo(t, bare, true)
	if e, _ := findEntry(indexOf(t, bare), res.Name); e.Title != "題" {
		t.Fatalf("title: %q", e.Title)
	}
}

func TestPublishManyMakesOneEntryWithAllTapes(t *testing.T) {
	// まとめて置いた 2 本は 1 件の中に並ぶ。
	res, _, bare := publishMany(t)
	if e, _ := findEntry(indexOf(t, bare), res.Name); len(e.Tapes) != 2 {
		t.Fatalf("テープ: %+v", e.Tapes)
	}
}

func indexAfterExpiry(t *testing.T) []IndexEntry {
	t.Helper()
	bare := seedWith(t, func(w string) {
		writeTapeDir(t, filepath.Join(w, DocsDir, TapesDir, oldTape))
		writeTapeDir(t, filepath.Join(w, DocsDir, TapesDir, recent))
		writeIndex(t, w,
			IndexEntry{Name: oldTape, Game: "g"},
			IndexEntry{Name: recent, Game: "g"},
			IndexEntry{Name: edgeTape, Game: "g"}) // フォルダが無い
	})
	publishTo(t, bare, true)
	return indexOf(t, bare)
}

func TestPublishDropsExpiredEntryFromIndex(t *testing.T) {
	// 30 日を過ぎて外したテープの件は tapes.json からも外れる。
	if _, ok := findEntry(indexAfterExpiry(t), oldTape); ok {
		t.Fatal("外したテープの件が残った")
	}
}

func TestPublishKeepsRecentEntryInIndex(t *testing.T) {
	// 30 日以内の件は残る。
	if _, ok := findEntry(indexAfterExpiry(t), recent); !ok {
		t.Fatal("30 日以内の件が消えた")
	}
}

func TestPublishDropsEntryWithoutFolder(t *testing.T) {
	// フォルダが置き場に無い件は外れる（消えた頁を指さない）。
	if _, ok := findEntry(indexAfterExpiry(t), edgeTape); ok {
		t.Fatal("フォルダの無い件が残った")
	}
}

// --- README と games/ ---

func TestPublishWritesReadmeAtRoot(t *testing.T) {
	// 根の README.md は作り直される。
	bare := seedBare(t)
	publishTo(t, bare, true)
	if got := git(t, bare, "show", DefaultBranch+":"+ReadmeFile); !strings.Contains(got, "](games/g.md)") {
		t.Fatalf("README: %s", got)
	}
}

func TestPublishWritesGamePageAtRoot(t *testing.T) {
	// games/<game>.md が根に置かれる。
	bare := seedBare(t)
	publishTo(t, bare, true)
	if !hasPath(treeOf(t, bare), GamesDir+"/g.md") {
		t.Fatalf("games/g.md が無い: %v", treeOf(t, bare))
	}
}

func TestPublishPutsNoListingInsideDocs(t *testing.T) {
	// docs/ の中（Pages で配られる所）に一覧を置かない。
	bare := seedBare(t, recent)
	publishTo(t, bare, true)
	for _, p := range treeOf(t, bare) {
		if p == DocsDir+"/"+IndexJSON || p == DocsDir+"/"+ReadmeFile || strings.HasPrefix(p, DocsDir+"/"+GamesDir+"/") {
			t.Fatalf("docs/ の中に一覧がある: %s", p)
		}
	}
}

func TestPublishRemovesGamePageWithNoTapes(t *testing.T) {
	// テープが全部外れたゲームの頁は消える。
	bare := seedWith(t, func(w string) {
		writeTapeDir(t, filepath.Join(w, DocsDir, TapesDir, oldTape))
		writeIndex(t, w, IndexEntry{Name: oldTape, Game: "old"})
		writeFile(t, filepath.Join(w, GamesDir, "old.md"), "old")
	})
	publishTo(t, bare, true)
	if hasPath(treeOf(t, bare), GamesDir+"/old.md") {
		t.Fatal("テープの無いゲームの頁が残った")
	}
}

var sampleEntries = []IndexEntry{
	{At: "2026-11-14T04:33:17+09:00", Name: "20261114-b6c3d29267f0a77a", Game: "game", Title: "序章", Commit: "41641ce", GameRepo: "o/game", Unpushed: true,
		Tapes: []IndexTape{{URL: "https://o.github.io/t/tapes/20261114-b6c3d29267f0a77a/", Flow: "e2e/tape.flow"}}},
	{At: "2026-11-14T09:10:08+09:00", Name: "20261114-62519a115b0566b4", Game: "game", Title: "本編", Commit: "07e499a", GameRepo: "o/game",
		Tapes: []IndexTape{
			{Folder: "light", URL: "https://o.github.io/t/tapes/20261114-62519a115b0566b4/light/", Flow: "e2e/light.flow"},
			{Folder: "dark", URL: "https://o.github.io/t/tapes/20261114-62519a115b0566b4/dark/", Flow: "e2e/dark.flow"}}},
}

func TestBuildReadmeLinksGamePageWithLatestTitle(t *testing.T) {
	// 見出しは最新の件の題名とゲーム名で、子ページへリンクする。
	if got := BuildReadme(sampleEntries); !strings.Contains(got, "## [本編（game）](games/game.md)") {
		t.Fatalf("README: %s", got)
	}
}

func TestBuildReadmeCountsTapesAndLatestDate(t *testing.T) {
	// 見出しの下にテープの数と最新の日付。
	if got := BuildReadme(sampleEntries); !strings.Contains(got, "テープ 3 本（publish 2 回）・最新 2026-11-14 09:10") {
		t.Fatalf("README: %s", got)
	}
}

func TestBuildGamePageNewestFirst(t *testing.T) {
	// 子ページは新しい順。
	got := BuildGamePage(sampleEntries)
	if strings.Index(got, "09:10") > strings.Index(got, "04:33") {
		t.Fatalf("並び: %s", got)
	}
}

func TestBuildGamePageLinksCommitTree(t *testing.T) {
	// 版はその commit の GitHub の tree へリンクする。
	if got := BuildGamePage(sampleEntries); !strings.Contains(got, "[07e499a](https://github.com/o/game/tree/07e499a)") {
		t.Fatalf("頁: %s", got)
	}
}

func TestBuildGamePageMarksUnpushedCommit(t *testing.T) {
	// remote に無い commit には「(push されていない)」を添える。
	if got := BuildGamePage(sampleEntries); !strings.Contains(got, "/tree/41641ce) (push されていない)") {
		t.Fatalf("頁: %s", got)
	}
}

func TestBuildGamePageListsEachFolder(t *testing.T) {
	// 複数のテープはフォルダ名ごとにリンクと flow が並ぶ。
	want := "- [dark](https://o.github.io/t/tapes/20261114-62519a115b0566b4/dark/) — `e2e/dark.flow`"
	if got := BuildGamePage(sampleEntries); !strings.Contains(got, want) {
		t.Fatalf("頁: %s", got)
	}
}

func TestBuildGamePageWithoutRepoHasNoLink(t *testing.T) {
	// ゲームのリポジトリが分からなければ版はリンクにしない。
	e := sampleEntries[1]
	e.GameRepo = ""
	if got := BuildGamePage([]IndexEntry{e}); strings.Contains(got, "github.com/") {
		t.Fatalf("頁: %s", got)
	}
}

// --- ゲームのリポジトリと commit ---

func TestGitHubRepoFromRemote(t *testing.T) {
	cases := map[string]string{
		"https://github.com/Owner/game.git":     "Owner/game",
		"https://github.com/owner/game":         "owner/game",
		"git@github.com:owner/game.git":         "owner/game",
		"ssh://git@github.com/owner/game.git":   "owner/game",
		"https://gitlab.com/owner/game.git":     "",
		"/Users/someone/repos/game":             "",
		"https://github.com/owner/my.game.git/": "owner/my.game",
	}
	for in, want := range cases {
		t.Run(in, func(t *testing.T) {
			// remote の URL の書き方ごとに owner/name を取る（github.com でなければ空）。
			if got := GitHubRepoFromRemote(in); got != want {
				t.Fatalf("%s → %q（want %q）", in, got, want)
			}
		})
	}
}

// gameTape は origin が GitHub のゲームのリポジトリにテープを撮り、pushed なら origin/main に commit を入れる。
func gameTape(t *testing.T, pushed bool) string {
	t.Helper()
	game := t.TempDir()
	git(t, game, "init", "--quiet", "-b", "main")
	git(t, game, "remote", "add", "origin", "https://github.com/owner/game.git")
	writeFile(t, filepath.Join(game, "a.txt"), "a")
	git(t, game, "add", "-A")
	git(t, game, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "game")
	commit := git(t, game, "rev-parse", "--short", "HEAD")
	if pushed {
		git(t, game, "update-ref", "refs/remotes/origin/main", "HEAD")
	}
	src := filepath.Join(game, "debug", "tape", "intro")
	writeTapeDir(t, src)
	page := strings.Replace(string(readFile(t, filepath.Join(src, IndexFile))), "abc1234", commit, 1)
	writeFile(t, filepath.Join(src, IndexFile), page)
	return src
}

func publishGameTape(t *testing.T, pushed bool) (IndexEntry, string) {
	t.Helper()
	src := gameTape(t, pushed)
	var log bytes.Buffer
	res, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: seedBare(t), Now: publishNow, Log: &log})
	if err != nil {
		t.Fatal(err)
	}
	e, _ := findEntry(res.Entries, res.Name)
	return e, log.String()
}

func TestPublishReadsGameRepoFromOrigin(t *testing.T) {
	// ゲームのリポジトリは remote origin から owner/name で取る。
	if e, _ := publishGameTape(t, true); e.GameRepo != "owner/game" {
		t.Fatalf("gameRepo: %q", e.GameRepo)
	}
}

func TestPublishMarksUnpushedCommit(t *testing.T) {
	// remote の枝に無い commit の件は unpushed。
	if e, _ := publishGameTape(t, false); !e.Unpushed {
		t.Fatal("push されていない commit を見落とした")
	}
}

func TestPublishDoesNotMarkPushedCommit(t *testing.T) {
	// remote の枝に入っている commit の件は unpushed でない。
	if e, _ := publishGameTape(t, true); e.Unpushed {
		t.Fatal("push 済みの commit を push されていないとした")
	}
}

func TestPublishDryRunSaysUnpushed(t *testing.T) {
	// dry run の言葉で push されていない commit を 1 行言う。
	if _, log := publishGameTape(t, false); !strings.Contains(log, "remote のどの枝にも無い") {
		t.Fatalf("言葉: %s", log)
	}
}

func TestPublishWithoutOriginLeavesGameRepoEmpty(t *testing.T) {
	// git の外のテープはゲームのリポジトリを空にする。
	bare := seedBare(t)
	res := publishTo(t, bare, false)
	if e, _ := findEntry(res.Entries, res.Name); e.GameRepo != "" {
		t.Fatalf("gameRepo: %q", e.GameRepo)
	}
}

// --- 埋め戻しと --reindex ---

const (
	seedOne  = "20261110-00000000000000c1" // 1 本だけ置いた公開
	seedMany = "20261111-00000000000000c2" // light と dark を並べた公開
	seedGone = "20261112-00000000000000c3" // 置き場に無い公開
)

// seedLogFixture は古い置き方の置き場と、その公開を書いた published.jsonl を作る。
func seedLogFixture(t *testing.T) (bare, logPath string) {
	t.Helper()
	bare = seedWith(t, func(w string) {
		writeTapeDir(t, filepath.Join(w, TapesDir, seedOne))
		writeTapeDir(t, filepath.Join(w, TapesDir, seedMany, "light"))
		writeTapeDir(t, filepath.Join(w, TapesDir, seedMany, "dark"))
	})
	root := filepath.Join(t.TempDir(), "debug", "tape")
	writeTapeDir(t, filepath.Join(root, "light"))
	writeTapeDir(t, filepath.Join(root, "dark"))
	recs := []Published{
		{At: "2026-11-10T10:00:00+09:00", Name: seedOne, URL: PagesURL("owner/tapes", seedOne), Source: filepath.Join(root, "missing"), Game: "g", Commit: "1111111", Repo: "owner/tapes"},
		{At: "2026-11-11T10:00:00+09:00", Name: seedMany, URL: PagesURL("owner/tapes", seedMany) + "light/", Source: filepath.Join(root, "light"), Game: "g", Commit: "2222222", Repo: "owner/tapes"},
		{At: "2026-11-11T10:00:00+09:00", Name: seedMany, URL: PagesURL("owner/tapes", seedMany) + "dark/", Source: filepath.Join(root, "dark"), Game: "g", Commit: "2222222", Repo: "owner/tapes"},
		{At: "2026-11-12T10:00:00+09:00", Name: seedGone, URL: PagesURL("owner/tapes", seedGone), Source: filepath.Join(root, "light"), Game: "g", Repo: "owner/tapes"},
		{At: "2026-11-12T10:00:00+09:00", Name: recent, URL: PagesURL("other/tapes", recent), Game: "g", Repo: "other/tapes"},
	}
	var b strings.Builder
	for _, r := range recs {
		line, _ := json.Marshal(r)
		b.Write(line)
		b.WriteByte('\n')
	}
	logPath = filepath.Join(root, PublishedLog)
	writeFile(t, logPath, b.String())
	return bare, logPath
}

func reindexSeeded(t *testing.T, yes bool) (PublishResult, string) {
	t.Helper()
	bare, logPath := seedLogFixture(t)
	res, err := Publish(PublishOptions{Reindex: true, SeedFrom: []string{logPath}, Repo: "owner/tapes", Remote: bare, Yes: yes, Now: publishNow})
	if err != nil {
		t.Fatal(err)
	}
	return res, bare
}

func TestReindexSeedsPlacedPublications(t *testing.T) {
	// published.jsonl から、置き場にある公開だけを埋める（置き場に無い物・別の置き場の物は飛ばす）。
	res, _ := reindexSeeded(t, false)
	if got := strings.Join(entryNames(res.Entries), " "); got != seedOne+" "+seedMany {
		t.Fatalf("件: %s", got)
	}
}

func TestSeedGroupsTapesByName(t *testing.T) {
	// 同じ乱数のフォルダの行は 1 件にまとまり、フォルダ名が URL から取れる。
	res, _ := reindexSeeded(t, false)
	e, _ := findEntry(res.Entries, seedMany)
	if len(e.Tapes) != 2 || e.Tapes[1].Folder != "dark" {
		t.Fatalf("テープ: %+v", e.Tapes)
	}
}

func TestSeedTakesTitleFromSource(t *testing.T) {
	// 題名は source のフォルダの tape.json から読む。
	res, _ := reindexSeeded(t, false)
	if e, _ := findEntry(res.Entries, seedMany); e.Title != "題" {
		t.Fatalf("title: %q", e.Title)
	}
}

func TestSeedTakesFlowFromSource(t *testing.T) {
	// flow も source のフォルダの tape.json から読む。
	res, _ := reindexSeeded(t, false)
	if e, _ := findEntry(res.Entries, seedMany); e.Tapes[0].Flow != "e2e/light.flow" {
		t.Fatalf("flow: %+v", e.Tapes)
	}
}

func TestSeedFallsBackToGameName(t *testing.T) {
	// source が読めなければ題名は game 名で代える。
	res, _ := reindexSeeded(t, false)
	if e, _ := findEntry(res.Entries, seedOne); e.Title != "g" {
		t.Fatalf("title: %q", e.Title)
	}
}

func TestReindexPlacesNoTape(t *testing.T) {
	// --reindex はテープを置かない（docs/tapes/ は移した 2 件だけ）。
	_, bare := reindexSeeded(t, true)
	dirs := map[string]bool{}
	for _, p := range treeOf(t, bare) {
		if rest, ok := strings.CutPrefix(p, docsTapes+"/"); ok {
			dirs[strings.SplitN(rest, "/", 2)[0]] = true
		}
	}
	if len(dirs) != 2 {
		t.Fatalf("docs/tapes/: %v", dirs)
	}
}

func TestReindexWritesSeededIndex(t *testing.T) {
	// --reindex --yes で埋めた件が置き場の tapes.json に入る。
	_, bare := reindexSeeded(t, true)
	if got := strings.Join(entryNames(indexOf(t, bare)), " "); got != seedOne+" "+seedMany {
		t.Fatalf("tapes.json: %s", got)
	}
}

func TestSeedDoesNotDuplicateKnownEntry(t *testing.T) {
	// tapes.json に既にある件は埋め直さない。
	bare, logPath := seedLogFixture(t)
	opt := PublishOptions{Reindex: true, SeedFrom: []string{logPath}, Repo: "owner/tapes", Remote: bare, Yes: true, Now: publishNow}
	if _, err := Publish(opt); err != nil {
		t.Fatal(err)
	}
	res, err := Publish(opt)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Seeded) != 0 {
		t.Fatalf("2 回目にも埋めた: %v", res.Seeded)
	}
}

func TestPublishReadsPublishedLogNextToDirs(t *testing.T) {
	// 置くテープのフォルダの隣の published.jsonl は --seed-from 無しでも読む。
	bare, logPath := seedLogFixture(t)
	src := filepath.Join(filepath.Dir(logPath), "intro")
	writeTapeDir(t, src)
	res, err := Publish(PublishOptions{Dirs: []string{src}, Repo: "owner/tapes", Remote: bare, Now: publishNow})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := findEntry(res.Entries, seedMany); !ok {
		t.Fatalf("隣の published.jsonl を読まなかった: %v", entryNames(res.Entries))
	}
}

func TestParseReindexRefusesDirs(t *testing.T) {
	// --reindex とテープのフォルダは一緒に使えない。
	if _, _, err := parsePublishArgs([]string{"--reindex", "debug/tape/intro"}); err == nil {
		t.Fatal("--reindex とフォルダを一緒に通した")
	}
}

func TestParseReindexNeedsNoDirs(t *testing.T) {
	// --reindex はフォルダ無しで通る。
	if _, _, err := parsePublishArgs([]string{"--reindex", "--repo", "owner/tapes"}); err != nil {
		t.Fatal(err)
	}
}

func TestParseSeedFromRepeats(t *testing.T) {
	// --seed-from は何度でも付けられる。
	opt, _, _ := parsePublishArgs([]string{"--reindex", "--seed-from", "a.jsonl", "--seed-from", "b.jsonl"})
	if strings.Join(opt.SeedFrom, " ") != "a.jsonl b.jsonl" {
		t.Fatalf("SeedFrom: %v", opt.SeedFrom)
	}
}

// --- Pages の /docs ---

func notDocs(string) error { return pagesNotDocsError{"owner/tapes", "/"} }

func TestPagesNotDocsOnlyWarnsInDryRun(t *testing.T) {
	// Pages が / を出していても dry run は止めずに言うだけ。
	if _, err := publishWith(t, seedBare(t), PublishOptions{CheckPages: notDocs}); err != nil {
		t.Fatal(err)
	}
}

func TestPagesNotDocsStopsPush(t *testing.T) {
	// Pages が / を出したままなら --yes は止める（移した頁が開けなくなる）。
	if _, err := publishWith(t, seedBare(t), PublishOptions{Yes: true, CheckPages: notDocs}); err == nil {
		t.Fatal("Pages が / のまま push した")
	}
}
