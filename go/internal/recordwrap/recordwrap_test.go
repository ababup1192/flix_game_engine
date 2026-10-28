package recordwrap

// 何を守るか: 大きさを欄の数でなく入れ子と型引数の中まで展開して数えること、enum で包んだ所で
// 数えるのが止まること、threshold の手前は鳴らさないこと、名指しのファイルが関わる時だけ出すこと、
// 除外と --warn の扱い。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const pkg = `mod Grp {
    pub type alias Rec = { a = Float64, b = Float64, c = Float64 }
}
mod Big {
    // 欄は 2 つだが、中身まで数えると 2 + 3 + 3 = 8
    pub type alias Rec = { left = Grp.Rec, right = Grp.Rec }
    pub enum Doc(Rec)
}
mod Track {
    pub type alias Beat = { at = Float64, z = Int32 }
    pub type alias Track = { beats = List[Beat], name = String }
}
mod World {
    pub type alias World = {
        big = Big.Rec,
        boxed = Big.Doc,
        track = Option[Track.Track],
        t = Float64
    }
}
`

func hitsOf(threshold int) map[string]int {
	got := map[string]int{}
	for _, h := range PackageHits(ParseAliases("src/Main.flix", pkg), []string{"World.World"}, threshold) {
		got[h.Field] = h.Size
	}
	return got
}

func TestSizeCountsNestedRecordsAndTypeArguments(t *testing.T) {
	got := hitsOf(1)
	if got["big"] != 8 || got["track"] != 4 {
		t.Fatalf("got %v", got)
	}
}

func TestWrappedFieldIsNotCounted(t *testing.T) {
	if _, ok := hitsOf(1)["boxed"]; ok {
		t.Fatalf("包んだ欄が鳴った: %v", hitsOf(1))
	}
}

func TestBelowThresholdIsQuiet(t *testing.T) {
	got := hitsOf(5)
	if len(got) != 1 || got["big"] != 8 {
		t.Fatalf("got %v", got)
	}
}

func TestHitLineIsTheFieldLine(t *testing.T) {
	for _, h := range PackageHits(ParseAliases("src/Main.flix", pkg), []string{"World.World"}, 5) {
		if h.Line != 15 {
			t.Fatalf("行 %d (期待 15)", h.Line)
		}
	}
}

func writeRepo(t *testing.T, exempt string) string {
	t.Helper()
	root := t.TempDir()
	put := func(rel, body string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	put("bin/lint-rules/record-wrap.json", `{"scopeSuffixes":[".flix"],"skipPrefixes":["testdata/"],`+
		`"skipDirNames":["lib","test"],"roots":["World.World"],"threshold":5,"exempt":`+exempt+`,`+
		`"worldShape":{"resourceTypes":["\\.Doc$"],"maxTopFields":4},"exemptRules":{}}`)
	put("game/flix.toml", "")
	put("game/src/Big.flix", "mod Big {\n    pub type alias Rec = { a = Float64, b = Float64, c = Float64, d = Float64, e = Float64 }\n}\n")
	put("game/src/World.flix", "mod World {\n    pub type alias World = { big = Big.Rec, t = Float64 }\n}\n")
	put("game/src/View.flix", "mod View {\n    pub def f(): Int32 = 1\n}\n")
	return root
}

func TestNamedFileReportsOnlyWhenItIsInvolved(t *testing.T) {
	root := writeRepo(t, `{}`)
	var out, errOut strings.Builder
	if code, _ := Run(&out, &errOut, root, []string{"game/src/View.flix"}); code != 0 {
		t.Fatalf("関わらないファイルで鳴った: %s", errOut.String())
	}
	out.Reset()
	errOut.Reset()
	code, _ := Run(&out, &errOut, root, []string{"game/src/Big.flix"})
	if code != 1 || !strings.Contains(errOut.String(), "game/src/World.flix:2 big = Big.Rec (展開すると 5)") {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}

func TestExemptSilencesAndStaleExemptFires(t *testing.T) {
	root := writeRepo(t, `{"World.World::big":"試しに残す","World.World::gone":"消えた"}`)
	var out, errOut strings.Builder
	code, _ := Run(&out, &errOut, root, []string{"--all"})
	if code != 1 || strings.Contains(errOut.String(), "big = ") || !strings.Contains(errOut.String(), "World.World::gone は exempt") {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}

func TestWarnExitsZero(t *testing.T) {
	root := writeRepo(t, `{}`)
	var out, errOut strings.Builder
	if code, _ := Run(&out, &errOut, root, []string{"--warn", "--all"}); code != 0 || !strings.Contains(errOut.String(), "big = ") {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}
