package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGlJarNameOfReadsTheDeclaredHashName(t *testing.T) {
	dir := t.TempDir()
	toml := filepath.Join(dir, "flix.toml")
	body := "[jar-dependencies]\n\"fge-gl-804005f4518b.jar\" = \"url:https://example.invalid/fge-gl-804005f4518b.jar\"\n\"fge-web-0.85.0.jar\" = \"url:x\"\n"
	if err := os.WriteFile(toml, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := glJarNameOf(toml, "0.85.0"); got != "fge-gl-804005f4518b.jar" {
		t.Fatalf("got %q", got)
	}
}

func TestGlJarNameOfFallsBackToTheVersionNameWithoutADeclaration(t *testing.T) {
	if got := glJarNameOf(filepath.Join(t.TempDir(), "missing.toml"), "0.85.0"); got != "fge-gl-0.85.0.jar" {
		t.Fatalf("got %q", got)
	}
}
