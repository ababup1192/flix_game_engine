package dashboard

import (
	_ "embed"
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/ababup1192/flix_game_engine/go/internal/fetchengine"
	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
	"github.com/ababup1192/flix_game_engine/go/internal/fgeinstall"
	"github.com/ababup1192/flix_game_engine/go/internal/newgame"
)

//go:embed page.html
var pageHTML []byte

// AppName は /_api/whoami が返す名前。既に立っているサーバーが自分の物かを見分ける。
const AppName = "flix-ge-dashboard"

var templateNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

// Server はワークスペースのサーバーの頁と API。
type Server struct {
	mu   sync.Mutex
	port int

	install       *installState
	startInstall  func()
	latest        func() (fgehome.Latest, bool)
	installedList func() []string
}

// NewServer は port で待つ前提の Server を作る。startInstall は engine を取る仕事を裏で始める（走っていれば何もしない）。
func NewServer(port int, install *installState, startInstall func(), latest func() (fgehome.Latest, bool)) *Server {
	return &Server{
		port:          port,
		install:       install,
		startInstall:  startInstall,
		latest:        latest,
		installedList: fgeinstall.InstalledVersions,
	}
}

// SetPort は待ち受けを決めた後に、Host と Origin の検査に使う番号を替える。
func (s *Server) SetPort(port int) {
	s.mu.Lock()
	s.port = port
	s.mu.Unlock()
}

func (s *Server) getPort() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.port
}

func (s *Server) allowedHosts() []string {
	p := strconv.Itoa(s.getPort())
	return []string{"127.0.0.1:" + p, "localhost:" + p}
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// WhyNot: Host を見ずに答えない — 外のサイトが DNS rebinding で自分の名前を 127.0.0.1 に向けると、頁と API を読まれる。
	if !contains(s.allowedHosts(), r.Host) {
		http.Error(w, "Host が違います", http.StatusForbidden)
		return
	}
	if r.Method == http.MethodPost {
		if !s.isOwnOrigin(r.Header.Get("Origin")) {
			http.Error(w, "Origin が違います", http.StatusForbidden)
			return
		}
	} else if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "GET と POST だけです", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	path := r.URL.Path
	switch {
	case path == "/_api/whoami":
		s.whoami(w)
	case path == "/_api/state":
		s.state(w)
	case path == "/_api/engines/install":
		if r.Method != http.MethodPost {
			http.Error(w, "POST だけです", http.StatusMethodNotAllowed)
			return
		}
		s.startInstall()
		writeJSON(w, map[string]bool{"started": true})
	case strings.HasPrefix(path, "/_api/templates/"):
		s.templateImage(w, r)
	case strings.HasPrefix(path, "/_api/"):
		http.NotFound(w, r)
	case path == "/":
		s.page(w)
	default:
		s.gamePath(w, r)
	}
}

func (s *Server) isOwnOrigin(origin string) bool {
	for _, h := range s.allowedHosts() {
		if origin == "http://"+h {
			return true
		}
	}
	return false
}

func (s *Server) page(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// WhyNot: 外の CDN や inline の外の物を読まない — 手元だけで開く頁で、網が無くても同じに見せる。
	w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(pageHTML)
}

// gamePath は /<ゲーム名>/ を、workspace.json にある名前の時だけ頁で返す。
func (s *Server) gamePath(w http.ResponseWriter, r *http.Request) {
	name, rest, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/"), "/")
	if _, ok := findGame(name); !ok {
		http.NotFound(w, r)
		return
	}
	if !strings.HasSuffix(r.URL.Path, "/") && rest == "" {
		http.Redirect(w, r, "/"+url.PathEscape(name)+"/", http.StatusFound)
		return
	}
	if rest != "" {
		http.NotFound(w, r)
		return
	}
	s.page(w)
}

func findGame(name string) (fgehome.Game, bool) {
	if name == "" {
		return fgehome.Game{}, false
	}
	ws, err := fgehome.ReadWorkspace()
	if err != nil {
		return fgehome.Game{}, false
	}
	for _, g := range ws.Games {
		if g.Name == name {
			return g, true
		}
	}
	return fgehome.Game{}, false
}

func (s *Server) whoami(w http.ResponseWriter) {
	writeJSON(w, map[string]any{"app": AppName, "pid": os.Getpid()})
}

// State は /_api/state の形。頁はこれだけを読んで描く。
type State struct {
	WorkspaceDir string         `json:"workspaceDir"`
	FgePath      string         `json:"fgePath"`
	Engines      []string       `json:"engines"`
	Newest       string         `json:"newest,omitempty"`
	Latest       string         `json:"latest,omitempty"`
	Newer        bool           `json:"newer"`
	Templates    []TemplateCard `json:"templates"`
	Games        []GameCard     `json:"games"`
	Install      InstallView    `json:"install"`
}

// TemplateCard はテンプレートのカード 1 枚。
type TemplateCard struct {
	Name     string `json:"name"`
	Title    string `json:"title,omitempty"`
	Summary  string `json:"summary,omitempty"`
	ImageURL string `json:"imageUrl,omitempty"`
}

// GameCard はゲームの一覧の 1 行。
type GameCard struct {
	Name          string `json:"name"`
	Dir           string `json:"dir"`
	EngineVersion string `json:"engineVersion,omitempty"`
	Exists        bool   `json:"exists"`
}

func (s *Server) state(w http.ResponseWriter) {
	ws, err := fgehome.ReadWorkspace()
	if err != nil {
		http.Error(w, "workspace.json を読めません: "+err.Error(), http.StatusInternalServerError)
		return
	}
	st := State{
		WorkspaceDir: ws.Dir,
		FgePath:      filepath.Join(fgehome.BinDir(), fgeExeName()),
		Engines:      s.installedList(),
		Templates:    []TemplateCard{},
		Games:        []GameCard{},
		Install:      s.install.view(),
	}
	if st.Engines == nil {
		st.Engines = []string{}
	}
	if n := len(st.Engines); n > 0 {
		st.Newest = st.Engines[n-1]
		st.Templates = templateCards(fgehome.EngineDir(st.Newest))
	}
	if l, ok := s.latest(); ok {
		st.Latest = l.Version
		st.Newer = st.Newest != "" && fetchengine.IsNewer(st.Newest, l.Version)
	}
	for _, g := range ws.Games {
		info, err := os.Stat(g.Dir)
		st.Games = append(st.Games, GameCard{
			Name:          g.Name,
			Dir:           g.Dir,
			EngineVersion: fgehome.ReadGameEngineVersion(g.Dir),
			Exists:        err == nil && info.IsDir(),
		})
	}
	writeJSON(w, st)
}

func templateCards(engineDir string) []TemplateCard {
	list, err := newgame.ListTemplates(engineDir)
	if err != nil {
		return []TemplateCard{}
	}
	cards := make([]TemplateCard, 0, len(list))
	for _, t := range list {
		c := TemplateCard{Name: t.Name, Title: t.Title, Summary: t.Summary}
		if _, err := os.Stat(templateImagePath(engineDir, t.Name)); err == nil {
			c.ImageURL = "/_api/templates/" + t.Name + "/title.png"
		}
		cards = append(cards, c)
	}
	return cards
}

func templateImagePath(engineDir, name string) string {
	return filepath.Join(engineDir, "templates", name, "reference", "title.png")
}

// templateImage は手元の最新の engine の templates/<名>/reference/title.png だけを出す。
func (s *Server) templateImage(w http.ResponseWriter, r *http.Request) {
	name, file, ok := strings.Cut(strings.TrimPrefix(r.URL.Path, "/_api/templates/"), "/")
	versions := s.installedList()
	if !ok || file != "title.png" || !templateNameRe.MatchString(name) || len(versions) == 0 {
		http.NotFound(w, r)
		return
	}
	engineDir := fgehome.EngineDir(versions[len(versions)-1])
	path, ok := insideDir(filepath.Join(engineDir, "templates"), templateImagePath(engineDir, name))
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "max-age=300")
	http.ServeFile(w, r, path)
}

// insideDir は path の symlink を辿った先が root の下にある時だけ、辿った先を返す。
func insideDir(root, path string) (string, bool) {
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", false
	}
	realPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", false
	}
	rel, err := filepath.Rel(realRoot, realPath)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", false
	}
	info, err := os.Stat(realPath)
	if err != nil || !info.Mode().IsRegular() {
		return "", false
	}
	return realPath, true
}

func fgeExeName() string {
	if os.PathSeparator == '\\' {
		return "fge.exe"
	}
	return "fge"
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(v)
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// listenLocal は 127.0.0.1:port で待つ。塞がっていれば空いた番号で待つ。
func listenLocal(port int) (net.Listener, error) {
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err == nil || port == 0 {
		return ln, err
	}
	return net.Listen("tcp", "127.0.0.1:0")
}
