package refactor

import (
	"io"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/movefields は move-fields のお手本（World の欄・alias の payload の Scene.Deck・inline の record の Scene.Board）。
// testdata/movefields-spans-<段>.tsv はそれに flixlint 0.8.x の --spans --stage <段> src を掛けた物。

func runMoveFields(t *testing.T, root string, args ...string) (int, string, []string) {
	t.Helper()
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")),
		Options{Run: spansRunner("movefields"), Verify: verifyWith(0, "", &cmds), Log: io.Discard})
	return code, out.String() + errOut.String(), cmds
}

// 写す段: payload の alias に欄を足し（型の字は World の宣言から）、payload の組み立てに World の組み立ての値を足す。
// World は触らない。幾つかの欄は 1 つの組み立てにまとめて足す。
func TestMoveFieldsCopiesTheFieldsIntoThePayloadAlias(t *testing.T) {
	root := fixtureRoot(t, "movefields")
	code, out, cmds := runMoveFields(t, root, "move-fields", "--labels", "deckScroll,deckOpen", "--receiver", "World.World",
		"--into-case", "World.Scene.Deck", "--apply")
	if code != 0 || len(cmds) != 1 {
		t.Fatalf("終了コード %d・確かめ %d 回:\n%s", code, len(cmds), out)
	}
	mustContain(t, read(t, root, "src/World.flix"),
		"pub type alias DeckUi = { cursor = Int32, deckScroll = Int32, deckOpen = Bool }",
		"Scene.Deck({ cursor = 0, deckScroll = 0, deckOpen = false })",
		"pub type alias World = { scene = Scene, deckScroll = Int32, deckOpen = Bool, hp = Int32, mode = Mode }")
	mustContain(t, out, "move-fields --labels deckScroll,deckOpen --receiver World.World --into-case World.Scene.Deck --finish")
}

// inline の record の payload（case Board({ … })）へは --value-of の値で足す。
func TestMoveFieldsCopiesIntoAnInlinePayloadWithTheGivenValue(t *testing.T) {
	root := fixtureRoot(t, "movefields")
	code, out, _ := runMoveFields(t, root, "move-fields", "--labels", "hp", "--receiver", "World.World",
		"--into-case", "World.Scene.Board", "--value-of", "hp=3", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/World.flix"), "case Board({ turn = Int32, hp = Int32 })", "Scene.Board({ turn = 1, hp = 3 })")
}

// --finish: 直の読み書き（scrollOf の w#deckScroll）が残れば止め、無い欄（deckOpen）は World の型と組み立てから消す。
func TestMoveFieldsFinishRemovesOnlyUnreadFieldsFromWorld(t *testing.T) {
	root := fixtureRoot(t, "movefields")
	if code, out, _ := runMoveFields(t, root, "move-fields", "--labels", "deckScroll,deckOpen", "--receiver", "World.World",
		"--into-case", "World.Scene.Deck", "--apply"); code != 0 {
		t.Fatalf("写す段の終了コード %d:\n%s", code, out)
	}
	before := read(t, root, "src/World.flix")
	code, out, cmds := runMoveFields(t, root, "move-fields", "--labels", "deckScroll,deckOpen", "--receiver", "World.World",
		"--into-case", "World.Scene.Deck", "--finish", "--apply")
	if code != 2 || len(cmds) != 0 || read(t, root, "src/World.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out, "src/World.flix:21:43")
	code, out, _ = runMoveFields(t, root, "move-fields", "--labels", "deckOpen", "--receiver", "World.World",
		"--into-case", "World.Scene.Deck", "--finish", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/World.flix"),
		"pub type alias World = { scene = Scene, deckScroll = Int32, hp = Int32, mode = Mode }",
		"pub def initial(): World = { scene = Scene.Title, deckScroll = 0, hp = 10, mode = Mode.Off }")
}

// World の組み立てから写す値は、書く所の mod で書ける形にする（Menu の中は Mode.Off → World.Mode.Off・World の中はそのまま）。
// payload の組み立ては別の mod（Menu）にもある。
func TestMoveFieldsQualifiesTheCopiedValueInOtherMods(t *testing.T) {
	root := fixtureRoot(t, "movefields")
	code, out, _ := runMoveFields(t, root, "move-fields", "--labels", "mode", "--receiver", "World.World",
		"--into-case", "World.Scene.Deck", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/World.flix"), "pub type alias DeckUi = { cursor = Int32, mode = Mode }", "Scene.Deck({ cursor = 0, mode = Mode.Off })")
	mustContain(t, read(t, root, "src/Menu.flix"), "World.Scene.Deck({ cursor = 1, mode = World.Mode.Off })")
}

// remove-field --case は、flixlint の typed の索引が出す case の受け手（owner=case:Panel.Open#1）もその case の物として数える
// （--case に #i を書かなければ、その case のどの場所にも当たる）。扱いの表の分類で引く。
func TestCaseReceiverMatchesTheCaseWithOrWithoutThePosition(t *testing.T) {
	open := OwnerTarget{Case: "Panel.Open"}
	if (FieldSite{Recv: "case:Panel.Open#1"}).Class(open) != ClassHit || (FieldSite{Recv: "case:Shape.Panel.Open"}).Class(open) != ClassHit ||
		(FieldSite{Recv: "case:Panel.Closed"}).Class(open) != ClassMiss {
		t.Fatal("case の受け手の当て方が違う")
	}
}
