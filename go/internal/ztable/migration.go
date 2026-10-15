package ztable

// 移行の口 — SortingLayer.z(層, 段) と ZStack.leafAbsolute(...) は、場面を ZStack の木にするまでの間だけ
// 残す口。--all では表の外の呼び出しを数えて残りを 1 行で出し (止めない)、コミット時は表の外で
// SortingLayer.z を新しく足した行 (ステージした差分の + 行) だけを止める。
// WhyNot: 今ある呼び出しを止めないのは、移行の途中のファイルを触るたびにコミットが止まるため。
// 新しく書いた行だけを裁くのは quadratic と同じ考え方。

import (
	"bufio"
	"fmt"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Migration は移行の口の残り (表の外の呼び出しの数)。
type Migration struct {
	LayerZ  int
	LeafAbs int
}

// isDefinition は line の start から始まる名前が、その名前の宣言 (def 名前() ...) か。
// WhyNot: 呼び出しの数に宣言の行 (ZStack.flix の pub def leafAbsolute(...)) を入れないため。
func isDefinition(line string, start int) bool {
	return strings.HasSuffix(strings.TrimRight(line[:start], " \t"), "def")
}

// countCalls は 1 行の中の re の呼び出しを数える (コメントと宣言を除く)。
func countCalls(re *regexp.Regexp, line string) int {
	n := 0
	for _, loc := range re.FindAllStringIndex(line, -1) {
		if !isDefinition(line, loc[0]) {
			n++
		}
	}
	return n
}

// MigrationCount はパッケージの本文 (パス → 本文) のうち、表の外の移行の口の呼び出しを数える。
func (r *Rules) MigrationCount(bodies map[string]string, tables map[string]bool) Migration {
	var m Migration
	for p, body := range bodies {
		if tables[p] {
			continue
		}
		sc := bufio.NewScanner(strings.NewReader(body))
		sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
		for sc.Scan() {
			line := stripComment(sc.Text())
			m.LayerZ += countCalls(r.LayerZ, line)
			m.LeafAbs += countCalls(r.LeafAbs, line)
		}
	}
	return m
}

func git(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	var out, errOut strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git %s が失敗しました: %v %s", strings.Join(args, " "), err, errOut.String())
	}
	return out.String(), nil
}

var hunkLine = regexp.MustCompile(`\+(\d+)`)

// addedLines はステージした差分で paths に足された行を返す (パス → 行番号 → 本文)。
// git が無い・差分が取れないときはエラー (quadratic と同じく、呼ぶ側は止める)。
// WhyNot: --relative を付けるのは、root が git の根より下 (見本の偽リポなど) でも、
// 差分のパスを root からの相対でそろえるため。
func addedLines(root string, paths []string) (map[string]map[int]string, error) {
	added := map[string]map[int]string{}
	if len(paths) == 0 {
		return added, nil
	}
	args := append([]string{"diff", "--cached", "--relative", "--no-color", "--no-ext-diff",
		"-U0", "--diff-filter=ACMR", "--"}, paths...)
	diff, err := git(root, args...)
	if err != nil {
		return nil, err
	}
	path, lineno, inHunk := "", 0, false
	for _, line := range strings.Split(diff, "\n") {
		switch {
		case strings.HasPrefix(line, "diff --git "):
			path, inHunk = "", false
		case !inHunk && strings.HasPrefix(line, "+++ b/"):
			path = line[6:]
		case strings.HasPrefix(line, "@@"):
			inHunk, lineno = true, 0
			if m := hunkLine.FindStringSubmatch(line); m != nil {
				lineno, _ = strconv.Atoi(m[1])
			}
		case inHunk && path != "" && strings.HasPrefix(line, "+"):
			if added[path] == nil {
				added[path] = map[int]string{}
			}
			added[path][lineno] = line[1:]
			lineno++
		}
	}
	return added, nil
}

// LayerZHits は足された行 (addedLines の結果) のうち、表の外で SortingLayer.z を呼んだ行を拾う。
// test/ などの下 (skipDirNames) は見ない (移行の口そのものを確かめるテストがあるため)。
func (r *Rules) LayerZHits(added map[string]map[int]string, tables map[string]bool) []Hit {
	var hits []Hit
	for p, lines := range added {
		if tables[p] || r.underSkipDir(p) {
			continue
		}
		for n, text := range lines {
			line := stripComment(text)
			for _, loc := range r.LayerZ.FindAllStringIndex(line, -1) {
				if isDefinition(line, loc[0]) {
					continue
				}
				name := strings.TrimRight(strings.TrimSpace(line[loc[0]:loc[1]]), "( ")
				hits = append(hits, Hit{Def: Def{Path: p, Line: n, Name: name}, NewLayerZ: true})
			}
		}
	}
	sort.Slice(hits, func(i, j int) bool {
		if hits[i].Path != hits[j].Path {
			return hits[i].Path < hits[j].Path
		}
		return hits[i].Line < hits[j].Line
	})
	return hits
}
