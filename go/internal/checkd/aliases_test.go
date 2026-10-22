package checkd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTypeAliasesReadsAMultiLineRecord(t *testing.T) {
	src := "mod A {\n    pub type alias Res = {\n        x = Int32,\n        y = Int32\n    }\n    type alias N = Int32\n    pub def make(): Res = { x = 1, y = 2 }\n}\n"
	got := typeAliases(src)
	want := []string{"pub type alias Res = { x = Int32, y = Int32 }", "type alias N = Int32"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %q", got)
	}
}

// 別名に欄を足した時だけ常駐を入れ替える (別名の外の書き換え・字下げだけの違いでは入れ替えない)。
func TestAliasesMovedOnlyWhenAnAliasChanges(t *testing.T) {
	r := loadRules(t)
	*r.Checkd.CacheDir = t.TempDir()
	pkg := t.TempDir()
	a := filepath.Join(pkg, "src", "A.flix")
	write := func(text string) {
		if err := os.MkdirAll(filepath.Dir(a), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(a, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("mod A {\n    pub type alias Res = { x = Int32 }\n    pub def make(): Res = { x = 1 }\n}\n")
	if !aliasesMoved(r, pkg) {
		t.Error("the first check without a record does not replace the server")
	}
	write("mod A {\n    pub type alias Res = {\n        x = Int32\n    }\n    pub def make(): Res = { x = 2 }\n}\n")
	if aliasesMoved(r, pkg) {
		t.Error("a change outside the alias replaced the server")
	}
	write("mod A {\n    pub type alias Res = { x = Int32, y = Int32 }\n    pub def make(): Res = { x = 1, y = 2 }\n}\n")
	if !aliasesMoved(r, pkg) {
		t.Error("a field added to the alias did not replace the server")
	}
}
