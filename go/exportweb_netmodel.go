package main

import (
	"bytes"
	"compress/gzip"
	"math"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// webStartupSize は「押して始める」の前に取る素材（後回しでない files・images・sounds）の本数と配る大きさの和、後回しの本数と大きさの和。
type webStartupSize struct {
	StartCount, DeferredCount int
	StartBytes, DeferredBytes int64
}

func webStartupSizeOf(sizes *webSizeTable, b *webBundle) webStartupSize {
	deferred := map[string]bool{}
	var s webStartupSize
	for _, e := range b.Deferred {
		deferred[e.Path] = true
		s.DeferredCount++
		s.DeferredBytes += e.Bytes
	}
	for _, rel := range b.copyList() {
		if deferred[rel] {
			continue
		}
		s.StartCount++
		s.StartBytes += sizes.assetRaw(b, rel)
	}
	return s
}

// webSizeTable は書き出し先の 1 本ずつの、素の大きさと回線に乗る量（webWireSize）。道は書き出し先から見た / 区切り。
// 同じ物を何度引いても読むのは 1 回。書き出し先の物を書き直したら作り直す（前の大きさを覚えたままになる）。
type webSizeTable struct {
	dir       string
	raw, wire map[string]int64
}

func newWebSizeTable(dir string) *webSizeTable {
	return &webSizeTable{dir: dir, raw: map[string]int64{}, wire: map[string]int64{}}
}

func (t *webSizeTable) path(rel string) string { return filepath.Join(t.dir, filepath.FromSlash(rel)) }

func (t *webSizeTable) rawOf(rel string) int64 {
	if n, ok := t.raw[rel]; ok {
		return n
	}
	n := fileSize(t.path(rel))
	t.raw[rel] = n
	return n
}

func (t *webSizeTable) wireOf(rel string) int64 {
	if n, ok := t.wire[rel]; ok {
		return n
	}
	n := webWireSize(t.path(rel))
	t.wire[rel] = n
	return n
}

func (t *webSizeTable) exists(rel string) bool { return fileExists(t.path(rel)) }

// assetRaw と assetWire は束の論理の道 rel の、配る形（assets/ の下）の大きさ。
func (t *webSizeTable) assetRaw(b *webBundle, rel string) int64 {
	return t.rawOf("assets/" + b.served(rel))
}

func (t *webSizeTable) assetWire(b *webBundle, rel string) int64 {
	return t.wireOf("assets/" + b.served(rel))
}

// 起動まで（遊べるまで）の見積もりの前提。測った 4G の回線（Lighthouse のモバイルと同じ 1.6 Mbps・往復 150 ms）に合わせる。
const (
	webStartupBitsPerSecond = 1.6e6
	// webStartupPreludeSeconds は index.html → version.txt → js → bundle.json の直列の往復（測った値）。
	webStartupPreludeSeconds = 1.5
	// webStartupTargetSeconds は web.startupBudget の既定の秒（「遊べるまで（すぐ押した時）」の上限）。
	webStartupTargetSeconds = 16.0
)

// webStartupBytes は頁が進みの棒を量で動かすための、起動の素材と wasm の大きさ（頁が数えるバイト数と回線に乗る量の見積もり）。
// wasm を brotli で配る時の Wasm は classes.wasm.br の大きさ（頁はそれを数える）。
type webStartupBytes struct {
	Assets     int64 `json:"assets"`
	AssetsWire int64 `json:"assetsWire"`
	Wasm       int64 `json:"wasm"`
	WasmWire   int64 `json:"wasmWire"`
}

// webArrival は後回しの 1 本が 1.6 Mbps で何秒目に届くかの見積もり。
type webArrival struct {
	Path    string
	Seconds float64
}

// webStartupEstimate は遊べるまでに回線に乗る量と秒数の見積もり、と後回しの届く時刻。
type webStartupEstimate struct {
	Boot     webStartupBytes
	PageWire int64
	Seconds  float64
	Deferred []webArrival
}

// webWireSize は置き場が gzip で配るとした時に回線に乗る量。もう詰めてある形（絵・音）は素の大きさ。
// WhyNot: 置き場の圧縮を brotli で見積もらない — 今の置き先（GitHub Pages）は gzip しか配らない。
func webWireSize(p string) int64 {
	switch strings.ToLower(path.Ext(p)) {
	case ".webp", ".jpg", ".jpeg", ".png", ".webm", ".opus", ".ogg", ".mp3", ".woff2", ".avif":
		return fileSize(p)
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return 0
	}
	gz, err := gzipBytes(data)
	if err != nil || int64(len(gz)) > int64(len(data)) {
		return int64(len(data))
	}
	return int64(len(gz))
}

func webSecondsFor(wire int64) float64 { return float64(wire) * 8 / webStartupBitsPerSecond }

// webStartupBytesOf は書き出し先の起動の素材（後回しでない物）と classes.wasm の大きさ。
func webStartupBytesOf(sizes *webSizeTable, b *webBundle) webStartupBytes {
	deferred := map[string]bool{}
	for _, e := range b.Deferred {
		deferred[e.Path] = true
	}
	var s webStartupBytes
	for _, rel := range b.copyList() {
		if deferred[rel] {
			continue
		}
		s.Assets += sizes.assetRaw(b, rel)
		s.AssetsWire += sizes.assetWire(b, rel)
	}
	s.Wasm, s.WasmWire = sizes.rawOf("classes.wasm"), sizes.wireOf("classes.wasm")
	if br := b.WasmBrotli; br != "" && sizes.exists(br) {
		s.Wasm, s.WasmWire = sizes.rawOf(br), sizes.rawOf(br)+sizes.wireOf(webBrotliDecoderFile)
	}
	return s
}

// webStartupEstimateOf は書き出し先の大きさの表から起動までの見積もりを作る。後回しは起動の後に、並べた順で回線を使い切るとして届く時刻を出す。
func webStartupEstimateOf(sizes *webSizeTable, b *webBundle) webStartupEstimate {
	s := webStartupEstimate{Boot: webStartupBytesOf(sizes, b)}
	for _, name := range []string{"index.html", "version.txt", "fge-web.js", "wasm-gc-runtime.js", "bundle.json"} {
		s.PageWire += sizes.wireOf(name)
	}
	s.Seconds = webStartupPreludeSeconds + webSecondsFor(s.Boot.AssetsWire+s.Boot.WasmWire+s.PageWire)
	for i, after := range webDeferredArrivals(sizes, b) {
		s.Deferred = append(s.Deferred, webArrival{Path: b.Deferred[i].Path, Seconds: s.Seconds + after})
	}
	return s
}

// webDeferredRoundTripSeconds は後回しの 1 本ごとに足す往復の秒（往復 150 ms を、頁が同時に取る 2 本で分け合う）。
// WhyNot: 帯域だけで積まない — 小さな絵が百本を超えるゲームは、帯域より本数の往復で詰まる。
const webDeferredRoundTripSeconds = 0.15 / 2

// webDeferredArrivals は後回しの 1 本ずつが、後回しを取り始めて（タッチして開始の頃）から 4G で届くまでの秒（取る順に積む）。
func webDeferredArrivals(sizes *webSizeTable, b *webBundle) []float64 {
	arrivals := make([]float64, len(b.Deferred))
	at := 0.0
	for i, e := range b.Deferred {
		at += webSecondsFor(sizes.assetWire(b, e.Path)) + webDeferredRoundTripSeconds
		arrivals[i] = at
	}
	return arrivals
}

// setWebArrivalSeconds は bundle.json の後回しの項目に arrivalSeconds を書く（頁の ?fge=4g がその秒まで渡さない）。
func setWebArrivalSeconds(sizes *webSizeTable, b *webBundle) {
	for i, at := range webDeferredArrivals(sizes, b) {
		b.Deferred[i].ArrivalSeconds = math.Round(at*1000) / 1000
	}
}

// webTapWait は「開いてすぐ押した時に、押してから最初の場面が動くまで」の 4G での見積もり。
// Group が空でなければ押した後のロゴが待つ group の最後が届く秒（Seconds）。空なら engine が待ちうる後回し（絵・wait の物・group を付けたフォント）の
// 最初が届く秒（Seconds・最初の場面が待つ物を使うなら少なくともこれだけ待つ）と最後が届く秒（Until・場面がどれを使うかで決まる上限）。待つ物が無ければ Count が 0。
type webTapWait struct {
	Group          []string
	Seconds, Until float64
	FirstPath      string
	Count          int
}

// webWaitsWhenMissing は後回しの 1 本が、届く前に使われた時に engine が待つ扱いか（fge-web.js の fgeDeferredPolicy と種類の既定を合わせる）。
func webWaitsWhenMissing(e webDeferredEntry, kind string) bool {
	switch kind {
	case "image":
		return e.OnMissing != "placeholder"
	case "font":
		return e.OnMissing == "wait" || (e.OnMissing == "" && e.Group != "")
	case "sound":
		return e.OnMissing == "wait"
	}
	return false
}

func webTapWaitOf(sizes *webSizeTable, b *webBundle, waitFor []string) webTapWait {
	arrivals := webDeferredArrivals(sizes, b)
	want := map[string]bool{}
	for _, g := range waitFor {
		want[g] = true
	}
	w := webTapWait{Group: waitFor}
	for i, e := range b.Deferred {
		if len(want) > 0 {
			if want[e.Group] {
				w.Count++
				w.Seconds = arrivals[i]
				w.Until = arrivals[i]
			}
			continue
		}
		if !webWaitsWhenMissing(e, webDeferredKindOf(e.Path, b)) {
			continue
		}
		if w.Count == 0 {
			w.Seconds, w.FirstPath = arrivals[i], e.Path
		}
		w.Count++
		w.Until = arrivals[i]
	}
	return w
}

// webBrotliToGzipRatio は wasm を brotli（11）にした大きさの、gzip にした大きさに対する割合（測った値: 1.4 MB / 2.4 MB）。
const webBrotliToGzipRatio = 0.58

func gzipBytes(data []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(data); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
