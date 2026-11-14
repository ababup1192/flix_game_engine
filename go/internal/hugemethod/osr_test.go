package hugemethod

import (
	"strings"
	"testing"
)

const skipped = "7850 21640 %     3       $pkg$github$ababup1192$flix_game_engine.Render3d.ScenePlan.Def$sceneDrawsOf$1063480::staticApply @ 71 (1242 bytes)   COMPILE SKIPPED: stack not empty at OSR entry point (retry at different tier)\n"

func scanLog(t *testing.T, log string) []OSRSkip {
	t.Helper()
	got, err := ScanOSR(strings.NewReader(log))
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestOSRSkipIsReportedWithFlixName(t *testing.T) {
	got := scanLog(t, skipped)
	if len(got) != 1 || got[0].Name != "Render3d.ScenePlan.sceneDrawsOf" {
		t.Fatalf("got %+v", got)
	}
}

func TestOSRSkipAtSameSiteThatLaterCompilesIsNotReported(t *testing.T) {
	later := "8100 21700 %     4       $pkg$github$ababup1192$flix_game_engine.Render3d.ScenePlan.Def$sceneDrawsOf$1063480::staticApply @ 71 (1242 bytes)\n"
	if got := scanLog(t, skipped+later); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}

func TestOSRAtOtherBciDoesNotCountAsPassing(t *testing.T) {
	other := "8100 21700 %     4       $pkg$github$ababup1192$flix_game_engine.Render3d.ScenePlan.Def$sceneDrawsOf$1063480::staticApply @ 0 (1242 bytes)\n"
	if got := scanLog(t, skipped+other); len(got) != 1 {
		t.Fatalf("got %+v", got)
	}
}

func TestOSRSkipForJvmtiReasonIsIgnored(t *testing.T) {
	jvmti := "190 1124 %     4       Field.Def$instancesAt$1::staticApply @ 2 (51 bytes)   COMPILE SKIPPED: Jvmti state change invalidated dependencies\n"
	if got := scanLog(t, jvmti); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}

func TestOSRSkipInJavaLibraryIsIgnored(t *testing.T) {
	java := "190 1124 %     4       java.util.HashMap::putVal @ 2 (300 bytes)   COMPILE SKIPPED: stack not empty at OSR entry point (retry at different tier)\n"
	if got := scanLog(t, java); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}
