//go:build !windows

package jarshare

import (
	"os"
	"syscall"
)

// processAlive は pid の相手が居るか（送らずに見る合図 kill -0）。
func processAlive(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}
