package main

import (
	"fmt"
	"io"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 押した後の速さ（⑨'' の足し）: 回線を絞らずに頁を開いて「タッチして開始」を押し、押してから最初のコマまでと、押した反応が画面に出るまでを測る。
// 押した時の待ち（⑨''）が起きないゲームでも値が出る。Service Worker が付いた後の 2 回目の起動も同じ頁で測れる。

// webBootTimes は頁の window.fgeBootTimes（engine_web の fge-web.js が置く・performance.now の ms・まだなら -1）。
type webBootTimes struct {
	ReadyAt      float64 `json:"readyAt"`
	TapAt        float64 `json:"tapAt"`
	TapEventAt   float64 `json:"tapEventAt"`
	TapPaintAt   float64 `json:"tapPaintAt"`
	FirstFrameAt float64 `json:"firstFrameAt"`
}

// webTapTiming は 1 回の起動の速さ。
type webTapTiming struct {
	ReadySeconds      float64 // 開いてから「タッチして開始」が出るまで
	FirstFrameSeconds float64 // 押してから最初のコマまで
	TapPaintMs        float64 // 押してから、押した後の最初の rAF（波紋が描ける所）まで
}

func webTapTimingOf(t webBootTimes) webTapTiming {
	return webTapTiming{
		ReadySeconds:      t.ReadyAt / 1000,
		FirstFrameSeconds: (t.FirstFrameAt - t.TapEventAt) / 1000,
		TapPaintMs:        t.TapPaintAt - t.TapEventAt,
	}
}

// webTapTimingRow は表の 1 行（測れなかった時は Why に理由）。
type webTapTimingRow struct {
	Label  string
	Timing webTapTiming
	Why    string
}

// measureWebTapTiming は書き出し先 out を配り、cond の条件で 1 回起動して押し、速さを測る。warm なら Service Worker が付いた後にもう 1 回開いて測る
// （warm の結果は、Service Worker を持たない束では nil で whyNoWarm に理由）。
func measureWebTapTiming(out string, cond webMeasureConditions, warm bool, wait time.Duration) (cold webTapTiming, second *webTapTiming, whyNoWarm string, err error) {
	ln, closeServer, err := serveWebCheck(out)
	if err != nil {
		return cold, nil, "", err
	}
	defer closeServer()
	url := fmt.Sprintf("http://%s/index.html", ln.Addr().String())
	page, err := openReadyPage(url, "", cond, wait)
	if err != nil {
		return cold, nil, "", err
	}
	defer page.Close()
	if cold, err = tapAndReadTiming(page, wait); err != nil || !warm {
		return cold, nil, "", err
	}
	if b, err := loadWebBundle(out); err != nil || !b.ServiceWorker {
		return cold, nil, "束が Service Worker を持たない（project.json の web.serviceWorker が false）", nil
	}
	if err := waitServiceWorkerCached(page, wait); err != nil {
		return cold, nil, "", err
	}
	// WhyNot: 開き直した直後に前の頁の値を読まない — Navigate は新しい頁が始まる前に返ることがあり、前の頁の fgeSplash.ready が真のまま見える。
	if err := page.Eval(`(window.fgeOldPage = true, true)`, nil); err != nil {
		return cold, nil, "", err
	}
	if err := page.Navigate(url); err != nil {
		return cold, nil, "", err
	}
	if err := page.WaitFor(`!window.fgeOldPage && `+webSplashReadyProbe, wait); err != nil {
		return cold, nil, "", fmt.Errorf("2 回目の起動で「タッチして開始」が出ない: %v", err)
	}
	time.Sleep(cond.TapDelay)
	t, err := tapAndReadTiming(page, wait)
	if err != nil {
		return cold, nil, "", fmt.Errorf("2 回目の起動: %v", err)
	}
	return cold, &t, "", nil
}

// tapAndReadTiming は「タッチして開始」が出ている頁で押し、最初のコマを待って起動の時刻を読む。
func tapAndReadTiming(page *cdp.Page, wait time.Duration) (webTapTiming, error) {
	var has bool
	if err := page.Eval(`!!window.fgeBootTimes`, &has); err != nil {
		return webTapTiming{}, err
	}
	if !has {
		return webTapTiming{}, fmt.Errorf("頁が起動の時刻（window.fgeBootTimes）を持たない（前の engine の fge-web.js）")
	}
	if err := page.PressKey("Enter", 0); err != nil {
		return webTapTiming{}, err
	}
	if err := page.WaitFor(`fgeBootTimes.firstFrameAt >= 0 && fgeBootTimes.tapPaintAt >= 0`, wait); err != nil {
		return webTapTiming{}, fmt.Errorf("押した後に最初のコマが出ない: %v", err)
	}
	var t webBootTimes
	if err := page.Eval(`window.fgeBootTimes`, &t); err != nil {
		return webTapTiming{}, err
	}
	return webTapTimingOf(t), nil
}

// webSwCachedProbe は頁の Service Worker のキャッシュに入った物の数（Service Worker が頁を受け持っていなければ -1）。
const webSwCachedProbe = `(async () => {
  if (!navigator.serviceWorker || !navigator.serviceWorker.controller) return -1;
  var names = (await caches.keys()).filter(function (n) { return n.indexOf("fge-sw:") === 0; });
  var n = 0;
  for (var i = 0; i < names.length; i++) n += (await (await caches.open(names[i])).keys()).length;
  return n;
})()`

// waitServiceWorkerCached は Service Worker が頁を受け持ち、キャッシュに入る物が 1 秒増えなくなるまで待つ。
// WhyNot: 受け持った所で 2 回目を開かない — 頁が送った URL を Service Worker が取り終える前に開くと、半分はネットから取り、2 回目の姿にならない。
func waitServiceWorkerCached(page *cdp.Page, wait time.Duration) error {
	deadline := time.Now().Add(wait)
	last, since := -1, time.Now()
	for time.Now().Before(deadline) {
		var n int
		if err := page.Eval(webSwCachedProbe, &n); err != nil {
			return err
		}
		if n != last {
			last, since = n, time.Now()
		} else if n > 0 && time.Since(since) >= time.Second {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("%s 待っても Service Worker が頁を受け持ってキャッシュを入れ終えない（入った数 %d）", wait, last)
}

// measureWebTapTimingRows は cond の条件の起動（warm なら 2 回目の起動も）を測り、表の行にする（1 行目はいつも 1 回目の起動）。
func measureWebTapTimingRows(out string, cond webMeasureConditions, warm bool, wait time.Duration) []webTapTimingRow {
	label := cond.label()
	cold, second, whyNoWarm, err := measureWebTapTiming(out, cond, warm, wait)
	if err != nil {
		return []webTapTimingRow{{Label: label, Why: err.Error()}}
	}
	rows := []webTapTimingRow{{Label: label, Timing: cold}}
	if !warm {
		return rows
	}
	row := webTapTimingRow{Label: "2 回目の起動・" + label, Why: whyNoWarm}
	if second != nil {
		row.Timing = *second
	}
	return append(rows, row)
}

// writeWebTapTimingNotice は書き出しの時の押した後の速さ（1 行目）を 1 行で知らせる。
func writeWebTapTimingNotice(rows []webTapTimingRow) {
	if len(rows) == 0 {
		return
	}
	if r := rows[0]; r.Why != "" {
		ewLogf("知らせ: 押してから最初のコマまでを測れなかった: %s", r.Why)
	} else {
		ewLogf("押してから最初のコマまで %.2f 秒・押してから波紋まで %.0f ms（回線を絞らない・%s。知らせ）", r.Timing.FirstFrameSeconds, r.Timing.TapPaintMs, r.Label)
	}
}

// writeWebTapTimingRows は押した後の速さの表を書く（知らせ・門ではない）。
func writeWebTapTimingRows(w io.Writer, rows []webTapTimingRow) {
	fmt.Fprintln(w, "押した後の速さ（回線を絞らない・知らせ。門は書き出しの時の「すぐ押す・CPU 1 倍」の 4G の測りだけ）:")
	for _, r := range rows {
		if r.Why != "" {
			fmt.Fprintf(w, "  %s: 測れなかった（%s）\n", r.Label, r.Why)
			continue
		}
		fmt.Fprintf(w, "  %s: タッチして開始まで %.2f 秒・押してから最初のコマ %.2f 秒・押してから波紋まで %.0f ms\n",
			r.Label, r.Timing.ReadySeconds, r.Timing.FirstFrameSeconds, r.Timing.TapPaintMs)
	}
}
