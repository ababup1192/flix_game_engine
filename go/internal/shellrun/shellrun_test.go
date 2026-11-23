package shellrun

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func host(goos string, env map[string]string, files []string, git string) Host {
	have := map[string]bool{}
	for _, f := range files {
		have[f] = true
	}
	return Host{
		GOOS:   goos,
		Getenv: func(k string) string { return env[k] },
		IsFile: func(p string) bool { return have[p] },
		LookPath: func(string) (string, error) {
			if git == "" {
				return "", errors.New("no git")
			}
			return git, nil
		},
	}
}

func TestFindBashIsEmptyOutsideWindows(t *testing.T) {
	got, err := host("linux", nil, nil, "").FindBash()
	if got != "" || err != nil {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestFindBashPrefersClaudeCodeGitBashPath(t *testing.T) {
	h := host("windows", map[string]string{GitBashEnv: `D:\tools\Git\bin\bash.exe`, "ProgramFiles": `C:\Program Files`},
		[]string{`D:\tools\Git\bin\bash.exe`, `C:\Program Files\Git\bin\bash.exe`}, "")
	if got, _ := h.FindBash(); got != `D:\tools\Git\bin\bash.exe` {
		t.Fatalf("got %q", got)
	}
}

func TestFindBashFailsWhenClaudeCodeGitBashPathIsMissing(t *testing.T) {
	h := host("windows", map[string]string{GitBashEnv: `D:\nope\bash.exe`, "ProgramFiles": `C:\Program Files`},
		[]string{`C:\Program Files\Git\bin\bash.exe`}, "")
	if _, err := h.FindBash(); err == nil {
		t.Fatal("want error")
	}
}

func TestFindBashUsesGitForWindowsBinNotUsrBin(t *testing.T) {
	h := host("windows", map[string]string{"ProgramFiles": `C:\Program Files`},
		[]string{`C:\Program Files\Git\usr\bin\bash.exe`, `C:\Program Files\Git\bin\bash.exe`}, "")
	if got, _ := h.FindBash(); got != `C:\Program Files\Git\bin\bash.exe` {
		t.Fatalf("got %q", got)
	}
}

func TestFindBashFollowsGitOnPathToItsBinBash(t *testing.T) {
	h := host("windows", nil, []string{`E:\PortableGit\bin\bash.exe`}, `E:\PortableGit\cmd\git.exe`)
	if got, _ := h.FindBash(); got != `E:\PortableGit\bin\bash.exe` {
		t.Fatalf("got %q", got)
	}
}

func TestFindBashDoesNotTakeSystem32Bash(t *testing.T) {
	h := host("windows", map[string]string{"SystemRoot": `C:\Windows`}, []string{`C:\Windows\System32\bash.exe`}, "")
	if _, err := h.FindBash(); !errors.Is(err, ErrNoBash) {
		t.Fatalf("got %v", err)
	}
}

func TestCommandHandsScriptToBashOnWindows(t *testing.T) {
	h := host("windows", map[string]string{"ProgramFiles": `C:\Program Files`}, []string{`C:\Program Files\Git\bin\bash.exe`}, "")
	cmd, err := h.Command("/x/engine/bin/headless-run", "SceneRender.all")
	if err != nil {
		t.Fatal(err)
	}
	if got := cmd.Args; len(got) != 3 || got[1] != "/x/engine/bin/headless-run" || got[2] != "SceneRender.all" {
		t.Fatalf("args %q", got)
	}
}

func TestCommandRunsScriptDirectlyOutsideWindows(t *testing.T) {
	cmd, err := host("darwin", nil, nil, "").Command("/x/bin/flix", "check")
	if err != nil {
		t.Fatal(err)
	}
	if got := cmd.Args; len(got) != 2 || got[0] != "/x/bin/flix" {
		t.Fatalf("args %q", got)
	}
}

func TestNativePathTurnsMsysDriveIntoWindowsDrive(t *testing.T) {
	if got := NativePath("windows", "/c/Users/me/flix.jar"); got != "C:/Users/me/flix.jar" {
		t.Fatalf("got %q", got)
	}
}

func TestNativePathKeepsWindowsFormAndOtherOS(t *testing.T) {
	for _, c := range []struct{ goos, in string }{{"windows", "C:/x/flix.jar"}, {"linux", "/c/x/flix.jar"}} {
		if got := NativePath(c.goos, c.in); got != c.in {
			t.Fatalf("%s %q → %q", c.goos, c.in, got)
		}
	}
}

func TestIsRunnableIgnoresExecBitOnlyOnWindows(t *testing.T) {
	p := filepath.Join(t.TempDir(), "flix")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !isRunnable("windows", p) || isRunnable("linux", p) {
		t.Fatalf("windows=%v linux=%v", isRunnable("windows", p), isRunnable("linux", p))
	}
}
