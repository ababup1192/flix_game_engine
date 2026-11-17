package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 書き出しの頁と同じ約束（?capture=<n> で n コマ目を描いたら fgeCaptureReady・止まったら fgeCaptureError）を守る小さな頁。
// wasm を compile させ、落ちたら fge-web.js と同じく fgeCaptureError へ置く。
const webCheckPage = `<!doctype html><canvas id=c width=4 height=4></canvas><script>
var n = parseInt(new URLSearchParams(location.search).get("capture") || "0", 10);
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
	stopOnGl = strings.Replace(stopOnGl, "<script>", `<script>if (new URLSearchParams(location.search).get("backend") === "webgl2") window.fgeCaptureError = "WebGL2 の道で止まった";`, 1)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(stopOnGl), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := checkWebLoads(dir, 3, 20*time.Second)
	if err == nil || !strings.Contains(err.Error(), "?backend=webgl2") {
		t.Fatalf("?backend=webgl2 の頁だけで止まる時も止まるはず: %v", err)
	}
}
