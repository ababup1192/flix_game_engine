package main

import (
	"reflect"
	"testing"
)

func TestParseVerifyArgsSplitsAtDashDash(t *testing.T) {
	o, err := parseVerifyArgs([]string{"--keep", "--dir", "g", "--touch-doc=assets/a.json", "--", "render", "SHOT=title"})
	if err != nil {
		t.Fatal(err)
	}
	got := []any{o.Keep, o.Dir, o.TouchDoc, o.MakeArgs}
	want := []any{true, "g", "assets/a.json", []string{"render", "SHOT=title"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%v", got)
	}
}

func TestParseVerifyArgsNeedsMakeTarget(t *testing.T) {
	if _, err := parseVerifyArgs([]string{"--keep"}); err == nil {
		t.Fatal("誤りにならない")
	}
}

func TestParseVerifyArgsRejectsUnknownFlag(t *testing.T) {
	if _, err := parseVerifyArgs([]string{"render", "--", "x"}); err == nil {
		t.Fatal("誤りにならない")
	}
}
