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

func TestSaveLoadPassesWhenTheGameDeclaresRoundTrip(t *testing.T) {
	c := &checker{vocab: Vocab{SaveLoad: true}}
	if _, why := c.line(0, []string{"saveload"}); why != "" {
		t.Fatalf("saveload should pass: %s", why)
	}
}

func TestSaveLoadIsRejectedWithoutRoundTrip(t *testing.T) {
	c := &checker{vocab: Vocab{}}
	if _, why := c.line(0, []string{"saveload"}); why == "" {
		t.Fatal("saveload without saveRoundTrip in the flow table should be rejected")
	}
}

func TestMouseButtonSetRejectsUnknownName(t *testing.T) {
	if why := mouseButtonSet("right,back"); why == "" {
		t.Fatal("back should be rejected")
	}
}
