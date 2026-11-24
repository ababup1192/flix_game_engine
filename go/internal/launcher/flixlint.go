package launcher

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/shellrun"
)

// LintFlixlint は lint/rules.flix の規則を型つきの AST で見る（mk/game.mk の lint-flixlint と同じ中身）。
// vars の FLIXLINT_STAGE（既定 resolved）と FLIXLINT_JAR（既定は bin/flix が使う flix.jar）を読む。
func (l *Launcher) LintFlixlint(vars map[string]string) int {
	if _, err := os.Stat(filepath.Join(l.Root, "lint", "rules.flix")); err != nil {
		fmt.Fprintln(l.Stderr, "lint-flixlint: lint/rules.flix がありません（手本はテンプレートの lint/rules.flix）")
		return 2
	}
	// WhyNot: Windows でも flixlint の起動役（bash）を Git Bash で起こす — flixlint 0.9.1 の起動役は Windows に未対応で、
	// engine.jar の鍵に shasum を決め打ちで呼び（bin/flixlint:329・Git for Windows に無い）、java のクラスパスを ':' 区切りの
	// /c/... で組むので Windows の java が flixlint.Lint を見つけられない（Windows の CI の 4・5 回目）。flixlint の側で直るまで飛ばす。
	if runtime.GOOS == "windows" {
		fmt.Fprintln(l.Stderr, "[lint-flixlint] Windows では飛ばしました（flixlint の起動役が Windows に未対応。型検査は bin/fge check で流れる。lint は macOS か Linux で）")
		return 0
	}
	prep, err := l.prepareFlixlint()
	if err != nil {
		fmt.Fprintf(l.Stderr, "lint-flixlint: %v\n", err)
		return 2
	}
	jar := vars["FLIXLINT_JAR"]
	if jar == "" {
		if jar, err = l.flixJar(); err != nil {
			fmt.Fprintf(l.Stderr, "lint-flixlint: %v\n", err)
			return 2
		}
	}
	stage := vars["FLIXLINT_STAGE"]
	if stage == "" {
		stage = "resolved"
	}
	args := []string{"--flix-jar", jar, "--shim", prep["FLIXLINT_SHIM"], "--rules", "lint/rules.flix"}
	if st, err := os.Stat(filepath.Join(l.Root, "lint", "limits")); err == nil && st.IsDir() {
		args = append(args, "--limits", "lint/limits")
	}
	args = append(args, "--stage", stage, "--build-dir", "build/flixlint", "src", "test")
	cmd, err := shellrun.Command(filepath.Join(prep["FLIXLINT_DIR"], "bin", "flixlint"), args...)
	if err != nil {
		fmt.Fprintf(l.Stderr, "lint-flixlint: %v\n", err)
		return 2
	}
	cmd = l.wire(cmd)
	if path := prep["PATH"]; path != "" {
		cmd.Env = withEnv(os.Environ(), map[string]string{"PATH": path})
	}
	return shellrun.Run(cmd, "lint-flixlint")
}

// prepareFlixlint は同じ版の fge の flixlint-prepare を流し、KEY='値' の行を読む。
func (l *Launcher) prepareFlixlint() (map[string]string, error) {
	cmd := exec.Command(l.Self, "flixlint-prepare")
	cmd.Dir = l.Root
	cmd.Stderr = l.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("flixlint-prepare が止まりました: %w", err)
	}
	return parseAssignments(out), nil
}

func parseAssignments(out []byte) map[string]string {
	vals := map[string]string{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), "=")
		if !ok || k == "" {
			continue
		}
		vals[k] = strings.TrimSuffix(strings.TrimPrefix(v, "'"), "'")
	}
	return vals
}

// flixJar は bin/flix が使う flix.jar（FLIX_PRINT_JAR=1）。Windows の Git Bash が返す /c/... は java が読める形に直す。
func (l *Launcher) flixJar() (string, error) {
	cmd, err := shellrun.Command(l.script("flix"))
	if err != nil {
		return "", err
	}
	cmd.Dir = l.Root
	cmd.Env = append(os.Environ(), "FLIX_PRINT_JAR=1")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("flix.jar の場所を bin/flix から引けません: %w", err)
	}
	jar := strings.TrimSpace(string(out))
	if jar == "" {
		return "", fmt.Errorf("bin/flix が flix.jar の場所を返しませんでした")
	}
	return shellrun.NativePath(runtime.GOOS, jar), nil
}
