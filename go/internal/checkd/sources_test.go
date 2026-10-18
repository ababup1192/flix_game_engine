package checkd

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 保存してすぐの check は、repl の監視が書き換えを拾うまで待ってから送られる
// (待たずに送ると、repl は書き換え前のソースを検査して壊れたコードに exit=0 を返す)。
func TestJustSavedSourceWaitsForReplWatcher(t *testing.T) {
	pkg := t.TempDir()
	src := filepath.Join(pkg, "src", "Main.flix")
	if err := os.MkdirAll(filepath.Dir(src), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src, []byte("def main(): Unit = ()\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	seenAt := time.Now()
	seen := takeSources(pkg)
	time.Sleep(20 * time.Millisecond)
	if err := os.WriteFile(src, []byte("use fge::NoSuchModule\ndef main(): Unit = ()\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	lag := 11 * time.Second
	if w := watchWait(seen, takeSources(pkg), seenAt, time.Now(), lag); w < lag-time.Second {
		t.Errorf("保存直後は監視の遅れのぶん待つはず: %v", w)
	}
}

// mtime が古いまま差し替わったファイルは、いつ変わったか分からないので遅れをまるごと待つ。
func TestOldMtimeReplacementWaitsFullLag(t *testing.T) {
	seenAt := time.Now()
	old := seenAt.Add(-time.Hour).UnixNano()
	seen := map[string]srcStamp{"src/A.flix": {mtime: old, size: 10}}
	now := map[string]srcStamp{"src/A.flix": {mtime: old - 1, size: 12}}
	lag := 11 * time.Second
	if w := watchWait(seen, now, seenAt, seenAt.Add(time.Minute), lag); w != lag {
		t.Errorf("古い mtime の差し替えは lag をまるごと待つはず: %v", w)
	}
}
