//go:build !windows

package rendercache

import (
	"os"
	"path/filepath"
	"syscall"
)

// FreeBytes は dir（無ければ有る所まで親へ辿る）のディスクの空き。分からなければ -1。
func FreeBytes(dir string) int64 {
	d := dir
	for {
		if _, err := os.Stat(d); err == nil {
			break
		}
		parent := filepath.Dir(d)
		if parent == d {
			return -1
		}
		d = parent
	}
	var st syscall.Statfs_t
	if syscall.Statfs(d, &st) != nil {
		return -1
	}
	return int64(st.Bavail) * int64(st.Bsize)
}
