package px

import (
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

func colorCtx(ramp []pxlib.Key, keys ...string) *ctx {
	known := map[pxlib.Key]bool{}
	for _, k := range keys {
		known[pxlib.Key(k)] = true
	}
	return &ctx{Part: &partState{Ramp: ramp}, hasKey: func(k pxlib.Key) bool { return known[k] }}
}

// ランプのある部品で、色票にも同じ名前の色キー light があれば、どちらとも読めるので止める（黙ってランプの 3 段目に化けない）。
func TestLightIsRefusedWhenBothTheRampAndAColorKeyMatch(t *testing.T) {
	c := colorCtx([]pxlib.Key{"k0", "k1", "k2", "k3"}, "light")
	_, err := c.Color("light")
	if err == nil || !strings.Contains(err.Error(), "key:light") {
		t.Errorf("止めて key:light を案内するはず: %v", err)
	}
}

// key:名前 は色キーをそのまま指し、ramp[3] はランプの段を指す。
func TestKeyPrefixAndRampIndexAreUnambiguous(t *testing.T) {
	c := colorCtx([]pxlib.Key{"k0", "k1", "k2", "k3"}, "light")
	key, err1 := c.Color("key:light")
	ramp, err2 := c.Color("ramp[3]")
	if err1 != nil || err2 != nil || key != "light" || ramp != "k3" {
		t.Errorf("got %q %v / %q %v", key, err1, ramp, err2)
	}
}

// 同じ名前の色キーが無ければ、今まで通り light はランプの 3 段目。ランプの無い部品では色キーの light。
func TestLightKeepsItsMeaningWithoutAClash(t *testing.T) {
	onRamp, err1 := colorCtx([]pxlib.Key{"k0", "k1", "k2", "k3"}).Color("light")
	noRamp, err2 := colorCtx(nil, "light").Color("light")
	if err1 != nil || err2 != nil || onRamp != "k3" || noRamp != "light" {
		t.Errorf("got %q %v / %q %v", onRamp, err1, noRamp, err2)
	}
}

// key: の後ろの色キーが無ければ止める。
func TestKeyPrefixNeedsAKnownKey(t *testing.T) {
	if _, err := colorCtx(nil).Color("key:nope"); err == nil {
		t.Error("無い色キーは止めるはず")
	}
}
