package main

// 外部依存を決めた物だけに機械で絞る。
// 許すのは Starlark（px の台本。BSD-3-Clause）と、それが POSIX で整数の最適化に使う x/sys と、
// 同じ持ち主の flixlint の go/（bin/fge refactor の本体の flix-search・flix-refactor と checkres。版は flixlint を上げる時に一緒に）。
// WhyNot: 目視の約束にしないのは、依存は 1 行の go get で静かに入るため。
// 足すときは allowedModules に版ごと書き、go list -deps で組み込まれる物を数えて報告する。

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// allowedModules は go.mod の require に書いてよいモジュールと版。
var allowedModules = map[string]string{
	"go.starlark.net":                   "v0.0.0-20261016124120-4811d7e34ea3",
	"golang.org/x/sys":                  "v0.42.0",
	"github.com/ababup1192/flixlint/go": "v0.0.0-20261026012143-7c672c65914d",
}

func TestGoModRequiresOnlyAllowed(t *testing.T) {
	data, err := os.ReadFile("go.mod")
	if err != nil {
		t.Fatal(err)
	}
	inBlock := false
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		switch {
		case trimmed == "require (":
			inBlock = true
			continue
		case inBlock && trimmed == ")":
			inBlock = false
			continue
		case strings.HasPrefix(trimmed, "require "):
			trimmed = strings.TrimSpace(strings.TrimPrefix(trimmed, "require "))
		case !inBlock:
			continue
		}
		f := strings.Fields(trimmed)
		if len(f) < 2 {
			continue
		}
		if want, ok := allowedModules[f[0]]; !ok || want != f[1] {
			t.Errorf("go.mod に決めていない依存がある: %s %s", f[0], f[1])
		}
	}
}

func TestGoSumOnlyKnownModules(t *testing.T) {
	data, err := os.ReadFile("go.sum")
	if os.IsNotExist(err) {
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	// go.sum には Starlark のテストが使うモジュールの検査値も載る（組み込まれはしない）
	known := map[string]bool{"go.starlark.net": true, "golang.org/x/sys": true, "github.com/ababup1192/flixlint/go": true,
		"github.com/google/go-cmp": true, "google.golang.org/protobuf": true}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if f := strings.Fields(line); len(f) > 0 && !known[f[0]] {
			t.Errorf("go.sum に知らないモジュール: %s", line)
		}
	}
}

var stdlibPath = regexp.MustCompile(`^[a-z0-9_/]+$`)

const modulePath = "github.com/ababup1192/flix_game_engine/go"

func TestAllDepsAreStdlibOrAllowed(t *testing.T) {
	out, err := exec.Command("go", "list", "-deps", "./...").Output()
	if err != nil {
		t.Skipf("go list が動かない環境: %v", err)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		p := strings.TrimSpace(line)
		if p == "" || p == modulePath || strings.HasPrefix(p, modulePath+"/") {
			continue
		}
		// 標準ライブラリのパスはドメインを持たない (ドットを含まない先頭要素)。
		head := strings.SplitN(p, "/", 2)[0]
		if !strings.Contains(head, ".") {
			continue
		}
		ok := false
		for m := range allowedModules {
			if p == m || strings.HasPrefix(p, m+"/") {
				ok = true
			}
		}
		if !ok {
			t.Errorf("決めていない依存: %s", p)
		}
	}
}

func TestNoHardcodedPathSeparator(t *testing.T) {
	// パス組み立てはすべて filepath.Join を通す。
	bad := regexp.MustCompile(`filepath\.Join\([^)]*\\\\`)
	err := filepath.WalkDir(".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(d.Name(), ".go") {
			return err
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if bad.Match(data) {
			t.Errorf("%s: パス区切りを直書きしている", p)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
