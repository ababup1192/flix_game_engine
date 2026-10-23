package distlinux

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type entry struct {
	mode     int64
	typeflag byte
	link     string
	body     string
}

type fakeEntry struct {
	h    tar.Header
	body string
}

func writeFakeJRE(t *testing.T, dir string, extra ...fakeEntry) (string, string) {
	t.Helper()
	p := filepath.Join(dir, "jre.tar.gz")
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	add := func(h *tar.Header, body string) {
		h.Size = int64(len(body))
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		io.WriteString(tw, body)
	}
	add(&tar.Header{Typeflag: tar.TypeDir, Name: "jdk-21-jre/", Mode: 0o755}, "")
	add(&tar.Header{Typeflag: tar.TypeDir, Name: "jdk-21-jre/bin/", Mode: 0o755}, "")
	add(&tar.Header{Typeflag: tar.TypeReg, Name: "jdk-21-jre/bin/java", Mode: 0o755}, fakeJava)
	add(&tar.Header{Typeflag: tar.TypeSymlink, Name: "jdk-21-jre/lib/libjli.so", Linkname: "server/libjli.so", Mode: 0o777}, "")
	for _, e := range extra {
		h := e.h
		add(&h, e.body)
	}
	tw.Close()
	gz.Close()
	f.Close()
	b, _ := os.ReadFile(p)
	sum := sha256.Sum256(b)
	return p, hex.EncodeToString(sum[:])
}

func writeFakeGame(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "my_game")
	for p, body := range map[string]string{
		"build/headless/headless.jar": "PK",
		"project.json":                "{}",
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

// fakeJava は java の代わりに、呼ばれた場所・入口・引数を java.out へ書く。
const fakeJava = `#!/bin/sh
{ pwd; echo "entry=$FGE_ENTRY"; echo "args=$*"; } > java.out
`

func buildFake(t *testing.T, mutate func(*Options), extra ...fakeEntry) (Result, error) {
	t.Helper()
	game := writeFakeGame(t)
	jre, sum := writeFakeJRE(t, t.TempDir(), extra...)
	opts := Options{
		Dir: game, Include: []string{"assets", "project.json"},
		JREArchive: jre, JRE: JRESpec{Version: "test", SHA256: sum},
	}
	if mutate != nil {
		mutate(&opts)
	}
	return Build(opts, io.Discard)
}

func readEntries(t *testing.T, archive string) map[string]entry {
	t.Helper()
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
	got := map[string]entry{}
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return got
		}
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(tr)
		got[h.Name] = entry{h.Mode, h.Typeflag, h.Linkname, string(b)}
	}
}

func builtEntries(t *testing.T) map[string]entry {
	t.Helper()
	res, err := buildFake(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	return readEntries(t, res.Archive)
}

func TestArchiveHasTheLayout(t *testing.T) {
	got := builtEntries(t)
	for _, name := range []string{
		"my_game-linux-x64/run.sh",
		"my_game-linux-x64/README.txt",
		"my_game-linux-x64/game/game.jar",
		"my_game-linux-x64/game/project.json",
		"my_game-linux-x64/game/assets/a.png",
		"my_game-linux-x64/jre/bin/java",
	} {
		if _, ok := got[name]; !ok {
			t.Errorf("%s が無い", name)
		}
	}
}

func TestRunScriptIsExecutable(t *testing.T) {
	if m := builtEntries(t)["my_game-linux-x64/run.sh"].mode; m != 0o755 {
		t.Errorf("run.sh の mode = %o", m)
	}
}

func TestRunScriptNamesTheGame(t *testing.T) {
	body := builtEntries(t)["my_game-linux-x64/run.sh"].body
	if !strings.Contains(body, "game=my_game\n") || strings.Contains(body, "@GAME@") {
		t.Errorf("run.sh にゲームの名前が入っていない")
	}
}

func TestJavaKeepsItsExecBit(t *testing.T) {
	if m := builtEntries(t)["my_game-linux-x64/jre/bin/java"].mode; m != 0o755 {
		t.Errorf("jre/bin/java の mode = %o", m)
	}
}

func TestJRESymlinkIsKept(t *testing.T) {
	e := builtEntries(t)["my_game-linux-x64/jre/lib/libjli.so"]
	if e.typeflag != tar.TypeSymlink || e.link != "server/libjli.so" {
		t.Errorf("symlink が運ばれていない: %+v", e)
	}
}

func TestDotFilesAreLeftOut(t *testing.T) {
	if _, ok := builtEntries(t)["my_game-linux-x64/game/assets/.DS_Store"]; ok {
		t.Errorf(".DS_Store が入っている")
	}
}

func TestSourcesAreLeftOut(t *testing.T) {
	for name := range builtEntries(t) {
		if strings.Contains(name, "/src/") {
			t.Errorf("include していない %s が入っている", name)
		}
	}
}

func TestParentDirsComeBeforeChildren(t *testing.T) {
	res, err := buildFake(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	f, _ := os.Open(res.Archive)
	defer f.Close()
	gz, _ := gzip.NewReader(f)
	tr := tar.NewReader(gz)
	seen := map[string]bool{}
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		name := strings.TrimSuffix(h.Name, "/")
		if parent := filepath.Dir(name); parent != "." && !seen[parent] {
			t.Errorf("%s より前に親 %s が無い", h.Name, parent)
		}
		seen[name] = true
	}
}

func TestSHA256FileMatchesArchive(t *testing.T) {
	res, err := buildFake(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(res.Archive + ".sha256")
	if want := res.SHA256 + "  my_game-linux-x64.tar.gz\n"; string(b) != want {
		t.Errorf(".sha256 = %q, want %q", b, want)
	}
}

func TestWrongJRESHA256Stops(t *testing.T) {
	_, err := buildFake(t, func(o *Options) { o.JRE.SHA256 = strings.Repeat("0", 64) })
	if err == nil || !strings.Contains(err.Error(), "SHA-256 が合いません") {
		t.Errorf("err = %v", err)
	}
}

func TestMissingJarStops(t *testing.T) {
	_, err := buildFake(t, func(o *Options) { o.Jar = filepath.Join(o.Dir, "nope.jar") })
	if err == nil || !strings.Contains(err.Error(), "jar がありません") {
		t.Errorf("err = %v", err)
	}
}

func TestIncludeOutsideTheGameStops(t *testing.T) {
	_, err := buildFake(t, func(o *Options) {
		os.MkdirAll(filepath.Join(filepath.Dir(o.Dir), "outside"), 0o755)
		o.Include = []string{"../outside"}
	})
	if err == nil || !strings.Contains(err.Error(), "ゲームの根の中の相対で") {
		t.Errorf("err = %v", err)
	}
}

func TestJRENameLeavingTheFolderStops(t *testing.T) {
	_, err := buildFake(t, nil, fakeEntry{tar.Header{Typeflag: tar.TypeReg, Name: "jdk-21-jre/../../x", Mode: 0o644}, ""})
	if err == nil || !strings.Contains(err.Error(), "外へ出る名前") {
		t.Errorf("err = %v", err)
	}
}

func TestJRESymlinkLeavingTheFolderStops(t *testing.T) {
	_, err := buildFake(t, nil, fakeEntry{tar.Header{Typeflag: tar.TypeSymlink, Name: "jdk-21-jre/lib/x.so", Linkname: "../../../etc/passwd", Mode: 0o777}, ""})
	if err == nil || !strings.Contains(err.Error(), "外を指しています") {
		t.Errorf("err = %v", err)
	}
}

func TestJREHardlinkStops(t *testing.T) {
	_, err := buildFake(t, nil, fakeEntry{tar.Header{Typeflag: tar.TypeLink, Name: "jdk-21-jre/bin/java2", Linkname: "jdk-21-jre/bin/java"}, ""})
	if err == nil || !strings.Contains(err.Error(), "運べない種類") {
		t.Errorf("err = %v", err)
	}
}

func TestNameWithSpaceStops(t *testing.T) {
	_, err := buildFake(t, func(o *Options) { o.Name = "my game" })
	if err == nil {
		t.Errorf("空白入りの名前が通る（run.sh の game= が壊れる）")
	}
}
