package main

import (
	"fmt"
	"io"
	"math"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 押した後の測り（⑨''）: 既定の頁を ?net=4g で開き、「タッチして開始」を押してすぐタイトルで決定し、
// 押した時の待ちが明けるまでの秒を取る（開いてすぐ押した人の「押してから最初の場面が動くまで」）。

// webTapMeasureLimit を過ぎても待ちが明けなければ、この秒で打ち切って「これ以上」として扱う。
const webTapMeasureLimit = 40 * time.Second

// webTapKeyGapFrames は startKeys の 1 つずつの間に待つコマ数・webTapNoRecordFrames は押した時の待ちの記録が出ないと見切るまでのコマ数（5 秒）・
// webTapAfterWindow は待ちが明けた後に途中の待ちを見る秒。
const (
	webTapKeyGapFrames   = 6
	webTapNoRecordFrames = 300
	webTapAfterWindow    = 10
)

// webTapMeasure は押した後の測りの結果。Seconds は開始を押してから（4G の時計が始まってから）押した時の待ちが明けるまでの秒。
// NoRecord は押した時の待ちの記録が無かった（待たずに動いた・キーが合わず何も始まらなかったのどちらか）。
type webTapMeasure struct {
	Seconds      float64
	NoRecord     bool
	Capped       bool
	Stopped      int
	StoppedSecs  float64
	Placeholders []string
}

// webTapProbe は頁で評価する式。押した時刻（window.fgeTapMark）より後に始まった最初の pressed の待ちを、開いたままなら今の時刻で閉じて読む。
// WhyNot: 記録の seconds をそのまま使わない — 待ちの最初のコマから数えた秒で、開始を押してからタイトルで押すまでの間が入らない。閉じる前は 0 のまま。
const webTapProbe = `(() => {
  var m = window.fgeTapMark, now = performance.now(), at = fgeNetClock.at;
  var ws = (window.fgeMissingWaits || []).filter(function (w) { return w.startedAt >= m.at - 20; });
  var p = ws.filter(function (w) { return w.kind === "pressed"; })[0] || null;
  var res = { sinceTap: (now - m.at) / 1000, tapAfter: (m.at - at) / 1000, frames: fgeFrameNo - m.frame, state: "none", seconds: 0, stopped: 0, stoppedSecs: 0, placeholders: [] };
  if (p) {
    var open = p === fgeMissingWaitOpen;
    var end = open ? now : p.startedAt + p.seconds * 1000;
    res.state = open ? "open" : "closed";
    res.seconds = (end - at) / 1000;
    res.closedFor = open ? 0 : (now - end) / 1000;
  }
  ws.forEach(function (w) {
    if (w.kind !== "stopped") return;
    res.stopped++;
    res.stoppedSecs += (w === fgeMissingWaitOpen ? now - w.startedAt : w.seconds * 1000) / 1000;
  });
  (window.fgeMissingSkips || []).forEach(function (s) {
    if (s.kind === "texture" && s.why === "placeholder" && s.frame >= m.frame && s.frame <= m.frame + 180) res.placeholders.push(s.name);
  });
  return res;
})()`

type webTapProbeResult struct {
	SinceTap     float64  `json:"sinceTap"`
	Frames       int      `json:"frames"`
	TapAfter     float64  `json:"tapAfter"`
	State        string   `json:"state"`
	Seconds      float64  `json:"seconds"`
	ClosedFor    float64  `json:"closedFor"`
	Stopped      int      `json:"stopped"`
	StoppedSecs  float64  `json:"stoppedSecs"`
	Placeholders []string `json:"placeholders"`
}

// measureWebTapWait は書き出し先 out を手元のサーバーで配り、押した後の待ちを測る（Chrome が無ければ skipped に理由）。
func measureWebTapWait(out string, keys []string, lastArrival float64, wait time.Duration) (m webTapMeasure, skipped string, err error) {
	if _, err := cdp.FindChrome(); err != nil {
		return m, "Chrome が見つからない", nil
	}
	ln, closeServer, err := serveWebCheck(out)
	if err != nil {
		return m, "", err
	}
	defer closeServer()
	page, err := cdp.OpenPage(cdp.PageOptions{})
	if err != nil {
		return m, "", err
	}
	defer page.Close()
	if err := page.Navigate(fmt.Sprintf("http://%s/index.html?net=4g", ln.Addr().String())); err != nil {
		return m, "", err
	}
	if err := page.WaitFor(`typeof fgeSplash !== "undefined" && fgeSplash.ready === true && typeof fgeNetClock !== "undefined"`, wait); err != nil {
		return m, "", fmt.Errorf("「タッチして開始」が出ない: %v", err)
	}
	if err := page.PressKey("Enter", 0); err != nil {
		return m, "", err
	}
	// WhyNot: 決まった秒だけ置いてから押さない — ロゴの間のキーはロゴを飛ばすだけでゲームへ渡らず、headless は main の始まりが遅い。
	if err := page.WaitFor(`!fgeAfterTap.showing && fgeFrameNo > 30`, wait); err != nil {
		return m, "", fmt.Errorf("押した後にコマが進まない: %v", err)
	}
	if err := page.Eval(`(window.fgeTapMark = { at: performance.now(), frame: fgeFrameNo }, true)`, nil); err != nil {
		return m, "", err
	}
	for i, k := range keys {
		if k == "Space" {
			k = " "
		}
		// WhyNot: キーを同じコマに続けて送らない — 頁は 1 コマの間の押しをまとめて渡し、「下へ移ってから決める」が 1 コマに重なる。
		if i > 0 {
			if err := page.WaitFor(fmt.Sprintf("fgeFrameNo >= fgeTapMark.frame + %d", webTapKeyGapFrames*i), wait); err != nil {
				return m, "", fmt.Errorf("キーの間にコマが進まない: %v", err)
			}
		}
		if err := page.PressKey(k, 0); err != nil {
			return m, "", err
		}
	}
	var r webTapProbeResult
	deadline := time.Now().Add(webTapMeasureLimit + 20*time.Second)
	for {
		time.Sleep(100 * time.Millisecond)
		if err := page.Eval(webTapProbe, &r); err != nil {
			return m, "", err
		}
		// WhyNot: 待ちが明けてすぐ終えない — 明けた直後の途中の待ち（控えの外の待ち）も表に出したい。
		// WhyNot: 記録が出ないのを秒だけで見切らない — headless はコマが遅く、タイトルから場面へのフェードが実時間で数秒かかる。
		done := (r.State == "closed" && r.ClosedFor >= webTapAfterWindow) || webTapSawNoRecord(r)
		if done || time.Duration(r.SinceTap*float64(time.Second)) >= webTapMeasureLimit || time.Now().After(deadline) {
			break
		}
	}
	m, skipped = webTapOutcome(r, lastArrival)
	return m, skipped, nil
}

// webTapSawNoRecord は押した時の待ちの記録が出ないまま、見切ってよいだけコマと秒が進んだか。
func webTapSawNoRecord(r webTapProbeResult) bool {
	return r.State == "none" && r.Frames >= webTapNoRecordFrames && r.SinceTap >= 5
}

// webTapOutcome は測りの最後の読みを結果にする。記録が無いまま上限で切れたら skipped に理由（測れなかった）。
// WhyNot: 上限で切れた記録無しを「待たずに動いた」にしない — コマが進まなかった頁（止まった・極端に遅い）を 0 秒の測った値として門に入れる。
func webTapOutcome(r webTapProbeResult, lastArrival float64) (webTapMeasure, string) {
	// WhyNot: 待つ後回しが全部届いた後に押した記録無しを「待たずに動いた」にしない — headless が遅くタイトルで押すまでに届き切っただけで、開いてすぐ押す人の待ちは測れていない。
	if r.State == "none" && lastArrival > 0 && r.TapAfter >= lastArrival {
		return webTapMeasure{}, fmt.Sprintf("タイトルで押せたのが開始から %.1f 秒後で、待つ後回しの最後（%.1f 秒目）が届いた後だった（headless が遅い）ので測れなかった", r.TapAfter, lastArrival)
	}
	if r.State == "none" && !webTapSawNoRecord(r) {
		return webTapMeasure{}, fmt.Sprintf("上限まで待っても押した後のコマが %d 進まず測れなかった（%d コマ・%.0f 秒）", webTapNoRecordFrames, r.Frames, r.SinceTap)
	}
	return webTapMeasure{Seconds: r.Seconds, NoRecord: r.State == "none", Capped: r.State == "open",
		Stopped: r.Stopped, StoppedSecs: r.StoppedSecs, Placeholders: r.Placeholders}, ""
}

// webTapNeedsMeasure は押した後に engine が待ちうる後回しがあるか（無い束は測らない。最大 40 秒以上かかるため）。
func webTapNeedsMeasure(b *webBundle) bool {
	for _, e := range b.Deferred {
		if webWaitsWhenMissing(e, webDeferredKindOf(e.Path, b)) || e.Group != "" {
			return true
		}
	}
	return false
}

// webLastWaitingArrival は押した後に engine が待ちうる後回しのうち、最後に届く物の arrivalSeconds（開始を押してから）。
func webLastWaitingArrival(b *webBundle) float64 {
	last := 0.0
	for _, e := range b.Deferred {
		if webWaitsWhenMissing(e, webDeferredKindOf(e.Path, b)) || e.Group != "" {
			last = math.Max(last, e.ArrivalSeconds)
		}
	}
	return last
}

// writeWebTapMeasure は押した後の測りを表の後ろへ書く。
func writeWebTapMeasure(w io.Writer, m *webTapMeasure, skipped string) {
	switch {
	case skipped != "":
		fmt.Fprintf(w, "  押した後の測り（4G・開いてすぐ押す）: 飛ばした（%s）\n", skipped)
		return
	case m == nil:
		return
	case m.NoRecord:
		fmt.Fprintln(w, "  押した後の測り（4G・開いてすぐ押す）: 待ちの記録が無い（待たずに動いたか、startKeys がタイトルに合わず何も始まらなかった。見積もりを使う）")
	case m.Capped:
		fmt.Fprintf(w, "  押した後の測り（4G・開いてすぐ押す）: %.0f 秒たっても待ちが明けない\n", webTapMeasureLimit.Seconds())
	default:
		fmt.Fprintf(w, "  押した後の測り（4G・開いてすぐ押す）: 開始を押してから最初の場面が動くまで 約 %.1f 秒\n", m.Seconds)
	}
	if m.Stopped > 0 {
		fmt.Fprintf(w, "  知らせ: 押した後、場面が動いてから途中の待ち %d 回・%.1f 秒（4G のまね）\n", m.Stopped, m.StoppedSecs)
	}
	if len(m.Placeholders) > 0 {
		fmt.Fprintf(w, "  ★ 押してから 3 秒の間に placeholder で描かずに進んだ絵: %s\n", strings.Join(m.Placeholders, "・"))
	}
}

// tapSeconds は bundle.json に残す測った値（記録が無ければ nil）。
func (m *webTapMeasure) tapSeconds() *float64 {
	if m == nil || m.NoRecord {
		return nil
	}
	v := round1(m.Seconds)
	if m.Capped {
		v = math.Max(v, webTapMeasureLimit.Seconds())
	}
	return &v
}
