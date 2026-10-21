package refactor

import (
	"io"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/prefer は呼ぶ所・作る所に書く式の代わりに局所の名前を使う（設計 §9）と add-field（§10）のお手本。
// testdata/prefer-spans-resolved.tsv は flixlint 0.7.1 の --spans --stage resolved と同じ形の行を、ソースの字の位置から
// 手で作った物（この Mac に 0.7 の flixlint が無いため。行の種類と extra の形は sigprep の索引に合わせた）。
// 期待の字は「前の let か、呼ぶ所が全部同じ式を渡す引数なら名前・型だけ同じなら式のまま候補に数える」の規則から手で書いた。

func runPrefer(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")),
		Options{Run: spansRunner("prefer"), Verify: verifyWith(0, "", &cmds), Log: io.Discard})
	return code, out.String() + errOut.String()
}

var handArgs = []string{"change-signature", "--def", "Hand.hand", "--params", "ctx, env: View.Env, w", "--args", "ctx, View.bareOf(w), w"}

// 前の let（withLet）と、呼ぶ所が全部 View.bareOf(w) を渡す引数（entry）は名前を書く。型だけ同じ引数（other）は
// 式のまま書いて候補に数え、別の match の腕の let（arms）は使わない。
func TestSignatureWritesTheLocalWithTheSameValue(t *testing.T) {
	root := fixtureRoot(t, "prefer")
	code, out := runPrefer(t, root, append(handArgs, "--apply")...)
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Screen.flix"),
		"        let env = View.bareOf(w);\n        Hand.hand(ctx, env, w) + env#scale\n",
		"    pub def entry(ctx: Int32, env: Env, w: World): Int32 =\n        Hand.hand(ctx, env, w) + env#scale\n",
		"    pub def other(ctx: Int32, env: Env, w: World): Int32 =\n        Hand.hand(ctx, View.bareOf(w), w) + env#scale\n",
		"        case false => Hand.hand(ctx, View.bareOf(w), w)\n")
	mustContain(t, out, "局所の名前を書く 2 か所",
		"→ 0 left · check ok\n局所の候補あり 1 か所（--prefer-local で使う）\n")
}

// --prefer-local は型が同じ候補が 1 つの所（other の env）も名前を書く。
func TestSignaturePreferLocalUsesTheOnlyCandidate(t *testing.T) {
	root := fixtureRoot(t, "prefer")
	code, out := runPrefer(t, root, append(handArgs, "--prefer-local", "--apply")...)
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Screen.flix"), "    pub def other(ctx: Int32, env: Env, w: World): Int32 =\n        Hand.hand(ctx, env, w) + env#scale\n",
		"        case false => Hand.hand(ctx, View.bareOf(w), w)\n")
	mustContain(t, out, "--prefer-local で局所の候補を書く 1 か所")
	if strings.Contains(out, "局所の候補あり") {
		t.Errorf("候補を使った後に候補ありと言う:\n%s", out)
	}
}

// add-field: 型の --after の位置と、組み立ての同じ位置に足す（1 行・1 欄ずつの行・前の let と同じ式は名前）。
// 型だけ同じ引数（given の env）は式のまま書いて候補に数える。
func TestAddFieldAddsToTheTypeAndEveryConstruction(t *testing.T) {
	root := fixtureRoot(t, "prefer")
	code, out := runPrefer(t, root, "add-field", "--receiver", "Rec.Panel", "--label", "env", "--type", "View.Env",
		"--value", "View.bareOf(w)", "--after", "open", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Rec.flix"),
		"pub type alias Panel = { open = Bool, env = View.Env, size = Int32 }",
		"{ open = false, env = View.bareOf(w), size = w#speed }",
		"        open = true,\n        env = View.bareOf(w),\n        // the size of the panel\n        size = w#speed\n",
		"{ open = true, env = env, size = env#scale }",
		"{ open = true, env = View.bareOf(w), size = w#speed + env#scale }")
	mustContain(t, out, "型に足す 1（src/Rec.flix:4:28・open の次）・組み立てに足す 4・人へ回す 0",
		"done: 5 sites（型 1・組み立て 4）→ 0 left · check ok\n局所の候補あり 1 か所（--prefer-local で使う）\n")
}

// dry-run が既定（書かない）で、next は --apply。欄がもうあれば止める。
func TestAddFieldIsDryRunByDefaultAndRefusesAnExistingField(t *testing.T) {
	root := fixtureRoot(t, "prefer")
	before := read(t, root, "src/Rec.flix")
	code, out := runPrefer(t, root, "add-field", "--receiver", "Rec.Panel", "--label", "env", "--type", "View.Env", "--value", "View.bareOf(w)")
	if code != 0 || read(t, root, "src/Rec.flix") != before {
		t.Fatalf("dry-run で書いた（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out, "next: bin/fge refactor add-field --receiver Rec.Panel --label env --type View.Env --value 'View.bareOf(w)' --apply")
	code, out = runPrefer(t, root, "add-field", "--receiver", "Rec.Panel", "--label", "size", "--type", "Int32", "--value", "0")
	if code != 2 {
		t.Fatalf("もうある欄で止まらない（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out, "欄 size はもうある")
}

// --after の欄が 1 行に並ぶ式では同じ行に、最後の欄なら最後に足す。
func TestInsertRecordFieldKeepsTheLayout(t *testing.T) {
	for _, c := range []struct{ text, after, want string }{
		{"{ a = 1, b = 2 }", "a", "{ a = 1, x = 9, b = 2 }"},
		{"{ a = 1, b = 2 }", "b", "{ a = 1, b = 2, x = 9 }"},
		{"{\n    a = 1,\n    b = 2\n}", "a", "{\n    a = 1,\n    x = 9,\n    b = 2\n}"},
	} {
		got, err := InsertRecordField(c.text, "x", "9", c.after)
		must(t, err)
		if got != c.want {
			t.Errorf("%q の %s の次: got %q（want %q）", c.text, c.after, got, c.want)
		}
	}
}
