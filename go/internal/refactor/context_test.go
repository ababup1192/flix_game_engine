package refactor

import "testing"

func fixtureRefs(t *testing.T) ([]Row, map[string]string) {
	rows := loadFixture(t, Resolved)
	var refs []Row
	for _, r := range rows {
		if refKinds[r.Kind] && r.Owner != "" {
			refs = append(refs, r)
		}
	}
	return refs, declWhere(rows)
}

// isRound は area を 2 回呼ぶ（プロジェクトの def は宣言の場所つき）。
func TestCalleesOfFoldsCallsByCallee(t *testing.T) {
	refs, decl := fixtureRefs(t)
	cs := CalleesOf(refs, "Shapes.isRound", decl)
	if len(cs) != 1 || cs[0].Sym != "Shapes.area" || cs[0].Count != 2 || cs[0].From != "project" || cs[0].Where != "src/Shapes.flix:15" {
		t.Errorf("%+v", cs)
	}
}

// area の呼び手は使う def ごと（isRound の 2 回は 1 つに畳み、多い順に先へ）。
func TestCallersOfFoldsByOwner(t *testing.T) {
	refs, decl := fixtureRefs(t)
	cs := CallersOf(refs, "Shapes.area", decl)
	if len(cs) < 3 || cs[0].Sym != "Shapes.isRound" || cs[0].Count != 2 {
		t.Errorf("%+v", cs)
	}
}

// enum の呼び手は case の作る・当てるも数え、型は宣言したプロジェクトの物だけ。
func TestEnumCallersAndTypes(t *testing.T) {
	refs, decl := fixtureRefs(t)
	byOwner := map[string]bool{}
	for _, c := range CallersOf(refs, "Shapes.Shape", decl) {
		byOwner[c.Sym] = true
	}
	if !byOwner["Shapes.area"] || !byOwner["Shapes.make"] {
		t.Errorf("%v", byOwner)
	}
	ts := TypesOf(refs, "Shapes.make", decl)
	if len(ts) != 2 || ts[0].Sym != "Shapes.Shape" || ts[1].Sym != "Shapes.World" {
		t.Errorf("%+v", ts)
	}
}
