package headlessrun

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func repoRoot() string { return filepath.Join("..", "..", "..") }

func write(t *testing.T, path, body string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
}

// fakeGame は、headless-run の写しを持つエンジンと、入口 1 つのゲームを作ってゲームの根を返す。
// 偽の flix は build-fatjar で artifact/ に小さな jar を置くだけ（コンパイルしない）。
// エンジンに bin/fge-go を置かないので、jar が古いかは更新時刻で決まり、段 1・段 2 の分け合いも動かない。
func fakeGame(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	script, err := os.ReadFile(filepath.Join(repoRoot(), "bin", "headless-run"))
	if err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(root, "engine", "bin", "headless-run"), string(script), 0o755)
	write(t, filepath.Join(root, "fakeflix"), "#!/bin/sh\n[ \"$1\" = build-fatjar ] || exit 1\nmkdir -p artifact\necho jar > artifact/game.jar\n", 0o755)
	game := filepath.Join(root, "game")
	write(t, filepath.Join(game, "flix.toml"), "[package]\nname = \"game\"\n", 0o644)
	write(t, filepath.Join(game, "src", "Shot.flix"), "mod Shot {\n    pub def all(): Unit \\ IO = ()\n}\n", 0o644)
	return game
}

// run は headless-run を引数 args で流し、終わりの番号と標準エラーを返す。
func run(t *testing.T, game string, args ...string) (int, string) {
	t.Helper()
	root := filepath.Dir(game)
	cmd := exec.Command("bash", append([]string{filepath.Join(root, "engine", "bin", "headless-run")}, args...)...)
	cmd.Dir = game
	cmd.Env = append(os.Environ(), "FLIX_CMD="+filepath.Join(root, "fakeflix"), "HEADLESS_LOCK_WAIT_SECONDS=2", "LC_ALL=en_US.UTF-8")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	code := 0
	if exit, ok := err.(*exec.ExitError); ok {
		code = exit.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return code, stderr.String()
}

func lockDir(game string) string { return filepath.Join(game, "build", "headless", ".lock") }

// placeLock は鍵を置く。pid が空なら pid のファイルを置かない。age だけ古くする。
func placeLock(t *testing.T, game, pid string, age time.Duration) {
	t.Helper()
	dir := lockDir(game)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if pid != "" {
		write(t, filepath.Join(dir, "pid"), pid+"\n", 0o644)
	}
	old := time.Now().Add(-age)
	if err := os.Chtimes(dir, old, old); err != nil {
		t.Fatal(err)
	}
}

// deadPid は、もう終わったプロセスの pid。
func deadPid(t *testing.T) string {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return strconv.Itoa(cmd.Process.Pid)
}

// livePid は、テストの間だけ生きているプロセスの pid。
func livePid(t *testing.T) string {
	t.Helper()
	cmd := exec.Command("sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	return strconv.Itoa(cmd.Process.Pid)
}

// leftovers は build/headless に残った鍵の名残（.lock・.lock.new.*・.lock.stale.*・.lock.done.*）。
func leftovers(t *testing.T, game string) []string {
	t.Helper()
	found, err := filepath.Glob(filepath.Join(game, "build", "headless", ".lock*"))
	if err != nil {
		t.Fatal(err)
	}
	return found
}

func TestBuildsAndLeavesNoLock(t *testing.T) {
	game := fakeGame(t)
	if code, stderr := run(t, game, "--build-only"); code != 0 {
		t.Fatalf("終わりの番号 %d: %s", code, stderr)
	}
	if got := leftovers(t, game); len(got) != 0 {
		t.Fatalf("鍵の名残: %v", got)
	}
}

func TestEmptyOldLockIsTakenOver(t *testing.T) {
	game := fakeGame(t)
	placeLock(t, game, "", 2*time.Minute)
	if code, stderr := run(t, game, "--build-only"); code != 0 {
		t.Fatalf("終わりの番号 %d: %s", code, stderr)
	}
	if _, err := os.Stat(filepath.Join(game, "build", "headless", "headless.jar")); err != nil {
		t.Fatalf("jar が無い: %v", err)
	}
}

func TestDeadOwnerLockIsRemoved(t *testing.T) {
	game := fakeGame(t)
	pid := deadPid(t)
	placeLock(t, game, pid, time.Second)
	code, stderr := run(t, game, "--build-only")
	if code != 0 {
		t.Fatalf("終わりの番号 %d: %s", code, stderr)
	}
	if !strings.Contains(stderr, "古い鍵を外した（pid "+pid+"・") {
		t.Fatalf("外した知らせが無い: %s", stderr)
	}
}

func TestLiveOwnerLockStopsWithPidAndAge(t *testing.T) {
	game := fakeGame(t)
	pid := livePid(t)
	placeLock(t, game, pid, 5*time.Second)
	code, stderr := run(t, game, "--build-only")
	if code != 3 {
		t.Fatalf("終わりの番号 %d（3 を待った）: %s", code, stderr)
	}
	if !strings.Contains(stderr, "jar を作る鍵を待つ（pid "+pid+"・鍵の年齢 ") {
		t.Fatalf("待つ行に pid と年齢が無い: %s", stderr)
	}
	if !strings.Contains(stderr, "秒待っても jar を作る鍵が空かない（鍵: build/headless/.lock・pid "+pid+"・") {
		t.Fatalf("止める知らせが崩れている: %s", stderr)
	}
}

func TestLiveOwnerLockIsKept(t *testing.T) {
	game := fakeGame(t)
	pid := livePid(t)
	placeLock(t, game, pid, 5*time.Second)
	run(t, game, "--build-only")
	got, err := os.ReadFile(filepath.Join(lockDir(game), "pid"))
	if err != nil || strings.TrimSpace(string(got)) != pid {
		t.Fatalf("生きている作り手の鍵が外された: %q %v", got, err)
	}
}

func TestStatusOfLocks(t *testing.T) {
	cases := []struct {
		name string
		pid  func(t *testing.T) string
		age  time.Duration
		want string
	}{
		{"pid の無い若い鍵は作っている途中", func(*testing.T) string { return "" }, time.Second, "building"},
		{"pid の無い古い鍵は誰も持っていない", func(*testing.T) string { return "" }, 2 * time.Minute, "stale"},
		{"作り手の居ない鍵は誰も持っていない", deadPid, time.Second, "stale"},
		{"作り手の生きている鍵", livePid, time.Second, "building"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			game := fakeGame(t)
			placeLock(t, game, c.pid(t), c.age)
			root := filepath.Dir(game)
			cmd := exec.Command("bash", filepath.Join(root, "engine", "bin", "headless-run"), "--status")
			cmd.Dir = game
			out, err := cmd.Output()
			if err != nil {
				t.Fatal(err)
			}
			if got := strings.TrimSpace(string(out)); got != c.want {
				t.Fatalf("got %q want %q", got, c.want)
			}
		})
	}
}
