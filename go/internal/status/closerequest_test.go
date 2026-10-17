package status

// 閉じるボタンの口の 1 行: 繋いでいる / いない / コメントの中だけ / engine リポ自身。

import (
	"path/filepath"
	"strings"
	"testing"
)

const closeRequestHead = "終了確認 App.withCloseRequest が繋がっていない"

func hasCloseRequestWarning(lines []string) bool {
	for _, ln := range lines {
		if strings.HasPrefix(ln, closeRequestHead) {
			return true
		}
	}
	return false
}

func TestCloseRequestWiredIsQuiet(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "src", "Main.flix"),
		"def main(): Unit \\ IO =\n    App.game({})\n        |> App.withCloseRequest(w -> w)\n        |> App.launch\n")
	if hasCloseRequestWarning(build(t, root)) {
		t.Error("繋いでいるのに警告が出ます")
	}
}

func TestCloseRequestWiredInAnotherFileIsQuiet(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "src", "Main.flix"), "    App.game({}) |> Wiring.closeRequest |> App.launch\n")
	write(t, filepath.Join(root, "src", "app", "Wiring.flix"), "    pub def closeRequest(a) = a |> App.withCloseRequest(w -> w)\n")
	if hasCloseRequestWarning(build(t, root)) {
		t.Error("別のファイルで繋いでいるのに警告が出ます")
	}
}

func TestCloseRequestMissingWarns(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "src", "Main.flix"), "    App.game({})\n        |> App.launch\n")
	if !hasCloseRequestWarning(build(t, root)) {
		t.Error("繋いでいないのに警告が出ません")
	}
}

func TestCloseRequestOnlyInCommentsWarns(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "src", "Main.flix"),
		"    // App.withCloseRequest は後で足す\n"+
			"    /* |> App.withCloseRequest(w -> w) */\n"+
			"    App.game({}) |> App.launch // App.withCloseRequest\n")
	if !hasCloseRequestWarning(build(t, root)) {
		t.Error("コメントの中にしか無いのに警告が出ません")
	}
}

func TestCloseRequestNoLaunchIsQuiet(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "src", "Lib.flix"), "    pub def f(): Int32 = 1\n")
	if hasCloseRequestWarning(build(t, root)) {
		t.Error("窓を開かないソースで警告が出ます")
	}
}

func TestCloseRequestSkipsEngineRepo(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "templates", "game-starter", "src", "Main.flix"), "    App.game({}) |> App.launch\n")
	write(t, filepath.Join(root, "src", "Main.flix"), "    App.game({}) |> App.launch\n")
	if hasCloseRequestWarning(build(t, root)) {
		t.Error("engine リポ自身で警告が出ます")
	}
}

func TestStripFlixCommentsKeepsStrings(t *testing.T) {
	src := "let g = \"assets/*.json\"; App.withCloseRequest(f) // x\nlet u = \"http://a\" /* y */ z"
	want := "let g = \"assets/*.json\"; App.withCloseRequest(f) \nlet u = \"http://a\"  z"
	if got := stripFlixComments(src); got != want {
		t.Errorf("文字列の中まで落としています:\n  got  %q\n  want %q", got, want)
	}
}
