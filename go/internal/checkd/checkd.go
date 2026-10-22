// Package checkd は make check の速い道。
//
// check は flixlint の常駐（lint・refactor の索引と同じ JVM・同じコンパイラ。hooks.json の checkd.server）に頼む。常駐は
// 頼まれた時にソースを読み、変わった物だけコンパイラに渡し、答えに「検査したソースの版」を付ける。クライアントは答えを
// 受けた後にディスクから版を取り直し、同じ時だけ答えを使う（違えば頼み直し、それでも合わなければ素の flix check）。
// ファイルの監視と待ちに正しさを預けないので、古い緑が出ない（flixlint の docs/design/checkd-freshness.md）。
// test は素の flix test（テストはゲームのコードを動かすので常駐に入れない）。
//
// 常駐が無い・壊れている・答えない時は、黙って素の CLI に落ちる。速さより結果の正しさを常に優先する。
package checkd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

// Usage は引数を読めなかったときに出す使い方。
const Usage = `使い方: fge checkd [パッケージdir]   # check する (省略時はカレント。flixlint の常駐で)
        fge checkd --test [dir]      # test する (素の flix test)
        fge checkd --stop [dir]      # そのパッケージの常駐を止める
        fge checkd --stop-all        # 常駐を全部止める
`

// Run は fge checkd の入口。out が check の出力、errOut が経過の記録。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	r, err := hooks.LoadRules(root)
	if err != nil {
		return 2, err
	}
	switch {
	case len(args) > 0 && args[0] == "--stop-all":
		return stopAll(r, out), nil
	case len(args) > 0 && args[0] == "--stop":
		arg := ""
		if len(args) > 1 {
			arg = args[1]
		}
		return stop(r, out, pkgDirOf(arg), false), nil
	}
	verb := "check"
	if len(args) > 0 && args[0] == "--test" {
		verb, args = "test", args[1:]
	}
	if len(args) > 0 && strings.HasPrefix(args[0], "--") {
		fmt.Fprint(errOut, Usage)
		return 2, nil
	}
	arg := ""
	if len(args) > 0 {
		arg = args[0]
	}
	pkg := pkgDirOf(arg)
	if !isFile(filepath.Join(pkg, "flix.toml")) {
		fmt.Fprintf(errOut, "[checkd] %s に flix.toml がありません\n", pkg)
		return 2, nil
	}
	return clientRun(r, out, errOut, root, pkg, verb), nil
}

// pkgDirOf は引数 (空ならカレント) を symlink を解いた絶対パスにする。
func pkgDirOf(arg string) string {
	if arg == "" {
		arg, _ = os.Getwd()
	}
	abs, err := filepath.Abs(arg)
	if err != nil {
		abs = arg
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		return real
	}
	return abs
}

// stateDir はそのパッケージの状態の置き場 (無ければ作る)。
func stateDir(r *hooks.Rules, pkg string) string {
	d := hooks.StateDir(r, pkg)
	_ = os.MkdirAll(d, 0o755)
	return d
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func isExec(path string) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	return info.Mode().Perm()&0o111 != 0
}

func seconds(v float64) time.Duration {
	return time.Duration(v * float64(time.Second))
}
