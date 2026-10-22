package hooks

// 常駐 (bin/fge checkd) との話し方と、起動予約の歯止め。
//
// WhyNot: フックごとに書き分けないのは、通信の手順が 2 か所でズレると、
// 片方だけ古い形のまま黙って結果を取り落とすため。

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// CacheDir は常駐の状態を集めて置く根 (~ は展開済み)。
func CacheDir(r *Rules) string { return expandHome(*r.Checkd.CacheDir) }

// StateDir はそのパッケージの状態の置き場。
// WhyNot: パスをそのままフォルダ名にしないのは、長さや記号で壊れるため。
func StateDir(r *Rules, pkg string) string {
	sum := sha1.Sum([]byte(pkg))
	h := hex.EncodeToString(sum[:])[:*r.Checkd.StateHashLen]
	return filepath.Join(expandHome(*r.Checkd.CacheDir), h)
}

func expandHome(path string) string {
	if !strings.HasPrefix(path, "~") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	return filepath.Join(home, filepath.FromSlash(strings.TrimPrefix(path, "~/")))
}

// FindPkg は編集ファイルから flix.toml まで遡ってパッケージの根を探す（無ければ空）。
func FindPkg(r *Rules, path string) string {
	d, err := filepath.EvalSymlinks(path)
	if err != nil {
		d = path
	}
	d = filepath.Dir(mustAbs(d))
	for i := 0; i < *r.Checkd.PkgSearchDepth; i++ {
		if isFile(filepath.Join(d, "flix.toml")) {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d {
			return ""
		}
		d = parent
	}
	return ""
}

func mustAbs(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return abs
}

// Detach は起こす子を親のセッション（Windows ではコンソール）から切り離す。
func Detach(cmd *exec.Cmd) { detach(cmd) }

// PidAlive はその pid のプロセスが居るか。シグナルは送らない。
//
// WhyNot: Windows で os.Process.Signal を使わないのは、0 を送るつもりでも
// 相手を止めてしまう（TerminateProcess に化ける）ため。
func PidAlive(pid int) bool {
	if runtime.GOOS == "windows" {
		out, err := exec.Command("tasklist", "/FI", fmt.Sprintf("PID eq %d", pid), "/NH").Output()
		if err != nil {
			return true // 確かめられない時は「居る」に倒す (誤って乗っ取らない)
		}
		return strings.Contains(string(out), strconv.Itoa(pid))
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = proc.Signal(syscall.Signal(0))
	if errors.Is(err, os.ErrProcessDone) || errors.Is(err, syscall.ESRCH) {
		return false
	}
	return true // 権限エラー等は「居る」扱い
}

// serverSocket は check を流した flixlint の常駐の socket（checkd が状態の置き場の server に書く 1 行目。無ければ ""）。
func serverSocket(stateDir string) string {
	b, err := os.ReadFile(filepath.Join(stateDir, "server"))
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return line
}

// serverAlive は記録の socket に今つながるか。
// WhyNot: socket のファイルの有無で決めないのは、落ちた常駐もファイルを残しうるため。
func serverAlive(stateDir string) bool {
	sock := serverSocket(stateDir)
	if sock == "" {
		return false
	}
	conn, err := net.DialTimeout("unix", sock, 500*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// DaemonAlive はそのパッケージの check の常駐（flixlint）が生きているか。
func DaemonAlive(r *Rules, pkg string) bool { return serverAlive(StateDir(r, pkg)) }

func liveDaemons(r *Rules) int {
	names, err := os.ReadDir(expandHome(*r.Checkd.CacheDir))
	if err != nil {
		return 0
	}
	live := 0
	for _, e := range names {
		if serverAlive(filepath.Join(expandHome(*r.Checkd.CacheDir), e.Name())) {
			live++
		}
	}
	return live
}

// MaxDaemonCount は常駐の数の上限。機械の物理メモリから決まる（環境変数で上書きできる）。
// 起動予約の歯止めと常駐側のメモリ予算は、どちらもこの 1 本を読む。
func MaxDaemonCount(r *Rules) int { return CountDaemons(r.Checkd.MaxDaemons) }

// CountDaemons は MaxDaemons の決め方から上限の数を出す。checkd 以外の常駐
// （bin/fge resident）も同じ式で数を決める。
func CountDaemons(m MaxDaemons) int {
	n := *m.Fallback
	if mb, ok := MachineMemoryMB(); ok && *m.GBPerDaemon > 0 {
		n = int(float64(mb) / 1024 / *m.GBPerDaemon)
		if n < 1 {
			n = 1
		}
		if n > *m.Cap {
			n = *m.Cap
		}
	}
	if v := os.Getenv(*m.EnvVar); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			n = parsed
		}
	}
	if n < 1 {
		n = 1
	}
	return n
}

// DaemonViable は常駐を立ててよい機械かを見る。常駐 1 本（checkd.server.heapMB + headroom）すら memoryShare の予算に
// 収まらない機械では起動予約をせず、check は素の CLI の速さになる（小さい機械を圧迫するより遅い方がまし）。
// 物理メモリが分からない機械と、環境変数で予算を明示した人は立ててよい側に倒す。
func DaemonViable(r *Rules) bool {
	if os.Getenv(*r.Checkd.Daemon.RSSLimit.EnvVar) != "" || r.Checkd.Server.HeapMB == nil {
		return true
	}
	total, ok := MachineMemoryMB()
	if !ok {
		return true
	}
	budget := float64(total) * *r.Checkd.Daemon.RSSLimit.MemoryShare
	need := float64(*r.Checkd.Server.HeapMB + *r.Checkd.Daemon.HeapHeadroomMB)
	return budget >= need
}

// tooBusy は起動予約を見送る条件。
// WhyNot: 無条件に増やさないのは、常駐 1 つが JVM 1 つを抱えたまま眠り続け、
// 並列のサブエージェントの数だけ立てると機械のメモリが尽きるため。
func tooBusy(r *Rules, pkg string) bool {
	if !DaemonViable(r) {
		return true
	}
	stamp := filepath.Join(StateDir(r, pkg), "reserved")
	if info, err := os.Stat(stamp); err == nil {
		if time.Since(info.ModTime()).Seconds() < *r.Checkd.ReserveIntervalSec {
			return true
		}
	}
	if load, ok := loadAvg1(); ok && load > float64(runtime.NumCPU()) {
		return true
	}
	if liveDaemons(r) >= MaxDaemonCount(r) {
		return true
	}
	if err := os.MkdirAll(filepath.Dir(stamp), 0o755); err == nil {
		if f, err := os.Create(stamp); err == nil {
			f.Close()
		}
	}
	return false
}

// ReserveDaemon は裏で `fge checkd <pkg>` を切り離して起動する。次の保存から温で効く。
//
// WhyNot: 結果を待たないのは、起動予約がおまけの善意で、フック本体の責務では
// ないため。失敗しても無音で降りる。
func ReserveDaemon(r *Rules, _, pkg string) {
	self, err := os.Executable()
	if err != nil || tooBusy(r, pkg) {
		return
	}
	cmd := exec.Command(self, "checkd", pkg)
	cmd.Dir = pkg
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	detach(cmd)
	if err := cmd.Start(); err != nil {
		return
	}
	// WhyNot: Wait を呼ばずに Release するのは、常駐が数十分生き続ける相手で、
	// 待つとフックがその間ずっと戻らないため。
	_ = cmd.Process.Release()
}

// MachineMemoryMB はこの機械の物理メモリ (MB)。分からなければ ok=false。
func MachineMemoryMB() (int64, bool) {
	switch runtime.GOOS {
	case "darwin":
		out, err := exec.Command("/usr/sbin/sysctl", "-n", "hw.memsize").Output()
		if err != nil {
			return 0, false
		}
		n, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
		if err != nil {
			return 0, false
		}
		return n / (1024 * 1024), true
	case "linux":
		raw, err := os.ReadFile("/proc/meminfo")
		if err != nil {
			return 0, false
		}
		for _, line := range strings.Split(string(raw), "\n") {
			if !strings.HasPrefix(line, "MemTotal:") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) < 2 {
				return 0, false
			}
			kb, err := strconv.ParseInt(fields[1], 10, 64)
			if err != nil {
				return 0, false
			}
			return kb / 1024, true
		}
	}
	return 0, false
}

// loadAvg1 は直近 1 分の負荷。読めなければ ok=false。
func loadAvg1() (float64, bool) {
	switch runtime.GOOS {
	case "darwin":
		out, err := exec.Command("/usr/sbin/sysctl", "-n", "vm.loadavg").Output()
		if err != nil {
			return 0, false
		}
		fields := strings.Fields(strings.Trim(strings.TrimSpace(string(out)), "{}"))
		if len(fields) == 0 {
			return 0, false
		}
		v, err := strconv.ParseFloat(fields[0], 64)
		return v, err == nil
	case "linux":
		raw, err := os.ReadFile("/proc/loadavg")
		if err != nil {
			return 0, false
		}
		fields := strings.Fields(string(raw))
		if len(fields) == 0 {
			return 0, false
		}
		v, err := strconv.ParseFloat(fields[0], 64)
		return v, err == nil
	}
	return 0, false
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func seconds(v float64) time.Duration {
	return time.Duration(v * float64(time.Second))
}
