package agenteval

// マシン全体の claude -p の同時本数の枠。
//
// agent-eval は heavy の鍵を取らない。claude -p は返事を待つ間ほとんど CPU を使わないので、
// 鍵を取ると 20 分ほど、ほかの作業場の check・test・リリースを止めてしまう。
// その代わり、いくつの作業場から流しても claude -p の本数がマシン全体で上限を超えないように、
// ここで枠を数える。枠は <dir>/<番号> のフォルダ（mkdir が成功した方が取る）で、
// 中の owner.json に持ち主の pid を書く。持ち主が死んで残った枠は、次に枠を探した人が片付ける。

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
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

type slotOwner struct {
	PID     int    `json:"pid"`
	Started string `json:"started"`
	Task    string `json:"task"`
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
func (s *slots) acquire(task string) (func(), error) {
	if err := os.MkdirAll(s.dir, 0o777); err != nil {
		return nil, err
	}
	me := slotOwner{PID: os.Getpid(), Started: heavy.ProcessStarted(os.Getpid()), Task: task}
	for {
		for k := 0; k < s.limit; k++ {
			p := filepath.Join(s.dir, strconv.Itoa(k))
			if os.Mkdir(p, 0o777) == nil {
				data, _ := json.Marshal(me)
				if err := os.WriteFile(filepath.Join(p, "owner.json"), data, 0o666); err != nil {
					os.RemoveAll(p)
					return nil, err
				}
				return func() { os.RemoveAll(p) }, nil
			}
			s.reapIfDead(p)
		}
		s.noteOnce.Do(func() {
			fmt.Fprintf(s.log, "[agent-eval] claude の枠（マシン全体で %d 本・%s）が埋まっているので空くのを待ちます\n", s.limit, s.dir)
		})
		time.Sleep(s.poll)
	}
}

// reapIfDead は持ち主の居ない枠を片付ける。owner.json がまだ書かれていない（取った直後の）枠は触らない。
func (s *slots) reapIfDead(p string) {
	data, err := os.ReadFile(filepath.Join(p, "owner.json"))
	if err != nil {
		if info, statErr := os.Stat(p); statErr == nil && time.Since(info.ModTime()) > time.Minute {
			os.RemoveAll(p) // 書きかけのまま 1 分経った = 書く前に落ちた
		}
		return
	}
	var ow slotOwner
	if json.Unmarshal(data, &ow) != nil || !heavy.ProcessAlive(ow.PID, ow.Started) {
		os.RemoveAll(p)
	}
}
