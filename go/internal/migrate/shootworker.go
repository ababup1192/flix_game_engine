package migrate

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/resident"
)

// 常駐で流す（plans/novel-migrate-scale.md の E1）: 並べる本数ぶんの JVM を App.Headless の待ち受け（E2e.serveHeadless）で起こし、
// flow とセーブの読み戻しを /run で 1 本ずつ頼む。JVM の起動・字と Doc の用意・JIT の温まりを本数ぶんだけで済ませる。
//
// WhyNot: bin/fge resident（ゲームの根に 1 つの常駐）を使わない — 1 つの常駐は /run を 1 本ずつしか流さず、並べられない。
// 常駐の印（HEADLESS_RESIDENT=1）を付けないのは、付けると build/headless/resident.json を書き、Studio や headless-run が
// この JVM へ頼みに来るため。印の無い待ち受けは入口の出力をその JVM の標準出力へ書くので、JVM ごとのログから切り出す。

// workerReadyWait は JVM が待ち受けを開くまで待つ秒（jar の読み込みと温めの 1 枚。機械が混んでいると長い）。
const workerReadyWait = 5 * time.Minute

// serveEntry は待ち受けの入口（bin/headless-run の常駐の入口と同じ決め方）。
func serveEntry() string {
	if v := os.Getenv("HEADLESS_RESIDENT_ENTRY"); v != "" {
		return v
	}
	return "E2e.serveHeadless"
}

type shootWorker struct {
	cmd    *exec.Cmd
	port   int
	log    string
	exited chan struct{}
	http   *http.Client
}

// startWorker は run（headless-run の呼び口）で待ち受けの JVM を起こし、entries の入口が全部あるのを確かめる。
func startWorker(run string, base []string, log string, entries []string) (*shootWorker, error) {
	f, err := os.Create(log)
	if err != nil {
		return nil, err
	}
	var env []string
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "HEADLESS_RESIDENT", "HEADLESS_ENTRIES", "HEADLESS_PORT", "FGE_SHOT":
			continue
		}
		env = append(env, kv)
	}
	cmd := exec.Command("bash", "-c", run+" "+serveEntry())
	cmd.Env = append(env, "HEADLESS_PORT=0")
	cmd.Stdout, cmd.Stderr = f, f
	if err := cmd.Start(); err != nil {
		f.Close()
		return nil, err
	}
	f.Close()
	w := &shootWorker{cmd: cmd, log: log, exited: make(chan struct{}), http: &http.Client{}}
	go func() { _ = cmd.Wait(); close(w.exited) }()
	deadline := time.Now().Add(workerReadyWait)
	for w.port == 0 {
		if port, ok := readyPortIn(log); ok {
			w.port = port
			break
		}
		if time.Now().After(deadline) {
			w.kill()
			return nil, fmt.Errorf("待ち受けが %.0f 秒で開かない（%s）", workerReadyWait.Seconds(), log)
		}
		select {
		case <-w.exited:
			return nil, fmt.Errorf("待ち受けの JVM が開く前に終わった（%s）", log)
		case <-time.After(200 * time.Millisecond):
		}
	}
	h, err := w.hello()
	if err != nil {
		w.kill()
		return nil, err
	}
	for _, e := range entries {
		if _, ok := h.FindJob(e); !ok {
			w.quit()
			return nil, errNoEntry{fmt.Sprintf("待ち受けの束に %s が無い（%s の jobs）", e, serveEntry())}
		}
	}
	return w, nil
}

// errNoEntry は待ち受けの束に頼みたい入口が無い（ゲームの FlowVideo が古い）。どの席でも同じなので、全部の席で常駐をやめる。
type errNoEntry struct{ why string }

func (e errNoEntry) Error() string { return e.why }

func readyPortIn(path string) (int, bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if port, _, ok := resident.ParseReady(line); ok {
			return port, true
		}
	}
	return 0, false
}

func (w *shootWorker) url(path string) string {
	return "http://127.0.0.1:" + strconv.Itoa(w.port) + path
}

func (w *shootWorker) hello() (resident.Hello, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, w.url("/hello"), nil)
	if err != nil {
		return resident.Hello{}, err
	}
	resp, err := w.http.Do(req)
	if err != nil {
		return resident.Hello{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return resident.Hello{}, err
	}
	return resident.ParseHello(string(body))
}

// do は job を /run で流し、入口の終了コードを返す。ok が偽なら待ち受けがもう使えない（落ちた・古い jar・メモリ切れ）ので、
// 呼ぶ側は新しい JVM で流し直す。入口の出力は、この JVM のログのうち流している間に増えた所を job.Log へ写す。
func (w *shootWorker) do(job *shootJob, env []string) (code int, ok bool) {
	start := fileSize(w.log)
	body := resident.RunBody(resident.EnvMap(env))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		select {
		case <-w.exited:
			cancel()
		case <-ctx.Done():
		}
	}()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url("/run?entry="+url.QueryEscape(job.entry)), strings.NewReader(body))
	if err != nil {
		return 0, false
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	end, code := resident.EndBroken, 0
	if resp, err := w.http.Do(req); err == nil {
		r := bufio.NewReader(resp.Body)
		for {
			line, err := r.ReadString('\n')
			if kind, text := resident.ParseLine(strings.TrimRight(line, "\r\n")); kind == resident.LineEnd {
				end, code = resident.ParseEnd(text)
				break
			}
			if err != nil {
				break
			}
		}
		resp.Body.Close()
	}
	copyLogTail(w.log, start, job.Log)
	return code, end == resident.EndExit
}

// copyLogTail は src の from バイト目から後ろを dst へ書く。
func copyLogTail(src string, from int64, dst string) {
	in, err := os.Open(src)
	if err != nil {
		return
	}
	defer in.Close()
	if _, err := in.Seek(from, io.SeekStart); err != nil {
		return
	}
	out, err := os.Create(dst)
	if err != nil {
		return
	}
	defer out.Close()
	_, _ = io.Copy(out, in)
}

func (w *shootWorker) quit() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url("/quit"), nil); err == nil {
		if resp, err := w.http.Do(req); err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
	}
	select {
	case <-w.exited:
	case <-time.After(10 * time.Second):
		w.kill()
	}
}

func (w *shootWorker) kill() {
	if w.cmd.Process != nil {
		_ = w.cmd.Process.Kill()
	}
	<-w.exited
}

// shootPool は並べる本数ぶんの席。席ごとに待ち受けの JVM を 1 本持ち（最初に頼む時に起こす）、使えなくなった席は新しい JVM で流す。
type shootPool struct {
	run      string
	base     []string
	logs     string
	resident bool
	entries  []string
	workers  []*shootWorker
	broken   []bool
	notes    chan string
	mu       sync.Mutex
}

func newShootPool(run string, base []string, logs string, seats int, resident bool, entries []string) *shootPool {
	return &shootPool{run: run, base: base, logs: logs, resident: resident, entries: entries,
		workers: make([]*shootWorker, seats), broken: make([]bool, seats), notes: make(chan string, 64)}
}

// exec は席 seat で job を流す（席は同時に 1 本の糸だけが使う）。
func (p *shootPool) exec(seat int, job *shootJob) {
	if !p.useResident() || p.broken[seat] {
		runShootJob(p.run, p.base, job)
		return
	}
	if p.workers[seat] == nil {
		w, err := startWorker(p.run, p.base, filepath.Join(p.logs, fmt.Sprintf("worker-%d.log", seat)), p.entries)
		if err != nil {
			p.broken[seat] = true
			if _, ok := err.(errNoEntry); ok {
				p.mu.Lock()
				p.resident = false
				p.mu.Unlock()
			}
			p.note(fmt.Sprintf("席 %d は常駐を使えない（%v）— 新しい JVM で流す", seat, err))
			runShootJob(p.run, p.base, job)
			return
		}
		p.workers[seat] = w
	}
	t0 := time.Now()
	code, ok := p.workers[seat].do(job, append(append([]string{}, p.base...), job.env...))
	if !ok {
		p.workers[seat].kill()
		p.workers[seat], p.broken[seat] = nil, true
		p.note(fmt.Sprintf("席 %d の常駐が %s %s の途中で使えなくなった — 新しい JVM で流し直す", seat, job.Kind, job.Name))
		runShootJob(p.run, p.base, job)
		return
	}
	job.Code = code
	if job.after != nil {
		if err := job.after(); err != nil {
			if f, ferr := os.OpenFile(job.Log, os.O_APPEND|os.O_WRONLY, 0o644); ferr == nil {
				fmt.Fprintf(f, "migrate shoot: %v\n", err)
				f.Close()
			}
			if job.Code == 0 {
				job.Code = 1
			}
		}
	}
	job.Seconds = time.Since(t0).Seconds()
}

func (p *shootPool) useResident() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.resident
}

func (p *shootPool) note(s string) {
	select {
	case p.notes <- s:
	default:
	}
}

// close は待ち受けの JVM を全部畳む。
func (p *shootPool) close() {
	for i, w := range p.workers {
		if w != nil {
			w.quit()
			p.workers[i] = nil
		}
	}
}
