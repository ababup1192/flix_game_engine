package agenteval

// マシン全体の claude -p の同時本数の枠。
//
// agent-eval は heavy の鍵を取らない。claude -p は返事を待つ間ほとんど CPU を使わないので、
// 鍵を取ると 20 分ほど、ほかの作業場の check・test・リリースを止めてしまう。
// その代わり、いくつの作業場から流しても claude -p の本数がマシン全体で上限を超えないように、
// ここで枠を数える。枠は <dir>/<番号>.lock のファイルロック（flock）で、持ち主のプロセスが
// 死ねば OS がロックを外す。
//
// WhyNot: mkdir と持ち主の pid のファイルで数えないのは、死んだ持ち主の枠を片付ける間に
// 別の人が同じ番号を取り直すと、生きている枠まで消してしまうため（片付けの競合が無いロックにした）。
// Windows は flock が無いので枠を数えず、1 つの agent-eval の中の --jobs だけで本数を抑える。

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"
)

// slotsEnv は上限の本数を変える環境変数。既定は defaultSlots。
const slotsEnv = "FGE_AGENT_EVAL_SLOTS"

// WhyNot: 3 にするのは、Mac mini で同時に流す claude -p は 2〜3 本まで、という依頼主の決まりに合わせるため。
// --jobs は 1 つの agent-eval の中の本数で、こちらはいくつの作業場から流しても合わせた本数。
const defaultSlots = 3

// slotDir は枠を置くフォルダ。heavy の鍵（/tmp/fge-heavy.lock）と同じ場所に並べ、どの作業場からも同じ所を見る。
func slotDir() string {
	if d := os.Getenv("FGE_AGENT_EVAL_SLOT_DIR"); d != "" {
		return d
	}
	if runtime.GOOS == "windows" {
		return filepath.Join(os.TempDir(), "fge-agent-eval.slots")
	}
	return "/tmp/fge-agent-eval.slots"
}

func slotLimit() int {
	if n, err := strconv.Atoi(os.Getenv(slotsEnv)); err == nil && n > 0 {
		return n
	}
	return defaultSlots
}

// slots は 1 つの agent-eval の中で枠を取るときの約束（待っている間の知らせを 1 回だけ出す）。
type slots struct {
	dir      string
	limit    int
	poll     time.Duration
	log      io.Writer
	noteOnce sync.Once
}

func newSlots(log io.Writer) *slots {
	return &slots{dir: slotDir(), limit: slotLimit(), poll: 2 * time.Second, log: log}
}

// acquire は空いた枠を 1 つ取るまで待ち、返すための関数を返す。
func (s *slots) acquire() (func(), error) {
	if !slotsSupported {
		return func() {}, nil
	}
	if err := os.MkdirAll(s.dir, 0o777); err != nil {
		return nil, err
	}
	for {
		for k := 0; k < s.limit; k++ {
			release, ok, err := tryLock(filepath.Join(s.dir, strconv.Itoa(k)+".lock"))
			if err != nil {
				return nil, err
			}
			if ok {
				return release, nil
			}
		}
		s.noteOnce.Do(func() {
			fmt.Fprintf(s.log, "[agent-eval] claude の枠（マシン全体で %d 本・%s）が埋まっているので空くのを待ちます\n", s.limit, s.dir)
		})
		time.Sleep(s.poll)
	}
}
