package checkd

// 常駐側 — flix repl を 1 本抱えて温め、127.0.0.1 の TCP で注文を受ける。

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

// errorHeading は check のエラー見出し (-- Resolution Error [E2136] ---)。
var errorHeading = regexp.MustCompile(`(?m)^-- .*\bError\b`)

// testSummary は test のまとめ行。
var testSummary = regexp.MustCompile(`Passed: (\d+), Failed: (\d+)\.`)

type daemon struct {
	r    *hooks.Rules
	root string
	pkg  string
	sd   string
	ln   net.Listener

	cmd     *exec.Cmd
	stdin   *os.File
	out     chan []byte
	gone    chan struct{} // repl が終わったら閉じる
	waitErr error         // repl の Wait の結果 (gone が閉じた後にだけ読む)
	seq     int
	checks  int

	// snapshot は依存の実体の新しさ。変わったら repl を作り直す。
	snapshot map[string]int64

	// seen は repl が知っているはずのソースの (mtime, 大きさ)、seenAt はそれを撮った時刻。
	// repl は書き換えを監視の知らせでしか取り込まないので、ここと今のソースの差が
	// 拾われるまで :check を送らない (sources.go)。
	seen   map[string]srcStamp
	seenAt time.Time

	// 直前に失敗した check の (出力, その時点の最新ソース mtime)。
	// 「ソースを編集したのに同一のエラーが返る」= repl の増分コンパイルの
	// 持ち越しを見破る材料。
	prevFail     string
	prevFailTime float64
	hasPrevFail  bool

	rssLimitMB int
}

// serve は常駐を立てて注文を受け続ける。1 パッケージに 1 匹しか立たない。
func serve(r *hooks.Rules, root, pkg string) int {
	d := &daemon{r: r, root: root, pkg: pkg, sd: stateDir(r, pkg), rssLimitMB: rssLimitMB(r)}
	// pid ファイルの O_EXCL 作成が「1 匹だけ」の鍵。作れなければ先客が居る。
	if !d.acquirePidFile() {
		return 0
	}
	meta, _ := json.Marshal(map[string]string{"pkg": pkg})
	_ = os.WriteFile(filepath.Join(d.sd, "meta.json"), meta, 0o644)

	portPath := filepath.Join(d.sd, "port")
	_ = os.Remove(portPath)
	// 127.0.0.1 限定 + ポート 0 (OS 採番)。外から届く口は開けない。
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		d.log(fmt.Sprintf("口を開けない: %v", err))
		d.releasePidFile()
		return 1
	}
	d.ln = ln
	port := ln.Addr().(*net.TCPAddr).Port
	// port ファイルは書き終えてから置く。書きかけを読ませない。
	tmp := portPath + ".tmp"
	if err := os.WriteFile(tmp, []byte(strconv.Itoa(port)), 0o644); err == nil {
		_ = os.Rename(tmp, portPath)
	}

	d.loop()
	d.shutdown()
	return 0
}

func (d *daemon) log(msg string) {
	fmt.Fprintf(os.Stderr, "[%s] %s\n", time.Now().Format("15:04:05"), msg)
}

func (d *daemon) acquirePidFile() bool {
	pidPath := filepath.Join(d.sd, "pid")
	for i := 0; i < 2; i++ {
		f, err := os.OpenFile(pidPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if err == nil {
			fmt.Fprint(f, os.Getpid())
			f.Close()
			return true
		}
		// 残骸 (死んだ pid) なら片付けてもう 1 度だけ試す。
		pid := readPidFile(d.sd)
		if pid > 0 && hooks.PidAlive(pid) {
			return false
		}
		_ = os.Remove(pidPath)
	}
	return false
}

func (d *daemon) releasePidFile() {
	// 消すのは自分の分だけ。STOP の直後に次の常駐が立っていることがあり、
	// 無条件に消すと入れ替わりの新入りのファイルを消してしまう。
	if readPidFile(d.sd) != os.Getpid() {
		return
	}
	for _, f := range []string{"port", "pid"} {
		_ = os.Remove(filepath.Join(d.sd, f))
	}
}

// --- repl の寿命管理

func (d *daemon) startRepl() error {
	env := os.Environ()
	// repl 起動時に依存解決が走る。素の匿名アクセスは GitHub の
	// rate limit にすぐ当たるので、取れるなら token を持たせる。
	// gh は keychain やネットワークで無期限に固まることがあるのでタイムアウトを持つ。
	// 取れなければ token 無しで続ける (匿名の rate limit に戻るだけ)。
	if os.Getenv("GITHUB_TOKEN") == "" {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		if out, err := exec.CommandContext(ctx, "gh", "auth", "token").Output(); err == nil {
			if tok := strings.TrimSpace(string(out)); tok != "" {
				env = append(env, "GITHUB_TOKEN="+tok)
			}
		}
		cancel()
	}
	// 前回 SIGKILL された repl が依存解決の途中だったなら、Maven の lock が
	// lib/cache に残っている。次の解決者はそれを「他プロセスが取得中」と読んで
	// 0% CPU で待ち続けるので、古い lock は起動前に掃く。
	d.sweepStaleLocks()
	// デーモンが killRepl を通らずに死ぬと (Ctrl-C・SIGKILL)、コンパイル中で
	// stdin の EOF に気づかない repl プロセスだけが残る (実測 2026-08-30:
	// ウォームアップの途中でデーモンを SIGKILL すると再現)。残った repl は GB 級の RSS と
	// lib/cache の lock を抱えたままなので、pid を repl.pid に記録しておき、
	// 起動前に stale なプロセスを kill する。
	d.killStaleRepl()
	// 1 回目は -Xmx の上限つきで起動し、上限が原因でウォームアップが終わらない
	// ときだけ上限なしでもう 1 回。上限なしの repl は RSS が rssLimit を超えるので
	// 最初の check の後に使い捨てられるが、そのフルコンパイルがディスクキャッシュを
	// 温めるので、次の上限つき repl は数十秒でウォームアップできて常駐に戻る
	// (実測 2026-08-30: 上限 1302MB + コールドキャッシュは GC スラッシングで
	// 900 秒でも終わらず、上限なし (ヒープ 4GB 級) は 25 秒)。
	heapSuspect, err := d.launchAndWarm(env, heapCapMB(d.r))
	if err == nil {
		return nil
	}
	if !heapSuspect {
		return err
	}
	d.log("-Xmx の上限が原因とみて、上限なしでウォームアップをリトライする")
	_, err = d.launchAndWarm(env, 0)
	return err
}

// launchAndWarm は repl を 1 本立ててウォームアップする。heapMB が 0 なら -Xmx を付けない。
// 戻りの bool は「-Xmx の上限が原因の疑いがあり、上限なしで試す価値がある」。
func (d *daemon) launchAndWarm(env []string, heapMB int) (bool, error) {
	// :test で GLFW と AWT の初期化がぶつかると固まるパッケージがある。
	// checkd は run を扱わないので常時 headless で害がない。
	//
	// -Xmx は「使い捨ての線 (rssLimitMB) に収まる repl」にするための蓋。
	// 蓋が無いと JVM は物理の 1/4 まで太り、1 回検査するたびに線を超えて
	// 捨てられる = 常駐が 1 度も効かない (実測 RSS 2,277MB 対 線 1,802MB)。
	opts := headlessOpts()
	if heapMB > 0 {
		opts = fmt.Sprintf("%s -Xmx%dm", opts, heapMB)
	}
	env = append(append([]string{}, env...), "JAVA_TOOL_OPTIONS="+opts)

	// 素のパイプで十分 (端末は要らない)。エコーが無いので、番兵文字列は
	// repl が処理した応答の中にだけ現れる。
	//
	// WhyNot: exec の StdinPipe/StdoutPipe を使わないのは、それらを Wait が
	// 閉じにいき、出力を読む goroutine と取り合いになるため。
	inR, inW, err := os.Pipe()
	if err != nil {
		return false, err
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		inR.Close()
		inW.Close()
		return false, err
	}
	// repl が起動時に読むソースを、起動の前に控える。
	startAt := time.Now()
	startSrc := takeSources(d.pkg)
	cmd := exec.Command(flixBin(d.root, d.pkg), "repl")
	cmd.Dir = d.pkg
	cmd.Env = env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = inR, outW, outW
	if err := cmd.Start(); err != nil {
		inR.Close()
		inW.Close()
		outR.Close()
		outW.Close()
		return false, err
	}
	inR.Close()
	outW.Close()
	_ = os.WriteFile(filepath.Join(d.sd, "repl.pid"),
		[]byte(strconv.Itoa(cmd.Process.Pid)), 0o644)
	d.cmd, d.stdin = cmd, inW
	// パイプの読みはブロックする一方、check には締め切りが要る。
	// 読み専用の脇 goroutine がチャネルへ流し、本流は締め切り付きで待つ。
	ch := make(chan []byte, 64)
	gone := make(chan struct{})
	d.out, d.gone = ch, gone
	// waitErr は前の repl の物を持ち越さない (上限なしのリトライでログが濁る)。
	d.waitErr = nil
	go pump(outR, ch)
	go func() {
		d.waitErr = cmd.Wait()
		close(gone)
	}()
	d.checks = 0

	// 初回コンパイルが終わるまで repl は入力を処理しない。
	// 番兵を投げて応答が返る = 温まった、とみなす。
	//
	// タイムアウトは check 用 (workTimeoutSec) より短い warmTimeoutSec。正常な
	// ウォームアップは数十秒で終わり、それを大きく超えるのはヒープ不足の
	// GC スラッシングがほぼ全て — 900 秒待たず数分で打ち切って、上限なしの
	// リトライへ渡す。
	work := seconds(*d.r.Checkd.Daemon.WarmTimeoutSec)
	if err := d.send(":zzz-warm\n"); err != nil {
		d.killRepl()
		return false, err
	}
	if ok, raw := d.waitFor("zzz-warm", work); !ok {
		// 「タイムアウト」と「repl が自分で死んだ (EOF)」は原因が別物。
		// エラーの本文と exit code を必ず残す — ここを捨てると根本原因が消える。
		reason := "タイムアウト"
		if d.replGone() {
			reason = "repl が自分で終了 (EOF)"
		}
		// 上限つきで「生きたままタイムアウト (GC スラッシング)」か「OutOfMemory で
		// 死亡」なら、上限なしのリトライに値する。
		heapSuspect := heapMB > 0 &&
			(!d.replGone() || bytes.Contains(raw, []byte("OutOfMemory")) ||
				bytes.Contains(raw, []byte("StackOverflowError")))
		d.killRepl()
		if d.waitErr != nil {
			reason += fmt.Sprintf(" wait=%v", d.waitErr)
		}
		d.log(fmt.Sprintf("repl のウォームアップに失敗 (-Xmx %dMB, %s)。出力の末尾:\n%s", heapMB, reason, tailLines(raw, 20)))
		return heapSuspect, fmt.Errorf("repl の起動に失敗 (%s)", reason)
	}
	// 鮮度の基準は温め完了後に撮る。起動中の依存解決が lib/ を触るので、
	// 先に撮ると 1 回目の照合が必ず「変わった」になってしまう。
	d.snapshot = d.takeSnapshot()
	// repl は起動時の読み込みが済んでから監視を始めるので、温めている間の書き換えは
	// 知らせが来ず、ずっと取り込まれない。変わっていたらこの repl は使わない。
	if !sameSources(takeSources(d.pkg), startSrc) {
		d.killRepl()
		d.log("温めている間にソースが変わった — この repl は書き換えを取り込めないので捨てる")
		return false, fmt.Errorf("温めている間にソースが変わった")
	}
	d.seen, d.seenAt = startSrc, startAt
	// 作り立ての repl の結果は持ち越しを含まないので、疑いも白紙に戻す。
	d.hasPrevFail = false
	return false, nil
}

// psBin は ps の置き場。PATH に頼ると make 経由以外の起動で見つからないことが
// あるので絶対パスを先に見る。
func psBin() string {
	if isFile("/bin/ps") {
		return "/bin/ps"
	}
	return "ps"
}

// tailLines は出力の末尾 n 行を返す (ANSI は落とす。ログにエラーの本文を残す用)。
func tailLines(raw []byte, n int) string {
	clean := ansi.ReplaceAll(raw, nil)
	lines := strings.Split(strings.TrimRight(string(clean), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// sweepStaleLocks は lib/cache に残った Maven の lock を掃く。
// SIGKILL された解決者の lock は誰も消さず、次の解決者が「他プロセスが取得中」と
// 読んで無期限に待つ (0% CPU のハングの正体)。生きている解決者を巻き込まないよう、
// 古い物だけ消す。
func (d *daemon) sweepStaleLocks() {
	cache := filepath.Join(d.pkg, "lib", "cache")
	cutoff := time.Now().Add(-10 * time.Minute)
	var removed []string
	_ = filepath.Walk(cache, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() {
			return nil
		}
		if strings.HasSuffix(path, ".lock") && info.ModTime().Before(cutoff) {
			if os.Remove(path) == nil {
				removed = append(removed, strings.TrimPrefix(path, d.pkg+string(os.PathSeparator)))
			}
		}
		return nil
	})
	if len(removed) > 0 {
		d.log(fmt.Sprintf("古い lock を %d 個掃いた: %s", len(removed), strings.Join(removed, " ")))
	}
}

func pump(r *os.File, ch chan []byte) {
	defer close(ch)
	defer r.Close()
	buf := make([]byte, 65536)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			ch <- chunk
		}
		if err != nil {
			return
		}
	}
}

func (d *daemon) send(s string) error {
	if d.stdin == nil {
		return io.ErrClosedPipe
	}
	_, err := d.stdin.WriteString(s)
	return err
}

// killRepl は repl を畳む。まず入力を閉じて自分で降りてもらい、駄目なら止める。
func (d *daemon) killRepl() {
	if d.cmd == nil {
		return
	}
	if d.stdin != nil {
		d.stdin.Close()
		d.stdin = nil
	}
	if d.gone == nil {
		_ = d.cmd.Process.Kill()
	} else {
		select {
		case <-d.gone:
		// 依存解決 (ネットワーク待ち) の最中に畳むことがある。短い猶予で
		// SIGKILL すると Maven の lock が lib/cache に残るので、長めに待つ。
		case <-time.After(20 * time.Second):
			_ = d.cmd.Process.Kill()
			<-d.gone
		}
	}
	d.cmd = nil
	d.out = nil
	d.gone = nil
	_ = os.Remove(filepath.Join(d.sd, "repl.pid"))
}

// killStaleRepl は repl.pid を読み、プロセスが生きていれば kill する。
// killRepl が正常に通れば repl.pid は消えているので、ここに残っているのは
// デーモンの異常終了で取り残された repl プロセスだけ。
func (d *daemon) killStaleRepl() {
	path := filepath.Join(d.sd, "repl.pid")
	raw, err := os.ReadFile(path)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		_ = os.Remove(path)
		return
	}
	// pid は OS が使い回す。repl.pid が古い(再起動をまたいだ等)と、同じ番号が
	// 無関係のプロセスに渡っていることがあるので、コマンドラインが flix である
	// ことを確かめてから kill する。確かめられない環境では kill しない(安全側)。
	if hooks.PidAlive(pid) && isFlixProcess(pid) {
		if proc, err := os.FindProcess(pid); err == nil {
			_ = proc.Kill()
			d.log(fmt.Sprintf("stale な repl プロセス (pid %d) を kill した", pid))
		}
	}
	_ = os.Remove(path)
}

// isFlixProcess は pid のコマンドラインに flix が含まれるかを見る。
// ps が無い・読めない環境では false(kill しない側)に倒す。
func isFlixProcess(pid int) bool {
	out, err := exec.Command(psBin(), "-p", strconv.Itoa(pid), "-o", "command=").Output()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "flix")
}

func (d *daemon) replGone() bool {
	if d.cmd == nil || d.gone == nil {
		return true
	}
	select {
	case <-d.gone:
		return true
	default:
		return false
	}
}

// rssMB は repl が今どれだけメモリを抱えているか。測れない環境では -1。
//
// WhyNot: 測れないときに 0 を返さないのは、0 なら「痩せている」と読めてしまい、
// 上限による立て直しが永久に来なくなるため (-1 は回数の上限に任せる印)。
func (d *daemon) rssMB() int {
	if d.cmd == nil || d.cmd.Process == nil {
		return -1
	}
	out, err := exec.Command(psBin(), "-p", strconv.Itoa(d.cmd.Process.Pid), "-o", "rss=").Output()
	if err != nil {
		return -1
	}
	kb, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return -1
	}
	return kb / 1024
}

// --- 鮮度 (make sync-engine-full で lib/ の fpkg 実体が差し替わったら作り直す)

func (d *daemon) takeSnapshot() map[string]int64 {
	items := map[string]int64{}
	toml := filepath.Join(d.pkg, "flix.toml")
	items[toml] = mtimeNS(toml)
	seen := map[string]bool{}
	suffixes := d.r.Checkd.Daemon.DepSuffixes
	var walk func(dir string)
	walk = func(dir string) {
		real, err := filepath.EvalSymlinks(dir)
		if err != nil {
			real = dir
		}
		if seen[real] {
			return
		}
		seen[real] = true
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range entries {
			p := filepath.Join(dir, e.Name())
			// Stat は symlink の先を見る (配った実体の新しさが知りたい)。
			info, err := os.Stat(p)
			if err != nil {
				continue
			}
			if info.IsDir() {
				walk(p)
				continue
			}
			// 依存の実体だけ見る。cache の lock 等まで見ると、無関係な
			// 更新のたびに repl を作り直してしまう。
			for _, s := range suffixes {
				if strings.HasSuffix(e.Name(), s) {
					items[p] = info.ModTime().UnixNano()
					break
				}
			}
		}
	}
	walk(filepath.Join(d.pkg, "lib"))
	return items
}

func mtimeNS(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.ModTime().UnixNano()
}

func sameSnapshot(a, b map[string]int64) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if w, ok := b[k]; !ok || w != v {
			return false
		}
	}
	return true
}

func snapshotDiff(now, old map[string]int64) []string {
	var diff []string
	for k, v := range now {
		if w, ok := old[k]; !ok || w != v {
			diff = append(diff, k)
		}
	}
	for k := range old {
		if _, ok := now[k]; !ok {
			diff = append(diff, k)
		}
	}
	if len(diff) > 5 {
		diff = diff[:5]
	}
	return diff
}

// --- 入出力

func (d *daemon) waitFor(marker string, timeout time.Duration) (bool, []byte) {
	deadline := time.Now().Add(timeout)
	var out []byte
	ch := d.out
	for time.Now().Before(deadline) {
		select {
		case chunk, ok := <-ch:
			if !ok {
				return false, out // repl が居なくなった
			}
			out = append(out, chunk...)
			if bytes.Contains(ansi.ReplaceAll(out, nil), []byte(marker)) {
				return true, out
			}
		case <-time.After(250 * time.Millisecond):
		}
	}
	return false, out
}

// settle は書きかけ読みを避けて少し待ち、最新ソースの mtime を返す (持ち越し検出に使う)。
func (d *daemon) settle() float64 {
	// ファイル保存の直後に check すると書きかけを読むことがある。
	// 一番新しい .flix の保存から settleSec 経つまで待つ (古ければ待たない)。
	skip := map[string]bool{}
	for _, s := range d.r.Checkd.Daemon.SkipDirs {
		skip[s] = true
	}
	var newest float64
	_ = filepath.Walk(d.pkg, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return nil
		}
		if info.IsDir() {
			if path != d.pkg && skip[filepath.Base(path)] {
				return filepath.SkipDir
			}
			return nil
		}
		name := info.Name()
		if strings.HasSuffix(name, ".flix") || name == "flix.toml" {
			t := float64(info.ModTime().UnixNano()) / 1e9
			if t > newest {
				newest = t
			}
		}
		return nil
	})
	settle := *d.r.Checkd.Daemon.SettleSec
	wait := settle - (float64(time.Now().UnixNano())/1e9 - newest)
	if wait > 0 && wait <= settle {
		time.Sleep(seconds(wait))
	}
	return newest
}

// scrub は repl の飾り (プロンプト・番兵の応答) を落とし、check の出力だけ残す。
func scrub(raw []byte, sentinel string) string {
	txt := string(ansi.ReplaceAll(raw, nil))
	txt = strings.ReplaceAll(txt, "\r\n", "\n")
	var lines []string
	for _, line := range strings.Split(txt, "\n") {
		// 残った \r は「行頭に戻って上書き」の印。スピナーの描き捨てを消して、
		// その行で最後に描かれた文字だけを残す。
		if i := strings.LastIndex(line, "\r"); i >= 0 {
			line = line[i+1:]
		}
		if strings.Contains(line, sentinel) {
			continue
		}
		line = strings.ReplaceAll(line, "flix> ", "")
		line = strings.ReplaceAll(line, "flix>", "")
		// repl がコンパイル中に出す進捗ドット (=>....) は CLI には無いので削る
		if line != "" && strings.Trim(line, "=>. ") == "" {
			continue
		}
		lines = append(lines, line)
	}
	out := strings.Trim(strings.Join(lines, "\n"), "\n")
	if out == "" {
		return ""
	}
	return out + "\n"
}

// exitCodeOf は CLI と同じ終了コードを出力から復元する。読み取れなければ負 (=素の CLI へ)。
func exitCodeOf(verb, text string) int {
	// ヒープの蓋が足りないと JVM が音を上げる。これは「ソースが悪い」ではないので、
	// 赤として持ち帰らず素の CLI へ投げ直す (蓋の無い JVM なら通る)。
	if strings.Contains(text, "OutOfMemoryError") {
		return -1
	}
	if strings.Contains(text, "Compilation failed") {
		return 1
	}
	if verb == "check" {
		// このバージョンの flix は check のエラーで "Compilation failed" を
		// 出さない。代わりにエラーは "-- Resolution Error [E2136] ----" の
		// ような "-- 〜 Error" 見出しで始まるので、それをマーカーにする。
		if errorHeading.MatchString(text) {
			return 1
		}
		return 0
	}
	// test はまとめ行 (Passed: N, Failed: M.) が唯一の頼り。行が無い出力は
	// 途中で切れた可能性があるので、推測せず素の CLI に投げ直す。
	m := testSummary.FindStringSubmatch(text)
	if m == nil {
		return -1
	}
	if m[2] == "0" {
		return 0
	}
	return 1
}

// doCheck は (終了コード, 出力)。コードが負なら「素の CLI で確かめて」の意味。
func (d *daemon) doCheck(verb string, retried bool) (int, string) {
	t0 := time.Now()
	if d.replGone() {
		d.log("repl が居ないので起動")
		d.killRepl()
		if err := d.startRepl(); err != nil {
			d.log(fmt.Sprintf("%s 失敗: %v", verb, err))
			d.killRepl()
			return -1, ""
		}
	} else if now := d.takeSnapshot(); !sameSnapshot(now, d.snapshot) {
		// 依存の実体が変わった。温めた結果は古い依存で出るので作り直す。
		d.log(fmt.Sprintf("依存が変わったので repl を作り直す: %v", snapshotDiff(now, d.snapshot)))
		d.killRepl()
		if err := d.startRepl(); err != nil {
			d.log(fmt.Sprintf("%s 失敗: %v", verb, err))
			d.killRepl()
			return -1, ""
		}
	}
	srcNewest := d.settle()
	// repl の監視が今のソースを拾うまで待つ。追いつけなければ、常駐の答えは
	// 古いソースの物になりうるので返さない (素の CLI で確かめ直してもらう)。
	if !d.catchUp() {
		d.log(fmt.Sprintf("%s: ソースが書き換わり続けて repl が追いつけない → 素の CLI へ", verb))
		return -1, ""
	}
	// 前のコマンドの残り (遅れて届いたプロンプト等) を捨てる。
	// 混ざると check の出力に無関係な欠片が載ってしまう。
	for drained := false; !drained; {
		select {
		case _, ok := <-d.out:
			if !ok {
				drained = true
			}
		default:
			drained = true
		}
	}
	d.seq++
	sentinel := fmt.Sprintf("zzz%d", d.seq)
	if err := d.send(fmt.Sprintf(":%s\n:%s\n", verb, sentinel)); err != nil {
		d.log(fmt.Sprintf("%s 失敗: %v", verb, err))
		d.killRepl()
		return -1, ""
	}
	ok, raw := d.waitFor(sentinel, seconds(*d.r.Checkd.Daemon.WorkTimeoutSec))
	if !ok {
		d.log(fmt.Sprintf("%s #%d が番兵まで届かずタイムアウト", verb, d.checks+1))
		d.killRepl()
		return -1, ""
	}
	text := scrub(raw, sentinel)
	code := exitCodeOf(verb, text)
	if code < 0 {
		// 判定できない出力を返すと exit code が嘘になる。repl も疑わしいので捨てる
		d.log(fmt.Sprintf("%s の出力から結果を読み取れない → 素の CLI へ", verb))
		d.killRepl()
		return -1, ""
	}
	d.checks++
	rss := d.rssMB()
	d.log(fmt.Sprintf("%s #%d 完了 exit=%d %.2fs RSS=%dMB",
		verb, d.checks, code, time.Since(t0).Seconds(), rss))
	// 持ち越しの防波堤: ソースが前回の失敗より後に編集されたのに、
	// バイト同一のエラーが返った。repl の増分コンパイルがエラーを
	// 抱え込んだ疑いがあるので、作り直して素の状態で確かめ直す。
	// 本当に直っていなければ再検査も同じエラーで、結果は変わらない。
	if code == 1 && !retried && d.hasPrevFail &&
		text == d.prevFail && srcNewest > d.prevFailTime {
		d.log("編集後も同一エラー — repl の持ち越しを疑い、作り直して確かめる")
		d.killRepl()
		d.hasPrevFail = false
		return d.doCheck(verb, true)
	}
	if code == 1 {
		d.prevFail, d.prevFailTime, d.hasPrevFail = text, srcNewest, true
	} else {
		d.hasPrevFail = false
	}
	// :test は 1 回で数百 MB 増えることがある。上限超えは次回の作り直しに
	// 回さず、その場で使い捨てて漏れを持ち越さない。
	if d.checks >= *d.r.Checkd.Daemon.MaxChecks || rss > d.rssLimitMB {
		d.log("repl を使い捨てる (回数か RSS の上限)")
		d.killRepl()
	}
	return code, text
}

// --- 本体ループ

func respond(conn net.Conn, code int, body string) {
	_, _ = io.WriteString(conn, fmt.Sprintf("RES %d %d\n%s", code, len(body), body))
}

func (d *daemon) loop() {
	idle := idleSec(d.r)
	convTimeout := seconds(*d.r.Checkd.Daemon.ConvTimeoutSec)
	for {
		if tl, ok := d.ln.(*net.TCPListener); ok {
			_ = tl.SetDeadline(time.Now().Add(idle))
		}
		conn, err := d.ln.Accept()
		if err != nil {
			return // 誰も来ないなら消える。溜まった常駐でマシンを重くしない
		}
		_ = conn.SetDeadline(time.Now().Add(convTimeout))
		command := readCommand(conn)
		switch command {
		case "CHECK", "TEST":
			_ = conn.SetDeadline(time.Time{})
			code, body := d.doCheck(strings.ToLower(command), false)
			respond(conn, code, body)
		case "PING":
			respond(conn, 0, "")
		case "STOP":
			respond(conn, 0, "")
			conn.Close()
			return
		default:
			respond(conn, -1, "")
		}
		conn.Close()
	}
}

func readCommand(conn net.Conn) string {
	var data []byte
	buf := make([]byte, 4096)
	for !bytes.Contains(data, []byte("\n")) {
		n, err := conn.Read(buf)
		if n > 0 {
			data = append(data, buf[:n]...)
		}
		if err != nil {
			break
		}
	}
	line, _, _ := bytes.Cut(data, []byte("\n"))
	return strings.TrimSpace(string(line))
}

func (d *daemon) shutdown() {
	d.killRepl()
	if d.ln != nil {
		d.ln.Close()
	}
	d.releasePidFile()
}
