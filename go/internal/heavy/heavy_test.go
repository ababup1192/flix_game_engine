//go:build !windows

package heavy

// 何を守るか: 枠の本数より多く同時に流さないこと、長い物を長い物の枠の本数（既定 2）より多く
// 重ねないこと、長い物が枠を埋めても短い物だけの枠で短い物が流れること、
// 長い物が枠 1 を持っていても短い物が枠 2 で流れること、古い heavy のエントリに枠 2 を配らないこと、
// 持ち主の死んだ鍵と古い手書きの鍵だけを外すこと、自分の鍵しか外さないこと、
// 中から呼んだ heavy が自分の鍵を待って止まらないこと、心拍の止まった待ち人が列を塞がないこと、
// 委ね先が壊れていたり置き換えに失敗したりしたら知らせてこの版のまま流すこと。

import (
	"errors"
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
	return heavyCmdLongSlots(t, lock, slots, DefaultLongSlots, args...)
}

func heavyCmdLongSlots(t *testing.T, lock string, slots, longSlots int, args ...string) *exec.Cmd {
	t.Helper()
	c := exec.Command(os.Args[0], append([]string{"-test.run=^$", "--"}, args...)...)
	c.Env = append(os.Environ(), "FGE_HEAVY_HELPER=1", "FGE_HEAVY_LOCK="+lock, NoDelegateEnv+"=1",
		fmt.Sprintf("%s=%d", SlotsEnv, slots), fmt.Sprintf("%s=%d", LongSlotsEnv, longSlots))
	return c
}

// waitFile は path ができるまで待つ（5 秒で諦める）。
func waitFile(t *testing.T, path, what string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
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

func TestLongRunsDoNotOverlapWithOneLongSlot(t *testing.T) {
	lock := newLock(t)
	marker := filepath.Join(t.TempDir(), "running")
	body := fmt.Sprintf("mkdir %s || exit 9; sleep 0.3; rmdir %s", marker, marker)
	cmds := []*exec.Cmd{
		heavyCmdLongSlots(t, lock, DefaultSlots, 1, "--long", "sh", "-c", body),
		heavyCmdLongSlots(t, lock, DefaultSlots, 1, "sh", "-c", body+" # make render-all"),
		heavyCmdLongSlots(t, lock, DefaultSlots, 1, "--long", "sh", "-c", body),
	}
	for i, code := range runAll(t, cmds) {
		if code != 0 {
			t.Fatalf("長い物の %d 本目が %d で終わった（重なって走った）", i, code)
		}
	}
}

func TestLongRunsTwoAtMost(t *testing.T) {
	lock := newLock(t)
	dir := t.TempDir()
	a, b, both := filepath.Join(dir, "a"), filepath.Join(dir, "b"), filepath.Join(dir, "both")
	// 長い物が 3 本重なると a も b も取れずに 9 で終わる。2 本が重なった印は both に残る。
	body := fmt.Sprintf(`if mkdir %[1]s 2>/dev/null; then m=%[1]s; elif mkdir %[2]s 2>/dev/null; then m=%[2]s; else exit 9; fi
[ -d %[1]s ] && [ -d %[2]s ] && touch %[3]s; sleep 0.5; [ -d %[1]s ] && [ -d %[2]s ] && touch %[3]s; rmdir $m`, a, b, both)
	var cmds []*exec.Cmd
	for i := 0; i < 5; i++ {
		cmds = append(cmds, heavyCmd(t, lock, "--long", "sh", "-c", body))
	}
	for i, code := range runAll(t, cmds) {
		if code != 0 {
			t.Fatalf("長い物の %d 本目が %d で終わった（3 本が重なって走った）", i, code)
		}
	}
	if _, err := os.Stat(both); err != nil {
		t.Fatalf("長い物の枠が 2 本あるのに長い物が 1 本ずつしか走らなかった")
	}
}

func TestShortSlotStaysFreeBesideTwoLongs(t *testing.T) {
	lock := newLock(t)
	dir := t.TempDir()
	done := filepath.Join(dir, "done")
	// 長い物 2 本が枠 1・2 を握り、3 本目の長い物が待つ。短い物は枠 3 ですぐ流れるはず。
	var longs []*exec.Cmd
	for i := 0; i < 2; i++ {
		started := filepath.Join(dir, fmt.Sprintf("started%d", i))
		c := heavyCmd(t, lock, "--long", "sh", "-c",
			fmt.Sprintf("touch %s; i=0; while [ ! -e %s ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done", started, done))
		if err := c.Start(); err != nil {
			t.Fatal(err)
		}
		longs = append(longs, c)
		waitFile(t, started, "長い物が始まらない")
	}
	defer func() {
		for _, c := range longs {
			c.Wait()
		}
	}()
	third := filepath.Join(dir, "third")
	extra := heavyCmd(t, lock, "--long", "touch", third)
	if err := extra.Start(); err != nil {
		t.Fatal(err)
	}
	defer extra.Wait()
	t0 := time.Now()
	if err := heavyCmd(t, lock, "touch", done).Run(); err != nil {
		t.Fatalf("短い物が失敗: %v", err)
	}
	if waited := time.Since(t0); waited > 3*time.Second {
		t.Fatalf("長い物が 2 本走っている間、短い物が %v 待たされた", waited)
	}
	if _, err := os.Stat(slotPath(lock, 2)); err == nil {
		t.Fatalf("短い物が終わった後も枠 3 が埋まっている（3 本目の長い物が短い物だけの枠を取った）")
	}
}

func TestEligibleKeepsShortOnlySlot(t *testing.T) {
	long := Owner{Long: true, Slots: 3, LongSlots: 2}
	if got := fmt.Sprint(eligible(long, 3)); got != "[0 1]" {
		t.Fatalf("長い物の枠が %s（枠 1・2 だけのはず）", got)
	}
	short := Owner{AnySlot: true, Slots: 3, LongSlots: 2}
	if got := fmt.Sprint(eligible(short, 3)); got != "[2 1 0]" {
		t.Fatalf("短い物の取る順が %s（短い物だけの枠 3 から・枠 1 を最後に）", got)
	}
	tooMany := Owner{Long: true, Slots: 3, LongSlots: 5}
	if got := fmt.Sprint(eligible(tooMany, 3)); got != "[0 1]" {
		t.Fatalf("長い物の枠を 5 本にしても短い物だけの枠を残すはず (got %s)", got)
	}
	// 0.35.32 までの heavy のエントリ（LongSlots が無い）は、長い物は枠 1 だけ・短い物は枠 2 から。
	oldLong := Owner{Long: true, Slots: 2}
	if got := fmt.Sprint(eligible(oldLong, 3)); got != "[0]" {
		t.Fatalf("前の版の長い物のエントリに %s を配った（枠 1 だけのはず）", got)
	}
	oldShort := Owner{AnySlot: true, Slots: 2}
	if got := fmt.Sprint(eligible(oldShort, 3)); got != "[1 0]" {
		t.Fatalf("前の版の短い物のエントリに %s を配った（枠 2・1 のはず）", got)
	}
}

func TestStatusShowsLongSlots(t *testing.T) {
	lock := newLock(t)
	var out strings.Builder
	printStatus(&out, defaults(Options{Lock: lock, Err: io.Discard}), false)
	for _, want := range []string{"枠 3 本", "枠 1〜2 の 2 本まで", "枠 2 (長い物も短い物も)", "枠 3 (短い物だけ)"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("--status に %q が無い:\n%s", want, out.String())
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
		"make agent-eval-release":                  false,
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
	// 枠 2 本で流す（枠 3 本だと短い物は空いた枠 3 を取ってしまい、外しを確かめられない）。
	c := heavyCmdSlots(t, lock, 2, "true")
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
	// 枠 2 本で流す（枠 3 本だと短い物は空いた枠 3 を取ってしまい、外しを確かめられない）。
	c := heavyCmdSlots(t, lock, 2, "true")
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
	// 枠 1 を塞いで短い物に枠 2 を取らせる（枠 2 本）。子の FGE_HEAVY_LOCK が枠 2 なら、中の古い heavy も待たずに流れる。
	os.Mkdir(lock, 0o755)
	writeJSON(filepath.Join(lock, ownerFile), Owner{PID: os.Getpid(), Since: time.Now()})
	want := slotPath(lock, 1)
	c := heavyCmdSlots(t, lock, 2, "sh", "-c", fmt.Sprintf(`test "$FGE_HEAVY_LOCK" = %s && grep -q "$FGE_HEAVY_TOKEN" "$FGE_HEAVY_LOCK/owner.json"`, want))
	if err := c.Run(); err != nil {
		t.Fatalf("枠 2 の子に枠 2 の置き場と合言葉が渡っていない: %v", err)
	}
}

func TestReleaseAppendsHistory(t *testing.T) {
	lock := newLock(t)
	cmds := []*exec.Cmd{
		heavyCmd(t, lock, "--long", "sh", "-c", "sleep 0.2"),
		heavyCmd(t, lock, "sh", "-c", "exit 3"),
	}
	runAll(t, cmds)
	recs := readHistory(lock, time.Time{})
	if len(recs) != 2 {
		t.Fatalf("記録が %d 行（2 本流したので 2 行のはず）", len(recs))
	}
	kinds := map[string]int{}
	for _, r := range recs {
		kinds[r.Kind] = r.Code
		if r.Acquired.Before(r.Queued) || r.Released.Before(r.Acquired) || r.Slot == 0 {
			t.Fatalf("時刻か枠がおかしい: %+v", r)
		}
	}
	if kinds["long"] != 0 || kinds["short"] != 3 {
		t.Fatalf("種類と終了コードが記録されていない: %v", kinds)
	}
}

func TestLooksLongInReadsGameMakefile(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "Makefile"), []byte("SHOTS := a b\nHEAVY_LONG := lab combo-sweep # ゲーム固有の長い口\n"), 0o644)
	for cmd, want := range map[string]bool{
		"make lab LAB_RUNS=200":              true,
		"bash -c 'make combo-sweep > x.log'": true,
		"make lab-cache":                     false,
		"make check":                         false,
		"make test LOG=/tmp/lab/out":         false,
		"make render-all":                    true,
	} {
		if got := LooksLongIn(cmd, dir); got != want {
			t.Errorf("LooksLongIn(%q) = %v, want %v", cmd, got, want)
		}
	}
	if LooksLongIn("make lab", t.TempDir()) {
		t.Errorf("Makefile の無い所で lab を長い物と見た")
	}
}

func TestAgentEvalRunsWithoutTakingASlot(t *testing.T) {
	lock := newLock(t)
	// 枠 1 も枠 2 も塞がっていても、agent-eval は待たずに流れる。
	os.Mkdir(lock, 0o755)
	os.Mkdir(slotPath(lock, 1), 0o755)
	c := heavyCmd(t, lock, "sh", "-c", "exit 4 # make agent-eval LABEL=x")
	done := make(chan int, 1)
	go func() { c.Run(); done <- c.ProcessState.ExitCode() }()
	select {
	case code := <-done:
		if code != 4 {
			t.Fatalf("終了コードが %d (4 のはず)", code)
		}
	case <-time.After(5 * time.Second):
		c.Process.Kill()
		t.Fatalf("agent-eval が鍵を待って止まった")
	}
}

func TestNewestReleaseComparesVersionsAsNumbers(t *testing.T) {
	home := t.TempDir()
	for _, v := range []string{"0.35.9", "0.35.10", "0.36.0-rc", "jre"} {
		d := filepath.Join(home, "engines", v)
		os.MkdirAll(filepath.Join(d, "bin"), 0o755)
		os.WriteFile(filepath.Join(d, "bin", "fge-go"), []byte("#!/bin/sh\n"), 0o755)
		os.WriteFile(filepath.Join(d, "Makefile"), nil, 0o644)
	}
	// 入れている途中（Makefile が無い）の版は選ばない。
	half := filepath.Join(home, "engines", "0.40.0", "bin")
	os.MkdirAll(half, 0o755)
	os.WriteFile(filepath.Join(half, "fge-go"), []byte("#!/bin/sh\n"), 0o755)
	if got, want := newestRelease(home), filepath.Join(home, "engines", "0.35.10", "bin", "fge-go"); got != want {
		t.Fatalf("newestRelease = %s, want %s", got, want)
	}
}

// 新しい作りの heavy がリリースの置き場にあれば、そちらへ置き換わって流れる。
func TestDelegatesToNewerReleaseOnce(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, ".flix_ge_studio", "engines", "9.0.0", "bin")
	os.MkdirAll(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "..", "Makefile"), nil, 0o644)
	marker := filepath.Join(home, "delegated")
	script := fmt.Sprintf(`#!/bin/sh
if [ "$2" = "--revision" ]; then echo 99; exit 0; fi
echo "$FGE_HEAVY_DELEGATED $*" > %s
exit 5
`, marker)
	os.WriteFile(filepath.Join(bin, "fge-go"), []byte(script), 0o755)

	run := func(extra ...string) int {
		c := exec.Command(os.Args[0], "-test.run=^$", "--", "--short", "sh", "-c", "exit 0")
		c.Env = append(os.Environ(), "FGE_HEAVY_HELPER=1", "FGE_HEAVY_LOCK="+newLock(t), "HOME="+home)
		c.Env = append(c.Env, extra...)
		c.Run()
		return c.ProcessState.ExitCode()
	}
	if code := run(); code != 5 {
		t.Fatalf("委ねた先の終了コード 5 が返らなかった (%d)", code)
	}
	if data, _ := os.ReadFile(marker); !strings.HasPrefix(string(data), "1 heavy --short sh -c") {
		t.Fatalf("委ねた先に印と引数が渡っていない: %q", data)
	}
	os.Remove(marker)
	os.WriteFile(filepath.Join(home, ".flix_ge_studio", "heavy-no-delegate"), nil, 0o644)
	if code := run(); code != 0 {
		t.Fatalf("止めスイッチがあるのに委ねた (%d)", code)
	}
	os.Remove(filepath.Join(home, ".flix_ge_studio", "heavy-no-delegate"))
	if code := run(NoDelegateEnv + "=1"); code != 0 {
		t.Fatalf("%s=1 なのに委ねた (%d)", NoDelegateEnv, code)
	}
}

// 心拍の止まった（Ctrl-Z で止められた）待ち人が列の先頭に居ても、後ろの heavy は空いた枠を取る。
func TestStaleQueueEntryDoesNotBlockHead(t *testing.T) {
	lock := newLock(t)
	stuck := exec.Command("sleep", "30")
	if err := stuck.Start(); err != nil {
		t.Fatal(err)
	}
	defer stuck.Process.Kill()
	os.MkdirAll(queueDir(lock), 0o777)
	qp := filepath.Join(queueDir(lock), fmt.Sprint(stuck.Process.Pid)+".json")
	writeJSON(qp, Owner{PID: stuck.Process.Pid, Started: processStarted(stuck.Process.Pid),
		Long: true, Since: time.Now().Add(-time.Hour)})
	old := time.Now().Add(-queueStale - time.Minute)
	os.Chtimes(qp, old, old)
	// 枠 1 本・長い物どうしなので、止まった先頭を飛ばさなければ後ろは流れない。
	c := heavyCmdSlots(t, lock, 1, "--long", "true")
	done := make(chan error, 1)
	go func() { done <- c.Run() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("後ろの heavy が失敗: %v", err)
		}
	case <-time.After(5 * time.Second):
		c.Process.Kill()
		t.Fatalf("心拍の止まった先頭の待ち人が列を塞いだ")
	}
	if _, err := os.Stat(qp); err != nil {
		t.Fatalf("止まっているだけの待ち人のエントリを消した（再開したら並び直せない）")
	}
}

// 枠 3（短い物だけの枠）の持ち主が死んでいれば、枠 1・2 が生きた長い物で埋まっていても短い物が外して取る。
func TestDeadShortOnlySlotIsReaped(t *testing.T) {
	lock := newLock(t)
	for i := 0; i < 2; i++ {
		os.Mkdir(slotPath(lock, i), 0o755)
		writeJSON(filepath.Join(slotPath(lock, i), ownerFile),
			Owner{PID: os.Getpid(), Command: "make render-all", Long: true, Since: time.Now()})
	}
	dead := exec.Command("true")
	dead.Run()
	os.Mkdir(slotPath(lock, 2), 0o755)
	writeJSON(filepath.Join(slotPath(lock, 2), ownerFile),
		Owner{PID: dead.Process.Pid, Command: "make test", AnySlot: true, Since: time.Now()})
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
		t.Fatalf("死んだ枠 3 を外さずに待ち続けた")
	}
	for i := 0; i < 2; i++ {
		if _, err := os.Stat(filepath.Join(slotPath(lock, i), ownerFile)); err != nil {
			t.Fatalf("生きた持ち主の枠 %d を外した", i+1)
		}
	}
}

// fakeRelease は ~/.flix_ge_studio/engines/9.0.0 に、script を中身にした fge-go を置き、HOME を差し替える。
func fakeRelease(t *testing.T, script string) {
	t.Helper()
	home := t.TempDir()
	bin := filepath.Join(home, ".flix_ge_studio", "engines", "9.0.0", "bin")
	os.MkdirAll(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "..", "Makefile"), []byte("VERSION := 9.0.0\n"), 0o644)
	os.WriteFile(filepath.Join(bin, "fge-go"), []byte(script), 0o755)
	t.Setenv("HOME", home)
	t.Setenv(DelegatedEnv, "")
	t.Setenv(NoDelegateEnv, "")
	t.Setenv(TokenEnv, "")
}

// 委ね先が --revision で落ちる（壊れたリリース）なら、そう 1 行言ってこの版のままコマンドを流す。
func TestBrokenReleaseRunsHereAndSaysSo(t *testing.T) {
	fakeRelease(t, "#!/bin/sh\nkill -SEGV $$\n")
	marker := filepath.Join(t.TempDir(), "ran")
	var errOut strings.Builder
	code := Run([]string{"--short", "touch", marker}, false, Options{Lock: newLock(t), Poll: 20 * time.Millisecond, Err: &errOut})
	if code != 0 {
		t.Fatalf("この版で流したコマンドの終了コード 0 が返らない (%d)", code)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("委ね先が落ちたのにコマンドを流さなかった")
	}
	if !strings.Contains(errOut.String(), "9.0.0") || !strings.Contains(errOut.String(), "この版のまま流します") {
		t.Fatalf("壊れた委ね先を知らせていない: %q", errOut.String())
	}
}

// 委ね先への置き換えが失敗したら、そう 1 行言ってこの版のままコマンドを流す（黙って 0 を返さない）。
func TestFailedExecRunsHereAndSaysSo(t *testing.T) {
	fakeRelease(t, "#!/bin/sh\nif [ \"$2\" = \"--revision\" ]; then echo 99; exit 0; fi\nexit 5\n")
	execDelegateFn = func(string, []string) error { return errors.New("置き換えに失敗") }
	t.Cleanup(func() { execDelegateFn = execDelegate })
	var errOut strings.Builder
	code := Run([]string{"--short", "sh", "-c", "exit 3"}, false, Options{Lock: newLock(t), Poll: 20 * time.Millisecond, Err: &errOut})
	if code != 3 {
		t.Fatalf("この版で流したコマンドの終了コード 3 が返らない (%d)", code)
	}
	if !strings.Contains(errOut.String(), "委ねられませんでした") {
		t.Fatalf("置き換えの失敗を知らせていない: %q", errOut.String())
	}
}

// --status の 1 行目は、答えている heavy の作りの版と、委ねていないならその理由。
func TestStatusFirstLineShowsVersionAndDelegation(t *testing.T) {
	fakeRelease(t, "#!/bin/sh\necho 99\n")
	t.Setenv(NoDelegateEnv, "1")
	firstLine := func() string {
		var out strings.Builder
		printStatus(&out, defaults(Options{Lock: newLock(t), Err: io.Discard}), false)
		return strings.SplitN(out.String(), "\n", 2)[0]
	}
	if got, want := firstLine(), fmt.Sprintf("作り %d", Revision); !strings.Contains(got, want) || !strings.Contains(got, NoDelegateEnv) {
		t.Fatalf("1 行目に %q と委ねない理由 (%s) が無い: %q", want, NoDelegateEnv, got)
	}
	t.Setenv(DelegatedEnv, "1")
	if got := firstLine(); !strings.Contains(got, "委ね先の heavy") {
		t.Fatalf("委ねられた先の 1 行目にそう出ていない: %q", got)
	}
}

// --help と -h は使い方の全文を出して 0 で終わる（知らない旗として落ちない）。
func TestHelpPrintsFullUsage(t *testing.T) {
	for _, flag := range []string{"--help", "-h"} {
		out, err := heavyCmd(t, newLock(t), flag).Output()
		if err != nil {
			t.Fatalf("%s が 0 で終わらない: %v", flag, err)
		}
		for _, want := range []string{LongSlotsEnv, "HEAVY_LONG", "--status", "--history"} {
			if !strings.Contains(string(out), want) {
				t.Fatalf("%s の出力に %q が無い:\n%s", flag, want, out)
			}
		}
	}
}
