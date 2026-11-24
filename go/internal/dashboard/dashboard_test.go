package dashboard

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

const testPort = 8790

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// setup は空の置き場と home を作る。withEngine の時は 0.108.0 の engine を置く。
func setup(t *testing.T, withEngine bool) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("HOME", filepath.Join(root, "home"))
	t.Setenv("USERPROFILE", filepath.Join(root, "home"))
	t.Setenv("FGE_HOME", filepath.Join(root, "fgehome"))
	if withEngine {
		eng := fgehome.EngineDir("0.108.0")
		write(t, filepath.Join(eng, fgehome.CompleteMarker), "")
		write(t, filepath.Join(eng, "Makefile"), "")
		write(t, filepath.Join(eng, "templates/rpg-starter/README.md"), "# rpg\n\n町と戦闘のある RPG\n")
		write(t, filepath.Join(eng, "templates/rpg-starter/reference/title.png"), "PNG")
		write(t, filepath.Join(eng, "templates/game-starter/README.md"), "# game\n\n最小のゲーム\n")
		write(t, filepath.Join(eng, "agents-pack/workspace/AGENTS.md"), "# ws v1\n")
	}
	return root
}

func newTestServer() (*Server, *int) {
	installs := 0
	srv := NewServer(testPort, &installState{}, func() { installs++ }, func() (fgehome.Latest, bool) {
		return fgehome.Latest{Version: "0.109.0"}, true
	})
	srv.SetLauncher(&inProcLauncher{version: 1})
	return srv, &installs
}

func do(srv http.Handler, method, target string, header map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, "http://127.0.0.1:"+strconv.Itoa(testPort)+target, nil)
	for k, v := range header {
		if k == "Host" {
			req.Host = v
		} else {
			req.Header.Set(k, v)
		}
	}
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)
	return rec
}

func addGame(t *testing.T, name, dir string) {
	t.Helper()
	ws, err := fgehome.ReadWorkspace()
	if err != nil {
		t.Fatal(err)
	}
	ws.AddGame(fgehome.Game{Name: name, Dir: dir})
	if err := fgehome.WriteWorkspace(ws); err != nil {
		t.Fatal(err)
	}
}

func TestRootServesTheEmbeddedPage(t *testing.T) {
	setup(t, true)
	srv, _ := newTestServer()
	rec := do(srv, "GET", "/", nil)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "新しいゲーム") {
		t.Fatalf("code=%d body の頭=%.80q", rec.Code, rec.Body.String())
	}
}

func TestPageLoadsNothingFromOutside(t *testing.T) {
	if bytes.Contains(pageHTML, []byte("<link")) || bytes.Contains(pageHTML, []byte("src=\"http")) {
		t.Fatal("頁が外の物を読んでいます")
	}
}

func TestRequestWithForeignHostIsRefused(t *testing.T) {
	setup(t, true)
	srv, _ := newTestServer()
	rec := do(srv, "GET", "/_api/state", map[string]string{"Host": "evil.example:8790"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestLocalhostHostIsAccepted(t *testing.T) {
	setup(t, true)
	srv, _ := newTestServer()
	rec := do(srv, "GET", "/_api/whoami", map[string]string{"Host": "localhost:8790"})
	if rec.Code != 200 {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestHostWithOtherPortIsRefused(t *testing.T) {
	setup(t, true)
	srv, _ := newTestServer()
	rec := do(srv, "GET", "/", map[string]string{"Host": "127.0.0.1:9999"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestPostWithoutOriginIsRefused(t *testing.T) {
	setup(t, true)
	srv, installs := newTestServer()
	rec := do(srv, "POST", "/_api/engines/install", nil)
	if rec.Code != http.StatusForbidden || *installs != 0 {
		t.Fatalf("code=%d installs=%d", rec.Code, *installs)
	}
}

func TestPostFromForeignOriginIsRefused(t *testing.T) {
	setup(t, true)
	srv, installs := newTestServer()
	rec := do(srv, "POST", "/_api/engines/install", map[string]string{"Origin": "http://evil.example"})
	if rec.Code != http.StatusForbidden || *installs != 0 {
		t.Fatalf("code=%d installs=%d", rec.Code, *installs)
	}
}

func TestPostFromOwnOriginStartsInstall(t *testing.T) {
	setup(t, true)
	srv, installs := newTestServer()
	rec := do(srv, "POST", "/_api/engines/install", map[string]string{"Origin": "http://127.0.0.1:8790"})
	if rec.Code != 200 || *installs != 1 {
		t.Fatalf("code=%d installs=%d", rec.Code, *installs)
	}
}

func TestUnknownApiPathIsNotFound(t *testing.T) {
	setup(t, true)
	srv, _ := newTestServer()
	if rec := do(srv, "GET", "/_api/nothing", nil); rec.Code != 404 {
		t.Fatalf("code=%d", rec.Code)
	}
}

func readState(t *testing.T, srv http.Handler) State {
	t.Helper()
	rec := do(srv, "GET", "/_api/state", nil)
	if rec.Code != 200 {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body.String())
	}
	var st State
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func TestStateListsTemplatesOfTheNewestEngineWithImageOnlyWhenPresent(t *testing.T) {
	setup(t, true)
	srv, _ := newTestServer()
	st := readState(t, srv)
	got := map[string]string{}
	for _, c := range st.Templates {
		got[c.Name] = c.ImageURL
	}
	want := map[string]string{"game-starter": "", "rpg-starter": "/_api/templates/rpg-starter/title.png"}
	if len(got) != 2 || got["game-starter"] != want["game-starter"] || got["rpg-starter"] != want["rpg-starter"] {
		t.Fatalf("templates=%v", got)
	}
}

func TestStateTellsANewerReleaseThanTheNewestEngine(t *testing.T) {
	setup(t, true)
	srv, _ := newTestServer()
	st := readState(t, srv)
	if !st.Newer || st.Latest != "0.109.0" || st.Newest != "0.108.0" {
		t.Fatalf("newer=%v latest=%s newest=%s", st.Newer, st.Latest, st.Newest)
	}
}

func TestStateListsGamesWithTheirEngineVersion(t *testing.T) {
	root := setup(t, true)
	game := filepath.Join(root, "ws", "tide-pool")
	write(t, filepath.Join(game, "flix.toml"), "[dependencies]\n\"github:ababup1192/flix_game_engine\" = { version = \"0.107.0\" }\n")
	addGame(t, "tide-pool", game)
	st := readState(t, srv(t))
	if len(st.Games) != 1 || st.Games[0].EngineVersion != "0.107.0" || !st.Games[0].Exists {
		t.Fatalf("games=%+v", st.Games)
	}
}

func srv(t *testing.T) *Server {
	s, _ := newTestServer()
	return s
}

func TestTemplateImageIsServed(t *testing.T) {
	setup(t, true)
	rec := do(srv(t), "GET", "/_api/templates/rpg-starter/title.png", nil)
	if rec.Code != 200 || rec.Body.String() != "PNG" {
		t.Fatalf("code=%d body=%q", rec.Code, rec.Body.String())
	}
}

func TestTemplateImageWithDotDotIsRefused(t *testing.T) {
	setup(t, true)
	rec := do(srv(t), "GET", "/_api/templates/../agents-pack/title.png", nil)
	if rec.Code != 404 {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestTemplateImageThroughSymlinkOutsideIsRefused(t *testing.T) {
	root := setup(t, true)
	secret := filepath.Join(root, "secret.png")
	write(t, secret, "SECRET")
	dir := filepath.Join(fgehome.EngineDir("0.108.0"), "templates/leak/reference")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, filepath.Join(dir, "title.png")); err != nil {
		t.Skip("symlink を作れません")
	}
	rec := do(srv(t), "GET", "/_api/templates/leak/title.png", nil)
	if rec.Code != 404 {
		t.Fatalf("code=%d body=%q", rec.Code, rec.Body.String())
	}
}

func TestKnownGamePathServesThePage(t *testing.T) {
	root := setup(t, true)
	addGame(t, "tide-pool", filepath.Join(root, "ws", "tide-pool"))
	if rec := do(srv(t), "GET", "/tide-pool/", nil); rec.Code != 200 {
		t.Fatalf("code=%d", rec.Code)
	}
}

func TestGamePathWithoutSlashRedirects(t *testing.T) {
	root := setup(t, true)
	addGame(t, "tide-pool", filepath.Join(root, "ws", "tide-pool"))
	rec := do(srv(t), "GET", "/tide-pool", nil)
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/tide-pool/" {
		t.Fatalf("code=%d location=%s", rec.Code, rec.Header().Get("Location"))
	}
}

func TestUnknownGamePathIsNotFound(t *testing.T) {
	setup(t, true)
	if rec := do(srv(t), "GET", "/nobody/", nil); rec.Code != 404 {
		t.Fatalf("code=%d", rec.Code)
	}
}

// fakeDeps は網とブラウザを持たない Deps。opened に開いた URL を残す。
type fakeDeps struct {
	mu       sync.Mutex
	opened   []string
	installs int
	ours     bool
	served   bool
	wd       string
}

func (f *fakeDeps) deps() Deps {
	return Deps{
		Getwd:       func() (string, error) { return f.wd, nil },
		OpenBrowser: func(u string) error { f.mu.Lock(); f.opened = append(f.opened, u); f.mu.Unlock(); return nil },
		Install: func(io.Writer) error {
			f.mu.Lock()
			f.installs++
			f.mu.Unlock()
			return nil
		},
		IsOurServer: func(int) bool { return f.ours },
		Serve: func(ln net.Listener, h http.Handler) error {
			f.served = true
			ln.Close()
			return nil
		},
	}
}

func runDashboard(t *testing.T, f *fakeDeps, args ...string) (int, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := Run(args, &out, &errOut, f.deps())
	return code, out.String() + errOut.String()
}

func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func TestRunInGameFolderAddsTheGameAndOpensItsPageOnTheRunningServer(t *testing.T) {
	root := setup(t, true)
	game := filepath.Join(root, "ws", "tide-pool")
	write(t, filepath.Join(game, "flix.toml"), "")
	f := &fakeDeps{ours: true, wd: filepath.Join(game, "src")}
	os.MkdirAll(f.wd, 0o755)
	code, log := runDashboard(t, f, "--port", "8790")
	ws, _ := fgehome.ReadWorkspace()
	if code != 0 || f.served || len(ws.Games) != 1 || ws.Games[0].Dir != game ||
		len(f.opened) != 1 || f.opened[0] != "http://127.0.0.1:8790/tide-pool/" {
		t.Fatalf("code=%d served=%v games=%+v opened=%v log=%s", code, f.served, ws.Games, f.opened, log)
	}
}

func TestRunInGameFolderWhoseNameIsTakenAddsANumber(t *testing.T) {
	root := setup(t, true)
	addGame(t, "tide-pool", filepath.Join(root, "other", "tide-pool"))
	game := filepath.Join(root, "ws", "tide-pool")
	write(t, filepath.Join(game, "flix.toml"), "")
	f := &fakeDeps{ours: true, wd: game}
	runDashboard(t, f)
	if len(f.opened) != 1 || f.opened[0] != "http://127.0.0.1:8790/tide-pool-2/" {
		t.Fatalf("opened=%v", f.opened)
	}
}

func TestRunInsideTheEngineRepoDoesNotAddAGame(t *testing.T) {
	root := setup(t, true)
	repo := filepath.Join(root, "flix_game_engine")
	write(t, filepath.Join(repo, "flix.toml"), "")
	write(t, filepath.Join(repo, "agents-pack/manifest.json"), "{}")
	f := &fakeDeps{ours: true, wd: repo}
	runDashboard(t, f)
	ws, _ := fgehome.ReadWorkspace()
	if len(ws.Games) != 0 || f.opened[0] != "http://127.0.0.1:8790/" {
		t.Fatalf("games=%+v opened=%v", ws.Games, f.opened)
	}
}

func TestRunCopiesTheWorkspaceAgentsAndClaudeMd(t *testing.T) {
	root := setup(t, true)
	dir := filepath.Join(root, "flix-games")
	f := &fakeDeps{wd: root}
	code, log := runDashboard(t, f, "--port", strconv.Itoa(freePort(t)), "--dir", dir, "--no-open")
	agents, _ := os.ReadFile(filepath.Join(dir, "AGENTS.md"))
	claude, _ := os.ReadFile(filepath.Join(dir, "CLAUDE.md"))
	if code != 0 || !f.served || string(agents) != "# ws v1\n" || string(claude) != "@AGENTS.md\n" {
		t.Fatalf("code=%d served=%v agents=%q claude=%q log=%s", code, f.served, agents, claude, log)
	}
}

func TestRunRemembersTheDirInWorkspaceJSON(t *testing.T) {
	root := setup(t, true)
	dir := filepath.Join(root, "games")
	runDashboard(t, &fakeDeps{wd: root}, "--port", strconv.Itoa(freePort(t)), "--dir", dir, "--no-open")
	ws, _ := fgehome.ReadWorkspace()
	if ws.Dir != dir {
		t.Fatalf("dir=%s", ws.Dir)
	}
}

func TestRunWithoutEngineStartsInstall(t *testing.T) {
	root := setup(t, false)
	f := &fakeDeps{wd: root}
	runDashboard(t, f, "--port", strconv.Itoa(freePort(t)), "--dir", filepath.Join(root, "g"), "--no-open")
	deadline := time.Now().Add(2 * time.Second)
	for {
		f.mu.Lock()
		n := f.installs
		f.mu.Unlock()
		if n == 1 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("installs=%d", n)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestRunListensOnAnotherPortWhenTheDefaultIsTaken(t *testing.T) {
	root := setup(t, true)
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	port := busy.Addr().(*net.TCPAddr).Port
	f := &fakeDeps{wd: root}
	code, _ := runDashboard(t, f, "--port", strconv.Itoa(port), "--dir", filepath.Join(root, "g"))
	if code != 0 || len(f.opened) != 1 || strings.Contains(f.opened[0], ":"+strconv.Itoa(port)+"/") {
		t.Fatalf("code=%d opened=%v", code, f.opened)
	}
}

func TestInstallLogKeepsOnlyTheLastProgressOfARewrittenLine(t *testing.T) {
	s := &installState{}
	s.begin()
	io.WriteString(s, "取ります\n10%\r50%\r100%\n")
	if got := s.view().Log; len(got) != 2 || got[1] != "100%" {
		t.Fatalf("log=%q", got)
	}
}
