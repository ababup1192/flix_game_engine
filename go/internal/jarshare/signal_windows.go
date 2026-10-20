//go:build windows

package jarshare

import "os"

// processAlive は pid の相手が居るか。Windows では合図を送って確かめられないので、FindProcess が通れば居るとみなす
// （作り手は Mac mini の launchd だけで走る）。
func processAlive(pid int) bool {
	_, err := os.FindProcess(pid)
	return err == nil
}
