package headlessjar

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, p, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPathIsTheJarItselfWhenItIsAZip(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, Rel), "PK\x03\x04rest")
	if got := Path(root); got != filepath.Join(root, Rel) {
		t.Fatalf("got %q", got)
	}
}

func TestPathFollowsThePointerToTheFingerprintedJar(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "build", "headless")
	write(t, filepath.Join(dir, "headless-abc.jar"), "PK\x03\x04")
	write(t, filepath.Join(root, Rel), "headless-abc.jar\r\n")
	if got := Path(root); got != filepath.Join(dir, "headless-abc.jar") {
		t.Fatalf("got %q", got)
	}
}

func TestPathKeepsTheNameWhenThePointedJarIsMissing(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, Rel), "headless-gone.jar\n")
	if got := Path(root); got != filepath.Join(root, Rel) {
		t.Fatalf("got %q", got)
	}
}

func TestPathRefusesPointersOutsideTheFolder(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "build", "evil.jar"), "PK\x03\x04")
	write(t, filepath.Join(root, Rel), "../evil.jar\n")
	if got := Path(root); got != filepath.Join(root, Rel) {
		t.Fatalf("got %q", got)
	}
}
