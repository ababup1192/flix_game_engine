package dashboard

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

// Launcher は子の bin/fge dashboard（ゲームの engine の版の物）を起こす口。テストは差し替える。
type Launcher interface {
	// Version は dir のゲームの bin/fge dashboard --version（約束の版）。ダッシュボードより前の版なら err。
	Version(dir string) (int, error)
	// Start は dir で bin/fge dashboard --port 0 --no-open --base <base> を起こし、待ち始めた番号を返す。
	// done は子が終わると閉じる。stop は子を止める（何度呼んでもよい）。
	Start(dir, base string) (port int, done <-chan struct{}, stop func(), err error)
}

// gameProxies は /<ゲーム名>/ を子へ中継する。子は初めて開いた時に起こす。
type gameProxies struct {
	launcher Launcher
	mu       sync.Mutex
	entries  map[string]*gameProxy
	// notes は最後に起こせなかった理由（ゲーム名 → 理由）。起こせたら消す。
	notes map[string]string
}

type gameProxy struct {
	dir   string
	ready chan struct{}
	done  <-chan struct{}
	stop  func()
	note  string
	proxy http.Handler
	// stopped は stopAll が起こし終える前の entry に立てるフラグ（p.mu の下で読み書きする）。
	stopped bool
}

func newGameProxies(l Launcher) *gameProxies {
	return &gameProxies{launcher: l, entries: map[string]*gameProxy{}, notes: map[string]string{}}
}

func (e *gameProxy) alive() bool {
	if e.proxy == nil {
		return false
	}
	select {
	case <-e.done:
		return false
	default:
		return true
	}
}

// errNotStarted は mayStart が偽で、まだ子が居ない時の答え。
var errNotStarted = errors.New("not started")

// get は g の子の中継を返す。中継できなければ nil と、頁に出す理由。
// mayStart が偽の時は子を新しく起こさず errNotStarted を返す。
func (p *gameProxies) get(g fgehome.Game, mayStart bool) (http.Handler, string, error) {
	for {
		p.mu.Lock()
		e := p.entries[g.Name]
		if e == nil {
			if !mayStart {
				p.mu.Unlock()
				return nil, "", errNotStarted
			}
			e = &gameProxy{dir: g.Dir, ready: make(chan struct{})}
			p.entries[g.Name] = e
			p.mu.Unlock()
			p.start(e, g)
			p.mu.Lock()
			if e.stopped {
				p.mu.Unlock()
				if e.stop != nil {
					e.stop()
				}
				return nil, "ダッシュボードを止めています", nil
			}
			if e.proxy == nil {
				// WhyNot: 起こせなかった子を entries に残さない — 人が版を上げた後に開き直せば起こし直す。
				if p.entries[g.Name] == e {
					delete(p.entries, g.Name)
				}
				p.notes[g.Name] = e.note
			} else {
				delete(p.notes, g.Name)
			}
			p.mu.Unlock()
			return e.proxy, e.note, nil
		}
		p.mu.Unlock()
		<-e.ready
		if e.proxy == nil {
			return nil, e.note, nil
		}
		if e.dir == g.Dir && e.alive() {
			return e.proxy, "", nil
		}
		// WhyNot: 起こしている途中の古い子を待たずに止めない — まだ stop が無く、起こし終えた子が誰にも止められずに残る。
		p.mu.Lock()
		if p.entries[g.Name] == e {
			delete(p.entries, g.Name)
		}
		p.mu.Unlock()
		e.stop()
	}
}

func (p *gameProxies) start(e *gameProxy, g fgehome.Game) {
	defer close(e.ready)
	if info, err := os.Stat(g.Dir); err != nil || !info.IsDir() {
		e.note = "フォルダがありません"
		return
	}
	v, err := p.launcher.Version(g.Dir)
	if err != nil || v < 1 {
		e.note = "このゲームの engine はダッシュボードより前の版です。版を上げると開けます（ゲームのフォルダで make engine-upgrade）"
		if errors.Is(err, errNoFge) {
			e.note = "bin/fge が配られていません（ゲームのフォルダで make status を打つと配り直します）"
		}
		return
	}
	port, done, stop, err := p.launcher.Start(g.Dir, "/"+g.Name+"/")
	if err != nil {
		e.note = "このゲームの頁を起こせませんでした: " + err.Error()
		return
	}
	e.done, e.stop = done, stop
	e.proxy = childProxy(port)
}

// note は g の子を起こせなかった理由（起こしていない・起こせた時は空）。
func (p *gameProxies) note(name string) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.notes[name]
}

func (p *gameProxies) stopAll() {
	p.mu.Lock()
	var ready []*gameProxy
	for name, e := range p.entries {
		delete(p.entries, name)
		select {
		case <-e.ready:
			ready = append(ready, e)
		default:
			// WhyNot: 起こしている途中の子を待たない — 待ち始めるまで最大 30 秒かかり、Ctrl-C がその間返らない。起こし終えた get がフラグを見て止める。
			e.stopped = true
		}
	}
	p.mu.Unlock()
	for _, e := range ready {
		if e.stop != nil {
			e.stop()
		}
	}
}

// childProxy は 127.0.0.1:<port> の子へ中継する。全体の fge が自分の Host と Origin を見た後で、両方を子の物に書き換える。
// WhyNot: 子に 8790 の Origin を許させない — 全体の fge が 8790 で待てずに別の番号へ移った時に、子が POST を断る。
func childProxy(port int) http.Handler {
	target := "127.0.0.1:" + strconv.Itoa(port)
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = "http"
			pr.Out.URL.Host = target
			pr.Out.Host = target
			if pr.In.Header.Get("Origin") != "" {
				pr.Out.Header.Set("Origin", "http://"+target)
			}
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "ゲームの頁に届きません（開き直すと起こし直します）: "+err.Error(), http.StatusBadGateway)
		},
	}
}

var errNoFge = errors.New("bin/fge-go がありません")

// execLauncher はゲームの bin/fge-go を直に起こす。
// WhyNot: bin/fge（sh の 1 行）を通さない — Windows の素の環境に sh が無い。中身は bin/fge-go を呼ぶだけ。
type execLauncher struct {
	log  io.Writer
	goos string
	// find はゲームのフォルダから起こす実行ファイルを決める（nil なら fgeFor）。
	find func(dir string) (string, error)
}

func (l execLauncher) exe(dir string) (string, error) {
	if l.find != nil {
		return l.find(dir)
	}
	return fgeFor(l.goos, dir)
}

// fgeFor は dir のゲームが使う fge-go。engine のリポの templates/<名> は bin/fge を持たないので engine の物を使う。
// WhyNot: Windows で拡張子の無い fge-go を見ない — それは macOS か Linux の物で、起こすと「Win32 アプリではない」で落ちる。
func fgeFor(goos, dir string) (string, error) {
	name := "fge-go"
	if goos == "windows" {
		name = "fge-go.exe"
	}
	cands := []string{filepath.Join(dir, "bin")}
	if up := filepath.Dir(filepath.Dir(dir)); isEngineRoot(up) && filepath.Base(filepath.Dir(dir)) == "templates" {
		cands = append(cands, filepath.Join(up, "bin"))
	}
	for _, bin := range cands {
		p := filepath.Join(bin, name)
		if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() {
			return p, nil
		}
	}
	return "", errNoFge
}

func (l execLauncher) Version(dir string) (int, error) {
	fge, err := l.exe(dir)
	if err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, fge, "dashboard", "--version")
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return 0, err
	}
	line, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	return strconv.Atoi(strings.TrimSpace(line))
}

// execChild は起こした子 1 つ。
type execChild struct {
	port  int
	stdin io.Closer
	cmd   *exec.Cmd
	done  chan struct{}
	once  sync.Once
}

func (c *execChild) stop() {
	c.once.Do(func() {
		c.stdin.Close()
		c.cmd.Process.Kill()
	})
}

func (l execLauncher) Start(dir, base string) (int, <-chan struct{}, func(), error) {
	c, err := l.startChild(dir, base)
	if err != nil {
		return 0, nil, nil, err
	}
	return c.port, c.done, c.stop, nil
}

func (l execLauncher) startChild(dir, base string) (*execChild, error) {
	fge, err := l.exe(dir)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(fge, "dashboard", "--port", "0", "--no-open", "--base", base)
	cmd.Dir = dir
	cmd.Stderr = prefixWriter(l.log, base)
	// WhyNot: 子の stdin を開けたまま渡す — 全体の fge が kill で落ちても、子は stdin が閉じたのを見て自分で止まる。
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	c := &execChild{stdin: stdin, cmd: cmd, done: make(chan struct{})}
	ports := make(chan int, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		sent := false
		for sc.Scan() {
			line := sc.Text()
			if !sent && strings.HasPrefix(line, ListenPrefix) {
				_, p, _ := strings.Cut(strings.TrimPrefix(line, ListenPrefix), ":")
				if n, err := strconv.Atoi(strings.TrimSpace(p)); err == nil {
					ports <- n
					sent = true
					continue
				}
			}
			fmt.Fprintf(l.log, "[%s] %s\n", strings.Trim(base, "/"), line)
		}
	}()
	go func() {
		cmd.Wait()
		close(c.done)
	}()
	select {
	case c.port = <-ports:
		return c, nil
	case <-c.done:
		return nil, fmt.Errorf("bin/fge dashboard が待ち始める前に終わりました")
	case <-time.After(30 * time.Second):
		c.stop()
		return nil, fmt.Errorf("bin/fge dashboard が 30 秒待っても待ち始めませんでした")
	}
}

type linePrefixWriter struct {
	mu     sync.Mutex
	w      io.Writer
	prefix string
	buf    []byte
}

func prefixWriter(w io.Writer, base string) io.Writer {
	return &linePrefixWriter{w: w, prefix: "[" + strings.Trim(base, "/") + "] "}
}

func (p *linePrefixWriter) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.buf = append(p.buf, b...)
	for {
		i := strings.IndexByte(string(p.buf), '\n')
		if i < 0 {
			break
		}
		fmt.Fprintf(p.w, "%s%s\n", p.prefix, p.buf[:i])
		p.buf = p.buf[i+1:]
	}
	return len(b), nil
}
