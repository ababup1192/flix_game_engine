package agenteval

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 枠が埋まっていれば、どれかが返されるまで次は始まらない（作業場をまたいで同時本数を守る）。
func TestSlotsWaitUntilOneIsReleased(t *testing.T) {
	s := &slots{dir: t.TempDir(), limit: 2, poll: 5 * time.Millisecond, log: io.Discard}
	a, _ := s.acquire("a")
	_, _ = s.acquire("b")
	got := make(chan struct{})
	go func() {
		release, _ := s.acquire("c")
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

// 持ち主が死んで残った枠は、次に枠を探した人が片付けて使う。
func TestSlotsReapDeadOwner(t *testing.T) {
	dir := t.TempDir()
	stale := filepath.Join(dir, "0")
	if err := os.Mkdir(stale, 0o777); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(slotOwner{PID: 999999999})
	if err := os.WriteFile(filepath.Join(stale, "owner.json"), data, 0o666); err != nil {
		t.Fatal(err)
	}
	s := &slots{dir: dir, limit: 1, poll: 5 * time.Millisecond, log: io.Discard}
	done := make(chan struct{})
	go func() { s.acquire("a"); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("死んだ持ち主の枠が片付かない")
	}
}
