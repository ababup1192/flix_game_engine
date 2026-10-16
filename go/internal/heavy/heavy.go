// Package heavy は、同じマシンで並んで走るエージェントが重い処理（描き出し・テスト・
// エンジンのビルド）を決まった本数ずつ流すための鍵。
//
//	fge heavy <コマンド...>           鍵を取ってコマンドを流し、終わったら（失敗・中断でも）自分の鍵だけ外す
//	fge heavy --long|--short <...>    長い物か短い物かを名前の見分けより優先して決める
//	fge heavy --status                枠ごとの持ち主と待っている列
//	fge heavy --history[=時間]        直近の待ちと走りの合計（鍵を返すたびに <鍵>.log へ 1 行）
//
// 鍵は FGE_HEAVY_SLOTS 本（既定 3）の枠。枠 1 は /tmp/fge-heavy.lock（FGE_HEAVY_LOCK で
// 差し替え）、枠 2 からは <鍵>.2・<鍵>.3 … の mkdir。mkdir が成功した方がその枠の持ち主。
//
// 長い物（render-all・動画・compare など 10 分を超えうる物）は枠 1〜L（FGE_HEAVY_LONG_SLOTS・
// 既定 2）だけを使うので、長い物は L 本までしか重ならない。枠 L+1 から先は短い物（check・test・sync）
// だけの枠で、長い物が並んでも短い物が必ず 1 本は走れる。短い物は短い物だけの枠から先に取り、
// 空いていれば長い物の枠も使う。枠 1 の名前は 1 本だった頃の鍵と同じなので、手書きの
// `until mkdir …; rmdir` も古い heavy も枠 1 を取り合い、古い heavy のエントリは「枠 1 だけを待つ
// エントリ」として順番に並ぶ。0.35.26〜0.35.32 の heavy の長い物も枠 1 だけを取るので、版が混ざっても
// 長い物が L 本を超えたり、短い物だけの枠を長い物が取ったりはしない。
// 持ち主は枠の中の owner.json に書き、待っている列は <鍵>.queue/<pid>.json に並ぶ。
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
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// DefaultLock は鍵の置き場。手書きの書き方と同じ名前にそろえる。
const DefaultLock = "/tmp/fge-heavy.lock"

// SlotsEnv は枠の本数を変える環境変数。
const SlotsEnv = "FGE_HEAVY_SLOTS"

// DefaultSlots は枠の本数の既定（長い物の枠 DefaultLongSlots 本 + 短い物だけの枠 1 本）。
//
// WhyNot: 長い物 2 本 + 短い物 1 本にするのは、長い物が 1 本ずつしか流れないと長い物が 5 本並び、
// release が 47 分待ったため（2026-10-16）。長い物 2 本の同時は JVM 19.6GB で 64GB の 1/3
// （heavy3 の測定）。短い物だけの枠を 1 本残すのは、長い物で枠が埋まっても check・test が
// 長い物の後ろで 30 分待たないようにするため。
const DefaultSlots = 3

// LongSlotsEnv は長い物が使える枠の本数（枠 1 から数えて）を変える環境変数。
const LongSlotsEnv = "FGE_HEAVY_LONG_SLOTS"

// DefaultLongSlots は長い物が使える枠の本数の既定。枠が 2 本以上なら、短い物だけの枠を必ず 1 本残す
// （clampLongSlots）。
const DefaultLongSlots = 2

// longTarget は「長い物」の make の口の名前。語ごとに丸ごと照らす。
var longTarget = regexp.MustCompile(`^(render-all|reference-update|gallery-[\w-]+|[\w-]*-video(-[\w-]+)?|video-[\w-]+|compare:?)$`)

// noLockTarget は鍵を取らずにそのまま流す口（claude -p を待つだけで CPU をほとんど使わない物）。
//
// WhyNot: agent-eval を長い物として枠 1 に並べないのは、返事を待つ間ほぼ CPU を使わないのに
// 枠 1 を 20 分以上ふさぎ、動画・compare を全部その後ろに並ばせるため。同時に走る本数は
// fge agent-eval がマシン全体の枠（/tmp/fge-agent-eval.slots）で守り、中の make check は
// それぞれ heavy を通る。
var noLockTarget = regexp.MustCompile(`^agent-eval[\w-]*$`)

// cmdWord はコマンドの文字列を語に切る（bash -c '…' の中や compare の説明の中も同じに切る）。
var cmdWord = regexp.MustCompile(`[^\s'"();&|<>]+`)

// LooksLong は cmd が 10 分を超えうる長い物か（名前で見分ける）。
//
// WhyNot: パス（/ を含む語）と代入（= を含む語）を見ないのは、作業場の名前
// （id-x-video・fge-compare-…）やログの置き場に口の名前が入っていても、中身が make test なら短い物だから。
func LooksLong(cmd string) bool {
	return matchesWord(cmd, longTarget)
}

// matchesWord は cmd の語（パスと代入を除く）のどれかが re に丸ごと合うか。
func matchesWord(cmd string, re *regexp.Regexp) bool {
	for _, w := range cmdWord.FindAllString(cmd, -1) {
		if strings.ContainsAny(w, "/=") {
			continue
		}
		if re.MatchString(w) {
			return true
		}
	}
	return false
}

// heavyLongLine はゲームの Makefile の `HEAVY_LONG := lab combo-sweep …`（ゲーム固有の長い口）。
var heavyLongLine = regexp.MustCompile(`(?m)^HEAVY_LONG[ \t]*[:+?]?=[ \t]*(.*?)[ \t]*(?:#.*)?$`)

// LooksLongIn は LooksLong に加えて、dir の Makefile の HEAVY_LONG に書かれた口も長い物と見る。
//
// WhyNot: 過去の実行時間で自動に決めないのは、release・test が負荷しだいで 1〜25 分に揺れ、
// 一度遅かっただけの短い物を長い枠の後ろへ送ってしまうため。長いかどうかは口の持ち主
// （ゲームの Makefile）が 1 行で宣言し、付け忘れを呼ぶ側のエージェントに任せない。
func LooksLongIn(cmd, dir string) bool {
	if LooksLong(cmd) {
		return true
	}
	data, err := os.ReadFile(filepath.Join(dir, "Makefile"))
	if err != nil {
		return false
	}
	targets := map[string]bool{}
	for _, m := range heavyLongLine.FindAllSubmatch(data, -1) {
		for _, t := range strings.Fields(string(m[1])) {
			targets[t] = true
		}
	}
	if len(targets) == 0 {
		return false
	}
	for _, w := range cmdWord.FindAllString(cmd, -1) {
		if !strings.ContainsAny(w, "/=") && targets[w] {
			return true
		}
	}
	return false
}

// TokenEnv は鍵を持っている heavy が子へ渡す合言葉。
// 子の中でもう一度 heavy を呼んだとき、自分の鍵を待って止まらないために使う。
const TokenEnv = "FGE_HEAVY_TOKEN"

const ownerFile = "owner.json"

// 持ち主の pid が見えない鍵（手書きの書き方）を外してよい古さ。
const anonymousStale = 40 * time.Minute

// 待ち列のエントリの心拍（poll ごとに触る）がこれより古ければ、そのエントリは飛ばす。
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
	// Long は長い物（枠 1〜LongSlots を使う）。AnySlot はどの枠でも使える短い物。
	// 両方とも無いエントリは 1 本だった頃の heavy で、枠 1 だけを待つ。
	Long    bool `json:"long,omitempty"`
	AnySlot bool `json:"anySlot,omitempty"`
	// Slot は持っている枠（1 から数える）。待っている間は 0。
	Slot int `json:"slot,omitempty"`
	// Slots はこのエントリが知っている枠の本数。FGE_HEAVY_SLOTS が人ごとに違っても、
	// エントリが使えない枠をそのエントリに取っておかないために読む。
	Slots int `json:"slots,omitempty"`
	// LongSlots はこのエントリが知っている長い物の枠の本数。0 は 0.35.32 までの heavy の
	// エントリで、長い物は枠 1 だけ・短い物は枠 2 から先を取る決まりで読む。
	LongSlots int `json:"longSlots,omitempty"`
}

// Options は差し替えられる所。テストが待ち時間と場所を縮める。
type Options struct {
	Lock string
	// Slots は枠の本数（0 なら FGE_HEAVY_SLOTS、それも無ければ DefaultSlots）。
	Slots int
	// LongSlots は長い物が使える枠の本数（0 なら FGE_HEAVY_LONG_SLOTS、それも無ければ
	// DefaultLongSlots）。枠が 2 本以上なら Slots-1 までに詰める。
	LongSlots int
	// Long / Short は長い物か短い物かを名前の見分けより優先して決める。
	Long, Short bool
	Poll        time.Duration
	// childEnv は子へ足す環境変数（Hold が持っている枠を渡す）。
	childEnv []string
	Now      func() time.Time
	Err      io.Writer
}

func defaults(o Options) Options {
	if o.Lock == "" {
		o.Lock = os.Getenv("FGE_HEAVY_LOCK")
	}
	if o.Lock == "" {
		o.Lock = DefaultLock
	}
	if o.Slots == 0 {
		o.Slots, _ = strconv.Atoi(os.Getenv(SlotsEnv))
	}
	if o.Slots < 1 {
		o.Slots = DefaultSlots
	}
	if o.Slots > 8 {
		o.Slots = 8
	}
	if o.LongSlots == 0 {
		o.LongSlots, _ = strconv.Atoi(os.Getenv(LongSlotsEnv))
	}
	if o.LongSlots < 1 {
		o.LongSlots = DefaultLongSlots
	}
	o.LongSlots = clampLongSlots(o.LongSlots, o.Slots)
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

// clampLongSlots は長い物の枠を、短い物だけの枠が 1 本残る数までに詰める（枠が 1 本なら 1）。
func clampLongSlots(l, slots int) int {
	if slots <= 1 {
		return 1
	}
	return min(max(l, 1), slots-1)
}

func queueDir(lock string) string { return lock + ".queue" }
func reapDir(slot string) string  { return slot + ".reap" }

// slotPath は i 番目（0 から）の枠の置き場。枠 1 は 1 本だった頃の鍵そのもの。
func slotPath(lock string, i int) string {
	if i == 0 {
		return lock
	}
	return lock + "." + strconv.Itoa(i+1)
}

// Run は fge heavy の入口。args は heavy に渡った引数そのまま。
func Run(args []string, asJSON bool, o Options) int {
	o = defaults(o)
	if len(args) == 1 && args[0] == "--revision" {
		fmt.Println(Revision)
		return 0
	}
	if bin := delegateTarget(); bin != "" {
		if err := execDelegate(bin, args); err != nil {
			fmt.Fprintf(o.Err, "[heavy] %s へ委ねられませんでした (%v)・この版のまま流します\n", shortPath(bin), err)
		}
	}
	var cmd []string
	status, history := false, 0
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
		if a == "--history" || strings.HasPrefix(a, "--history=") {
			history = 24
			if h, err := strconv.Atoi(strings.TrimPrefix(a, "--history=")); err == nil && h > 0 {
				history = h
			}
			continue
		}
		if a == "--long" {
			o.Long = true
			continue
		}
		if a == "--short" {
			o.Short = true
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
	if history > 0 {
		return printHistory(os.Stdout, o, history)
	}
	if len(cmd) == 0 {
		fmt.Fprintln(o.Err, "使い方: fge heavy <コマンド...>          鍵を取ってコマンドを流す（CHECKD=0 が既定）")
		fmt.Fprintf(o.Err, "        fge heavy --long|--short <...>   長い物（枠 1〜%d）か短い物かを名前の見分けより優先\n", o.LongSlots)
		fmt.Fprintln(o.Err, "        fge heavy --status               枠ごとの持ち主と待っている列")
		fmt.Fprintln(o.Err, "        fge heavy --history[=時間]       直近 (既定 24 時間) の待ちと走りの合計 (<鍵>.log)")
		return 2
	}
	return Exec(cmd, "", o)
}

// ── 鍵の中身 ─────────────────────────────────────────────

// SlotState は枠 1 本の今。
type SlotState struct {
	Slot  int    `json:"slot"`
	Path  string `json:"path"`
	Held  bool   `json:"held"`
	Owner *Owner `json:"owner,omitempty"`
	Alive bool   `json:"alive"`
	Age   string `json:"age,omitempty"`
}

// Snapshot は --status の中身。Lock〜Age は枠 1（1 本だった頃の鍵）で、前の形を読む物のために残す。
type Snapshot struct {
	Lock  string      `json:"lock"`
	Held  bool        `json:"held"`
	Owner *Owner      `json:"owner,omitempty"`
	Alive bool        `json:"alive"`
	Age   string      `json:"age,omitempty"`
	Slots []SlotState `json:"slots"`
	// LongSlots は長い物が使える枠の本数（枠 1 から数えて）。これより後ろの枠は短い物だけ。
	LongSlots int     `json:"longSlots"`
	Waiting   []Owner `json:"waiting"`
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
func reap(o Options, slot string) bool {
	rd := reapDir(slot)
	if err := os.Mkdir(rd, 0o755); err != nil {
		if info, err := os.Stat(rd); err == nil && o.Now().Sub(info.ModTime()) > reapStale {
			os.Remove(rd)
		}
		return false
	}
	defer os.Remove(rd)
	stale, ow := isStale(slot, o.Now())
	if !stale {
		return false
	}
	if ow != nil {
		fmt.Fprintf(o.Err, "[heavy] 持ち主の居ない鍵を外します (%s pid %d: %s)\n",
			shortPath(ow.Workdir), ow.PID, ow.Command)
		os.Remove(filepath.Join(slot, ownerFile))
	} else {
		fmt.Fprintf(o.Err, "[heavy] 持ち主の書かれていない鍵 %s が %d 分を超えたので外します\n",
			slot, int(anonymousStale.Minutes()))
	}
	return os.Remove(slot) == nil
}

// ── 待っている列 ─────────────────────────────────────────

// waiting は列に並んでいる生きた heavy を、並んだ順に返す。死んだエントリはここで掃く。
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
		// WhyNot: 心拍の止まったエントリ（Ctrl-Z で止められた heavy）を飛ばすのは、先頭だけが
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
// 長い物か短い物かは o.Long / o.Short、どちらも無ければ desc の名前で決める。
// 途中で止められたら run は 130 を返すので、fn はそれを見て抜ける。
func Hold(desc, dir string, o Options, fn func(run Runner) int) int {
	o = defaults(o)
	// 鍵を持っている heavy の子の中で呼ばれたら、待たずにそのまま流す。
	if tok := os.Getenv(TokenEnv); tok != "" {
		for i := 0; i < o.Slots; i++ {
			if ow, err := readOwner(slotPath(o.Lock, i)); err == nil && ow.Token == tok {
				return fn(func(d string, cmd ...string) int {
					return runChild(cmd, d, tok, nil, o, nil, nil)
				})
			}
		}
	}
	if !o.Long && !o.Short && matchesWord(desc, noLockTarget) {
		fmt.Fprintln(o.Err, "[heavy] agent-eval は鍵を取らずに流します (claude -p の本数は fge agent-eval が自分の枠で守る)")
		return fn(func(d string, cmd ...string) int {
			return runChild(cmd, d, "", nil, o, nil, nil)
		})
	}
	wd := dir
	if wd == "" {
		wd, _ = os.Getwd()
	} else if abs, err := filepath.Abs(dir); err == nil {
		wd = abs
	}
	long := o.Long || (!o.Short && LooksLongIn(desc, wd))
	me := Owner{
		Workdir:   wd,
		PID:       os.Getpid(),
		Started:   processStarted(os.Getpid()),
		Command:   desc,
		Since:     o.Now(),
		Token:     newToken(),
		Long:      long,
		AnySlot:   !long,
		Slots:     o.Slots,
		LongSlots: o.LongSlots,
	}

	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, InterruptSignals...)
	defer signal.Stop(sigs)

	queued := me.Since
	slot, err := acquire(&me, sigs, o)
	if err != nil {
		if errors.Is(err, errInterrupted) {
			return 130
		}
		fmt.Fprintf(o.Err, "heavy: %v\n", err)
		return 2
	}
	code := 1
	defer func() {
		release(slot, me.Token)
		appendHistory(o.Lock, Record{Workdir: me.Workdir, PID: me.PID, Command: me.Command, Kind: kindOf(me),
			Slot: me.Slot, Queued: queued, Acquired: me.Since, Released: o.Now(), Code: code})
	}()
	if slot != o.Lock {
		// WhyNot: 枠 2 からを持つときに子へ枠の置き場を鍵として渡すのは、中で呼ばれた
		// 古い heavy（合言葉を FGE_HEAVY_LOCK の中だけで探す）が自分の鍵だと気づかず、
		// 枠 1 を待って 2 本ぶんを塞ぐため。
		o.childEnv = []string{"FGE_HEAVY_LOCK=" + slot}
	}
	var stopped atomic.Bool
	code = fn(func(d string, cmd ...string) int {
		return runChild(cmd, d, me.Token, func(child int) {
			me.ChildPID, me.ChildStarted = child, processStarted(child)
			writeJSON(filepath.Join(slot, ownerFile), me)
		}, o, sigs, &stopped)
	})
	return code
}

var errInterrupted = errors.New("待っている間に止められました")

// eligible はエントリ w が使える枠を、取りたい順に返す。長い物は枠 1〜L（L = w.LongSlots）を
// 前から取る。短い物は短い物だけの枠（枠 L+1 から先）を先に取り、長い物の枠は後ろから
// （枠 1 を最後に）回す。古い heavy のエントリは枠 1 だけ。L は 0.35.32 までのエントリでは 1 と読む。
func eligible(w Owner, n int) []int {
	if w.Slots > 0 && w.Slots < n {
		n = w.Slots
	}
	l := clampLongSlots(w.LongSlots, n)
	if !w.AnySlot {
		if !w.Long {
			return []int{0}
		}
		order := make([]int, 0, l)
		for i := 0; i < l; i++ {
			order = append(order, i)
		}
		return order
	}
	order := make([]int, 0, n)
	for i := l; i < n; i++ {
		order = append(order, i)
	}
	for i := l - 1; i >= 0; i-- {
		order = append(order, i)
	}
	return order
}

// pick は列の順に空いた枠を配ってみて、自分の取る枠を返す（無ければ -1）。
// 取る枠が無いとき、持ち主の居ないかもしれない枠のうち自分が見に行く番の物を reap に返す。
//
// WhyNot: 先頭だけが取る決まりを「列の順に配る」に広げるのは、枠 1 を待つ長い物が先頭に
// 居ても、後ろの短い物が空いた枠 2 で流れられるようにするため。前のエントリが使える枠を
// 後ろが先に取らないので、空いた瞬間に後から来た方が割り込むことは無い。
func pick(o Options, list []Owner, pid int) (slot int, reap []int) {
	free := make([]bool, o.Slots)
	for i := range free {
		_, err := os.Stat(slotPath(o.Lock, i))
		free[i] = errors.Is(err, os.ErrNotExist)
	}
	claimed := make([]bool, o.Slots)
	for _, w := range list {
		got := -1
		for _, i := range eligible(w, o.Slots) {
			if free[i] {
				got = i
				break
			}
		}
		if got >= 0 {
			if w.PID == pid {
				return got, nil
			}
			free[got] = false
			continue
		}
		for _, i := range eligible(w, o.Slots) {
			if !claimed[i] {
				claimed[i] = true
				if w.PID == pid {
					reap = append(reap, i)
				}
			}
		}
		if w.PID == pid {
			return -1, reap
		}
	}
	return -1, nil
}

// acquire は列に並び、自分の番に空いた枠を取って、その枠の置き場を返す。
func acquire(me *Owner, sigs chan os.Signal, o Options) (string, error) {
	if err := os.MkdirAll(queueDir(o.Lock), 0o777); err != nil {
		return "", fmt.Errorf("待ちの列 %s を作れません: %v", queueDir(o.Lock), err)
	}
	qp := queuePath(o, me.PID)
	if err := writeJSON(qp, me); err != nil {
		return "", fmt.Errorf("待ちの列に並べません: %v", err)
	}
	defer os.Remove(qp)

	start := o.Now()
	var lastNote time.Time
	for {
		list := waiting(o)
		if position(list, me.PID) == len(list) {
			// 自分のエントリが心拍切れで飛ばされていても、最後尾に並んでいるとみなす。
			list = append(list, *me)
		}
		slot, toReap := pick(o, list, me.PID)
		if slot >= 0 {
			path := slotPath(o.Lock, slot)
			if err := os.Mkdir(path, 0o755); err == nil {
				me.Since = o.Now()
				me.Slot = slot + 1
				if err := writeJSON(filepath.Join(path, ownerFile), me); err != nil {
					os.Remove(path)
					return "", fmt.Errorf("持ち主を書けません: %v", err)
				}
				if waited := o.Now().Sub(start); waited >= time.Second {
					fmt.Fprintf(o.Err, "[heavy] 枠 %d を取りました (待ち %s)\n", slot+1, roundDuration(waited))
				}
				return path, nil
			} else if !errors.Is(err, os.ErrExist) {
				return "", fmt.Errorf("鍵 %s を作れません: %v", path, err)
			}
			// 見てから作るまでの間に手書きの mkdir か古い heavy が取った。配り直す。
			continue
		}
		reaped := false
		for _, i := range toReap {
			reaped = reap(o, slotPath(o.Lock, i)) || reaped
		}
		if reaped {
			continue
		}
		if lastNote.IsZero() || o.Now().Sub(lastNote) >= 2*time.Minute {
			fmt.Fprintf(o.Err, "[heavy] 鍵を待っています (%s): %s・前に %d 本\n",
				kindLabel(*me), describeHolders(o, me), position(list, me.PID))
			lastNote = o.Now()
		}
		select {
		case <-sigs:
			return "", errInterrupted
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
func release(slot, token string) {
	ow, err := readOwner(slot)
	if err != nil || ow.Token != token {
		return
	}
	os.Remove(filepath.Join(slot, ownerFile))
	os.Remove(slot)
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
	c.Env = append(append(env, o.childEnv...), TokenEnv+"="+token)
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

// kindLabel はエントリが長い物か短い物か。どちらでもないエントリは 1 本だった頃の heavy。
func kindLabel(w Owner) string {
	switch {
	case w.Long && w.LongSlots > 1:
		return fmt.Sprintf("長い・枠 1〜%d", w.LongSlots)
	case w.Long:
		return "長い・枠 1 だけ"
	case w.AnySlot:
		return "短い"
	default:
		return "古い heavy・枠 1 だけ"
	}
}

func describeSlot(o Options, i int) string {
	path := slotPath(o.Lock, i)
	ow, err := readOwner(path)
	if err != nil {
		info, serr := os.Stat(path)
		if serr != nil {
			return "空き"
		}
		return fmt.Sprintf("持ち主の書かれていない鍵 (%s前から)", roundDuration(o.Now().Sub(info.ModTime())))
	}
	return fmt.Sprintf("%s pid %d が %s前から %s", shortPath(ow.Workdir), ow.PID,
		roundDuration(o.Now().Sub(ow.Since)), ow.Command)
}

// describeHolders は me が使える枠の持ち主を並べる（待っている間の 1 行）。
func describeHolders(o Options, me *Owner) string {
	var parts []string
	for _, i := range eligible(*me, o.Slots) {
		parts = append(parts, fmt.Sprintf("枠 %d: %s", i+1, describeSlot(o, i)))
	}
	sort.Strings(parts)
	return strings.Join(parts, " / ")
}

func snapshot(o Options) Snapshot {
	s := Snapshot{Lock: o.Lock, LongSlots: o.LongSlots, Waiting: waiting(o)}
	if s.Waiting == nil {
		s.Waiting = []Owner{}
	}
	for i := range s.Waiting {
		s.Waiting[i].Token = ""
	}
	for i := 0; i < o.Slots; i++ {
		st := SlotState{Slot: i + 1, Path: slotPath(o.Lock, i)}
		if info, err := os.Stat(st.Path); err == nil {
			st.Held = true
			if ow, err := readOwner(st.Path); err == nil {
				ow.Token = ""
				st.Owner = ow
				st.Alive = isAlive(ow)
				st.Age = roundDuration(o.Now().Sub(ow.Since))
			} else {
				st.Age = roundDuration(o.Now().Sub(info.ModTime()))
			}
		}
		s.Slots = append(s.Slots, st)
	}
	first := s.Slots[0]
	s.Held, s.Owner, s.Alive, s.Age = first.Held, first.Owner, first.Alive, first.Age
	return s
}

func printStatus(w io.Writer, o Options, asJSON bool) int {
	s := snapshot(o)
	if asJSON {
		data, _ := json.Marshal(s)
		fmt.Fprintln(w, string(data))
		return 0
	}
	longs := "枠 1 だけ"
	if s.LongSlots > 1 {
		longs = fmt.Sprintf("枠 1〜%d の %d 本まで", s.LongSlots, s.LongSlots)
	}
	fmt.Fprintf(w, "[heavy] 枠 %d 本 (%s で変える)・長い物 (render-all・動画・compare など) は%s (%s で変える)\n",
		len(s.Slots), SlotsEnv, longs, LongSlotsEnv)
	for _, st := range s.Slots {
		use := "長い物も短い物も"
		if st.Slot > s.LongSlots {
			use = "短い物だけ"
		}
		switch {
		case !st.Held:
			fmt.Fprintf(w, "[heavy] 枠 %d (%s): 空き (%s)\n", st.Slot, use, st.Path)
		case st.Owner == nil:
			fmt.Fprintf(w, "[heavy] 枠 %d (%s): 持ち主の書かれていない鍵 (手書きの mkdir)・%s前から\n", st.Slot, use, st.Age)
		default:
			state := "生きている"
			if !st.Alive {
				state = "死んでいる・次に待つ heavy が外す"
			}
			fmt.Fprintf(w, "[heavy] 枠 %d (%s): %s pid %d (%s・%s)・%s前から\n        %s\n", st.Slot, use,
				shortPath(st.Owner.Workdir), st.Owner.PID, kindLabel(*st.Owner), state, st.Age, st.Owner.Command)
		}
	}
	if len(s.Waiting) == 0 {
		fmt.Fprintln(w, "[heavy] 待ち: なし (手書きの until mkdir で待っている物は数えられません)")
		return 0
	}
	fmt.Fprintf(w, "[heavy] 待ち %d 本 (この順で、使える枠が空いた物から取る):\n", len(s.Waiting))
	for i, ow := range s.Waiting {
		fmt.Fprintf(w, "  %d. [%s] %s pid %d・%s前から: %s\n", i+1, kindLabel(ow), shortPath(ow.Workdir), ow.PID,
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
