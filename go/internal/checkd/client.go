package checkd

// クライアント側 — 常駐を探し、話し、駄目なら素の CLI に落ちる。

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
	"github.com/ababup1192/flix_game_engine/go/internal/mvncache"
	"github.com/ababup1192/flix_game_engine/go/internal/shellrun"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// flixBin はこのパッケージが使う flix コンパイラの呼び口（bin/flix）を返す。Windows では Git Bash で起こす（shellrun）。
func flixBin(root, pkg string) string {
	// ゲーム側の bin/flix (symlink 含む) を優先。
	if cand := filepath.Join(pkg, "bin", "flix"); shellrun.IsRunnable(cand) {
		return cand
	}
	// 配った先 (ゲームの bin/) に flix は居ないので、engine の場所を
	// game Makefile の ENGINE の既定と同じ決まり (status.ResolveEngineDir) で引く。
	engine, _ := status.ResolveEngineDir(pkg)
	if engine != "" {
		if cand := filepath.Join(engine, "bin", "flix"); shellrun.IsRunnable(cand) {
			return cand
		}
	}
	return filepath.Join(root, "bin", "flix")
}

// flixJarOf は bin/flix が使う flix.jar のパス（FLIX_PRINT_JAR=1）。Windows では MSYS の /c/... を C:/... に直して返す。
//
// WhyNot: 標準入力を開いたまま渡さない — FLIX_PRINT_JAR を知らない古い bin/flix は素の java -jar flix.jar（REPL）になり、
// 開いた標準入力を待って止まる（bin/headless-run の shared_flix_jar と同じ理由）。
func flixJarOf(bin string) (string, error) {
	cmd, err := shellrun.Command(bin)
	if err != nil {
		return "", err
	}
	cmd.Env = append(os.Environ(), "FLIX_PRINT_JAR=1")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return shellrun.NativePath(runtime.GOOS, strings.TrimSpace(string(out))), nil
}

func debugLog(errOut *strings.Builder, msg string) {
	if os.Getenv("CHECKD_DEBUG") != "" {
		fmt.Fprintf(errOut, "[checkd] %s\n", msg)
	}
}

// clientRun は verb をする。check は flixlint の常駐（hooks.json の checkd.server。lint・refactor の索引と同じ JVM）に頼み、
// 答えの版がディスクと合う時だけ使う（serverCheck）。test は素の flix test（テストはゲームのコードを動かすので常駐に入れない。
// checkd-freshness の C-T の記録: 常駐で組んでも縮まず、コード生成のヒープが線を超える）。
// checkd.server が無い hooks.json と CHECKD_BACKEND=cli は素の flix check。
func clientRun(r *hooks.Rules, out, errOut *strings.Builder, root, pkg, verb string) int {
	// WhyNot: bin/flix に任せない — 常駐の道は bin/flix を通らず、Studio が同梱する engine の bin/flix は別の物。
	if msg := mvncache.Link(pkg); msg != "" {
		fmt.Fprintln(errOut, msg)
	}
	if verb == "check" && useServer(r) {
		return serverCheck(r, out, errOut, root, pkg)
	}
	debugLog(errOut, "素の "+verb)
	return runFallback(root, pkg, verb)
}

// runFallback は素の flix CLI をそのまま走らせる (出力も終了コードもそのまま)。
func runFallback(root, pkg, verb string) int {
	cmd, err := shellrun.Command(flixBin(root, pkg), verb)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[checkd] 素の %s を起動できません: %v\n", verb, err)
		return 2
	}
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

// stop はそのパッケージの check の常駐（flixlint）を止める。lint・refactor の索引も同じ常駐なので一緒に止まる。
func stop(r *hooks.Rules, out *strings.Builder, pkg string, quiet bool) int {
	stopped := stopServer(r, pkg)
	if !quiet {
		if stopped {
			fmt.Fprintf(out, "[checkd] 停止: %s\n", pkg)
		} else {
			fmt.Fprintf(out, "[checkd] 常駐なし: %s\n", pkg)
		}
	}
	return 0
}

// stopAll は状態の置き場に記録のある常駐を全部止める。
func stopAll(r *hooks.Rules, out *strings.Builder) int {
	base := hooks.CacheDir(r)
	entries, err := os.ReadDir(base)
	if err != nil {
		fmt.Fprintln(out, "[checkd] 常駐なし")
		return 0
	}
	for _, e := range entries {
		if s, ok := readServerMark(filepath.Join(base, e.Name())); ok {
			stop(r, out, s.pkg, false)
		}
	}
	return 0
}
