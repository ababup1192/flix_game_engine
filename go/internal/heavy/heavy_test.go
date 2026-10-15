//go:build !windows

package heavy

// 何を守るか: 同時に 2 本流さないこと、持ち主の死んだ鍵と古い手書きの鍵だけを外すこと、
// 自分の鍵しか外さないこと、中から呼んだ heavy が自分の鍵を待って止まらないこと。

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// 子のプロセスとして heavy を動かす（pid ごとの列と鍵の取り合いは別プロセスでしか起きない）。
func TestMain(m *testing.M) {
	if os.Getenv("FGE_HEAVY_HELPER") == "1" {
		args := os.Args
		for i, a := range args {
			if a == "--" {
				args = args[i+1:]
				break
			}
		}
		os.Exit(Run(args, false, Options{Poll: 20 * time.Millisecond}))
	}
	os.Exit(m.Run())
}

func heavyCmd(t *testing.T, lock string, args ...string) *exec.Cmd {
	t.Helper()
	c := exec.Command(os.Args[0], append([]string{"-test.run=^$", "--"}, args...)...)
	c.Env = append(os.Environ(), "FGE_HEAVY_HELPER=1", "FGE_HEAVY_LOCK="+lock)
	return c
}

func newLock(t *testing.T) string {
	return filepath.Join(t.TempDir(), "fge-heavy.lock")
}

func TestTwoRunsDoNotOverlap(t *testing.T) {
	lock := newLock(t)
	marker := filepath.Join(t.TempDir(), "running")
	// 同時に 2 本走ると mkdir が失敗して 9 で終わる。
	body := fmt.Sprintf("mkdir %s || exit 9; sleep 0.3; rmdir %s", marker, marker)
	var wg sync.WaitGroup
	codes := make([]int, 3)
	for i := range codes {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c := heavyCmd(t, lock, "sh", "-c", body)
			if err := c.Run(); err != nil {
				codes[i] = c.ProcessState.ExitCode()
			}
		}(i)
	}
	wg.Wait()
	for i, code := range codes {
		if code != 0 {
			t.Fatalf("%d 本目が %d で終わった（重なって走った）", i, code)
		}
	}
	if _, err := os.Stat(lock); !os.IsNotExist(err) {
		t.Fatalf("終わった後も鍵が残っている")
	}
}

func TestDeadOwnerLockIsTaken(t *testing.T) {
	lock := newLock(t)
	os.Mkdir(lock, 0o755)
	dead := exec.Command("true")
	dead.Run()
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: dead.Process.Pid, Command: "make test", Since: time.Now()})
	c := heavyCmd(t, lock, "true")
	done := make(chan error, 1)
	go func() { done <- c.Run() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("死んだ持ち主の鍵を外せず失敗: %v", err)
		}
	case <-time.After(5 * time.Second):
		c.Process.Kill()
		t.Fatalf("死んだ持ち主の鍵を待ち続けた")
	}
}

func TestYoungAnonymousLockIsKept(t *testing.T) {
	lock := newLock(t)
	os.Mkdir(lock, 0o755)
	if reap(Options{Lock: lock, Now: time.Now, Err: io.Discard}) {
		t.Fatalf("手書きの鍵を %v 経つ前に外した", anonymousStale)
	}
	old := time.Now().Add(-anonymousStale - time.Minute)
	os.Chtimes(lock, old, old)
	if !reap(Options{Lock: lock, Now: time.Now, Err: io.Discard}) {
		t.Fatalf("%v を超えた手書きの鍵を外さなかった", anonymousStale)
	}
}

func TestReleaseLeavesSomeoneElsesLock(t *testing.T) {
	lock := newLock(t)
	os.Mkdir(lock, 0o755)
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: os.Getpid(), Token: "theirs"})
	release(Options{Lock: lock}, "mine")
	if _, err := os.Stat(filepath.Join(lock, ownerFile)); err != nil {
		t.Fatalf("他人の鍵を外した")
	}
}

func TestChildSeesCheckdOffAndExitCode(t *testing.T) {
	lock := newLock(t)
	c := heavyCmd(t, lock, "sh", "-c", `test "$CHECKD" = 0 && exit 7`)
	var env []string
	for _, kv := range c.Env {
		if !strings.HasPrefix(kv, "CHECKD=") {
			env = append(env, kv)
		}
	}
	c.Env = env
	err := c.Run()
	if err == nil || c.ProcessState.ExitCode() != 7 {
		t.Fatalf("CHECKD=0 で子の終了コード 7 が返るはずが %v", err)
	}
}

func TestNestedHeavyDoesNotWaitForItself(t *testing.T) {
	lock := newLock(t)
	inner := strings.Join([]string{os.Args[0], "-test.run=^$", "--", "true"}, " ")
	c := heavyCmd(t, lock, "sh", "-c", inner)
	done := make(chan error, 1)
	go func() { done <- c.Run() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("中の heavy が失敗: %v", err)
		}
	case <-time.After(5 * time.Second):
		c.Process.Kill()
		t.Fatalf("中の heavy が外の鍵を待って止まった")
	}
}
