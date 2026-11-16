//go:build windows

package rendercache

// FreeBytes は Windows では数えない（-1 = 分からない）。
// WhyNot: GetDiskFreeSpaceEx を呼ばない — 置き場の上限の知らせのためだけに Windows の API の配線を足すほどではない。
func FreeBytes(dir string) int64 { return -1 }
