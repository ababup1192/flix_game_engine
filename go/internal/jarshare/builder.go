package jarshare

// 作り手（Mac mini）: launchd が 5 分ごとに RunBuilder を起こす（docs/design/prebuilt-jar.md の 4 節・7 節の 2）。
// ゲームの master が前に作った時から進んでいれば、作り手専用の作業場で headless-run --build-only を流し、
// 段 1 と段 2 へ置かせる（headless-run は FGE_JAR_PUBLISH_REMOTE=1 で段 2 へも上げる）。

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"text/template"
)

// BuilderConfig は作り手の 1 巡の設定。
type BuilderConfig struct {
	Repo    string // ゲームの clone（git fetch して作り手の作業場をここから足す）
	Work    string // 作り手の置き場（既定 ~/.flix_ge_studio/prebuilt/<repo の名前>）
	Engines string // 配ったエンジンの置き場（既定 ~/.flix_ge_studio/engines）
	Branch  string // 見る枝（既定 master）
}

// WithDefaults は空の欄を既定で埋めた BuilderConfig を返す。
func (c BuilderConfig) WithDefaults(home string) BuilderConfig {
	if c.Work == "" {
		c.Work = filepath.Join(home, ".flix_ge_studio", "prebuilt", filepath.Base(filepath.Clean(c.Repo)))
	}
	if c.Engines == "" {
		c.Engines = filepath.Join(home, ".flix_ge_studio", "engines")
	}
	if c.Branch == "" {
		c.Branch = "master"
	}
	return c
}

var engineVersionInToml = regexp.MustCompile(`"github:ababup1192/flix_game_engine"\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"`)

// EngineVersionOf はゲームの flix.toml が使うエンジンの版。
func EngineVersionOf(flixToml string) (string, bool) {
	m := engineVersionInToml.FindStringSubmatch(flixToml)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// RunBuilder は作り手の 1 巡。進んでいなければ何もせずに nil。log へ 1 巡の行を書く。
func RunBuilder(cfg BuilderConfig, log io.Writer) error {
	if cfg.Repo == "" {
		return errors.New("--repo（ゲームの clone）が要る")
	}
	if err := os.MkdirAll(cfg.Work, 0o755); err != nil {
		return err
	}
	unlock, err := lockDir(filepath.Join(cfg.Work, ".lock"))
	if err != nil {
		fmt.Fprintf(log, "[jar-builder] 前の 1 巡がまだ走っている（%v）\n", err)
		return nil
	}
	defer unlock()
	if err := git(cfg.Repo, "fetch", "-q", "origin", cfg.Branch); err != nil {
		return err
	}
	head, err := gitOut(cfg.Repo, "rev-parse", "origin/"+cfg.Branch)
	if err != nil {
		return err
	}
	lastPath := filepath.Join(cfg.Work, "last-built")
	if strings.TrimSpace(readText(lastPath)) == head {
		return nil
	}
	game := filepath.Join(cfg.Work, "game")
	if _, err := os.Stat(game); err != nil {
		if err := git(cfg.Repo, "worktree", "add", "--detach", game, head); err != nil {
			return err
		}
	} else if err := git(game, "checkout", "-q", "--detach", "-f", head); err != nil {
		return err
	}
	version, ok := EngineVersionOf(readText(filepath.Join(game, "flix.toml")))
	if !ok {
		return errors.New("flix.toml にエンジンの版が無い")
	}
	engine := filepath.Join(cfg.Engines, version)
	if !engineSharesJars(engine) {
		// WhyNot: 止まらない（error にしない）— ゲームが段 2 の口の無い版のエンジンを使っている間は、作っても置けない。
		// 版を上げた push が来た次の巡で作れるので、last-built も書かずに待つ。
		fmt.Fprintf(log, "[jar-builder] %s: エンジン %s に段 2 の口（fge jar）が無いので作らない\n", head[:8], version)
		return nil
	}
	if err := os.WriteFile(filepath.Join(game, "local.mk"), []byte("ENGINE := "+engine+"\n"), 0o644); err != nil {
		return err
	}
	cmd := exec.Command(filepath.Join(engine, "bin", "fge"), "heavy", "--short",
		filepath.Join(engine, "bin", "headless-run"), "--build-only")
	cmd.Dir = game
	cmd.Env = append(os.Environ(), "FGE_JAR_PUBLISH_REMOTE=1", "FGE_JAR_COMMIT="+head)
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: headless-run --build-only が止まった: %v", head[:8], err)
	}
	fmt.Fprintf(log, "[jar-builder] %s: 作った（エンジン %s）\n", head[:8], version)
	return os.WriteFile(lastPath, []byte(head+"\n"), 0o644)
}

// engineSharesJars は、そのエンジンの fge-go が段 2 の口（jar fetch --remote）を持つか。
func engineSharesJars(engine string) bool {
	out, _ := exec.Command(filepath.Join(engine, "bin", "fge-go"), "jar").CombinedOutput()
	return bytes.Contains(out, []byte("--remote"))
}

func git(dir string, args ...string) error {
	_, err := gitOut(dir, args...)
	return err
}

func gitOut(dir string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

// lockDir は mkdir の鍵を取る（中に pid）。持ち主が居なければ外して取り直す。
func lockDir(path string) (func(), error) {
	for i := 0; i < 2; i++ {
		if err := os.Mkdir(path, 0o755); err == nil {
			_ = os.WriteFile(filepath.Join(path, "pid"), []byte(strconv.Itoa(os.Getpid())), 0o644)
			return func() { _ = os.RemoveAll(path) }, nil
		}
		pid, _ := strconv.Atoi(strings.TrimSpace(readText(filepath.Join(path, "pid"))))
		if pid > 0 && processAlive(pid) {
			return nil, fmt.Errorf("pid %d が持っている", pid)
		}
		_ = os.RemoveAll(path)
	}
	return nil, errors.New("鍵を取れない")
}

//go:embed jar-builder.plist
var plistTemplate string

// PlistConfig は launchd の plist の中身。
type PlistConfig struct {
	Label string   // com.flixge.jar-builder.<repo の名前>
	Fge   string   // 作り手を起こす fge（このエンジンの bin/fge）
	Repo  string   // ゲームの clone
	Log   string   // 1 巡の行を書くファイル
	Path  string   // launchd の PATH（git・gh・java を引けるように）
	Args  []string // builder run に足す旗（--work=・--engines=）
}

// LabelOf は repo の clone の場所から launchd の Label を作る。
func LabelOf(repo string) string {
	return "com.flixge.jar-builder." + filepath.Base(filepath.Clean(repo))
}

// RenderPlist は plist の字（純粋）。
func RenderPlist(c PlistConfig) (string, error) {
	t, err := template.New("plist").Parse(plistTemplate)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	if err := t.Execute(&b, c); err != nil {
		return "", err
	}
	return b.String(), nil
}
