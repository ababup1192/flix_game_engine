//go:build !windows

package agenteval

import (
	"errors"
	"os"
	"syscall"
)

const slotsSupported = true

// tryLock は path のファイルロックを待たずに取る。取れなければ ok=false。
// ロックはファイルを開いている間だけ効き、プロセスが死ねば OS が外す。
func tryLock(path string) (release func(), ok bool, err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o666)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, true, nil
}
