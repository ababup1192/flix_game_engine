package distlinux

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// unpackAndRun は作った tar.gz を tar で解き、偽の java の入った run.sh を流す。
func unpackAndRun(t *testing.T, env ...string) (unpacked, data string, err error) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("run.sh は bash")
	}
	res, err := buildFake(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	// macOS の一時置き場は symlink の下にあり、run.sh の readlink -f は実パスを返す。
	tmp, _ := filepath.EvalSymlinks(t.TempDir())
	root := filepath.Join(tmp, "with space")
	os.MkdirAll(root, 0o755)
	if out, err := exec.Command("tar", "xzf", res.Archive, "-C", root).CombinedOutput(); err != nil {
		t.Fatalf("tar xzf: %v %s", err, out)
	}
	unpacked = filepath.Join(root, "my_game-linux-x64")
	home := t.TempDir()
	data = filepath.Join(home, ".local", "share", "my_game")
	cmd := exec.Command(filepath.Join(unpacked, "run.sh"))
	cmd.Dir = t.TempDir()
	cmd.Env = append([]string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}, env...)
	_, err = cmd.CombinedOutput()
	return unpacked, data, err
}

func readJavaOut(t *testing.T, data string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(data, "java.out"))
	if err != nil {
		t.Fatalf("java が呼ばれていない: %v", err)
	}
	return string(b)
}

func TestRunScriptStartsJavaInTheDataDir(t *testing.T) {
	_, data, err := unpackAndRun(t)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := filepath.EvalSymlinks(strings.SplitN(readJavaOut(t, data), "\n", 2)[0])
	want, _ := filepath.EvalSymlinks(data)
	if got != want {
		t.Errorf("java の cwd = %s, want %s", got, want)
	}
}

func TestRunScriptStartsTheMainEntry(t *testing.T) {
	_, data, err := unpackAndRun(t)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(readJavaOut(t, data), "entry=main\n") {
		t.Errorf("FGE_ENTRY が main でない: %s", readJavaOut(t, data))
	}
}

func TestRunScriptPassesTheJar(t *testing.T) {
	unpacked, data, err := unpackAndRun(t)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(readJavaOut(t, data), "-jar "+filepath.Join(unpacked, "game", "game.jar")) {
		t.Errorf("game.jar を渡していない: %s", readJavaOut(t, data))
	}
}

func TestRunScriptLinksAssetsIntoTheDataDir(t *testing.T) {
	unpacked, data, err := unpackAndRun(t)
	if err != nil {
		t.Fatal(err)
	}
	link, _ := os.Readlink(filepath.Join(data, "assets"))
	if link != filepath.Join(unpacked, "game", "assets") {
		t.Errorf("assets の symlink = %q", link)
	}
}

func TestRunScriptWritesTheLog(t *testing.T) {
	_, data, err := unpackAndRun(t)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(data, "logs", "run.log"))
	if !strings.Contains(string(b), "[run.sh]") {
		t.Errorf("run.log に起動の行が無い: %q", b)
	}
}

func TestRunScriptAcceptsRelativeDataDir(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("run.sh は bash")
	}
	_, _, err := unpackAndRun(t, "FGE_DATA_DIR=rel-data")
	if err != nil {
		t.Errorf("相対の FGE_DATA_DIR で落ちた: %v", err)
	}
}

func TestRunScriptStopsOnARealAssetsFolder(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("run.sh は bash")
	}
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, ".local", "share", "my_game", "assets"), 0o755)
	res, err := buildFake(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if out, err := exec.Command("tar", "xzf", res.Archive, "-C", root).CombinedOutput(); err != nil {
		t.Fatalf("tar xzf: %v %s", err, out)
	}
	cmd := exec.Command(filepath.Join(root, "my_game-linux-x64", "run.sh"))
	cmd.Env = []string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}
	if err := cmd.Run(); err == nil {
		t.Errorf("symlink でない assets があっても続いた")
	}
}
