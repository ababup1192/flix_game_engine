package launcher

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseAssignmentsReadsQuotedValues(t *testing.T) {
	got := parseAssignments([]byte("FLIXLINT_DIR='/a/b'\nFLIXLINT_SHIM='/c.jar'\n\nnoise\nPATH='/j/bin:/usr/bin'\n"))
	if got["FLIXLINT_DIR"] != "/a/b" || got["FLIXLINT_SHIM"] != "/c.jar" || got["PATH"] != "/j/bin:/usr/bin" {
		t.Fatalf("%v", got)
	}
}

func TestParseAssignmentsSkipsLinesWithoutEquals(t *testing.T) {
	if got := parseAssignments([]byte("noise\n")); len(got) != 0 {
		t.Fatalf("%v", got)
	}
}

func TestShasumShimMatchesSha1sumAndSha256sum(t *testing.T) {
	if _, err := exec.LookPath("sha1sum"); err != nil {
		t.Skip("sha1sum が無い")
	}
	dir := t.TempDir()
	shim := filepath.Join(dir, "shasum")
	if err := os.WriteFile(shim, []byte(shasumShim), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{nil, "sha1sum"},
		{[]string{"-a", "256"}, "sha256sum"},
	} {
		g := exec.Command(shim, c.args...)
		g.Stdin = strings.NewReader("x")
		got, err1 := g.Output()
		w := exec.Command(c.want)
		w.Stdin = strings.NewReader("x")
		want, err2 := w.Output()
		if err1 != nil || err2 != nil || string(got) != string(want) {
			t.Errorf("%v: got %q (%v) want %q (%v)", c.args, got, err1, want, err2)
		}
	}
}
