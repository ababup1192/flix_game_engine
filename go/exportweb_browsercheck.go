package main

import (
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
	if _, err := cdp.FindChrome(); err != nil {
		return "Chrome が見つからないので、ブラウザで wasm を読めるかは確かめていない（" + cdp.EnvChrome + " で Chrome を指せる）", nil
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", fmt.Errorf("確かめ用のサーバーを開けない: %v", err)
	}
	srv := &http.Server{Handler: http.FileServer(http.Dir(out)), ReadHeaderTimeout: 10 * time.Second}
	go srv.Serve(ln)
	defer srv.Close()
	// WhyNot: 既定の頁（WebGPU）だけを開かない — WebGL2 は WebGPU を使えないブラウザで頼る道で、書き出しの時に通さないと配った先で初めて落ちる。
	for _, query := range []string{"", "&backend=webgl2"} {
		url := fmt.Sprintf("http://%s/index.html?capture=%d%s", ln.Addr().String(), frames, query)
		if _, err := cdp.Capture(cdp.Options{URL: url, Wait: wait}); err != nil {
			if query == "" {
				return "", err
			}
			return "", fmt.Errorf("?backend=webgl2 の頁: %w", err)
		}
	}
	return "", nil
}
