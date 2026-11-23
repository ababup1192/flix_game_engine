package main

import "testing"

func TestLookupArgsAcceptsTheMakeStyleQ(t *testing.T) {
	if _, q := lookupArgs([]string{"Q=gradPolygon"}); q != "gradPolygon" {
		t.Fatalf("q=%q", q)
	}
}

func TestLookupArgsJoinsPlainWords(t *testing.T) {
	if engine, q := lookupArgs([]string{"--engine", "/e", "draw", "text"}); engine != "/e" || q != "draw text" {
		t.Fatalf("engine=%q q=%q", engine, q)
	}
}
