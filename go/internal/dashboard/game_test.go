package dashboard

// 何を守るか: ゲームの頁（子）が base の下だけで答え、Host と Origin を自分の番号で見ること・返事を reply.json に書くこと・
// テープを全部の worktree から読むこと。全体の fge が子へ中継する時に Host と Origin を書き換えること、
// ダッシュボードより前の版のゲームには理由を出すこと。worktree の AI が post → 人が中継の頁で返す → AI が inbox で拾う、が通ること。

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/posts"
)

var fixedNow = time.Date(2026, 11, 24, 10, 15, 0, 0, time.Local)

func gitRun(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com"}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// gameRepo は main の作業ツリー（ゲーム tide）と、枝 feat の worktree を作る。
func gameRepo(t *testing.T, root string) (string, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git がありません")
	}
	main := filepath.Join(root, "ws", "tide")
	write(t, filepath.Join(main, "flix.toml"), "[package]\nname = \"tide\"\n")
	gitRun(t, main, "init", "-q", "-b", "main")
	gitRun(t, main, "add", ".")
	gitRun(t, main, "commit", "-q", "-m", "init")
	wt := filepath.Join(root, "wt-feat")
	gitRun(t, main, "worktree", "add", "-q", "-b", "feat", wt)
	return posts.RealPath(main), posts.RealPath(wt)
}

func gameServer(dir, base string) *GameServer {
	return NewGameServer(testPort, base, strings.Trim(base, "/"), posts.Resolve(dir), func() time.Time { return fixedNow })
}

func postBody(srv http.Handler, target, origin, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", "http://127.0.0.1:"+strconv.Itoa(testPort)+target, strings.NewReader(body))
	req.Header.Set("Origin", origin)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)
	return rec
}

// putPost は dir の作業ツリーから post を 1 つ置き、id を返す。
func putPost(t *testing.T, dir string) string {
	t.Helper()
	write(t, filepath.Join(dir, "shots", "a1.png"), "PNG1")
	write(t, filepath.Join(dir, "shots", "a2.png"), "PNG2")
	write(t, filepath.Join(dir, "shots", "post.json"), `{"version": 1, "title": "Glow", "sections": [{"id": "A", "title": "光", "options": [
	  {"id": "A1", "rec": true, "media": ["a1.png"]}, {"id": "A2", "media": ["a2.png"]}]}]}`)
	var out, errOut bytes.Buffer
	d := Deps{Getwd: func() (string, error) { return dir, nil }, Now: func() time.Time { return fixedNow }}
	if code := Main([]string{"post", filepath.Join("shots", "post.json"), "--author", "claude"}, true, &out, &errOut, d); code != 0 {
		t.Fatalf("post code=%d %s", code, errOut.String())
	}
	var res struct{ ID string }
	if err := json.Unmarshal(out.Bytes(), &res); err != nil {
		t.Fatal(err, out.String())
	}
	return res.ID
}

func TestGamePageIsServedUnderBase(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	rec := do(gameServer(main, "/tide/"), "GET", "/tide/", nil)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "tab-inbox") {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestGameRequestOutsideBaseIsNotFound(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	if rec := do(gameServer(main, "/tide/"), "GET", "/other/", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestGameRequestWithForeignHostIsRefused(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	if rec := do(gameServer(main, "/tide/"), "GET", "/tide/_api/posts", map[string]string{"Host": "evil.example:8790"}); rec.Code != http.StatusForbidden {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestReplyIsWrittenToReplyJSON(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	id := putPost(t, main)
	rec := postBody(gameServer(main, "/"), "/_api/posts/"+id+"/reply", "http://127.0.0.1:8790", `{"picks": {"A": "A2"}, "comment": "暗く"}`)
	got, _ := os.ReadFile(filepath.Join(posts.Resolve(main).PostsDir(), id, "reply.json"))
	if rec.Code != 200 || !strings.Contains(string(got), `"A": "A2"`) {
		t.Fatalf("code=%d body=%s reply=%s", rec.Code, rec.Body.String(), got)
	}
}

func TestReplyWithForeignOriginIsRefused(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	id := putPost(t, main)
	if rec := postBody(gameServer(main, "/"), "/_api/posts/"+id+"/reply", "http://evil.example", `{}`); rec.Code != http.StatusForbidden {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestPostPageOpensWithCurrentReplyPicks(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	id := putPost(t, main)
	posts.WriteReply(posts.Resolve(main).PostsDir(), id, map[string]string{"A": "A2"}, "", fixedNow)
	rec := do(gameServer(main, "/tide/"), "GET", "/tide/posts/"+id+"/", nil)
	if !strings.Contains(rec.Body.String(), `value="A2" checked`) {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestPostMediaIsServedFromPostFolder(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	id := putPost(t, main)
	if rec := do(gameServer(main, "/tide/"), "GET", "/tide/posts/"+id+"/a2.png", nil); rec.Body.String() != "PNG2" {
		t.Fatalf("code=%d body=%q", rec.Code, rec.Body.String())
	}
}

func TestPostMediaSymlinkOutsideIsRefused(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	id := putPost(t, main)
	secret := filepath.Join(root, "secret.txt")
	write(t, secret, "S")
	if err := os.Symlink(secret, filepath.Join(posts.Resolve(main).PostsDir(), id, "leak.png")); err != nil {
		t.Skip("symlink を作れません")
	}
	if rec := do(gameServer(main, "/tide/"), "GET", "/tide/posts/"+id+"/leak.png", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestTapesAreListedFromEveryWorktree(t *testing.T) {
	root := setup(t, false)
	main, wt := gameRepo(t, root)
	write(t, filepath.Join(wt, "debug", "tape", "intro", "tape.json"), `{"title": "はじまり"}`)
	rec := do(gameServer(main, "/tide/"), "GET", "/tide/_api/tapes", nil)
	var cards []TapeCard
	json.Unmarshal(rec.Body.Bytes(), &cards)
	if len(cards) != 1 || cards[0].Title != "はじまり" || cards[0].Branch != "feat" {
		t.Fatalf("cards=%+v", cards)
	}
}

func TestTapePageIsServedFromItsWorktree(t *testing.T) {
	root := setup(t, false)
	main, wt := gameRepo(t, root)
	write(t, filepath.Join(wt, "debug", "tape", "intro", "tape.json"), `{"title": "t"}`)
	write(t, filepath.Join(wt, "debug", "tape", "intro", "index.html"), "TAPE PAGE")
	gs := gameServer(main, "/tide/")
	var cards []TapeCard
	json.Unmarshal(do(gs, "GET", "/tide/_api/tapes", nil).Body.Bytes(), &cards)
	if len(cards) != 1 {
		t.Fatalf("cards=%+v", cards)
	}
	if rec := do(gs, "GET", "/tide/"+cards[0].PageURL, nil); rec.Body.String() != "TAPE PAGE" {
		t.Fatalf("code=%d body=%q", rec.Code, rec.Body.String())
	}
}

func TestTapeShowsPublishedURL(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	dir := filepath.Join(main, "debug", "tape", "intro")
	write(t, filepath.Join(dir, "tape.json"), `{"title": "t"}`)
	write(t, filepath.Join(main, "debug", "tape", "published.jsonl"), `{"url": "https://x.github.io/t/", "source": "`+filepath.ToSlash(dir)+`"}`+"\n")
	var cards []TapeCard
	json.Unmarshal(do(gameServer(main, "/tide/"), "GET", "/tide/_api/tapes", nil).Body.Bytes(), &cards)
	if len(cards) != 1 || cards[0].Published != "https://x.github.io/t/" {
		t.Fatalf("cards=%+v", cards)
	}
}

func TestIndexSignatureChangesAfterReply(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	id := putPost(t, main)
	gs := gameServer(main, "/tide/")
	before := do(gs, "GET", "/tide/_api/index", nil).Body.String()
	time.Sleep(20 * time.Millisecond)
	posts.WriteReply(posts.Resolve(main).PostsDir(), id, nil, "ok", fixedNow)
	if after := do(gs, "GET", "/tide/_api/index", nil).Body.String(); after == before {
		t.Fatalf("返事の後も同じ: %s", after)
	}
}

// inProcLauncher は子の bin/fge dashboard の代わりに、同じプロセスの中で GameServer を本物の待ち受けで立てる。
type inProcLauncher struct {
	mu      sync.Mutex
	version int
	started int
	hosts   []string
	origins []string
}

func (l *inProcLauncher) Version(string) (int, error) {
	if l.version == 0 {
		return 0, errors.New("flag provided but not defined: -version")
	}
	return l.version, nil
}

func (l *inProcLauncher) Start(dir, base string) (int, <-chan struct{}, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, nil, nil, err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	gs := NewGameServer(port, base, strings.Trim(base, "/"), posts.Resolve(dir), func() time.Time { return fixedNow })
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		l.mu.Lock()
		l.hosts = append(l.hosts, r.Host)
		l.origins = append(l.origins, r.Header.Get("Origin"))
		l.mu.Unlock()
		gs.ServeHTTP(w, r)
	})}
	go srv.Serve(ln)
	done := make(chan struct{})
	l.mu.Lock()
	l.started++
	l.mu.Unlock()
	var once sync.Once
	return port, done, func() { once.Do(func() { srv.Close(); close(done) }) }, nil
}

func proxiedServer(t *testing.T, l *inProcLauncher) *Server {
	t.Helper()
	srv, _ := newTestServer()
	srv.SetLauncher(l)
	t.Cleanup(srv.Close)
	return srv
}

func TestWorkspaceProxiesGamePageToChild(t *testing.T) {
	root := setup(t, true)
	main, _ := gameRepo(t, root)
	addGame(t, "tide", main)
	rec := do(proxiedServer(t, &inProcLauncher{version: 1}), "GET", "/tide/_api/state", nil)
	var st GameState
	json.Unmarshal(rec.Body.Bytes(), &st)
	if rec.Code != 200 || st.Base != "/tide/" || st.Dir != main {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestProxyRewritesHostToChild(t *testing.T) {
	root := setup(t, true)
	main, _ := gameRepo(t, root)
	addGame(t, "tide", main)
	l := &inProcLauncher{version: 1}
	do(proxiedServer(t, l), "GET", "/tide/", nil)
	if len(l.hosts) != 1 || !strings.HasPrefix(l.hosts[0], "127.0.0.1:") || l.hosts[0] == "127.0.0.1:8790" {
		t.Fatalf("hosts=%v", l.hosts)
	}
}

func TestProxyRewritesOriginOfReplyToChild(t *testing.T) {
	root := setup(t, true)
	main, _ := gameRepo(t, root)
	addGame(t, "tide", main)
	id := putPost(t, main)
	l := &inProcLauncher{version: 1}
	rec := postBody(proxiedServer(t, l), "/tide/_api/posts/"+id+"/reply", "http://127.0.0.1:8790", `{"comment": "ok"}`)
	if rec.Code != 200 || len(l.origins) != 1 || l.origins[0] != "http://"+l.hosts[0] {
		t.Fatalf("code=%d body=%s origins=%v hosts=%v", rec.Code, rec.Body.String(), l.origins, l.hosts)
	}
}

func TestProxyRefusesForeignOriginBeforeChild(t *testing.T) {
	root := setup(t, true)
	main, _ := gameRepo(t, root)
	addGame(t, "tide", main)
	id := putPost(t, main)
	l := &inProcLauncher{version: 1}
	rec := postBody(proxiedServer(t, l), "/tide/_api/posts/"+id+"/reply", "http://evil.example", `{}`)
	if rec.Code != http.StatusForbidden || l.started != 0 {
		t.Fatalf("code=%d started=%d", rec.Code, l.started)
	}
}

func TestChildIsStartedOnceForManyRequests(t *testing.T) {
	root := setup(t, true)
	main, _ := gameRepo(t, root)
	addGame(t, "tide", main)
	l := &inProcLauncher{version: 1}
	srv := proxiedServer(t, l)
	do(srv, "GET", "/tide/", nil)
	do(srv, "GET", "/tide/_api/posts", nil)
	if l.started != 1 {
		t.Fatalf("started=%d", l.started)
	}
}

func TestGameWithoutDashboardShowsUpgradeNote(t *testing.T) {
	root := setup(t, true)
	main, _ := gameRepo(t, root)
	addGame(t, "tide", main)
	srv := proxiedServer(t, &inProcLauncher{version: 0})
	do(srv, "GET", "/tide/", nil)
	var st State
	json.Unmarshal(do(srv, "GET", "/_api/state", nil).Body.Bytes(), &st)
	if len(st.Games) != 1 || !strings.Contains(st.Games[0].Note, "版を上げると開けます") {
		t.Fatalf("games=%+v", st.Games)
	}
}

func TestVersionFlagPrintsContractVersion(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := Main([]string{"--version"}, false, &out, &errOut, Deps{}); code != 0 || out.String() != "1\n" {
		t.Fatalf("code=%d out=%q", code, out.String())
	}
}

func TestBaseModePrintsListenLineFirst(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	var out, errOut bytes.Buffer
	d := Deps{Getwd: func() (string, error) { return main, nil }, Serve: func(net.Listener, http.Handler) error { return nil }}
	code := Main([]string{"--port", "0", "--no-open", "--base", "/tide/"}, false, &out, &errOut, d)
	if code != 0 || !strings.HasPrefix(out.String(), ListenPrefix+"127.0.0.1:") {
		t.Fatalf("code=%d out=%q err=%q", code, out.String(), errOut.String())
	}
}

func TestBaseModeOutsideGameIsRefused(t *testing.T) {
	root := setup(t, false)
	var out, errOut bytes.Buffer
	d := Deps{Getwd: func() (string, error) { return root, nil }, Serve: func(net.Listener, http.Handler) error { return nil }}
	if code := Main([]string{"--port", "0", "--base", "/x/"}, false, &out, &errOut, d); code != exitProblem {
		t.Fatalf("code=%d", code)
	}
}

func TestInboxTextShowsPicksAndComment(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	id := putPost(t, main)
	posts.WriteReply(posts.Resolve(main).PostsDir(), id, map[string]string{"A": "A2"}, "暗く", fixedNow)
	var out bytes.Buffer
	Main([]string{"inbox"}, false, &out, &bytes.Buffer{}, Deps{Getwd: func() (string, error) { return main, nil }})
	if !strings.Contains(out.String(), "選んだ案: A=A2") || !strings.Contains(out.String(), "暗く") {
		t.Fatalf("out=%s", out.String())
	}
}

func TestResolveHidesPostFromInbox(t *testing.T) {
	root := setup(t, false)
	main, _ := gameRepo(t, root)
	id := putPost(t, main)
	posts.WriteReply(posts.Resolve(main).PostsDir(), id, nil, "ok", fixedNow)
	d := Deps{Getwd: func() (string, error) { return main, nil }}
	Main([]string{"resolve", id}, false, &bytes.Buffer{}, &bytes.Buffer{}, d)
	var out bytes.Buffer
	Main([]string{"inbox", "--all"}, true, &out, &bytes.Buffer{}, d)
	if strings.TrimSpace(out.String()) != "[]" {
		t.Fatalf("out=%s", out.String())
	}
}

func TestPostOutputHasGameURLWithPostAnchor(t *testing.T) {
	root := setup(t, false)
	main, wt := gameRepo(t, root)
	addGame(t, "tide", main)
	write(t, filepath.Join(wt, "p.json"), `{"title": "t"}`)
	var out bytes.Buffer
	Main([]string{"post", "p.json"}, false, &out, &bytes.Buffer{}, Deps{Getwd: func() (string, error) { return wt, nil }, Now: func() time.Time { return fixedNow }})
	if !strings.Contains(out.String(), "http://127.0.0.1:8790/tide/#post-20261124-101500-t") {
		t.Fatalf("out=%s", out.String())
	}
}

// 終わりの基準（plans/dashboard.md 9 節のフェーズ 1）: worktree の AI が post → 人が main のダッシュボードで選んで返す → AI が inbox で拾う。
func TestWorktreePostReplyInboxRoundTrip(t *testing.T) {
	root := setup(t, true)
	main, wt := gameRepo(t, root)
	addGame(t, "tide", main)
	id := putPost(t, wt)

	srv := proxiedServer(t, &inProcLauncher{version: 1})
	var list []posts.Post
	json.Unmarshal(do(srv, "GET", "/tide/_api/posts", nil).Body.Bytes(), &list)
	if len(list) != 1 || list[0].ID != id {
		t.Fatalf("main のダッシュボードに worktree の post が出ない: %+v", list)
	}
	if rec := postBody(srv, "/tide/_api/posts/"+id+"/reply", "http://127.0.0.1:8790", `{"picks": {"A": "A2"}, "comment": "A2 で"}`); rec.Code != 200 {
		t.Fatalf("返せない: %d %s", rec.Code, rec.Body.String())
	}

	var out bytes.Buffer
	Main([]string{"inbox"}, true, &out, &bytes.Buffer{}, Deps{Getwd: func() (string, error) { return filepath.Join(wt), nil }})
	var items []InboxItem
	json.Unmarshal(out.Bytes(), &items)
	if len(items) != 1 || items[0].Reply.Picks["A"] != "A2" || items[0].Reply.Comment != "A2 で" {
		t.Fatalf("worktree の inbox で拾えない: %s", out.String())
	}
}

func TestFgeForTemplateUsesEngineBin(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "agents-pack", "manifest.json"), "{}")
	write(t, filepath.Join(root, "bin", "fge-go"), "")
	write(t, filepath.Join(root, "templates", "x", "flix.toml"), "")
	got, err := fgeFor(filepath.Join(root, "templates", "x"))
	if err != nil || got != filepath.Join(root, "bin", "fge-go") {
		t.Fatalf("got=%s err=%v", got, err)
	}
}
