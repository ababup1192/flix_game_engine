package fgeinstall

// 何を守るか: Windows では Azul に zip を頼み、zip を開いて <dir>/bin/java.exe にそろえること、zip でも置き場の外へ書けないこと。

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func makeZip(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func windowsJDK(t *testing.T) []byte {
	top := "zulu25.32.17-ca-jdk25.0.3-win_x64/"
	return makeZip(t, map[string]string{
		top:                  "",
		top + "bin/java.exe": "MZ",
		top + "lib/modules":  "m",
	})
}

func TestAzulPlatformNamesWindows(t *testing.T) {
	osName, arch, err := azulPlatform("windows", "amd64")
	if err != nil || osName != "windows" || arch != "x64" {
		t.Fatalf("windows/amd64 → %s/%s %v", osName, arch, err)
	}
}

func TestInstallJDKAsksAzulForAZipOnWindows(t *testing.T) {
	f := newFakeNet(t)
	archive := windowsJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	e := testEnv(t, f, "windows")

	if _, _, err := e.InstallJDK(spec); err != nil {
		t.Fatal(err)
	}
	q := f.query["/metadata/v1/zulu/packages/"]
	for _, want := range []string{"os=windows", "arch=x64", "archive_type=zip"} {
		if !strings.Contains(q, want) {
			t.Errorf("問い合わせに %s が無い: %s", want, q)
		}
	}
}

func TestInstallJDKPutsJavaExeUnderTheSpecFolderOnWindows(t *testing.T) {
	f := newFakeNet(t)
	archive := windowsJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	e := testEnv(t, f, "windows")
	var ran string
	e.RunExe = func(path string, _ ...string) error { ran = path; return nil }

	dir, _, err := e.InstallJDK(spec)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "bin", "java.exe")
	if _, err := os.Stat(want); err != nil || filepath.Base(ran) != "java.exe" {
		t.Fatalf("java.exe が %s にそろっていない（走らせた物 %s）: %v", want, ran, err)
	}
}

func TestExtractZipRefusesAnEscapingName(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "a.zip")
	if err := os.WriteFile(archive, makeZip(t, map[string]string{"../evil": "x"}), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := extractZip(archive, filepath.Join(dir, "x")); err == nil {
		t.Fatal("置き場の外を指す名前を受けた")
	}
}

func TestExtractZipRefusesABackslashEscape(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "a.zip")
	if err := os.WriteFile(archive, makeZip(t, map[string]string{`..\evil`: "x"}), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := extractZip(archive, filepath.Join(dir, "x")); err == nil {
		t.Fatal("逆斜線で外を指す名前を受けた")
	}
}
