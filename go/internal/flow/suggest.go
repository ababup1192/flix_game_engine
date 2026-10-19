package flow

// 知らない名前に「もしかして」の候補を付ける。engine_world/src/Suggest.flix と同じ決まり
// （片方だけ直すと、check と実行器で案が食い違う）。

import (
	"sort"
	"strings"
)

// Distance は大文字小文字を区別しない編集距離。隣り合う 2 字の入れ替えも 1 と数える。
func Distance(a, b string) int {
	xs := []rune(strings.ToLower(a))
	ys := []rune(strings.ToLower(b))
	n := len(ys)
	twoBack := make([]int, n+1)
	prev := make([]int, n+1)
	for j := range prev {
		prev[j] = j
		twoBack[j] = j
	}
	for i := 1; i <= len(xs); i++ {
		row := make([]int, n+1)
		row[0] = i
		for j := 1; j <= n; j++ {
			cost := 1
			if xs[i-1] == ys[j-1] {
				cost = 0
			}
			d := min(row[j-1]+1, prev[j]+1, prev[j-1]+cost)
			if i > 1 && j > 1 && xs[i-1] == ys[j-2] && xs[i-2] == ys[j-1] {
				d = min(d, twoBack[j-2]+1)
			}
			row[j] = d
		}
		twoBack, prev = prev, row
	}
	return prev[n]
}

// Near は known のうち name に近い名前（距離 2 以内（3 字以下の名前は 1 以内）か、2 字以上の頭が同じ物）を近い順に 3 つまで。
func Near(name string, known []string) []string {
	lower := strings.ToLower(name)
	limit := 2
	if len([]rune(name)) <= 3 {
		limit = 1
	}
	type cand struct {
		d, index int
		name     string
	}
	var found []cand
	for i, k := range known {
		d := Distance(name, k)
		if d <= limit || (len([]rune(name)) >= 2 && strings.HasPrefix(strings.ToLower(k), lower)) {
			found = append(found, cand{d, i, k})
		}
	}
	sort.SliceStable(found, func(a, b int) bool {
		if found[a].d != found[b].d {
			return found[a].d < found[b].d
		}
		return found[a].index < found[b].index
	})
	var out []string
	for i := 0; i < len(found) && i < 3; i++ {
		out = append(out, found[i].name)
	}
	return out
}

// Hint は知らせの後ろに付ける 1 句。
func Hint(name string, known []string) string {
	near := Near(name, known)
	if len(near) > 0 {
		return "（もしかして: " + strings.Join(near, " / ") + "）"
	}
	if len(known) == 0 {
		return "（使える名前はまだ無い）"
	}
	shown := known
	more := ""
	if len(shown) > 12 {
		shown = shown[:12]
		more = " …"
	}
	return "（使える名前: " + strings.Join(shown, " ") + more + "）"
}
