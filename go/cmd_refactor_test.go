package main

import (
	"os"
	"path/filepath"
	"testing"
)

// engine の devbox に java があれば、その bin が PATH の先頭に来る。
func TestPathWithEngineJavaPrependsDevboxBin(t *testing.T) {
	engine := t.TempDir()
	bin := filepath.Join(engine, ".devbox", "nix", "profile", "default", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "java"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	got, ok := pathWithEngineJava("/usr/bin", engine)
	if !ok || got != bin+string(os.PathListSeparator)+"/usr/bin" {
		t.Errorf("got %q %v", got, ok)
	}
}

// engine の devbox に java が無ければ、PATH はそのまま。
func TestPathWithEngineJavaKeepsPathWithoutDevbox(t *testing.T) {
	got, ok := pathWithEngineJava("/usr/bin", t.TempDir())
	if ok || got != "/usr/bin" {
		t.Errorf("got %q %v", got, ok)
	}
}
