//go:build !windows

package heavy

// 何を守るか: 枠の本数より多く同時に流さないこと、長い物どうしを同時に流さないこと、
// 長い物が枠 1 を持っていても短い物が枠 2 で流れること、古い heavy のエントリに枠 2 を配らないこと、
// 持ち主の死んだ鍵と古い手書きの鍵だけを外すこと、自分の鍵しか外さないこと、
// 中から呼んだ heavy が自分の鍵を待って止まらないこと。

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
	return heavyCmdSlots(t, lock, DefaultSlots, args...)
}

func heavyCmdSlots(t *testing.T, lock string, slots int, args ...string) *exec.Cmd {
	t.Helper()
	c := exec.Command(os.Args[0], append([]string{"-test.run=^$", "--"}, args...)...)
	c.Env = append(os.Environ(), "FGE_HEAVY_HELPER=1", "FGE_HEAVY_LOCK="+lock,
		fmt.Sprintf("%s=%d", SlotsEnv, slots))
	return c
}

// runAll は同じ鍵で heavy を並べて流し、それぞれの終了コードを返す。
func runAll(t *testing.T, cmds []*exec.Cmd) []int {
	t.Helper()
	var wg sync.WaitGroup
	codes := make([]int, len(cmds))
	for i, c := range cmds {
		wg.Add(1)
		go func(i int, c *exec.Cmd) {
			defer wg.Done()
			if err := c.Run(); err != nil {
				codes[i] = c.ProcessState.ExitCode()
			}
		}(i, c)
	}
	wg.Wait()
	return codes
}

func newLock(t *testing.T) string {
	return filepath.Join(t.TempDir(), "fge-heavy.lock")
}

func TestOneSlotRunsOneAtATime(t *testing.T) {
	lock := newLock(t)
	marker := filepath.Join(t.TempDir(), "running")
	// 同時に 2 本走ると mkdir が失敗して 9 で終わる。
	body := fmt.Sprintf("mkdir %s || exit 9; sleep 0.3; rmdir %s", marker, marker)
	var cmds []*exec.Cmd
	for i := 0; i < 3; i++ {
		cmds = append(cmds, heavyCmdSlots(t, lock, 1, "sh", "-c", body))
	}
	for i, code := range runAll(t, cmds) {
		if code != 0 {
			t.Fatalf("%d 本目が %d で終わった（重なって走った）", i, code)
		}
	}
	if _, err := os.Stat(lock); !os.IsNotExist(err) {
		t.Fatalf("終わった後も鍵が残っている")
	}
}

func TestTwoSlotsRunTwoShortAtMost(t *testing.T) {
	lock := newLock(t)
	dir := t.TempDir()
	a, b, both := filepath.Join(dir, "a"), filepath.Join(dir, "b"), filepath.Join(dir, "both")
	// 3 本目が重なると a も b も取れずに 9 で終わる。2 本が重なった印は both に残る。
	body := fmt.Sprintf(`if mkdir %[1]s 2>/dev/null; then m=%[1]s; elif mkdir %[2]s 2>/dev/null; then m=%[2]s; else exit 9; fi
[ -d %[1]s ] && [ -d %[2]s ] && touch %[3]s; sleep 0.5; [ -d %[1]s ] && [ -d %[2]s ] && touch %[3]s; rmdir $m`, a, b, both)
	var cmds []*exec.Cmd
	for i := 0; i < 4; i++ {
		cmds = append(cmds, heavyCmdSlots(t, lock, 2, "sh", "-c", body))
	}
	for i, code := range runAll(t, cmds) {
		if code != 0 {
			t.Fatalf("%d 本目が %d で終わった（3 本が重なって走った）", i, code)
		}
	}
	if _, err := os.Stat(both); err != nil {
		t.Fatalf("枠が 2 本あるのに短い物が 1 本ずつしか走らなかった")
	}
}

func TestLongRunsDoNotOverlap(t *testing.T) {
	lock := newLock(t)
	marker := filepath.Join(t.TempDir(), "running")
	body := fmt.Sprintf("mkdir %s || exit 9; sleep 0.3; rmdir %s", marker, marker)
	cmds := []*exec.Cmd{
		heavyCmd(t, lock, "--long", "sh", "-c", body),
		heavyCmd(t, lock, "sh", "-c", body+" # make render-all"),
		heavyCmd(t, lock, "--long", "sh", "-c", body),
	}
	for i, code := range runAll(t, cmds) {
		if code != 0 {
			t.Fatalf("長い物の %d 本目が %d で終わった（重なって走った）", i, code)
		}
	}
}

func TestShortRunsBesideLong(t *testing.T) {
	lock := newLock(t)
	dir := t.TempDir()
	started, done := filepath.Join(dir, "started"), filepath.Join(dir, "done")
	// 長い物は短い物が終わるまで（最大 5 秒）枠 1 を握る。短い物が待たされれば done が遅れる。
	long := heavyCmd(t, lock, "--long", "sh", "-c",
		fmt.Sprintf("touch %s; i=0; while [ ! -e %s ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done", started, done))
	if err := long.Start(); err != nil {
		t.Fatal(err)
	}
	defer long.Wait()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(started); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("長い物が始まらない")
		}
		time.Sleep(20 * time.Millisecond)
	}
	t0 := time.Now()
	if err := heavyCmd(t, lock, "touch", done).Run(); err != nil {
		t.Fatalf("短い物が失敗: %v", err)
	}
	if waited := time.Since(t0); waited > 3*time.Second {
		t.Fatalf("長い物が枠 1 を持っている間、短い物が %v 待たされた", waited)
	}
}

func TestPickKeepsSlotTwoFromOldEntries(t *testing.T) {
	lock := newLock(t)
	o := defaults(Options{Lock: lock, Slots: 2, Err: io.Discard})
	os.Mkdir(slotPath(lock, 0), 0o755)
	old := Owner{PID: 1}                  // 1 本だった頃の heavy のエントリ（Long も AnySlot も無い）
	long := Owner{PID: 2, Long: true}     // 枠 1 だけ
	short := Owner{PID: 3, AnySlot: true} // どこでも
	if slot, _ := pick(o, []Owner{old, long, short}, 1); slot != -1 {
		t.Fatalf("古い heavy のエントリに枠 %d を配った（枠 1 だけを待つはず）", slot+1)
	}
	if slot, _ := pick(o, []Owner{old, long, short}, 3); slot != 1 {
		t.Fatalf("枠 1 を待つエントリの後ろの短い物が枠 2 を取れない (got %d)", slot+1)
	}
	os.Remove(slotPath(lock, 0))
	if slot, _ := pick(o, []Owner{short, long}, 3); slot != 1 {
		t.Fatalf("短い物が枠 1 を先に取った（長い物のために枠 2 から取るはず）")
	}
	if slot, _ := pick(o, []Owner{short, long}, 2); slot != 0 {
		t.Fatalf("前の短い物が枠 2 を取るのに、長い物が枠 1 を取れない")
	}
}

func TestLooksLong(t *testing.T) {
	for cmd, want := range map[string]bool{
		"make render-all": true,
		"bash -c 'fmake CHECKD=0 puzzle-video-sfx > log'": true,
		"make reference-update":                           true,
		"make gallery-sounds":                             true,
		"compare: 基準 の描き出し (render-all)":                  true,
		"make check":                               false,
		"make test":                                false,
		"fmake release TEST=test":                  false,
		"make render SHOT=title":                   false,
		"use-engine: v0.35.25 を組む":                 false,
		"bash -c 'cd ~/w/id-x-video && make test'": false,
		"make mix-compare":                         false,
		"make check > /tmp/fge-compare-1/base.log": false,
		"make agent-eval-release":                  true,
		"make compare BASE=master":                 true,
	} {
		if got := LooksLong(cmd); got != want {
			t.Errorf("LooksLong(%q) = %v", cmd, got)
		}
	}
}

func TestDeadOwnerLockIsTaken(t *testing.T) {
	lock := newLock(t)
	os.Mkdir(lock, 0o755)
	dead := exec.Command("true")
	dead.Run()
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: dead.Process.Pid, Command: "make test", Since: time.Now()})
	// 長い物は枠 1 しか使えないので、死んだ持ち主の鍵を外さないと流れない。
	c := heavyCmd(t, lock, "--long", "true")
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
	if reap(Options{Lock: lock, Now: time.Now, Err: io.Discard}, lock) {
		t.Fatalf("手書きの鍵を %v 経つ前に外した", anonymousStale)
	}
	old := time.Now().Add(-anonymousStale - time.Minute)
	os.Chtimes(lock, old, old)
	if !reap(Options{Lock: lock, Now: time.Now, Err: io.Discard}, lock) {
		t.Fatalf("%v を超えた手書きの鍵を外さなかった", anonymousStale)
	}
}

func TestReleaseLeavesSomeoneElsesLock(t *testing.T) {
	lock := newLock(t)
	os.Mkdir(lock, 0o755)
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: os.Getpid(), Token: "theirs"})
	release(lock, "mine")
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

func TestShortReapsDeadSlotOneWhileSlotTwoBusy(t *testing.T) {
	lock := newLock(t)
	os.Mkdir(slotPath(lock, 1), 0o755)
	writeJSON(filepath.Join(slotPath(lock, 1), ownerFile), Owner{PID: os.Getpid(), Command: "make test", Since: time.Now()})
	os.Mkdir(lock, 0o755)
	dead := exec.Command("true")
	dead.Run()
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: dead.Process.Pid, Command: "make render-all", Since: time.Now()})
	c := heavyCmd(t, lock, "true")
	done := make(chan error, 1)
	go func() { done <- c.Run() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("短い物が失敗: %v", err)
		}
	case <-time.After(5 * time.Second):
		c.Process.Kill()
		t.Fatalf("枠 2 が埋まっている間、死んだ枠 1 を外さずに待ち続けた")
	}
}

func TestPickHonorsFewerSlotsOfEntriesAhead(t *testing.T) {
	lock := newLock(t)
	o := defaults(Options{Lock: lock, Slots: 2, Err: io.Discard})
	os.Mkdir(slotPath(lock, 0), 0o755)
	one := Owner{PID: 1, AnySlot: true, Slots: 1} // FGE_HEAVY_SLOTS=1 のエントリは枠 2 を使えない
	me := Owner{PID: 2, AnySlot: true, Slots: 2}
	if slot, _ := pick(o, []Owner{one, me}, 2); slot != 1 {
		t.Fatalf("枠 1 しか知らないエントリの後ろで、空いた枠 2 を取れない (got %d)", slot+1)
	}
}

func TestShortDoesNotJumpOldEntryForSlotOne(t *testing.T) {
	lock := newLock(t)
	// 枠 1 と枠 2 を生きた持ち主で塞ぎ、列には古い heavy のエントリ（Long も AnySlot も無い）を先に置く。
	os.Mkdir(slotPath(lock, 1), 0o755)
	writeJSON(filepath.Join(slotPath(lock, 1), ownerFile), Owner{PID: os.Getpid(), Since: time.Now()})
	os.Mkdir(lock, 0o755)
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: os.Getpid(), Since: time.Now()})
	old := exec.Command("sleep", "30")
	if err := old.Start(); err != nil {
		t.Fatal(err)
	}
	defer old.Process.Kill()
	os.MkdirAll(queueDir(lock), 0o777)
	writeJSON(filepath.Join(queueDir(lock), fmt.Sprint(old.Process.Pid)+".json"),
		Owner{PID: old.Process.Pid, Started: processStarted(old.Process.Pid), Since: time.Now().Add(-time.Minute)})
	c := heavyCmd(t, lock, "true")
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	os.Remove(filepath.Join(lock, ownerFile))
	os.Remove(lock) // 枠 1 が空く。番は古いエントリなので、短い物は取らずに待つはず
	time.Sleep(300 * time.Millisecond)
	if _, err := os.Stat(lock); err == nil {
		c.Process.Kill()
		c.Wait()
		t.Fatalf("短い物が前に並ぶ古い heavy を飛ばして枠 1 を取った")
	}
	os.Remove(filepath.Join(slotPath(lock, 1), ownerFile))
	os.Remove(slotPath(lock, 1)) // 枠 2 が空けば短い物は流れる
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("短い物が失敗: %v", err)
		}
	case <-time.After(5 * time.Second):
		c.Process.Kill()
		t.Fatalf("枠 2 が空いても短い物が流れない")
	}
}

func TestDeadSlotTwoIsReapedWhileSlotOneBusy(t *testing.T) {
	lock := newLock(t)
	os.Mkdir(lock, 0o755)
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: os.Getpid(), Command: "make render-all", Since: time.Now()})
	os.Mkdir(slotPath(lock, 1), 0o755)
	dead := exec.Command("true")
	dead.Run()
	writeJSON(filepath.Join(slotPath(lock, 1), ownerFile), Owner{PID: dead.Process.Pid, Command: "make test", Since: time.Now()})
	c := heavyCmd(t, lock, "true")
	done := make(chan error, 1)
	go func() { done <- c.Run() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("短い物が失敗: %v", err)
		}
	case <-time.After(5 * time.Second):
		c.Process.Kill()
		t.Fatalf("死んだ枠 2 を外さずに待ち続けた")
	}
}

func TestChildOfSlotTwoSeesItsSlotAsLock(t *testing.T) {
	lock := newLock(t)
	// 枠 1 を塞いで短い物に枠 2 を取らせる。子の FGE_HEAVY_LOCK が枠 2 なら、中の古い heavy も待たずに流れる。
	os.Mkdir(lock, 0o755)
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: os.Getpid(), Since: time.Now()})
	want := slotPath(lock, 1)
	c := heavyCmd(t, lock, "sh", "-c", fmt.Sprintf(`test "$FGE_HEAVY_LOCK" = %s && grep -q "$FGE_HEAVY_TOKEN" "$FGE_HEAVY_LOCK/owner.json"`, want))
	if err := c.Run(); err != nil {
		t.Fatalf("枠 2 の子に枠 2 の置き場と合言葉が渡っていない: %v", err)
	}
}
