// Package heavy は、同じマシンで並んで走るエージェントが重い処理（描き出し・テスト・
// エンジンのビルド）を 1 本ずつ流すための鍵。
//
//	fge heavy <コマンド...>   鍵を取ってコマンドを流し、終わったら（失敗・中断でも）自分の鍵だけ外す
//	fge heavy --status       今の持ち主と待っている列
//
// 鍵は /tmp/fge-heavy.lock（FGE_HEAVY_LOCK で差し替え）の mkdir。mkdir が成功した方が
// 持ち主で、手書きの `until mkdir …; rmdir` とも同じ鍵を取り合う。
// 持ち主は鍵の中の owner.json に書き、待っている列は <鍵>.queue/<pid>.json に並ぶ。
package heavy

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// DefaultLock は鍵の置き場。手書きの書き方と同じ名前にそろえる。
const DefaultLock = "/tmp/fge-heavy.lock"

// TokenEnv は鍵を持っている heavy が子へ渡す合言葉。
// 子の中でもう一度 heavy を呼んだとき、自分の鍵を待って止まらないために使う。
const TokenEnv = "FGE_HEAVY_TOKEN"

const ownerFile = "owner.json"

// 持ち主の pid が見えない鍵（手書きの書き方）を外してよい古さ。
const anonymousStale = 40 * time.Minute

// 待ち列の札の心拍（poll ごとに触る）がこれより古ければ、その札は飛ばす。
const queueStale = time.Minute

// 外しの最中に死んだ heavy が残した reap の鍵を外してよい古さ。
const reapStale = 2 * time.Minute

// Owner は鍵の持ち主、または列に並んでいる 1 本。
type Owner struct {
	Workdir      string    `json:"workdir"`
	PID          int       `json:"pid"`
	Started      string    `json:"started,omitempty"`
	ChildPID     int       `json:"childPid,omitempty"`
	ChildStarted string    `json:"childStarted,omitempty"`
	Command      string    `json:"command"`
	Since        time.Time `json:"since"`
	Token        string    `json:"token,omitempty"`
}

// Options は差し替えられる所。テストが待ち時間と場所を縮める。
type Options struct {
	Lock string
	Poll time.Duration
	Now  func() time.Time
	Err  io.Writer
}

func defaults(o Options) Options {
	if o.Lock == "" {
		o.Lock = os.Getenv("FGE_HEAVY_LOCK")
	}
	if o.Lock == "" {
		o.Lock = DefaultLock
	}
	if o.Poll == 0 {
		o.Poll = 3 * time.Second
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Err == nil {
		o.Err = os.Stderr
	}
	return o
}

func queueDir(lock string) string { return lock + ".queue" }
func reapDir(lock string) string  { return lock + ".reap" }

// Run は fge heavy の入口。args は heavy に渡った引数そのまま。
func Run(args []string, asJSON bool, o Options) int {
	o = defaults(o)
	var cmd []string
	status := false
	for i, a := range args {
		if a == "--" {
			cmd = args[i+1:]
			break
		}
		if a == "--status" {
			status = true
			continue
		}
		if a == "--json" {
			continue
		}
		if strings.HasPrefix(a, "--") {
			fmt.Fprintf(o.Err, "heavy: 知らない旗 %s\n", a)
			return 2
		}
		cmd = args[i:]
		break
	}
	if status {
		return printStatus(os.Stdout, o, asJSON)
	}
	if len(cmd) == 0 {
		fmt.Fprintln(o.Err, "使い方: fge heavy <コマンド...>   鍵を取ってコマンドを流す（CHECKD=0 が既定）")
		fmt.Fprintln(o.Err, "        fge heavy --status       今の持ち主と待っている列")
		return 2
	}
	return Exec(cmd, "", o)
}

// ── 鍵の中身 ─────────────────────────────────────────────

// Snapshot は --status の中身。
type Snapshot struct {
	Lock    string  `json:"lock"`
	Held    bool    `json:"held"`
	Owner   *Owner  `json:"owner,omitempty"`
	Alive   bool    `json:"alive"`
	Age     string  `json:"age,omitempty"`
	Waiting []Owner `json:"waiting"`
}

func readOwner(lock string) (*Owner, error) {
	data, err := os.ReadFile(filepath.Join(lock, ownerFile))
	if err != nil {
		return nil, err
	}
	var ow Owner
	if err := json.Unmarshal(data, &ow); err != nil {
		return nil, err
	}
	return &ow, nil
}

func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	// WhyNot: 一時ファイルを鍵のフォルダの外（隣）に置くのは、書いている途中で殺されると
	// 鍵の中に残り、手書きの rmdir も heavy の外しも「空でない」で失敗し続けるため。
	tmp := filepath.Join(filepath.Dir(filepath.Dir(path)),
		"."+filepath.Base(filepath.Dir(path))+"."+filepath.Base(path)+".tmp"+strconv.Itoa(os.Getpid()))
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// isAlive は持ち主（heavy 本体か、その子）がまだ居るか。
func isAlive(ow *Owner) bool {
	if processAlive(ow.PID, ow.Started) {
		return true
	}
	return ow.ChildPID > 0 && processAlive(ow.ChildPID, ow.ChildStarted)
}

// isStale は鍵を外してよいか。持ち主が書いてあれば pid だけで決め、
// 書いていない鍵（手書きの書き方・書く前の一瞬）は古さで決める。
func isStale(lock string, now time.Time) (bool, *Owner) {
	info, err := os.Stat(lock)
	if err != nil {
		return false, nil
	}
	ow, err := readOwner(lock)
	if err == nil {
		return !isAlive(ow), ow
	}
	return now.Sub(info.ModTime()) > anonymousStale, nil
}

// reap は持ち主の居ない鍵を外す。外したら true。
//
// WhyNot: 見てすぐ消さず reap の鍵を挟むのは、2 本が同時に「死んでいる」と見て
// 片方が外して取り直した直後の鍵を、もう片方が消してしまうため。
func reap(o Options) bool {
	rd := reapDir(o.Lock)
	if err := os.Mkdir(rd, 0o755); err != nil {
		if info, err := os.Stat(rd); err == nil && o.Now().Sub(info.ModTime()) > reapStale {
			os.Remove(rd)
		}
		return false
	}
	defer os.Remove(rd)
	stale, ow := isStale(o.Lock, o.Now())
	if !stale {
		return false
	}
	if ow != nil {
		fmt.Fprintf(o.Err, "[heavy] 持ち主の居ない鍵を外します (%s pid %d: %s)\n",
			shortPath(ow.Workdir), ow.PID, ow.Command)
		os.Remove(filepath.Join(o.Lock, ownerFile))
	} else {
		fmt.Fprintf(o.Err, "[heavy] 持ち主の書かれていない鍵が %d 分を超えたので外します\n",
			int(anonymousStale.Minutes()))
	}
	return os.Remove(o.Lock) == nil
}

// ── 待っている列 ─────────────────────────────────────────

// waiting は列に並んでいる生きた heavy を、並んだ順に返す。死んだ札はここで掃く。
func waiting(o Options) []Owner {
	entries, _ := os.ReadDir(queueDir(o.Lock))
	var list []Owner
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		path := filepath.Join(queueDir(o.Lock), e.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var ow Owner
		if json.Unmarshal(data, &ow) != nil || !processAlive(ow.PID, ow.Started) {
			os.Remove(path)
			continue
		}
		// WhyNot: 心拍の止まった札（Ctrl-Z で止められた heavy）を飛ばすのは、先頭だけが
		// 鍵を試す決まりなので、止まった先頭が後ろの全員を待たせ続けるため。
		if info, err := e.Info(); err == nil && o.Now().Sub(info.ModTime()) > queueStale {
			continue
		}
		list = append(list, ow)
	}
	sort.Slice(list, func(i, j int) bool {
		if !list[i].Since.Equal(list[j].Since) {
			return list[i].Since.Before(list[j].Since)
		}
		return list[i].PID < list[j].PID
	})
	return list
}

func queuePath(o Options, pid int) string {
	return filepath.Join(queueDir(o.Lock), strconv.Itoa(pid)+".json")
}

// ── 流す ─────────────────────────────────────────────────

func newToken() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// Exec は鍵を取って cmd を dir（空なら今の場所）で流し、終わったら鍵を外す。
func Exec(cmd []string, dir string, o Options) int {
	return Hold(quoteCommand(cmd), dir, o, func(run Runner) int {
		return run(dir, cmd...)
	})
}

// Hold は鍵を取ったまま fn を流し、終わったら（失敗・中断でも）鍵を外す。
// fge の他のサブコマンド（use-engine・compare）が重い段だけを囲む口。fn は run で子を流す。
// 途中で止められたら run は 130 を返すので、fn はそれを見て抜ける。
func Hold(desc, dir string, o Options, fn func(run Runner) int) int {
	o = defaults(o)
	// 鍵を持っている heavy の子の中で呼ばれたら、待たずにそのまま流す。
	if tok := os.Getenv(TokenEnv); tok != "" {
		if ow, err := readOwner(o.Lock); err == nil && ow.Token == tok {
			return fn(func(d string, cmd ...string) int {
				return runChild(cmd, d, tok, nil, o, nil, nil)
			})
		}
	}
	wd := dir
	if wd == "" {
		wd, _ = os.Getwd()
	} else if abs, err := filepath.Abs(dir); err == nil {
		wd = abs
	}
	me := Owner{
		Workdir: wd,
		PID:     os.Getpid(),
		Started: processStarted(os.Getpid()),
		Command: desc,
		Since:   o.Now(),
		Token:   newToken(),
	}

	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, InterruptSignals...)
	defer signal.Stop(sigs)

	if err := acquire(&me, sigs, o); err != nil {
		if errors.Is(err, errInterrupted) {
			return 130
		}
		fmt.Fprintf(o.Err, "heavy: %v\n", err)
		return 2
	}
	defer release(o, me.Token)
	var stopped atomic.Bool
	return fn(func(d string, cmd ...string) int {
		return runChild(cmd, d, me.Token, func(child int) {
			me.ChildPID, me.ChildStarted = child, processStarted(child)
			writeJSON(filepath.Join(o.Lock, ownerFile), me)
		}, o, sigs, &stopped)
	})
}

var errInterrupted = errors.New("待っている間に止められました")

func acquire(me *Owner, sigs chan os.Signal, o Options) error {
	if err := os.MkdirAll(queueDir(o.Lock), 0o777); err != nil {
		return fmt.Errorf("待ちの列 %s を作れません: %v", queueDir(o.Lock), err)
	}
	qp := queuePath(o, me.PID)
	if err := writeJSON(qp, me); err != nil {
		return fmt.Errorf("待ちの列に並べません: %v", err)
	}
	defer os.Remove(qp)

	start := o.Now()
	var lastNote time.Time
	for {
		list := waiting(o)
		// WhyNot: 列の先頭だけが mkdir を試すのは、空いた瞬間に後から来た方が
		// 先に取ると、何本待っているかを見せても順番の目安にならないため。
		head := len(list) == 0 || list[0].PID == me.PID
		if head {
			if err := os.Mkdir(o.Lock, 0o755); err == nil {
				me.Since = o.Now()
				if err := writeJSON(filepath.Join(o.Lock, ownerFile), me); err != nil {
					os.Remove(o.Lock)
					return fmt.Errorf("持ち主を書けません: %v", err)
				}
				if waited := o.Now().Sub(start); waited >= time.Second {
					fmt.Fprintf(o.Err, "[heavy] 鍵を取りました (待ち %s)\n", roundDuration(waited))
				}
				return nil
			} else if !errors.Is(err, os.ErrExist) {
				return fmt.Errorf("鍵 %s を作れません: %v", o.Lock, err)
			}
			if reap(o) {
				continue
			}
		}
		if lastNote.IsZero() || o.Now().Sub(lastNote) >= 2*time.Minute {
			fmt.Fprintf(o.Err, "[heavy] 鍵を待っています: %s・前に %d 本\n",
				describeHolder(o), position(list, me.PID))
			lastNote = o.Now()
		}
		select {
		case <-sigs:
			return errInterrupted
		case <-time.After(o.Poll):
			now := o.Now()
			os.Chtimes(qp, now, now)
		}
	}
}

func position(list []Owner, pid int) int {
	for i, w := range list {
		if w.PID == pid {
			return i
		}
	}
	return len(list)
}

// release は自分の鍵だけを外す。合言葉が違えば（外されて他が取った後なら）触らない。
func release(o Options, token string) {
	ow, err := readOwner(o.Lock)
	if err != nil || ow.Token != token {
		return
	}
	os.Remove(filepath.Join(o.Lock, ownerFile))
	os.Remove(o.Lock)
}

// Runner は鍵の内側で子を 1 本流す。dir が空なら今の場所。終了コードを返す。
type Runner func(dir string, cmd ...string) int

// runChild はコマンドを流して終了コードを返す。sigs が来たら子のプロセスグループへ回す。
// sigs が nil（外の heavy の鍵の中）なら子を同じグループに置き、シグナルは外に任せる。
func runChild(cmd []string, dir, token string, started func(int), o Options, sigs chan os.Signal, stopped *atomic.Bool) int {
	if stopped != nil && stopped.Load() {
		return 130
	}
	c := exec.Command(cmd[0], cmd[1:]...)
	c.Dir = dir
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	env := os.Environ()
	if _, set := os.LookupEnv("CHECKD"); !set {
		// WhyNot: 常駐の checkd に相乗りさせない。重い処理は 1 本ずつ流すので
		// 常駐を温める得が無く、常駐の repl は物理メモリに蓋があって描き出しが収まらない。
		env = append(env, "CHECKD=0")
	}
	c.Env = append(env, TokenEnv+"="+token)
	// WhyNot: 中から呼ばれた heavy は子を別のグループへ出さない。外の heavy が
	// 回したシグナルが孫まで届かず、孫だけが走り残るため。
	if sigs != nil {
		setGroup(c)
		// WhyNot: 別グループの子に端末の stdin を渡さない。読みに行った途端 SIGTTIN で
		// 止まり、鍵を持ったまま動かなくなるため。
		c.Stdin = nil
	}
	if err := c.Start(); err != nil {
		fmt.Fprintf(o.Err, "heavy: %s を起動できません: %v\n", cmd[0], err)
		return 127
	}
	if started != nil {
		started(c.Process.Pid)
	}
	done := make(chan struct{})
	if sigs != nil {
		go func() {
			for {
				select {
				case s := <-sigs:
					// 2 回目は待たずに止める（JVM が SIGTERM で降りないときの逃げ道）。
					if stopped.Swap(true) {
						killGroup(c)
					} else {
						signalGroup(c, s)
					}
				case <-done:
					return
				}
			}
		}()
	}
	err := c.Wait()
	close(done)
	if stopped != nil && stopped.Load() {
		return 130
	}
	return exitCode(c, err)
}

// ── 見せる ───────────────────────────────────────────────

func describeHolder(o Options) string {
	ow, err := readOwner(o.Lock)
	if err != nil {
		info, serr := os.Stat(o.Lock)
		if serr != nil {
			return "空き"
		}
		return fmt.Sprintf("持ち主の書かれていない鍵 (%s前から)", roundDuration(o.Now().Sub(info.ModTime())))
	}
	return fmt.Sprintf("%s pid %d が %s前から %s", shortPath(ow.Workdir), ow.PID,
		roundDuration(o.Now().Sub(ow.Since)), ow.Command)
}

func snapshot(o Options) Snapshot {
	s := Snapshot{Lock: o.Lock, Waiting: waiting(o)}
	if s.Waiting == nil {
		s.Waiting = []Owner{}
	}
	info, err := os.Stat(o.Lock)
	if err != nil {
		return s
	}
	s.Held = true
	if ow, err := readOwner(o.Lock); err == nil {
		ow.Token = ""
		s.Owner = ow
		s.Alive = isAlive(ow)
		s.Age = roundDuration(o.Now().Sub(ow.Since))
	} else {
		s.Age = roundDuration(o.Now().Sub(info.ModTime()))
	}
	for i := range s.Waiting {
		s.Waiting[i].Token = ""
	}
	return s
}

func printStatus(w io.Writer, o Options, asJSON bool) int {
	s := snapshot(o)
	if asJSON {
		data, _ := json.Marshal(s)
		fmt.Fprintln(w, string(data))
		return 0
	}
	switch {
	case !s.Held:
		fmt.Fprintf(w, "[heavy] 空き (%s)\n", s.Lock)
	case s.Owner == nil:
		fmt.Fprintf(w, "[heavy] 持ち主の書かれていない鍵 (手書きの mkdir)・%s前から\n", s.Age)
	default:
		state := "生きている"
		if !s.Alive {
			state = "死んでいる・次に待つ heavy が外す"
		}
		fmt.Fprintf(w, "[heavy] 持ち主: %s pid %d (%s)・%s前から\n        %s\n",
			shortPath(s.Owner.Workdir), s.Owner.PID, state, s.Age, s.Owner.Command)
	}
	if len(s.Waiting) == 0 {
		fmt.Fprintln(w, "[heavy] 待ち: なし (手書きの until mkdir で待っている物は数えられません)")
		return 0
	}
	fmt.Fprintf(w, "[heavy] 待ち %d 本 (この順で取る):\n", len(s.Waiting))
	for i, ow := range s.Waiting {
		fmt.Fprintf(w, "  %d. %s pid %d・%s前から: %s\n", i+1, shortPath(ow.Workdir), ow.PID,
			roundDuration(o.Now().Sub(ow.Since)), ow.Command)
	}
	return 0
}

func shortPath(p string) string {
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(p, home+"/") {
		return "~" + p[len(home):]
	}
	return p
}

func roundDuration(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%d 秒", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%d 分", int(d.Minutes()))
	default:
		return fmt.Sprintf("%d 時間 %d 分", int(d.Hours()), int(d.Minutes())%60)
	}
}

func quoteCommand(cmd []string) string {
	parts := make([]string, len(cmd))
	for i, a := range cmd {
		if a != "" && !strings.ContainsAny(a, " \t\n'\"\\$`*?;&|<>()") {
			parts[i] = a
			continue
		}
		parts[i] = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
	}
	return strings.Join(parts, " ")
}

func itoa(n int) string { return strconv.Itoa(n) }
