package resident

// 常駐を探し・起こし・頼み・落とす。駄目なら 125 で素の道へ返す。

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

var (
	// InfoFile は常駐が ready の直後に書き、終わる時に消す名乗り（ゲームの根からの相対）。
	InfoFile = filepath.Join("build", "headless", "resident.json")
	lockDir  = filepath.Join("build", "headless", "resident.lock")
	// spawnOut は起こした JVM の標準出力・標準エラーの行き先（ready の行をここで待つ）。
	// WhyNot: パイプで受けないのは、クライアントが先に終わった後も常駐が書き続けるので、
	// 読み手の居ないパイプへ書いて詰まる・落ちるため。resident.log と分けるのは、
	// 常駐が自分で開き直す時に ready の行を読む前に消されないため。
	spawnOut = filepath.Join("build", "headless", "resident.out")
)

// RunOptions は `fge resident run` の引数と行き先。
type RunOptions struct {
	Dir    string
	Entry  string
	Java   string
	Env    map[string]string
	Stdout io.Writer
	Stderr io.Writer
}

type client struct {
	cfg    *Config
	root   string
	env    map[string]string
	stderr io.Writer
	http   *http.Client
}

func newClient(cfg *Config, root string, env map[string]string, stderr io.Writer) *client {
	dialer := &net.Dialer{Timeout: seconds(*cfg.ConnectTimeoutSec)}
	return &client{cfg: cfg, root: root, env: env, stderr: stderr,
		http: &http.Client{Transport: &http.Transport{DialContext: dialer.DialContext, DisableKeepAlives: true}}}
}

func (c *client) debugf(format string, args ...any) {
	if c.env["RESIDENT_DEBUG"] != "" {
		fmt.Fprintf(c.stderr, "[resident] "+format+"\n", args...)
	}
}

// EnvMap は os.Environ を表にする。
func EnvMap(environ []string) map[string]string {
	m := map[string]string{}
	for _, kv := range environ {
		if k, v, ok := strings.Cut(kv, "="); ok {
			m[k] = v
		}
	}
	return m
}

// ResolveRoot は根の絶対パス（symlink を辿った物）。
func ResolveRoot(dir string) (string, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		return real, nil
	}
	return abs, nil
}

// Run は入口を常駐で流し、入口の終了コードか 125 を返す。
func Run(engineRoot string, o RunOptions) int {
	cfg, err := LoadConfig(engineRoot)
	if err != nil {
		fmt.Fprintf(o.Stderr, "[resident] %v — 素の道で流す\n", err)
		return Unusable
	}
	root, err := ResolveRoot(o.Dir)
	if err != nil {
		return Unusable
	}
	c := newClient(cfg, root, o.Env, o.Stderr)
	if o.Entry == cfg.ResidentEntry(o.Env) {
		c.debugf("%s は常駐の入口そのもの", o.Entry)
		return Unusable
	}
	want := Want{Dir: root, Manifest: ReadManifest(root), Env: o.Env, Entry: o.Entry}
	if want.Manifest == "" {
		c.debugf("%s が無い", ManifestFile)
		return Unusable
	}
	port, h, err := c.findOrSpawn(o.Java)
	if err != nil {
		c.debugf("%v", err)
		return Unusable
	}
	switch v, why := Judge(h, want); v {
	case QuitAndRefuse:
		c.debugf("%s — 常駐を落とす", why)
		c.quit(port, h.Pid)
		return Unusable
	case Refuse:
		c.debugf("%s", why)
		return Unusable
	}
	out := c.run(port, o.Entry, o.Stdout, o.Stderr)
	code, notice, after := Settle(out)
	if job, ok := h.FindJob(o.Entry); ok {
		after = AftercareOf(job, after)
	}
	if notice != "" {
		fmt.Fprintln(o.Stderr, notice)
	}
	switch after {
	case QuitResident:
		c.quit(port, h.Pid)
	case KillResident:
		c.kill(h.Pid)
	}
	return code
}

// findOrSpawn は生きている常駐の port と /hello を返す。居なければ起こす。
func (c *client) findOrSpawn(java string) (int, Hello, error) {
	port, pid, err := c.readInfo()
	if err == nil {
		if h, herr := c.hello(port); herr == nil {
			return port, h, nil
		}
		if pid > 0 && hooks.PidAlive(pid) {
			return 0, Hello{}, fmt.Errorf("常駐 pid %d が /hello に答えない", pid)
		}
		c.forget()
	}
	port, err = c.spawnLocked(java)
	if err != nil {
		return 0, Hello{}, err
	}
	h, err := c.hello(port)
	return port, h, err
}

func (c *client) readInfo() (port, pid int, err error) {
	raw, err := os.ReadFile(filepath.Join(c.root, InfoFile))
	if err != nil {
		return 0, 0, err
	}
	var info map[string]string
	if err := json.Unmarshal(raw, &info); err != nil {
		return 0, 0, err
	}
	pid, _ = strconv.Atoi(info["pid"])
	port, err = strconv.Atoi(info["port"])
	return port, pid, err
}

func (c *client) baseURL(port int) string { return "http://127.0.0.1:" + strconv.Itoa(port) }

func (c *client) hello(port int) (Hello, error) {
	ctx, cancel := context.WithTimeout(context.Background(), seconds(*c.cfg.HelloTimeoutSec))
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL(port)+"/hello", nil)
	if err != nil {
		return Hello{}, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return Hello{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return Hello{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return Hello{}, fmt.Errorf("/hello が %d", resp.StatusCode)
	}
	h, err := ParseHello(string(body))
	if err != nil {
		return Hello{}, err
	}
	if real, err := filepath.EvalSymlinks(h.Dir); err == nil {
		h.Dir = real
	}
	return h, nil
}

// run は POST /run を流し、行を写しながら終わり方を見る。
func (c *client) run(port int, entry string, stdout, stderr io.Writer) Outcome {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	o := Outcome{End: EndBroken, Entry: entry}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.baseURL(port)+"/run?entry="+url.QueryEscape(entry), strings.NewReader(RunBody(c.env)))
	if err != nil {
		return o
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	lines := make(chan string)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		resp, err := c.http.Do(req)
		if err != nil {
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return
		}
		r := bufio.NewReader(resp.Body)
		for {
			line, err := r.ReadString('\n')
			if line != "" {
				select {
				case lines <- strings.TrimRight(line, "\r\n"):
				case <-ctx.Done():
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return relay(lines, finished, c.cfg.SilentLimit(c.env), stdout, stderr, o)
}

// relay は行を写し、`x` の行・流れの切れ目・沈黙のどれかで止まる。
func relay(lines <-chan string, finished <-chan struct{}, silent time.Duration,
	stdout, stderr io.Writer, o Outcome) Outcome {
	timer := time.NewTimer(silent)
	defer timer.Stop()
	for {
		select {
		case line := <-lines:
			kind, text := ParseLine(line)
			switch kind {
			case LineOut:
				fmt.Fprintln(stdout, text)
				o.Emitted = true
			case LineErr:
				fmt.Fprintln(stderr, text)
				o.Emitted = true
			case LineEnd:
				o.End, o.Code = ParseEnd(text)
				return o
			default:
				o.End = EndBroken
				return o
			}
			if !timer.Stop() {
				<-timer.C
			}
			timer.Reset(silent)
		case <-finished:
			o.End = EndBroken
			return o
		case <-timer.C:
			o.End = EndSilent
			return o
		}
	}
}

// quit は常駐に /quit を頼み、終わるのを少し待つ。
func (c *client) quit(port int, pidText string) {
	ctx, cancel := context.WithTimeout(context.Background(), seconds(*c.cfg.HelloTimeoutSec))
	defer cancel()
	if req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL(port)+"/quit", nil); err == nil {
		if resp, err := c.http.Do(req); err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
	}
	pid, _ := strconv.Atoi(pidText)
	deadline := time.Now().Add(seconds(*c.cfg.QuitWaitSec))
	for pid > 0 && hooks.PidAlive(pid) && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if pid > 0 && hooks.PidAlive(pid) {
		c.kill(pidText)
		return
	}
	c.forget()
}

func (c *client) kill(pidText string) {
	if pid, err := strconv.Atoi(pidText); err == nil && pid > 0 {
		if proc, err := os.FindProcess(pid); err == nil {
			_ = proc.Kill()
		}
	}
	c.forget()
}

// forget は落ちた常駐の名乗りと数の印を片付ける。
// WhyNot: 常駐が書いた resident.json をクライアントが消すのは、kill された常駐は
// 自分で消せず、残ると次の人が毎回つながらない port へ話しかけるため。
func (c *client) forget() {
	_ = os.Remove(filepath.Join(c.root, InfoFile))
	_ = os.RemoveAll(c.stateDir())
}

// markedPid はこの根で前に起こした常駐の pid（印が無ければ 0）。
func (c *client) markedPid() int {
	raw, err := os.ReadFile(filepath.Join(c.stateDir(), "pid"))
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
	return pid
}

// stateDir は全部の根の常駐を数えるための、この根の印の置き場。
func (c *client) stateDir() string {
	sum := sha1.Sum([]byte(c.root))
	return filepath.Join(expandHome(*c.cfg.CacheDir), hex.EncodeToString(sum[:])[:*c.cfg.StateHashLen])
}

func expandHome(path string) string {
	rest, ok := strings.CutPrefix(path, "~/")
	if !ok {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	return filepath.Join(home, filepath.FromSlash(rest))
}

// LiveResidents は印の置き場から、生きている常駐の数を数える。
func LiveResidents(cacheDir string) int {
	entries, err := os.ReadDir(expandHome(cacheDir))
	if err != nil {
		return 0
	}
	live := 0
	for _, e := range entries {
		raw, err := os.ReadFile(filepath.Join(expandHome(cacheDir), e.Name(), "pid"))
		if err != nil {
			continue
		}
		if pid, err := strconv.Atoi(strings.TrimSpace(string(raw))); err == nil && pid > 0 && hooks.PidAlive(pid) {
			live++
		}
	}
	return live
}

// spawnLocked は resident.lock を取って常駐を起こす。鍵を他の人が持っていれば、その人の常駐が
// 答えるのを待つ（2 人が同時に起こさない）。
func (c *client) spawnLocked(java string) (int, error) {
	lock := filepath.Join(c.root, lockDir)
	if !takeLock(lock) {
		deadline := time.Now().Add(seconds(*c.cfg.ReadyWaitSec))
		for time.Now().Before(deadline) {
			if port, _, err := c.readInfo(); err == nil {
				if _, err := c.hello(port); err == nil {
					return port, nil
				}
			}
			time.Sleep(200 * time.Millisecond)
		}
		return 0, errors.New("他の人が常駐を起こしているが答えない")
	}
	defer releaseLock(lock)
	// 鍵を待つ間に他の人が起こし終えていれば、もう 1 本は立てない。答えなくても pid が
	// 生きていれば立てない（同じ根に 2 つ立てると、片方の resident.json がもう片方を指す）。
	if port, pid, err := c.readInfo(); err == nil {
		if _, err := c.hello(port); err == nil {
			return port, nil
		}
		if pid > 0 && hooks.PidAlive(pid) {
			return 0, fmt.Errorf("常駐 pid %d が居るが /hello に答えない", pid)
		}
	}
	if pid := c.markedPid(); pid > 0 && hooks.PidAlive(pid) {
		return 0, fmt.Errorf("この根で起こした pid %d がまだ生きている（ready 前か名乗りを消した）", pid)
	}
	if live, max := LiveResidents(*c.cfg.CacheDir), c.cfg.MaxResidents(); live >= max {
		return 0, fmt.Errorf("常駐の数が上限（%d/%d・%s）", live, max, *c.cfg.MaxDaemons.EnvVar)
	}
	return c.spawn(java)
}

func takeLock(lock string) bool {
	for attempt := 0; attempt < 2; attempt++ {
		if err := os.Mkdir(lock, 0o755); err == nil {
			_ = os.WriteFile(filepath.Join(lock, "pid"), []byte(strconv.Itoa(os.Getpid())), 0o644)
			return true
		}
		raw, err := os.ReadFile(filepath.Join(lock, "pid"))
		owner, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
		if err == nil && owner > 0 && hooks.PidAlive(owner) {
			return false
		}
		// WhyNot: 外すのを別名への mv 1 回にするのは、2 人が同時に古い鍵を見ても外せるのは
		// 1 人で、その後に取り直された新しい鍵を消さないため（headless-run の鍵と同じ）。
		stale := fmt.Sprintf("%s.stale.%d", lock, os.Getpid())
		if os.Rename(lock, stale) == nil {
			_ = os.RemoveAll(stale)
		}
	}
	return false
}

func releaseLock(lock string) {
	_ = os.Remove(filepath.Join(lock, "pid"))
	_ = os.Remove(lock)
}

// spawn は常駐の JVM を切り離して起こし、ready の行を待って port を返す。
func (c *client) spawn(java string) (int, error) {
	if java == "" {
		java = "java"
	}
	if _, err := os.Stat(filepath.Join(c.root, "build", "headless", "headless.jar")); err != nil {
		return 0, errors.New("build/headless/headless.jar が無い")
	}
	outPath := filepath.Join(c.root, spawnOut)
	f, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return 0, err
	}
	cmd := exec.Command(java, JavaArgs(c.env["HEADLESS_JAVA_OPTS"], c.cfg.HeapCapMB(c.env))...)
	cmd.Dir = c.root
	cmd.Env = SpawnEnv(c.env, c.cfg.ResidentEntry(c.env), c.env["HEADLESS_ENTRIES"])
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, f, f
	// 呼んだ make への Ctrl+C を常駐が巻き添えで受けないよう切り離す。
	hooks.Detach(cmd)
	err = cmd.Start()
	f.Close()
	if err != nil {
		return 0, err
	}
	if sd := c.stateDir(); os.MkdirAll(sd, 0o755) == nil {
		_ = os.WriteFile(filepath.Join(sd, "pid"), []byte(strconv.Itoa(cmd.Process.Pid)), 0o644)
		_ = os.WriteFile(filepath.Join(sd, "dir"), []byte(c.root), 0o644)
	}
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()
	deadline := time.Now().Add(seconds(*c.cfg.ReadyWaitSec))
	for time.Now().Before(deadline) {
		if port, ok := readyPort(outPath); ok {
			return port, nil
		}
		select {
		case <-exited:
			c.forget()
			return 0, fmt.Errorf("常駐が ready の前に終わった（%s を見る）", spawnOut)
		case <-time.After(100 * time.Millisecond):
		}
	}
	_ = cmd.Process.Kill()
	c.forget()
	return 0, fmt.Errorf("常駐が %.0f 秒で ready にならなかった（%s を見る）", *c.cfg.ReadyWaitSec, spawnOut)
}

func readyPort(path string) (int, bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if port, _, ok := ParseReady(line); ok {
			return port, true
		}
	}
	return 0, false
}

// Status は常駐の有無と /hello の中身を書く。all なら印の置き場から機械の全部の根を並べる。
func Status(engineRoot, dir string, all bool, out io.Writer) int {
	cfg, err := LoadConfig(engineRoot)
	if err != nil {
		fmt.Fprintf(out, "[resident] %v\n", err)
		return 2
	}
	fmt.Fprintf(out, "常駐の数: %d / 上限 %d（全部の根・%s で変える）\n",
		LiveResidents(*cfg.CacheDir), cfg.MaxResidents(), *cfg.MaxDaemons.EnvVar)
	roots := []string{}
	if all {
		roots = markedRoots(*cfg.CacheDir)
	} else {
		root, err := ResolveRoot(dir)
		if err != nil {
			return 2
		}
		roots = append(roots, root)
	}
	if all && len(roots) == 0 {
		fmt.Fprintln(out, "常駐なし")
	}
	for _, root := range roots {
		c := newClient(cfg, root, EnvMap(os.Environ()), out)
		fmt.Fprintln(out, c.statusLine())
	}
	return 0
}

// statusLine は 1 つの根の常駐の様子を 1 行にする。
func (c *client) statusLine() string {
	port, pid, err := c.readInfo()
	if err != nil {
		return c.root + ": 常駐なし"
	}
	if pid <= 0 || !hooks.PidAlive(pid) {
		return fmt.Sprintf("%s: 常駐なし（pid %d は居ない・%s が残っている）", c.root, pid, InfoFile)
	}
	h, err := c.hello(port)
	if err != nil {
		return fmt.Sprintf("%s: pid %d port %d rss %s — /hello に答えない（%v）", c.root, pid, port, rssText(pid), err)
	}
	busy := h.Busy
	if busy == "" {
		busy = "（空き）"
	}
	return fmt.Sprintf("%s: pid %d port %d rss %s idle.left %s idle.window %s served %s busy %s manifest %s",
		c.root, pid, port, rssText(pid), secondsText(h.IdleLeft), secondsText(h.IdleWindow),
		orNone(h.Served), busy, sameText(h.Manifest == ReadManifest(c.root)))
}

// markedRoots は印の置き場に残っている根（字の順）。
func markedRoots(cacheDir string) []string {
	base := expandHome(cacheDir)
	entries, err := os.ReadDir(base)
	if err != nil {
		return nil
	}
	var roots []string
	for _, e := range entries {
		if raw, err := os.ReadFile(filepath.Join(base, e.Name(), "dir")); err == nil {
			roots = append(roots, strings.TrimSpace(string(raw)))
		}
	}
	return roots
}

// rssText は ps で引いた常駐の RSS（MB）。引けなければ ?。
//
// WhyNot: PATH の ps だけを引かない — devbox（nix）の procps の ps は macOS で rss を
// 「requires entitlement」と断るので、OS の /bin/ps を先に引く。
func rssText(pid int) string {
	for _, ps := range []string{"/bin/ps", "ps"} {
		out, err := exec.Command(ps, "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
		if err != nil {
			continue
		}
		if kb, err := strconv.Atoi(strings.TrimSpace(string(out))); err == nil {
			return fmt.Sprintf("%dMB", kb/1024)
		}
	}
	return "?"
}

func secondsText(n int) string {
	if n < 0 {
		return "?"
	}
	return strconv.Itoa(n) + "s"
}

func sameText(same bool) string {
	if same {
		return "jar と同じ"
	}
	return "jar と違う"
}

// Stop は常駐に /quit を頼む（答えなければ pid で落とす）。居なければ何もせず 0。
//
// WhyNot: 居ない時に何も書かないのは、make の口が成否にかかわらず毎回最後に流すので、
// 1 行でも出すと素の道の出力と見た目がずれるため。
func Stop(engineRoot, dir string, out io.Writer) int {
	cfg, err := LoadConfig(engineRoot)
	if err != nil {
		return 0
	}
	root, err := ResolveRoot(dir)
	if err != nil {
		return 0
	}
	c := newClient(cfg, root, EnvMap(os.Environ()), out)
	port, pid, err := c.readInfo()
	if err != nil {
		return 0
	}
	if pid <= 0 || !hooks.PidAlive(pid) {
		c.forget()
		return 0
	}
	c.quit(port, strconv.Itoa(pid))
	fmt.Fprintf(out, "[resident] 停止: %s\n", root)
	return 0
}

func orNone(s string) string {
	if s == "" {
		return "（無い）"
	}
	return s
}
