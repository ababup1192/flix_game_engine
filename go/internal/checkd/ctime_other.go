//go:build !darwin && !linux

package checkd

import (
	"os"
	"time"
)

// changedAt は ctime を読めない所では mtime。
func changedAt(info os.FileInfo) time.Time { return info.ModTime() }
