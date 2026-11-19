package flow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFlows(t *testing.T, files map[string]string) (string, []string) {
	t.Helper()
	dir := t.TempDir()
	var paths []string
	for name, body := range files {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	return dir, paths
}

func TestSettingMismatchNamesTheMissingLines(t *testing.T) {
	dir, paths := writeFlows(t, map[string]string{
		"end.flow":  "fps 30\nready off\nstart title\nrun part.flow\n",
		"part.flow": "tap confirm\n",
	})
	got := settingMismatches(paths)[filepath.Join(dir, "part.flow")]
	if len(got) != 1 || !strings.Contains(got[0].Why, "'fps 30' 'ready off'") {
		t.Errorf("%v", got)
	}
}

func TestSettingMismatchPassesWhenTheChildRepeatsTheSettings(t *testing.T) {
	_, paths := writeFlows(t, map[string]string{
		"end.flow":  "fps 30\nready off\nrun part.flow\n",
		"part.flow": "fps 30\nready off  # 親と同じ\ntap confirm\n",
	})
	if got := settingMismatches(paths); len(got) != 0 {
		t.Errorf("%v", got)
	}
}

func TestSettingMismatchFollowsNestedRuns(t *testing.T) {
	dir, paths := writeFlows(t, map[string]string{
		"end.flow":     "ready off\nrun part.flow\n",
		"part.flow":    "ready off\nrun to_room.flow\n",
		"to_room.flow": "tap confirm\n",
	})
	got := settingMismatches(paths)
	if len(got) != 1 || len(got[filepath.Join(dir, "to_room.flow")]) != 1 {
		t.Errorf("%v", got)
	}
}

func TestSettingMismatchSkipsParentsThatDisagree(t *testing.T) {
	_, paths := writeFlows(t, map[string]string{
		"a.flow":    "fps 30\nrun part.flow\n",
		"b.flow":    "fps 20\nrun part.flow\n",
		"part.flow": "tap confirm\n",
	})
	if got := settingMismatches(paths); len(got) != 0 {
		t.Errorf("%v", got)
	}
}

func TestSettingMismatchTreatsTheDefaultsAsWritten(t *testing.T) {
	_, paths := writeFlows(t, map[string]string{
		"end.flow":  "fps 60\nready on\nrun part.flow\n",
		"part.flow": "tap confirm\n",
	})
	if got := settingMismatches(paths); len(got) != 0 {
		t.Errorf("%v", got)
	}
}
