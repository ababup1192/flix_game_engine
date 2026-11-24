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
	// done は子が終わると閉じる。stop は子を止める。
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
	port  int
	done  <-chan struct{}
	stop  func()
	note  string
	proxy http.Handler
}

func newGameProxies(l Launcher) *gameProxies {
	return &gameProxies{launcher: l, entries: map[string]*gameProxy{}, notes: map[string]string{}}
}

// get は g の子の中継を返す。中継できなければ nil と、頁に出す理由。
func (p *gameProxies) get(g fgehome.Game) (http.Handler, string) {
	p.mu.Lock()
	e, ok := p.entries[g.Name]
	if ok && e.dir != g.Dir {
		ok = false
	}
	if ok {
		select {
		case <-e.ready:
			if e.done != nil {
				select {
				case <-e.done:
					ok = false
				default:
				}
			}
		default:
		}
	}
	if !ok {
		if e != nil && e.stop != nil {
			e.stop()
		}
		e = &gameProxy{dir: g.Dir, ready: make(chan struct{})}
		p.entries[g.Name] = e
		p.mu.Unlock()
		p.start(e, g)
	} else {
		p.mu.Unlock()
	}
	<-e.ready
	p.mu.Lock()
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
	return e.proxy, e.note
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
	base := "/" + g.Name + "/"
	port, done, stop, err := p.launcher.Start(g.Dir, base)
	if err != nil {
		e.note = "このゲームの頁を起こせませんでした: " + err.Error()
		return
	}
	e.port, e.done, e.stop = port, done, stop
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
	defer p.mu.Unlock()
	for name, e := range p.entries {
		select {
		case <-e.ready:
			if e.stop != nil {
				e.stop()
			}
		default:
		}
		delete(p.entries, name)
	}
}

// childProxy は 127.0.0.1:<port> の子へ中継する。
// 子は自分の番号で Host と Origin を見るので、全体の fge が自分の Host と Origin を先に見た後で、両方を子の物に書き換える。
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
	log io.Writer
}

// fgeFor は dir のゲームが使う fge-go。engine のリポの templates/<名> は bin/fge を持たないので engine の物を使う。
func fgeFor(dir string) (string, error) {
	cands := []string{filepath.Join(dir, "bin")}
	if up := filepath.Dir(filepath.Dir(dir)); isEngineRoot(up) && filepath.Base(filepath.Dir(dir)) == "templates" {
		cands = append(cands, filepath.Join(up, "bin"))
	}
	for _, bin := range cands {
		for _, name := range []string{"fge-go", "fge-go.exe"} {
			p := filepath.Join(bin, name)
			if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() {
				return p, nil
			}
		}
	}
	return "", errNoFge
}

func (l execLauncher) Version(dir string) (int, error) {
	fge, err := fgeFor(dir)
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

func (l execLauncher) Start(dir, base string) (int, <-chan struct{}, func(), error) {
	fge, err := fgeFor(dir)
	if err != nil {
		return 0, nil, nil, err
	}
	cmd := exec.Command(fge, "dashboard", "--port", "0", "--no-open", "--base", base)
	cmd.Dir = dir
	cmd.Stderr = prefixWriter(l.log, base)
	// WhyNot: 子の stdin を開けたまま渡す — 全体の fge が kill で落ちても、子は stdin が閉じたのを見て自分で止まる。
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return 0, nil, nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return 0, nil, nil, err
	}
	if err := cmd.Start(); err != nil {
		return 0, nil, nil, err
	}
	done := make(chan struct{})
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
		close(done)
	}()
	stop := func() {
		stdin.Close()
		cmd.Process.Kill()
	}
	select {
	case p := <-ports:
		return p, done, stop, nil
	case <-done:
		return 0, nil, nil, fmt.Errorf("bin/fge dashboard が待ち始める前に終わりました")
	case <-time.After(30 * time.Second):
		stop()
		return 0, nil, nil, fmt.Errorf("bin/fge dashboard が 30 秒待っても待ち始めませんでした")
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
