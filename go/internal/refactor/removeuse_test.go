package refactor

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 使っていない use の字の消し方: 波括弧の中なら名前を 1 つ（区切りは元の形のまま）、全部消えれば行ごと、
// 波括弧の無い use・import も行ごと。同じ行に別の物があれば消さない。
func TestRemoveUseEditShapes(t *testing.T) {
	for _, c := range []struct {
		name, src string
		line      int
		names     []string
		want      string
	}{
		{"波括弧の真ん中", "mod M {\n    use A.{b, c, d}\n}\n", 2, []string{"A.c"}, "mod M {\n    use A.{b, d}\n}\n"},
		{"波括弧の最後", "mod M {\n    use A.{b, c}\n}\n", 2, []string{"A.c"}, "mod M {\n    use A.{b}\n}\n"},
		{"波括弧の頭と別名", "mod M {\n    use A.{b => x, c}\n}\n", 2, []string{"A.b"}, "mod M {\n    use A.{c}\n}\n"},
		{"折った波括弧", "mod M {\n    use fge::{\n        App, GifEncoder, Num\n    }\n}\n", 2, []string{"GifEncoder"},
			"mod M {\n    use fge::{\n        App, Num\n    }\n}\n"},
		{"折った波括弧の中の行（lint は名前の行を言う）", "mod M {\n    use fge::{\n        App, GifEncoder, Num\n    }\n}\n", 3, []string{"$pkg$fge.Num"},
			"mod M {\n    use fge::{\n        App, GifEncoder\n    }\n}\n"},
		{"全部消えれば行ごと", "mod M {\n    use A.{b, c}\n    use D.e\n}\n", 2, []string{"A.b", "A.c"}, "mod M {\n    use D.e\n}\n"},
		{"import は行ごと・後ろの空行も", "mod M {\n    import java.io.File\n\n    def f(): Int32 = 1\n}\n", 2, []string{"java.io.File"},
			"mod M {\n    def f(): Int32 = 1\n}\n"},
		{"空行の間の use は空行を 1 つに", "mod M {\n    use A.b\n\n    use C.d\n\n    def f(): Int32 = 1\n}\n", 4, []string{"C.d"},
			"mod M {\n    use A.b\n\n    def f(): Int32 = 1\n}\n"},
	} {
		e, err := removeUseEdit(c.src, "src/M.flix", c.line, c.names)
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		got, err := ApplyEdits(c.src, []Edit{e})
		if err != nil || got != c.want {
			t.Errorf("%s: got %q（%v）want %q", c.name, got, err, c.want)
		}
	}
	if _, err := removeUseEdit("mod M { use A.b }\n", "src/M.flix", 1, []string{"A.b"}); err == nil {
		t.Errorf("同じ行に別の物がある use を消した")
	}
	if _, err := removeUseEdit("mod M {\n    use A.{b, c}\n}\n", "src/M.flix", 2, []string{"A.z"}); err == nil {
		t.Errorf("波括弧に無い名前で消した")
	}
}

// flixlint の出力から unused-use の違反だけを読む。
func TestParseUnusedUsesReadsOnlyTheRule(t *testing.T) {
	got := parseUnusedUses("flixlint: note: x\nsrc/B.flix:3: unused-use: B: brings in java.io.File, which the module never uses\n" +
		"    remove\nsrc/A.flix:2: other-rule: A: x\nsrc/A.flix:2: unused-use: A: brings in Auth.Permit, which the module never uses\n")
	if len(got) != 2 || got[0] != (UseFinding{"src/A.flix", 2, "A", "Auth.Permit"}) || got[1].Name != "java.io.File" {
		t.Errorf("got %+v", got)
	}
}

// unusedLintRunner は索引を置き、--rules の流しでは lines を出力（ログ）に書く Runner。
func unusedLintRunner(name string, lines string) Runner {
	spans := spansRunner(name)
	return func(stage Stage, desc, dir string, cmd []string, log string) int {
		for _, c := range cmd {
			if c == "--rules" {
				os.WriteFile(log, []byte(lines), 0o644)
				if lines == "" {
					return 0
				}
				return 1
			}
		}
		return spans(stage, desc, dir, cmd, log)
	}
}

func runRemoveUse(t *testing.T, root, lint string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")),
		Options{Run: unusedLintRunner("refmore", lint), Verify: verifyWith(0, "", &cmds), Log: io.Discard,
			Version: func(string) string { return "flixlint " + MinFlixlint }})
	return code, out.String() + errOut.String()
}

// remove-use は flixlint の unused-use の違反の行の名前を消し、done で言い切る。usages --unused も同じ判定を数える。
func TestRemoveUseRemovesWhatTheLintReports(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	lint := "src/B.flix:2: unused-use: B: brings in A.onlyUsed, which the module never uses\n"
	code, out := runRemoveUse(t, root, lint, "usages", "--unused")
	if code != 0 || !strings.Contains(out, "使っていない use 1") {
		t.Fatalf("usages --unused が lint の判定を数えない（%d）:\n%s", code, out)
	}
	code, out = runRemoveUse(t, root, lint, "remove-use", "src/B.flix:2", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/B.flix"), "    use A.{keep}\n")
	mustContain(t, out, "done: 1 names → 消した · check ok")
}

// 行も --all も無ければ、何を消すかを言って止まる。
func TestRemoveUseNeedsALineOrAll(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	if code, out := runRemoveUse(t, root, "", "remove-use", "src/B.flix"); code != 2 || !strings.Contains(out, "--all") {
		t.Errorf("止まらない（%d）:\n%s", code, out)
	}
}
