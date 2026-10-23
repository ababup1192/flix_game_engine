package dist

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// launched は解いた配布物の起動を偽の java で流した結果。
type launched struct {
	root string // game/ と jre/ のあるフォルダ
	data string
	err  error
}

// unpackAndLaunch は key の配布物を tar / unzip で解き、起動（run.sh か .app の中の実行ファイル）を流す。
func unpackAndLaunch(t *testing.T, key string, home string, env ...string) launched {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("起動は bash")
	}
	res, err := buildFake(t, key, nil)
	if err != nil {
		t.Fatal(err)
	}
	// macOS の一時置き場は symlink の下にあり、起動の readlink -f は実パスを返す。
	tmp, _ := filepath.EvalSymlinks(t.TempDir())
	dest := filepath.Join(tmp, "with space")
	os.MkdirAll(dest, 0o755)
	var cmd *exec.Cmd
	if strings.HasSuffix(res.Archive, ".zip") {
		if _, err := exec.LookPath("unzip"); err != nil {
			t.Skip("unzip が無い")
		}
		cmd = exec.Command("unzip", "-q", res.Archive, "-d", dest)
	} else {
		cmd = exec.Command("tar", "xzf", res.Archive, "-C", dest)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("解けない: %v %s", err, out)
	}
	top := filepath.Join(dest, strings.TrimSuffix(strings.TrimSuffix(filepath.Base(res.Archive), ".zip"), ".tar.gz"))
	var root, launcher, data string
	switch key {
	case "macos":
		root = filepath.Join(top, "my_game.app", "Contents", "Resources")
		launcher = filepath.Join(top, "my_game.app", "Contents", "MacOS", "my_game")
		data = filepath.Join(home, "Library", "Application Support", "my_game")
	default:
		root = top
		launcher = filepath.Join(top, "run.sh")
		data = filepath.Join(home, ".local", "share", "my_game")
	}
	run := exec.Command(launcher)
	run.Dir = t.TempDir()
	run.Env = append([]string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}, env...)
	_, err = run.CombinedOutput()
	return launched{root: root, data: data, err: err}
}

func readJavaOut(t *testing.T, data string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(data, "java.out"))
	if err != nil {
		t.Fatalf("java が呼ばれていない: %v", err)
	}
	return string(b)
}

func launchOK(t *testing.T, key string) launched {
	t.Helper()
	l := unpackAndLaunch(t, key, t.TempDir())
	if l.err != nil {
		t.Fatal(l.err)
	}
	return l
}

func TestLauncherStartsJavaInTheDataDir(t *testing.T) {
	for _, key := range []string{"linux", "macos"} {
		l := launchOK(t, key)
		got, _ := filepath.EvalSymlinks(strings.SplitN(readJavaOut(t, l.data), "\n", 2)[0])
		want, _ := filepath.EvalSymlinks(l.data)
		if got != want {
			t.Errorf("%s: java の cwd = %s, want %s", key, got, want)
		}
	}
}

func TestLauncherStartsTheMainEntry(t *testing.T) {
	for _, key := range []string{"linux", "macos"} {
		if out := readJavaOut(t, launchOK(t, key).data); !strings.Contains(out, "entry=main\n") {
			t.Errorf("%s: FGE_ENTRY が main でない: %s", key, out)
		}
	}
}

func TestLauncherPassesTheJar(t *testing.T) {
	for _, key := range []string{"linux", "macos"} {
		l := launchOK(t, key)
		if out := readJavaOut(t, l.data); !strings.Contains(out, "-jar "+filepath.Join(l.root, "game", "game.jar")) {
			t.Errorf("%s: game.jar を渡していない: %s", key, out)
		}
	}
}

func TestMacLauncherPassesTheDockName(t *testing.T) {
	if out := readJavaOut(t, launchOK(t, "macos").data); !strings.Contains(out, "-Xdock:name=ゲーム ") {
		t.Errorf("Dock の名前が project.json の title でない: %s", out)
	}
}

func TestLauncherLinksAssetsIntoTheDataDir(t *testing.T) {
	for _, key := range []string{"linux", "macos"} {
		l := launchOK(t, key)
		link, _ := os.Readlink(filepath.Join(l.data, "assets"))
		if link != filepath.Join(l.root, "game", "assets") {
			t.Errorf("%s: assets の symlink = %q", key, link)
		}
	}
}

func TestLauncherWritesTheLog(t *testing.T) {
	for _, key := range []string{"linux", "macos"} {
		b, _ := os.ReadFile(filepath.Join(launchOK(t, key).data, "logs", "run.log"))
		if !strings.Contains(string(b), "[run]") {
			t.Errorf("%s: run.log に起動の行が無い: %q", key, b)
		}
	}
}

func TestLauncherAcceptsRelativeDataDir(t *testing.T) {
	if l := unpackAndLaunch(t, "linux", t.TempDir(), "FGE_DATA_DIR=rel-data"); l.err != nil {
		t.Errorf("相対の FGE_DATA_DIR で落ちた: %v", l.err)
	}
}

func TestLauncherStopsOnARealAssetsFolder(t *testing.T) {
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, ".local", "share", "my_game", "assets"), 0o755)
	if l := unpackAndLaunch(t, "linux", home); l.err == nil {
		t.Errorf("symlink でない assets があっても続いた")
	}
}
