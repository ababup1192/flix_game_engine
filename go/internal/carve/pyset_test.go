package carve

// set の回る順は CPython 3.7 の並びで縛る。ここがずれると彫った立体の並びが変わり、
// 「同じ (x,y) にどの z を残すか」が変わって絵が別物になる。

import (
	"encoding/json"
	"testing"
)

// intCases は int を 1 つずつ足したときに回る順。CPython 3.7 の set と同じ並び。
const intCases = `[
{"add":[3,9],"order":[9,3]},
{"add":[9,3],"order":[9,3]},
{"add":[0],"order":[0]},
{"add":[],"order":[]},
{"add":[1,2,3,4],"order":[1,2,3,4]},
{"add":[1,2,3,4,5],"order":[1,2,3,4,5]},
{"add":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18],
 "order":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]},
{"add":[31,15,7,3,1,0],"order":[0,1,3,7,15,31]},
{"add":[8,16,24,32,40],"order":[32,8,40,16,24]},
{"add":[5,13,21,29,37,45,53],"order":[37,5,13,45,21,53,29]},
{"add":[100,4,68,36,12],"order":[100,4,36,68,12]},
{"add":[19,50,6,9,12,46,7,27,4,11,55,53,8,30,11,54,7,15,28,7,50],
 "order":[4,6,7,8,9,11,12,46,15,50,19,53,54,55,27,28,30]},
{"add":[28,5,17,37],"order":[17,37,28,5]},
{"add":[60,33,24,44,57,44,46,10,28,13,29,60,25,43,26,61,0,61],
 "order":[0,33,10,43,44,28,46,13,61,24,57,26,60,29,25]},
{"add":[59,28,12,50,62,20,28,20,55],"order":[12,50,20,55,59,28,62]}
]`

// tupleCases は鍵の並びからまとめて作ったときに回る順。CPython 3.7 の set と同じ並び。
// popped は pop と remove を混ぜて空にするまでの並び。
const tupleCases = `[
{"keys":[[16,3],[11,12],[19,40],[19,33],[13,18],[28,32],[11,17],[22,1],[16,2],[0,1],[12,32]],
 "order":[[19,40],[0,1],[11,17],[12,32],[16,3],[16,2],[13,18],[28,32],[22,1],[19,33],[11,12]],
 "popped":[[19,40],[0,1],[11,17],[12,32],[16,3],[16,2],[13,18],[28,32],[22,1],[19,33],[11,12]]},
{"keys":[[25,3],[13,1],[9,26],[3,45],[3,11],[25,28],[20,46],[7,5],[10,21],[12,11]],
 "order":[[9,26],[13,1],[3,45],[3,11],[10,21],[7,5],[12,11],[25,3],[20,46],[25,28]],
 "popped":[[9,26],[13,1],[3,45],[3,11],[10,21],[7,5],[12,11],[25,3],[20,46],[25,28]]},
{"keys":[[15,28],[6,42],[27,42],[31,34],[25,32],[19,44],[13,14],[21,12],[8,25],[22,3],[8,0],
 [4,40],[16,27],[10,3],[5,42],[24,32],[18,38],[15,44],[18,2],[29,11],[10,17],[28,0],[16,23],
 [21,35],[20,15],[2,19],[13,22],[11,0],[21,24],[5,30],[17,32]],
 "order":[[8,25],[22,3],[15,44],[13,22],[5,42],[10,17],[18,2],[20,15],[6,42],[8,0],[17,32],
 [16,23],[29,11],[21,35],[11,0],[27,42],[25,32],[19,44],[31,34],[10,3],[5,30],[2,19],[4,40],
 [13,14],[15,28],[16,27],[18,38],[28,0],[21,12],[24,32],[21,24]],
 "popped":[[8,25],[22,3],[15,44],[13,22],[5,42],[6,42],[10,17],[18,2],[20,15],[8,0],[17,32],
 [16,23],[29,11],[21,35],[11,0],[27,42],[25,32],[19,44],[31,34],[10,3],[5,30],[2,19],[4,40],
 [13,14],[15,28],[16,27],[18,38],[28,0],[21,12],[24,32],[21,24]]}
]`

func TestIntSetOrderMatchesPython(t *testing.T) {
	var cases []struct {
		Add   []int `json:"add"`
		Order []int `json:"order"`
	}
	if err := json.Unmarshal([]byte(intCases), &cases); err != nil {
		t.Fatal(err)
	}
	for i, c := range cases {
		s := NewPySet(hashInt)
		for _, v := range c.Add {
			s.Add(v)
		}
		got := s.Items()
		if len(got) != len(c.Order) {
			t.Fatalf("%d 番目: 個数 %d を期待したが %d", i, len(c.Order), len(got))
		}
		for j := range got {
			if got[j] != c.Order[j] {
				t.Fatalf("%d 番目: 並びが %v ではなく %v", i, c.Order, got)
			}
		}
	}
}

func TestTupleSetOrderMatchesPython(t *testing.T) {
	var cases []struct {
		Keys   [][2]int `json:"keys"`
		Order  [][2]int `json:"order"`
		Popped [][2]int `json:"popped"`
	}
	if err := json.Unmarshal([]byte(tupleCases), &cases); err != nil {
		t.Fatal(err)
	}
	for i, c := range cases {
		var keys []Pt
		for _, k := range c.Keys {
			keys = append(keys, Pt{X: k[0], Y: k[1]})
		}
		s := NewPySetFromKeys(keys, hashPt)
		got := s.Items()
		for j, want := range c.Order {
			if got[j] != (Pt{X: want[0], Y: want[1]}) {
				t.Fatalf("%d 番目: %d 個目が %v ではなく %v", i, j, want, got[j])
			}
		}
		// pop と remove を混ぜても表の舐め方が同じか。
		s2 := NewPySetFromKeys(keys, hashPt)
		var popped []Pt
		for s2.Len() > 0 {
			p, _ := s2.Pop()
			popped = append(popped, p)
			for _, q := range []Pt{{X: p.X + 1, Y: p.Y}, {X: p.X, Y: p.Y + 1}} {
				if s2.Contains(q) {
					s2.Remove(q)
					popped = append(popped, q)
				}
			}
		}
		if len(popped) != len(c.Popped) {
			t.Fatalf("%d 番目: 取り出した個数が %d ではなく %d", i, len(c.Popped), len(popped))
		}
		for j, want := range c.Popped {
			if popped[j] != (Pt{X: want[0], Y: want[1]}) {
				t.Fatalf("%d 番目: %d 個目の取り出しが %v ではなく %v", i, j, want, popped[j])
			}
		}
	}
}

func TestTupleHashMatchesPython(t *testing.T) {
	cases := []struct {
		p    Pt
		want uint64
	}{
		{Pt{X: 0, Y: 0}, 3713080549408328131},
		{Pt{X: 3, Y: 7}, 3713083796998483481},
	}
	for _, c := range cases {
		if got := hashPt(c.p); got != c.want {
			t.Fatalf("hash(%v) が %d ではなく %d", c.p, c.want, got)
		}
	}
}

func TestIntHashOfMinusOne(t *testing.T) {
	if hashInt(-1) != hashInt(-2) {
		t.Fatal("Python は hash(-1) を -2 にする")
	}
}
