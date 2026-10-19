package yarn

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testdata = "../../../testdata/yarn"

func buildText(t *testing.T, text string, vocab *Vocab) (*Program, []Problem) {
	t.Helper()
	return BuildProgram([]string{"t.yarn"}, []string{text}, vocab, "vocab.json")
}

func messages(ps []Problem) string {
	var out []string
	for _, p := range ps {
		out = append(out, p.String())
	}
	return strings.Join(out, "\n")
}

// ── 公式のテストケース ──

// 公式の TestCases の .yarn は、どれも部分集合の外の構文を含み、行番号つきの「読まない」で止まる。
func TestOfficialFilesOutsideTheSubsetAreRefusedWithLineNumbers(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(testdata, "official", "*.yarn"))
	if len(files) != 35 {
		t.Fatalf("公式の .yarn は 35 本のはず: %d", len(files))
	}
	for _, f := range files {
		data, _ := os.ReadFile(f)
		_, ps := BuildProgram([]string{filepath.Base(f)}, []string{string(data)}, nil, "")
		refused := 0
		for _, p := range ps {
			if p.Unsupported && p.Line > 0 {
				refused++
			}
		}
		if refused == 0 {
			t.Errorf("%s が断られない:\n%s", filepath.Base(f), messages(ps))
		}
	}
}

// 公式の ParseFailures は、どれも行番号つきの知らせで止まる（読まない構文か、公式と同じ誤り）。
func TestOfficialParseFailuresAllStopWithLineNumbers(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(testdata, "official", "ParseFailures", "*.yarn"))
	if len(files) != 33 {
		t.Fatalf("ParseFailures は 33 本のはず: %d", len(files))
	}
	for _, f := range files {
		data, _ := os.ReadFile(f)
		_, ps := BuildProgram([]string{filepath.Base(f)}, []string{string(data)}, nil, "")
		if len(ps) == 0 || ps[0].Line <= 0 {
			t.Errorf("%s が行番号つきで止まらない: %v", filepath.Base(f), ps)
		}
	}
}

// engine_world のテストが読む木（抜き出した部分集合と YarnRunner のシナリオ）は .yarn から作り直した物と同じ。
func TestSubsetJsonIsFresh(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(testdata, "subset", "*.yarn"))
	runner, _ := filepath.Glob(filepath.Join(testdata, "runner", "*.yarn"))
	files = append(files, runner...)
	if len(files) < 2 {
		t.Fatal("subset と runner に .yarn が無い")
	}
	for _, f := range files {
		data, _ := os.ReadFile(f)
		prog, ps := BuildProgram([]string{filepath.Base(f)}, []string{string(data)}, nil, "")
		if len(ps) > 0 {
			t.Errorf("%s が読めない:\n%s", f, messages(ps))
			continue
		}
		want, _ := Encode(prog)
		got, _ := os.ReadFile(strings.TrimSuffix(f, ".yarn") + ".yarn.json")
		if string(got) != string(want) {
			t.Errorf("%s.json がずれている（bin/fge yarn build %s --no-vocab --out %s.json）", f, filepath.Base(f), filepath.Base(f))
		}
	}
}

// ── 字下げと選択肢 ──

// -> の行より深い行はその選択肢の中身になり、浅い行で選択肢の後ろへ戻る。
func TestIndentedLinesAfterAnOptionBecomeItsBody(t *testing.T) {
	prog, ps := buildText(t, "title: A\n---\n-> x\n    in x\n-> y\nafter\n===\n", nil)
	if len(ps) > 0 {
		t.Fatal(messages(ps))
	}
	body := prog.Nodes[0].Body
	got := []string{body[0].Kind, body[0].Options[0].Body[0].Text, body[0].Options[1].Text, body[1].Text}
	want := []string{"options", "in x", "y", "after"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("got %v want %v", got, want)
	}
}

// -> の直後の空行は選択肢のまとまりを終える（続く -> は別のまとまり）。
func TestBlankLineAfterAnOptionEndsTheGroup(t *testing.T) {
	prog, _ := buildText(t, "title: A\n---\n-> x\n\n-> y\n===\n", nil)
	if n := len(prog.Nodes[0].Body); n != 2 {
		t.Errorf("まとまりは 2 つのはず: %d", n)
	}
}

// ── 行 ──

// エスケープしていない最初の : の左が話し手。\: は字のまま。
func TestSpeakerIsBeforeTheFirstUnescapedColon(t *testing.T) {
	prog, _ := buildText(t, "title: A\n---\ngirl: やあ: 元気？\n時刻は 9\\:12\n===\n", nil)
	b := prog.Nodes[0].Body
	got := []string{b[0].Speaker, b[0].Text, b[1].Speaker, b[1].Text}
	want := []string{"girl", "やあ: 元気？", "", "時刻は 9:12"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("got %q want %q", got, want)
	}
}

// 読まない構文は行番号と「代わりに」を付けて断る。
func TestRefusedSyntaxNamesTheLineAndTheAlternative(t *testing.T) {
	_, ps := buildText(t, "title: A\n---\nhi\n<<set $x = 1>>\n===\n", nil)
	if len(ps) != 1 || ps[0].Line != 4 || !ps[0].Unsupported || !strings.Contains(ps[0].Msg, "代わりに") {
		t.Errorf("got %v", ps)
	}
}

// ── 語彙 ──

func testVocab() *Vocab {
	return &Vocab{
		Speakers: []string{"girl", "avatar"},
		Nodes:    []string{"op_desk"},
		Tags:     map[string][]string{"face": {"happy", "sad"}, "suspect": {}},
	}
}

// 語彙に無い話し手・タグの値・コマンドと、コードが開くのに .yarn に無いノードを、行番号と近い名前の案で止める。
func TestVocabularyMismatchesStopWithSuggestions(t *testing.T) {
	_, ps := buildText(t, "title: op_dsk\n---\ngril: やあ #face:hapy\n-> 疑う #suspect:yes\n<<shake>>\n===\n", testVocab())
	got := messages(ps)
	for _, want := range []string{
		"t.yarn:3: 知らない話し手 gril（もしかして: girl）",
		"t.yarn:3: タグ #face の値 \"hapy\" を知らない（もしかして: happy）",
		"t.yarn:4: タグ #suspect は値を取らない",
		"t.yarn:5: 知らないコマンド <<shake>>",
		"vocab.json:1: コードが開くノード op_desk が .yarn に無い（もしかして: op_dsk）",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%q が無い:\n%s", want, got)
		}
	}
}

// <<wait>> は 0 以上の秒を 1 つだけ取る。
func TestWaitTakesOneNonNegativeNumber(t *testing.T) {
	_, ps := buildText(t, "title: op_desk\n---\n<<wait 0.5>>\n<<wait>>\n<<wait -1>>\n===\n", testVocab())
	lines := []int{}
	for _, p := range ps {
		lines = append(lines, p.Line)
	}
	if len(lines) != 2 || lines[0] != 4 || lines[1] != 5 {
		t.Errorf("4 行目と 5 行目だけのはず: %v", ps)
	}
}
