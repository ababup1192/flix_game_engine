package ztable

// 付け替え — 表を持つパッケージで、表の外から z を関数で付け替えている所。
//
// zMapped(z -> z / 4)・zShifted・zShiftedAll・raiseZ・Depth.place・Depth.placeOne のような付け替えは、
// 表が決めた層・帯の数を後から動かすので、付け替えた後の z がどの層に入るかは表を見ても分からない。
// 表を持つパッケージでは、層 (SortingLayer) と ZStack の積んだ順で作り直す。表の無いパッケージ
// (エンジンの道具の側を含む) は z の置き場を自分で決めているので見ない。

import (
	"bufio"
	"sort"
	"strings"
)

// RemapHits はパッケージの本文 (パス → 本文) から付け替えを拾う。tables が空なら空。
// Hit の Name は呼んだ関数の名前 (zShiftedAll / Depth.place)。除外の鍵 "パス::名前" に使う。
func (r *Rules) RemapHits(bodies map[string]string, tables map[string]bool) []Hit {
	if len(tables) == 0 {
		return nil
	}
	paths := make([]string, 0, len(bodies))
	for p := range bodies {
		if !tables[p] {
			paths = append(paths, p)
		}
	}
	sort.Strings(paths)
	var hits []Hit
	for _, p := range paths {
		sc := bufio.NewScanner(strings.NewReader(bodies[p]))
		sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
		for n := 1; sc.Scan(); n++ {
			for _, m := range r.Remap.FindAllStringSubmatch(stripComment(sc.Text()), -1) {
				hits = append(hits, Hit{Def: Def{Path: p, Line: n, Name: m[1]}, Remap: true})
			}
		}
	}
	return hits
}
