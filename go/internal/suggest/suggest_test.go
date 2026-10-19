package suggest

import "testing"

// 隣の 2 字の入れ替えは 1（engine_world/src/Suggest.flix と同じ）。
func TestDistanceCountsSwapAsOne(t *testing.T) {
	if got := Distance("tpa", "tap"); got != 1 {
		t.Fatalf("Distance(tpa, tap) = %d, want 1", got)
	}
}

// 3 字以下の名前は距離 1 まで: tpa から fps（距離 2）は案に出ない。
func TestShortNamesSuggestOnlyDistanceOne(t *testing.T) {
	got := Hint("tpa", []string{"start", "tap", "fps"})
	if want := "（もしかして: tap）"; got != want {
		t.Fatalf("Hint = %q, want %q", got, want)
	}
}

// 近い名前が無ければ、使える名前を 12 個まで並べる。
func TestHintListsKnownNamesWhenNothingIsNear(t *testing.T) {
	got := Hint("zzzz", []string{"left", "right"})
	if want := "（使える名前: left right）"; got != want {
		t.Fatalf("Hint = %q, want %q", got, want)
	}
}
