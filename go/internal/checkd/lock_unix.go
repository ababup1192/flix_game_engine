//go:build !windows

package checkd

import (
	"os"
	"syscall"
)

// lockHeld は常駐の lock ファイルを、まだどこかのプロセスが持っているか（Java の FileChannel.tryLock は fcntl の lock）。
func lockHeld(path string) bool {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return false
	}
	defer f.Close()
	lk := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: 0, Start: 0, Len: 0}
	if err := syscall.FcntlFlock(f.Fd(), syscall.F_GETLK, &lk); err != nil {
		return false
	}
	return lk.Type != syscall.F_UNLCK
}
