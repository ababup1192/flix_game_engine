package claudeopen

import (
	"errors"
	"net/url"
	"strings"
	"testing"
)

func TestBuildURLCarriesCwdAndPrompt(t *testing.T) {
	link, err := BuildURL("/home/a/flix-games/tide pool", "make run で動くか確かめて")
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(link)
	if err != nil || u.Scheme != "claude-cli" || u.Host != "open" {
		t.Fatalf("link=%s err=%v", link, err)
	}
	q := u.Query()
	if q.Get("cwd") != "/home/a/flix-games/tide pool" || q.Get("q") != "make run で動くか確かめて" {
		t.Fatalf("q=%v", q)
	}
}

func TestBuildURLEncodesSpacesAsPercent20(t *testing.T) {
	link, _ := BuildURL("/a b", "c d")
	if strings.Contains(link, "+") || !strings.Contains(link, "c%20d") {
		t.Fatalf("link=%s", link)
	}
}

func TestBuildURLLeavesOutAnEmptyPrompt(t *testing.T) {
	link, _ := BuildURL("/a", "")
	if strings.Contains(link, "q=") {
		t.Fatalf("link=%s", link)
	}
}

func TestBuildURLRefusesARelativeCwd(t *testing.T) {
	if _, err := BuildURL("games/tide", ""); err == nil {
		t.Fatal("相対パスを受けた")
	}
}

func TestBuildURLRefusesAPromptOver5000Characters(t *testing.T) {
	if _, err := BuildURL("/a", strings.Repeat("字", MaxPromptRunes+1)); err == nil {
		t.Fatal("5,000 字を超える文を受けた")
	}
}

func TestBuildURLAcceptsAPromptOfExactly5000Characters(t *testing.T) {
	if _, err := BuildURL("/a", strings.Repeat("字", MaxPromptRunes)); err != nil {
		t.Fatal(err)
	}
}

func TestOpenCommandPerOS(t *testing.T) {
	cases := map[string]string{
		"darwin":  "open claude-cli://x",
		"linux":   "xdg-open claude-cli://x",
		"windows": `cmd /c start  claude-cli://x`,
	}
	for goos, want := range cases {
		name, args, ok := OpenCommand(goos, "claude-cli://x")
		if got := name + " " + strings.Join(args, " "); !ok || got != want {
			t.Errorf("%s: %q (want %q)", goos, got, want)
		}
	}
}

func TestOpenCommandPutsAnEmptyTitleBeforeTheURLOnWindows(t *testing.T) {
	_, args, _ := OpenCommand("windows", "claude-cli://x")
	if len(args) != 4 || args[2] != "" || args[3] != "claude-cli://x" {
		t.Fatalf("args=%q", args)
	}
}

func TestOpenCommandRefusesAnUnknownOS(t *testing.T) {
	if _, _, ok := OpenCommand("plan9", "x"); ok {
		t.Fatal("知らない OS を受けた")
	}
}

func TestCopyLineQuotesThePrompt(t *testing.T) {
	got := CopyLine("/home/a/tide", "it's ok")
	if got != `cd /home/a/tide && claude 'it'\''s ok'` {
		t.Fatalf("got %s", got)
	}
}

func TestRunPrintsACopyLineWhenTheOSCannotOpen(t *testing.T) {
	dir := t.TempDir()
	d := Deps{GOOS: "linux", Run: func(string, ...string) error { return errors.New("exit status 3") }}
	var out, errOut strings.Builder

	code := Run(&out, &errOut, []string{dir, "--prompt", "続けて"}, d)
	if code != 0 || !strings.Contains(out.String(), CopyLine(dir, "続けて")) {
		t.Fatalf("code=%d out=%s", code, out.String())
	}
}

func TestRunHandsTheLinkToXdgOpenOnLinux(t *testing.T) {
	dir := t.TempDir()
	var called string
	d := Deps{GOOS: "linux", Run: func(name string, args ...string) error {
		called = name + " " + strings.Join(args, " ")
		return nil
	}}
	var out, errOut strings.Builder

	if code := Run(&out, &errOut, []string{dir}, d); code != 0 || !strings.HasPrefix(called, "xdg-open claude-cli://open?cwd=") {
		t.Fatalf("code=%d called=%s", code, called)
	}
}

func TestRunRefusesAMissingFolder(t *testing.T) {
	d := Deps{GOOS: "linux", Run: func(string, ...string) error { return nil }}
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, []string{"/no/such/dir"}, d); code == 0 {
		t.Fatal("無いフォルダを受けた")
	}
}
