package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// webLoadCheckFrames は書き出した頁を何コマ目まで回せたら「読めた」とするか。
// WhyNot: 1 コマにしない — main の頭だけ通って、2 コマ目の描く所で落ちる形を見逃す。
const webLoadCheckFrames = 3

// webLoadCheckWait は頁が合図を出すまで待つ上限。FLIX_GE_WEB_CHECK_WAIT（秒）で替える（遅い機械向け）。
func webLoadCheckWait() time.Duration {
	if v := os.Getenv("FLIX_GE_WEB_CHECK_WAIT"); v != "" {
		if sec, err := strconv.ParseFloat(v, 64); err == nil && sec > 0 {
			return time.Duration(sec * float64(time.Second))
		}
	}
	return 90 * time.Second
}

// checkWebLoads は書き出し先 out を 127.0.0.1 の使い捨てのサーバーで配り、ヘッドレスの Chrome で `?capture=<n>` を開いて、
// wasm の compile・instantiate と main の最初の数コマで頁が止まらないかを見る。
// Chrome が無ければ確かめずに skipped へ理由を返す（err は nil）。
// WhyNot: TeaVM が穴 0 件で訳し終えた事を合格にしない — JSO の物を Object を受ける所へ渡す形は、TeaVM は通るのに
// ブラウザが wasm を読む所でモジュールごと落とし、配った先で真っ白になる。
func checkWebLoads(out string, frames int, wait time.Duration) (skipped string, err error) {
	skipped, _, err = checkWebLoadsRecording(out, frames, 0, wait)
	return skipped, err
}

// checkWebLoadsRecording は checkWebLoads と同じ確かめをし、titleFrames が正なら既定の頁を `?capture=<titleFrames>&usedAssets=1` で開いて、
// その間に使った素材の記録（window.fgeUsedAssets）も返す。頁が記録を持たない（古い engine の fge-web.js）・確かめを飛ばした時の used は nil。
func checkWebLoadsRecording(out string, frames, titleFrames int, wait time.Duration) (skipped string, used *webUsedAssets, err error) {
	if _, err := cdp.FindChrome(); err != nil {
		return "Chrome が見つからないので、ブラウザで wasm を読めるかは確かめていない（" + cdp.EnvChrome + " で Chrome を指せる）", nil, nil
	}
	ln, closeServer, err := serveWebCheck(out)
	if err != nil {
		return "", nil, err
	}
	defer closeServer()
	// WhyNot: 既定の頁（WebGPU）だけを開かない — WebGL2 は WebGPU を使えないブラウザで頼る道で、書き出しの時に通さないと配った先で初めて落ちる。
	// WhyNot: WebGL2 の頁でも記録しない — 記録は描き手より外（WebLayer）で取るので、同じ物がもう 1 回取れるだけで時間が延びる。
	for _, query := range []string{"", "&backend=webgl2"} {
		n, opt := frames, cdp.Options{Wait: wait}
		if query == "" && titleFrames > 0 {
			n, query, opt.Eval = max(frames, titleFrames), "&usedAssets=1", "window.fgeUsedAssets || null"
		}
		opt.URL = fmt.Sprintf("http://%s/index.html?capture=%d%s", ln.Addr().String(), n, query)
		res, err := cdp.Capture(opt)
		if err != nil {
			if query != "&backend=webgl2" {
				return "", nil, err
			}
			return "", nil, fmt.Errorf("?backend=webgl2 の頁: %w", err)
		}
		if opt.Eval != "" && len(res.Eval) > 0 && string(res.Eval) != "null" {
			var u webUsedAssets
			if err := json.Unmarshal(res.Eval, &u); err != nil {
				return "", nil, fmt.Errorf("頁の window.fgeUsedAssets の形が違う: %v", err)
			}
			used = &u
		}
	}
	return "", used, nil
}

// serveWebCheck は書き出し先 out を 127.0.0.1 の使い捨てのサーバーで配る。
func serveWebCheck(out string) (net.Listener, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, nil, fmt.Errorf("確かめ用のサーバーを開けない: %v", err)
	}
	srv := &http.Server{Handler: http.FileServer(http.Dir(out)), ReadHeaderTimeout: 10 * time.Second}
	go srv.Serve(ln)
	return ln, func() { srv.Close() }, nil
}

// webMissingWait は頁の window.fgeMissingWaits の 1 本（engine_web の fge-web.js が engine の待ちごとに積む）。
// Kind は pressed（押した所へ戻して待った）か stopped（控えの外で前の World のまま止まった）。
type webMissingWait struct {
	Reason     string   `json:"reason"`
	Kind       string   `json:"kind"`
	Names      []string `json:"names"`
	FirstFrame int      `json:"firstFrame"`
	Frames     int      `json:"frames"`
}

// webMissingSkip は頁の window.fgeMissingSkips の 1 本（届く前に描かずに・鳴らさずに進んだ名前）。
// Why は placeholder・skip（deferredPolicy か種類の既定）か gaveUp（wait の物を諦めた）。
type webMissingSkip struct {
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	Why   string `json:"why"`
	Frame int    `json:"frame"`
}

type webMissingReport struct {
	Waits []webMissingWait `json:"waits"`
	Skips []webMissingSkip `json:"skips"`
}

// checkWebMissingTitle は既定の頁を `?capture=<titleFrames>&net=4g` で開き、後回しが 4G の見積もりの秒まで届かない形で
// タイトルの間に engine が待ったか・描かずに進んだかを返す（頁が記録を持たない古い fge-web.js なら nil）。
// WhyNot: P3 の記録（usedAssets=1）の頁に net=4g を足さない — 届くのが遅れた分だけ「タイトルで使った」が増え、後回しの候補が変わる。
func checkWebMissingTitle(out string, titleFrames int, wait time.Duration) (*webMissingReport, error) {
	ln, closeServer, err := serveWebCheck(out)
	if err != nil {
		return nil, err
	}
	defer closeServer()
	res, err := cdp.Capture(cdp.Options{
		URL:  fmt.Sprintf("http://%s/index.html?capture=%d&net=4g", ln.Addr().String(), titleFrames),
		Wait: wait,
		Eval: "window.fgeMissingWaits ? { waits: window.fgeMissingWaits, skips: window.fgeMissingSkips } : null",
	})
	if err != nil {
		return nil, fmt.Errorf("?net=4g の頁: %w", err)
	}
	if len(res.Eval) == 0 || string(res.Eval) == "null" {
		return nil, nil
	}
	var r webMissingReport
	if err := json.Unmarshal(res.Eval, &r); err != nil {
		return nil, fmt.Errorf("頁の window.fgeMissingWaits の形が違う: %v", err)
	}
	return &r, nil
}

// writeWebMissingTitle は ?net=4g のタイトルの間の待ちと、wait の物を描かずに進んだ所を知らせる（止めない・初めは知らせだけ）。
func writeWebMissingTitle(w io.Writer, r *webMissingReport, frames int) {
	if r == nil {
		return
	}
	stopped, pressed := 0, 0
	for _, wt := range r.Waits {
		if wt.Kind == "stopped" {
			stopped++
			fmt.Fprintf(w, "  知らせ: 4G（?net=4g）のタイトルの %d コマで、届いていない %s を待って前の場面のまま %d コマ止まった（%d コマ目から）— タイトルで使う物は web.deferred から外すか、deferredPolicy で placeholder にする\n",
				frames, strings.Join(wt.Names, "・"), wt.Frames, wt.FirstFrame)
		} else {
			pressed++
		}
	}
	gaveUp := 0
	for _, sk := range r.Skips {
		if sk.Why == "gaveUp" {
			gaveUp++
			fmt.Fprintf(w, "  知らせ: 4G（?net=4g）のタイトルで、待つはずの %s を描かずに進んだ（%d コマ目・%s）\n", sk.Name, sk.Frame, sk.Why)
		}
	}
	fmt.Fprintf(w, "  4G（?net=4g）のタイトルの %d コマ: 止まった待ち %d 回・押した時の待ち %d 回・描かずに / 鳴らさずに進んだ名前 %d 個（うち待つはずの物 %d 個）\n",
		frames, stopped, pressed, len(r.Skips), gaveUp)
}
