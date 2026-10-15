//go:build windows

package heavy

import (
	"os"
	"os/exec"
	"syscall"
)

// InterruptSignals は heavy が受けて子へ回すシグナル。compare も同じ物で片付けに入る。
var InterruptSignals = []os.Signal{os.Interrupt}

const (
	processQueryLimitedInformation = 0x1000
	stillActive                    = 259
)

// processAlive は pid が生きているか。
//
// WhyNot: FindProcess で見ないのは、Windows では死んだ pid でも成功するため。
// 起動時刻は見ないので、番号の使い回しは見分けられない（札が残っても --status で見える）。
func processAlive(pid int, started string) bool {
	if pid <= 0 {
		return false
	}
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(h)
	var code uint32
	if err := syscall.GetExitCodeProcess(h, &code); err != nil {
		return true
	}
	return code == stillActive
}

func processStarted(pid int) string { return "" }

func setGroup(c *exec.Cmd) {}

func signalGroup(c *exec.Cmd, s os.Signal) { killGroup(c) }

func killGroup(c *exec.Cmd) {
	if c.Process != nil {
		c.Process.Kill()
	}
}

func exitCode(c *exec.Cmd, err error) int {
	if err == nil {
		return 0
	}
	if c.ProcessState != nil {
		return c.ProcessState.ExitCode()
	}
	return 1
}
