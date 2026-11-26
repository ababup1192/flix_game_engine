package main

import (
	"strings"
	"testing"
	"time"
)

func TestWebBenchArgsReadQueryWithoutQuestionMark(t *testing.T) {
	o, err := parseWebBenchArgs([]string{"out", "--query", "?n=20000&tex=16"})
	if err != nil || o.Query != "n=20000&tex=16" {
		t.Fatalf("got %q %v", o.Query, err)
	}
}

func TestWebBenchArgsReadWaitAndSize(t *testing.T) {
	o, err := parseWebBenchArgs([]string{"out", "--wait", "90", "--size", "1280x720"})
	if err != nil || o.Wait != 90*time.Second || o.Width != 1280 || o.Height != 720 {
		t.Fatalf("got %+v %v", o, err)
	}
}

func TestWebBenchArgsReadCPUThrottle(t *testing.T) {
	o, err := parseWebBenchArgs([]string{"out", "--cpu", "4"})
	if err != nil || o.CPU != 4 || cpuRateOf(o.CPU) != 4 || cpuRateOf(0) != 1 {
		t.Fatalf("got %+v %v", o, err)
	}
}

func TestWebBenchArgsRejectMissingFolder(t *testing.T) {
	if _, err := parseWebBenchArgs([]string{"--query", "n=1"}); err == nil {
		t.Fatal("want error")
	}
}

func TestWebBenchNeedsExportedIndex(t *testing.T) {
	var out, errOut strings.Builder
	if code := cmdWebBench(&out, &errOut, []string{t.TempDir()}); code != 2 || !strings.Contains(errOut.String(), "index.html") {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
}
