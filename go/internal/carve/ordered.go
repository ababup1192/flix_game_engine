package carve

// 入れた順を覚える Counter（入れた順の Map は pxlib.OMap）。
//
// WhyNot: 標準の map で置き換えられないのは、出力が回る順に依存するため。
// 入れた順が「同点のときどれを選ぶか」を決めている (MostCommon の同点・
// min/max の同点・投票の先着)。map にすると順が散って絵が変わる。

import "sort"

// Counter は鍵ごとの回数を、入れた順を保って数える。
type Counter[K comparable] struct {
	idx    map[K]int
	keys   []K
	counts []int
}

// NewCounter は空の Counter を作る。
func NewCounter[K comparable]() *Counter[K] {
	return &Counter[K]{idx: map[K]int{}}
}

// Add は数える。
func (c *Counter[K]) Add(k K, n int) {
	if i, ok := c.idx[k]; ok {
		c.counts[i] += n
		return
	}
	c.idx[k] = len(c.keys)
	c.keys = append(c.keys, k)
	c.counts = append(c.counts, n)
}

// Get は回数。無ければ 0。
func (c *Counter[K]) Get(k K) int {
	if i, ok := c.idx[k]; ok {
		return c.counts[i]
	}
	return 0
}

// Len は種類の数。
func (c *Counter[K]) Len() int { return len(c.keys) }

// MostCommon は多い順。同点は先に入れた方が先。
//
// WhyNot: 同点を鍵の大小で決めないのは、この順が色への legend 文字の割り当てを
// 決めるため。入れた順の通し番号で並べ替えれば、同点でも先に入れた方が必ず勝つ。
func (c *Counter[K]) MostCommon() ([]K, []int) {
	order := make([]int, len(c.keys))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool {
		return c.counts[order[a]] > c.counts[order[b]]
	})
	keys := make([]K, len(order))
	counts := make([]int, len(order))
	for i, o := range order {
		keys[i], counts[i] = c.keys[o], c.counts[o]
	}
	return keys, counts
}

// MostCommon1 は最も多い 1 つ。同点は先に入れた方。
func (c *Counter[K]) MostCommon1() (K, int, bool) {
	var best K
	bestCount := 0
	found := false
	for i, k := range c.keys {
		if !found || c.counts[i] > bestCount {
			best, bestCount, found = k, c.counts[i], true
		}
	}
	return best, bestCount, found
}
