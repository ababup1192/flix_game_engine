package hooks

import (
	"os"
	"path/filepath"
	"testing"
)

func layerRepo(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(root, "render_gl", "flix.toml"), "x")
	writeFile(t, filepath.Join(root, ".layers", "render_gl", "flix.toml"), "x")
	return root
}

func TestCheckDirUsesTheLayerFolder(t *testing.T) {
	root := layerRepo(t)
	want := filepath.Join(root, ".layers", "render_gl")
	if got := CheckDir(root, filepath.Join(root, "render_gl")); got != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

func TestCheckDirKeepsAPackageWithoutALayer(t *testing.T) {
	root := layerRepo(t)
	pkg := filepath.Join(root, "templates", "rpg-starter")
	if got := CheckDir(root, pkg); got != pkg {
		t.Fatalf("got %s want %s", got, pkg)
	}
}

func TestCheckDirLinksANewSourceFile(t *testing.T) {
	root := layerRepo(t)
	writeFile(t, filepath.Join(root, "render_gl", "src", "New.flix"), "x")
	CheckDir(root, filepath.Join(root, "render_gl"))
	if !isFile(filepath.Join(root, ".layers", "render_gl", "src", "render_gl", "New.flix")) {
		t.Fatal("新しいファイルのリンクが無い")
	}
}

func TestCheckDirLinksTheBaseEngineSource(t *testing.T) {
	root := layerRepo(t)
	writeFile(t, filepath.Join(root, "engine", "src", "core", "Num.flix"), "x")
	CheckDir(root, filepath.Join(root, "render_gl"))
	if !isFile(filepath.Join(root, ".layers", "render_gl", "src", "engine", "core", "Num.flix")) {
		t.Fatal("土台のファイルのリンクが無い")
	}
}

func TestCheckDirRemovesALinkToADeletedFile(t *testing.T) {
	root := layerRepo(t)
	src := filepath.Join(root, "render_gl", "src", "Old.flix")
	writeFile(t, src, "x")
	pkg := filepath.Join(root, "render_gl")
	CheckDir(root, pkg)
	if err := os.Remove(src); err != nil {
		t.Fatal(err)
	}
	CheckDir(root, pkg)
	link := filepath.Join(root, ".layers", "render_gl", "src", "render_gl", "Old.flix")
	if _, err := os.Lstat(link); err == nil {
		t.Fatal("消したファイルのリンクが残っている")
	}
}
