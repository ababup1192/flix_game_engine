package recordwrap

// 何を守るか: world-resource が型エイリアスとパッケージ内の enum の payload (何 case でも) までたどって
// Doc を見つけること、List・Option などの型引数の中は見ないこと、World そのものを 1 case の enum で
// 包んでも中の record を見ること、world-fields が上限を超えた時だけ鳴ること、exemptRules を配る側と local から足して読むこと、古い除外を --all で止めること、
// このリポに無いファイルの除外は古いと数えないこと。

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const worldPkg = `mod Theme {
    pub type alias Doc = { bg = Int32 }
}
mod Res {
    pub type alias Docs = { theme = Theme.Doc, n = Int32 }
    pub enum Boxed(Docs)
    pub enum Block { case Block(Theme.Doc) }
    pub enum Screen { case Title(Theme.Doc), case Play(Int32) }
    pub enum Flag { case On, Off }
}
mod Enemy {
    pub type alias Enemy = { kind = Theme.Doc }
}
mod World {
    pub type alias World = {
        docs = Res.Docs,
        boxed = Res.Boxed,
        block = Res.Block,
        screen = Res.Screen,
        flag = Res.Flag,
        enemies = List[Enemy.Enemy],
        picked = Option[Theme.Doc],
        pair = (Int32, Theme.Doc),
        t = Float64
    }
}
`

func worldHitsOf(max int) map[string]Hit {
	got := map[string]Hit{}
	res := []*regexp.Regexp{regexp.MustCompile(`\.Doc$`)}
	for _, h := range WorldHits(ParseAliases("src/World.flix", worldPkg), ParseEnums("src/World.flix", worldPkg),
		[]string{"World.World"}, res, max) {
		got[h.Rule+":"+h.Field] = h
	}
	return got
}

func TestWorldResourceFollowsAliasesAndEnums(t *testing.T) {
	got := worldHitsOf(100)
	for _, f := range []string{"docs", "boxed", "block", "screen", "pair"} {
		if h, ok := got["world-resource:"+f]; !ok || strings.Join(h.Found, ",") != "Theme.Doc" {
			t.Fatalf("%s が鳴らない: %v", f, got)
		}
	}
}

func TestWorldResourceDoesNotEnterTypeArguments(t *testing.T) {
	got := worldHitsOf(100)
	for _, f := range []string{"flag", "enemies", "picked", "t"} {
		if _, ok := got["world-resource:"+f]; ok {
			t.Fatalf("%s が鳴った: %v", f, got)
		}
	}
}

func TestWorldResourceHitLineIsTheFieldLine(t *testing.T) {
	if h := worldHitsOf(100)["world-resource:block"]; h.Line != 18 {
		t.Fatalf("行 %d (期待 18)", h.Line)
	}
}

func TestWorldFieldsIsQuietAtTheLimit(t *testing.T) {
	if _, ok := worldHitsOf(9)["world-fields:"]; ok {
		t.Fatal("上限ちょうどで鳴った")
	}
}

func TestWorldFieldsFiresAboveTheLimit(t *testing.T) {
	if h := worldHitsOf(8)["world-fields:"]; h.Size != 9 {
		t.Fatalf("上限を超えて鳴らない: %v", worldHitsOf(8))
	}
}

// 画面の enum に case を足しても、Doc を見つけるかどうかは変わらない
func TestWorldResourceIgnoresTheNumberOfScreenCases(t *testing.T) {
	const one = "mod World {\n    pub type alias World = { screen = Screen }\n    pub enum Screen { case Play(Theme.Doc) }\n}\n"
	const two = "mod World {\n    pub type alias World = { screen = Screen }\n    pub enum Screen { case Title, case Play(Theme.Doc) }\n}\n"
	res := []*regexp.Regexp{regexp.MustCompile(`\.Doc$`)}
	count := func(src string) int {
		return len(WorldHits(ParseAliases("w.flix", src), ParseEnums("w.flix", src), []string{"World.World"}, res, 100))
	}
	if count(one) != 1 || count(two) != 1 {
		t.Fatalf("1 case: %d / 2 case: %d", count(one), count(two))
	}
}

const wrappedWorld = `mod World {
    pub type alias World = WorldOf
    enum WorldOf(WorldRec)
    type alias WorldRec = {
        theme = Theme.Doc,
        t = Float64
    }
}
`

func TestWorldResourceSeesThroughAWorldWrappedInAnEnum(t *testing.T) {
	res := []*regexp.Regexp{regexp.MustCompile(`\.Doc$`)}
	hits := WorldHits(ParseAliases("w.flix", wrappedWorld), ParseEnums("w.flix", wrappedWorld), []string{"World.World"}, res, 100)
	if len(hits) != 1 || hits[0].Field != "theme" || hits[0].Line != 5 {
		t.Fatalf("got %+v", hits)
	}
}

func TestParseEnumsReadsEveryCasePayload(t *testing.T) {
	var got []string
	for _, e := range ParseEnums("a.flix", "mod M { enum Flag { case On, case Off }\n enum Two { case A(Int32), B, case C(Bool) }\n enum One(String) }\n") {
		var types []string
		for _, p := range e.Payloads {
			types = append(types, p.Type)
		}
		got = append(got, fmt.Sprintf("%s/%d=%s", e.Name, e.Cases, strings.Join(types, ",")))
	}
	if strings.Join(got, " ") != "Flag/2= Two/3=Int32,Bool One/1=String" {
		t.Fatalf("got %v", got)
	}
}

func writeWorldRepo(t *testing.T, exemptRules, local string) string {
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
		`"skipDirNames":["lib","test"],"roots":["World.World"],"threshold":50,"exempt":{},`+
		`"worldShape":{"resourceTypes":["\\.Doc$"],"maxTopFields":2},"exemptRules":`+exemptRules+`}`)
	if local != "" {
		put("bin/lint-rules/record-wrap.local.json", local)
	}
	put("flix.toml", "")
	put("src/Theme.flix", "mod Theme {\n    pub type alias Doc = { bg = Int32 }\n    pub enum Wrap(Doc)\n}\n")
	put("src/World.flix", "mod World {\n    pub type alias World = { theme = Theme.Wrap, t = Float64 }\n}\n")
	put("src/View.flix", "mod View {\n    pub def f(): Int32 = 1\n}\n")
	return root
}

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String() + errOut.String()
}

func TestWorldResourceIsQuietForAnUnrelatedFile(t *testing.T) {
	root := writeWorldRepo(t, `{}`, "")
	if code, text := run(t, root, "src/View.flix"); code != 0 {
		t.Fatalf("関わらないファイルで鳴った: %s", text)
	}
}

func TestWorldResourceReportsWhenTheEnumFileIsNamed(t *testing.T) {
	root := writeWorldRepo(t, `{}`, "")
	code, text := run(t, root, "src/Theme.flix")
	if code != 1 || !strings.Contains(text, "src/World.flix:2 theme = Theme.Wrap (Theme.Doc)") {
		t.Fatalf("code=%d\n%s", code, text)
	}
}

func TestLocalExemptRulesSilences(t *testing.T) {
	root := writeWorldRepo(t, `{}`, `{"exemptRules":{"src/World.flix::world-resource":"試しに残す"}}`)
	if code, text := run(t, root, "--all"); code != 0 {
		t.Fatalf("code=%d\n%s", code, text)
	}
}

func TestStaleExemptRulesFiresButMissingFileIsNotCounted(t *testing.T) {
	root := writeWorldRepo(t, `{"src/World.flix::world-resource":"残す","templates/x/src/World.flix::world-fields":"このリポに無い"}`,
		`{"exemptRules":{"src/World.flix::world-fields":"もう鳴らない"}}`)
	code, text := run(t, root, "--all")
	if code != 1 || !strings.Contains(text, "src/World.flix::world-fields は bin/lint-rules/record-wrap.local.json の exemptRules") ||
		strings.Contains(text, "templates/x") {
		t.Fatalf("code=%d\n%s", code, text)
	}
}

func TestExemptRulesKeyMustNameARule(t *testing.T) {
	root := writeWorldRepo(t, `{"src/World.flix::theme":"欄名は書かない"}`, "")
	var out, errOut strings.Builder
	if _, err := Run(&out, &errOut, root, []string{"--all"}); err == nil {
		t.Fatal("規則の id でない鍵を通した")
	}
}
