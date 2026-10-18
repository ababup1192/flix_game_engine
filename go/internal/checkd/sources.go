package checkd

// repl の監視がソースの書き換えに追いつくのを待つ。
//
// flix repl は起動時に 1 度だけソースを全部読み、その後の書き換えは java の WatchService の
// 知らせでだけ取り込む (:check の度にディスクを読み直さない)。macOS の JDK の WatchService は
// 10 秒おきの見回り (PollingWatchService) なので、保存してすぐの :check は書き換え前の
// ソースを検査して、壊れたコードに exit=0 を返す (実測 2026-10-18: use を壊してすぐの
// make check が 2 回に 1 回「OK」・ログ空。CHECKD=0 は止まる)。
// 常駐は自分でソースの (mtime, 大きさ) を控え、変わったファイルが見回りに拾われる
// 時間が経つまで :check を送らない。

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// srcStamp は 1 ファイルの (mtime, 大きさ)。どちらかが変われば書き換えとみなす。
type srcStamp struct {
	mtime int64
	size  int64
}

// srcDirs は flix がコンパイルするソースの置き場。
//
// WhyNot: パッケージ全体を歩かないのは、ゲームの .claude/worktrees/ の下に別の
// 作業場の .flix が何千とあり、その書き換えのたびに無関係な待ちが入るため。
var srcDirs = []string{"src", "test"}

// catchUpRounds は「待っている間にまた書き換わった」を何度まで待ち直すか。
const catchUpRounds = 3

// watchLag は repl の監視が書き換えを拾うまでの最長の遅れ。
//
// WhyNot: hooks.json の調整値にしないのは、これが JDK の作り (macOS は 10 秒おきの
// 見回り・ほかの OS は OS の知らせで即時) で決まる値で、遊びの調整ではないため。
func watchLag() time.Duration {
	if runtime.GOOS == "darwin" {
		return 11 * time.Second // 見回り 10 秒 + 知らせが届くまでの 1 秒
	}
	return 1 * time.Second
}

// takeSources は src/ と test/ の .flix の (mtime, 大きさ) を集める。
func takeSources(pkg string) map[string]srcStamp {
	items := map[string]srcStamp{}
	for _, dir := range srcDirs {
		_ = filepath.Walk(filepath.Join(pkg, dir), func(path string, info os.FileInfo, err error) error {
			if err != nil || info == nil || info.IsDir() {
				return nil
			}
			if strings.HasSuffix(info.Name(), ".flix") {
				items[path] = srcStamp{mtime: info.ModTime().UnixNano(), size: info.Size()}
			}
			return nil
		})
	}
	return items
}

// watchWait は、repl が seen の時点のソースを知っているとして、now のソースを
// repl の監視が拾い終えるまでにあと何秒待つか。at は今の時刻、seenAt は seen を撮った時刻。
//
// 書き換えの時刻は mtime から読む。ただし mtime が seenAt より前のまま差し替わった
// ファイル (cp -p・アーカイブの展開) と、消えたファイルは、いつ変わったか分からない
// ので、今から lag をまるごと待つ。
func watchWait(seen, now map[string]srcStamp, seenAt, at time.Time, lag time.Duration) time.Duration {
	var newest time.Time
	for p, s := range now {
		if old, ok := seen[p]; ok && old == s {
			continue
		}
		t := time.Unix(0, s.mtime)
		if !t.After(seenAt) {
			return lag
		}
		if t.After(newest) {
			newest = t
		}
	}
	for p := range seen {
		if _, ok := now[p]; !ok {
			return lag
		}
	}
	if newest.IsZero() {
		return 0
	}
	w := lag - at.Sub(newest)
	switch {
	case w < 0:
		return 0
	case w > lag: // mtime が未来 (時計のずれ)。待ちすぎないよう lag で頭打ち
		return lag
	}
	return w
}

// catchUp は repl の監視が今のソースに追いつくまで待つ。追いついたら true。
// 待つ間も書き換えが続いて追いつけなければ false (= 常駐では確かめられない)。
func (d *daemon) catchUp() bool {
	lag := watchLag()
	for i := 0; i < catchUpRounds; i++ {
		at := time.Now()
		now := takeSources(d.pkg)
		w := watchWait(d.seen, now, d.seenAt, at, lag)
		if w == 0 {
			d.seen, d.seenAt = now, at
			return true
		}
		d.log(fmt.Sprintf("ソースの書き換えを repl の監視が拾うまで %.1fs 待つ", w.Seconds()))
		time.Sleep(w)
		// 待つ間に変わっていなければ、書き換えはどれも at より前に済んでいて、
		// at から lag 経った今は拾われている。
		if sameSources(takeSources(d.pkg), now) {
			d.seen, d.seenAt = now, at
			return true
		}
	}
	return false
}

func sameSources(a, b map[string]srcStamp) bool {
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
