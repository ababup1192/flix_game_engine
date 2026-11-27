package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseWebPerfArgsReadsFlags(t *testing.T) {
	o, err := parseWebPerfArgs([]string{"build/web", "--query", "?a=1", "--cpu", "4", "--settle", "5", "--uncapped", "--size", "640x360"})
	if err != nil {
		t.Fatal(err)
	}
	if o.Target != "build/web" || o.Query != "a=1" || o.CPU != 4 || o.Settle != 5*time.Second || !o.Uncapped || o.Width != 640 || o.Height != 360 {
		t.Fatalf("got %+v", o)
	}
}

func TestParseWebPerfArgsNeedsTarget(t *testing.T) {
	if _, err := parseWebPerfArgs([]string{"--cpu", "4"}); err == nil {
		t.Fatal("want error")
	}
}

func TestReadWasmNamesMapsFunctionIndex(t *testing.T) {
	// 区画 1（関数の名前）・長さ 7・個数 1・番号 300（LEB128 で ac 02）・名前 "ab"
	data := []byte{0x01, 0x07, 0x01, 0xac, 0x02, 0x02, 'a', 'b', 0x00}
	data[1] = byte(len(data) - 3)
	path := filepath.Join(t.TempDir(), "classes.names")
	if err := os.WriteFile(path, data[:len(data)-1], 0o644); err != nil {
		t.Fatal(err)
	}
	names := readWasmNames(path)
	if got := wasmNameOf(names, "wasm-function[300]"); got != "ab" {
		t.Fatalf("got %q", got)
	}
}

func TestWasmNameOfKeepsUnknownName(t *testing.T) {
	if got := wasmNameOf(map[int]string{}, "beginRenderPass"); got != "beginRenderPass" {
		t.Fatalf("got %q", got)
	}
}
