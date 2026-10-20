//go:build !windows

package jarshare

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// fakeEngineRepo は、タグ v9.9.9（devbox.json は flix 9.9.9・小さな Go の口・bin/headless-run）を持つ origin と、
// その作り手専用の clone を作って clone を返す。
func fakeEngineRepo(t *testing.T) string {
	t.Helper()
	base := t.TempDir()
	origin := filepath.Join(base, "origin")
	seed := filepath.Join(base, "seed")
	clone := filepath.Join(base, "engine")
	for _, d := range []string{origin, filepath.Join(seed, "go"), filepath.Join(seed, "bin")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gitIn(t, origin, "init", "-q", "--bare", "-b", "main")
	gitIn(t, seed, "init", "-q", "-b", "main")
	write(t, filepath.Join(seed, "devbox.json"), `{"packages": ["path:./nix/flix#flix_9_9_9"]}`)
	write(t, filepath.Join(seed, "go", "go.mod"), "module fake\n\ngo 1.21\n")
	write(t, filepath.Join(seed, "go", "main.go"), "package main\n\nfunc main() {}\n")
	write(t, filepath.Join(seed, "bin", "headless-run"), "#!/bin/sh\n")
	gitIn(t, seed, "add", ".")
	gitIn(t, seed, "commit", "-q", "-m", "seed")
	gitIn(t, seed, "tag", "v9.9.9")
	gitIn(t, seed, "remote", "add", "origin", origin)
	gitIn(t, seed, "push", "-q", "origin", "main", "--tags")
	gitIn(t, base, "clone", "-q", origin, clone)
	return clone
}

// otherEngineWithFlix は、同じ flix の版（9.9.9）のコンパイラの jar を持つ、ほかの版の置き場を作る。
func otherEngineWithFlix(t *testing.T, engines string) {
	t.Helper()
	other := filepath.Join(engines, "9.9.8")
	if err := os.MkdirAll(filepath.Join(other, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(other, "devbox.json"), `"path:./nix/flix#flix_9_9_9"`)
	write(t, filepath.Join(other, "bin", "flix.jar"), "FLIX")
}

func provisioner(engines, repo, jarVersion string) Provisioner {
	return Provisioner{
		Engines: engines, EngineRepo: repo, GH: &fakeGH{store: filepath.Join(engines, "none")},
		JarVersion: func(string) (string, error) { return jarVersion, nil },
		Log:        &bytes.Buffer{},
	}
}

// タグから作業場を作り、fge-go を組み、ほかの版の置き場から同じ版のコンパイラの jar を写して、置き場がそろう。
func TestProvisionMakesAReadyEngine(t *testing.T) {
	engines := t.TempDir()
	otherEngineWithFlix(t, engines)
	if err := provisioner(engines, fakeEngineRepo(t), "9.9.9").Provision(context.Background(), "9.9.9"); err != nil {
		t.Fatal(err)
	}
	if !Ready(filepath.Join(engines, "9.9.9")) {
		t.Fatal("置き場がそろっていない")
	}
}

// タグがまだ無い版は ErrNoTag（作り手は待つ）。
func TestProvisionWaitsForAMissingTag(t *testing.T) {
	engines := t.TempDir()
	err := provisioner(engines, fakeEngineRepo(t), "9.9.9").Provision(context.Background(), "9.9.10")
	if !errors.Is(err, ErrNoTag) {
		t.Fatalf("got %v", err)
	}
}

// コンパイラの jar の版が devbox.json と違えば置かず、置き場はそろわない。
func TestProvisionRejectsAFlixJarOfAnotherVersion(t *testing.T) {
	engines := t.TempDir()
	otherEngineWithFlix(t, engines)
	if err := provisioner(engines, fakeEngineRepo(t), "0.0.1").Provision(context.Background(), "9.9.9"); err == nil {
		t.Fatal("版の違うコンパイラの jar を置いた")
	}
	if _, err := os.Stat(filepath.Join(engines, "9.9.9", "bin", "flix.jar")); !os.IsNotExist(err) {
		t.Fatal("版の違うコンパイラの jar が置き場に残った")
	}
}

// devbox.json の flix の版を読む。
func TestFlixVersionOf(t *testing.T) {
	if got, ok := FlixVersionOf(`"path:./nix/flix#flix_0_78_0"`); !ok || got != "0.78.0" {
		t.Fatalf("got %q", got)
	}
}
