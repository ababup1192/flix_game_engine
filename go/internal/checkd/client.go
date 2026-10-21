package checkd

// クライアント側 — 常駐を探し、話し、駄目なら素の CLI に落ちる。

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

// enginePat は local.mk の「ENGINE := /path/to/engine」の行。
var enginePat = regexp.MustCompile(`^\s*ENGINE\s*[?:]*=\s*(.+?)\s*$`)

// flixBin はこのパッケージが使う flix コンパイラの呼び口を返す。
//
// WhyNot: Windows の「JAVA + bin/flix.jar」経路をまだ知らない (repl 起動も
// 素の CLI への逃げ道も落ちる)。そのためテンプレの make check は Windows で
// CHECKD := 0 に固定している。教えるなら local.mk の JAVA と
// $(ENGINE)/bin/flix.jar から組み立てる。
func flixBin(root, pkg string) string {
	// ゲーム側の bin/flix (symlink 含む) を優先。
	if cand := filepath.Join(pkg, "bin", "flix"); isExec(cand) {
		return cand
	}
	// 配った先 (ゲームの bin/) に flix は居ないので、engine の場所を
	// 環境変数 ENGINE → local.mk から引く (game Makefile と同じ解決順)。
	engine := os.Getenv("ENGINE")
	if engine == "" {
		if f, err := os.Open(filepath.Join(pkg, "local.mk")); err == nil {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				if m := enginePat.FindStringSubmatch(sc.Text()); m != nil {
					engine = m[1]
				}
			}
			f.Close()
		}
	}
	if engine != "" {
		if cand := filepath.Join(engine, "bin", "flix"); isExec(cand) {
			return cand
		}
	}
	return filepath.Join(root, "bin", "flix")
}

// hasSymlinkedSources は src/ の .flix を symlink で束ねたパッケージか (engine_full がこれ)。
//
// WhyNot: 温めた repl はこの形のソースの書き換えを読み直さず、直した後も直す前も
// 「緑」を返し続ける（実測: 壊したソースに exit=0 を出し続け、素の flix check は
// exit=1）。symlink 自身の mtime を新しくしても変わらないので、こちらから知らせる
// 手が無い。偽の緑は偽の赤より悪い（壊れた物が配られる）ので、この形のときは
// 常駐を使わない。
func hasSymlinkedSources(pkg string) bool {
	found := false
	_ = filepath.Walk(filepath.Join(pkg, "src"), func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return nil
		}
		if !info.IsDir() && strings.HasSuffix(path, ".flix") && info.Mode()&os.ModeSymlink != 0 {
			found = true
			return filepath.SkipDir
		}
		return nil
	})
	return found
}

func debugLog(errOut *strings.Builder, msg string) {
	if os.Getenv("CHECKD_DEBUG") != "" {
		fmt.Fprintf(errOut, "[checkd] %s\n", msg)
	}
}

// clientRun は常駐に verb を頼み、駄目なら素の CLI に落ちる。
func clientRun(r *hooks.Rules, out, errOut *strings.Builder, root, pkg, verb string) int {
	if verb == "check" && useServer(r) {
		return serverCheck(r, out, errOut, root, pkg)
	}
	if hasSymlinkedSources(pkg) {
		debugLog(errOut, pkg+" は src が symlink → 常駐を使わず素の "+verb+" へ")
		return runFallback(root, pkg, verb)
	}
	if !hooks.DaemonViable(r) {
		debugLog(errOut, "物理メモリが repl 1 本の予算に足りない → 常駐を使わず素の "+verb+" へ")
		return runFallback(root, pkg, verb)
	}
	d := r.Checkd.Daemon
	for attempt := 1; attempt <= 2; attempt++ {
		code, body, err := hooks.AskWithDial(r, pkg, strings.ToUpper(verb),
			seconds(*d.ConnectTimeoutSec), seconds(*d.WorkTimeoutSec))
		if err == nil {
			if code < 0 {
				debugLog(errOut, "常駐が "+verb+" をやり切れなかった → 素の "+verb+" へ")
				break
			}
			out.WriteString(body)
			return code
		}
		hooks.DropPort(r, pkg)
		debugLog(errOut, fmt.Sprintf("常駐と話せない (%v)", err))
		if attempt == 1 && spawnDaemon(r, pkg) {
			continue
		}
		break
	}
	return runFallback(root, pkg, verb)
}

// runFallback は素の flix CLI をそのまま走らせる (出力も終了コードもそのまま)。
func runFallback(root, pkg, verb string) int {
	cmd := exec.Command(flixBin(root, pkg), verb)
	cmd.Dir = pkg
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = os.Environ()
	if verb == "test" {
		// 素の test も headless にする。GLFW と AWT の初期化がぶつかると
		// テストが固まるパッケージがあるため。
		cmd.Env = append(cmd.Env, "JAVA_TOOL_OPTIONS="+headlessOpts())
	}
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
		// WhyNot: 黙って 0 を返さないのは、検査そのものが動かなかったことを
		// 「緑」と見分けられなくなるため。
		fmt.Fprintf(os.Stderr, "[checkd] 素の %s を起動できません: %v\n", verb, err)
		return 2
	}
	return 0
}

func headlessOpts() string {
	return strings.TrimSpace(os.Getenv("JAVA_TOOL_OPTIONS") + " -Djava.awt.headless=true")
}

// spawnDaemon は常駐を切り離して起こし、口が開くまで待つ。
func spawnDaemon(r *hooks.Rules, pkg string) bool {
	sd := stateDir(r, pkg)
	self, err := os.Executable()
	if err != nil {
		return false
	}
	log, err := os.OpenFile(filepath.Join(sd, "daemon.log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return false
	}
	defer log.Close()
	cmd := exec.Command(self, "checkd", "--daemon", pkg)
	cmd.Dir = pkg
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, log, log
	// 親 (make 等) への Ctrl+C を常駐が巻き添えで受けないよう切り離す。
	hooks.Detach(cmd)
	if err := cmd.Start(); err != nil {
		return false
	}
	_ = cmd.Process.Release()
	// port が開くまで待つ (コンパイルは待たない。それは CHECK 側で待つ)
	d := r.Checkd.Daemon
	deadline := time.Now().Add(seconds(*d.SpawnWaitSec))
	for time.Now().Before(deadline) {
		if _, _, err := hooks.AskWithDial(r, pkg, "PING",
			seconds(*d.ConnectTimeoutSec), seconds(*d.ConvTimeoutSec)); err == nil {
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

// stop はそのパッケージの常駐を止め、残骸を片付ける。
func stop(r *hooks.Rules, out *strings.Builder, pkg string, quiet bool) int {
	sd := stateDir(r, pkg)
	d := r.Checkd.Daemon
	stopped := false
	if _, _, err := hooks.AskWithDial(r, pkg, "STOP",
		seconds(*d.ConnectTimeoutSec), seconds(*d.ConvTimeoutSec)); err == nil {
		stopped = true
	} else if pid := readPidFile(sd); pid > 0 {
		// 会話できない常駐は pid で直接落とす。repl は常駐とパイプで
		// つながっているので、常駐が消えれば EOF を見て自分で終わる。
		if proc, err := os.FindProcess(pid); err == nil && terminate(proc) == nil {
			stopped = true
		}
	}
	for _, f := range []string{"port", "pid", "sock", "lock"} {
		_ = os.Remove(filepath.Join(sd, f))
	}
	if !quiet {
		if stopped {
			fmt.Fprintf(out, "[checkd] 停止: %s\n", pkg)
		} else {
			fmt.Fprintf(out, "[checkd] 常駐なし: %s\n", pkg)
		}
	}
	return 0
}

// stopAll は状態の置き場に居る常駐を全部止める。
func stopAll(r *hooks.Rules, out *strings.Builder) int {
	base := hooks.CacheDir(r)
	entries, err := os.ReadDir(base)
	if err != nil {
		fmt.Fprintln(out, "[checkd] 常駐なし")
		return 0
	}
	for _, e := range entries {
		raw, err := os.ReadFile(filepath.Join(base, e.Name(), "meta.json"))
		if err != nil {
			continue
		}
		var meta struct {
			Pkg string `json:"pkg"`
		}
		if json.Unmarshal(raw, &meta) != nil || meta.Pkg == "" {
			continue
		}
		stop(r, out, meta.Pkg, false)
	}
	return 0
}

func readPidFile(sd string) int {
	raw, err := os.ReadFile(filepath.Join(sd, "pid"))
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return 0
	}
	return pid
}
