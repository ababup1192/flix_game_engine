package stageengine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const mvnToml = `[mvn-dependencies]
"org.lwjgl:lwjgl"        = "3.4.1"

[jar-dependencies]
"x.jar" = "url:https://example.com/x.jar"
`

func mvnRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writeRules(t, root, `{"items": [{"src": "@mvn-cache", "dest": "lib/cache", "optional": true}]}`)
	writeFile(t, filepath.Join(root, "engine_full", "flix.toml"), mvnToml)
	return root
}

func TestMvnCacheIsStagedIntoLibCache(t *testing.T) {
	root := mvnRoot(t)
	cache := t.TempDir()
	jar := "https/repo1.maven.org/maven2/org/lwjgl/lwjgl/3.4.1/lwjgl-3.4.1.jar"
	writeFile(t, filepath.Join(cache, jar), "jar")
	out := filepath.Join(t.TempDir(), "bundle")
	var body, errBody strings.Builder
	Run(&body, &errBody, root, []string{"--out", out, "--mvn-cache", cache})
	if _, err := os.Stat(filepath.Join(out, "lib", "cache", jar)); err != nil {
		t.Fatalf("lib/cache に入っていません: %v (%s)", err, errBody.String())
	}
}

func TestMvnCacheMissingADeclaredJarStops(t *testing.T) {
	root := mvnRoot(t)
	cache := t.TempDir()
	writeFile(t, filepath.Join(cache, "https/repo1.maven.org/maven2/org/lwjgl/lwjgl-glfw/3.4.1/lwjgl-glfw-3.4.1.jar"), "jar")
	var body, errBody strings.Builder
	code, _ := Run(&body, &errBody, root, []string{"--out", filepath.Join(t.TempDir(), "bundle"), "--mvn-cache", cache})
	if code != 1 || !strings.Contains(errBody.String(), "org.lwjgl:lwjgl:3.4.1") {
		t.Fatalf("code=%d %q", code, errBody.String())
	}
}

func TestMissingMavenJarsReadsOnlyTheMvnSection(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "flix.toml"), mvnToml)
	missing, err := MissingMavenJars(filepath.Join(dir, "flix.toml"), t.TempDir())
	if err != nil || strings.Join(missing, ",") != "org.lwjgl:lwjgl:3.4.1" {
		t.Fatalf("missing=%v err=%v", missing, err)
	}
}

func TestFlixlintWithAWrongShimStops(t *testing.T) {
	root := t.TempDir()
	writeRules(t, root, `{"items": [{"src": "@flixlint", "dest": "cache/flixlint", "optional": true}]}`)
	hooksJSON, err := os.ReadFile(filepath.Join("..", "..", "..", "bin", "lint-rules", "hooks.json"))
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(root, "bin", "lint-rules", "hooks.json"), string(hooksJSON))
	seed := t.TempDir()
	writeFile(t, filepath.Join(seed, "0.9.1", "flixlint-shim-0.80.0.jar"), "not the shim")
	writeFile(t, filepath.Join(seed, "0.9.1", "src", "bin", "flixlint"), "#!/bin/sh\n")
	var body, errBody strings.Builder
	code, _ := Run(&body, &errBody, root, []string{"--out", filepath.Join(t.TempDir(), "bundle"), "--flixlint", seed})
	if code != 1 || !strings.Contains(errBody.String(), "shimSha256") {
		t.Fatalf("code=%d %q", code, errBody.String())
	}
}
