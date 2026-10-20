package jarshare

// 作り手のエンジンの置き場を、作り手が自分で用意する（docs/design/prebuilt-jar.md の 4 節）。
// ゲームの flix.toml の版の置き場が無ければ、エンジンの repo のその版のタグから作業場を作り、fge-go を組み、
// コンパイラの jar（bin/flix.jar）を置く。どの手も済んでいれば飛ばすので、途中で止まっても次の巡でやり直せる。

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// EngineRepoURL はエンジンの repo（作り手専用の clone を作る元）。
const EngineRepoURL = "https://github.com/ababup1192/flix_game_engine.git"

var devboxFlix = regexp.MustCompile(`flix_([0-9]+)_([0-9]+)_([0-9]+)`)

// FlixVersionOf はエンジンの devbox.json が決める flix の版（"0.78.0"）。
func FlixVersionOf(devboxJSON string) (string, bool) {
	m := devboxFlix.FindStringSubmatch(devboxJSON)
	if m == nil {
		return "", false
	}
	return m[1] + "." + m[2] + "." + m[3], true
}

// FlixJarVersion は flix.jar の版を読む口（テストでは偽物に替える）。
type FlixJarVersion func(jar string) (string, error)

var versionInOutput = regexp.MustCompile(`[0-9]+\.[0-9]+\.[0-9]+`)

// JavaFlixJarVersion は java -jar <jar> --version で版を読む（リリースの check-bundle-flix と同じ確かめ方）。
func JavaFlixJarVersion(jar string) (string, error) {
	out, err := exec.Command("java", "-jar", jar, "--version").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("java -jar %s --version: %v", jar, err)
	}
	v := versionInOutput.FindString(string(out))
	if v == "" {
		return "", fmt.Errorf("%s の版を読めない", jar)
	}
	return v, nil
}

// Provisioner は作り手のエンジンの置き場を用意する口。
type Provisioner struct {
	Engines    string         // 置き場（<Engines>/<版>）
	EngineRepo string         // エンジンの repo の作り手専用の clone（無ければ EngineRepoURL から作る）
	GH         GH             // flix.jar を flix の Release から落とす
	JarVersion FlixJarVersion // flix.jar の版を読む
	Log        io.Writer
}

// Ready は置き場の版が使える形か（fge-go とコンパイラの jar がそろっている）。
func Ready(engine string) bool {
	for _, f := range []string{filepath.Join("bin", "fge-go"), filepath.Join("bin", "flix.jar"), filepath.Join("bin", "headless-run")} {
		if _, err := os.Stat(filepath.Join(engine, f)); err != nil {
			return false
		}
	}
	return true
}

// Provision は <Engines>/<version> を用意する。用意できたら nil。タグがまだ無ければ ErrNoTag。
func (p Provisioner) Provision(ctx context.Context, version string) error {
	engine := filepath.Join(p.Engines, version)
	if Ready(engine) {
		return nil
	}
	if err := os.MkdirAll(p.Engines, 0o755); err != nil {
		return err
	}
	if err := p.ensureRepo(); err != nil {
		return err
	}
	tag := "v" + version
	if _, err := gitOut(p.EngineRepo, "rev-parse", "-q", "--verify", "refs/tags/"+tag); err != nil {
		return ErrNoTag
	}
	if _, err := os.Stat(engine); err != nil {
		// WhyNot: 置き場の名前のまま作らない — 作っている途中で止まると、半端な作業場が「その版の置き場」に見える。
		// 一時の名前で作ってから worktree move で移す（移すのは git の手続き 1 回）。
		tmp := filepath.Join(p.Engines, ".tmp-"+version)
		_ = git(p.EngineRepo, "worktree", "remove", "--force", tmp)
		_ = os.RemoveAll(tmp)
		if err := git(p.EngineRepo, "worktree", "add", "--detach", tmp, tag); err != nil {
			return err
		}
		if err := git(p.EngineRepo, "worktree", "move", tmp, engine); err != nil {
			return err
		}
		fmt.Fprintf(p.Log, "[jar-builder] エンジン %s の作業場を作った（%s）\n", version, tag)
	}
	if err := p.buildFgeGo(engine); err != nil {
		return err
	}
	if err := p.placeFlixJar(ctx, engine); err != nil {
		return err
	}
	if !Ready(engine) {
		return fmt.Errorf("エンジン %s の置き場がそろわない", version)
	}
	fmt.Fprintf(p.Log, "[jar-builder] エンジン %s を用意した\n", version)
	return nil
}

// ErrNoTag はエンジンの repo にその版のタグがまだ無い（出たばかりで fetch が追いついていない・出ていない）。
var ErrNoTag = errors.New("エンジンの repo にその版のタグが無い")

func (p Provisioner) ensureRepo() error {
	if _, err := os.Stat(filepath.Join(p.EngineRepo, ".git")); err != nil {
		if err := os.MkdirAll(filepath.Dir(p.EngineRepo), 0o755); err != nil {
			return err
		}
		out, err := exec.Command("git", "clone", "-q", "--filter=blob:none", "--no-checkout", EngineRepoURL, p.EngineRepo).CombinedOutput()
		if err != nil {
			return fmt.Errorf("エンジンの repo を clone できない: %v: %s", err, strings.TrimSpace(string(out)))
		}
	}
	return git(p.EngineRepo, "fetch", "-q", "--tags", "origin")
}

// buildFgeGo は置き場の fge-go を組む（手元の OS の分だけ。make go-build は 5 つの OS 向けに組むので重い）。
func (p Provisioner) buildFgeGo(engine string) error {
	if _, err := os.Stat(filepath.Join(engine, "bin", "fge-go")); err == nil {
		return nil
	}
	cmd := exec.Command("go", "build", "-ldflags=-s -w", "-o", filepath.Join("..", "bin", "fge-go"), ".")
	cmd.Dir = filepath.Join(engine, "go")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("fge-go を組めない: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// placeFlixJar は置き場の bin/flix.jar を、devbox.json の版の物にする。ほかの版の置き場に同じ版の jar があれば写し、
// 無ければ flix の Release から落とす。どちらも --version が devbox.json の版と同じかを確かめてから置く。
func (p Provisioner) placeFlixJar(ctx context.Context, engine string) error {
	dest := filepath.Join(engine, "bin", "flix.jar")
	if _, err := os.Stat(dest); err == nil {
		return nil
	}
	want, ok := FlixVersionOf(readText(filepath.Join(engine, "devbox.json")))
	if !ok {
		return errors.New("devbox.json に flix の版が無い")
	}
	tmp := filepath.Join(engine, "bin", ".flix.jar.tmp")
	defer os.Remove(tmp)
	if from := p.sameFlixJar(want, engine); from != "" {
		if err := copyAtomic(from, tmp); err != nil {
			return err
		}
	} else {
		dir, err := os.MkdirTemp(filepath.Join(engine, "bin"), ".dl-flix-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
		if _, err := p.GH.Run(ctx, dir, "release", "download", "v"+want, "-R", "flix/flix", "-p", "flix.jar", "-D", dir); err != nil {
			return fmt.Errorf("flix %s の jar を落とせない: %v", want, err)
		}
		if err := os.Rename(filepath.Join(dir, "flix.jar"), tmp); err != nil {
			return err
		}
	}
	got, err := p.JarVersion(tmp)
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf("flix.jar の版が %s（devbox.json は %s）", got, want)
	}
	return os.Rename(tmp, dest)
}

// sameFlixJar は、ほかの版の置き場で、同じ flix の版のコンパイラの jar を探す（無ければ空）。
func (p Provisioner) sameFlixJar(want, self string) string {
	items, _ := os.ReadDir(p.Engines)
	for _, it := range items {
		other := filepath.Join(p.Engines, it.Name())
		if other == self || strings.HasPrefix(it.Name(), ".") {
			continue
		}
		jar := filepath.Join(other, "bin", "flix.jar")
		if _, err := os.Stat(jar); err != nil {
			continue
		}
		if v, ok := FlixVersionOf(readText(filepath.Join(other, "devbox.json"))); ok && v == want {
			return jar
		}
	}
	return ""
}
