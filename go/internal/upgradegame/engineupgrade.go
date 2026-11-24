package upgradegame

// engine-upgrade — ゲームのフォルダで打つ版上げの入口（make engine-upgrade [TO=<版>] の中身）。決まりの本文は
// plans/onboarding.md の 2.9 と plans/windows.md 5 節の #8。
//
//	fge engine-upgrade [TO=<版>] [REFERENCE=1]
//
// TO が無ければゲームの今の engine へ追随する。TO は配った engine の時だけ: その版を ~/.flix_ge/engines/<版> に入れてから上げる。
// 配った engine はその engine の fge-go の upgrade-game を直に起こし、clone した engine は make upgrade-game を起こす
// （engine_full の束が古くないかを見る engine-full-fresh が make の側にあるため）。

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fgeinstall"
	"github.com/ababup1192/flix_game_engine/go/internal/scaffold"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

const engineUpgradeUsage = "使い方: fge engine-upgrade [TO=<版>] [REFERENCE=1]"

// EngineUpgradeDeps は外の世界とつなぐ所。テストは差し替える。
type EngineUpgradeDeps struct {
	Out, Err io.Writer
	Getwd    func() (string, error)
	// ResolveEngine はゲームの今の engine（status.ResolveEngineDir と同じ決まり）。
	ResolveEngine func(game string) string
	Install       func(version string) (string, error)
	// Exec は子のプロセスを流して終了コードを返す（起こせなければ err）。
	Exec func(dir, name string, args ...string) (int, error)
	GOOS string
}

// DefaultEngineUpgradeDeps は本物の置き場・網・exec を使う。
func DefaultEngineUpgradeDeps() EngineUpgradeDeps {
	return EngineUpgradeDeps{
		Out: os.Stdout, Err: os.Stderr,
		Getwd: os.Getwd,
		ResolveEngine: func(game string) string {
			dir, self := status.ResolveEngineDir(game)
			if self {
				return ""
			}
			return dir
		},
		Install: func(version string) (string, error) {
			res, err := fgeinstall.DefaultEnv().Install(version)
			return res.EngineDir, err
		},
		Exec: func(dir, name string, args ...string) (int, error) {
			c := exec.Command(name, args...)
			c.Dir = dir
			c.Stdout, c.Stderr, c.Stdin = os.Stdout, os.Stderr, os.Stdin
			err := c.Run()
			if ee, ok := err.(*exec.ExitError); ok {
				return ee.ExitCode(), nil
			}
			if err != nil {
				return 1, err
			}
			return 0, nil
		},
		GOOS: runtime.GOOS,
	}
}

// RunEngineUpgrade は fge engine-upgrade の本体。
func RunEngineUpgrade(args []string, d EngineUpgradeDeps) int {
	to, reference := "", false
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "TO="):
			to = strings.TrimPrefix(a, "TO=")
		case a == "REFERENCE=1" || a == "--reference":
			reference = true
		case a == "REFERENCE=" || a == "REFERENCE=0":
		default:
			fmt.Fprintf(d.Err, "error: 知らない引数です: %s\n%s\n", a, engineUpgradeUsage)
			return exitBadUsage
		}
	}
	game, err := d.Getwd()
	if err != nil {
		fmt.Fprintf(d.Err, "error: %v\n", err)
		return exitBadUsage
	}
	if _, err := os.Stat(filepath.Join(game, "flix.toml")); err != nil {
		fmt.Fprintf(d.Err, "error: %s はゲームのフォルダではありません（flix.toml がありません）\n", game)
		return exitBadUsage
	}
	current := d.ResolveEngine(game)
	engine := current
	if to != "" {
		if current != "" && !scaffold.IsBundle(current) {
			fmt.Fprintln(d.Err, "error: TO= は配った engine の時だけ使えます。clone した engine は、engine の版を替えてから make engine-upgrade を打ってください")
			return exitUnknown
		}
		dir, err := d.Install(to)
		if err != nil {
			fmt.Fprintf(d.Err, "error: engine %s を入れられません: %v\n", to, err)
			return exitUnknown
		}
		engine = dir
	}
	if engine == "" {
		fmt.Fprintln(d.Err, "error: このゲームの engine が見つかりません（local.mk の ENGINE か、TO=<版> で名指ししてください）")
		return exitUnknown
	}
	if !scaffold.IsBundle(engine) {
		makeArgs := []string{"-C", engine, "upgrade-game", "GAME=" + game}
		if reference {
			makeArgs = append(makeArgs, "REFERENCE=1")
		}
		code, err := d.Exec(game, "make", makeArgs...)
		if err != nil {
			fmt.Fprintf(d.Err, "error: make upgrade-game を起こせません: %v\n", err)
			return exitUnknown
		}
		return code
	}
	upArgs, err := UpgradeGameArgs(engine, game, reference)
	if err != nil {
		fmt.Fprintf(d.Err, "error: %v\n", err)
		return exitUnknown
	}
	fge := filepath.Join(engine, "bin", "fge-go")
	if d.GOOS == "windows" {
		fge += ".exe"
	}
	code, err := d.Exec(engine, fge, upArgs...)
	if err != nil {
		fmt.Fprintf(d.Err, "error: %s を起こせません: %v\n", fge, err)
		return exitUnknown
	}
	// WhyNot: 追随待ち（3）を 0 に潰す — 非互換のある版上げでは直すまで check が赤いのが正常で、何をすべきかは指示書に書いてある。
	// 区別したい呼び手（CI・Studio）は upgrade-game を直に呼ぶ。
	if code == exitFollowUp {
		return exitDone
	}
	return code
}

// UpgradeGameArgs は配った engine の upgrade-game に渡す引数（Makefile の upgrade-game と同じ物）。
func UpgradeGameArgs(engine, game string, reference bool) ([]string, error) {
	version, err := scaffold.EngineVersion(engine)
	if err != nil {
		return nil, err
	}
	ef, err := scaffold.EngineFullFiles(engine, version)
	if err != nil {
		return nil, err
	}
	args := []string{"upgrade-game", "--game", game, "--version", version,
		"--fpkg", ef.Fpkg, "--toml", ef.Toml, "--dest", ef.Subpath,
		"--fpkg-name", ef.FpkgName, "--toml-name", ef.TomlName}
	if scaffold.IsBundle(engine) {
		args = append(args, "--no-content-swap")
	}
	if reference {
		args = append(args, "--reference")
	}
	return args, nil
}
