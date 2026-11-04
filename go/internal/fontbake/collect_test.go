package fontbake

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func collectFrom(t *testing.T, files map[string]string) (*Charset, []Notice) {
	t.Helper()
	root := t.TempDir()
	for rel, body := range files {
		writeFile(t, root, rel, body)
	}
	cs, notices, err := Collect(root, DefaultDevDirs)
	if err != nil {
		t.Fatal(err)
	}
	return cs, notices
}

func has(cs *Charset, s string) bool {
	for _, r := range s {
		if _, ok := cs.Origins[r]; !ok {
			return false
		}
	}
	return true
}

func hasAny(cs *Charset, s string) bool {
	for _, r := range s {
		if _, ok := cs.Origins[r]; ok {
			return true
		}
	}
	return false
}

func TestYarnLinesAreCollectedButNotCommentsOrHeaders(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/talk/a.yarn": "title: 見出し\n---\n// 注釈\nルネ: 泉へ\n==="})
	if !has(cs, "ルネ泉へ") || hasAny(cs, "見出注釈") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestYarnOriginHasFileAndLine(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/talk/a.yarn": "title: x\n---\n泉"})
	if got := cs.Origins['泉'][0].String(); got != "assets/talk/a.yarn:3" {
		t.Fatalf("got %s", got)
	}
}

func TestJSONValuesAreCollectedButNotKeys(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/items.json": `{"名前": "薬草", "list": ["毒消し"]}`})
	if !has(cs, "薬草毒消し") || hasAny(cs, "名前") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestJSONNoteValuesAreSkipped(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/a.json": `{"// memo": "鬱", "note": "鬱", "_x": ["鬱"], "v": "可"}`})
	if hasAny(cs, "鬱") || !has(cs, "可") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestJSONRootTitleIsSkippedButNestedTitleIsKept(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/a.json": `{"title": "🃏一覧", "quests": [{"title": "泉"}]}`})
	if hasAny(cs, "🃏一覧") || !has(cs, "泉") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestVariationSelectorIsNotCollected(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/a.txt": "☀\uFE0F"})
	if hasAny(cs, "\uFE0F") || !has(cs, "☀") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestPrivateUseCharIsNotGame(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"src/A.flix": "def f(): Char = '\\uE000'\n"})
	if !has(cs, "\uE000") || cs.Game['\uE000'] {
		t.Fatalf("game=%v", cs.Game['\uE000'])
	}
}

func TestJSONUnicodeEscapeIsDecoded(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/a.json": `{"v": "\u6cc9"}`})
	if !has(cs, "泉") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestJSONOriginLineCountsNewlines(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/a.json": "{\n  \"a\": \"x\",\n  \"b\": \"泉\"\n}"})
	if got := cs.Origins['泉'][0].Line; got != 3 {
		t.Fatalf("got %d", got)
	}
}

func TestSchemaJSONIsSkipped(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/a.schema.json": `{"description": "説", "title": "題"}`})
	if hasAny(cs, "説題") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestFlixStringLiteralsAreCollectedButNotComments(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"src/A.flix": "// 注\ndef f(): String = \"宿屋\" /* 釈 */\n/// 文書\n"})
	if !has(cs, "宿屋") || hasAny(cs, "注釈文書") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestFlixInterpolationNestedStringIsCollected(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"src/A.flix": "def f(n: Int32): String = \"所持${g(\"金\")}円\"\n"})
	if !has(cs, "所持金円") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestFlixCharLiteralAndUnicodeEscapeAreCollected(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"src/A.flix": "def f(): Char = '・'\ndef g(): String = \"\\u3000\"\n"})
	if !has(cs, "・\u3000") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestFlixConsoleLinesAreSkipped(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"src/A.flix": "def f(): Unit \\ IO = println(\"鬱\")\ndef g(): Unit = Log.warn(\"鬱\")\n"})
	if hasAny(cs, "鬱") {
		t.Fatalf("got %q", string(cs.Runes()))
	}
}

func TestRuntimeCharConstructionIsNoticed(t *testing.T) {
	_, notices := collectFrom(t, map[string]string{"src/A.flix": "def f(): Char = Int32.truncateToChar(0x3042)\n"})
	if len(notices) != 1 || notices[0].At.String() != "src/A.flix:1" {
		t.Fatalf("got %+v", notices)
	}
}

func TestWithASCIIAddsPrintableASCII(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"assets/a.txt": "泉"})
	got := cs.WithASCII()
	if !strings.Contains(got, "泉") || !strings.Contains(got, "~") || !strings.Contains(got, " ") {
		t.Fatalf("got %q", got)
	}
}

func TestDevDirCharIsNotGame(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"src/sim/Sim.flix": "def f(): String = \"⚠\"\n"})
	if !has(cs, "⚠") || cs.Game['⚠'] {
		t.Fatalf("game=%v", cs.Game['⚠'])
	}
}

func TestDocFieldCharIsNotGame(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{"src/Starts.flix": "def f(): R = { name = \"a\", doc = \"〜\" }\n"})
	if cs.Game['〜'] {
		t.Fatal("doc の欄の字が遊ぶ画面の字になった")
	}
}

func TestGameOriginIsListedFirst(t *testing.T) {
	cs, _ := collectFrom(t, map[string]string{
		"src/render/A.flix": "def f(): String = \"泉\"\n",
		"src/B.flix":        "def g(): String = \"泉\"\n",
	})
	if !cs.Game['泉'] || cs.Origins['泉'][0].File != "src/B.flix" {
		t.Fatalf("got %+v", cs.Origins['泉'])
	}
}
