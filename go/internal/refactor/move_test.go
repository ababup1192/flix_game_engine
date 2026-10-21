package refactor

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/move は move のお手本（src/Shapes.flix の doc に形の説明）。testdata/move-spans-resolved.tsv はそれに
// flixlint 0.7.1 の --spans --stage resolved src test を掛けた物。期待の字は「移した名前を指す所は全部新しい mod を指す・
// 本体の中の名前は移した後も同じ物を指す」の規則から手で書いた物。

func runMove(t *testing.T, root string, verify int, args ...string) (int, string, []string) {
	t.Helper()
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, append(append([]string{"move"}, args...), "--flixlint", filepath.Join(root, "flixlint")),
		Options{Run: spansRunner("move"), Verify: verifyWith(verify, "src/Geometry.flix:5:1 error", &cmds), Log: io.Discard})
	return code, out.String() + errOut.String(), cmds
}

// 修飾名（Draw・テスト）・同じ mod の中の素の名前（total・scaled）・use の波括弧（Panel）・1 つだけの use（Tile）・
// 別名の use（Badge）・移し先の中の修飾名（Geometry.unitArea）を全部直し、本体の型 Rect は元の mod の修飾名に、
// 本体が use で入れた px は use ごと移す（元の mod ではもう使わないので消す）。
func TestMoveRewritesEveryKindOfCaller(t *testing.T) {
	root := fixtureRoot(t, "move")
	code, out, cmds := runMove(t, root, 0, "--def", "Shapes.area", "--to", "Geometry", "--apply")
	if code != 0 || len(cmds) != 1 {
		t.Fatalf("終了コード %d・確かめ %d 回:\n%s", code, len(cmds), out)
	}
	if got, want := read(t, root, "src/Geometry.flix"), "/// 移し先（もうある mod）。移す def を修飾名で呼ぶ所もある。\n"+
		"mod Geometry {\n    use Units.{px}\n\n    pub def origin(): Int32 = 0\n\n    pub def unitArea(): Int32 = area({ w = 1, h = 1 })\n\n"+
		"    /// 面積（px）。\n    pub def area(r: Shapes.Rect): Int32 = px(r#w * r#h)\n}\n"; got != want {
		t.Errorf("移し先:\n%s\nwant:\n%s", got, want)
	}
	shapes := read(t, root, "src/Shapes.flix")
	mustContain(t, shapes, "mod Shapes {\n    pub type alias Rect",
		"    pub def perimeter(r: Rect): Int32 = 2 * (r#w + r#h)\n\n    pub def total(r: Rect): Int32 = Geometry.area(r) + perimeter(r)\n",
		"pub def scaled(r: Rect): Int32 = Geometry.area(r) * scale()")
	for _, gone := range []string{"面積", "use Units", "def area"} {
		if strings.Contains(shapes, gone) {
			t.Errorf("元の mod に %q が残る:\n%s", gone, shapes)
		}
	}
	mustContain(t, read(t, root, "src/Draw.flix"), "Geometry.area(r) + Shapes.total(r)")
	mustContain(t, read(t, root, "src/Panel.flix"), "mod Panel {\n    use Shapes.{perimeter}\n    use Geometry.{area}\n\n")
	mustContain(t, read(t, root, "src/Tile.flix"), "    use Geometry.area\n")
	mustContain(t, read(t, root, "src/Badge.flix"), "mod Badge {\n    use Geometry.{area => size}\n\n    pub def badge(r: Shapes.Rect): Int32 = size(r)\n")
	mustContain(t, read(t, root, "test/TestMove.flix"), "pub def areaOfTwoByThree(): Int32 = Geometry.area({ w = 2, h = 3 })")
	mustContain(t, out, "移す宣言 1（→ src/Geometry.flix）・呼ぶ所 5（4 ファイル）・use 3・本体の中の名前 1・人へ回す 0",
		"use を足す: 3（Geometry.{area => size} → src/Badge.flix・Geometry.{area} → src/Panel.flix・Units.{px} → src/Geometry.flix）",
		"元の mod で使わなくなった use を消す: px（src/Shapes.flix）",
		"done: 9 sites（移した宣言 1・呼ぶ所 5・use 3）→ 0 left · check ok",
		"next: bin/fge refactor usages Geometry.area --callers")
}

// 移し先の mod がどこにも無ければ src/<mod>.flix を作る。2 つを 1 回で移すと use の波括弧から両方外して行ごと消す。
// 確かめが落ちれば、作ったファイルを消して元の中身へ戻す。
func TestMoveCreatesTheTargetModuleAndRevertsIt(t *testing.T) {
	root := fixtureRoot(t, "move")
	before := read(t, root, "src/Shapes.flix")
	code, out, _ := runMove(t, root, 1, "--def", "Shapes.area,Shapes.perimeter", "--to", "Layout", "--apply")
	if code != 1 || !strings.Contains(out, "reverted") {
		t.Fatalf("戻すはず（終了コード %d）:\n%s", code, out)
	}
	if _, err := os.Stat(filepath.Join(root, "src", "Layout.flix")); !os.IsNotExist(err) {
		t.Errorf("作ったファイルが戻した後も残る: %v", err)
	}
	if read(t, root, "src/Shapes.flix") != before {
		t.Errorf("元の中身へ戻っていない")
	}
	code, out, _ = runMove(t, root, 0, "--def", "Shapes.area,Shapes.perimeter", "--to", "Layout", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	if got, want := read(t, root, "src/Layout.flix"), "mod Layout {\n    use Units.{px}\n\n    /// 面積（px）。\n"+
		"    pub def area(r: Shapes.Rect): Int32 = px(r#w * r#h)\n\n    pub def perimeter(r: Shapes.Rect): Int32 = 2 * (r#w + r#h)\n}\n"; got != want {
		t.Errorf("作った mod:\n%s\nwant:\n%s", got, want)
	}
	mustContain(t, read(t, root, "src/Panel.flix"), "mod Panel {\n    use Layout.{area, perimeter}\n\n")
	mustContain(t, read(t, root, "src/Shapes.flix"), "pub def total(r: Rect): Int32 = Layout.area(r) + Layout.perimeter(r)\n")
	mustContain(t, out, "src/Layout.flix を作る")
}

// 移す def が元の mod の非 pub の def を使えば書かずに止め、--with で一緒に移すコマンドを next に出す。--with を付ければ
// 2 つを移し、非 pub のまま移し先の中で使う。
func TestMoveHandsNonPublicDependenciesToAPerson(t *testing.T) {
	root := fixtureRoot(t, "move")
	code, out, cmds := runMove(t, root, 0, "--def", "Shapes.scaled", "--to", "Geometry", "--apply")
	if code != 2 || len(cmds) != 0 {
		t.Fatalf("書かずに断るはず（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out, "src/Shapes.flix:18:48", "元の mod の非 pub の Shapes.scale を使う。--with Shapes.scale で一緒に移すか、Shapes.scale を pub にする（Shapes.scaled）",
		"next: bin/fge refactor move --def Shapes.scaled --to Geometry --with Shapes.scale")
	code, out, _ = runMove(t, root, 0, "--def", "Shapes.scaled", "--to", "Geometry", "--with", "Shapes.scale", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Geometry.flix"), "    def scale(): Int32 = 2\n\n    pub def scaled(r: Shapes.Rect): Int32 = Shapes.area(r) * scale()\n}\n")
	shapes := read(t, root, "src/Shapes.flix")
	mustContain(t, shapes, "    pub def total(r: Rect): Int32 = area(r) + perimeter(r)\n\n    def unit(): Int32 = 1\n")
}

// --def の非 pub の def を元の mod の中だけで使うなら、移す意味が無いので止める。
func TestMoveRefusesAPrivateDefUsedOnlyInItsModule(t *testing.T) {
	root := fixtureRoot(t, "move")
	code, out, _ := runMove(t, root, 0, "--def", "Shapes.unit", "--to", "Geometry", "--apply")
	if code != 2 {
		t.Fatalf("断るはず（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out, "非 pub の Shapes.unit は元の mod の中だけで使う物（Shapes.one）で、移す意味が無い")
}

// 型 alias も移せる: 宣言の行を切り、型の注記（元の mod の中の素の Rect・外の Shapes.Rect）を新しい mod の名前に。
func TestMoveMovesATypeAlias(t *testing.T) {
	root := fixtureRoot(t, "move")
	code, out, _ := runMove(t, root, 0, "--def", "Shapes.Rect", "--to", "Geometry", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Geometry.flix"), "    pub type alias Rect = { w = Int32, h = Int32 }\n}\n")
	shapes := read(t, root, "src/Shapes.flix")
	mustContain(t, shapes, "    use Units.{px}\n\n    /// 面積（px）。\n    pub def area(r: Geometry.Rect): Int32", "pub def total(r: Geometry.Rect)")
	mustContain(t, read(t, root, "src/Draw.flix"), "pub def draw(r: Geometry.Rect)")
}

// 移し先に同じ名前があれば止める（索引の宣言の行で見る）。
func TestMoveStopsOnANameClash(t *testing.T) {
	rows, err := ReadIndex(filepath.Join("testdata", "move-spans-resolved.tsv"), Resolved)
	must(t, err)
	rows = append(rows, Row{Kind: KindDefDecl, File: "src/Geometry.flix", Line: 3, Col: 13, EndLine: 3, EndCol: 19, Sym: "Geometry.area", Owner: "Geometry.area", Extra: "pub ext=3:5:3:32"})
	root := fixtureRoot(t, "move")
	_, err = PlanMove(rows, &reshapeSources{root: root, m: map[string]string{}}, MoveQuery{Defs: []string{"Shapes.area"}, To: "Geometry"})
	if err == nil || !strings.Contains(err.Error(), "移し先に同じ名前がある: Geometry.area（src/Geometry.flix:3:13）") {
		t.Fatalf("止まるはず: %v", err)
	}
}

// 本物の flixlint と flix で、お手本の area を Geometry へ移して flix check が通るか（FGE_REFACTOR_E2E=1 の時だけ）。
func TestEndToEndMove(t *testing.T) {
	if os.Getenv("FGE_REFACTOR_E2E") == "" {
		t.Skip("FGE_REFACTOR_E2E=1 の時だけ（本物の flixlint と flix を流す）")
	}
	jar, fl := os.Getenv("FLIX_JAR"), os.Getenv("FGE_FLIXLINT")
	for _, c := range [][]string{
		{"--def", "Shapes.area", "--to", "Geometry"},
		{"--def", "Shapes.area,Shapes.perimeter", "--to", "Layout"},
		{"--def", "Shapes.scaled", "--to", "Geometry", "--with", "Shapes.scale"},
		{"--def", "Shapes.Rect", "--to", "Geometry"},
	} {
		root := fixtureRoot(t, "move")
		must(t, os.MkdirAll(filepath.Join(root, "bin", "lint-rules"), 0o755))
		must(t, os.WriteFile(filepath.Join(root, "bin", "lint-rules", "refactor.local.json"), []byte(`{"verify": "java -jar `+jar+` check"}`), 0o644))
		direct := func(_ Stage, _, dir string, cmd []string, _ string) int {
			x := exec.Command(cmd[0], cmd[1:]...)
			x.Dir, x.Stderr = dir, os.Stderr
			if x.Run() != nil {
				return 1
			}
			return 0
		}
		verify := func(cmd, dir, log string) int {
			x := exec.Command("sh", "-c", cmd+" > '"+log+"' 2>&1")
			x.Dir = dir
			if x.Run() != nil {
				return 1
			}
			return 0
		}
		var out, errOut strings.Builder
		code := Run(&out, &errOut, root, append(append([]string{"move"}, c...), "--apply", "--flixlint", fl), Options{Run: direct, Verify: verify, Log: io.Discard})
		if code != 0 || !strings.Contains(out.String(), "applied") {
			t.Errorf("%v: exit %d\n%s%s", c, code, out.String(), errOut.String())
		}
	}
}

// コンパイラの宣言の範囲が後ろの節の見出しのコメントまで含んでも（ゲームの Broadcast.scaled の ext=16:5:19:27）、
// 切り出すのは doc と宣言の行だけ。見出しは元の場所に残す。
func TestDeclLinesLeavesTheNextSectionsComment(t *testing.T) {
	src := "mod M {\n    /// 倍率。\n    pub def scaled(x: Float64): Float64 =\n        x * 2.0\n\n    // ── 次の節 ──\n\n    pub def next(): Int32 = 1\n}\n"
	row := Row{File: "src/M.flix", Line: 3, Col: 13, EndLine: 3, EndCol: 19}
	_, text, err := declLines(src, Row{File: "src/M.flix", Line: 2, Col: 5, EndLine: 6, EndCol: 16}, row)
	must(t, err)
	if got, want := src[text[0]:text[1]], "    /// 倍率。\n    pub def scaled(x: Float64): Float64 =\n        x * 2.0\n"; got != want {
		t.Errorf("切り出し %q（want %q）", got, want)
	}
}

// 索引に行の無い名前（型の所に書いた効果 `\ Emit[…]` など。ここでは戻りの型の Meter で写す）を移す字が使えば、
// 元の mod の use も移し先へ写す（VideoKit.readIfWaiting を WorldSetup へ移した時に use fge::Emit が足りず戻った物）。
func TestMoveCopiesTheUseOfANameTheIndexDoesNotRow(t *testing.T) {
	root := fixtureRoot(t, "move")
	shapes := read(t, root, "src/Shapes.flix")
	shapes = strings.Replace(shapes, "    use Units.{px}", "    use Units.{px, Meter}", 1)
	shapes = strings.Replace(shapes, "pub def area(r: Rect): Int32 = px(r#w * r#h)", "pub def area(r: Rect): Meter = px(r#w * r#h)", 1)
	must(t, os.WriteFile(filepath.Join(root, "src/Shapes.flix"), []byte(shapes), 0o644))
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-am", "Meter")
	tsv, err := os.ReadFile(filepath.Join("testdata", "move-spans-resolved.tsv"))
	must(t, err)
	// Meter の use の行はあるが、戻りの型の Meter を指す行は無い（効果の名前を索引が持たないのと同じ形）。
	rows := string(tsv) + "use\tsrc/Shapes.flix\t5\t20\t5\t25\tUnits.Meter\tShapes\talias=Meter what=type\n"
	run := func(_ Stage, _, _ string, cmd []string, _ string) int {
		for i := 0; i+1 < len(cmd); i++ {
			if cmd[i] == "--spans" && os.WriteFile(cmd[i+1], []byte(rows), 0o644) != nil {
				return 4
			}
		}
		return 0
	}
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, []string{"move", "--def", "Shapes.area", "--to", "Geometry", "--apply", "--flixlint", filepath.Join(root, "flixlint")},
		Options{Run: run, Verify: verifyWith(0, "", &cmds), Log: io.Discard})
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s%s", code, out.String(), errOut.String())
	}
	geo := read(t, root, "src/Geometry.flix")
	if !strings.Contains(geo, "Meter") || !strings.Contains(geo, "pub def area(r: Shapes.Rect): Meter") {
		t.Fatalf("移し先に Meter の use を足していない:\n%s", geo)
	}
	use := geo[strings.Index(geo, "use Units"):]
	if !strings.Contains(use[:strings.Index(use, "\n")], "Meter") {
		t.Fatalf("Meter を use の文で入れていない:\n%s", geo)
	}
}
