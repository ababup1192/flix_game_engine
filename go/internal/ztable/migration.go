package ztable

// 移行の口 — SortingLayer.z(層, 段) と ZStack.leafAbsolute(...) は、場面を ZStack の木にするまでの間だけ
// 使った口。表を持つパッケージでは、表の外の呼び出しを付け替えと同じく鳴らす (残すなら理由つきの除外へ)。
// WhyNot: 表の無いパッケージを見ないのは、層の表を持たないパッケージ (エンジン・見本) には
// 木に積む先の層が無く、口そのものを確かめるテストもそこにあるため。

import (
	"bufio"
	"regexp"
	"sort"
	"strings"
)

// isDefinition は line の start から始まる名前が、その名前の宣言 (def 名前() ...) か。
// WhyNot: 宣言の行 (ZStack.flix の pub def leafAbsolute(...)) を呼び出しに数えないため。
func isDefinition(line string, start int) bool {
	return strings.HasSuffix(strings.TrimRight(line[:start], " \t"), "def")
}

// MigrationHits は表を持つパッケージで、表の外から移行の口を呼んでいる所を拾う。
// Name は呼んだ口の名前 ("SortingLayer.z" か "leafAbsolute")。除外の鍵は "パス::名前"。
func (r *Rules) MigrationHits(bodies map[string]string, tables map[string]bool) []Hit {
	if len(tables) == 0 {
		return nil
	}
	var hits []Hit
	for p, body := range bodies {
		if tables[p] {
			continue
		}
		sc := bufio.NewScanner(strings.NewReader(body))
		sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
		n := 0
		for sc.Scan() {
			n++
			line := stripComment(sc.Text())
			for _, re := range []*regexp.Regexp{r.LayerZ, r.LeafAbs} {
				for _, loc := range re.FindAllStringIndex(line, -1) {
					if isDefinition(line, loc[0]) {
						continue
					}
					name := strings.TrimRight(strings.TrimSpace(line[loc[0]:loc[1]]), "( ")
					hits = append(hits, Hit{Def: Def{Path: p, Line: n, Name: name}, Migration: true})
				}
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

// stripComment は行の // 以降を落とす。
func stripComment(line string) string {
	if i := strings.Index(line, "//"); i >= 0 {
		return line[:i]
	}
	return line
}
