package mvncache

import (
	"os"
	"path/filepath"
	"testing"
)

func setup(t *testing.T) (pkg, shared string) {
	t.Helper()
	tmp, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	shared = filepath.Join(tmp, "shared")
	t.Setenv("MVN_CACHE", shared)
	pkg = filepath.Join(tmp, "pkg")
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pkg, "flix.toml"), []byte("[package]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return pkg, shared
}

func write(t *testing.T, p, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func linkTarget(t *testing.T, pkg string) string {
	t.Helper()
	got, err := os.Readlink(filepath.Join(pkg, "lib", "cache"))
	if err != nil {
		t.Fatalf("lib/cache が symlink でない: %v", err)
	}
	return got
}

func TestMissingCacheBecomesALinkToTheSharedDir(t *testing.T) {
	pkg, shared := setup(t)
	Link(pkg)
	if got := linkTarget(t, pkg); got != shared {
		t.Fatalf("got %s, want %s", got, shared)
	}
}

func TestAnExistingSymlinkIsLeftAlone(t *testing.T) {
	pkg, _ := setup(t)
	other := filepath.Join(filepath.Dir(pkg), "other")
	os.MkdirAll(other, 0o755)
	os.MkdirAll(filepath.Join(pkg, "lib"), 0o755)
	os.Symlink(other, filepath.Join(pkg, "lib", "cache"))
	if msg := Link(pkg); msg != "" || linkTarget(t, pkg) != other {
		t.Fatalf("触ってはいけない symlink を触った: %q", msg)
	}
}

func TestADirectoryWithoutFlixTomlIsLeftAlone(t *testing.T) {
	pkg, _ := setup(t)
	os.Remove(filepath.Join(pkg, "flix.toml"))
	Link(pkg)
	if _, err := os.Lstat(filepath.Join(pkg, "lib", "cache")); err == nil {
		t.Fatal("flix.toml の無い所に lib/cache を作った")
	}
}

func TestFilesOfARealCacheMoveIntoTheSharedDir(t *testing.T) {
	pkg, shared := setup(t)
	write(t, filepath.Join(pkg, "lib", "cache", "https", "a.pom"), "a")
	Link(pkg)
	b, err := os.ReadFile(filepath.Join(shared, "https", "a.pom"))
	if err != nil || string(b) != "a" {
		t.Fatalf("置き場へ移っていない: %v %q", err, b)
	}
}

func TestARealCacheBecomesALinkAfterMoving(t *testing.T) {
	pkg, shared := setup(t)
	write(t, filepath.Join(pkg, "lib", "cache", "https", "a.pom"), "a")
	Link(pkg)
	if got := linkTarget(t, pkg); got != shared {
		t.Fatalf("got %s, want %s", got, shared)
	}
}

func TestTheNestedCacheFolderIsLiftedOneLevel(t *testing.T) {
	pkg, shared := setup(t)
	write(t, filepath.Join(pkg, "lib", "cache", "cache", "https", "b.pom"), "b")
	Link(pkg)
	if _, err := os.Stat(filepath.Join(shared, "https", "b.pom")); err != nil {
		t.Fatalf("lib/cache/cache の下が 1 階層上がっていない: %v", err)
	}
}

func TestAFileThatDiffersFromTheSharedOneIsKeptInUnmerged(t *testing.T) {
	pkg, shared := setup(t)
	write(t, filepath.Join(shared, "https", "a.pom"), "shared")
	write(t, filepath.Join(pkg, "lib", "cache", "https", "a.pom"), "mine")
	Link(pkg)
	b, err := os.ReadFile(filepath.Join(pkg, "lib", "cache.unmerged", "https", "a.pom"))
	if err != nil || string(b) != "mine" {
		t.Fatalf("違う中身が残っていない: %v %q", err, b)
	}
}

func TestTheSharedFileIsNotOverwritten(t *testing.T) {
	pkg, shared := setup(t)
	write(t, filepath.Join(shared, "https", "a.pom"), "shared")
	write(t, filepath.Join(pkg, "lib", "cache", "https", "a.pom"), "mine")
	Link(pkg)
	b, _ := os.ReadFile(filepath.Join(shared, "https", "a.pom"))
	if string(b) != "shared" {
		t.Fatalf("置き場を上書きした: %q", b)
	}
}

func TestLeftoverLocksAreNotMoved(t *testing.T) {
	pkg, shared := setup(t)
	write(t, filepath.Join(pkg, "lib", "cache", "https", "a.pom.lock"), "")
	Link(pkg)
	if _, err := os.Stat(filepath.Join(shared, "https", "a.pom.lock")); err == nil {
		t.Fatal(".lock を置き場へ移した")
	}
}

func TestOffReportsARealCache(t *testing.T) {
	pkg, _ := setup(t)
	write(t, filepath.Join(pkg, "lib", "cache", "x"), "x")
	if got := Off(pkg); got != "実体のフォルダ" {
		t.Fatalf("got %q", got)
	}
}

func TestOffIsQuietForALinkToTheSharedDir(t *testing.T) {
	pkg, _ := setup(t)
	Link(pkg)
	if got := Off(pkg); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestOffIsQuietWhenThereIsNoCacheYet(t *testing.T) {
	pkg, _ := setup(t)
	if got := Off(pkg); got != "" {
		t.Fatalf("got %q", got)
	}
}
