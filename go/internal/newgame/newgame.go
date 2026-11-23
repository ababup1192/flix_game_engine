// Package newgame は fge new の本体。配った engine のテンプレートから scaffold でゲームを作り、workspace.json に足す。
// 決まりの本文は plans/onboarding.md の 2.8。
package newgame

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/cmdhint"
	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
	"github.com/ababup1192/flix_game_engine/go/internal/fgeinstall"
	"github.com/ababup1192/flix_game_engine/go/internal/gamesteps"
	"github.com/ababup1192/flix_game_engine/go/internal/scaffold"
)

const (
	exitDone     = 0
	exitProblem  = 1
	exitBadUsage = 2
)

// DefaultTemplate は scaffold（make new-game）の TEMPLATE の既定と同じ。
const DefaultTemplate = scaffold.DefaultTemplate

const usage = `使い方: fge new <フォルダ名> [--template <名>] [--name <パッケージ名>] [--title <題>] [--engine <版>]
        fge new --list [--engine <版>]`

// Deps は外の世界（網・git・置き場）とつなぐ所。テストは差し替える。
type Deps struct {
	Install  func(version string) (fgeinstall.InstallResult, error)
	Latest   func() (string, error)
	Newest   func() string
	LookPath func(name string) (string, error)
	// NeedsMake は産声の確認に make を使うか（fge がまだ check・test・render を持たない時）。
	NeedsMake func() bool
	Create    func(req scaffold.Request) error
	Getwd     func() (string, error)
	GOOS      string
	GOARCH    string
	Progress  io.Writer
}

// DefaultDeps は本物の網・git・置き場を使う。
func DefaultDeps(e *fgeinstall.Env) Deps {
	return Deps{
		Install: e.Install,
		Latest: func() (string, error) {
			l, ok, err := e.RefreshLatest(false)
			if !ok {
				return "", err
			}
			return l.Version, nil
		},
		Newest:    fgeinstall.NewestInstalled,
		LookPath:  exec.LookPath,
		NeedsMake: func() bool { return !gamesteps.New("").UsesFge() },
		Create:    createStreaming,
		Getwd:     os.Getwd,
		GOOS:      e.GOOS,
		GOARCH:    e.GOARCH,
		Progress:  e.Progress,
	}
}

// WhyNot: 出力を貯めずに端末へ直に流す — 作るのは 2〜3 分かかり、貯めると呼ぶ側の Claude が止まったと見分けられない。
// WhyNot: JAVA を足さない — 配った engine では bin/java-resolve.sh が mk/jdk.mk から決める。人が名指しした JAVA は環境のまま子へ届く。
// WhyNot: Ctrl-C で fge まで落とさない — 子の check・描き出しだけが止まり、fge が作りかけのフォルダを片付けてから終わる。
func createStreaming(req scaffold.Request) error {
	signal.Ignore(os.Interrupt)
	defer signal.Reset(os.Interrupt)
	return scaffold.Create(req, scaffold.DefaultDeps(os.Stdout, gamesteps.New(req.Engine)))
}

type options struct {
	folder   string
	template string
	name     string
	title    string
	engine   string
	list     bool
}

// parseArgs はフォルダ名を旗の前にも後にも置けるように読む。
// WhyNot: flag.Parse 1 回にしない — 最初の旗でない引数で読むのを止めるので、`fge new tidepool --template x` の旗を落とす。
func parseArgs(args []string, errOut io.Writer) (options, error) {
	var o options
	fs := flag.NewFlagSet("new", flag.ContinueOnError)
	fs.SetOutput(errOut)
	fs.StringVar(&o.template, "template", "", "写すテンプレート（既定 "+DefaultTemplate+"）")
	fs.StringVar(&o.name, "name", "", "Flix のパッケージ名（既定はフォルダ名の - を _ に替えた物）")
	fs.StringVar(&o.title, "title", "", "ウィンドウの題（既定はパッケージ名）")
	fs.StringVar(&o.engine, "engine", "", "使う engine の版（既定は手元の最新、無ければ Release の最新）")
	fs.BoolVar(&o.list, "list", false, "テンプレートの一覧")
	var positional []string
	for {
		if err := fs.Parse(args); err != nil {
			return o, err
		}
		if fs.NArg() == 0 {
			break
		}
		positional = append(positional, fs.Arg(0))
		args = fs.Args()[1:]
	}
	if len(positional) > 1 {
		return o, fmt.Errorf("フォルダ名は 1 つだけです: %s", strings.Join(positional, " "))
	}
	if len(positional) == 1 {
		o.folder = positional[0]
	}
	return o, nil
}

var packageNameRe = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
var templateNameRe = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// PackageName はフォルダ名と --name からパッケージ名を決める。決まりに合わなければ理由を返す。
func PackageName(folder, name string) (string, error) {
	if name == "" {
		name = strings.ReplaceAll(folder, "-", "_")
	}
	if packageNameRe.MatchString(name) {
		return name, nil
	}
	return "", fmt.Errorf("パッケージ名 %q は使えません（英小文字ではじまり、英小文字・数字・_ だけ）。--name で別に付けてください（例: fge new %s --name %s）",
		name, folder, suggestName(name))
}

func suggestName(name string) string {
	var b strings.Builder
	for _, c := range strings.ToLower(name) {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_':
			b.WriteRune(c)
		case c == '-' || c == ' ' || c == '.':
			b.WriteRune('_')
		}
	}
	s := strings.Trim(b.String(), "_")
	if s == "" || s[0] < 'a' || s[0] > 'z' {
		s = "game_" + s
	}
	return strings.TrimRight(s, "_")
}

// checkFolderName はフォルダ名として置いてよいか。
func checkFolderName(folder string) error {
	if folder == "" || folder == "." || folder == ".." || strings.ContainsAny(folder, `/\`) || strings.HasPrefix(folder, "-") {
		return fmt.Errorf("フォルダ名 %q は使えません（今のフォルダの下に作る 1 つの名前を渡してください）", folder)
	}
	return nil
}

// missingTools は要る道具（git と、産声の確認に make を使う時は make）のうち PATH に無い物。
func missingTools(lookPath func(string) (string, error), needsMake bool) []string {
	tools := []string{"git"}
	if needsMake {
		tools = append(tools, "make")
	}
	var missing []string
	for _, tool := range tools {
		if _, err := lookPath(tool); err != nil {
			missing = append(missing, tool)
		}
	}
	return missing
}

// installHint は OS ごとの入れ方の 1 行。
func installHint(goos string, missing []string) string {
	switch goos {
	case "darwin":
		return "macOS では `xcode-select --install` で make・git が入ります"
	case "linux":
		return "Debian・Ubuntu は `sudo apt-get install -y " + strings.Join(missing, " ") + "`、Fedora は `sudo dnf install -y " + strings.Join(missing, " ") + "`"
	}
	return strings.Join(missing, "・") + " を入れてください"
}

// Template は fge new --list の 1 行。
type Template struct {
	Name    string `json:"name"`
	Title   string `json:"title,omitempty"`
	Summary string `json:"summary,omitempty"`
}

// ListTemplates は engine の templates/ の一覧。題は project.json の title、説明は README.md の見出しの次の本文の 1 行目。
func ListTemplates(engineDir string) ([]Template, error) {
	entries, err := os.ReadDir(filepath.Join(engineDir, "templates"))
	if err != nil {
		return nil, fmt.Errorf("テンプレートの一覧を読めません: %v", err)
	}
	var list []Template
	for _, e := range entries {
		if !e.IsDir() || !templateNameRe.MatchString(e.Name()) {
			continue
		}
		dir := filepath.Join(engineDir, "templates", e.Name())
		list = append(list, Template{Name: e.Name(), Title: projectTitle(dir), Summary: readmeSummary(dir)})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	return list, nil
}

func projectTitle(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, "project.json"))
	if err != nil {
		return ""
	}
	var p struct {
		Title string `json:"title"`
	}
	// WhyNot: 置き換え前の字（__TITLE__）を題として出さない — 一覧を読む人には意味が無い。
	if json.Unmarshal(b, &p) != nil || strings.Contains(p.Title, "__") {
		return ""
	}
	return p.Title
}

func readmeSummary(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, "README.md"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		return line
	}
	return ""
}

// Run は fge new の本体。
func Run(out, errOut *strings.Builder, args []string, asJSON bool, d Deps) int {
	o, err := parseArgs(args, errOut)
	if err != nil {
		fmt.Fprintln(errOut, usage)
		return exitBadUsage
	}
	if o.list {
		return runList(out, errOut, o, asJSON, d)
	}
	if o.folder == "" {
		fmt.Fprintln(errOut, usage)
		return exitBadUsage
	}
	res, err := create(o, d)
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitProblem
	}
	if asJSON {
		b, _ := json.Marshal(res)
		out.Write(append(b, '\n'))
		return exitDone
	}
	fmt.Fprintf(out, "[fge new] %s を作りました（engine %s・テンプレート %s）\n", res.Dir, res.Engine, res.Template)
	fmt.Fprintln(out, "次にやること:")
	fmt.Fprintf(out, "  fge open %s            このゲームのフォルダで Claude Code を開く\n", res.Name)
	fmt.Fprintf(out, "  cd %s && %s   動かしてみる（%s で描き出しの確かめ）\n",
		res.Name, cmdhint.CommandFor(d.GOOS, "run"), cmdhint.CommandFor(d.GOOS, "debug"))
	fmt.Fprintln(out, "配られた skills・rules・AGENTS.md の共通部は版上げで上書きされます。ゲーム用に変えたい時は AGENTS.local.md に書くか、別の名前のスキルを足してください。")
	return exitDone
}

// Result は fge new の結果。
type Result struct {
	Name     string `json:"name"`
	Dir      string `json:"dir"`
	Package  string `json:"package"`
	Template string `json:"template"`
	Engine   string `json:"engine"`
}

func (d Deps) progressf(format string, args ...any) {
	if d.Progress != nil {
		fmt.Fprintf(d.Progress, format, args...)
	}
}

func create(o options, d Deps) (Result, error) {
	if err := checkFolderName(o.folder); err != nil {
		return Result{}, err
	}
	pkg, err := PackageName(o.folder, o.name)
	if err != nil {
		return Result{}, err
	}
	template := o.template
	if template == "" {
		template = DefaultTemplate
	}
	if !templateNameRe.MatchString(template) {
		return Result{}, fmt.Errorf("テンプレート名 %q は読めません（一覧は fge new --list）", template)
	}
	// WhyNot: engine を取るより先に道具を見る — 300 MB を落とした後に git が無いと分かっても、人は何もできない。
	if missing := missingTools(d.LookPath, d.NeedsMake()); len(missing) > 0 {
		return Result{}, fmt.Errorf("%s が見つかりません。%s", strings.Join(missing, "・"), installHint(d.GOOS, missing))
	}
	cwd, err := d.Getwd()
	if err != nil {
		return Result{}, err
	}
	dir := filepath.Join(cwd, o.folder)
	if _, err := os.Lstat(dir); err == nil {
		return Result{}, fmt.Errorf("%s は既にあります。別のフォルダ名にしてください", dir)
	}

	d.progressf("[fge new] 1/3 engine と JDK を用意します\n")
	version, err := pickEngine(o.engine, d)
	if err != nil {
		return Result{}, err
	}
	inst, err := d.Install(version)
	if err != nil {
		return Result{}, err
	}
	if _, err := os.Stat(filepath.Join(inst.EngineDir, "templates", template)); err != nil {
		names := []string{}
		if list, err := ListTemplates(inst.EngineDir); err == nil {
			for _, t := range list {
				names = append(names, t.Name)
			}
		}
		return Result{}, fmt.Errorf("engine %s にテンプレート %q はありません（あるのは %s）", inst.Version, template, strings.Join(names, "・"))
	}

	d.progressf("[fge new] 2/3 %s を %s から作ります（check → test → 描き出しまで流すので 2〜3 分かかります）\n", o.folder, template)
	req := scaffold.Request{Engine: inst.EngineDir, Game: dir, Name: pkg, Title: o.title, Template: template, GOOS: d.GOOS, GOARCH: d.GOARCH}
	if err := d.Create(req); err != nil {
		removeHalfMade(dir, d.Progress)
		return Result{}, fmt.Errorf("ゲームを作る途中で止まりました: %v（上の出力に理由があります）", err)
	}

	d.progressf("[fge new] 3/3 ワークスペースの一覧（%s）に足します\n", fgehome.WorkspacePath())
	if err := addToWorkspace(fgehome.Game{Name: o.folder, Dir: dir}, d.Progress); err != nil {
		return Result{}, err
	}
	return Result{Name: o.folder, Dir: dir, Package: pkg, Template: template, Engine: inst.Version}, nil
}

// removeHalfMade は作る途中で止まった時に作りかけのフォルダを消す。
// WhyNot: 前からあった物を消すかを見分けない — create が作る前に dir が無いことを確かめ、あれば止めている。
func removeHalfMade(dir string, progress io.Writer) {
	if _, err := os.Lstat(dir); err != nil {
		return
	}
	if err := os.RemoveAll(dir); err != nil {
		if progress != nil {
			fmt.Fprintf(progress, "[fge new] 作りかけの %s を消せませんでした: %v（打ち直す前に手で消してください）\n", dir, err)
		}
		return
	}
	if progress != nil {
		fmt.Fprintf(progress, "[fge new] 作りかけの %s を消しました（同じ名前で打ち直せます）\n", dir)
	}
}

// pickEngine は --engine・手元の最新・Release の最新の順に版を決める。
func pickEngine(flagVersion string, d Deps) (string, error) {
	if flagVersion != "" {
		return flagVersion, nil
	}
	if v := d.Newest(); v != "" {
		return v, nil
	}
	v, err := d.Latest()
	if err != nil || v == "" {
		return "", fmt.Errorf("手元に engine が無く、Release の最新も引けません: %v（--engine <版> で名指しできます）", err)
	}
	return v, nil
}

func addToWorkspace(g fgehome.Game, progress io.Writer) error {
	unlock, err := fgehome.Lock(fgehome.LockPath(), progress)
	if err != nil {
		return fmt.Errorf("排他を取れません: %v", err)
	}
	defer unlock()
	ws, err := fgehome.ReadWorkspace()
	if err != nil {
		return fmt.Errorf("workspace.json を読めません: %v", err)
	}
	ws.AddGame(g)
	return fgehome.WriteWorkspace(ws)
}

func runList(out, errOut *strings.Builder, o options, asJSON bool, d Deps) int {
	version, err := pickEngine(o.engine, d)
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitProblem
	}
	inst, err := d.Install(version)
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitProblem
	}
	list, err := ListTemplates(inst.EngineDir)
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitProblem
	}
	if asJSON {
		if list == nil {
			list = []Template{}
		}
		b, _ := json.Marshal(list)
		out.Write(append(b, '\n'))
		return exitDone
	}
	fmt.Fprintf(out, "engine %s のテンプレート（fge new <フォルダ名> --template <名>）:\n", inst.Version)
	for _, t := range list {
		title := t.Title
		if title == "" {
			title = "-"
		}
		fmt.Fprintf(out, "  %-24s %s  %s\n", t.Name, title, t.Summary)
	}
	return exitDone
}
