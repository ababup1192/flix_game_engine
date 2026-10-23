package dist

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"testing"
)

type entry struct {
	mode    int64
	symlink bool
	isDir   bool
	link    string
	body    string
}

type fakeEntry struct {
	name     string
	typeflag byte
	link     string
	body     string
	mode     int64
}

// fakeJava は java の代わりに、呼ばれた場所・入口・引数を java.out へ書く。
const fakeJava = `#!/bin/sh
{ pwd; echo "entry=$FGE_ENTRY"; echo "args=$*"; } > java.out
`

// writeFakeJRE は Target と同じ形（tar.gz か zip・頭のフォルダ・root）の小さな JRE を作る。
func writeFakeJRE(t *testing.T, tg Target, extra ...fakeEntry) (string, string) {
	t.Helper()
	pre := "jdk-21-jre/"
	if tg.JRE.Root != "" {
		pre += tg.JRE.Root + "/"
	}
	entries := []fakeEntry{
		{name: "jdk-21-jre/", typeflag: tar.TypeDir, mode: 0o755},
		{name: pre + tg.java, typeflag: tar.TypeReg, body: fakeJava, mode: 0o755},
		{name: pre + "lib/libjli.so", typeflag: tar.TypeSymlink, link: "server/libjli.so"},
		{name: "jdk-21-jre/Contents/MacOS/libjli.dylib", typeflag: tar.TypeReg, body: "x", mode: 0o755},
	}
	entries = append(entries, extra...)
	var buf bytes.Buffer
	ext := ".tar.gz"
	if strings.HasSuffix(tg.JRE.URL, ".zip") {
		ext = ".zip"
		zw := zip.NewWriter(&buf)
		for _, e := range entries {
			h := &zip.FileHeader{Name: e.name}
			switch e.typeflag {
			case tar.TypeDir:
				h.SetMode(fs.ModeDir | 0o755)
			case tar.TypeSymlink:
				h.SetMode(fs.ModeSymlink | 0o777)
				e.body = e.link
			default:
				h.SetMode(fs.FileMode(e.mode))
			}
			w, err := zw.CreateHeader(h)
			if err != nil {
				t.Fatal(err)
			}
			io.WriteString(w, e.body)
		}
		zw.Close()
	} else {
		gz := gzip.NewWriter(&buf)
		tw := tar.NewWriter(gz)
		for _, e := range entries {
			h := &tar.Header{Typeflag: e.typeflag, Name: e.name, Linkname: e.link, Mode: e.mode, Size: int64(len(e.body))}
			if e.typeflag != tar.TypeReg {
				h.Size = 0
			}
			if err := tw.WriteHeader(h); err != nil {
				t.Fatal(err)
			}
			if e.typeflag == tar.TypeReg {
				io.WriteString(tw, e.body)
			}
		}
		tw.Close()
		gz.Close()
	}
	p := filepath.Join(t.TempDir(), "jre"+ext)
	os.WriteFile(p, buf.Bytes(), 0o644)
	sum := sha256.Sum256(buf.Bytes())
	return p, hex.EncodeToString(sum[:])
}

func writeFakeGame(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "my_game")
	for p, body := range map[string]string{
		"build/headless/headless.jar": "PK",
		"project.json":                `{"title": "ゲーム"}`,
		"assets/a.png":                "png",
		"assets/.DS_Store":            "x",
		"src/Main.flix":               "def main",
	} {
		full := filepath.Join(dir, p)
		os.MkdirAll(filepath.Dir(full), 0o755)
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func buildFake(t *testing.T, key string, mutate func(*Options), extra ...fakeEntry) (Result, error) {
	t.Helper()
	tg := Targets[key]
	game := writeFakeGame(t)
	jre, sum := writeFakeJRE(t, tg, extra...)
	spec := tg.JRE
	spec.SHA256 = sum
	opts := Options{
		Dir: game, Version: "v1", Include: []string{"assets", "project.json"},
		JREArchive: jre, JRE: &spec, Out: t.TempDir(),
	}
	if mutate != nil {
		mutate(&opts)
	}
	return Build(tg, opts, io.Discard)
}

func readEntries(t *testing.T, archive string) (map[string]entry, []string) {
	t.Helper()
	got := map[string]entry{}
	var order []string
	if strings.HasSuffix(archive, ".zip") {
		zr, err := zip.OpenReader(archive)
		if err != nil {
			t.Fatal(err)
		}
		defer zr.Close()
		for _, f := range zr.File {
			rc, _ := f.Open()
			b, _ := io.ReadAll(rc)
			rc.Close()
			e := entry{mode: int64(f.Mode().Perm()), isDir: f.Mode().IsDir(), symlink: f.Mode()&fs.ModeSymlink != 0, body: string(b)}
			if e.symlink {
				e.link = string(b)
			}
			name := strings.TrimSuffix(f.Name, "/")
			got[name] = e
			order = append(order, name)
		}
		return got, order
	}
	f, err := os.Open(archive)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return got, order
		}
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(tr)
		name := strings.TrimSuffix(h.Name, "/")
		got[name] = entry{h.Mode, h.Typeflag == tar.TypeSymlink, h.Typeflag == tar.TypeDir, h.Linkname, string(b)}
		order = append(order, name)
	}
}

func builtEntries(t *testing.T, key string) map[string]entry {
	t.Helper()
	res, err := buildFake(t, key, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := readEntries(t, res.Archive)
	return got
}

func TestEveryTargetHasTheLayout(t *testing.T) {
	want := map[string][]string{
		"linux": {"run.sh", "README.txt", "game/game.jar", "game/project.json", "game/assets/a.png", "jre/bin/java"},
		"macos": {"README.txt", "my_game.app/Contents/Info.plist", "my_game.app/Contents/MacOS/my_game",
			"my_game.app/Contents/Resources/game/game.jar", "my_game.app/Contents/Resources/game/assets/a.png",
			"my_game.app/Contents/Resources/jre/bin/java"},
		"windows": {"run.bat", "README.txt", "game/game.jar", "game/project.json", "game/assets/a.png", "jre/bin/java.exe"},
	}
	for _, key := range TargetKeys {
		tg := Targets[key]
		got := builtEntries(t, key)
		for _, rel := range want[key] {
			name := "my_game-v1-" + key + "-" + tg.Arch + "/" + rel
			if _, ok := got[name]; !ok {
				t.Errorf("%s: %s が無い", key, name)
			}
		}
	}
}

func TestArchiveNameCarriesTheVersion(t *testing.T) {
	res, err := buildFake(t, "windows", nil)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(res.Archive) != "my_game-v1-windows-x64.zip" {
		t.Errorf("名前 = %s", filepath.Base(res.Archive))
	}
}

func TestLinuxLauncherIsExecutable(t *testing.T) {
	if m := builtEntries(t, "linux")["my_game-v1-linux-x64/run.sh"].mode; m != 0o755 {
		t.Errorf("run.sh の mode = %o", m)
	}
}

func TestMacLauncherIsExecutable(t *testing.T) {
	if m := builtEntries(t, "macos")["my_game-v1-macos-arm64/my_game.app/Contents/MacOS/my_game"].mode; m != 0o755 {
		t.Errorf("Contents/MacOS/my_game の mode = %o", m)
	}
}

func TestMacJavaKeepsItsExecBitInZip(t *testing.T) {
	if m := builtEntries(t, "macos")["my_game-v1-macos-arm64/my_game.app/Contents/Resources/jre/bin/java"].mode; m != 0o755 {
		t.Errorf("jre/bin/java の mode = %o", m)
	}
}

func TestMacTakesOnlyContentsHome(t *testing.T) {
	for name := range builtEntries(t, "macos") {
		if strings.Contains(name, "libjli.dylib") {
			t.Errorf("Contents/Home の外が入っている: %s", name)
		}
	}
}

func TestMacLauncherStartsOnTheFirstThread(t *testing.T) {
	body := builtEntries(t, "macos")["my_game-v1-macos-arm64/my_game.app/Contents/MacOS/my_game"].body
	if !strings.Contains(body, "-XstartOnFirstThread") {
		t.Errorf("-XstartOnFirstThread が無い")
	}
}

func TestLinuxLauncherHasNoMacFlags(t *testing.T) {
	if strings.Contains(builtEntries(t, "linux")["my_game-v1-linux-x64/run.sh"].body, "XstartOnFirstThread") {
		t.Errorf("Linux の run.sh に macOS の旗がある")
	}
}

func TestInfoPlistNamesTheExecutable(t *testing.T) {
	body := builtEntries(t, "macos")["my_game-v1-macos-arm64/my_game.app/Contents/Info.plist"].body
	if !strings.Contains(body, "<key>CFBundleExecutable</key><string>my_game</string>") {
		t.Errorf("Info.plist の CFBundleExecutable が my_game でない")
	}
}

func TestInfoPlistShowsTheTitle(t *testing.T) {
	body := builtEntries(t, "macos")["my_game-v1-macos-arm64/my_game.app/Contents/Info.plist"].body
	if !strings.Contains(body, "<key>CFBundleDisplayName</key><string>ゲーム</string>") {
		t.Errorf("CFBundleDisplayName が project.json の title でない")
	}
}

func TestWindowsBatchUsesCRLF(t *testing.T) {
	body := builtEntries(t, "windows")["my_game-v1-windows-x64/run.bat"].body
	if strings.Count(body, "\n") != strings.Count(body, "\r\n") {
		t.Errorf("run.bat に LF だけの行がある")
	}
}

func TestWindowsBatchIsASCII(t *testing.T) {
	for i, r := range builtEntries(t, "windows")["my_game-v1-windows-x64/run.bat"].body {
		if r > 0x7e && r != '\r' {
			t.Errorf("run.bat の %d バイト目に ASCII でない字 %q", i, r)
			return
		}
	}
}

func TestWindowsBatchNamesTheGame(t *testing.T) {
	if !strings.Contains(builtEntries(t, "windows")["my_game-v1-windows-x64/run.bat"].body, `set "GAME=my_game"`) {
		t.Errorf("run.bat にゲームの名前が入っていない")
	}
}

func TestLauncherNamesTheGame(t *testing.T) {
	body := builtEntries(t, "linux")["my_game-v1-linux-x64/run.sh"].body
	if !strings.Contains(body, "game=my_game\n") || strings.Contains(body, "{{") {
		t.Errorf("run.sh にゲームの名前が入っていない")
	}
}

func TestJRESymlinkIsKept(t *testing.T) {
	e := builtEntries(t, "linux")["my_game-v1-linux-x64/jre/lib/libjli.so"]
	if !e.symlink || e.link != "server/libjli.so" {
		t.Errorf("symlink が運ばれていない: %+v", e)
	}
}

func TestJRESymlinkIsKeptInZip(t *testing.T) {
	e := builtEntries(t, "macos")["my_game-v1-macos-arm64/my_game.app/Contents/Resources/jre/lib/libjli.so"]
	if !e.symlink || e.link != "server/libjli.so" {
		t.Errorf("zip の symlink が運ばれていない: %+v", e)
	}
}

func TestDotFilesAreLeftOut(t *testing.T) {
	if _, ok := builtEntries(t, "linux")["my_game-v1-linux-x64/game/assets/.DS_Store"]; ok {
		t.Errorf(".DS_Store が入っている")
	}
}

func TestSourcesAreLeftOut(t *testing.T) {
	for name := range builtEntries(t, "linux") {
		if strings.Contains(name, "/src/") {
			t.Errorf("include していない %s が入っている", name)
		}
	}
}

func TestParentDirsComeBeforeChildren(t *testing.T) {
	for _, key := range TargetKeys {
		res, err := buildFake(t, key, nil)
		if err != nil {
			t.Fatal(err)
		}
		got, order := readEntries(t, res.Archive)
		seen := map[string]bool{}
		for _, name := range order {
			if parent := path.Dir(name); parent != "." && !seen[parent] {
				t.Errorf("%s: %s より前に親 %s が無い", key, name, parent)
			}
			if !got[name].isDir && seen[name] {
				t.Errorf("%s: %s が 2 回ある", key, name)
			}
			seen[name] = true
		}
	}
}

func TestSHA256FileMatchesArchive(t *testing.T) {
	res, err := buildFake(t, "linux", nil)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(res.Archive + ".sha256")
	if want := res.SHA256 + "  my_game-v1-linux-x64.tar.gz\n"; string(b) != want {
		t.Errorf(".sha256 = %q, want %q", b, want)
	}
}

func gitCommitAll(t *testing.T, dir string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git が無い")
	}
	for _, args := range [][]string{{"init", "-q"}, {"add", "."}, {"commit", "-qm", "x"}} {
		cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@t"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	out, _ := exec.Command("git", "-C", dir, "rev-parse", "--short", "HEAD").Output()
	return strings.TrimSpace(string(out))
}

func TestVersionComesFromGit(t *testing.T) {
	var head string
	res, err := buildFake(t, "linux", func(o *Options) {
		o.Version = ""
		head = gitCommitAll(t, o.Dir)
	})
	if err != nil {
		t.Fatal(err)
	}
	if want := "my_game-" + head + "-linux-x64.tar.gz"; filepath.Base(res.Archive) != want {
		t.Errorf("名前 = %s, want %s", filepath.Base(res.Archive), want)
	}
}

func TestVersionMarksUncommittedChanges(t *testing.T) {
	res, err := buildFake(t, "linux", func(o *Options) {
		o.Version = ""
		gitCommitAll(t, o.Dir)
		os.WriteFile(filepath.Join(o.Dir, "project.json"), []byte("{}"), 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(filepath.Base(res.Archive), "-dirty-linux") {
		t.Errorf("変更が残っているのに -dirty が無い: %s", filepath.Base(res.Archive))
	}
}

func TestOutsideGitWithoutVersionStops(t *testing.T) {
	t.Setenv("GIT_CEILING_DIRECTORIES", os.TempDir())
	_, err := buildFake(t, "linux", func(o *Options) {
		o.Version = ""
		t.Setenv("GIT_CEILING_DIRECTORIES", filepath.Dir(o.Dir))
	})
	if err == nil || !strings.Contains(err.Error(), "--version") {
		t.Errorf("err = %v", err)
	}
}

func TestWrongJRESHA256Stops(t *testing.T) {
	_, err := buildFake(t, "linux", func(o *Options) { o.JRE.SHA256 = strings.Repeat("0", 64) })
	if err == nil || !strings.Contains(err.Error(), "SHA-256 が合いません") {
		t.Errorf("err = %v", err)
	}
}

func TestMissingJarStops(t *testing.T) {
	_, err := buildFake(t, "linux", func(o *Options) { o.Jar = filepath.Join(o.Dir, "nope.jar") })
	if err == nil || !strings.Contains(err.Error(), "jar がありません") {
		t.Errorf("err = %v", err)
	}
}

func TestMissingJavaInJREStops(t *testing.T) {
	_, err := buildFake(t, "windows", func(o *Options) {
		// Linux の JRE を Windows の物として渡すと java.exe が無い。
		jre, sum := writeFakeJRE(t, Targets["linux"])
		o.JREArchive, o.JRE.SHA256 = jre, sum
	})
	if err == nil || !strings.Contains(err.Error(), "bin/java.exe がありません") {
		t.Errorf("err = %v", err)
	}
}

func TestIncludeOutsideTheGameStops(t *testing.T) {
	_, err := buildFake(t, "linux", func(o *Options) {
		os.MkdirAll(filepath.Join(filepath.Dir(o.Dir), "outside"), 0o755)
		o.Include = []string{"../outside"}
	})
	if err == nil || !strings.Contains(err.Error(), "ゲームの根の中の相対で") {
		t.Errorf("err = %v", err)
	}
}

func TestJRENameLeavingTheFolderStops(t *testing.T) {
	_, err := buildFake(t, "linux", nil, fakeEntry{name: "jdk-21-jre/../../x", typeflag: tar.TypeReg, mode: 0o644})
	if err == nil || !strings.Contains(err.Error(), "外へ出る名前") {
		t.Errorf("err = %v", err)
	}
}

func TestJRESymlinkLeavingTheFolderStops(t *testing.T) {
	_, err := buildFake(t, "linux", nil, fakeEntry{name: "jdk-21-jre/lib/x.so", typeflag: tar.TypeSymlink, link: "../../../etc/passwd"})
	if err == nil || !strings.Contains(err.Error(), "外を指しています") {
		t.Errorf("err = %v", err)
	}
}

func TestJREHardlinkStops(t *testing.T) {
	_, err := buildFake(t, "linux", nil, fakeEntry{name: "jdk-21-jre/bin/java2", typeflag: tar.TypeLink, link: "jdk-21-jre/bin/java"})
	if err == nil || !strings.Contains(err.Error(), "運べない種類") {
		t.Errorf("err = %v", err)
	}
}

func TestNameWithSpaceStops(t *testing.T) {
	_, err := buildFake(t, "linux", func(o *Options) { o.Name = "my game" })
	if err == nil {
		t.Errorf("空白入りの名前が通る（起動の game= が壊れる）")
	}
}

func TestUnknownOSIsRejected(t *testing.T) {
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, []string{"plan9"}); code != 2 {
		t.Errorf("終了コード = %d", code)
	}
}

func TestJREArchiveWithAllIsRejected(t *testing.T) {
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, []string{"all", "--jre-archive", "x.tar.gz"}); code != 2 {
		t.Errorf("終了コード = %d", code)
	}
}
