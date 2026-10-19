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

// Ask は常駐へ 1 コマンド送り (終了コード, 出力) を返す。話せなければエラー。
func Ask(r *Rules, pkg, command string, timeout time.Duration) (int, string, error) {
	return AskWithDial(r, pkg, command, timeout, timeout)
}

// AskWithDial は接続の待ち時間と返事の待ち時間を別々に決める Ask。
// WhyNot: 1 つの締め切りにまとめないのは、check の返事は数分待ってよい一方で、
// 死んだ常駐への接続はすぐ諦めて素の CLI へ落ちたいため。
func AskWithDial(r *Rules, pkg, command string, dial, timeout time.Duration) (int, string, error) {
	raw, err := os.ReadFile(filepath.Join(StateDir(r, pkg), "port"))
	if err != nil {
		return 0, "", err
	}
	port, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return 0, "", err
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), dial)
	if err != nil {
		return 0, "", err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return 0, "", err
	}
	if _, err := conn.Write([]byte(command + "\n")); err != nil {
		return 0, "", err
	}
	var buf []byte
	chunk := make([]byte, 65536)
	for !strings.Contains(string(buf), "\n") {
		n, err := conn.Read(chunk)
		if n > 0 {
			buf = append(buf, chunk[:n]...)
		}
		if err != nil {
			return 0, "", errors.New("常駐の返事が途中で切れました")
		}
	}
	head, body, _ := strings.Cut(string(buf), "\n")
	fields := strings.Fields(head)
	if len(fields) < 3 {
		return 0, "", fmt.Errorf("常駐の返事の見出しが読めません: %q", head)
	}
	code, err1 := strconv.Atoi(fields[1])
	length, err2 := strconv.Atoi(fields[2])
	if err1 != nil || err2 != nil {
		return 0, "", fmt.Errorf("常駐の返事の見出しが読めません: %q", head)
	}
	for len(body) < length {
		n, err := conn.Read(chunk)
		if n > 0 {
			body += string(chunk[:n])
		}
		if err != nil {
			return 0, "", errors.New("常駐の返事が途中で切れました")
		}
	}
	return code, body, nil
}

// DropPort はつながらなくなった常駐の port ファイルを片付ける。
// WhyNot: 残したままにしないのは、死んだ常駐の残骸を次のクライアントが読んで
// 毎回つながらない相手へ接続を試みるため。
func DropPort(r *Rules, pkg string) {
	_ = os.Remove(filepath.Join(StateDir(r, pkg), "port"))
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

func readPid(stateDir string) int {
	raw, err := os.ReadFile(filepath.Join(stateDir, "pid"))
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return 0
	}
	return pid
}

// DaemonAlive はそのパッケージの常駐が生きているか。
// WhyNot: pid ファイルの有無で決めないのは、落ちた常駐もファイルを残すため。
func DaemonAlive(r *Rules, pkg string) bool {
	pid := readPid(StateDir(r, pkg))
	return pid != 0 && PidAlive(pid)
}

func liveDaemons(r *Rules) int {
	names, err := os.ReadDir(expandHome(*r.Checkd.CacheDir))
	if err != nil {
		return 0
	}
	live := 0
	for _, e := range names {
		pid := readPid(filepath.Join(expandHome(*r.Checkd.CacheDir), e.Name()))
		if pid != 0 && PidAlive(pid) {
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

// DaemonViable は常駐を立ててよい機械かを見る。repl 1 本 (heapMinMB + headroom)
// すら memoryShare の予算に収まらない機械では常駐せず、毎回素の CLI で検査する
// (3.6GB 級の JVM で小さい機械を圧迫するより、check が 1〜2 分かかる方がまし)。
// 物理メモリが分からない機械と、環境変数で rssLimit を明示した人は常駐してよい側に倒す。
func DaemonViable(r *Rules) bool {
	if os.Getenv(*r.Checkd.Daemon.RSSLimit.EnvVar) != "" {
		return true
	}
	total, ok := MachineMemoryMB()
	if !ok {
		return true
	}
	budget := float64(total) * *r.Checkd.Daemon.RSSLimit.MemoryShare
	need := float64(*r.Checkd.Daemon.HeapMinMB + *r.Checkd.Daemon.HeapHeadroomMB)
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
