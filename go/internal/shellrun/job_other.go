//go:build !windows

package shellrun

import "os"

// attachKillOnClose は macOS と Linux では何もしない。スクリプトの最後の exec が java をそのプロセスに置き換えるので、
// 止める相手は起こした 1 本だけで済む。
func attachKillOnClose(*os.Process) func() { return func() {} }
