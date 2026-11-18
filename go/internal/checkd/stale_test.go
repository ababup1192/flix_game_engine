//go:build !windows

package checkd

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 何を守るか: 常駐が起きた後に lib の engine の束が張り替わったら（make sync-engine-full）古いと分かること、
// 起きる前の束・lib/cache の中は古さに数えないこと。

// listenAt は短いパスに Unix socket を開き、その時刻を at にする（socket のパスは 100 字ほどが上限）。
func listenAt(t *testing.T, at time.Time) string {
	dir, err := os.MkdirTemp("/tmp", "stale")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "s.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	if err := os.Chtimes(sock, at, at); err != nil {
		t.Fatal(err)
	}
	return sock
}

// pkgWithFpkg は lib/github の下に束への symlink を持つパッケージ（束そのものは long ago の時刻）。
func pkgWithFpkg(t *testing.T, longAgo time.Time) string {
	pkg := t.TempDir()
	store := filepath.Join(pkg, "store", "package.fpkg")
	os.MkdirAll(filepath.Dir(store), 0o755)
	os.WriteFile(store, []byte("x"), 0o644)
	os.Chtimes(store, longAgo, longAgo)
	dir := filepath.Join(pkg, "lib", "github", "o", "e", "1.0.0")
	os.MkdirAll(dir, 0o755)
	if err := os.Symlink(store, filepath.Join(dir, "e-1.0.0.fpkg")); err != nil {
		t.Fatal(err)
	}
	return pkg
}

func TestStaleWhenFpkgSymlinkReplacedAfterResidentStarted(t *testing.T) {
	now := time.Now()
	sock := listenAt(t, now.Add(-time.Hour))
	pkg := pkgWithFpkg(t, now.Add(-2*time.Hour))
	if _, stale := staleReason(sock, pkg); !stale {
		t.Error("起きた後に張り替えた束を古いと言わない")
	}
}

func TestNotStaleWhenResidentStartedAfterFpkg(t *testing.T) {
	now := time.Now()
	pkg := pkgWithFpkg(t, now.Add(-2*time.Hour))
	sock := listenAt(t, now.Add(time.Minute))
	if why, stale := staleReason(sock, pkg); stale {
		t.Errorf("束より後に起きた常駐を古いと言った: %s", why)
	}
}

func TestLibCacheDoesNotCountAsDependency(t *testing.T) {
	now := time.Now()
	pkg := pkgWithFpkg(t, now.Add(-2*time.Hour))
	sock := listenAt(t, now.Add(time.Minute))
	cache := filepath.Join(pkg, "lib", "cache", "x.jar")
	os.MkdirAll(filepath.Dir(cache), 0o755)
	os.WriteFile(cache, []byte("x"), 0o644)
	future := now.Add(time.Hour)
	os.Chtimes(cache, future, future)
	if why, stale := staleReason(sock, pkg); stale {
		t.Errorf("lib/cache の中を依存に数えた: %s", why)
	}
}

func TestNotStaleWithoutSocket(t *testing.T) {
	pkg := pkgWithFpkg(t, time.Now())
	if _, stale := staleReason(filepath.Join(pkg, "none.sock"), pkg); stale {
		t.Error("居ない常駐を古いと言った")
	}
}

func TestLibExternalJarsDoNotCountAsDependency(t *testing.T) {
	pkg := pkgWithFpkg(t, time.Now().Add(-2*time.Hour))
	time.Sleep(20 * time.Millisecond)
	sock := listenAt(t, time.Now())
	time.Sleep(20 * time.Millisecond)
	jar := filepath.Join(pkg, "lib", "external", "lwjgl-natives.jar")
	os.MkdirAll(filepath.Dir(jar), 0o755)
	os.WriteFile(jar, []byte("x"), 0o644)
	if why, stale := staleReason(sock, pkg); stale {
		t.Errorf("常駐の Bootstrap が起きた後に置いた lib/external の jar を依存に数えた: %s", why)
	}
}
