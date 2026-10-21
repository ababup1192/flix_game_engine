package checkd

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/resident は flixlint のリリース (hooks.json の checkd.server.flixlintVersion) の test/resident の写し。
// 常駐 (Scala) とこのクライアントが同じバイト列・同じ名前・同じ版を出す事を、同じ fixture で確かめる。

// fixtureHex は # から行末を落とした 16 進の並び。
func fixtureHex(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "resident", name))
	if err != nil {
		t.Fatal(err)
	}
	var text strings.Builder
	for _, line := range strings.Split(string(raw), "\n") {
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		text.WriteString(strings.Join(strings.Fields(line), ""))
	}
	b, err := hex.DecodeString(text.String())
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestRequestIsTheFixturesBytes(t *testing.T) {
	want := fixtureHex(t, "request.hex")
	got := encodeRequest(residentRequest{Kind: "lint", Root: "/p/game", Identity: "id-1",
		Settings: []string{"FLIXLINT_TODAY=2026-10-21"}, Args: []string{"--stage", "src/日🎮.flix"}})
	if !bytes.Equal(got, want) {
		t.Fatalf("request:\n got %x\nwant %x", got, want)
	}
}

func TestReplyFramesAreTheFixturesBytes(t *testing.T) {
	want := fixtureHex(t, "reply.hex")
	frames := []residentFrame{
		{Tag: 'Q', Ahead: 1, Running: "check", Seconds: 12}, {Tag: 'Q', Ahead: 0, Running: "lint", Seconds: 0},
		{Tag: 'O', Bytes: []byte("ok\n")}, {Tag: 'E', Bytes: []byte("e\n")},
		{Tag: 'V', Version: "abc"}, {Tag: 'X', ExitCode: 1},
	}
	var enc []byte
	for _, f := range frames {
		enc = append(enc, encodeFrame(f)...)
	}
	if !bytes.Equal(enc, want) {
		t.Fatalf("reply:\n got %x\nwant %x", enc, want)
	}
	r := bytes.NewReader(want)
	for i, f := range frames {
		got, err := readFrame(r)
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if got.Tag != f.Tag || !bytes.Equal(got.Bytes, f.Bytes) || got.Ahead != f.Ahead || got.Running != f.Running ||
			got.Seconds != f.Seconds || got.Version != f.Version || got.ExitCode != f.ExitCode {
			t.Fatalf("frame %d: got %+v, want %+v", i, got, f)
		}
	}
}

func TestSocketNamesAreTheFixtures(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "resident", "socket-name.txt"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	n := 0
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		cols := strings.Split(line, "\t")
		if got := socketName(cols[0], cols[1]); got != cols[2] {
			t.Errorf("%s: %s, want %s", cols[0], got, cols[2])
		}
		n++
	}
	if n == 0 {
		t.Fatal("socket-name.txt has no row")
	}
}

func TestVersionIsTheFixtures(t *testing.T) {
	dir := filepath.Join("testdata", "resident", "version")
	want, err := os.ReadFile(filepath.Join(dir, "expected.txt"))
	if err != nil {
		t.Fatal(err)
	}
	abs, _ := filepath.Abs(dir)
	got, err := sourcesVersion(abs)
	if err != nil {
		t.Fatal(err)
	}
	if got != strings.TrimSpace(string(want)) {
		t.Fatalf("version %s, want %s", got, strings.TrimSpace(string(want)))
	}
}
