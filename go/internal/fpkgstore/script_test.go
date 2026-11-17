package fpkgstore

// What: bin/fpkg-store.sh を偽の engine の根で動かす。put の冪等と書きかけの zip の拒み・link の相対 symlink（空白入りの道）と
// packages.lock の sha（Go の WithEngineLock と同じ結果）・gc の残す決まり（指されている物・KEEP・名前の頭が同じ別の名前）・
// symlink の置き場を自分の実体に替えること。

import (
	"archive/zip"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// fakeEngine は bin/fpkg-store.sh を写した偽の engine の根。
func fakeEngine(t *testing.T) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("symlink と perl の rename を使う")
	}
	root := filepath.Join(t.TempDir(), "eng ine")
	script, err := os.ReadFile(filepath.Join("..", "..", "..", "bin", "fpkg-store.sh"))
	if err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(root, "bin", "fpkg-store.sh"), script, 0o755)
	return root
}

func mustWrite(t *testing.T, path string, body []byte, perm os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, body, perm); err != nil {
		t.Fatal(err)
	}
}

func zipOf(t *testing.T, content string) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	f, err := w.Create("flix.toml")
	if err != nil {
		t.Fatal(err)
	}
	f.Write([]byte(content))
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func run(t *testing.T, root string, env []string, args ...string) (string, error) {
	t.Helper()
	cmd := exec.Command(filepath.Join(root, "bin", "fpkg-store.sh"), args...)
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// putEngineFull は中身 content の engine_full を置き、エントリ（根からの相対）を返す。
func putEngineFull(t *testing.T, root, content string) string {
	t.Helper()
	src := filepath.Join(root, "src-"+content)
	mustWrite(t, filepath.Join(src, "package.fpkg"), zipOf(t, content), 0o644)
	mustWrite(t, filepath.Join(src, "flix.toml"), []byte("toml "+content), 0o644)
	out, err := run(t, root, nil, "put", "engine_full", "0.1.0", filepath.Join(src, "package.fpkg"), filepath.Join(src, "flix.toml"))
	if err != nil {
		t.Fatalf("put: %v %s", err, out)
	}
	return out
}

func TestPutIsIdempotentAndPointsCurrent(t *testing.T) {
	root := fakeEngine(t)
	a := putEngineFull(t, root, "a")
	if again := putEngineFull(t, root, "a"); again != a {
		t.Errorf("同じ中身で別のエントリ: %s と %s", a, again)
	}
	b := putEngineFull(t, root, "b")
	if b == a {
		t.Error("違う中身が同じエントリ")
	}
	cur, ok := Current(root, EngineFull)
	if !ok || filepath.Base(cur) != filepath.Base(b) {
		t.Errorf("current が最後のエントリを指していません: %s", cur)
	}
	info, err := os.Stat(filepath.Join(cur, "package.fpkg"))
	if err != nil || info.Mode().Perm() != 0o444 {
		t.Errorf("エントリのファイルが読むだけになっていません: %v", info.Mode())
	}
}

func TestPutRejectsATruncatedZip(t *testing.T) {
	if _, err := exec.LookPath("unzip"); err != nil {
		t.Skip("unzip が無い")
	}
	root := fakeEngine(t)
	full := zipOf(t, "a")
	mustWrite(t, filepath.Join(root, "half", "package.fpkg"), full[:len(full)/2], 0o644)
	if out, err := run(t, root, nil, "put", "engine_full", "0.1.0", filepath.Join(root, "half", "package.fpkg")); err == nil {
		t.Errorf("書きかけの zip を置いています: %s", out)
	}
	if _, ok := Current(root, EngineFull); ok {
		t.Error("書きかけの zip に current を向けています")
	}
}

func TestLinkPointsTheLibAndAlignsTheLock(t *testing.T) {
	root := fakeEngine(t)
	putEngineFull(t, root, "a")
	pkg := filepath.Join(root, "templates", "my game")
	lock := "[lock]\nversion = 1\n\n" + EngineLockHeader("0.1.0") + "\ntoml = \"sha256:aa\"\nfpkg = \"sha256:bb\"\n"
	mustWrite(t, filepath.Join(pkg, "packages.lock"), []byte(lock), 0o644)
	dest := "lib/github/ababup1192/flix_game_engine/0.1.0"
	if out, err := run(t, root, nil, "link", "templates/my game/", dest, "flix_game_engine-0.1.0.fpkg", "flix_game_engine-0.1.0.toml"); err != nil {
		t.Fatalf("link: %v %s", err, out)
	}
	link := filepath.Join(pkg, dest, "flix_game_engine-0.1.0.fpkg")
	target, err := os.Readlink(link)
	if err != nil || filepath.IsAbs(target) || !IsInStore(root, link) {
		t.Errorf("置き場への相対 symlink ではありません: %q %v", target, err)
	}
	cur, _ := Current(root, EngineFull)
	fsum, _ := Sha256File(filepath.Join(cur, "package.fpkg"))
	tsum, _ := Sha256File(filepath.Join(cur, "flix.toml"))
	want, _ := WithEngineLock(lock, "0.1.0", tsum, fsum)
	got, _ := os.ReadFile(filepath.Join(pkg, "packages.lock"))
	if string(got) != want {
		t.Errorf("シェルと Go で lock の書き換えが違います:\n%s\n---\n%s", got, want)
	}
}

func TestGcKeepsReferencedAndNewestAndOtherNames(t *testing.T) {
	root := fakeEngine(t)
	old := putEngineFull(t, root, "old")
	pkg := filepath.Join(root, "templates", "g")
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	dest := "lib/github/ababup1192/flix_game_engine/0.1.0"
	if out, err := run(t, root, nil, "link", "templates/g", dest, "x.fpkg", "x.toml"); err != nil {
		t.Fatalf("link: %v %s", err, out)
	}
	mid := putEngineFull(t, root, "mid")
	last := putEngineFull(t, root, "last")
	// ls -t の順が同じ秒で揺れないよう、置いた時刻をずらす。
	for i, e := range []string{old, mid} {
		at := time.Now().Add(-time.Duration(3-i) * time.Hour)
		if err := os.Chtimes(filepath.Join(root, e), at, at); err != nil {
			t.Fatal(err)
		}
	}
	web := filepath.Join(root, "w", "package.fpkg")
	mustWrite(t, web, zipOf(t, "web"), 0o644)
	webOut, err := run(t, root, nil, "put", "engine_full_web", "0.1.0", web)
	if err != nil {
		t.Fatal(webOut)
	}
	env := []string{"FPKG_STORE_KEEP=1", "FPKG_STORE_MIN_AGE_MIN=0"}
	// 名前ごとに 1 個だけ残す決まりでも、templates/g が指す old・current の last・別の名前の web は残る。mid だけが消える。
	if out, err := run(t, root, env, "gc"); err != nil {
		t.Fatalf("gc: %v %s", err, out)
	}
	for _, keep := range []string{old, last, webOut} {
		if _, err := os.Stat(filepath.Join(root, keep)); err != nil {
			t.Errorf("%s を消しています", keep)
		}
	}
	if _, err := os.Stat(filepath.Join(root, mid)); err == nil {
		t.Errorf("%s を残しています", mid)
	}
}

func TestPutReplacesASymlinkedStoreWithItsOwnCopy(t *testing.T) {
	root := fakeEngine(t)
	other := filepath.Join(t.TempDir(), "main-store")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "build"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, filepath.Join(root, "build", "fpkg-store")); err != nil {
		t.Fatal(err)
	}
	putEngineFull(t, root, "a")
	if info, err := os.Lstat(filepath.Join(root, "build", "fpkg-store")); err != nil || info.Mode()&os.ModeSymlink != 0 {
		t.Error("置き場が symlink のまま")
	}
	if entries, _ := os.ReadDir(other); len(entries) != 0 {
		t.Errorf("symlink の先（main の置き場）へ書いています: %d 個", len(entries))
	}
}

// 落ちたプロセスの鍵（pid が生きていない）は取り直し、終わったら鍵を外す。コマンドの終了コードはそのまま返す。
func TestLockedTakesOverAStaleLockAndPassesTheExitCode(t *testing.T) {
	root := fakeEngine(t)
	mustWrite(t, filepath.Join(root, "build", ".fpkg-store.lock", "pid"), []byte("999999\n"), 0o644)
	if out, err := run(t, root, nil, "locked", "true"); err != nil {
		t.Fatalf("落ちた鍵を取り直していません: %v %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(root, "build", ".fpkg-store.lock")); err == nil {
		t.Error("終わった後も鍵が残っています")
	}
	if _, err := run(t, root, nil, "locked", "false"); err == nil {
		t.Error("中のコマンドの失敗を返していません")
	}
}
