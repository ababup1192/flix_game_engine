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

// refactor.local.json が flixlint を書いた時だけ、既定の flixlint の探し方を止める。
func TestLocalNamesFlixlintOnlyWhenTheFieldIsSet(t *testing.T) {
	for body, want := range map[string]bool{
		``: false,
		`{"verify": "java -jar bin/flix.jar check"}`: false,
		`{"flixlint": ""}`:                           false,
		`{"flixlint": "/opt/flixlint/bin/flixlint"}`: true,
	} {
		root := t.TempDir()
		if body != "" {
			dir := filepath.Join(root, "bin", "lint-rules")
			os.MkdirAll(dir, 0o755)
			os.WriteFile(filepath.Join(dir, "refactor.local.json"), []byte(body), 0o644)
		}
		if got := localNamesFlixlint(root); got != want {
			t.Errorf("%q: %v のはず（%v）", body, want, got)
		}
	}
}
