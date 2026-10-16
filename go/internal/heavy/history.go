package heavy

// 記録: 鍵を返すたびに 1 本 1 行を <鍵>.log へ足す。どの待ちがどれだけあったかを、
// 各エージェントのログを漁らずに後から数えるための物。
//
// WhyNot: 書けなくても（/tmp が埋まった・権限）流すのは止めない。記録は見積もりのための物で、
// 鍵そのものの正しさには関わらないため。

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"
)

// historyLimit を超えたら .log.1 へ回して書き直す（1 行 300 バイト前後なので 1 万本余り）。
const historyLimit = 4 << 20

// Record は鍵を返した 1 本。
type Record struct {
	Workdir  string    `json:"workdir"`
	PID      int       `json:"pid"`
	Command  string    `json:"command"`
	Kind     string    `json:"kind"` // long / short
	Slot     int       `json:"slot"`
	Queued   time.Time `json:"queued"`
	Acquired time.Time `json:"acquired"`
	Released time.Time `json:"released"`
	Code     int       `json:"code"`
}

func historyPath(lock string) string { return lock + ".log" }

func kindOf(w Owner) string {
	if w.Long {
		return "long"
	}
	return "short"
}

// appendHistory は 1 行を足す。O_APPEND の 1 回の write は行が混ざらない。
func appendHistory(lock string, r Record) {
	if len(r.Command) > 300 {
		r.Command = r.Command[:300] + "…"
	}
	data, err := json.Marshal(r)
	if err != nil {
		return
	}
	path := historyPath(lock)
	if info, err := os.Stat(path); err == nil && info.Size() > historyLimit {
		os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o666)
	if err != nil {
		return
	}
	defer f.Close()
	f.Write(append(data, '\n'))
}

// readHistory は since より後に返した記録を古い順に返す。壊れた行は飛ばす。
func readHistory(lock string, since time.Time) []Record {
	var out []Record
	for _, path := range []string{historyPath(lock) + ".1", historyPath(lock)} {
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		for sc.Scan() {
			var r Record
			if json.Unmarshal(sc.Bytes(), &r) == nil && r.Released.After(since) {
				out = append(out, r)
			}
		}
		f.Close()
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Released.Before(out[j].Released) })
	return out
}

// printHistory は直近 hours 時間の待ちを、長い物と短い物に分けて数える（--history）。
func printHistory(w io.Writer, o Options, hours int) int {
	recs := readHistory(o.Lock, o.Now().Add(-time.Duration(hours)*time.Hour))
	if len(recs) == 0 {
		fmt.Fprintf(w, "[heavy] 直近 %d 時間の記録はありません (%s)\n", hours, historyPath(o.Lock))
		return 0
	}
	type sum struct {
		n          int
		wait, run  time.Duration
		maxWait    time.Duration
		maxCommand string
	}
	by := map[string]*sum{"long": {}, "short": {}}
	for _, r := range recs {
		s := by[r.Kind]
		if s == nil {
			s = &sum{}
			by[r.Kind] = s
		}
		wait, run := r.Acquired.Sub(r.Queued), r.Released.Sub(r.Acquired)
		s.n++
		s.wait += wait
		s.run += run
		if wait > s.maxWait {
			s.maxWait, s.maxCommand = wait, r.Command
		}
	}
	fmt.Fprintf(w, "[heavy] 直近 %d 時間に返した %d 本 (%s・0.35.30 より前の heavy は書かない)\n",
		hours, len(recs), historyPath(o.Lock))
	for _, k := range []string{"long", "short"} {
		s := by[k]
		if s.n == 0 {
			continue
		}
		label := map[string]string{"long": "長い物", "short": "短い物"}[k]
		fmt.Fprintf(w, "  %s %d 本: 待ち 合計 %s・平均 %s・最長 %s (%s) / 走り 合計 %s\n", label, s.n,
			roundDuration(s.wait), roundDuration(s.wait/time.Duration(s.n)), roundDuration(s.maxWait),
			trimCommand(s.maxCommand, 60), roundDuration(s.run))
	}
	return 0
}

func trimCommand(c string, n int) string {
	c = strings.Join(strings.Fields(c), " ")
	if r := []rune(c); len(r) > n {
		return string(r[:n]) + "…"
	}
	return c
}
