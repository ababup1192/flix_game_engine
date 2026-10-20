package videoentries

// 何を守るか: 入口の正はレシピの $(call video,…) の行だけ（# で止めた行・レシピの外は数えない）、
// \ で続けた行をつなぐこと、+= で足し := で置き直すこと、extra を足し skip を除くこと、
// 同じ入口は 1 回、--check が食い違いと読めない行で止めること、動画の口が無いゲームは通すこと。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func rules() *Rules {
	return (&Rules{Makefile: "Makefile", Out: "src/E.flix", Module: "E", Macro: "video", ExtraVar: "EXTRA", SkipVar: "SKIP"}).compilePatterns()
}

const makefile = "" +
	"EXTRA := M.frames\n" +
	"SKIP := A.custom\n" +
	"SKIP += A.other\n" +
	"a:\n" +
	"\t$(call video,A.frames,a,60,--mute)\n" +
	"\t# $(call video,A.commented,a,60,)\n" +
	"\t$(call video,A.custom,a,60,)\n" +
	"b:\n" +
	"\tFOO=1 \\\n" +
	"\t$(call video,B.long,b,30,)\n" +
	"\t$(call video,A.frames,again,60,)\n" +
	"# $(call video,Top.level,x,1,)\n"

func TestEntriesFollowRecipeOrderWithExtraAndSkip(t *testing.T) {
	got := strings.Join(rules().Entries(makefile), " ")
	if got != "A.frames B.long M.frames" {
		t.Fatalf("got %q", got)
	}
}

func TestVariablePlusEqualsAppendsAndAssignResets(t *testing.T) {
	got := strings.Join(Variable("X := a\nX += b\nX = c\nX += d\n", "X"), " ")
	if got != "c d" {
		t.Fatalf("got %q", got)
	}
}

func repo(t *testing.T, mk, out string) string {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "bin", "lint-rules"), 0o755)
	os.MkdirAll(filepath.Join(root, "src"), 0o755)
	os.WriteFile(filepath.Join(root, "bin", "lint-rules", "video-entries.json"),
		[]byte(`{"makefile":"Makefile","out":"src/E.flix","module":"E","macro":"video","extraVar":"EXTRA","skipVar":"SKIP"}`), 0o644)
	os.WriteFile(filepath.Join(root, "Makefile"), []byte(mk), 0o644)
	if out != "" {
		os.WriteFile(filepath.Join(root, "src", "E.flix"), []byte(out), 0o644)
	}
	return root
}

func TestCheckFailsUntilWrittenThenPasses(t *testing.T) {
	root := repo(t, makefile, "")
	var out strings.Builder
	before, _ := Run(&out, root, true)
	Run(&out, root, false)
	after, _ := Run(&out, root, true)
	if before != 1 || after != 0 {
		t.Fatalf("before=%d after=%d out=%s", before, after, out.String())
	}
}

func TestCheckStopsOnUnreadableCall(t *testing.T) {
	mk := "a:\n\t$(call video,$(ENTRY),a,60,)\n\t$(call video,A.frames,a,60,)\n"
	root := repo(t, mk, rules().Render([]string{"A.frames"}))
	var out strings.Builder
	code, _ := Run(&out, root, true)
	if code != 1 || !strings.Contains(out.String(), "入口を読めない") {
		t.Fatalf("code=%d out=%s", code, out.String())
	}
}

func TestRecipeCallsSkipsMacroWithSameHead(t *testing.T) {
	mk := "define video\n" +
		"\tVIDEO_MAKE=$@ $(call video-mix-env,$(2),$(3)) run $(1)\n" +
		"endef\n" +
		"a:\n\t$(call video,A.frames,a,60,)\n"
	got := strings.Join(rules().RecipeCalls(mk), "|")
	if got != "\t$(call video,A.frames,a,60,)" {
		t.Fatalf("got %q", got)
	}
}

func TestCallOfMacroWithSameHeadIsNotAnEntry(t *testing.T) {
	mk := "mix-env = MIX=\"$(1)\"\n" +
		"define video\n" +
		"\tVIDEO_MAKE=$@ $(call video-mix-env,$(2),$(3)) run $(1)\n" +
		"endef\n" +
		"a:\n\t$(call video,A.frames,a,60,)\n"
	root := repo(t, mk, rules().Render([]string{"A.frames"}))
	var out strings.Builder
	code, _ := Run(&out, root, true)
	if code != 0 {
		t.Fatalf("code=%d out=%s", code, out.String())
	}
}

func TestGameWithoutVideosPasses(t *testing.T) {
	root := repo(t, "a:\n\techo hi\n", "")
	var out strings.Builder
	code, err := Run(&out, root, true)
	if err != nil || code != 0 {
		t.Fatalf("code=%d err=%v", code, err)
	}
}

func TestLocalOverridesOnlyWrittenKeys(t *testing.T) {
	root := repo(t, makefile, "")
	os.WriteFile(filepath.Join(root, "bin", "lint-rules", "video-entries.local.json"), []byte(`{"module":"Other"}`), 0o644)
	r, err := LoadRules(root)
	if err != nil || r.Module != "Other" || r.Out != "src/E.flix" {
		t.Fatalf("r=%+v err=%v", r, err)
	}
}
