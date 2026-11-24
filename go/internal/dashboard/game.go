package dashboard

import (
	_ "embed"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/posts"
	"github.com/ababup1192/flix_game_engine/go/internal/proposal"
)

//go:embed game.html
var gameHTML []byte

// ContractVersion は全体の fge と子の bin/fge dashboard の間の約束の版（--version が 1 行で出す）。
// 約束は --port・--no-open・--base・--version と、子が待ち始めた時に出す ListenPrefix の 1 行だけ。
const ContractVersion = 1

// ListenPrefix は子が待ち始めた時に stdout へ出す行の頭（後ろに 127.0.0.1:<番号>）。
const ListenPrefix = "[fge dashboard] listen "

// StarterPrompt は「はじめに」カードの下書き（plans/dashboard.md 15.2）。
const StarterPrompt = "このゲームで何ができるか教えて。make status を見て、次にやることを 3 つ挙げて"

const maxReplyBytes = 64 << 10

// GameServer はゲーム 1 つの頁（Inbox・Tape・はじめに のカード）と API。base の下で答える。
type GameServer struct {
	mu    sync.Mutex
	port  int
	base  string
	name  string
	roots posts.Roots
	now   func() time.Time
	// replyMu は同じ post への返事が 2 つ同時に来ても、前の返事を replies へ移す順が崩れないようにする。
	replyMu sync.Mutex
}

// NewGameServer は base（/ か /<名前>/）の下で roots のゲームを出す GameServer を作る。
func NewGameServer(port int, base, name string, roots posts.Roots, now func() time.Time) *GameServer {
	return &GameServer{port: port, base: base, name: name, roots: roots, now: now}
}

// SetPort は待ち受けを決めた後に、Host と Origin の検査に使う番号を替える。
func (g *GameServer) SetPort(port int) {
	g.mu.Lock()
	g.port = port
	g.mu.Unlock()
}

func (g *GameServer) allowedHosts() []string {
	g.mu.Lock()
	p := strconv.Itoa(g.port)
	g.mu.Unlock()
	return []string{"127.0.0.1:" + p, "localhost:" + p}
}

func (g *GameServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !guard(w, r, g.allowedHosts()) {
		return
	}
	path := r.URL.Path
	if path+"/" == g.base {
		http.Redirect(w, r, g.base, http.StatusFound)
		return
	}
	if !strings.HasPrefix(path, g.base) {
		http.NotFound(w, r)
		return
	}
	rest := strings.TrimPrefix(path, g.base)
	switch {
	case rest == "":
		servePage(w, gameHTML)
	case rest == "_api/state":
		g.state(w)
	case rest == "_api/index":
		writeJSON(w, map[string]string{"posts": posts.Signature(g.roots.PostsDir()), "tapes": tapesSignature(tapeRoots(g.roots))})
	case rest == "_api/posts":
		writeJSON(w, posts.List(g.roots.PostsDir()))
	case rest == "_api/tapes":
		writeJSON(w, listTapes(tapeRoots(g.roots)))
	case strings.HasPrefix(rest, "_api/posts/") && strings.HasSuffix(rest, "/reply"):
		g.reply(w, r, strings.TrimSuffix(strings.TrimPrefix(rest, "_api/posts/"), "/reply"))
	case strings.HasPrefix(rest, "_api/"):
		http.NotFound(w, r)
	case strings.HasPrefix(rest, "posts/"):
		g.post(w, r, strings.TrimPrefix(rest, "posts/"))
	case strings.HasPrefix(rest, "tapes/"):
		g.tapeFile(w, r, strings.TrimPrefix(rest, "tapes/"))
	default:
		http.NotFound(w, r)
	}
}

// GameState は <base>_api/state の形。
type GameState struct {
	Name     string `json:"name"`
	Dir      string `json:"dir"`
	Base     string `json:"base"`
	Branch   string `json:"branch,omitempty"`
	PostsDir string `json:"postsDir"`
	Prompt   string `json:"prompt"`
}

func (g *GameServer) state(w http.ResponseWriter) {
	writeJSON(w, GameState{
		Name: g.name, Dir: g.roots.MainRoot, Base: g.base, Branch: g.roots.Branch,
		PostsDir: g.roots.PostsDir(), Prompt: StarterPrompt,
	})
}

// post は posts/<id>/ を「送る」つきの proposal の頁で、posts/<id>/<名前> をその post の素材で返す。
func (g *GameServer) post(w http.ResponseWriter, r *http.Request, rest string) {
	id, file, slash := strings.Cut(rest, "/")
	if !posts.ValidID(id) {
		http.NotFound(w, r)
		return
	}
	if !slash {
		http.Redirect(w, r, g.base+"posts/"+id+"/", http.StatusFound)
		return
	}
	dir := filepath.Join(g.roots.PostsDir(), id)
	if file != "" {
		if strings.Contains(file, "/") || file == posts.ReplyFile {
			http.NotFound(w, r)
			return
		}
		path, ok := insideDir(dir, filepath.Join(dir, file))
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		serveFile(w, r, path)
		return
	}
	p, m, err := posts.Load(g.roots.PostsDir(), id)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	opts := proposal.PageOptions{Send: true, SendURL: g.base + "_api/posts/" + id + "/reply", BackURL: g.base + "#post-" + id}
	if p.Reply != nil {
		opts.Picks, opts.Comment = p.Reply.Picks, p.Reply.Comment
	}
	html, _ := proposal.Page(m, dir, opts)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'")
	w.Header().Set("Cache-Control", "no-store")
	w.Write([]byte(html))
}

type replyBody struct {
	Picks   map[string]string `json:"picks"`
	Comment string            `json:"comment"`
}

func (g *GameServer) reply(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST だけです", http.StatusMethodNotAllowed)
		return
	}
	if !posts.ValidID(id) {
		http.NotFound(w, r)
		return
	}
	var body replyBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxReplyBytes))
	if err := dec.Decode(&body); err != nil {
		http.Error(w, "返事の JSON を読めません: "+err.Error(), http.StatusBadRequest)
		return
	}
	g.replyMu.Lock()
	rep, err := posts.WriteReply(g.roots.PostsDir(), id, body.Picks, body.Comment, g.now())
	g.replyMu.Unlock()
	if errors.Is(err, os.ErrNotExist) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, "返事を書けません: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, rep)
}

// tapeFile は tapes/<作業ツリーの key>/<テープ>/<ファイル> を、その作業ツリーの debug/tape の下からだけ返す。
func (g *GameServer) tapeFile(w http.ResponseWriter, r *http.Request, rest string) {
	key, rel, ok := strings.Cut(rest, "/")
	if !ok || rel == "" {
		http.NotFound(w, r)
		return
	}
	if strings.HasSuffix(rel, "/") {
		rel += "index.html"
	}
	for _, root := range tapeRoots(g.roots) {
		if root.key != key {
			continue
		}
		path, ok := insideDir(root.dir, filepath.Join(root.dir, filepath.FromSlash(rel)))
		if !ok {
			break
		}
		serveFile(w, r, path)
		return
	}
	http.NotFound(w, r)
}

// serveFile は path を返す。
// WhyNot: http.ServeFile を使わない — 名前が index.html の要求を「./」へ転送し、転送先のフォルダは insideDir が断る。
func serveFile(w http.ResponseWriter, r *http.Request, path string) {
	f, err := os.Open(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		http.NotFound(w, r)
		return
	}
	http.ServeContent(w, r, filepath.Base(path), info.ModTime(), f)
}
