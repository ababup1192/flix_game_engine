package checkd

import (
	"os"
	"syscall"
	"time"
)

// changedAt は info のファイルが置かれた・書き換わった時刻（ctime）。cp -p で mtime を古いまま写した jar も、写した時刻になる。
func changedAt(info os.FileInfo) time.Time {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return time.Unix(st.Ctim.Sec, st.Ctim.Nsec)
	}
	return info.ModTime()
}
