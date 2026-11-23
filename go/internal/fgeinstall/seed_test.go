package fgeinstall

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const fakeShim = "shim body"

// seedEngine は flixlint と Maven の取り物を同梱した engine を作る（hooks.json の shimSha256 は fakeShim に合わせる）。
func seedEngine(t *testing.T) (engine, flixlintDest string) {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("HOME", filepath.Join(tmp, "user"))
	t.Setenv("USERPROFILE", filepath.Join(tmp, "user"))
	t.Setenv("MVN_CACHE", filepath.Join(tmp, "mvn-cache"))
	engine = filepath.Join(tmp, "engine")

	b, err := os.ReadFile(filepath.Join("..", "..", "..", "bin", "lint-rules", "hooks.json"))
	if err != nil {
		t.Fatal(err)
	}
	var rules map[string]any
	if err := json.Unmarshal(b, &rules); err != nil {
		t.Fatal(err)
	}
	checkd := rules["checkd"].(map[string]any)
	server := checkd["server"].(map[string]any)
	sum := sha256.Sum256([]byte(fakeShim))
	server["shimSha256"] = hex.EncodeToString(sum[:])
	out, _ := json.Marshal(rules)
	writeSeedFile(t, filepath.Join(engine, "bin", "lint-rules", "hooks.json"), string(out))

	version, jar := server["flixlintVersion"].(string), server["shimJar"].(string)
	bundled := filepath.Join(engine, "cache", "flixlint", version)
	writeSeedFile(t, filepath.Join(bundled, jar), fakeShim)
	writeSeedFile(t, filepath.Join(bundled, "src", "bin", "flixlint"), "#!/bin/sh\n")
	writeSeedFile(t, filepath.Join(engine, "lib", "cache", "https", "a", "x.jar"), "jar")

	cacheDir := strings.Replace(checkd["cacheDir"].(string), "~", filepath.Join(tmp, "user"), 1)
	return engine, filepath.Join(filepath.FromSlash(cacheDir), "flixlint", version)
}

func writeSeedFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestSeedCachesPlacesTheBundledFlixlint(t *testing.T) {
	engine, dest := seedEngine(t)
	lines := SeedCaches(engine)
	if _, err := os.Stat(filepath.Join(dest, "src", "bin", "flixlint")); err != nil {
		t.Fatalf("本体を置いていません: %v (%v)", err, lines)
	}
}

func TestSeedCachesPlacesTheBundledShim(t *testing.T) {
	engine, dest := seedEngine(t)
	SeedCaches(engine)
	matches, _ := filepath.Glob(filepath.Join(dest, "*.jar"))
	if len(matches) != 1 {
		t.Fatalf("shim の jar: %v", matches)
	}
}

func TestSeedCachesKeepsAFlixlintAlreadyThere(t *testing.T) {
	engine, dest := seedEngine(t)
	writeSeedFile(t, filepath.Join(dest, "src", "bin", "flixlint"), "already")
	SeedCaches(engine)
	if b, _ := os.ReadFile(filepath.Join(dest, "src", "bin", "flixlint")); string(b) != "already" {
		t.Errorf("置き場に在った本体を書き換えた: %s", b)
	}
}

func TestSeedCachesRefusesAShimWithTheWrongSha(t *testing.T) {
	engine, dest := seedEngine(t)
	jars, _ := filepath.Glob(filepath.Join(engine, "cache", "flixlint", "*", "*.jar"))
	writeSeedFile(t, jars[0], "tampered")
	lines := SeedCaches(engine)
	if len(lines) == 0 || !strings.Contains(lines[0], "sha256") {
		t.Errorf("lines: %v", lines)
	}
	if matches, _ := filepath.Glob(filepath.Join(dest, "*.jar")); len(matches) != 0 {
		t.Errorf("sha256 の合わない jar を置いた: %v", matches)
	}
}

func TestSeedCachesCopiesTheMavenCacheIntoTheSharedDir(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows では共有の置き場を使わない")
	}
	engine, _ := seedEngine(t)
	SeedCaches(engine)
	if _, err := os.Stat(filepath.Join(os.Getenv("MVN_CACHE"), "https", "a", "x.jar")); err != nil {
		t.Errorf("共有の置き場に写していません: %v", err)
	}
}
