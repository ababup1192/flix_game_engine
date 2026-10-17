package pxlib

import "testing"

func TestOMapKeepsPlaceOnOverwrite(t *testing.T) {
	m := NewOMap[string, int]()
	m.Set("a", 1)
	m.Set("b", 2)
	m.Set("a", 3)
	keys := m.Keys()
	if keys[0] != "a" || keys[1] != "b" || len(keys) != 2 {
		t.Fatalf("上書きで並びが動いた: %v", keys)
	}
}

func TestOMapReinsertGoesToEnd(t *testing.T) {
	m := NewOMap[string, int]()
	m.Set("a", 1)
	m.Set("b", 2)
	m.Delete("a")
	m.Set("a", 9)
	keys := m.Keys()
	if keys[0] != "b" || keys[1] != "a" {
		t.Fatalf("消して入れ直した鍵が末尾に来ない: %v", keys)
	}
}

func TestJSONStringEscapesLikePython(t *testing.T) {
	got := JSONString("a\"b\\cあ\n\t\x01")
	want := `"a\"b\\cあ\n\t\u0001"`
	if got != want {
		t.Fatalf("%s ではなく %s", want, got)
	}
}
