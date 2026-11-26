package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestParseSizeAcceptsWxH(t *testing.T) {
	w, h, ok := parseSize("640x360")
	if !ok || w != 640 || h != 360 {
		t.Fatalf("got %d %d %v", w, h, ok)
	}
}

func TestParseSizeRejectsMissingHeight(t *testing.T) {
	if _, _, ok := parseSize("640"); ok {
		t.Fatal("want reject")
	}
}

func TestWebCaptureNeedsURLAndOutput(t *testing.T) {
	var out, errOut strings.Builder
	if code := cmdWebCapture(&out, &errOut, []string{"http://127.0.0.1:1/"}); code != 2 {
		t.Fatalf("code = %d", code)
	}
}

func TestWebCaptureRejectsUnknownFlag(t *testing.T) {
	var out, errOut strings.Builder
	if code := cmdWebCapture(&out, &errOut, []string{"u", "o.png", "--fast"}); code != 2 {
		t.Fatalf("code = %d", code)
	}
}

func TestWebCaptureDevGivesOldKeysToOldEnginePage(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	old := strings.Replace(strings.Replace(webCheckPage, "WASM", "[0,97,115,109,1,0,0,0]", 1), "function fgePageSwitches() {}", "", 1)
	old = strings.Replace(old, "var n = dev.capture || 0;", `var n = parseInt(new URLSearchParams(location.search).get("capture") || "0", 10); if (!(n > 0)) window.fgeCaptureError = "capture が届かない";`, 1)
	old = strings.Replace(old, `if (location.search !== "") window.fgeCaptureError = "URL にクエリが付いた: " + location.search;`, "", 1)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(old), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if code := cmdWebCapture(&out, &errOut, []string{"index.html", filepath.Join(t.TempDir(), "o.png"), "--dir", dir, "--dev", "capture:3", "--wait", "20"}); code != 0 {
		t.Fatalf("前の engine の頁（URL の capture を読む）にも --dev の旗が届くはず: %d %s", code, errOut.String())
	}
}

func TestSplitAllowedConsoleKeepsUnmatchedLines(t *testing.T) {
	bad, allowed := splitAllowedConsole(
		[]string{"WebFs fail-open: a を書かないに替えました — b", "java.lang.NoSuchMethodError: x"},
		[]*regexp.Regexp{regexp.MustCompile(` fail-open: `)})
	if len(bad) != 1 || bad[0] != "java.lang.NoSuchMethodError: x" || len(allowed) != 1 {
		t.Fatalf("bad=%v allowed=%v", bad, allowed)
	}
}

func TestWebCaptureConsoleAllowNeedsConsoleErrors(t *testing.T) {
	var out, errOut strings.Builder
	if code := cmdWebCapture(&out, &errOut, []string{"u", "o.png", "--console-allow", "x"}); code != 2 {
		t.Fatalf("code = %d", code)
	}
}

func TestWebCaptureConsoleErrorsFailsOnUncaughtRejection(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	page := strings.Replace(webCheckPage, "WASM", "[0,97,115,109,1,0,0,0]", 1)
	page = strings.Replace(page, "var frame = 0;", `var frame = 0; Promise.reject(new Error("ClassNotFound y"));`, 1)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(page), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	code := cmdWebCapture(&out, &errOut, []string{"index.html", filepath.Join(t.TempDir(), "o.png"), "--dir", dir, "--dev", "capture:3", "--wait", "20", "--console-errors"})
	if code != 1 || !strings.Contains(out.String(), "unhandledrejection") {
		t.Fatalf("拾われなかった reject は exit 1 で行を出すはず: %d %s", code, out.String())
	}
}

func TestWebCaptureConsoleAllowSkipsMatchedLine(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	page := strings.Replace(webCheckPage, "WASM", "[0,97,115,109,1,0,0,0]", 1)
	page = strings.Replace(page, "var frame = 0;", `var frame = 0; console.error("WebFs fail-open: a を書かないに替えました");`, 1)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(page), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if code := cmdWebCapture(&out, &errOut, []string{"index.html", filepath.Join(t.TempDir(), "o.png"), "--dir", dir, "--dev", "capture:3", "--wait", "20", "--console-errors", "--console-allow", "^WebFs fail-open: "}); code != 0 {
		t.Fatalf("--console-allow に当たる行だけなら通るはず: %d %s", code, out.String())
	}
}

func TestWebCaptureConsoleErrorsPassesCleanPage(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	var out, errOut strings.Builder
	if code := cmdWebCapture(&out, &errOut, []string{"index.html", filepath.Join(t.TempDir(), "o.png"), "--dir", dir, "--dev", "capture:3", "--wait", "20", "--console-errors"}); code != 0 {
		t.Fatalf("console.error を出さない頁は通るはず: %d %s", code, errOut.String())
	}
}

func TestWebCaptureConsoleErrorsFailsOnConsoleError(t *testing.T) {
	skipWithoutChrome(t)
	dir := writeWebCheckPage(t, "[0,97,115,109,1,0,0,0]")
	page := strings.Replace(webCheckPage, "WASM", "[0,97,115,109,1,0,0,0]", 1)
	page = strings.Replace(page, "var frame = 0;", `var frame = 0; console.error("java.lang.NoSuchMethodError: x");`, 1)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(page), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	code := cmdWebCapture(&out, &errOut, []string{"index.html", filepath.Join(t.TempDir(), "o.png"), "--dir", dir, "--dev", "capture:3", "--wait", "20", "--console-errors"})
	if code != 1 || !strings.Contains(out.String(), "NoSuchMethodError") {
		t.Fatalf("console.error を出した頁は exit 1 で行を出すはず: %d %s", code, out.String())
	}
}
