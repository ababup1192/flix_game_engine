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
	path := prep["PATH"]
	if path == "" {
		path = os.Getenv("PATH")
	}
	if runtime.GOOS == "windows" {
		shim, err := l.writeShasumShim()
		if err != nil {
			fmt.Fprintf(l.Stderr, "lint-flixlint: %v\n", err)
			return 2
		}
		path = shim + string(os.PathListSeparator) + path
	}
	cmd.Env = withEnv(os.Environ(), map[string]string{"PATH": path})
	return shellrun.Run(cmd, "lint-flixlint")
}

// shasumShim は shasum（macOS と Linux の perl の道具）を Git Bash にある sha1sum・sha256sum へ渡す sh。
// WhyNot: flixlint の起動役をそのまま起こす — 起動役の engine.jar の鍵が `shasum` を決め打ちで呼び（flixlint 0.9.1 の bin/flixlint:329）、
// Git for Windows には shasum が無く、鍵が作れずに止まる（Windows の CI の 4 回目）。flixlint の側で直るまでの手当て。
const shasumShim = `#!/bin/sh
if [ "$1" = "-a" ]; then algo=$2; shift 2; else algo=1; fi
exec "sha${algo}sum" "$@"
`

// writeShasumShim は build/flixlint/shim/shasum を書き、その置き場を返す。
func (l *Launcher) writeShasumShim() (string, error) {
	dir := filepath.Join(l.Root, "build", "flixlint", "shim")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dir, "shasum"), []byte(shasumShim), 0o755); err != nil {
		return "", err
	}
	return dir, nil
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
