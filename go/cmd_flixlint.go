package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkd"
	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

// make lint-flixlint の下ごしらえ: flixlint の本体 (bin/flixlint と規則の engine) と shim の jar を、hooks.json の
// checkd.server が決める版でそろえ、置き場を sh の代入 2 行で返す (Makefile が eval して bin/flixlint を流す)。
//
// WhyNot: flixlint を流すところまでここでしない。出力を貯めてから返す作りなので、型検査の待ちの間に何も出ず、
// 違反の行も終わるまで見えない。流すのは make のレシピ (出力がそのまま流れる)。
// WhyNot: ゲームごとに submodule を置かせない。テンプレートは engine のリポの中にあり submodule を持てず、
// 版はエンジンの版ごとに 1 つ (check の常駐と同じ hooks.json の pin) で足りる。
func init() {
	register("flixlint-prepare", "make lint-flixlint の下ごしらえ: hooks.json の版の flixlint の本体と shim の jar をそろえ、置き場を FLIXLINT_DIR= と FLIXLINT_SHIM= の 2 行で返す",
		func(out, errOut *strings.Builder, _ []string, _ bool) int {
			dir, shim, err := prepareFlixlint(repoRoot())
			if err != nil {
				return orAbort(errOut, 0, err)
			}
			fmt.Fprintf(out, "FLIXLINT_DIR='%s'\nFLIXLINT_SHIM='%s'\n", dir, shim)
			return 0
		})
}

func prepareFlixlint(root string) (string, string, error) {
	r, err := hooks.LoadRules(root)
	if err != nil {
		return "", "", err
	}
	sv := r.Checkd.Server
	if sv.FlixlintVersion == nil || sv.RepoURL == nil {
		return "", "", fmt.Errorf("hooks.json の checkd.server に flixlintVersion と repoUrl が要る")
	}
	shim, err := checkd.ShimJar(r)
	if err != nil {
		return "", "", err
	}
	dir := filepath.Join(hooks.CacheDir(r), "flixlint", *sv.FlixlintVersion, "src")
	if _, err := os.Stat(filepath.Join(dir, "bin", "flixlint")); err == nil {
		return dir, shim, nil
	}
	part := dir + ".part"
	_ = os.RemoveAll(part)
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return "", "", err
	}
	tag := "v" + *sv.FlixlintVersion
	clone := exec.Command("git", "clone", "--quiet", "--depth", "1", "--branch", tag, *sv.RepoURL, part)
	if msg, err := clone.CombinedOutput(); err != nil {
		_ = os.RemoveAll(part)
		return "", "", fmt.Errorf("flixlint %s を取れない (%s): %v\n%s", tag, *sv.RepoURL, err, msg)
	}
	return dir, shim, os.Rename(part, dir)
}
