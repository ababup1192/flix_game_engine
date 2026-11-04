//go:build !windows

package cdp

import "syscall"

func sysProcAttrNewGroup() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true}
}

// killGroup は Setpgid で自分が作った組（pgid = 起こした Chrome の pid）だけへ送る。
func killGroup(pid int) {
	if pid <= 0 {
		return
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
}
