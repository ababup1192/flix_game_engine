package cdp

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// EnvChrome は Chrome の実行ファイルを直に指す環境変数。見つける順の先頭。
const EnvChrome = "FGE_CHROME"

// chromeCandidates は探す場所を順に返す（見つからなかった時の知らせにもそのまま出す）。
func chromeCandidates() []string {
	var c []string
	if v := os.Getenv(EnvChrome); v != "" {
		c = append(c, v)
	}
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "darwin":
		for _, app := range []string{
			"Google Chrome.app/Contents/MacOS/Google Chrome",
			"Chromium.app/Contents/MacOS/Chromium",
			"Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
			"Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
		} {
			c = append(c, filepath.Join("/Applications", app))
			if home != "" {
				c = append(c, filepath.Join(home, "Applications", app))
			}
		}
	case "windows":
		for _, base := range []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)"), os.Getenv("LocalAppData")} {
			if base != "" {
				c = append(c, filepath.Join(base, `Google\Chrome\Application\chrome.exe`))
			}
		}
	}
	for _, name := range []string{"google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome"} {
		c = append(c, "PATH:"+name)
	}
	return c
}

// FindChrome は手元の Chrome（Chromium）の実行ファイルを探す。見つからなければ探した場所を全部並べたエラー。
func FindChrome() (string, error) {
	tried := chromeCandidates()
	for _, cand := range tried {
		if name, ok := strings.CutPrefix(cand, "PATH:"); ok {
			if p, err := exec.LookPath(name); err == nil {
				return p, nil
			}
			continue
		}
		if info, err := os.Stat(cand); err == nil && !info.IsDir() {
			return cand, nil
		}
	}
	return "", fmt.Errorf("Chrome が見つからない。探した場所:\n  %s\n%s で実行ファイルを直に指せる",
		strings.Join(tried, "\n  "), EnvChrome)
}

// browser は自分が起こした Chrome 1 つ。止めるのはこのプロセスの組だけ。
type browser struct {
	cmd         *exec.Cmd
	userDataDir string
	port        int
	browserWS   string
	exited      chan struct{}
	stderr      *tailBuffer
}

func chromeArgs(userDataDir string, width, height int) []string {
	return []string{
		"--headless=new",
		"--remote-debugging-port=0",
		"--remote-debugging-address=127.0.0.1",
		"--user-data-dir=" + userDataDir,
		"--no-first-run",
		"--no-default-browser-check",
		"--disable-extensions",
		"--disable-background-networking",
		"--disable-component-update",
		"--disable-sync",
		"--mute-audio",
		"--hide-scrollbars",
		// WhyNot: 隠れた頁の rAF を絞る仕組みを切る。ヘッドレスでも頁が「見えていない」と判断されると rAF が止まり、合図が来ない。
		"--disable-background-timer-throttling",
		"--disable-renderer-backgrounding",
		"--disable-backgrounding-occluded-windows",
		fmt.Sprintf("--window-size=%d,%d", width, height),
		"about:blank",
	}
}

func launchChrome(exe string, width, height int, timeout time.Duration) (*browser, error) {
	dir, err := os.MkdirTemp("", "fge-web-capture-")
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(exe, chromeArgs(dir, width, height)...)
	// WhyNot: 組（process group）を分けるのは、止める時に自分が起こした Chrome とその子（GPU・描画のプロセス）だけへ合図を送るため。
	// 名前で pkill すると人が開いている Chrome まで落ちる。
	cmd.SysProcAttr = sysProcAttrNewGroup()
	tail := &tailBuffer{max: 8 << 10}
	cmd.Stdout = tail
	cmd.Stderr = tail
	if err := cmd.Start(); err != nil {
		os.RemoveAll(dir)
		return nil, fmt.Errorf("Chrome を起こせない: %w", err)
	}
	b := &browser{cmd: cmd, userDataDir: dir, exited: make(chan struct{}), stderr: tail}
	go func() { cmd.Wait(); close(b.exited) }()

	portFile := filepath.Join(dir, "DevToolsActivePort")
	deadline := time.Now().Add(timeout)
	for {
		if data, err := os.ReadFile(portFile); err == nil {
			lines := strings.Split(strings.TrimSpace(string(data)), "\n")
			if len(lines) >= 2 {
				if p, err := strconv.Atoi(strings.TrimSpace(lines[0])); err == nil && p > 0 {
					b.port = p
					b.browserWS = fmt.Sprintf("ws://127.0.0.1:%d%s", p, strings.TrimSpace(lines[1]))
					return b, nil
				}
			}
		}
		select {
		case <-b.exited:
			b.cleanup()
			return nil, fmt.Errorf("Chrome が起きてすぐ止まった:\n%s", tail.String())
		default:
		}
		if time.Now().After(deadline) {
			b.stop()
			return nil, fmt.Errorf("Chrome の CDP の口が %s 以内に開かない:\n%s", timeout, tail.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

type targetInfo struct {
	ID                   string `json:"id"`
	Type                 string `json:"type"`
	URL                  string `json:"url"`
	WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
}

// pageWS は起動時に開いた about:blank の頁の WebSocket の URL を返す。
func (b *browser) pageWS(timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	hc := &http.Client{Timeout: 2 * time.Second}
	for {
		resp, err := hc.Get(fmt.Sprintf("http://127.0.0.1:%d/json/list", b.port))
		if err == nil {
			var targets []targetInfo
			derr := json.NewDecoder(resp.Body).Decode(&targets)
			resp.Body.Close()
			if derr == nil {
				for _, t := range targets {
					if t.Type == "page" && t.WebSocketDebuggerURL != "" {
						return t.WebSocketDebuggerURL, nil
					}
				}
			}
		}
		if time.Now().After(deadline) {
			return "", errors.New("Chrome に頁（page の target）が見当たらない")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// stop は Browser.close で閉じるよう頼み、閉じなければ自分の組へ SIGKILL を送る。作業用のフォルダも消す。
func (b *browser) stop() {
	if ws, err := dialWebSocket(b.browserWS, 2*time.Second); err == nil {
		c := &client{ws: ws}
		_, _ = c.call("Browser.close", nil, 2*time.Second)
		ws.close()
	}
	select {
	case <-b.exited:
	case <-time.After(5 * time.Second):
		killGroup(b.cmd.Process.Pid)
		select {
		case <-b.exited:
		case <-time.After(5 * time.Second):
		}
	}
	b.cleanup()
}

func (b *browser) cleanup() {
	// WhyNot: 消すのは MkdirTemp で自分が作ったフォルダだけ。Chrome の子が掴んでいる間は消し残るが、OS の一時フォルダなので放る。
	os.RemoveAll(b.userDataDir)
}

// tailBuffer は Chrome の出力の末尾だけを持つ（起動に失敗した時の知らせ用）。
type tailBuffer struct {
	mu  sync.Mutex
	max int
	buf []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > t.max {
		t.buf = t.buf[len(t.buf)-t.max:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.buf)
}
