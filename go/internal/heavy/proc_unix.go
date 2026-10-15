//go:build !windows

package heavy

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// InterruptSignals は heavy が受けて子へ回すシグナル。compare も同じ物で片付けに入る。
var InterruptSignals = []os.Signal{os.Interrupt, syscall.SIGTERM, syscall.SIGHUP}

// processAlive は pid が生きているか。started が書いてあれば、同じ番号を
// 別のプロセスが使い回していないかも ps の起動時刻で見る。
func processAlive(pid int, started string) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	if err != nil && !errors.Is(err, syscall.EPERM) {
		return false
	}
	if started == "" {
		return true
	}
	now := processStarted(pid)
	return now == "" || now == started
}

// processStarted は pid の起動時刻（ps の lstart）。読めなければ空。
func processStarted(pid int) string {
	out, err := exec.Command("ps", "-o", "lstart=", "-p", itoa(pid)).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// setGroup は子を自分のプロセスグループに入れる。
//
// WhyNot: 子を heavy と同じグループに置かないのは、make の下の JVM まで止めるのに
// グループごとシグナルを送りたいから。端末の Ctrl-C は heavy が受けて回す。
func setGroup(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func signalGroup(c *exec.Cmd, s os.Signal) {
	if c.Process == nil {
		return
	}
	sig, ok := s.(syscall.Signal)
	if !ok {
		sig = syscall.SIGTERM
	}
	if c.SysProcAttr != nil && c.SysProcAttr.Setpgid {
		syscall.Kill(-c.Process.Pid, sig)
		return
	}
	c.Process.Signal(sig)
}

func exitCode(c *exec.Cmd, err error) int {
	if err == nil {
		return 0
	}
	if ws, ok := c.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	if c.ProcessState != nil {
		return c.ProcessState.ExitCode()
	}
	return 1
}

func killGroup(c *exec.Cmd) {
	if c.Process != nil {
		syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
	}
}
