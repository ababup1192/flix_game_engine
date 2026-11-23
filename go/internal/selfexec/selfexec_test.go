package selfexec

import (
	"path/filepath"
	"testing"
)

func TestHeadlessIsOffWhenTheSubcommandIsMissing(t *testing.T) {
	SetLookup(func(string) bool { return false })
	if _, ok := Headless("E2e.play"); ok {
		t.Fatal("headless の無い fge で起こそうとした")
	}
}

func TestHeadlessRunsThisExecutableWithTheEntry(t *testing.T) {
	SetLookup(func(name string) bool { return name == "headless" })
	cmd, ok := Headless("E2e.play")
	if !ok {
		t.Fatal("headless のある fge で起こさなかった")
	}
	if !filepath.IsAbs(cmd.Path) || len(cmd.Args) != 3 || cmd.Args[1] != "headless" || cmd.Args[2] != "E2e.play" {
		t.Fatalf("%s %q", cmd.Path, cmd.Args)
	}
}
