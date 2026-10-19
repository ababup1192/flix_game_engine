package compare

import "testing"

func TestBaseStepTurnsResidentOff(t *testing.T) {
	got := baseStep([]string{"make", "render-all"})
	if got[len(got)-1] != "HEADLESS_RESIDENT=0" {
		t.Fatalf("step = %q", got)
	}
}
