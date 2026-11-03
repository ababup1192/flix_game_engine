package flow

import "testing"

func TestMouseButtonSetAcceptsKnownNames(t *testing.T) {
	if why := mouseButtonSet("left,right,middle"); why != "" {
		t.Fatalf("left,right,middle should pass: %s", why)
	}
}

func TestMouseButtonSetAcceptsNone(t *testing.T) {
	if why := mouseButtonSet("-"); why != "" {
		t.Fatalf("- should pass: %s", why)
	}
}

func TestMouseButtonSetRejectsUnknownName(t *testing.T) {
	if why := mouseButtonSet("right,back"); why == "" {
		t.Fatal("back should be rejected")
	}
}
