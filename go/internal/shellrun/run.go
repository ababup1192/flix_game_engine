package shellrun

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
)

// Run は cmd を起こして終わるまで待ち、終了コードを返す。Windows ではプロセスの木を Job Object（KILL_ON_JOB_CLOSE）に入れ、
// fge が止まれば（時間切れ・Ctrl+C を含む）bash と、bash が起こした java も一緒に止まる（plans/windows.md の 12 節 K3）。
// 起こせなかった時は理由を標準エラーに出して 2 を返す。
//
// WhyNot: 常駐を起こす道（checkd）には使わない — 常駐の JVM は fge より長く生きる物で、木ごと止めると次の check が毎回 JVM を起こし直す。
func Run(cmd *exec.Cmd, name string) int {
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "%s を起動できません: %v\n", name, err)
		return 2
	}
	release := attachKillOnClose(cmd.Process)
	defer release()
	if err := cmd.Wait(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "%s が途中で止まりました: %v\n", name, err)
		return 2
	}
	return 0
}
