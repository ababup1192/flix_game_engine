package main

import (
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
