package testselect

import (
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/precommit"
)

var (
	joinUp    = regexp.MustCompile(`Join\(((?:"\.\.",\s*)+)((?:"[^"]+"(?:,\s*)?)+)\)`)
	joinConst = regexp.MustCompile(`Join\(engineRoot,\s*((?:"[^"]+"(?:,\s*)?)+)\)`)
	constRoot = regexp.MustCompile(`const engineRoot\s*=\s*"((?:\.\./)*\.\.)"`)
	upString  = regexp.MustCompile(`"((?:\.\./)+)([A-Za-z_][^"%*]*)"`)
	quoted    = regexp.MustCompile(`"([^"]+)"`)
)

func words(list string) []string {
	var out []string
	for _, m := range quoted.FindAllStringSubmatch(list, -1) {
		out = append(out, m[1])
	}
	return out
}

func prefixesOf(m precommit.Matcher) []string {
	out := append([]string{}, m.Prefixes...)
	for _, sub := range m.AnyOf {
		out = append(out, prefixesOf(sub)...)
	}
	return out
}

// repoReads は go のテストのファイルが repo の根から読むパス（Join("..", …)・engineRoot・"../../x" の字から拾える物だけ）。
func repoReads(t *testing.T, root string) map[string][]string {
	t.Helper()
	out := map[string][]string{}
	err := filepath.WalkDir(filepath.Join(root, "go"), func(p string, de os.DirEntry, err error) error {
		if err != nil || de.IsDir() || !strings.HasSuffix(p, "_test.go") {
			return err
		}
		body, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		dir := path.Dir(filepath.ToSlash(rel))
		src := string(body)
		var found []string
		for _, m := range joinUp.FindAllStringSubmatch(src, -1) {
			found = append(found, path.Join(append([]string{dir, strings.Repeat("../", strings.Count(m[1], `".."`))}, words(m[2])...)...))
		}
		if c := constRoot.FindStringSubmatch(src); c != nil {
			for _, m := range joinConst.FindAllStringSubmatch(src, -1) {
				found = append(found, path.Join(append([]string{dir, c[1]}, words(m[1])...)...))
			}
		}
		for _, m := range upString.FindAllStringSubmatch(src, -1) {
			found = append(found, path.Join(dir, m[1], m[2]))
		}
		pkg := GoPkgOf(filepath.ToSlash(rel))
		for _, f := range found {
			if strings.HasPrefix(f, "..") || strings.HasPrefix(f, "go/") || f == "go" || f == "." {
				continue
			}
			if _, err := os.Lstat(filepath.Join(root, f)); err != nil {
				continue
			}
			out[pkg] = append(out[pkg], f)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// go のテストが repo の根から読む本物のファイルは、goReads（そのパッケージか *）か wiring に当たる。表が古くなるのを止める。
func TestGoTestRepoReadsAreCoveredByGoReads(t *testing.T) {
	tb := table(t)
	root, _ := filepath.Abs(filepath.Join("..", "..", ".."))
	reads := repoReads(t, root)
	t.Logf("拾ったパス: %v", reads)
	for pkg, list := range reads {
		for _, f := range list {
			if tb.File.Wiring.Match(f) {
				continue
			}
			ok := false
			for _, r := range tb.File.GoReads {
				mine := false
				for _, n := range r.Pkgs {
					mine = mine || n == pkg || n == GoAll
				}
				if !mine {
					continue
				}
				if r.Reads.Match(f) || r.Reads.Match(f+"/x") {
					ok = true
				}
				for _, pre := range prefixesOf(r.Reads) {
					ok = ok || strings.HasPrefix(pre, f+"/")
				}
			}
			if !ok {
				t.Errorf("go のパッケージ %s のテストが %s を読むのに、gates.json の goReads に当たりません", pkg, f)
			}
		}
	}
}
