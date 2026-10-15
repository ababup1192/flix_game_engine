package ztable

// 付け替え — 表 (tableFileNames) を持つパッケージで、表の外から z を関数で付け替えている所。
//
// zMapped(z -> z / 4) のような付け替えは、表が決めた層・帯の数を後から全部動かすので、
// 付け替えた後の z がどの層に入るかは表を見ても分からない。表を持つパッケージでは、
// 層・帯の段から z を作り直す。表の無いパッケージは z の置き場を自分で決めているので見ない。

import (
	"bufio"
	"sort"
	"strings"
)

// RemapHits はパッケージの本文 (パス → 本文) から付け替えを拾う。表のファイルが無ければ空。
func (r *Rules) RemapHits(bodies map[string]string) []Hit {
	var paths []string
	hasTable := false
	for p := range bodies {
		paths = append(paths, p)
		if r.IsTable(p) {
			hasTable = true
		}
	}
	if !hasTable {
		return nil
	}
	sort.Strings(paths)
	var hits []Hit
	for _, p := range paths {
		if r.IsTable(p) {
			continue
		}
		sc := bufio.NewScanner(strings.NewReader(bodies[p]))
		sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
		for n := 1; sc.Scan(); n++ {
			if m := r.Remap.FindString(stripComment(sc.Text())); m != "" {
				hits = append(hits, Hit{Def: Def{Path: p, Line: n, Name: strings.TrimRight(strings.TrimSpace(m), "( ")}, Remap: true})
			}
		}
	}
	return hits
}
