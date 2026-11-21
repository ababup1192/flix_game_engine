package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 書き出しの頁と同じ約束（頁の旗 window.fgeDev.capture の n コマ目を描いたら fgeCaptureReady・止まったら fgeCaptureError）を守る小さな頁。
// 道具が旗を URL のクエリに付けたら止まる（Start の引数に混ざる形を見逃さない）。頁の旗の読み手を持つ頁と同じ印（fgePageSwitches）を持つ。
// wasm を compile させ、落ちたら fge-web.js と同じく fgeCaptureError へ置く。
const webCheckPage = `<!doctype html><canvas id=c width=4 height=4></canvas><script>function fgePageSwitches() {}</script><script>
var dev = window.fgeDev || {};
var n = dev.capture || 0;
if (location.search !== "") window.fgeCaptureError = "URL にクエリが付いた: " + location.search;
WebAssembly.compile(new Uint8Array(WASM)).then(function () {
  var gl = document.getElementById("c").getContext("webgl2");
  var frame = 0;
  (function tick() {
    gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
    if (++frame < n) { requestAnimationFrame(tick); return; }
    var buf = new Uint8Array(64); gl.readPixels(0, 0, 4, 4, gl.RGBA, gl.UNSIGNED_BYTE, buf);
    var s = ""; buf.forEach(function (b) { s += String.fromCharCode(b); });
    var shot = { width: 4, height: 4, rgba: btoa(s) };
    window.fgeCapture = function () { return shot; };
    window.fgeCaptureReady = true;
  })();
}, function (e) { window.fgeCaptureError = "wasm を読めません: " + e; });
</script>`

func writeWebCheckPage(t *testing.T, wasmBytes string) string {
	t.Helper()
	dir := t.TempDir()
	page := strings.Replace(webCheckPage, "WASM", wasmBytes, 1)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(page), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func skipWithoutChrome(t *testing.T) {
	t.Helper()
	if testing.Short() {
		t.Skip("-short")
	}
	if _, err := cdp.FindChrome(); err != nil {
		t.Skip(err)
	}
}

func TestCheckWebLoadsPassesWhenPageReachesFrame(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	if skipped, err := checkWebLoads(dir, 3, 20*time.Second); err != nil || skipped != "" {
		t.Fatalf("空の wasm を読めて 3 コマ回る頁は通るはず: skipped=%q err=%v", skipped, err)
	}
}

func TestCheckWebLoadsFailsWhenWasmDoesNotCompile(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0,1,255]")
	_, err := checkWebLoads(dir, 3, 20*time.Second)
	if err == nil || !strings.Contains(err.Error(), "wasm を読めません") {
		t.Fatalf("compile で落ちる頁は止まるはず: %v", err)
	}
}

func TestCheckWebLoadsFailsWhenOnlyWebGl2PageStops(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	stopOnGl := strings.Replace(webCheckPage, "WASM", "[0,97,115,109,1,0,0,0]", 1)
	stopOnGl = strings.Replace(stopOnGl, "<script>", `<script>if ((window.fgeDev || {}).backend === "webgl2") window.fgeCaptureError = "WebGL2 の道で止まった";`, 1)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(stopOnGl), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := checkWebLoads(dir, 3, 20*time.Second)
	if err == nil || !strings.Contains(err.Error(), "WebGL2 の頁") {
		t.Fatalf("WebGL2 の頁だけで止まる時も止まるはず: %v", err)
	}
}

func TestCheckWebLoadsRecordingReadsUsedAssetsFromTitlePage(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	page := strings.Replace(webCheckPage, "WASM", "[0,97,115,109,1,0,0,0]", 1)
	page = strings.Replace(page, "<script>", `<script>if ((window.fgeDev || {}).usedAssets === true) window.fgeUsedAssets = {frame: 5, texture: {title: 1}, sound: {}, file: {}, early: {}};`, 1)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(page), 0o644); err != nil {
		t.Fatal(err)
	}
	_, used, err := checkWebLoadsRecording(dir, 3, 5, 20*time.Second)
	if err != nil || used == nil || used.Texture["title"] != 1 {
		t.Fatalf("旗 usedAssets の頁の記録を受け取るはず: used=%+v err=%v", used, err)
	}
}

func TestCheckWebLoadsRecordingReturnsNilWhenPageHasNoRecord(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	if _, used, err := checkWebLoadsRecording(dir, 3, 5, 20*time.Second); err != nil || used != nil {
		t.Fatalf("記録を持たない頁（古い engine）の used は nil のはず: used=%+v err=%v", used, err)
	}
}

func TestWebMissingTitleCountsStoppedWaitsAndGaveUp(t *testing.T) {
	var b strings.Builder
	writeWebMissingTitle(&b, &webMissingReport{
		Waits: []webMissingWait{{Kind: "stopped", Names: []string{"bg"}, Frames: 30}, {Kind: "pressed", Names: []string{"bg2"}}},
		Skips: []webMissingSkip{{Name: "bg3", Why: "gaveUp"}, {Name: "se", Why: "skip"}},
	}, 120)
	if !strings.Contains(b.String(), "止まった待ち 1 回・押した時の待ち 1 回・描かずに / 鳴らさずに進んだ名前 2 個（うち待つはずの物 1 個）") {
		t.Errorf("数が違う:\n%s", b.String())
	}
}
