package cdp

import (
	"os"
	"os/signal"
	"sync"
	"syscall"
)

// 起こした Chrome は別の組（Setpgid）にいるので、端末の Ctrl-C も make の TERM も届かない。
// 道具のプロセスだけが合図で落ちると、Chrome が親を失って何日も残る。合図を受けたら生きている Chrome を
// 組ごと止めてから、同じ合図で自分も止まる。
//
// WhyNot: 合図を握り続けない — Chrome が 1 つも無い間は signal.Stop で既定の止まり方へ戻し、
// cdp を使う道具の Ctrl-C の振る舞いを Chrome を起こしている間の外では変えない。
var live = struct {
	sync.Mutex
	set map[*browser]bool
	ch  chan os.Signal
}{set: map[*browser]bool{}}

func track(b *browser) {
	live.Lock()
	defer live.Unlock()
	live.set[b] = true
	if live.ch != nil {
		return
	}
	ch := make(chan os.Signal, 1)
	live.ch = ch
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
	go func() {
		s, ok := <-ch
		if !ok {
			return
		}
		live.Lock()
		for b := range live.set {
			killGroup(b.cmd.Process.Pid)
			os.RemoveAll(b.userDataDir)
		}
		live.set = map[*browser]bool{}
		signal.Stop(ch)
		live.ch = nil
		live.Unlock()
		// 既定の止まり方へ戻した後に同じ合図を自分へ送り直す（ほかに合図を待つ所があればそちらが受ける）。
		if p, err := os.FindProcess(os.Getpid()); err != nil || p.Signal(s) != nil {
			os.Exit(130)
		}
	}()
}

func untrack(b *browser) {
	live.Lock()
	defer live.Unlock()
	delete(live.set, b)
	if len(live.set) == 0 && live.ch != nil {
		signal.Stop(live.ch)
		close(live.ch)
		live.ch = nil
	}
}
