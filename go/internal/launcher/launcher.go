// Package launcher は、ゲームの make の run・debug・render・render-all・check・test・flow とゲーム固有の作業が流していた物を
// Go から流す（plans/windows.md の 5 節 #4〜#6）。engine の sh のスクリプト（bin/headless-run・bin/flix・bin/with-sample-tests）は
// shellrun で起こすので、Windows でも Git Bash の上で同じスクリプトが走る。
//
// 流す中身（環境変数・入口・ログの置き場）は mk/game.mk の同じターゲットにそろえる。make のターゲットはこれを呼ぶ 1 行の別名。
package launcher

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/shellrun"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// Launcher は 1 つのゲームの根で流す物。
type Launcher struct {
	Root, Engine string
	// Self は fge-go の実行ファイル（checkd・explain-error・resident stop を同じ版で呼ぶ）。
	Self           string
	Project        Project
	Stdout, Stderr io.Writer
}

// New はゲームの根 root の Launcher。engine の場所は make の ENGINE と同じ決まり（status.ResolveEngineDir）。
func New(root string) (*Launcher, error) {
	engine, _ := status.ResolveEngineDir(root)
	if engine == "" {
		return nil, fmt.Errorf("engine が見つかりません（%s）。flix.toml の版の engine を fge engines install で入れるか、local.mk に ENGINE := <engine の場所> を書く", root)
	}
	if abs, err := filepath.Abs(engine); err == nil {
		engine = abs
	}
	if _, err := os.Stat(filepath.Join(engine, "bin", "headless-run")); err != nil {
		return nil, fmt.Errorf("engine %s に bin/headless-run がありません。配った engine なら fge engines install <flix.toml の版> で入れる", engine)
	}
	p, err := LoadProject(root)
	if err != nil {
		return nil, err
	}
	// 子（checkd・explain-error・headless-run の中の fge-go）が同じ engine を引くように渡す。
	os.Setenv("ENGINE", engine)
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	return &Launcher{Root: root, Engine: engine, Self: self, Project: p, Stdout: os.Stdout, Stderr: os.Stderr}, nil
}

var varNameRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// SplitVars は引数を K=V（環境変数として渡す物）とそれ以外に分ける。
func SplitVars(args []string) (vars map[string]string, rest []string) {
	vars = map[string]string{}
	for _, a := range args {
		if k, v, ok := strings.Cut(a, "="); ok && varNameRe.MatchString(k) {
			vars[k] = v
			continue
		}
		rest = append(rest, a)
	}
	return vars, rest
}

// withEnv は env の上に vars を重ねた物（同じ名前は vars が勝つ）。
func withEnv(env []string, vars map[string]string) []string {
	out := make([]string, 0, len(env)+len(vars))
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		if _, over := vars[k]; !over {
			out = append(out, kv)
		}
	}
	for k, v := range vars {
		out = append(out, k+"="+v)
	}
	return out
}

func (l *Launcher) script(name string) string { return filepath.Join(l.Engine, "bin", name) }

func (l *Launcher) wire(cmd *exec.Cmd) *exec.Cmd {
	cmd.Dir = l.Root
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, l.Stdout, l.Stderr
	return cmd
}

// HeadlessVars はヘッドレスで流す時に足す環境変数（mk/game.mk の HEADLESS_RUN と同じ）。
func HeadlessVars() map[string]string {
	return map[string]string{"JAVA_TOOL_OPTIONS": "-Djava.awt.headless=true"}
}

// headless は bin/headless-run を entry で流す。window ならウィンドウあり（--window）。vars は環境変数として渡す。
func (l *Launcher) headless(entry string, window bool, vars map[string]string) int {
	args := []string{entry}
	if window {
		args = []string{"--window", entry}
	}
	cmd, err := shellrun.Command(l.script("headless-run"), args...)
	if err != nil {
		fmt.Fprintln(l.Stderr, err)
		return 2
	}
	cmd.Env = withEnv(os.Environ(), vars)
	return shellrun.Run(l.wire(cmd), "bin/headless-run")
}

// Headless はヘッドレスの入口を 1 つ流す（bin/fge headless）。
func (l *Launcher) Headless(entry string, vars map[string]string) int {
	return l.headless(entry, false, merge(HeadlessVars(), vars))
}

// Play はゲームをウィンドウありで起こす（make run・debug と同じ: 描き出しの jar から main を流し、jar を作れない時は flix run で続ける）。
// shot が空でなければ、その場面の World から F8 で止めた状態で開く。
func (l *Launcher) Play(shot string, debug bool, vars map[string]string) int {
	if code := l.RunPrebuild(); code != 0 {
		return code
	}
	base := map[string]string{"FGE_HEADLESS_FALLBACK": "1"}
	if debug {
		base["DEBUG"] = "true"
	}
	if shot != "" {
		base["START"] = "shot:" + shot
		base["DEBUG"] = "1"
	}
	if path, ok := l.shaderVariantsPath(); ok {
		base["FLIX_GE_SHADER_VARIANTS"] = path
	}
	return l.headless("main", true, merge(base, vars))
}

// shaderVariantsPath はブラウザ版を出すゲーム（web/WebMain.flix がある）の、3D の描き手が使ったシェーダーの鍵を記録するファイルの道。
// 書き出し（bin/fge export-web）はこの記録の分だけシェーダーの字を前もって作る。
// WhyNot: ゲームの Makefile で旗を立てない — Makefile を通らない外のゲームと Studio から走らせた時に記録が漏れる。
// WhyNot: web/ の無い 3D のゲームでも書かない — ブラウザに出さないゲームのフォルダに使わないファイルが増える。
func (l *Launcher) shaderVariantsPath() (string, bool) {
	if _, err := os.Stat(filepath.Join(l.Root, "web", "WebMain.flix")); err != nil {
		return "", false
	}
	abs, err := filepath.Abs(filepath.Join(l.Root, "web", "shader-variants.json"))
	if err != nil {
		return "", false
	}
	return abs, true
}

// Render は場面を 1 枚ずつ debug/<場面>.png へ描き出す（make render SHOT=）。
func (l *Launcher) Render(shots []string, vars map[string]string) int {
	if code := l.RunPrebuild(); code != 0 {
		return code
	}
	return l.Headless("SceneRender.one", merge(map[string]string{"SHOT": strings.Join(shots, " ")}, vars))
}

// RenderAll は全部の場面を gallery/ へ描き出し、成否にかかわらずヘッドレスのゲームの常駐を止める（make render-all）。
func (l *Launcher) RenderAll(vars map[string]string) int {
	if code := l.RunPrebuild(); code != 0 {
		return code
	}
	code := l.Headless("SceneRender.all", vars)
	l.stopResident()
	return code
}

// Flow は flow を画面なしで最後まで流す（make flow FLOW=）。
func (l *Launcher) Flow(flow string, vars map[string]string) int {
	if code := l.RunPrebuild(); code != 0 {
		return code
	}
	return l.Headless("E2e.play", merge(map[string]string{"FLOW": flow, "FLOW_MODE": "run"}, vars))
}

// stopResident はヘッドレスのゲームの常駐（HEADLESS_RESIDENT=1 の時に headless-run が起こす物）を止める。居なければ何もしない。
func (l *Launcher) stopResident() {
	cmd := l.wire(exec.Command(l.Self, "resident", "stop", "--dir", "."))
	_ = cmd.Run()
}

// RunPrebuild は project.json の prebuild のうち、入力が出力より新しい物を作り直す。
func (l *Launcher) RunPrebuild() int {
	for _, pb := range l.Project.Prebuild {
		stale, err := pb.Stale(l.Root)
		if err != nil {
			fmt.Fprintln(l.Stderr, err)
			return 2
		}
		if !stale {
			continue
		}
		fmt.Fprintf(l.Stderr, "[fge] %s を作り直す（%s）\n", pb.Out, pb.Entry)
		if code := l.Headless(pb.Entry, nil); code != 0 {
			return code
		}
		// WhyNot: 時刻を新しくする — 入口は中身が同じなら書き直さないので、そのままだと入力より古いまま毎回作り直す。
		now := time.Now()
		_ = os.Chtimes(filepath.Join(l.Root, pb.Out), now, now)
	}
	return 0
}

// Task はゲーム固有の作業 name を流す。vars は project.json の env の既定と外の環境変数を上書きする。
func (l *Launcher) Task(name string, vars map[string]string) int {
	t, ok := l.Project.Tasks[name]
	if !ok {
		fmt.Fprintf(l.Stderr, "task: project.json の tasks に %q がありません\n", name)
		l.ListTasks(l.Stderr)
		return 2
	}
	env := map[string]string{}
	for k, v := range t.Env {
		if _, set := os.LookupEnv(k); !set {
			env[k] = v
		}
	}
	env = merge(env, vars)
	if t.Entry != "" {
		if t.Window {
			return l.headless(t.Entry, true, env)
		}
		return l.Headless(t.Entry, env)
	}
	cmd, err := l.taskCommand(t.Cmd)
	if err != nil {
		fmt.Fprintln(l.Stderr, err)
		return 2
	}
	cmd.Env = withEnv(os.Environ(), env)
	return shellrun.Run(l.wire(cmd), t.Cmd[0])
}

// taskCommand は cmd の並びを起こす形。python3 は macOS と Linux では engine の bin/py3（make の PYTHON3 と同じ）を通す。
func (l *Launcher) taskCommand(argv []string) (*exec.Cmd, error) {
	if argv[0] == "python3" && runtime.GOOS != "windows" && shellrun.IsRunnable(l.script("py3")) {
		return shellrun.Command(l.script("py3"), argv[1:]...)
	}
	return exec.Command(argv[0], argv[1:]...), nil
}

// ListTasks は tasks の名前と説明を w へ出す。
func (l *Launcher) ListTasks(w io.Writer) {
	names := l.Project.TaskNames()
	if len(names) == 0 {
		fmt.Fprintln(w, "  （project.json に tasks がありません）")
		return
	}
	for _, n := range names {
		t := l.Project.Tasks[n]
		fmt.Fprintf(w, "  %-14s %s\n", n, t.About)
	}
}

// Check は型検査だけを流す（make check）。全文は .test-logs/check.log・画面には explain-error の要約。
// vars の CHECKD=0 で常駐を使わない素の check・QUIET=0 で全文を出す（外の環境変数でも同じ）。
func (l *Launcher) Check(vars map[string]string) int {
	logPath := filepath.Join(l.Root, ".test-logs", "check.log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		fmt.Fprintln(l.Stderr, err)
		return 2
	}
	log, err := os.Create(logPath)
	if err != nil {
		fmt.Fprintln(l.Stderr, err)
		return 2
	}
	var cmd *exec.Cmd
	if lookup(vars, "CHECKD") == "0" {
		cmd, err = shellrun.Command(l.script("flix"), "check")
		if err != nil {
			log.Close()
			fmt.Fprintln(l.Stderr, err)
			return 2
		}
	} else {
		cmd = exec.Command(l.Self, "checkd", ".")
	}
	cmd.Dir = l.Root
	cmd.Stdout, cmd.Stderr = log, log
	code := runCode(cmd)
	log.Close()
	if lookup(vars, "QUIET") == "0" {
		b, _ := os.ReadFile(logPath)
		l.Stdout.Write(b)
		return code
	}
	in, err := os.Open(logPath)
	if err != nil {
		fmt.Fprintln(l.Stderr, err)
		return code
	}
	defer in.Close()
	explain := exec.Command(l.Self, "explain-error", "--status", fmt.Sprint(code), "--log", filepath.Join(".test-logs", "check.log"))
	explain.Dir = l.Root
	explain.Stdin, explain.Stdout, explain.Stderr = in, l.Stdout, l.Stderr
	_ = explain.Run()
	return code
}

// Test はテストを headless で流す（make test）。出力は .test-logs/test.log に落とし、緑なら末尾 5 行・赤なら末尾 40 行と
// .test-logs/test.fail（make status が読む）。
func (l *Launcher) Test(vars map[string]string) int {
	logs := filepath.Join(l.Root, ".test-logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		fmt.Fprintln(l.Stderr, err)
		return 2
	}
	failMark := filepath.Join(logs, "test.fail")
	_ = os.Remove(failMark)
	flix := l.script("flix")
	var cmd *exec.Cmd
	var err error
	if sample := l.script("with-sample-tests"); shellrun.IsRunnable(sample) {
		cmd, err = shellrun.Command(sample, ".", filepath.ToSlash(flix), "test")
	} else {
		cmd, err = shellrun.Command(flix, "test")
	}
	if err != nil {
		fmt.Fprintln(l.Stderr, err)
		return 2
	}
	logPath := filepath.Join(logs, "test.log")
	log, err := os.Create(logPath)
	if err != nil {
		fmt.Fprintln(l.Stderr, err)
		return 2
	}
	cmd.Dir = l.Root
	cmd.Env = withEnv(os.Environ(), merge(HeadlessVars(), vars))
	cmd.Stdout, cmd.Stderr = log, log
	code := shellrun.Run(cmd, "flix test")
	log.Close()
	b, _ := os.ReadFile(logPath)
	if code == 0 {
		l.Stdout.Write(tailLines(b, 5))
		return 0
	}
	_ = os.WriteFile(failMark, nil, 0o644)
	l.Stdout.Write(tailLines(b, 40))
	return 1
}

func runCode(cmd *exec.Cmd) int {
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		fmt.Fprintf(cmd.Stderr, "%s を起動できません: %v\n", cmd.Path, err)
		return 2
	}
	return 0
}

// lookup は vars の値、無ければ外の環境変数。
func lookup(vars map[string]string, k string) string {
	if v, ok := vars[k]; ok {
		return v
	}
	return os.Getenv(k)
}

func merge(base, over map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range base {
		out[k] = v
	}
	for k, v := range over {
		out[k] = v
	}
	return out
}

// tailLines は b の最後の n 行（tail -n と同じく、最後の改行の後ろの字も 1 行と数える）。
func tailLines(b []byte, n int) []byte {
	trimmed := bytes.TrimSuffix(b, []byte("\n"))
	cut := len(trimmed)
	for i := 0; i < n; i++ {
		j := bytes.LastIndexByte(trimmed[:cut], '\n')
		if j < 0 {
			return b
		}
		cut = j
	}
	return b[cut+1:]
}
