package fgehome

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseJDKSpecReadsVendorAndVersion(t *testing.T) {
	spec, ok, err := parseJDKSpec(strings.NewReader("# 注釈\nFGE_JDK_VENDOR  := zulu\nFGE_JDK_VERSION := 25.0.3 # 版\n"))
	if err != nil || !ok || spec != (JDKSpec{Vendor: "zulu", Version: "25.0.3"}) {
		t.Fatalf("got %+v ok=%v err=%v", spec, ok, err)
	}
}

func TestParseJDKSpecRejectsMissingVersion(t *testing.T) {
	if _, _, err := parseJDKSpec(strings.NewReader("FGE_JDK_VENDOR := zulu\n")); err == nil {
		t.Fatal("want error")
	}
}

func TestReadJDKSpecWithoutFileIsNotAnError(t *testing.T) {
	_, ok, err := ReadJDKSpec(t.TempDir())
	if ok || err != nil {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
}

func TestHomeFollowsFGEHome(t *testing.T) {
	t.Setenv("FGE_HOME", "/x/home")
	if got := EngineDir("0.108.0"); got != filepath.Join("/x/home", "engines", "0.108.0") {
		t.Fatal(got)
	}
}

func TestJDKJavaPath(t *testing.T) {
	t.Setenv("FGE_HOME", "/x")
	if got := (JDKSpec{"zulu", "25.0.3"}).Java(); got != filepath.Join("/x", "jdk", "zulu-25.0.3", "bin", "java") {
		t.Fatal(got)
	}
}

func TestIsBundleIsFalseWhenGoDirExists(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "Makefile"), nil, 0o644)
	os.Mkdir(filepath.Join(dir, "go"), 0o755)
	if IsBundle(dir) {
		t.Fatal("clone を配った engine と見た")
	}
}

func TestIsBundleIsTrueWithoutGoDir(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "Makefile"), nil, 0o644)
	if !IsBundle(dir) {
		t.Fatal("配った engine を見落とした")
	}
}

func TestLatestRoundTrip(t *testing.T) {
	t.Setenv("FGE_HOME", t.TempDir())
	at := time.Date(2026, 11, 23, 0, 0, 0, 0, time.UTC)
	if err := WriteLatest(Latest{Version: "0.109.0", CheckedAt: at}); err != nil {
		t.Fatal(err)
	}
	if l, ok := ReadLatest(); !ok || l.Version != "0.109.0" || !l.CheckedAt.Equal(at) {
		t.Fatalf("%+v %v", l, ok)
	}
}

func TestReadLatestWithoutFileIsNotOK(t *testing.T) {
	t.Setenv("FGE_HOME", t.TempDir())
	if _, ok := ReadLatest(); ok {
		t.Fatal("want ok=false")
	}
}

func TestAddGameReplacesSameDir(t *testing.T) {
	w := Workspace{Games: []Game{{Name: "a", Dir: "/g"}}}
	w.AddGame(Game{Name: "b", Dir: "/g"})
	if len(w.Games) != 1 || w.Games[0].Name != "b" {
		t.Fatalf("%+v", w.Games)
	}
}
