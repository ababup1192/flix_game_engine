package tape

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 起動画面の門: 動画の取りを止められる簡易サーバーで、取っている途中・取り終えた後・失敗した後の頁を見る。

const videoBytes = 1 << 20

// videoServer は index.html を返し、video.mp4 は serve に任せるサーバーを立てて URL を返す。
func videoServer(t *testing.T, serve http.HandlerFunc) string {
	t.Helper()
	return pageServer(t, renderFile(t, otherPath, sampleStrip), serve)
}

// pageServer は page を返し、video.mp4 は serve に任せるサーバーを立てて URL を返す。
func pageServer(t *testing.T, page string, serve http.HandlerFunc) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(page))
	})
	mux.HandleFunc("/"+VideoFile, serve)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL + "/"
}

// steppedVideo は step から 1 つ受けるごとに parts の次の割合まで書く（最初の割合は待たずに書く）。length が偽なら Content-Length を付けない。
func steppedVideo(t *testing.T, length bool, parts []float64, step <-chan struct{}) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if length {
			w.Header().Set("Content-Length", strconv.Itoa(videoBytes))
		}
		w.Header().Set("Content-Type", "video/mp4")
		sent := 0
		for i, p := range parts {
			if i > 0 {
				select {
				case <-step:
				case <-r.Context().Done():
					return
				}
			}
			n := int(p*videoBytes) - sent
			_, _ = w.Write(make([]byte, n))
			w.(http.Flusher).Flush()
			sent += n
		}
	}
}

func openSplashPage(t *testing.T, url string) *cdp.Page {
	t.Helper()
	p := openTapePage(t)
	if err := p.Navigate(url); err != nil {
		t.Fatal(err)
	}
	return p
}

// gaugeLit は 2 コマ待ってから、ゲージの真ん中の横 1 列で白く塗られた画素の数を返す。
const gaugeLit = `new Promise(res => requestAnimationFrame(() => requestAnimationFrame(() => {
  const L = splash.layout, v = splash.view;
  const row = splash.el.getContext("2d").getImageData(Math.round(v.x + L.gaugeLeft * v.k), Math.round(v.y + (L.gaugeTop + L.gaugeH / 2) * v.k), Math.round(L.gaugeW * v.k), 1).data;
  let n = 0;
  for (let i = 0; i < row.length; i += 4) if (row[i] > 200) n++;
  res(n);
})))`

func litAt(t *testing.T, p *cdp.Page, ratio float64) int {
	t.Helper()
	if err := p.WaitFor("typeof splash !== 'undefined' && splash.ratio >= "+strconv.FormatFloat(ratio, 'f', 2, 64), 20*time.Second); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := p.Eval(gaugeLit, &n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestSplashGaugeGrowsAsVideoArrives(t *testing.T) {
	step := make(chan struct{})
	p := openSplashPage(t, videoServer(t, steppedVideo(t, true, []float64{.3, .7, 1}, step)))
	early := litAt(t, p, .29)
	step <- struct{}{}
	late := litAt(t, p, .69)
	close(step)
	if late <= early {
		t.Errorf("3 割の時に %d 画素・7 割の時に %d 画素（取れた分だけゲージが伸びるはず）", early, late)
	}
}

func TestSplashLeavesWhenVideoIsFetched(t *testing.T) {
	p := openSplashPage(t, videoServer(t, steppedVideo(t, true, []float64{1}, nil)))
	if err := p.WaitFor(`document.readyState === "complete" && !document.getElementById("splash")`, 20*time.Second); err != nil {
		t.Errorf("動画を取り終えても起動画面が残る: %v", err)
	}
}

func TestSplashGaugeHasNoRatioWithoutContentLength(t *testing.T) {
	step := make(chan struct{})
	t.Cleanup(func() { close(step) })
	p := openSplashPage(t, videoServer(t, steppedVideo(t, false, []float64{.3, 1}, step)))
	if err := p.WaitFor("typeof splash !== 'undefined' && splash.got > 0", 20*time.Second); err != nil {
		t.Fatal(err)
	}
	var ratio *float64
	if err := p.Eval("splash.ratio", &ratio); err != nil {
		t.Fatal(err)
	}
	if ratio != nil {
		t.Errorf("Content-Length が無いのに割合 %v を出す（左右に動くゲージのはず）", *ratio)
	}
}

func TestSplashFallsBackToVideoSrcWhenFetchFails(t *testing.T) {
	p := openSplashPage(t, videoServer(t, func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "gone", http.StatusInternalServerError)
	}))
	if err := p.WaitFor(`document.readyState === "complete" && !document.getElementById("splash")`, 20*time.Second); err != nil {
		t.Fatal(err)
	}
	var src string
	if err := p.Eval(`video.getAttribute("src")`, &src); err != nil {
		t.Fatal(err)
	}
	if src != VideoFile {
		t.Errorf("取りに失敗した後の video の src が %q（%s を直に指すはず）", src, VideoFile)
	}
}

func TestRenderEmbedsSplashMaterials(t *testing.T) {
	tp, err := Parse(readFile(t, otherPath))
	if err != nil {
		t.Fatal(err)
	}
	page, err := Render(tp, "abc", sampleStrip, Splash{Logo: "data:image/png;base64,TE9HTw==", Glyphs: "0041", CellH: 11})
	if err != nil {
		t.Fatal(err)
	}
	if want := `const SPLASH = {"logo":"data:image/png;base64,TE9HTw==","glyphs":"0041","cellH":11};`; !strings.Contains(string(page), want) {
		t.Errorf("頁に %s が無い", want)
	}
}

func TestSplashGaugeUsesVideoBytesWithoutContentLength(t *testing.T) {
	// Content-Length が無くても、頁に書いた動画の大きさ（videoBytes）で割合を出す。
	step := make(chan struct{})
	t.Cleanup(func() { close(step) })
	page := strings.Replace(renderFile(t, otherPath, sampleStrip), "const TAPE = {", "const TAPE = {\"videoBytes\":"+strconv.Itoa(videoBytes)+",", 1)
	p := openSplashPage(t, pageServer(t, page, steppedVideo(t, false, []float64{.3, 1}, step)))
	if err := p.WaitFor("typeof splash !== 'undefined' && splash.ratio >= 0.29", 20*time.Second); err != nil {
		t.Errorf("videoBytes があるのに割合が出ない: %v", err)
	}
}
