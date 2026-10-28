// Package talk は、会話のシナリオ（.yarn）の行から、ゲームの本物の画面へ行く道具。
//
//	fge talk goto <file.yarn>:<行> [$名前=値…] [--port N]   起動中のゲームを、その行を出している所へ飛ばす
//	fge talk shot <file.yarn>:<行> [$名前=値…] [--out <png>] [--entry E2e.serveHeadless]   窓なしのゲームで 1 枚撮る
//	fge talk where <file.yarn>:<行>              その行を中に持つノードの名前
//
// どれもゲームの根で流す。行からノードを引く決まりは engine の Yarn.nodeAtLine と同じ
// （そのファイルで title: の行が line 以下の、いちばん後のノード）。
// 飛ばす・撮るのに使う始まりは `talk node=<ノード> line=<行>`（ゲームの App.withStarts。雛形 sound-novel-starter の Starts）。
// $名前=値 はシナリオの変数（<<declare>>）の値として始まりの引数へそのまま足す（ゲームは YarnStorage.withArgs で読む）。
//
// goto の行き先: --port → 環境変数 DEBUG_HTTP_PORT → ~/.flix_ge_studio/games.json のこのゲームの行（DEBUG で起動した
// ゲームが自分で書き置く・Studio が起こしたゲームは Studio が書く）。VS Code はタスクで
// `bin/fge talk goto ${relativeFile}:${lineNumber}` を流し、キーを割り当てるだけ。
//
// shot は engine の bin/headless-run でゲームの入口（既定 E2e.serveHeadless）を FGE_SHOT つきで流す
// （新しい make の口は作らない。jar は src が変わった時だけ作り直す）。
package talk

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/status"
	"github.com/ababup1192/flix_game_engine/go/internal/videos"
	"github.com/ababup1192/flix_game_engine/go/internal/yarn"
)

const usage = `使い方（ゲームの根で）:
  fge talk goto <file.yarn>:<行> [$名前=値…] [--port N]
                                               起動中のゲーム（DEBUG=true）を、その行を出している所へ飛ばす
  fge talk shot <file.yarn>:<行> [$名前=値…] [--out <png>] [--entry E2e.serveHeadless]
                                               窓なしのゲームで 1 枚撮る（ゲームを起動していなくてよい）
  fge talk where <file.yarn>:<行>              その行を中に持つノードの名前
始まりは talk node=<ノード> line=<行> $名前=値…（ゲームの App.withStarts）。
$名前=値 はシナリオの変数をその値にして流す（例 '$切符=0'。シェルが $ を読まないよう ' ' で囲む。値に空白は書けない）。`

// Target は飛ぶ先（.yarn のパスはゲームの根から・ノード・行・変数の値 "$名前=値" の並び）。
type Target struct {
	File string
	Node string
	Line int
	Vars []string
}

// StartLine は始まりの行（flow の start・FGE_SHOT・POST /start と同じ字）。
func (t Target) StartLine() string {
	line := fmt.Sprintf("talk node=%s line=%d", t.Node, t.Line)
	for _, v := range t.Vars {
		line += " " + v
	}
	return line
}

// varsOf は引数のうち $名前=値 の物（形の違う物は誤り）。
func varsOf(args []string) ([]string, error) {
	var out []string
	for _, a := range args {
		if !strings.HasPrefix(a, "$") {
			continue
		}
		name, value, ok := strings.Cut(a, "=")
		if !ok || len(name) < 2 || value == "" || strings.ContainsAny(a, " \t") {
			return nil, fmt.Errorf("変数は $名前=値 の形で、空白を入れずに渡す: %q", a)
		}
		out = append(out, a)
	}
	return out, nil
}

// Run は fge talk の入口。
func Run(out, errOut *strings.Builder, root string, args []string) int {
	if len(args) < 2 || args[0] == "help" || args[0] == "--help" {
		out.WriteString(usage + "\n")
		if len(args) == 0 {
			return 2
		}
		return 0
	}
	sub, spot, rest := args[0], args[1], args[2:]
	target, err := Resolve(root, spot)
	if err == nil {
		target.Vars, err = varsOf(rest)
	}
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 1
	}
	switch sub {
	case "where":
		out.WriteString(target.Node + "\n")
		return 0
	case "goto":
		port, err := portOf(root, flag(rest, "--port"))
		if err != nil {
			errOut.WriteString(err.Error() + "\n")
			return 1
		}
		reply, err := Goto(port, target)
		if err != nil {
			errOut.WriteString(err.Error() + "\n")
			return 1
		}
		out.WriteString(reply)
		if !strings.HasPrefix(reply, "ok") {
			return 1
		}
		return 0
	case "shot":
		png, err := Shot(root, target, flag(rest, "--entry"))
		if err != nil {
			errOut.WriteString(err.Error() + "\n")
			return 1
		}
		if dest := flag(rest, "--out"); dest != "" {
			if err := copyFile(filepath.Join(root, png), dest); err != nil {
				errOut.WriteString(err.Error() + "\n")
				return 1
			}
			png = dest
		}
		out.WriteString(png + "\n")
		return 0
	}
	errOut.WriteString("知らない口: " + sub + "（goto / shot / where）\n")
	return 2
}

func flag(args []string, name string) string {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1]
		}
		if strings.HasPrefix(a, name+"=") {
			return strings.TrimPrefix(a, name+"=")
		}
	}
	return ""
}

// Resolve は「file.yarn:行」をノードへ解く。ファイルはゲームの根からの .yarn。
func Resolve(root, spot string) (Target, error) {
	i := strings.LastIndex(spot, ":")
	if i <= 0 {
		return Target{}, fmt.Errorf("<file.yarn>:<行> の形で渡す（例 assets/talk/novel.yarn:40）: %q", spot)
	}
	file, lineText := spot[:i], spot[i+1:]
	line, err := strconv.Atoi(lineText)
	if err != nil || line < 1 {
		return Target{}, fmt.Errorf("行は 1 以上の数: %q", lineText)
	}
	abs := file
	if !filepath.IsAbs(abs) {
		abs = filepath.Join(root, file)
	}
	rel, err := filepath.Rel(root, abs)
	if err != nil || strings.HasPrefix(rel, "..") {
		return Target{}, fmt.Errorf("%s はゲームの根（%s）の外です", file, root)
	}
	rel = filepath.ToSlash(rel)
	text, err := os.ReadFile(abs)
	if err != nil {
		return Target{}, fmt.Errorf("読めない: %s", file)
	}
	nodes, _ := yarn.ParseFile(rel, string(text))
	node := NodeAtLine(nodes, line)
	if node == "" {
		return Target{}, fmt.Errorf("%s:%d より前にノード（title:）がありません", rel, line)
	}
	return Target{File: rel, Node: node, Line: line}, nil
}

// NodeAtLine は title: の行が line 以下の、いちばん後のノードの名前（無ければ空）。
func NodeAtLine(nodes []*yarn.Node, line int) string {
	best, bestLine := "", 0
	for _, n := range nodes {
		if n.Line <= line && n.Line >= bestLine {
			best, bestLine = n.Title, n.Line
		}
	}
	return best
}

// ── goto ─────────────────────────────────────────────────

// registryEntry は ~/.flix_ge_studio/games.json の 1 行（値はどれも文字列）。
type registryEntry struct {
	Dir  string `json:"dir"`
	Pid  string `json:"pid"`
	Port string `json:"port"`
}

// RegistryPath は書き置きの置き場。
func RegistryPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".flix_ge_studio", "games.json")
}

func portOf(root, given string) (int, error) {
	if given == "" {
		given = os.Getenv("DEBUG_HTTP_PORT")
	}
	if given != "" {
		port, err := strconv.Atoi(given)
		if err != nil {
			return 0, fmt.Errorf("ポートは数: %q", given)
		}
		return port, nil
	}
	port, ok := PortFromRegistry(RegistryPath(), root, videos.PidAlive)
	if !ok {
		return 0, fmt.Errorf("起動中のゲームが見つかりません（DEBUG=true で起動したゲームは %s に書き置きます。--port でも渡せます）", RegistryPath())
	}
	return port, nil
}

// PortFromRegistry は書き置きからゲームの根 root の命令口を引く（生きている pid の行のうち最後の物）。
func PortFromRegistry(path, root string, alive func(int) bool) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	var reg struct {
		Games []registryEntry `json:"games"`
	}
	if json.Unmarshal(data, &reg) != nil {
		return 0, false
	}
	want := realPath(root)
	found, ok := 0, false
	for _, e := range reg.Games {
		pid, errPid := strconv.Atoi(e.Pid)
		port, errPort := strconv.Atoi(e.Port)
		if errPid != nil || errPort != nil || realPath(e.Dir) != want || !alive(pid) {
			continue
		}
		found, ok = port, true
	}
	return found, ok
}

func realPath(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	if real, err := filepath.EvalSymlinks(p); err == nil {
		return real
	}
	return filepath.Clean(p)
}

// Goto は起動中のゲームの命令口へ POST /start?name=talk&node=…&line=… を送り、答えの本文を返す。
func Goto(port int, t Target) (string, error) {
	q := url.Values{}
	q.Set("name", "talk")
	q.Set("node", t.Node)
	q.Set("line", strconv.Itoa(t.Line))
	for _, v := range t.Vars {
		name, value, _ := strings.Cut(v, "=")
		q.Set(name, value)
	}
	client := http.Client{Timeout: 15 * time.Second}
	res, err := client.Post(fmt.Sprintf("http://127.0.0.1:%d/start?%s", port, q.Encode()), "text/plain", strings.NewReader(""))
	if err != nil {
		return "", fmt.Errorf("ゲームの命令口（127.0.0.1:%d）に繋がりません: %v", port, err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return string(body), nil
}

// ── shot ─────────────────────────────────────────────────

// Shot は窓なしのゲームで t を 1 枚撮り、PNG のパス（ゲームの根から）を返す。
func Shot(root string, t Target, entry string) (string, error) {
	if entry == "" {
		entry = "E2e.serveHeadless"
	}
	engine, _ := status.FindEngineDir(root, "bin/headless-run")
	if engine == "" {
		return "", fmt.Errorf("engine の bin/headless-run が見つかりません（ENGINE= か local.mk の ENGINE で場所を渡す）")
	}
	cmd := exec.Command(filepath.Join(engine, "bin", "headless-run"), entry)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "FGE_SHOT="+t.StartLine())
	if os.Getenv("HEADLESS_JAVA_OPTS") == "" {
		cmd.Env = append(cmd.Env, "HEADLESS_JAVA_OPTS=-Xmx1g")
	}
	raw, err := cmd.CombinedOutput()
	png := PngOf(string(raw))
	if png == "" {
		tail := strings.TrimSpace(string(raw))
		if lines := strings.Split(tail, "\n"); len(lines) > 6 {
			tail = strings.Join(lines[len(lines)-6:], "\n")
		}
		if err != nil {
			return "", fmt.Errorf("撮れませんでした（%s %s）: %v\n%s", "bin/headless-run", entry, err, tail)
		}
		return "", fmt.Errorf("撮れませんでした（ok png= の行がありません）\n%s", tail)
	}
	return png, nil
}

// PngOf は答えの中の `ok png=<パス>` のパス（無ければ空）。/render・view=shot と同じ形。
func PngOf(text string) string {
	for _, line := range strings.Split(text, "\n") {
		if p, ok := strings.CutPrefix(strings.TrimSpace(line), "ok png="); ok {
			return strings.TrimSpace(p)
		}
	}
	return ""
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}
