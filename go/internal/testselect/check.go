package testselect

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
)

var selectValues = map[string]bool{"": true, "always": true, "code": true, "never": true, "hold": true, "package": true, "go": true}

// CheckTable は gates.json の test-select の表（packages・go・goReads と門の select ほか）の食い違いを並べる。
// testPkgs は Makefile のテストのパッケージ（make gates-facts の test-pkgs）。tracked は git の追跡しているファイル、links は git の symlink（パス → 先）。
func CheckTable(root string, t *Table, testPkgs []string, tracked []string, links map[string]string) []string {
	var errs []string
	add := func(format string, a ...any) { errs = append(errs, fmt.Sprintf(format, a...)) }
	f := t.File
	owned := map[string]bool{}
	seen := map[string]bool{}
	for _, pk := range f.Packages {
		if seen[pk.ID] {
			add("packages: id %s が 2 回あります", pk.ID)
		}
		seen[pk.ID] = true
		if !strings.HasSuffix(pk.Dir, "/") {
			add("packages %s: dir %s は / で終える", pk.ID, pk.Dir)
		}
		if st, err := os.Stat(filepath.Join(root, pk.Dir)); err != nil || !st.IsDir() {
			add("packages %s: dir %s がありません", pk.ID, pk.Dir)
		}
		for _, n := range pk.Feeds {
			if t.pkgs[n] == nil {
				add("packages %s: feeds の %s は packages にありません", pk.ID, n)
			}
		}
		if pk.Test {
			id := "test-" + pk.ID
			owned[id] = true
			if t.gates[id] == nil {
				add("packages %s: test: true なのに門 %s がありません", pk.ID, id)
			}
		}
		if pk.Check && !hasCheck(root, pk.Dir) {
			add("packages %s: check: true なのに flix.toml も Makefile の check の入口もありません", pk.ID)
		}
		for _, g := range pk.Gates {
			owned[g] = true
			if t.gates[g] == nil {
				add("packages %s: 門 %s がありません", pk.ID, g)
			}
		}
	}
	if cyc := t.feedCycle(); cyc != "" {
		add("packages: feeds が輪になっています（%s）", cyc)
	}
	for _, p := range testPkgs {
		pk := t.pkgs[p]
		if pk == nil || !pk.Test {
			add("テストのパッケージ %s が packages に test: true で載っていません", p)
		}
	}
	for _, row := range f.Go {
		for _, g := range row.Gates {
			owned[g] = true
			if t.gates[g] == nil {
				add("go の行「%s」: 門 %s がありません", row.About, g)
			}
		}
		for _, p := range row.Tests {
			if pk := t.pkgs[p]; pk == nil || !pk.Test {
				add("go の行「%s」: tests の %s は test: true のパッケージではありません", row.About, p)
			}
		}
	}
	for _, g := range f.Gates {
		if !selectValues[g.Select] {
			add("%s: select の %s は知らない値（always・code・never・hold・package・go）", g.ID, g.Select)
		}
		if g.Input == nil && g.Select == "" && g.Make != "" {
			add("%s: input の無い門は select が要ります（package の門は package）", g.ID)
		}
		if g.Select == "hold" && g.Hold == "" {
			add("%s: hold の門は流さない理由（hold）を書く", g.ID)
		}
		if g.Select == "package" && !owned[g.ID] && g.ID != "test" && g.ID != "check-pkgs" {
			add("%s: select が package なのに、どの packages の gates・test にも go の行にも載っていません", g.ID)
		}
		if owned[g.ID] && g.Input != nil {
			for _, p := range tracked {
				if g.Input.Match(p) {
					if pk := t.Owner(p); pk != nil {
						add("%s: パッケージに持たれた門の input が packages の dir の中（%s）に当たります。dir の中の差は packages で選ぶ", g.ID, p)
						break
					}
				}
			}
		}
		for _, prefix := range g.Covers {
			hit := false
			for _, o := range f.Gates {
				if o.ID != g.ID && strings.HasPrefix(o.ID, prefix) {
					hit = true
					if o.Make != g.Make {
						add("%s: covers の %s は make の入口が違います（%s と %s）", g.ID, o.ID, g.Make, o.Make)
					}
				}
			}
			if !hit {
				add("%s: covers の %s に当たる門がありません", g.ID, prefix)
			}
		}
	}
	for _, p := range tracked {
		if !strings.HasPrefix(p, "go/") {
			continue
		}
		hit := false
		for _, row := range f.Go {
			if row.Input.Match(p) {
				hit = true
				break
			}
		}
		if !hit && GoPkgOf(p) != GoAll {
			add("go の表のどの行にも当たらない go/ のファイル: %s", p)
		}
	}
	for link, target := range links {
		from := t.Owner(link)
		to := t.Owner(target)
		if from == nil || to == nil || from.ID == to.ID {
			continue
		}
		if !matches(from.Reads, target) && !t.feedClosure(to.ID)[from.ID] {
			add("%s は %s（%s）を指すのに、%s の reads にも %s の feeds にもありません", link, target, to.ID, from.ID, to.ID)
		}
	}
	return errs
}

func hasCheck(root, dir string) bool {
	if _, err := os.Stat(filepath.Join(root, dir, "flix.toml")); err == nil {
		return true
	}
	mk, err := os.ReadFile(filepath.Join(root, dir, "Makefile"))
	return err == nil && strings.Contains("\n"+string(mk), "\ncheck:")
}

func (t *Table) feedCycle() string {
	const (
		white = iota
		grey
		black
	)
	color := map[string]int{}
	var found string
	var visit func(id string, trail []string)
	visit = func(id string, trail []string) {
		if found != "" {
			return
		}
		color[id] = grey
		if pk := t.pkgs[id]; pk != nil {
			for _, n := range pk.Feeds {
				switch color[n] {
				case grey:
					found = strings.Join(append(trail, id, n), " → ")
					return
				case white:
					visit(n, append(trail, id))
				}
			}
		}
		color[id] = black
	}
	for _, pk := range t.File.Packages {
		if color[pk.ID] == white {
			visit(pk.ID, nil)
		}
	}
	return found
}

// TrackedAndLinks は git の追跡しているファイルと、symlink（パス → repo の根からの先）。
func TrackedAndLinks(root string) ([]string, map[string]string, error) {
	out, err := git(root, "ls-files", "-s")
	if err != nil {
		return nil, nil, err
	}
	var tracked []string
	links := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		meta, p, ok := strings.Cut(line, "\t")
		if !ok {
			continue
		}
		tracked = append(tracked, p)
		if strings.HasPrefix(meta, "120000") {
			if dest, err := os.Readlink(filepath.Join(root, p)); err == nil && !filepath.IsAbs(dest) {
				links[p] = path.Clean(path.Join(path.Dir(p), filepath.ToSlash(dest)))
			}
		}
	}
	return tracked, links, nil
}
