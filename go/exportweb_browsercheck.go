package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
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
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, fmt.Errorf("確かめ用のサーバーを開けない: %v", err)
	}
	srv := &http.Server{Handler: http.FileServer(http.Dir(out)), ReadHeaderTimeout: 10 * time.Second}
	go srv.Serve(ln)
	defer srv.Close()
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
