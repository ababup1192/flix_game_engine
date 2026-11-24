package cmdhint

import "testing"

func TestBuildFor(t *testing.T) {
	cases := []struct {
		name    string
		goos    string
		hasMake bool
		task    string
		args    []string
		want    string
	}{
		{"Linux で make があれば make の形", "linux", true, "engine-upgrade", []string{"TO=1.2.3"}, "make engine-upgrade TO=1.2.3"},
		{"macOS で make があれば make の形", "darwin", true, "reference-update", nil, "make reference-update"},
		{"Windows では make があっても bin/fge の形", "windows", true, "test", nil, "bin/fge test"},
		{"make の無い Linux では bin/fge の形", "linux", false, "status", nil, "bin/fge status"},
		{"bin/fge で名前が 2 語に分かれる作業", "windows", false, "reference-update", nil, "bin/fge reference update"},
		{"K=V の引数は bin/fge の形にもそのまま付く", "windows", false, "api", []string{"Q=gradPolygon"}, "bin/fge api Q=gradPolygon"},
		{"bin/fge を通さず 1 行で打てる作業", "windows", false, "hooks", nil, "git config core.hooksPath bin/githooks"},
		{"bin/fge にまだ無い作業は macOS か Linux でと添える", "windows", false, "worktree-gc", nil, "make worktree-gc" + OutOfScope},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := buildFor(c.goos, c.hasMake, c.task, c.args...); got != c.want {
				t.Errorf("buildFor(%q, %v, %q, %v) = %q, want %q", c.goos, c.hasMake, c.task, c.args, got, c.want)
			}
		})
	}
}

func TestCommandForWindowsIgnoresMake(t *testing.T) {
	if got := CommandFor("windows", "reference-update"); got != "bin/fge reference update" {
		t.Errorf("got %q", got)
	}
}
