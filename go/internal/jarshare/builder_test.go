//go:build !windows

package jarshare

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gitIn は dir で git を流す（テストの下ごしらえ）。
func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
}

// gameClone は、master に flix.toml（エンジン 9.9.9）を持つ origin と、その clone を作って clone を返す。
func gameClone(t *testing.T) string {
	t.Helper()
	base := t.TempDir()
	origin := filepath.Join(base, "origin")
	seed := filepath.Join(base, "seed")
	clone := filepath.Join(base, "game")
	for _, d := range []string{origin, seed} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gitIn(t, origin, "init", "-q", "--bare", "-b", "master")
	gitIn(t, seed, "init", "-q", "-b", "master")
	write(t, filepath.Join(seed, "flix.toml"), `"github:ababup1192/flix_game_engine" = { version = "9.9.9", mount = "fge" }`)
	gitIn(t, seed, "add", ".")
	gitIn(t, seed, "commit", "-q", "-m", "seed")
	gitIn(t, seed, "remote", "add", "origin", origin)
	gitIn(t, seed, "push", "-q", "origin", "master")
	gitIn(t, base, "clone", "-q", origin, clone)
	return clone
}

// fakeEngine は engines/9.9.9 に偽のエンジンを置く。shares なら fge-go の使い方に --remote があり、bin/fge は流した印を残す。
func fakeEngine(t *testing.T, shares bool) (engines, ran string) {
	t.Helper()
	engines = t.TempDir()
	bin := filepath.Join(engines, "9.9.9", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	usage := "使い方: jar key"
	if shares {
		usage += " [--remote]"
	}
	ran = filepath.Join(engines, "ran")
	write(t, filepath.Join(bin, "fge-go"), "#!/bin/sh\necho '"+usage+"' >&2\nexit 2\n")
	write(t, filepath.Join(bin, "fge"), "#!/bin/sh\necho \"$FGE_JAR_PUBLISH_REMOTE $FGE_JAR_COMMIT\" >> "+ran+"\n")
	for _, f := range []string{"fge-go", "fge"} {
		if err := os.Chmod(filepath.Join(bin, f), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return engines, ran
}

// ゲームの版のエンジンに段 2 の口が無ければ、作らず、last-built も書かない（版を上げた push の後の巡で作る）。
func TestRunBuilderWaitsForAnEngineWithoutSharing(t *testing.T) {
	engines, ran := fakeEngine(t, false)
	cfg := BuilderConfig{Repo: gameClone(t), Work: t.TempDir(), Engines: engines}.WithDefaults(t.TempDir())
	var log bytes.Buffer
	if err := RunBuilder(cfg, &log); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(ran); !os.IsNotExist(err) {
		t.Fatal("段 2 の口の無いエンジンで作った")
	}
}

// 口のあるエンジンなら、作り手の作業場で 1 回作らせ（段 2 へ上げる印つき）、同じ master の 2 巡目は何もしない。
func TestRunBuilderBuildsOncePerMasterCommit(t *testing.T) {
	engines, ran := fakeEngine(t, true)
	cfg := BuilderConfig{Repo: gameClone(t), Work: t.TempDir(), Engines: engines}.WithDefaults(t.TempDir())
	var log bytes.Buffer
	for i := 0; i < 2; i++ {
		if err := RunBuilder(cfg, &log); err != nil {
			t.Fatal(err)
		}
	}
	lines := strings.Split(strings.TrimSpace(read(t, ran)), "\n")
	if len(lines) != 1 || !strings.HasPrefix(lines[0], "1 ") {
		t.Fatalf("got %q", lines)
	}
}
