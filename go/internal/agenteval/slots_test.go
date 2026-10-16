//go:build !windows

package agenteval

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// 枠が埋まっていれば、どれかが返されるまで次は始まらない（作業場をまたいで同時本数を守る）。
func TestSlotsWaitUntilOneIsReleased(t *testing.T) {
	s := &slots{dir: t.TempDir(), limit: 2, poll: 5 * time.Millisecond, log: io.Discard}
	a, _ := s.acquire()
	_, _ = s.acquire()
	got := make(chan struct{})
	go func() {
		release, _ := s.acquire()
		release()
		close(got)
	}()
	select {
	case <-got:
		t.Fatal("枠が埋まっているのに 3 本目が始まった")
	case <-time.After(50 * time.Millisecond):
	}
	a()
	select {
	case <-got:
	case <-time.After(2 * time.Second):
		t.Fatal("枠を返したのに 3 本目が始まらない")
	}
}

// 持ち主のプロセスが死ねば、片付けなくても枠は空く（OS がロックを外す）。
func TestSlotFreedWhenOwnerProcessDies(t *testing.T) {
	if os.Getenv("FGE_SLOT_HOLDER") != "" {
		s := &slots{dir: os.Getenv("FGE_SLOT_HOLDER"), limit: 1, poll: time.Millisecond, log: io.Discard}
		s.acquire()
		os.WriteFile(filepath.Join(s.dir, "held"), nil, 0o666)
		time.Sleep(time.Minute)
		return
	}
	dir := t.TempDir()
	c := exec.Command(os.Args[0], "-test.run=TestSlotFreedWhenOwnerProcessDies")
	c.Env = append(os.Environ(), "FGE_SLOT_HOLDER="+dir)
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	for i := 0; ; i++ {
		if _, err := os.Stat(filepath.Join(dir, "held")); err == nil {
			break
		}
		if i > 500 {
			t.Fatal("子が枠を取らない")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok, _ := tryLock(filepath.Join(dir, "0.lock")); ok {
		t.Fatal("子が持っている枠を取れてしまった")
	}
	c.Process.Kill()
	c.Wait()
	if _, ok, _ := tryLock(filepath.Join(dir, "0.lock")); !ok {
		t.Fatal("持ち主が死んだのに枠が空かない")
	}
}
