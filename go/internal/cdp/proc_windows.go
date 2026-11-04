//go:build windows

package cdp

import (
	"os"
	"syscall"
)

func sysProcAttrNewGroup() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

// killGroup は Windows では起こした本体だけを止める。
// WhyNot: 子まで止める taskkill /T を呼ばないのは、Browser.close が先に効いて子は本体と一緒に閉じるのが普通で、ここは閉じなかった時の後始末だから。
func killGroup(pid int) {
	if p, err := os.FindProcess(pid); err == nil {
		_ = p.Kill()
	}
}
