//go:build !windows

package heavy

import (
	"os"
	"syscall"
)

const canDelegate = true

// execDelegate は今のプロセスを bin の heavy に置き換える。戻ってきたら失敗。
//
// WhyNot: 子として流さず exec で置き換えるのは、pid が同じまま残るので、待ち列のエントリと
// シグナル（Ctrl-C）と終了コードが、委ねなかったときと同じに振る舞うため。
func execDelegate(bin string, args []string) error {
	return syscall.Exec(bin, append([]string{bin, "heavy"}, args...), append(os.Environ(), DelegatedEnv+"=1"))
}
